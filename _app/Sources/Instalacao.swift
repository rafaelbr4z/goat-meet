// Primeira abertura (permissões e modelo de transcrição) e atualização automática pelo GitHub.

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

let appAbertoEm = Date()

// MARK: - Utilidades

func executar(_ caminho: String, _ args: [String]) -> (codigo: Int32, saida: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caminho)
    p.arguments = args
    let cano = Pipe()
    p.standardOutput = cano
    p.standardError = cano
    do { try p.run() } catch { return (-1, "") }
    let d = cano.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

/// A identidade da assinatura de um app, quando ela é fixa (igual de uma versão para a outra).
/// App montado localmente, sem assinatura fixa, devolve nil.
func requisitoFixo(_ caminho: String) -> String? {
    let r = executar("/usr/bin/codesign", ["-d", "-r-", caminho])
    for linha in r.saida.components(separatedBy: "\n") {
        if linha.hasPrefix("designated =>") {
            return linha.contains("certificate leaf") ? linha : nil
        }
    }
    return nil
}

// MARK: - Primeira abertura

func estadoDoSetup() -> [String: Any] {
    let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let tela = CGPreflightScreenCaptureAccess()
    let modelo = FileManager.default.fileExists(atPath: modelURL.path)
    let nome = ((cfg()["nome"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var perm = [String: Any]()
    perm["mic"] = mic
    perm["tela"] = tela
    perm["agenda"] = Agenda.shared.permitido
    var o = [String: Any]()
    o["perm"] = perm
    o["nome"] = nome
    o["pasta"] = caminhoAmigavel(reunioesDir.path)
    o["modelo"] = modelo
    o["baixando"] = Modelo.shared.ativo
    o["precisa"] = nome.isEmpty || !mic || !tela || !modelo
    o["atualizacao"] = Atualizador.shared.pronta ?? ""
    o["versao"] = Atualizador.shared.versaoAtual
    return o
}

func abrirAjustesDePrivacidade(_ painel: String) {
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + painel) {
        NSWorkspace.shared.open(u)
    }
}

func pedirPermissao(_ qual: String, _ fim: @escaping (Bool) -> Void) {
    if qual == "mic" {
        let estado = AVCaptureDevice.authorizationStatus(for: .audio)
        if estado == .authorized {
            fim(true)
        } else if estado == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { fim(ok) } }
        } else {
            abrirAjustesDePrivacidade("Privacy_Microphone")
            fim(false)
        }
    } else if qual == "tela" {
        if CGPreflightScreenCaptureAccess() {
            fim(true)
        } else {
            let ok = CGRequestScreenCaptureAccess()
            if !ok { abrirAjustesDePrivacidade("Privacy_ScreenCapture") }
            fim(CGPreflightScreenCaptureAccess())
        }
    } else if qual == "agenda" {
        if Agenda.shared.negado {
            abrirAjustesDePrivacidade("Privacy_Calendars")
            fim(false)
        } else {
            Agenda.shared.pedirAcesso { ok in fim(ok) }
        }
    } else {
        fim(false)
    }
}

/// Baixa o modelo de transcrição (1,6 GB) e avisa o andamento.
final class Modelo: NSObject, URLSessionDownloadDelegate {
    static let shared = Modelo()
    var ativo = false
    var aviso: (([String: Any]) -> Void)?
    private var ultimo = Date.distantPast

    private func evento(_ p: Double, pronto: Bool, erro: String = "") -> [String: Any] {
        var e = [String: Any]()
        e["tipo"] = "modelo"
        e["p"] = p
        e["pronto"] = pronto
        if !erro.isEmpty { e["erro"] = erro }
        return e
    }

    func baixar(_ aviso: @escaping ([String: Any]) -> Void) {
        self.aviso = aviso
        if FileManager.default.fileExists(atPath: modelURL.path) {
            aviso(evento(1, pronto: true))
            return
        }
        if ativo { return }
        guard let u = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin") else { return }
        ativo = true
        let sessao = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        sessao.downloadTask(with: u).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite <= 0 || Date().timeIntervalSince(ultimo) < 0.3 { return }
        ultimo = Date()
        aviso?(evento(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), pronto: false))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        var certo = false
        if let h = downloadTask.response as? HTTPURLResponse, h.statusCode == 200 {
            try? fm.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: modelURL)
            do {
                try fm.moveItem(at: location, to: modelURL)
                certo = true
            } catch {
                certo = false
            }
        }
        ativo = false
        if certo {
            gmLog("Modelo de transcrição baixado.")
            aviso?(evento(1, pronto: true))
        } else {
            aviso?(evento(0, pronto: false, erro: "Não consegui baixar o modelo. Confira a internet e tente de novo."))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil { return }
        ativo = false
        aviso?(evento(0, pronto: false, erro: "O download do modelo parou. Confira a internet e tente de novo."))
        session.finishTasksAndInvalidate()
    }
}

// MARK: - Atualização automática

/// Confere a última versão publicada no GitHub, baixa, confere a assinatura e deixa pronta para trocar.
final class Atualizador {
    static let shared = Atualizador()
    let repositorio = "rafaelbr4z/goat-meet"
    var pronta: String?
    var avisar: ((String) -> Void)?
    private var ocupado = false

    var versaoAtual: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    var pastaNova: URL { appDir.appendingPathComponent("atualizacao", isDirectory: true) }

    /// Só se atualiza sozinho o app instalado com assinatura fixa, em uma pasta onde dá para gravar.
    var podeAtualizar: Bool {
        let caminho = Bundle.main.bundlePath
        if !caminho.hasSuffix(".app") || caminho.contains("/AppTranslocation/") { return false }
        let pasta = Bundle.main.bundleURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: pasta) { return false }
        return requisitoFixo(caminho) != nil
    }

    func verificar() {
        if ocupado || pronta != nil { return }
        ocupado = true
        DispatchQueue.global(qos: .utility).async {
            self.buscar()
            self.ocupado = false
        }
    }

    private func buscar() {
        if !podeAtualizar { return }
        guard let u = URL(string: "https://api.github.com/repos/" + repositorio + "/releases/latest"),
              let d = try? Data(contentsOf: u),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let arquivos = o["assets"] as? [[String: Any]] else { return }
        let nova = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if nova.compare(versaoAtual, options: .numeric) != .orderedDescending { return }
        var link = ""
        for a in arquivos {
            if let nome = a["name"] as? String, nome == "GoatMeet.zip", let l = a["browser_download_url"] as? String { link = l }
        }
        guard let zipURL = URL(string: link), !link.isEmpty, let zip = try? Data(contentsOf: zipURL) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: pastaNova)
        try? fm.createDirectory(at: pastaNova, withIntermediateDirectories: true)
        let arquivo = pastaNova.appendingPathComponent("GoatMeet.zip")
        guard (try? zip.write(to: arquivo)) != nil else { return }
        if executar("/usr/bin/ditto", ["-x", "-k", arquivo.path, pastaNova.path]).codigo != 0 { return }
        try? fm.removeItem(at: arquivo)
        let novo = pastaNova.appendingPathComponent("Goat Meet.app").path
        let meu = requisitoFixo(Bundle.main.bundlePath)
        if !fm.fileExists(atPath: novo) || executar("/usr/bin/codesign", ["--verify", "--strict", novo]).codigo != 0
            || meu == nil || meu != requisitoFixo(novo) {
            gmLog("Atualização " + nova + " recusada: a assinatura não confere.")
            try? fm.removeItem(at: pastaNova)
            return
        }
        gmLog("Atualização " + nova + " pronta.")
        DispatchQueue.main.async {
            self.pronta = nova
            self.avisar?(nova)
        }
    }

    /// Troca o app pelo novo e abre de novo. Chamar só com o app parado (sem gravar nem transcrever).
    func aplicar() {
        if pronta == nil { return }
        let novo = pastaNova.appendingPathComponent("Goat Meet.app").path
        let atual = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; rm -rf \"$1.antigo\"; "
            + "mv \"$1\" \"$1.antigo\" && { mv \"$2\" \"$1\" || mv \"$1.antigo\" \"$1\"; }; rm -rf \"$1.antigo\"; open \"$1\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", atual, novo]
        do { try p.run() } catch { return }
        gmLog("Trocando para a versão " + (pronta ?? "") + ".")
        NSApp.terminate(nil)
    }
}

// Goat Meet 2 — grava reuniões (som do computador + microfone, em faixas separadas),
// transcreve no próprio Mac com o whisper.cpp e mostra tudo num catálogo.
//
// Cada reunião é uma pasta em ~/Goat Meet/Reunioes/<id>/ com:
//   reuniao.json      título, data, duração, status, participantes
//   transcricao.md    transcrição com "Você" / "Outros" (é o que o Claude lê)
//   transcricao.json  a mesma transcrição em trechos, para a interface
//   minuta.md         escrita pelo Claude; aparece na aba Minuta
//   audio.m4a         áudio completo; eu.m4a e outros.m4a são as faixas separadas

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import CoreGraphics
import EventKit
import WebKit

// MARK: - Pastas

let home = FileManager.default.homeDirectoryForCurrentUser
let baseDir = home.appendingPathComponent("Goat Meet", isDirectory: true)
let appDir = baseDir.appendingPathComponent("_app", isDirectory: true)
let tmpDir = appDir.appendingPathComponent("tmp", isDirectory: true)
let uiURL = appDir.appendingPathComponent("ui/index.html")
let modelURL = appDir.appendingPathComponent("models/ggml-large-v3-turbo.bin")
let vocabularioURL = appDir.appendingPathComponent("vocabulario.txt")
let logURL = appDir.appendingPathComponent("goatmeet.log")

struct GMError: LocalizedError {
    let message: String
    let permissao: Bool
    init(_ m: String, permissao: Bool = false) {
        message = m
        self.permissao = permissao
    }
    var errorDescription: String? { message }
}

let logLock = NSLock()
func gmLog(_ text: String) {
    logLock.lock(); defer { logLock.unlock() }
    guard let data = "[\(Date())] \(text)\n".data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

func hostSecondsNow() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

func whisperPath() -> String? {
    ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

func formatted(_ d: Date, _ pattern: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "pt_BR")
    f.dateFormat = pattern
    return f.string(from: d)
}

func jsonTexto(_ o: Any) -> String {
    guard JSONSerialization.isValidJSONObject(o),
          let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "null" }
    return String(decoding: d, as: UTF8.self)
}

// MARK: - Catálogo (pastas das reuniões)

let metaLock = NSLock()

func pastaReuniao(_ id: String) -> URL? {
    guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
    return reunioesDir.appendingPathComponent(id, isDirectory: true)
}

func lerMeta(_ id: String) -> [String: Any]? {
    guard let dir = pastaReuniao(id),
          let d = try? Data(contentsOf: dir.appendingPathComponent("reuniao.json")),
          let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
    return o as? [String: Any]
}

func gravarMeta(_ id: String, _ meta: [String: Any]) {
    guard let dir = pastaReuniao(id),
          let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? d.write(to: dir.appendingPathComponent("reuniao.json"), options: .atomic)
}

func atualizarMeta(_ id: String, _ mudar: (inout [String: Any]) -> Void) {
    metaLock.lock(); defer { metaLock.unlock() }
    guard var m = lerMeta(id) else { return }
    mudar(&m)
    gravarMeta(id, m)
}

func idsDasReunioes() -> [String] {
    let nomes = (try? FileManager.default.contentsOfDirectory(atPath: reunioesDir.path)) ?? []
    return nomes.filter { lerMeta($0) != nil }
}

func resumoDaMinuta(_ texto: String) -> String {
    var linhas: [String] = []
    for l in texto.components(separatedBy: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(">") {
            linhas.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else if !linhas.isEmpty {
            break
        }
    }
    var r = linhas.joined(separator: " ")
    r = r.replacingOccurrences(of: "\\{\\?([^}]+)\\}", with: "$1", options: .regularExpression)
    return r.count > 220 ? String(r.prefix(220)) + "…" : r
}

func lerMinuta(_ dir: URL) -> String? {
    guard let t = try? String(contentsOf: dir.appendingPathComponent("minuta.md"), encoding: .utf8) else { return nil }
    if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    return t
}

func numero(_ v: Any?) -> Double {
    (v as? NSNumber)?.doubleValue ?? 0
}

func listarReunioes() -> [[String: Any]] {
    var out: [[String: Any]] = []
    for id in idsDasReunioes() {
        guard let m = lerMeta(id), let dir = pastaReuniao(id) else { continue }
        let minuta = lerMinuta(dir)
        var r = [String: Any]()
        r["id"] = id
        r["titulo"] = (m["titulo"] as? String) ?? id
        r["inicio"] = (m["inicio"] as? String) ?? ""
        r["duracaoSeg"] = numero(m["duracaoSeg"])
        r["status"] = (m["status"] as? String) ?? "pronta"
        r["temMinuta"] = minuta != nil
        r["resumo"] = minuta == nil ? "" : resumoDaMinuta(minuta ?? "")
        r["participantes"] = (m["participantes"] as? [String]) ?? [String]()
        out.append(r)
    }
    out.sort { (a, b) in
        let x = (a["inicio"] as? String) ?? ""
        let y = (b["inicio"] as? String) ?? ""
        return x > y
    }
    return out
}

func abrirReuniao(_ id: String) -> [String: Any]? {
    guard let m = lerMeta(id), let dir = pastaReuniao(id) else { return nil }
    var o = [String: Any]()
    o["id"] = id
    o["titulo"] = (m["titulo"] as? String) ?? id
    o["inicio"] = (m["inicio"] as? String) ?? ""
    o["duracaoSeg"] = numero(m["duracaoSeg"])
    o["status"] = (m["status"] as? String) ?? "pronta"
    o["participantes"] = (m["participantes"] as? [String]) ?? [String]()
    o["erro"] = (m["erro"] as? String) ?? ""
    o["ondas"] = (m["ondas"] as? [Any]) ?? [Any]()
    if let ag = m["agenda"] as? [String: Any] {
        var a = [String: Any]()
        a["tipo"] = (ag["tipo"] as? String) ?? "criado"
        a["titulo"] = (ag["titulo"] as? String) ?? ""
        o["agenda"] = a
    }
    if let minuta = lerMinuta(dir) {
        o["minuta"] = minuta
    } else {
        o["minuta"] = NSNull()
    }

    var segmentos: [Any] = []
    if let d = try? Data(contentsOf: dir.appendingPathComponent("transcricao.json")),
       let j = try? JSONSerialization.jsonObject(with: d),
       let a = j as? [Any] {
        segmentos = a
    }
    o["segmentos"] = segmentos

    o["audio"] = NSNull()
    for nome in ["audio.m4a", "audio.wav"] {
        let u = dir.appendingPathComponent(nome)
        if FileManager.default.fileExists(atPath: u.path) {
            o["audio"] = u.absoluteString
            break
        }
    }
    return o
}

func criarReuniao(titulo: String, inicio: Date, duracao: Double, trabalho: String) -> String {
    let fm = FileManager.default
    let base = formatted(inicio, "yyyy-MM-dd HH'h'mm")
    var id = base
    var n = 2
    while fm.fileExists(atPath: reunioesDir.appendingPathComponent(id).path) {
        id = "\(base) (\(n))"
        n += 1
    }
    try? fm.createDirectory(at: reunioesDir.appendingPathComponent(id), withIntermediateDirectories: true)
    let t = titulo.trimmingCharacters(in: .whitespacesAndNewlines)
    var meta = [String: Any]()
    meta["titulo"] = t.isEmpty ? "Reunião \(formatted(inicio, "dd/MM HH:mm"))" : t
    meta["tituloAutomatico"] = t.isEmpty
    meta["inicio"] = ISO8601DateFormatter().string(from: inicio)
    meta["duracaoSeg"] = duracao.rounded()
    meta["status"] = "transcrevendo"
    meta["participantes"] = [String]()
    meta["trabalho"] = trabalho
    gravarMeta(id, meta)
    return id
}

// MARK: - Gravação de uma faixa (com silêncio nos buracos, para as duas faixas ficarem alinhadas)

func zeroFill(_ b: AVAudioPCMBuffer) {
    for buf in UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList) {
        if let p = buf.mData { memset(p, 0, Int(buf.mDataByteSize)) }
    }
}

final class TrackWriter {
    let url: URL
    private var startTime: Double
    private var file: AVAudioFile?
    private var written: AVAudioFramePosition = 0
    private var first = true
    private var failed = false
    private var pico: Float = 0
    private let lock = NSLock()

    init(url: URL, startTime: Double) {
        self.url = url
        self.startTime = startTime
    }

    /// Pico do áudio desde a última leitura (0 a 1), para o medidor da interface.
    func lerNivel() -> Float {
        lock.lock(); defer { lock.unlock() }
        let v = pico
        pico = 0
        return v
    }

    func write(_ buffer: AVAudioPCMBuffer, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !failed, buffer.frameLength > 0 else { return }
        if let ch = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            let p = ch[0]
            var i = 0
            while i < n {
                let v = abs(p[i])
                if v > pico { pico = v }
                i += 8
            }
        }
        do {
            if file == nil {
                let f = buffer.format
                file = try AVAudioFile(forWriting: url, settings: f.settings,
                                       commonFormat: f.commonFormat, interleaved: f.isInterleaved)
            }
            guard let file = file else { return }
            if first {
                first = false
                // Se o relógio do bloco não bater com o do início, alinha a partir daqui.
                if time.isFinite, abs(time - startTime) > 5 { startTime = time }
            }
            let sr = buffer.format.sampleRate
            let t = time.isFinite ? time : startTime + Double(written) / sr
            var gap = AVAudioFramePosition((t - startTime) * sr) - written
            if gap > AVAudioFramePosition(sr * 0.05) {
                while gap > 0 {
                    let n = AVAudioFrameCount(min(gap, AVAudioFramePosition(sr)))
                    guard let z = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: n) else { break }
                    z.frameLength = n
                    zeroFill(z)
                    try file.write(from: z)
                    written += AVAudioFramePosition(n)
                    gap -= AVAudioFramePosition(n)
                }
            }
            try file.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        } catch {
            failed = true
            gmLog("Erro gravando \(url.lastPathComponent): \(error)")
        }
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}

func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let desc = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
          let format = AVAudioFormat(streamDescription: asbd) else { return nil }
    let frames = CMSampleBufferGetNumSamples(sb)
    guard frames > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
    buf.frameLength = AVAudioFrameCount(frames)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
    return status == noErr ? buf : nil
}

// MARK: - Gravador (som do computador via ScreenCaptureKit + microfone via AVAudioEngine)

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private var sysWriter: TrackWriter?
    private var micWriter: TrackWriter?
    private let audioQueue = DispatchQueue(label: "goatmeet.audio")
    private let screenQueue = DispatchQueue(label: "goatmeet.screen")
    private(set) var micAvailable = false

    func nivelEu() -> Float { micWriter?.lerNivel() ?? 0 }
    func nivelOutros() -> Float { sysWriter?.lerNivel() ?? 0 }

    func start(in dir: URL) async throws {
        let t0 = hostSecondsNow()
        sysWriter = TrackWriter(url: dir.appendingPathComponent("sistema.caf"), startTime: t0)
        micWriter = TrackWriter(url: dir.appendingPathComponent("microfone.caf"), startTime: t0)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            gmLog("Sem permissão de gravação de tela/áudio: \(error)")
            throw GMError("O macOS ainda não deixou o Goat Meet gravar o som do computador.", permissao: true)
        }
        guard let display = content.displays.first else { throw GMError("Nenhuma tela encontrada.") }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await s.startCapture()
        stream = s

        micAvailable = false
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            gmLog("Sem permissão de microfone.")
            return
        }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            gmLog("Nenhum microfone encontrado.")
            return
        }
        let writer = micWriter
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, when in
            let t = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : hostSecondsNow()
            writer?.write(buf, at: t)
        }
        do {
            try e.start()
            engine = e
            micAvailable = true
        } catch {
            input.removeTap(onBus: 0)
            gmLog("Microfone não iniciou: \(error)")
        }
    }

    func stop() async {
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        sysWriter?.close()
        micWriter?.close()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sb), let buf = pcmBuffer(from: sb) else { return }
        sysWriter?.write(buf, at: CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        gmLog("Captura parou: \(error)")
    }
}

// MARK: - Áudio: conversão para 16 kHz mono (formato do Whisper), mixagem e medidas

func loadMono16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0 else { return [] }
    let inFmt = file.processingFormat
    guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
          let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw GMError("Não consegui converter o áudio.") }
    conv.downmix = true

    var out: [Float] = []
    out.reserveCapacity(Int(Double(file.length) * 16000 / inFmt.sampleRate) + 16000)
    let chunk: AVAudioFrameCount = 32768
    var done = false
    while true {
        guard let ob = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 16384) else { break }
        var err: NSError?
        let st = conv.convert(to: ob, error: &err) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            guard let ib = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk) else {
                done = true; status.pointee = .endOfStream; return nil
            }
            do { try file.read(into: ib, frameCount: chunk) } catch {
                done = true; status.pointee = .endOfStream; return nil
            }
            if ib.frameLength == 0 { done = true; status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return ib
        }
        if st == .error { throw err ?? GMError("Erro convertendo o áudio.") }
        if ob.frameLength > 0, let p = ob.floatChannelData {
            out.append(contentsOf: UnsafeBufferPointer(start: p[0], count: Int(ob.frameLength)))
        }
        if st == .endOfStream { break }
    }
    return out
}

func picoDe(_ s: [Float]) -> Float {
    var p: Float = 0
    for v in s {
        let a = abs(v)
        if a > p { p = a }
    }
    return p
}

func comGanho(_ s: [Float], alvo: Float, maximo: Float) -> [Float] {
    let p = picoDe(s)
    guard p > 0.001 else { return s }
    let g = min(alvo / p, maximo)
    var out = s
    for i in 0..<out.count { out[i] = max(-1, min(1, out[i] * g)) }
    return out
}

func mix(_ signals: [[Float]]) -> [Float] {
    let n = signals.map { $0.count }.max() ?? 0
    var out = [Float](repeating: 0, count: n)
    for s in signals {
        let p = picoDe(s)
        guard p > 0.001 else { continue }
        let g = min(0.5 / p, 8)  // nivela as duas faixas sem estourar o chiado
        for i in 0..<s.count { out[i] += s[i] * g }
    }
    for i in 0..<n { out[i] = max(-1, min(1, out[i])) }
    return out
}

func writeWav(_ samples: [Float], to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var i = 0
    while i < samples.count {
        let n = min(160_000, samples.count - i)
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n)),
              let dst = b.floatChannelData else { throw GMError("Sem memória para gravar o áudio.") }
        b.frameLength = AVAudioFrameCount(n)
        samples.withUnsafeBufferPointer { p in
            dst[0].update(from: p.baseAddress! + i, count: n)
        }
        try f.write(from: b)
        i += n
    }
}

/// Volume (RMS) de um trecho, em amostras de 16 kHz.
func rmsTrecho(_ s: [Float], deMs: Int, ateMs: Int) -> Float {
    let a = max(0, deMs * 16)
    let b = min(s.count, ateMs * 16)
    guard b > a else { return 0 }
    var soma: Float = 0
    for i in a..<b { soma += s[i] * s[i] }
    return (soma / Float(b - a)).squareRoot()
}

/// Volume típico de quando há fala na faixa (percentil 97 de janelas de 100 ms).
func nivelDeFala(_ s: [Float]) -> Float {
    let w = 1600
    var v: [Float] = []
    v.reserveCapacity(s.count / w + 1)
    var i = 0
    while i + w <= s.count {
        var soma: Float = 0
        for j in i..<(i + w) { soma += s[j] * s[j] }
        v.append((soma / Float(w)).squareRoot())
        i += w
    }
    guard !v.isEmpty else { return 0 }
    v.sort()
    return v[min(v.count - 1, Int(Double(v.count) * 0.97))]
}

@discardableResult
func rodar(_ caminho: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caminho)
    p.arguments = args
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    let h = try? FileHandle(forWritingTo: logURL)
    h?.seekToEndOfFile()
    if let h = h {
        p.standardOutput = h
        p.standardError = h
    } else {
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
    }
    do {
        try p.run()
    } catch {
        gmLog("Não consegui rodar \(caminho): \(error)")
        return -1
    }
    p.waitUntilExit()
    try? h?.close()
    return p.terminationStatus
}

// MARK: - Transcrição (whisper.cpp local)

struct Trecho {
    var de: Int      // ms
    var ate: Int     // ms
    var quem: String // "eu" ou "outros"
    var texto: String
}

struct WhisperJSON: Decodable {
    struct Seg: Decodable {
        struct Off: Decodable {
            let from: Int
            let to: Int
        }
        let offsets: Off
        let text: String
    }
    let transcription: [Seg]
}

func transcrever(wav: URL, quem: String) throws -> [Trecho] {
    guard let bin = whisperPath() else {
        throw GMError("O programa de transcrição (whisper-cli) não foi encontrado. Rode o \"Instalar Goat Meet\" de novo.")
    }
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        throw GMError("O modelo de transcrição não foi encontrado. Rode o \"Instalar Goat Meet\" de novo.")
    }
    let base = wav.deletingPathExtension()
    var prompt = "Reunião de trabalho em português do Brasil."
    let termos = termosConhecidos().joined(separator: ", ")
    if !termos.isEmpty { prompt += " Termos usados: " + String(termos.prefix(600)) + "." }
    let status = rodar(bin, ["-m", modelURL.path, "-f", wav.path, "-l", "pt", "-t", "8", "-np",
                             "--prompt", prompt, "-oj", "-of", base.path])
    guard status == 0 else {
        throw GMError("A transcrição falhou (código \(status)). Detalhes em Goat Meet/_app/goatmeet.log.")
    }
    let d = try Data(contentsOf: base.appendingPathExtension("json"))
    let j = try JSONDecoder().decode(WhisperJSON.self, from: d)
    return j.transcription.map { s in
        Trecho(de: s.offsets.from, ate: s.offsets.to, quem: quem,
               texto: s.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

func palavras(_ t: String) -> [String] {
    t.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count > 2 }
}

let frasesFantasma = ["amara.org", "legendas pela comunidade", "legendado por", "inscreva-se no canal", "obrigado por assistir"]

/// O Whisper às vezes marca o começo do trecho no silêncio anterior. Puxa o começo para onde a fala aparece.
func inicioReal(_ faixa: [Float], deMs: Int, ateMs: Int, limiar: Float) -> Int {
    var t = deMs
    while t + 50 <= ateMs {
        if rmsTrecho(faixa, deMs: t, ateMs: t + 50) >= limiar { return max(deMs, t - 100) }
        t += 50
    }
    return deMs
}

/// Tira o que o Whisper inventa em trechos de silêncio e as repetições seguidas.
func limpar(_ trechos: [Trecho], faixa: [Float]) -> [Trecho] {
    let fala = nivelDeFala(faixa)
    let minimo = max(0.0004, fala * 0.06)
    var out: [Trecho] = []
    for t in trechos {
        if t.texto.isEmpty { continue }
        let baixo = t.texto.lowercased()
        if frasesFantasma.contains(where: { baixo.contains($0) }) { continue }
        if rmsTrecho(faixa, deMs: t.de, ateMs: max(t.ate, t.de + 300)) < minimo { continue }
        if let u = out.last, u.texto == t.texto { continue }
        var n = t
        n.de = inicioReal(faixa, deMs: t.de, ateMs: t.ate, limiar: max(minimo * 2, fala * 0.15))
        out.append(n)
    }
    return out
}

/// Sem fone de ouvido, o microfone também pega a voz dos outros saindo da caixa de som.
/// Tira do microfone os trechos que repetem o que já está na faixa da chamada.
func tirarEco(_ eu: [Trecho], _ outros: [Trecho]) -> [Trecho] {
    var out: [Trecho] = []
    for t in eu {
        let p = palavras(t.texto)
        if p.count < 4 {
            out.append(t)
            continue
        }
        var perto = Set<String>()
        for o in outros where o.ate >= t.de - 3000 && o.de <= t.ate + 3000 {
            perto.formUnion(palavras(o.texto))
        }
        let iguais = p.filter { perto.contains($0) }.count
        if Double(iguais) / Double(p.count) < 0.7 { out.append(t) }
    }
    return out
}

func relogio(_ ms: Int) -> String {
    let s = ms / 1000
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%02d:%02d", s / 60, s % 60)
}

func converterM4A(_ wav: URL, _ destino: URL) -> Bool {
    try? FileManager.default.removeItem(at: destino)
    let status = rodar("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "32000", wav.path, destino.path])
    return status == 0 && FileManager.default.fileExists(atPath: destino.path)
}

/// Transforma a gravação bruta (pasta de trabalho) nos arquivos finais da reunião.
func processar(id: String, trabalho: URL) throws {
    guard let dir = pastaReuniao(id) else { throw GMError("Reunião não encontrada.") }
    let fm = FileManager.default
    let sis = (try? loadMono16k(trabalho.appendingPathComponent("sistema.caf"))) ?? []
    let mic = (try? loadMono16k(trabalho.appendingPathComponent("microfone.caf"))) ?? []
    guard !sis.isEmpty || !mic.isEmpty else { throw GMError("Nenhum áudio foi gravado.") }
    let duracao = Double(max(sis.count, mic.count)) / 16000

    var outros: [Trecho] = []
    var eu: [Trecho] = []
    let wavOutros = trabalho.appendingPathComponent("outros.wav")
    let wavEu = trabalho.appendingPathComponent("eu.wav")
    if picoDe(sis) > 0.002 {
        try writeWav(comGanho(sis, alvo: 0.7, maximo: 10), to: wavOutros)
        let bruto = try transcrever(wav: wavOutros, quem: "outros")
        outros = limpar(bruto, faixa: sis)
    }
    if picoDe(mic) > 0.002 {
        try writeWav(comGanho(mic, alvo: 0.7, maximo: 10), to: wavEu)
        let bruto = try transcrever(wav: wavEu, quem: "eu")
        eu = tirarEco(limpar(bruto, faixa: mic), outros)
    }
    var todos = outros + eu
    todos.sort { $0.de < $1.de }

    // transcricao.json (interface)
    var segmentos: [[String: Any]] = []
    for t in todos {
        var s = [String: Any]()
        s["t"] = (Double(t.de) / 100).rounded() / 10
        s["quem"] = t.quem
        s["texto"] = t.texto
        segmentos.append(s)
    }
    let dj = try JSONSerialization.data(withJSONObject: segmentos, options: [])
    try dj.write(to: dir.appendingPathComponent("transcricao.json"), options: .atomic)

    // transcricao.md (leitura e Claude)
    let meta = lerMeta(id) ?? [String: Any]()
    let inicio = ISO8601DateFormatter().date(from: (meta["inicio"] as? String) ?? "") ?? Date()
    let titulo = (meta["titulo"] as? String) ?? id
    var md = "# \(titulo)\n\n"
    md += "- Data: \(formatted(inicio, "dd/MM/yyyy HH:mm"))\n"
    md += "- Duração: \(max(1, Int((duracao / 60).rounded()))) min\n"
    md += "- Falantes: \"Você\" é o microfone do Braz; \"Outros\" é o som da chamada (todas as outras pessoas juntas).\n\n"
    md += "## Transcrição\n\n"
    for t in todos {
        let quem = t.quem == "eu" ? "Você" : "Outros"
        md += "[\(relogio(t.de))] \(quem): \(t.texto)\n"
    }
    if todos.isEmpty { md += "_(nada foi reconhecido na gravação)_\n" }
    try md.write(to: dir.appendingPathComponent("transcricao.md"), atomically: true, encoding: .utf8)

    // áudio final
    let wavMix = trabalho.appendingPathComponent("audio.wav")
    let mixado = mix([sis, mic])
    let ondas = ondasDe(mixado)
    try writeWav(mixado, to: wavMix)
    if !converterM4A(wavMix, dir.appendingPathComponent("audio.m4a")) {
        try? fm.removeItem(at: dir.appendingPathComponent("audio.wav"))
        try? fm.copyItem(at: wavMix, to: dir.appendingPathComponent("audio.wav"))
    }
    if fm.fileExists(atPath: wavEu.path) { _ = converterM4A(wavEu, dir.appendingPathComponent("eu.m4a")) }
    if fm.fileExists(atPath: wavOutros.path) { _ = converterM4A(wavOutros, dir.appendingPathComponent("outros.m4a")) }

    atualizarMeta(id) { m in
        m["status"] = "pronta"
        m["duracaoSeg"] = duracao.rounded()
        m["ondas"] = ondas
        m.removeValue(forKey: "erro")
        m.removeValue(forKey: "trabalho")
    }
    try? fm.removeItem(at: trabalho)
}

// MARK: - App

final class FaixaDeArrasto: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var toggleItem: NSMenuItem!
    var window: NSWindow!
    var webView: WKWebView!
    var paginaPronta = false

    var recorder: Recorder?
    var workDir: URL?
    var iniciando = false
    var startDate = Date()
    var timer: Timer?
    var tiques = 0
    var rascunho = ""
    var pendentes = 0
    var atividade: NSObjectProtocol?
    let fila = DispatchQueue(label: "goatmeet.transcricao")
    var emFila = Set<String>()
    var proximoTitulo = ""
    var avisados = Set<String>()
    var ronda: Timer?
    var rodadas = 0
    var ultimoProx = ""
    var abrirOculto = CommandLine.arguments.contains("--oculto")
    var tocador: AVAudioPlayer?
    var tocadorTimer: Timer?
    var tocadorAtivo = false

    // MARK: início

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        prepararPasta()
        if let a = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let tamanho = a[.size] as? NSNumber, tamanho.intValue > 2_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        criarMenuPrincipal()
        criarMenuDaBarra()
        criarJanela()
        atualizarBarra()
        recuperarPendentes()

        Avisos.shared.aoGravar = { [weak self] titulo in self?.gravarPeloAviso(titulo) }
        if cfgBool("agenda.auto") || cfgBool("avisos.mac") {
            Agenda.shared.pedirAcesso { ok in
                if ok { registrarAntigas() }
                self.emitir(["tipo": "config"])
                self.verificarAvisos()
            }
        }
        ronda = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in self.rondar() }
        fila.async { self.preencherOndas() }

        if whisperPath() == nil || !FileManager.default.fileExists(atPath: modelURL.path) {
            alerta("Falta instalar a transcrição", "Abra a pasta Goat Meet e rode o \"Instalar Goat Meet\".")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mostrarJanela()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder == nil && pendentes == 0 { return .terminateNow }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if recorder != nil {
            a.messageText = "Você está gravando."
            a.informativeText = "Se sair agora, a gravação é interrompida. O que já foi gravado é recuperado quando você abrir o app de novo."
        } else {
            a.messageText = "Ainda estou transcrevendo."
            a.informativeText = "Se sair agora, a transcrição recomeça quando você abrir o app de novo."
        }
        a.addButton(withTitle: "Continuar no app")
        a.addButton(withTitle: "Sair mesmo assim")
        return a.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    // MARK: menus e janela

    func criarMenuPrincipal() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ocultar Goat Meet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Sair do Goat Meet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar Tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Janela")
        win.addItem(withTitle: "Fechar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)

        NSApp.mainMenu = main
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func criarMenuDaBarra() {
        menu.autoenablesItems = false
        toggleItem = item("Iniciar gravação", #selector(alternarPelaBarra))
        menu.addItem(toggleItem)
        menu.addItem(item("Abrir Goat Meet", #selector(abrirPelaBarra)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("Sair do Goat Meet", #selector(sair)))
        statusItem.menu = menu
    }

    func criarJanela() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "goat")
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760), configuration: cfg)
        wv.navigationDelegate = self
        webView = wv

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Goat Meet"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 900, height: 560)
        w.backgroundColor = NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = wv
        // Faixa no alto da janela, acima da interface, para sempre dar para arrastar (e ampliar com dois cliques).
        let faixa = FaixaDeArrasto()
        faixa.translatesAutoresizingMaskIntoConstraints = false
        wv.addSubview(faixa)
        NSLayoutConstraint.activate([
            faixa.topAnchor.constraint(equalTo: wv.topAnchor),
            faixa.leadingAnchor.constraint(equalTo: wv.leadingAnchor),
            faixa.trailingAnchor.constraint(equalTo: wv.trailingAnchor),
            faixa.heightAnchor.constraint(equalToConstant: 30)
        ])
        w.center()
        w.setFrameAutosaveName("GoatMeetPrincipal")
        window = w

        if FileManager.default.fileExists(atPath: uiURL.path) {
            wv.loadFileURL(uiURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
            // Se o aviso de "página carregada" não chegar, mostra a janela mesmo assim.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !self.paginaPronta {
                    self.paginaPronta = true
                    if self.abrirOculto { self.abrirOculto = false } else { self.mostrarJanela() }
                }
            }
        } else {
            alerta("Falta a interface", "Não encontrei Goat Meet/_app/ui/index.html. Rode o \"Instalar Goat Meet\" de novo.")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if paginaPronta { return }
        paginaPronta = true
        ultimoProx = "~"
        verificarAvisos()
        if abrirOculto {
            abrirOculto = false
            return
        }
        mostrarJanela()
    }

    func mostrarJanela() {
        if !paginaPronta { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func alerta(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    func alertaPermissao() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Falta uma permissão do macOS"
        a.informativeText = "Para gravar o som da chamada, ative o Goat Meet em Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema. Depois saia do Goat Meet e abra de novo."
        a.addButton(withTitle: "Abrir Ajustes")
        a.addButton(withTitle: "Agora não")
        if a.runModal() == .alertFirstButtonReturn {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(u)
            }
        }
    }

    // MARK: conversa com a interface

    func emitir(_ evento: [String: Any]) {
        if !paginaPronta { return }
        webView.evaluateJavaScript("window.goatEvento && window.goatEvento(\(jsonTexto(evento)))", completionHandler: nil)
    }

    func responder(_ n: Int, _ valor: Any) {
        webView.evaluateJavaScript("window.goatResposta && window.goatResposta(\(n), \(jsonTexto(valor)))", completionHandler: nil)
    }

    func estadoAtual() -> [String: Any] {
        var e = [String: Any]()
        e["tipo"] = "estado"
        e["gravando"] = recorder != nil
        e["inicio"] = (startDate.timeIntervalSince1970 * 1000).rounded()
        e["micOk"] = recorder?.micAvailable ?? true
        e["titulo"] = rascunho
        return e
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let b = message.body as? [String: Any], let cmd = b["cmd"] as? String else { return }
        let n = (b["n"] as? NSNumber)?.intValue ?? 0
        let id = (b["id"] as? String) ?? ""
        let texto = (b["texto"] as? String) ?? ""
        let titulo = ((b["titulo"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let vazio = [String: Any]()

        switch cmd {
        case "listar":
            responder(n, listarReunioes())
        case "abrir":
            responder(n, abrirReuniao(id) ?? vazio)
        case "estado":
            responder(n, estadoAtual())
        case "gravar":
            iniciarGravacao { erro in
                var r = [String: Any]()
                if let e = erro { r["erro"] = e }
                self.responder(n, r)
            }
        case "parar":
            pararGravacao(titulo: titulo) { novo in
                var r = [String: Any]()
                if let i = novo {
                    r["id"] = i
                    r["agenda"] = lerMeta(i)?["agenda"] != nil
                }
                self.responder(n, r)
            }
        case "rascunho":
            rascunho = titulo
            responder(n, vazio)
        case "renomear":
            if !titulo.isEmpty {
                atualizarMeta(id) { m in
                    m["titulo"] = titulo
                    m["tituloAutomatico"] = false
                }
            }
            responder(n, vazio)
        case "apagar":
            if let dir = pastaReuniao(id), let m = lerMeta(id) {
                if let t = m["trabalho"] as? String, !t.isEmpty, !t.contains("/") {
                    try? FileManager.default.removeItem(at: tmpDir.appendingPathComponent(t))
                }
                try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
            }
            responder(n, vazio)
        case "pasta":
            if let dir = pastaReuniao(id), lerMeta(id) != nil {
                NSWorkspace.shared.open(dir)
            } else {
                NSWorkspace.shared.open(reunioesDir)
            }
            responder(n, vazio)
        case "som":
            responder(n, comandoDeSom(b))
        case "arrastar":
            // A interface ocupa a janela inteira; ela avisa quando o clique foi na faixa de cima para a janela poder ser arrastada.
            if let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseDragged {
                window.performDrag(with: e)
            }
            responder(n, vazio)
        case "ampliar":
            window.zoom(nil)
            responder(n, vazio)
        case "copiar":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texto, forType: .string)
            responder(n, vazio)
        case "retranscrever":
            if let m = lerMeta(id), let t = m["trabalho"] as? String, !t.isEmpty, !t.contains("/") {
                atualizarMeta(id) { m in
                    m["status"] = "transcrevendo"
                    m.removeValue(forKey: "erro")
                }
                enfileirar(id, tmpDir.appendingPathComponent(t))
            }
            responder(n, vazio)
        case "config":
            responder(n, configParaInterface())
        case "definir":
            let chave = (b["chave"] as? String) ?? ""
            let permitidas = ["nome", "login", "agenda.auto", "agenda.ligar", "avisos.mac", "avisos.opcoes", "avisos.antes"]
            if permitidas.contains(chave), let valor = b["valor"] {
                cfgDefinir(chave, valor)
                if chave == "login" { definirLogin(cfgBool("login")) }
                if chave.hasPrefix("agenda") || chave == "avisos.mac" {
                    if (cfgBool("agenda.auto") || cfgBool("avisos.mac")) && !Agenda.shared.negado {
                        Agenda.shared.pedirAcesso { ok in
                            if ok { registrarAntigas() }
                            self.emitir(["tipo": "config"])
                        }
                    }
                }
            }
            responder(n, vazio)
        case "pedirAgenda":
            if Agenda.shared.negado {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(u)
                }
                responder(n, vazio)
            } else {
                Agenda.shared.pedirAcesso { ok in
                    if ok { registrarAntigas() }
                    var r = [String: Any]()
                    r["ok"] = ok
                    self.responder(n, r)
                    self.emitir(["tipo": "config"])
                }
            }
        case "agenda":
            responder(n, agendaDoDia())
        case "abrirAgenda":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            responder(n, vazio)
        case "salvarResumo":
            if let dir = pastaReuniao(id), lerMeta(id) != nil,
               !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? texto.write(to: dir.appendingPathComponent("minuta.md"), atomically: true, encoding: .utf8)
            }
            responder(n, vazio)
        case "aprenderNome":
            aprenderNome((b["nome"] as? String) ?? "")
            responder(n, vazio)
        case "claude":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(texto, forType: .string)
            var c = URLComponents()
            c.scheme = "claude"
            c.host = "claude.ai"
            c.path = "/new"
            c.queryItems = [URLQueryItem(name: "q", value: texto)]
            var r = [String: Any]()
            r["ok"] = false
            if let u = c.url, NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
                NSWorkspace.shared.open(u)
                r["ok"] = true
            }
            responder(n, r)
        case "escolherPasta":
            escolherPasta(levar: (b["levar"] as? NSNumber)?.boolValue ?? true) { r in self.responder(n, r) }
        default:
            responder(n, vazio)
        }
    }

    // MARK: ajustes, pasta, agenda e avisos

    func configParaInterface() -> [String: Any] {
        var c = cfg()
        c["pastaCaminho"] = caminhoAmigavel(reunioesDir.path)
        c["pastaReal"] = reunioesDir.path
        c["pastaOk"] = pastaDisponivel()
        var cl = [String: Any]()
        cl["app"] = claudeInstalado()
        cl["pasta"] = FileManager.default.fileExists(atPath: reunioesDir.appendingPathComponent("_claude/COMO FAZER O RESUMO.md").path)
        var temResumo = false
        for i in idsDasReunioes() {
            if let d = pastaReuniao(i), lerMinuta(d) != nil {
                temResumo = true
                break
            }
        }
        cl["skill"] = temResumo
        c["claude"] = cl
        var pm = [String: Any]()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        pm["mic"] = mic == .authorized || mic == .notDetermined
        pm["sistema"] = CGPreflightScreenCaptureAccess()
        c["perm"] = pm
        c["agendaOk"] = Agenda.shared.permitido
        c["agendaConta"] = Agenda.shared.nomeDaConta()
        return c
    }

    func escolherPasta(levar: Bool, _ fim: @escaping ([String: Any]) -> Void) {
        var r = [String: Any]()
        if recorder != nil || iniciando || pendentes > 0 {
            r["erro"] = "Termine a gravação e a transcrição antes de trocar a pasta."
            fim(r)
            return
        }
        let painel = NSOpenPanel()
        painel.canChooseDirectories = true
        painel.canChooseFiles = false
        painel.canCreateDirectories = true
        painel.allowsMultipleSelection = false
        painel.prompt = "Usar esta pasta"
        painel.message = "Escolha onde o Goat Meet guarda as gravações."
        if pastaDisponivel() { painel.directoryURL = reunioesDir }
        NSApp.activate(ignoringOtherApps: true)
        guard painel.runModal() == .OK, let nova = painel.url else {
            fim(r)
            return
        }
        let antiga = reunioesDir
        if nova.standardizedFileURL.path != antiga.standardizedFileURL.path {
            cfgDefinir("pasta", nova.path)
            prepararPasta()
            if levar { moverReunioes(de: antiga, para: nova) }
        }
        r["caminho"] = caminhoAmigavel(nova.path)
        fim(r)
        emitir(["tipo": "mudou"])
    }

    // MARK: tocar o áudio de uma reunião (pelo Mac, para funcionar com a pasta em qualquer disco)

    func avisarSom(fim: Bool = false) {
        var e = [String: Any]()
        e["tipo"] = "som"
        e["t"] = tocador?.currentTime ?? 0
        e["dur"] = tocador?.duration ?? 0
        e["tocando"] = tocador?.isPlaying ?? false
        e["fim"] = fim
        emitir(e)
    }

    func pararRelogioDoSom() {
        tocadorTimer?.invalidate()
        tocadorTimer = nil
    }

    func comandoDeSom(_ b: [String: Any]) -> [String: Any] {
        var r = [String: Any]()
        let acao = (b["acao"] as? String) ?? ""
        switch acao {
        case "carregar":
            pararRelogioDoSom()
            tocador?.stop()
            tocador = nil
            tocadorAtivo = false
            r["ok"] = false
            guard let dir = pastaReuniao((b["id"] as? String) ?? "") else { return r }
            for nome in ["audio.m4a", "audio.wav"] {
                let u = dir.appendingPathComponent(nome)
                if !FileManager.default.fileExists(atPath: u.path) { continue }
                do {
                    let p = try AVAudioPlayer(contentsOf: u)
                    p.enableRate = true
                    p.prepareToPlay()
                    tocador = p
                    r["ok"] = true
                    r["dur"] = p.duration
                } catch {
                    gmLog("Áudio: não consegui abrir \(u.path): \(error)")
                }
                break
            }
        case "tocar":
            guard let p = tocador else { return r }
            p.rate = Float(numero(b["v"]) > 0 ? numero(b["v"]) : 1)
            p.play()
            tocadorAtivo = true
            pararRelogioDoSom()
            tocadorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                guard let p = self.tocador else { return }
                if p.isPlaying {
                    self.avisarSom()
                } else if self.tocadorAtivo {
                    // parou sozinho: chegou ao fim
                    self.tocadorAtivo = false
                    self.pararRelogioDoSom()
                    self.avisarSom(fim: true)
                }
            }
        case "pausar":
            tocadorAtivo = false
            tocador?.pause()
            pararRelogioDoSom()
        case "ir":
            if let p = tocador {
                p.currentTime = max(0, min(p.duration, numero(b["t"])))
            }
        case "velocidade":
            if let p = tocador, numero(b["v"]) > 0 { p.rate = Float(numero(b["v"])) }
        case "parar":
            tocadorAtivo = false
            pararRelogioDoSom()
            tocador?.stop()
            tocador = nil
        default:
            break
        }
        return r
    }

    func gravarPeloAviso(_ titulo: String) {
        if recorder != nil || iniciando { return }
        proximoTitulo = titulo
        iniciarGravacao { erro in
            if let e = erro, !e.isEmpty { self.alerta("Não deu pra gravar", e) }
        }
    }

    /// A cada 20 s: avisos de reunião. A cada minuto: agenda em dia e gravações que ficaram esperando a pasta.
    func rondar() {
        rodadas += 1
        verificarAvisos()
        if rodadas % 3 == 0 {
            sincronizarAgenda()
            if recorder == nil && !iniciando && pendentes == 0 && pastaDisponivel() { recuperarPendentes() }
        }
    }

    func verificarAvisos() {
        var proximo: EKEvent?
        if cfgBool("avisos.mac") && Agenda.shared.permitido {
            let agora = Date()
            let lista = (cfgValor("avisos.antes") as? [Any]) ?? [Any]()
            let antes = lista.compactMap { ($0 as? NSNumber)?.intValue }.filter { $0 > 0 && $0 <= 180 }
            let alcance = Double((antes.max() ?? 5) * 60)
            for e in Agenda.shared.eventos(de: agora.addingTimeInterval(-600), ate: agora.addingTimeInterval(alcance + 120)) {
                if Agenda.shared.doApp(e) { continue }
                let falta = e.startDate.timeIntervalSince(agora)
                if falta < -90 { continue }
                if proximo == nil && falta <= alcance { proximo = e }
                if recorder != nil || iniciando { continue }
                let nome = (e.title ?? "").isEmpty ? "Reunião" : (e.title ?? "")
                for m in antes + [0] {
                    let alvo = Double(m * 60)
                    if falta <= alvo && falta > alvo - 60 {
                        let chave = "\(e.eventIdentifier ?? "")|\(Int(e.startDate.timeIntervalSince1970))|\(m)"
                        if avisados.insert(chave).inserted {
                            Avisos.shared.mostrar(titulo: nome, inicio: e.startDate, minutos: m)
                        }
                    }
                }
            }
        }
        var ev = [String: Any]()
        ev["tipo"] = "prox"
        var chave = ""
        if let p = proximo {
            ev["titulo"] = (p.title ?? "").isEmpty ? "Reunião" : (p.title ?? "")
            ev["inicio"] = (p.startDate.timeIntervalSince1970 * 1000).rounded()
            chave = "\(p.eventIdentifier ?? "")|\(Int(p.startDate.timeIntervalSince1970))"
        }
        if chave != ultimoProx {
            ultimoProx = chave
            emitir(ev)
        }
    }

    /// Reuniões antigas ganham a onda do áudio para o player.
    func preencherOndas() {
        for id in idsDasReunioes() {
            guard let m = lerMeta(id), (m["status"] as? String) == "pronta", m["ondas"] == nil,
                  let dir = pastaReuniao(id) else { continue }
            let audio = dir.appendingPathComponent("audio.m4a")
            guard FileManager.default.fileExists(atPath: audio.path), let s = try? loadMono16k(audio) else { continue }
            let o = ondasDe(s)
            if o.isEmpty { continue }
            atualizarMeta(id) { $0["ondas"] = o }
        }
    }

    // MARK: barra de menu

    func atualizarBarra() {
        guard let b = statusItem.button else { return }
        if recorder != nil {
            b.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Gravando")
            let s = Int(Date().timeIntervalSince(startDate))
            if s >= 3600 {
                b.title = String(format: " %d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            } else {
                b.title = String(format: " %02d:%02d", s / 60, s % 60)
            }
            toggleItem.title = "Parar e transcrever"
        } else if pendentes > 0 {
            b.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Transcrevendo")
            b.title = " transcrevendo…"
            toggleItem.title = "Iniciar gravação"
        } else {
            b.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Goat Meet")
            b.title = ""
            toggleItem.title = "Iniciar gravação"
        }
        toggleItem.isEnabled = !iniciando
    }

    @objc func alternarPelaBarra() {
        if recorder != nil {
            pararGravacao(titulo: "") { _ in
                self.emitir(["tipo": "mudou"])
                self.mostrarJanela()
            }
        } else {
            iniciarGravacao { erro in
                if let e = erro, !e.isEmpty { self.alerta("Não deu pra gravar", e) }
            }
        }
    }

    @objc func abrirPelaBarra() {
        mostrarJanela()
    }

    @objc func sair() {
        NSApp.terminate(nil)
    }

    // MARK: gravação

    func tique() {
        guard let r = recorder else { return }
        tiques += 1
        if tiques % 10 == 0 { atualizarBarra() }
        if window.isVisible {
            var e = [String: Any]()
            e["tipo"] = "niveis"
            e["eu"] = Double(min(1, r.nivelEu().squareRoot() * 1.15))
            e["outros"] = Double(min(1, r.nivelOutros().squareRoot() * 1.15))
            emitir(e)
        }
    }

    /// `fim(nil)` = começou; `fim("")` = não começou e o aviso já foi mostrado; `fim(texto)` = erro.
    func iniciarGravacao(_ fim: @escaping (String?) -> Void) {
        if recorder != nil || iniciando {
            fim("Já existe uma gravação em andamento.")
            return
        }
        let dir = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fim(error.localizedDescription)
            return
        }
        iniciando = true
        tocadorAtivo = false
        pararRelogioDoSom()
        tocador?.pause()
        atualizarBarra()
        let r = Recorder()
        Task { @MainActor in
            do {
                try await r.start(in: dir)
                self.recorder = r
                self.workDir = dir
                self.startDate = Date()
                self.rascunho = self.proximoTitulo
                self.proximoTitulo = ""
                self.tiques = 0
                self.iniciando = false
                self.atividade = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled], reason: "Gravando reunião")
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.tique() }
                self.atualizarBarra()
                self.emitir(self.estadoAtual())
                fim(nil)
            } catch {
                await r.stop()
                try? FileManager.default.removeItem(at: dir)
                self.iniciando = false
                self.atualizarBarra()
                if let g = error as? GMError, g.permissao {
                    fim("")
                    self.alertaPermissao()
                } else {
                    fim(error.localizedDescription)
                }
            }
        }
    }

    func pararGravacao(titulo: String, _ fim: @escaping (String?) -> Void) {
        guard let r = recorder, let dir = workDir else {
            fim(nil)
            return
        }
        recorder = nil
        workDir = nil
        timer?.invalidate()
        timer = nil
        if let a = atividade { ProcessInfo.processInfo.endActivity(a) }
        atividade = nil
        let inicio = startDate
        let nome = titulo.isEmpty ? rascunho : titulo
        rascunho = ""
        atualizarBarra()
        Task { @MainActor in
            await r.stop()
            if !pastaDisponivel() { prepararPasta() }
            if !pastaDisponivel() {
                // A pasta está em um disco que não está conectado: o áudio fica guardado e entra na lista quando ela voltar.
                let marcador = "\(formatted(inicio, "yyyy-MM-dd HH'h'mm")) - \(nome.isEmpty ? "Reunião" : nome)"
                try? marcador.write(to: dir.appendingPathComponent("nome.txt"), atomically: true, encoding: .utf8)
                self.emitir(self.estadoAtual())
                self.emitir(["tipo": "aviso", "texto": "A pasta das gravações não está disponível. A gravação ficou guardada."])
                fim(nil)
                return
            }
            let id = criarReuniao(titulo: nome, inicio: inicio,
                                  duracao: Date().timeIntervalSince(inicio), trabalho: dir.lastPathComponent)
            registrarNaAgenda(id)
            self.emitir(self.estadoAtual())
            fim(id)
            self.enfileirar(id, dir)
        }
    }

    // MARK: fila de transcrição

    func enfileirar(_ id: String, _ trabalho: URL) {
        if emFila.contains(id) { return }
        emFila.insert(id)
        pendentes += 1
        atualizarBarra()
        fila.async {
            do {
                try processar(id: id, trabalho: trabalho)
                gmLog("Pronta: \(id)")
            } catch {
                gmLog("Falhou \(id): \(error)")
                let texto = error.localizedDescription
                atualizarMeta(id) { m in
                    m["status"] = "erro"
                    m["erro"] = texto
                }
            }
            DispatchQueue.main.async {
                self.pendentes = max(0, self.pendentes - 1)
                self.emFila.remove(id)
                self.atualizarBarra()
                sincronizarAgenda()
                self.emitir(["tipo": "mudou"])
                NSSound(named: "Glass")?.play()
            }
        }
    }

    /// Ao abrir: retoma transcrições interrompidas e recupera gravações que ficaram sem reunião
    /// (app fechado no meio, ou gravações feitas na versão 1).
    func recuperarPendentes() {
        guard pastaDisponivel() else { return }
        let fm = FileManager.default
        var donos = [String: String]()
        for id in idsDasReunioes() {
            if let m = lerMeta(id), let t = m["trabalho"] as? String, !t.isEmpty { donos[t] = id }
        }
        let nomes = (try? fm.contentsOfDirectory(atPath: tmpDir.path)) ?? []
        for nome in nomes {
            if nome.hasPrefix(".") { continue }
            let dir = tmpDir.appendingPathComponent(nome, isDirectory: true)
            let temAudio = fm.fileExists(atPath: dir.appendingPathComponent("sistema.caf").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("microfone.caf").path)
            if !temAudio {
                let dentro = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]
                if dentro.isEmpty { try? fm.removeItem(at: dir) }
                continue
            }
            if let id = donos[nome] {
                let status = lerMeta(id).flatMap { $0["status"] as? String } ?? ""
                if status == "transcrevendo" { enfileirar(id, dir) }
                continue
            }
            var titulo = ""
            var inicio = Date()
            if let attrs = try? fm.attributesOfItem(atPath: dir.path), let c = attrs[.creationDate] as? Date {
                inicio = c
            }
            if let antigo = try? String(contentsOf: dir.appendingPathComponent("nome.txt"), encoding: .utf8) {
                // Versão 1: "2026-11-27 10h40 - Título", com arquivos soltos em Reunioes/ e Audios/.
                let partes = antigo.components(separatedBy: " - ")
                let f = DateFormatter()
                f.locale = Locale(identifier: "pt_BR")
                f.dateFormat = "yyyy-MM-dd HH'h'mm"
                if let d = f.date(from: partes[0]) { inicio = d }
                if partes.count > 1 { titulo = partes.dropFirst().joined(separator: " - ") }
                if titulo == "Reunião" { titulo = "" }
                try? fm.trashItem(at: reunioesDir.appendingPathComponent(antigo + ".md"), resultingItemURL: nil)
                try? fm.trashItem(at: baseDir.appendingPathComponent("Audios/" + antigo + ".wav"), resultingItemURL: nil)
            }
            let id = criarReuniao(titulo: titulo, inicio: inicio, duracao: 0, trabalho: nome)
            enfileirar(id, dir)
        }
        let audios = baseDir.appendingPathComponent("Audios")
        let dentro = (try? fm.contentsOfDirectory(atPath: audios.path)) ?? ["?"]
        if dentro.isEmpty { try? fm.removeItem(at: audios) }
    }
}

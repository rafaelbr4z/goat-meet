// Goat Meet 3: ajustes, pasta das gravações, agenda (EventKit), avisos na tela e abrir junto com o Mac.

import AppKit
import AVFoundation
import EventKit

// MARK: - Ajustes (config.json)

let configURL = appDir.appendingPathComponent("config.json")
let pastaPadrao = baseDir.appendingPathComponent("Reunioes", isDirectory: true)
/// O guia que o Claude segue vem de dentro do app; na montagem local, da pasta `_app`.
let guiaURL: URL = {
    if let r = Bundle.main.resourceURL {
        let doApp = r.appendingPathComponent("guia.md")
        if FileManager.default.fileExists(atPath: doApp.path) { return doApp }
    }
    return appDir.appendingPathComponent("COMO O CLAUDE FAZ O RESUMO.md")
}()
let agenteURL = home.appendingPathComponent("Library/LaunchAgents/com.braz.goatmeet.plist")
let configLock = NSLock()
var configCache: [String: Any] = lerConfigDoDisco()

func configPadrao() -> [String: Any] {
    var c = [String: Any]()
    c["nome"] = ""
    c["pasta"] = pastaPadrao.path
    c["login"] = false
    c["agenda"] = ["auto": true, "ligar": true]
    c["avisos"] = ["mac": true, "opcoes": [30, 15, 5], "antes": [30, 15, 5]]
    return c
}

func lerConfigDoDisco() -> [String: Any] {
    var c = configPadrao()
    guard let d = try? Data(contentsOf: configURL),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return c }
    for (k, v) in o {
        if let sub = v as? [String: Any], var base = c[k] as? [String: Any] {
            for (k2, v2) in sub { base[k2] = v2 }
            c[k] = base
        } else {
            c[k] = v
        }
    }
    return c
}

func cfg() -> [String: Any] {
    configLock.lock(); defer { configLock.unlock() }
    return configCache
}

func cfgValor(_ caminho: String) -> Any? {
    var atual: Any? = cfg()
    for p in caminho.split(separator: ".") {
        atual = (atual as? [String: Any])?[String(p)]
    }
    return atual
}

func cfgBool(_ caminho: String) -> Bool {
    (cfgValor(caminho) as? NSNumber)?.boolValue ?? false
}

func cfgDefinir(_ caminho: String, _ valor: Any) {
    configLock.lock()
    let partes = caminho.split(separator: ".").map { String($0) }
    if partes.count == 1 {
        configCache[partes[0]] = valor
    } else if partes.count == 2 {
        var sub = (configCache[partes[0]] as? [String: Any]) ?? [String: Any]()
        sub[partes[1]] = valor
        configCache[partes[0]] = sub
    }
    let copia = configCache
    configLock.unlock()
    if let d = try? JSONSerialization.data(withJSONObject: copia, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: configURL, options: .atomic)
    }
}

/// Pasta onde ficam as reuniões. Vem dos ajustes; pode estar em outro disco.
var reunioesDir: URL {
    let p = (cfgValor("pasta") as? String) ?? ""
    if p.isEmpty { return pastaPadrao }
    return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
}

func pastaDisponivel() -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: reunioesDir.path, isDirectory: &isDir) && isDir.boolValue
}

func caminhoAmigavel(_ p: String) -> String {
    let h = home.path
    return p.hasPrefix(h) ? "~" + String(p.dropFirst(h.count)) : p
}

/// Cria a pasta das gravações (se der) e deixa dentro dela o guia que o Claude segue.
func prepararPasta() {
    let fm = FileManager.default
    try? fm.createDirectory(at: reunioesDir, withIntermediateDirectories: true)
    guard pastaDisponivel() else { return }
    let dest = reunioesDir.appendingPathComponent("_claude", isDirectory: true)
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
    if let d = try? Data(contentsOf: guiaURL) {
        try? d.write(to: dest.appendingPathComponent("COMO FAZER O RESUMO.md"), options: .atomic)
    }
    let nomes = dest.appendingPathComponent("nomes.txt")
    if !fm.fileExists(atPath: nomes.path) {
        try? "# Nomes confirmados pelo Claude, um por linha. O Goat Meet usa na transcrição.\n"
            .write(to: nomes, atomically: true, encoding: .utf8)
    }
}

/// Termos para a transcrição: a lista do app mais os nomes que o Claude confirmou.
func termosConhecidos() -> [String] {
    var vistos = Set<String>()
    var out: [String] = []
    let fontes = [vocabularioURL, reunioesDir.appendingPathComponent("_claude/nomes.txt")]
    for u in fontes {
        guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
        for linha in t.components(separatedBy: "\n") {
            let s = linha.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            if vistos.insert(s.lowercased()).inserted { out.append(s) }
        }
    }
    return out
}

func aprenderNome(_ nome: String) {
    let n = nome.trimmingCharacters(in: .whitespacesAndNewlines)
    if n.isEmpty || n.count > 80 || n.contains("\n") { return }
    if termosConhecidos().contains(where: { $0.lowercased() == n.lowercased() }) { return }
    var atual = (try? String(contentsOf: vocabularioURL, encoding: .utf8)) ?? ""
    if !atual.isEmpty && !atual.hasSuffix("\n") { atual += "\n" }
    atual += n + "\n"
    try? atual.write(to: vocabularioURL, atomically: true, encoding: .utf8)
}

/// Copia cada reunião para a pasta nova e só então manda a antiga para o Lixo.
func moverReunioes(de antiga: URL, para nova: URL) {
    let fm = FileManager.default
    let nomes = (try? fm.contentsOfDirectory(atPath: antiga.path)) ?? []
    for nome in nomes {
        if nome.hasPrefix(".") || nome.hasPrefix("_") { continue }
        let origem = antiga.appendingPathComponent(nome, isDirectory: true)
        if !fm.fileExists(atPath: origem.appendingPathComponent("reuniao.json").path) { continue }
        let destino = nova.appendingPathComponent(nome, isDirectory: true)
        if fm.fileExists(atPath: destino.path) { continue }
        do {
            try fm.copyItem(at: origem, to: destino)
            if fm.fileExists(atPath: destino.appendingPathComponent("reuniao.json").path) {
                try? fm.trashItem(at: origem, resultingItemURL: nil)
            }
        } catch {
            gmLog("Não consegui levar \(nome): \(error)")
        }
    }
}

func definirLogin(_ ligado: Bool) {
    let fm = FileManager.default
    if !ligado {
        try? fm.removeItem(at: agenteURL)
        return
    }
    var d = [String: Any]()
    d["Label"] = "com.braz.goatmeet"
    d["ProgramArguments"] = ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--oculto"]
    d["RunAtLoad"] = true
    try? fm.createDirectory(at: agenteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0) {
        try? data.write(to: agenteURL, options: .atomic)
    }
}

func claudeInstalado() -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: "/Applications/Claude.app")
        || fm.fileExists(atPath: home.appendingPathComponent("Applications/Claude.app").path)
}

/// 96 picos de 0 a 1 para desenhar a onda do áudio.
func ondasDe(_ s: [Float], n: Int = 96) -> [Double] {
    if s.isEmpty { return [] }
    var picos = [Float](repeating: 0, count: n)
    let passo = max(1, s.count / n)
    for i in 0..<n {
        let a = i * passo
        if a >= s.count { break }
        let b = min(s.count, a + passo)
        var m: Float = 0
        var j = a
        while j < b {
            let v = abs(s[j])
            if v > m { m = v }
            j += 16
        }
        picos[i] = m
    }
    let maior = picos.max() ?? 0
    if maior <= 0 { return [] }
    return picos.map { Double((($0 / maior).squareRoot() * 100).rounded() / 100) }
}

// MARK: - Agenda do Mac (EventKit). O Mac sincroniza com o Google.

final class Agenda {
    static let shared = Agenda()
    let store = EKEventStore()
    let marca = "Gravada no Goat Meet"

    var permitido: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return s == .fullAccess }
        return s == .authorized
    }

    var negado: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    func pedirAcesso(_ fim: @escaping (Bool) -> Void) {
        if permitido {
            fim(true)
            return
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { ok, _ in DispatchQueue.main.async { fim(ok) } }
        } else {
            store.requestAccess(to: .event) { ok, _ in DispatchQueue.main.async { fim(ok) } }
        }
    }

    func ehGoogle(_ c: EKCalendar) -> Bool {
        let t = (c.source?.title ?? "").lowercased()
        return t.contains("google") || t.contains("gmail")
    }

    /// Onde as gravações são registradas: de preferência a conta Google do Mac.
    func calendarioDeGravacao() -> EKCalendar? {
        let todos = store.calendars(for: .event).filter { $0.allowsContentModifications }
        let google = todos.filter { ehGoogle($0) }
        if let padrao = store.defaultCalendarForNewEvents,
           google.contains(where: { $0.calendarIdentifier == padrao.calendarIdentifier }) {
            return padrao
        }
        if let principal = google.first(where: { $0.title.contains("@") }) { return principal }
        if let g = google.first { return g }
        if let padrao = store.defaultCalendarForNewEvents { return padrao }
        return todos.first
    }

    func nomeDaConta() -> String {
        guard permitido, let c = calendarioDeGravacao() else { return "" }
        if ehGoogle(c) { return "Google Agenda" }
        let t = c.source?.title ?? ""
        if t.lowercased().contains("icloud") { return "iCloud" }
        return t.isEmpty ? "Agenda do Mac" : t
    }

    func eventos(de: Date, ate: Date) -> [EKEvent] {
        guard permitido else { return [] }
        let p = store.predicateForEvents(withStart: de, end: ate, calendars: nil)
        return store.events(matching: p).filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
    }

    func doApp(_ e: EKEvent) -> Bool {
        (e.notes ?? "").contains(marca)
    }

    /// Evento da agenda que estava acontecendo (ou começando) quando a gravação começou.
    func eventoNoHorario(_ inicio: Date) -> EKEvent? {
        let cand = eventos(de: inicio.addingTimeInterval(-4 * 3600), ate: inicio.addingTimeInterval(3600))
        let servem = cand.filter { e in
            !doApp(e) && e.startDate <= inicio.addingTimeInterval(600) && e.endDate >= inicio.addingTimeInterval(60)
        }
        return servem.min { abs($0.startDate.timeIntervalSince(inicio)) < abs($1.startDate.timeIntervalSince(inicio)) }
    }

    func notas(_ inicio: Date, _ fim: Date, _ resumo: String) -> String {
        let min = max(1, Int((fim.timeIntervalSince(inicio) / 60).rounded()))
        var t = "\(marca) · gravação de \(min) min iniciada às \(formatted(inicio, "HH:mm"))."
        if !resumo.isEmpty { t += "\n\n" + resumo }
        return t
    }

    func registrar(titulo: String, inicio: Date, fim: Date) -> String? {
        guard permitido, let cal = calendarioDeGravacao() else { return nil }
        let e = EKEvent(eventStore: store)
        e.title = titulo
        e.startDate = inicio
        e.endDate = max(fim, inicio.addingTimeInterval(60))
        e.calendar = cal
        e.notes = notas(inicio, fim, "")
        do {
            try store.save(e, span: .thisEvent, commit: true)
            return e.eventIdentifier
        } catch {
            gmLog("Agenda: não consegui registrar: \(error)")
            return nil
        }
    }

    func atualizar(id: String, titulo: String, inicio: Date, fim: Date, resumo: String) {
        guard permitido, let e = store.event(withIdentifier: id), doApp(e) else { return }
        let n = notas(inicio, fim, resumo)
        let fimCerto = max(fim, inicio.addingTimeInterval(60))
        var mudou = false
        if (e.title ?? "") != titulo { e.title = titulo; mudou = true }
        if (e.notes ?? "") != n { e.notes = n; mudou = true }
        if abs(e.endDate.timeIntervalSince(fimCerto)) > 30 { e.endDate = fimCerto; mudou = true }
        if mudou {
            do { try store.save(e, span: .thisEvent, commit: true) } catch { gmLog("Agenda: não consegui atualizar: \(error)") }
        }
    }
}

func dataISO(_ s: Any?) -> Date? {
    guard let t = s as? String, !t.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: t)
}

/// Liga a reunião a um evento que já existe no horário ou cria um evento novo. Devolve true se entrou na agenda.
@discardableResult
func registrarNaAgenda(_ id: String) -> Bool {
    guard cfgBool("agenda.auto"), Agenda.shared.permitido, let m = lerMeta(id) else { return false }
    if m["agenda"] != nil { return true }
    guard let inicio = dataISO(m["inicio"]) else { return false }
    let fim = inicio.addingTimeInterval(max(60, numero(m["duracaoSeg"])))
    var info = [String: Any]()
    if cfgBool("agenda.ligar"), let e = Agenda.shared.eventoNoHorario(inicio) {
        let nome = e.title ?? ""
        info["tipo"] = "evento"
        info["titulo"] = nome
        info["eventoId"] = e.eventIdentifier ?? ""
        atualizarMeta(id) { m in
            m["agenda"] = info
            if (m["tituloAutomatico"] as? Bool) == true, !nome.isEmpty {
                m["titulo"] = nome
                m["tituloAutomatico"] = false
            }
        }
        return true
    }
    let titulo = (m["titulo"] as? String) ?? "Reunião"
    if let eid = Agenda.shared.registrar(titulo: titulo, inicio: inicio, fim: fim) {
        info["tipo"] = "criado"
        info["eventoId"] = eid
        atualizarMeta(id) { $0["agenda"] = info }
        return true
    }
    return false
}

/// Mantém os eventos criados pelo app em dia: título, fim real e resumo.
func sincronizarAgenda() {
    guard Agenda.shared.permitido else { return }
    let limite = Date().addingTimeInterval(-14 * 86400)
    for id in idsDasReunioes() {
        guard let m = lerMeta(id), let ag = m["agenda"] as? [String: Any],
              (ag["tipo"] as? String) == "criado", let eid = ag["eventoId"] as? String, !eid.isEmpty,
              let inicio = dataISO(m["inicio"]), inicio > limite,
              let dir = pastaReuniao(id) else { continue }
        let fim = inicio.addingTimeInterval(max(60, numero(m["duracaoSeg"])))
        let minuta = lerMinuta(dir) ?? ""
        Agenda.shared.atualizar(id: eid, titulo: (m["titulo"] as? String) ?? "Reunião",
                                inicio: inicio, fim: fim, resumo: resumoDaMinuta(minuta))
    }
}

/// Reuniões gravadas antes de a agenda existir no app também entram nela.
func registrarAntigas() {
    guard cfgBool("agenda.auto"), Agenda.shared.permitido else { return }
    for id in idsDasReunioes() {
        guard let m = lerMeta(id), m["agenda"] == nil, (m["status"] as? String) == "pronta" else { continue }
        if ((m["titulo"] as? String) ?? "").hasPrefix("Teste do Goat Meet") { continue }
        registrarNaAgenda(id)
    }
}

/// Eventos de hoje e de amanhã para o painel "Hoje", já casados com as gravações.
func agendaDoDia() -> [[String: Any]] {
    let cal = Calendar.current
    let hoje = cal.startOfDay(for: Date())
    guard let amanha = cal.date(byAdding: .day, value: 1, to: hoje),
          let depois = cal.date(byAdding: .day, value: 2, to: hoje) else { return [] }
    let iso = ISO8601DateFormatter()

    var porEvento = [String: [String: Any]]()
    var soltas: [[String: Any]] = []
    for id in idsDasReunioes() {
        guard let m = lerMeta(id), let ini = dataISO(m["inicio"]), ini >= hoje, ini < amanha else { continue }
        let ag = m["agenda"] as? [String: Any]
        var r = [String: Any]()
        r["reuniaoId"] = id
        r["criadoPeloApp"] = ((ag?["tipo"] as? String) ?? "criado") == "criado"
        r["titulo"] = (m["titulo"] as? String) ?? id
        r["inicio"] = iso.string(from: ini)
        r["fim"] = iso.string(from: ini.addingTimeInterval(max(60, numero(m["duracaoSeg"]))))
        if let eid = ag?["eventoId"] as? String, !eid.isEmpty {
            porEvento[eid] = r
        } else {
            soltas.append(r)
        }
    }

    var out: [[String: Any]] = []
    var usados = Set<String>()
    for e in Agenda.shared.eventos(de: hoje, ate: depois) {
        var o = [String: Any]()
        o["titulo"] = (e.title ?? "").isEmpty ? "Sem título" : (e.title ?? "")
        o["inicio"] = iso.string(from: e.startDate)
        o["fim"] = iso.string(from: e.endDate)
        o["amanha"] = e.startDate >= amanha
        if let eid = e.eventIdentifier, let r = porEvento[eid] {
            usados.insert(eid)
            for chave in ["reuniaoId", "criadoPeloApp", "inicio", "fim"] {
                if let valor = r[chave] { o[chave] = valor }
            }
        }
        out.append(o)
    }
    for (eid, r) in porEvento where !usados.contains(eid) { soltas.append(r) }
    for var r in soltas {
        r["amanha"] = false
        out.append(r)
    }
    return out
}

// MARK: - Aviso na tela do Mac (cartão do próprio app, para controlar quanto tempo fica)

final class AvisoPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AvisoView: NSView {
    var aoClicar: (() -> Void)?
    override func mouseDown(with event: NSEvent) { aoClicar?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Avisos: NSObject {
    static let shared = Avisos()
    var painel: NSPanel?
    var fechaTimer: Timer?
    var tituloAtual = ""
    var aoGravar: ((String) -> Void)?

    func botao(_ titulo: String, tamanho: CGFloat, peso: NSFont.Weight, cor: NSColor, acao: Selector) -> NSButton {
        let b = NSButton(title: titulo, target: self, action: acao)
        b.isBordered = false
        b.wantsLayer = true
        b.focusRingType = .none
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        b.attributedTitle = NSAttributedString(string: titulo, attributes: [
            .font: NSFont.systemFont(ofSize: tamanho, weight: peso),
            .foregroundColor: cor,
            .paragraphStyle: p
        ])
        return b
    }

    /// minutos > 0: aviso antecipado, some sozinho em 30 s. minutos == 0: é a hora, fica até clicar.
    func mostrar(titulo: String, inicio: Date, minutos: Int) {
        fechar(animado: false)
        guard let tela = NSScreen.main else { return }
        tituloAtual = titulo
        let largura: CGFloat = 440
        let altura: CGFloat = 78
        let area = tela.visibleFrame
        let destino = NSRect(x: area.maxX - largura - 16, y: area.maxY - altura - 16, width: largura, height: altura)

        let p = AvisoPanel(contentRect: destino, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        let v = AvisoView(frame: NSRect(x: 0, y: 0, width: largura, height: altura))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(red: 0.039, green: 0.039, blue: 0.039, alpha: 1).cgColor
        v.layer?.cornerRadius = 24
        v.layer?.masksToBounds = true
        v.aoClicar = { [weak self] in self?.fechar(animado: true) }

        let ponto = NSView(frame: NSRect(x: 26, y: 50, width: 6, height: 6))
        ponto.wantsLayer = true
        ponto.layer?.backgroundColor = NSColor(red: 1, green: 0.29, blue: 0.17, alpha: 1).cgColor
        ponto.layer?.cornerRadius = 3
        v.addSubview(ponto)

        let l1 = NSTextField(labelWithString: minutos > 0 ? "Começa em \(minutos) min" : "Começando agora")
        l1.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        l1.textColor = NSColor(white: 0.55, alpha: 1)
        l1.frame = NSRect(x: 39, y: 45, width: 230, height: 16)
        v.addSubview(l1)

        let l2 = NSTextField(labelWithString: "\(titulo) · \(formatted(inicio, "HH:mm"))")
        l2.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        l2.textColor = .white
        l2.lineBreakMode = .byTruncatingTail
        l2.frame = NSRect(x: 26, y: 17, width: 248, height: 21)
        v.addSubview(l2)

        let gravar = botao("Gravar", tamanho: 14, peso: .medium, cor: NSColor(white: 0.04, alpha: 1), acao: #selector(clicouGravar))
        gravar.frame = NSRect(x: largura - 14 - 34 - 10 - 92, y: 18, width: 92, height: 42)
        gravar.layer?.backgroundColor = NSColor.white.cgColor
        gravar.layer?.cornerRadius = 21
        v.addSubview(gravar)

        let x = botao("×", tamanho: 19, peso: .regular, cor: NSColor(white: 0.55, alpha: 1), acao: #selector(clicouFechar))
        x.frame = NSRect(x: largura - 14 - 34, y: 22, width: 34, height: 34)
        v.addSubview(x)

        p.contentView = v
        p.alphaValue = 0
        p.setFrame(destino.offsetBy(dx: 24, dy: 0), display: false)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
            p.animator().setFrame(destino, display: true)
        }
        painel = p
        if minutos > 0 {
            fechaTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                self?.fechar(animado: true)
            }
        }
    }

    func fechar(animado: Bool) {
        fechaTimer?.invalidate()
        fechaTimer = nil
        guard let p = painel else { return }
        painel = nil
        if !animado {
            p.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: 24, dy: 0), display: true)
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    @objc func clicouGravar() {
        let t = tituloAtual
        fechar(animado: true)
        aoGravar?(t)
    }

    @objc func clicouFechar() {
        fechar(animado: true)
    }
}

// MARK: - Projetos (grupos de reuniões)

/// Os projetos ficam em `_claude/projetos.json`, dentro da pasta das gravações: [{id, nome, ficha}].
/// Cada reunião guarda o id do projeto dela no campo `projeto` do `reuniao.json`.
var projetosURL: URL { reunioesDir.appendingPathComponent("_claude/projetos.json") }

func lerProjetos() -> [[String: Any]] {
    guard let d = try? Data(contentsOf: projetosURL),
          let o = try? JSONSerialization.jsonObject(with: d),
          let a = o as? [[String: Any]] else { return [] }
    return a
}

func gravarProjetos(_ lista: [[String: Any]]) {
    let pasta = projetosURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
    guard let d = try? JSONSerialization.data(withJSONObject: lista, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? d.write(to: projetosURL, options: .atomic)
}

/// Só os projetos que têm pelo menos uma reunião.
func projetosParaInterface() -> [[String: Any]] {
    var usados = Set<String>()
    for id in idsDasReunioes() {
        if let m = lerMeta(id), let p = m["projeto"] as? String, !p.isEmpty { usados.insert(p) }
    }
    var out: [[String: Any]] = []
    for p in lerProjetos() {
        guard let pid = p["id"] as? String, usados.contains(pid) else { continue }
        var o = [String: Any]()
        o["id"] = pid
        o["nome"] = (p["nome"] as? String) ?? "Projeto"
        o["ficha"] = (p["ficha"] as? [String: Any]) ?? [String: Any]()
        out.append(o)
    }
    return out
}

/// Lê a seção "## Projeto" do resumo: linhas "- **Campo:** valor".
func fichaDaMinuta(_ texto: String) -> [String: String] {
    var f = [String: String]()
    var dentro = false
    for l in texto.components(separatedBy: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("## ") {
            let titulo = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
            dentro = titulo == "projeto"
            continue
        }
        if !dentro { continue }
        if !(t.hasPrefix("- **") || t.hasPrefix("* **")) { continue }
        let resto = String(t.dropFirst(4))
        guard let fim = resto.range(of: "**") else { continue }
        var chave = String(resto[..<fim.lowerBound]).trimmingCharacters(in: .whitespaces)
        var valor = String(resto[fim.upperBound...]).trimmingCharacters(in: .whitespaces)
        if chave.hasSuffix(":") { chave = String(chave.dropLast()).trimmingCharacters(in: .whitespaces) }
        if valor.hasPrefix(":") { valor = String(valor.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if !chave.isEmpty { f[chave] = valor }
    }
    return f
}

/// Conta as tarefas do resumo: [abertas, total].
func tarefasDaMinuta(_ texto: String) -> [Int] {
    var abertas = 0
    var total = 0
    for l in texto.components(separatedBy: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- [ ] ") || t.hasPrefix("* [ ] ") {
            abertas += 1
            total += 1
        } else if t.hasPrefix("- [x] ") || t.hasPrefix("- [X] ") || t.hasPrefix("* [x] ") || t.hasPrefix("* [X] ") {
            total += 1
        }
    }
    return [abertas, total]
}

/// Põe as reuniões em um projeto. Sem id de projeto existente, cria um novo com o nome dado.
/// A ficha do projeto recebe o que os resumos já trazem, sem apagar o que estava preenchido.
func agruparReunioes(_ ids: [String], projeto: String, nome: String) -> String {
    var lista = lerProjetos()
    var pid = projeto
    var indice = -1
    for (i, p) in lista.enumerated() {
        if let x = p["id"] as? String, x == pid, !pid.isEmpty { indice = i }
    }
    if indice < 0 {
        pid = "p" + String(Int(Date().timeIntervalSince1970))
        var novo = [String: Any]()
        novo["id"] = pid
        novo["nome"] = nome.isEmpty ? "Projeto" : nome
        novo["ficha"] = [String: Any]()
        lista.append(novo)
        indice = lista.count - 1
    }
    var ficha = (lista[indice]["ficha"] as? [String: Any]) ?? [String: Any]()
    let destino = pid
    for id in ids.sorted(by: >) {
        guard lerMeta(id) != nil, let dir = pastaReuniao(id) else { continue }
        atualizarMeta(id) { meta in
            meta["projeto"] = destino
        }
        guard let minuta = lerMinuta(dir) else { continue }
        for (campo, valor) in fichaDaMinuta(minuta) {
            if valor.isEmpty { continue }
            let atual = (ficha[campo] as? String) ?? ""
            if atual.isEmpty { ficha[campo] = valor }
        }
    }
    lista[indice]["ficha"] = ficha
    gravarProjetos(lista)
    return destino
}

func desagruparReunioes(_ ids: [String]) {
    for id in ids {
        atualizarMeta(id) { meta in
            _ = meta.removeValue(forKey: "projeto")
        }
    }
}

func salvarProjeto(_ id: String, nome: String, ficha: [String: Any]?) {
    var lista = lerProjetos()
    for i in lista.indices {
        guard let x = lista[i]["id"] as? String, x == id else { continue }
        if !nome.isEmpty { lista[i]["nome"] = nome }
        if let f = ficha { lista[i]["ficha"] = f }
    }
    gravarProjetos(lista)
}

/// Desfaz o projeto. As reuniões continuam guardadas, só deixam de estar agrupadas.
func apagarProjeto(_ id: String) {
    if id.isEmpty { return }
    for r in idsDasReunioes() {
        if let m = lerMeta(r), let p = m["projeto"] as? String, p == id {
            atualizarMeta(r) { meta in
                _ = meta.removeValue(forKey: "projeto")
            }
        }
    }
    let resto = lerProjetos().filter { p in
        let x = (p["id"] as? String) ?? ""
        return x != id
    }
    gravarProjetos(resto)
}

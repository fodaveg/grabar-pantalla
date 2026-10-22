// Icono de barra de menús para `grabar-pantalla`. No graba nada: lanza el script del repo
// (ruta en la clave GrabarPantallaScript del Info.plist) como hijo con GRABAR_PANTALLA_APP=1,
// lee su stdout y pinta el estado a partir de las líneas `@estado ...`. El resto de líneas
// (y todo su stderr) se reenvían tal cual a la salida de esta app.
// Argumentos: los del script. Sin argumentos (LaunchServices al abrirla desde Spotlight) se
// pasa «0» = grabar sin límite hasta Detener (el script pone un tope de 30 min).
// Sale con el código de salida del script.
import AppKit

// MARK: - Arranque

let script = Bundle.main.object(forInfoDictionaryKey: "GrabarPantallaScript") as? String ?? ""
// LaunchServices puede añadir -psn_... o -NS...; no son del script.
var args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
if args.isEmpty { args = ["0"] }

// Foundation lanza el script en su propio grupo de procesos (medido), así que un Ctrl-C en la
// terminal llega solo a esta app. Se reenvía al script, que lo pasa a ffmpeg y cierra el mp4
// limpio; la app sobrevive hasta que el script termine. Un manejador (no SIG_IGN) para que el
// hijo no herede la señal ignorada y pueda atraparla.
var pidScript: pid_t = 0
var interrumpido = false
signal(SIGINT) { _ in
    interrumpido = true
    if pidScript > 0 { kill(pidScript, SIGINT) }
}

/// avfoundation numera «Capture screen N» en el orden de CGGetActiveDisplayList (medido con
/// dos pantallas: 0 = la principal, 3024x1964; 1 = la externa, 1920x1080). Devuelve las
/// pantallas de AppKit en ese orden.
func pantallasEnOrdenAvfoundation() -> [NSScreen] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).compactMap { id in
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
}

/// Índice de avfoundation y pantalla que se graba: la que ya fije GRABAR_PANTALLA_INDICE (a mano
/// desde la terminal) o, si no, la que contiene el puntero al arrancar.
func elegirPantalla() -> (indice: Int, nombre: String) {
    let lista = pantallasEnOrdenAvfoundation()
    if let v = ProcessInfo.processInfo.environment["GRABAR_PANTALLA_INDICE"], let i = Int(v) {
        return (i, i < lista.count ? lista[i].localizedName : "pantalla \(i)")
    }
    let p = NSEvent.mouseLocation
    if let i = lista.firstIndex(where: { NSMouseInRect(p, $0.frame, false) }) { return (i, lista[i].localizedName) }
    return (0, lista.first?.localizedName ?? "pantalla 0")
}

// SIGTERM y SIGHUP (cierre ordenado desde fuera): el manejador C solo escribe en una tubería y
// el hilo principal hace la limpieza. Con un manejador (no SIG_IGN) el script hijo no hereda
// la señal ignorada.
var tuberiaSenal: [Int32] = [-1, -1]
pipe(&tuberiaSenal)
func alSenal(_ s: Int32) { var b: UInt8 = 1; write(tuberiaSenal[1], &b, 1) }
signal(SIGTERM, alSenal)
signal(SIGHUP, alSenal)

enum Estado { case cuenta(Int), iniciando, grabando, guardando, hecho, error }

final class Controlador: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let proceso = Process()
    var estado = Estado.cuenta(3)
    var pidFfmpeg: pid_t = 0
    var inicio = Date()
    var temporizador: Timer?
    var rutaVideo: String?
    var ultimaLinea = ""
    var cancelado = false
    var buffers: [Int32: Data] = [:]
    var pantalla = (indice: 0, nombre: "")
    var fuenteSenal: DispatchSourceRead?
    var saliendo = false
    var menuActual = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        pantalla = elegirPantalla()
        item.button?.target = self
        item.button?.action = #selector(clicEnIcono)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let fuente = DispatchSource.makeReadSource(fileDescriptor: tuberiaSenal[0], queue: .main)
        fuente.setEventHandler { [self] in
            var b: UInt8 = 0
            read(tuberiaSenal[0], &b, 1)
            guard !saliendo else { return }
            saliendo = true
            matarHijos { exit(143) }
        }
        fuente.resume()
        fuenteSenal = fuente
        pintar()
        lanzar()
    }

    /// Segunda activación (Spotlight con la app ya viva) equivale a Detener.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if case .grabando = estado { detener() }
        return false
    }

    /// ⌘Q o terminate: nunca deja el script ni ffmpeg huérfanos.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hayHijos() else { return .terminateNow }
        matarHijos { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func vivo(_ p: pid_t) -> Bool { p > 0 && kill(p, 0) == 0 }
    func hayHijos() -> Bool { (pidScript > 0 && proceso.isRunning) || vivo(pidFfmpeg) }

    /// SIGINT al script, que la pasa a ffmpeg (ffmpeg cierra el mp4 limpio); espera hasta 5 s a que acaben
    /// y, si siguen vivos (una captura colgada no responde a SIGINT, medido), SIGKILL. No bloquea
    /// el hilo principal: Foundation necesita su bucle para dar el script por terminado.
    func matarHijos(luego: @escaping () -> Void) {
        guard hayHijos() else { luego(); return }
        // Una sola SIGINT a ffmpeg: con dos seguidas aborta sin escribir el moov (mp4 roto, medido).
        // Si el script vive la reenvía él; si no, va directa.
        if pidScript > 0, proceso.isRunning { kill(pidScript, SIGINT) }
        else if vivo(pidFfmpeg) { kill(pidFfmpeg, SIGINT) }
        let limite = Date().addingTimeInterval(5)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] t in
            if hayHijos(), Date() < limite { return }
            t.invalidate()
            if vivo(pidFfmpeg) { kill(pidFfmpeg, SIGKILL) }
            if pidScript > 0, proceso.isRunning { kill(pidScript, SIGKILL) }
            luego()
        }
    }

    // MARK: Proceso hijo

    func lanzar() {
        guard !script.isEmpty, FileManager.default.isExecutableFile(atPath: script) else {
            ultimaLinea = "No encuentro el script: \(script.isEmpty ? "(sin ruta en el Info.plist)" : script)"
            terminar(codigo: 127)
            return
        }
        proceso.executableURL = URL(fileURLWithPath: script)
        proceso.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GRABAR_PANTALLA_APP"] = "1"
        env["GRABAR_PANTALLA_INDICE"] = String(pantalla.indice)
        proceso.environment = env
        let salida = Pipe(), errores = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = errores
        let grupo = DispatchGroup()
        for (pipe, esStdout) in [(salida, true), (errores, false)] {
            grupo.enter()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let datos = h.availableData
                if datos.isEmpty {
                    h.readabilityHandler = nil
                    grupo.leave()
                    return
                }
                DispatchQueue.main.async { self?.recibir(datos, stdout: esStdout) }
            }
        }
        grupo.enter()
        proceso.terminationHandler = { _ in grupo.leave() }
        grupo.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.terminar(codigo: self.proceso.terminationStatus)
        }
        do { try proceso.run(); pidScript = proceso.processIdentifier } catch {
            ultimaLinea = "No pude lanzar el script: \(error.localizedDescription)"
            terminar(codigo: 126)
        }
    }

    /// Acumula bytes y procesa líneas completas (un trozo puede cortar una línea o traer varias).
    func recibir(_ datos: Data, stdout: Bool) {
        let clave: Int32 = stdout ? 1 : 2
        var buf = buffers[clave, default: Data()]
        buf.append(datos)
        while let nl = buf.firstIndex(of: 0x0A) {
            let linea = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
            buf.removeSubrange(buf.startIndex...nl)
            procesar(linea, stdout: stdout)
        }
        buffers[clave] = buf
    }

    func procesar(_ linea: String, stdout: Bool) {
        if stdout, linea.hasPrefix("@estado ") {
            let partes = linea.dropFirst(8).split(separator: " ", maxSplits: 1).map(String.init)
            switch (partes.first, partes.count > 1 ? partes[1] : "") {
            case ("cuenta", let n): estado = .cuenta(Int(n) ?? 0)
            case ("iniciando", let p):
                pidFfmpeg = pid_t(p) ?? 0
                estado = .iniciando
            case ("grabando", let p):
                pidFfmpeg = pid_t(p) ?? 0
                inicio = Date()
                estado = .grabando
                temporizador = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pintar() }
            case ("hecho", let ruta): rutaVideo = ruta
            default: break
            }
            pintar()
            return
        }
        FileHandle.standardError.write(Data((linea + "\n").utf8))
        if !stdout, !linea.isEmpty { ultimaLinea = linea }
    }

    // MARK: Acciones

    /// Clic derecho (o Control + clic, convención de macOS) en el icono: acción directa sin abrir el
    /// menú. Grabando detiene; en la cuenta atrás o «Iniciando…» cancela. En «Guardando…», hecho o
    /// error no hay nada que parar y se abre el menú (en hecho y error trae «Mostrar en Finder» / «Cerrar»).
    /// Clic izquierdo: el menú de siempre. El menú se asigna solo mientras se muestra para que el
    /// botón reciba la acción del clic derecho (con `menu` fijo, AppKit se queda el clic).
    @objc func clicEnIcono() {
        let e = NSApp.currentEvent
        let derecho = e?.type == .rightMouseUp || (e?.type == .leftMouseUp && e!.modifierFlags.contains(.control))
        if derecho {
            switch estado {
            case .grabando: detener(); return
            case .cuenta, .iniciando: cancelar(); return
            default: break
            }
        }
        item.menu = menuActual
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func detener() {
        guard case .grabando = estado, pidFfmpeg > 0 else { return }
        estado = .guardando
        kill(pidFfmpeg, SIGINT)
        pintar()
    }

    @objc func cancelar() {
        cancelado = true
        matarHijos { exit(130) }
    }

    @objc func mostrarEnFinder() {
        if let r = rutaVideo { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r)]) }
    }

    @objc func cerrar() { exit(proceso.terminationStatus) }

    /// El script ya terminó (y su salida está leída): hecho, error o cancelación.
    func terminar(codigo: Int32) {
        temporizador?.invalidate()
        if cancelado || (interrumpido && rutaVideo == nil) { exit(codigo) }
        if rutaVideo != nil, codigo == 0 {
            estado = .hecho
            pintar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        } else {
            estado = .error
            if ultimaLinea.isEmpty { ultimaLinea = "El script terminó con código \(codigo)" }
            pintar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(codigo) }
        }
    }

    // MARK: Icono y menú

    func tiempo() -> String {
        let s = Int(Date().timeIntervalSince(inicio))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    func simbolo(_ nombre: String, rojo: Bool = false) -> NSImage? {
        guard var img = NSImage(systemSymbolName: nombre, accessibilityDescription: "Grabar pantalla") else { return nil }
        if rojo, let c = img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) {
            img = c
            img.isTemplate = false
        } else {
            img.isTemplate = true
        }
        return img
    }

    func pintar() {
        let menu = NSMenu()
        let boton = item.button
        func fila(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func accion(_ t: String, _ sel: Selector, _ tecla: String = "") {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: tecla)
            i.target = self
            menu.addItem(i)
        }
        boton?.imagePosition = .imageLeft
        switch estado {
        case .cuenta(let n):
            boton?.image = nil
            boton?.title = String(n)
            fila("Empieza en \(n)… · \(pantalla.nombre)")
            accion("Cancelar", #selector(cancelar))
        case .iniciando:
            boton?.image = nil
            boton?.title = "Iniciando…"
            fila("Iniciando… · \(pantalla.nombre)")
            accion("Cancelar", #selector(cancelar))
        case .grabando:
            boton?.image = simbolo("record.circle.fill", rojo: true)
            boton?.title = tiempo()
            fila("Grabando \(tiempo()) · \(pantalla.nombre)")
            accion("Detener grabación", #selector(detener), ".")
            fila("Clic derecho en el icono: detener")
        case .guardando:
            boton?.image = simbolo("record.circle")
            boton?.title = "Guardando…"
            fila("Guardando…")
        case .hecho:
            boton?.image = simbolo("checkmark.circle")
            boton?.title = ""
            accion("Mostrar en Finder", #selector(mostrarEnFinder))
        case .error:
            boton?.image = simbolo("exclamationmark.triangle")
            boton?.title = ""
            fila(ultimaLinea)
            accion("Cerrar", #selector(cerrar))
        }
        menuActual = menu
    }
}

let app = NSApplication.shared
let controlador = Controlador()
app.delegate = controlador
app.run()

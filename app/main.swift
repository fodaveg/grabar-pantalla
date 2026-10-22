// Icono de barra de menús para `grabar-pantalla`. No graba nada: lanza el script del repo
// (ruta en la clave GrabarPantallaScript del Info.plist) como hijo con GRABAR_PANTALLA_APP=1,
// lee su stdout y pinta el estado a partir de las líneas `@estado ...`. El resto de líneas
// (y todo su stderr) se reenvían tal cual a la salida de esta app.
//
// Dos modos, según los argumentos:
// - Residente (sin argumentos: LaunchServices desde Spotlight, Finder, `open` o el inicio de
//   sesión): se queda en la barra de menús en espera y lanza un `Process` nuevo por grabación,
//   con «0» = hasta Detener (el script pone un tope de 30 min). Abierta normalmente graba al
//   instante; como ítem de inicio de sesión queda en espera. Registra el atajo global.
// - Terminal (con argumentos, que pone el script `grabar-pantalla [segundos]`): proceso propio de
//   un solo uso. Graba, espera al final y sale con el código del script. No toca la residente.
import AppKit
import Carbon.HIToolbox
import UserNotifications

// MARK: - Arranque

let script = Bundle.main.object(forInfoDictionaryKey: "GrabarPantallaScript") as? String ?? ""
// LaunchServices puede añadir -psn_... o -NS...; no son del script.
let argsTerminal = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
let residente = argsTerminal.isEmpty
let args = residente ? ["0"] : argsTerminal

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

/// Índice de avfoundation y pantalla que se graba: la pedida explícitamente (submenú), la que
/// fije GRABAR_PANTALLA_INDICE (a mano desde la terminal) o, si no, la que contiene el puntero.
func elegirPantalla(forzada: Int? = nil) -> (indice: Int, nombre: String) {
    let lista = pantallasEnOrdenAvfoundation()
    var pedida = forzada
    if pedida == nil, !residente, let v = ProcessInfo.processInfo.environment["GRABAR_PANTALLA_INDICE"] { pedida = Int(v) }
    if let i = pedida { return (i, i < lista.count ? lista[i].localizedName : "pantalla \(i)") }
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

enum Estado { case espera, cuenta(Int), iniciando, grabando, guardando, hecho, error }

/// Una grabación: su `Process` y lo que el script cuenta de ella. Cada grabación estrena la suya,
/// y lo que llega de una anterior (salida rezagada) se ignora comparando identidades.
final class Sesion {
    let proceso = Process()
    var pidFfmpeg: pid_t = 0
    var rutaVideo: String?
    var medida = ""
    var ultimaLinea = ""
    var cancelado = false
    var buffers: [Int32: Data] = [:]
}

/// Atajo global fijo: ⌃⌥⌘R (los ⌘⇧3/4/5 son del sistema).
let atajoTecla = UInt32(kVK_ANSI_R)
let atajoModificadores = UInt32(controlKey | optionKey | cmdKey)
let categoriaNotificacion = "grabacion-terminada"

final class Controlador: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var estado = Estado.espera
    var sesion: Sesion?
    var inicio = Date()
    var temporizador: Timer?
    var pantalla = (indice: 0, nombre: "")
    var fuenteSenal: DispatchSourceRead?
    var saliendo = false
    var menuActual = NSMenu()
    var tokenEspera = 0
    var lanzadaPorNotificacion = false
    var atajoRef: EventHotKeyRef?

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
        configurarNotificaciones()
        if residente { registrarAtajo() }
        guard residente else {
            estado = .cuenta(3)
            pintar()
            lanzar()
            return
        }
        estado = .espera
        pintar()
        if lanzadaComoItemDeInicio() { return }
        // Un clic en una notificación de una instancia ya muerta relanza la app por LaunchServices
        // sin argumentos: la respuesta llega justo después del arranque y no debe empezar a grabar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            if !lanzadaPorNotificacion, case .espera = estado { empezar() }
        }
    }

    /// El evento de apertura trae la propiedad `lgit` (keyAELaunchedAsLogInItem) cuando macOS
    /// lanza la app al iniciar sesión.
    func lanzadaComoItemDeInicio() -> Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent, ev.eventID == AEEventID(kAEOpenApplication) else { return false }
        return ev.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// Reabrir la app (Spotlight, Finder, `open`) con ella viva: grabando detiene, en la cuenta
    /// atrás cancela y en espera empieza a grabar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard residente else {
            if case .grabando = estado { detener() }
            return false
        }
        alternar()
        return false
    }

    /// ⌘Q o terminate: nunca deja el script ni ffmpeg huérfanos.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hayHijos() else { return .terminateNow }
        matarHijos { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func vivo(_ p: pid_t) -> Bool { p > 0 && kill(p, 0) == 0 }
    func hayHijos() -> Bool {
        guard let s = sesion else { return false }
        return (s.proceso.isRunning && s.proceso.processIdentifier > 0) || vivo(s.pidFfmpeg)
    }

    /// SIGINT al script, que la pasa a ffmpeg (ffmpeg cierra el mp4 limpio); espera hasta 5 s a que acaben
    /// y, si siguen vivos (una captura colgada no responde a SIGINT, medido), SIGKILL. No bloquea
    /// el hilo principal: Foundation necesita su bucle para dar el script por terminado.
    func matarHijos(luego: @escaping () -> Void) {
        guard hayHijos(), let s = sesion else { luego(); return }
        // Una sola SIGINT a ffmpeg: con dos seguidas aborta sin escribir el moov (mp4 roto, medido).
        // Si el script vive la reenvía él; si no, va directa.
        if s.proceso.isRunning { kill(s.proceso.processIdentifier, SIGINT) }
        else if vivo(s.pidFfmpeg) { kill(s.pidFfmpeg, SIGINT) }
        let limite = Date().addingTimeInterval(5)
        // En modos comunes: con `terminateLater` AppKit corre el bucle en modo modal y un temporizador
        // del modo por defecto no dispara nunca (medido: osascript quit se quedaba colgado).
        let t = Timer(timeInterval: 0.05, repeats: true) { [self] t in
            if hayHijos(), Date() < limite { return }
            t.invalidate()
            if vivo(s.pidFfmpeg) { kill(s.pidFfmpeg, SIGKILL) }
            if s.proceso.isRunning { kill(s.proceso.processIdentifier, SIGKILL) }
            luego()
        }
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: Atajo global

    /// Carbon `RegisterEventHotKey`: no pide permiso de Accesibilidad. Si otra app ya tiene la
    /// combinación, el registro falla y el atajo no funciona (se avisa por stderr).
    func registrarAtajo() {
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { controlador.alternar() }
            return noErr
        }, 1, &tipo, nil, nil)
        let r = RegisterEventHotKey(atajoTecla, atajoModificadores, EventHotKeyID(signature: OSType(0x4752_4142), id: 1),
                                    GetApplicationEventTarget(), 0, &atajoRef)
        if r != noErr { FileHandle.standardError.write(Data("No pude registrar el atajo ⌃⌥⌘R (error \(r))\n".utf8)) }
    }

    /// Atajo y reapertura: empieza si está en espera, detiene si graba, cancela en la cuenta atrás.
    func alternar() {
        switch estado {
        case .espera, .hecho, .error: empezar()
        case .grabando: detener()
        case .cuenta, .iniciando: cancelar()
        case .guardando: break
        }
    }

    // MARK: Notificaciones

    func configurarNotificaciones() {
        let centro = UNUserNotificationCenter.current()
        centro.delegate = self
        let mostrar = UNNotificationAction(identifier: "mostrar", title: "Mostrar", options: [])
        let copiar = UNNotificationAction(identifier: "copiar", title: "Copiar ruta", options: [])
        centro.setNotificationCategories([UNNotificationCategory(identifier: categoriaNotificacion, actions: [mostrar, copiar],
                                                                 intentIdentifiers: [], options: [])])
        centro.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notificar(ruta: String, medida: String) {
        let c = UNMutableNotificationContent()
        c.title = "Grabación terminada"
        c.subtitle = (ruta as NSString).lastPathComponent
        c.body = medida
        c.sound = .default
        c.categoryIdentifier = categoriaNotificacion
        c.userInfo = ["ruta": ruta]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { _ in }
    }

    /// Con la app en primer plano macOS no muestra la notificación si no se pide aquí.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Pulsar la notificación o «Mostrar» = revelar en Finder; «Copiar ruta» = portapapeles.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        lanzadaPorNotificacion = true
        if let ruta = response.notification.request.content.userInfo["ruta"] as? String {
            if response.actionIdentifier == "copiar" {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ruta, forType: .string)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ruta)])
            }
        }
        completionHandler()
    }

    // MARK: Proceso hijo

    /// Nueva grabación desde la espera (menú, atajo, reapertura o arranque normal).
    func empezar(indice: Int? = nil) {
        tokenEspera += 1
        interrumpido = false
        pantalla = elegirPantalla(forzada: indice)
        estado = .cuenta(3)
        pintar()
        lanzar()
    }

    func lanzar() {
        let s = Sesion()
        sesion = s
        guard !script.isEmpty, FileManager.default.isExecutableFile(atPath: script) else {
            s.ultimaLinea = "No encuentro el script: \(script.isEmpty ? "(sin ruta en el Info.plist)" : script)"
            terminar(s, codigo: 127)
            return
        }
        let proceso = s.proceso
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
                DispatchQueue.main.async { self?.recibir(s, datos, stdout: esStdout) }
            }
        }
        grupo.enter()
        proceso.terminationHandler = { _ in grupo.leave() }
        grupo.notify(queue: .main) { [weak self] in
            guard let self else { return }
            pidScript = 0
            self.terminar(s, codigo: s.proceso.terminationStatus)
        }
        do { try proceso.run(); pidScript = proceso.processIdentifier } catch {
            s.ultimaLinea = "No pude lanzar el script: \(error.localizedDescription)"
            terminar(s, codigo: 126)
        }
    }

    /// Acumula bytes y procesa líneas completas (un trozo puede cortar una línea o traer varias).
    func recibir(_ s: Sesion, _ datos: Data, stdout: Bool) {
        let clave: Int32 = stdout ? 1 : 2
        var buf = s.buffers[clave, default: Data()]
        buf.append(datos)
        while let nl = buf.firstIndex(of: 0x0A) {
            let linea = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
            buf.removeSubrange(buf.startIndex...nl)
            procesar(s, linea, stdout: stdout)
        }
        s.buffers[clave] = buf
    }

    func procesar(_ s: Sesion, _ linea: String, stdout: Bool) {
        if stdout, linea.hasPrefix("@estado ") {
            guard s === sesion else { return }
            let partes = linea.dropFirst(8).split(separator: " ", maxSplits: 1).map(String.init)
            switch (partes.first, partes.count > 1 ? partes[1] : "") {
            case ("cuenta", let n): estado = .cuenta(Int(n) ?? 0)
            case ("iniciando", let p):
                s.pidFfmpeg = pid_t(p) ?? 0
                estado = .iniciando
            case ("grabando", let p):
                s.pidFfmpeg = pid_t(p) ?? 0
                inicio = Date()
                estado = .grabando
                temporizador?.invalidate()
                temporizador = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pintar() }
            case ("medida", let m): s.medida = m
            case ("hecho", let ruta): s.rutaVideo = ruta
            default: break
            }
            pintar()
            return
        }
        FileHandle.standardError.write(Data((linea + "\n").utf8))
        if !stdout, !linea.isEmpty { s.ultimaLinea = linea }
    }

    // MARK: Acciones

    /// Grabando, el clic izquierdo detiene directamente; en la cuenta atrás o «Iniciando…» cancela.
    /// El clic derecho (o Control + clic, convención de macOS) abre siempre el menú, igual que el
    /// izquierdo en el resto de estados. El menú se asigna solo mientras se muestra para que el
    /// botón reciba la acción del clic derecho (con `menu` fijo, AppKit se queda el clic).
    @objc func clicEnIcono() {
        let e = NSApp.currentEvent
        let derecho = e?.type == .rightMouseUp || (e?.type == .leftMouseUp && e!.modifierFlags.contains(.control))
        if !derecho {
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
        guard case .grabando = estado, let s = sesion, s.pidFfmpeg > 0 else { return }
        estado = .guardando
        kill(s.pidFfmpeg, SIGINT)
        pintar()
    }

    @objc func cancelar() {
        sesion?.cancelado = true
        matarHijos { if !residente { exit(130) } }
    }

    @objc func grabarPunteroDesdeMenu() { empezar() }
    @objc func grabarPantallaDesdeMenu(_ i: NSMenuItem) { empezar(indice: i.tag) }
    @objc func salir() { NSApp.terminate(nil) }

    @objc func mostrarEnFinder() {
        if let r = sesion?.rutaVideo { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r)]) }
    }

    /// «Cerrar» tras un error: la terminal sale, la residente vuelve a espera.
    @objc func cerrar() {
        if residente { volverAEspera(en: 0) } else { exit(sesion?.proceso.terminationStatus ?? 1) }
    }

    /// Pasado `segundos`, si nadie ha empezado otra grabación, vuelve al estado de espera.
    func volverAEspera(en segundos: Double) {
        tokenEspera += 1
        let t = tokenEspera
        let hacer = { [self] in
            guard t == tokenEspera else { return }
            sesion = nil
            estado = .espera
            pintar()
        }
        if segundos <= 0 { hacer() } else { DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: hacer) }
    }

    /// El script ya terminó (y su salida está leída): hecho, error o cancelación.
    func terminar(_ s: Sesion, codigo: Int32) {
        guard s === sesion else { return }
        temporizador?.invalidate()
        if s.cancelado || (interrumpido && s.rutaVideo == nil) {
            if residente { volverAEspera(en: 0) } else { exit(codigo) }
            return
        }
        if let ruta = s.rutaVideo, codigo == 0 {
            estado = .hecho
            pintar()
            notificar(ruta: ruta, medida: s.medida)
            if residente { volverAEspera(en: 5) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) } }
        } else {
            estado = .error
            if s.ultimaLinea.isEmpty { s.ultimaLinea = "El script terminó con código \(codigo)" }
            pintar()
            if residente { volverAEspera(en: 15) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(codigo) } }
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
        @discardableResult
        func accion(_ t: String, _ sel: Selector?, _ tecla: String = "", atajo: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: atajo ? "r" : tecla)
            if atajo { i.keyEquivalentModifierMask = [.control, .option, .command] }
            i.target = self
            menu.addItem(i)
            return i
        }
        func pieResidente() {
            guard residente else { return }
            menu.addItem(.separator())
            let ajustes = accion("Ajustes…", nil, ",")
            ajustes.isEnabled = false
            accion("Salir", #selector(salir), "q")
        }
        boton?.imagePosition = .imageLeft
        switch estado {
        case .espera:
            boton?.image = simbolo("display")
            boton?.title = ""
            accion("Grabar", #selector(grabarPunteroDesdeMenu), atajo: true)
            let sub = NSMenu()
            for (i, p) in pantallasEnOrdenAvfoundation().enumerated() {
                let it = NSMenuItem(title: p.localizedName, action: #selector(grabarPantallaDesdeMenu(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                sub.addItem(it)
            }
            let padre = NSMenuItem(title: "Grabar pantalla", action: nil, keyEquivalent: "")
            padre.submenu = sub
            menu.addItem(padre)
            pieResidente()
        case .cuenta(let n):
            boton?.image = nil
            boton?.title = String(n)
            fila("Empieza en \(n)… · \(pantalla.nombre)")
            accion("Cancelar", #selector(cancelar), atajo: residente)
            fila("Clic en el icono: cancelar")
            pieResidente()
        case .iniciando:
            boton?.image = nil
            boton?.title = "Iniciando…"
            fila("Iniciando… · \(pantalla.nombre)")
            accion("Cancelar", #selector(cancelar), atajo: residente)
            fila("Clic en el icono: cancelar")
            pieResidente()
        case .grabando:
            boton?.image = simbolo("record.circle.fill", rojo: true)
            boton?.title = tiempo()
            fila("Grabando \(tiempo()) · \(pantalla.nombre)")
            accion("Detener grabación", #selector(detener), residente ? "" : ".", atajo: residente)
            fila("Clic en el icono: detener")
            pieResidente()
        case .guardando:
            boton?.image = simbolo("record.circle")
            boton?.title = "Guardando…"
            fila("Guardando…")
            pieResidente()
        case .hecho:
            boton?.image = simbolo("checkmark.circle")
            boton?.title = ""
            accion("Mostrar en Finder", #selector(mostrarEnFinder))
            if residente { accion("Grabar", #selector(grabarPunteroDesdeMenu), atajo: true) }
            pieResidente()
        case .error:
            boton?.image = simbolo("exclamationmark.triangle")
            boton?.title = ""
            fila(sesion?.ultimaLinea ?? "")
            accion("Cerrar", #selector(cerrar))
            if residente { accion("Grabar", #selector(grabarPunteroDesdeMenu), atajo: true) }
            pieResidente()
        }
        menuActual = menu
    }
}

let app = NSApplication.shared
let controlador = Controlador()
app.delegate = controlador
app.run()

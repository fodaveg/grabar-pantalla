// Ajustes de Grabar pantalla: lo que se guarda en UserDefaults (dominio net.fodaveg.grabar-pantalla)
// y la ventana que lo cambia. Se leen al empezar cada grabación, también la de un solo uso de la
// terminal, así que cambiar uno nunca toca la grabación en curso. Cada cambio de la ventana se guarda
// al momento; no hay botón de guardar.
import AppKit
import AVFoundation
import ServiceManagement

/// Claves de UserDefaults. Se pueden cambiar a mano con
/// `defaults write net.fodaveg.grabar-pantalla <clave> …`; sin clave, vale el valor por defecto.
enum Clave {
    /// Ruta de la carpeta de destino (texto, admite `~`). Por defecto, ~/Movies.
    static let carpeta = "carpeta"
    /// `compacta`, `normal` (por defecto) o `animaciones`.
    static let calidad = "calidad"
    /// Segundos de cuenta atrás, de 0 a 10 (por defecto, 3).
    static let cuentaAtras = "cuentaAtras"
    /// Segundos al grabar desde la app y el atajo; 0 = hasta Detener (por defecto). Tope: 30 min.
    static let duracion = "duracion"
    static let mostrarPuntero = "mostrarPuntero"
    static let marcarClics = "marcarClics"
    /// `ninguno` (por defecto), `sistema`, `microfono` o `sistemaYMicrofono`.
    static let audio = "audio"
    static let notificar = "notificar"
    static let sonido = "sonido"
    static let abrirEnFinder = "abrirEnFinder"
    static let copiarRuta = "copiarRuta"
}

/// Qué audio se graba. Cada fuente va en su propia pista AAC del mp4.
enum Audio: String, CaseIterable {
    case ninguno, sistema, microfono, sistemaYMicrofono

    var nombre: String {
        switch self {
        case .ninguno: return "Ninguno"
        case .sistema: return "Sonido del sistema"
        case .microfono: return "Micrófono"
        case .sistemaYMicrofono: return "Sistema y micrófono"
        }
    }
    var sistema: Bool { self == .sistema || self == .sistemaYMicrofono }
    var microfono: Bool { self == .microfono || self == .sistemaYMicrofono }
}

/// El micrófono por ScreenCaptureKit (`captureMicrophone`) y los clics marcados llegan en macOS 15.
func hayMacOS15() -> Bool {
    if #available(macOS 15.0, *) { return true }
    return false
}

/// Los ajustes de una grabación, leídos de UserDefaults con sus límites aplicados.
struct Ajustes {
    static let carpetaPorDefecto = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
    static let cuentaMaxima = 10
    /// Lo más largo que se puede pedir: el tope de seguridad, que no se ajusta.
    static let duracionMaxima = Int(topeSegundos)

    var carpeta = carpetaPorDefecto
    var calidad = Calidad.normal
    var cuentaAtras = 3
    var duracion = 0
    var mostrarPuntero = true
    var marcarClics = true
    var audio = Audio.ninguno
    var notificar = true
    var sonido = true
    var abrirEnFinder = false
    var copiarRuta = false

    /// Lee los ajustes. Un valor fuera de rango (escrito a mano con `defaults`) se ajusta al límite y
    /// uno ilegible vale lo de por defecto.
    static func leer(_ d: UserDefaults = .standard) -> Ajustes {
        var a = Ajustes()
        if let c = d.string(forKey: Clave.carpeta), !c.isEmpty {
            a.carpeta = URL(fileURLWithPath: (c as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let c = d.string(forKey: Clave.calidad).flatMap(Calidad.init(rawValue:)) { a.calidad = c }
        if d.object(forKey: Clave.cuentaAtras) != nil { a.cuentaAtras = min(max(d.integer(forKey: Clave.cuentaAtras), 0), cuentaMaxima) }
        if d.object(forKey: Clave.duracion) != nil { a.duracion = min(max(d.integer(forKey: Clave.duracion), 0), duracionMaxima) }
        func si(_ k: String, _ porDefecto: Bool) -> Bool { d.object(forKey: k) == nil ? porDefecto : d.bool(forKey: k) }
        a.mostrarPuntero = si(Clave.mostrarPuntero, a.mostrarPuntero)
        a.marcarClics = si(Clave.marcarClics, a.marcarClics)
        if let v = d.string(forKey: Clave.audio).flatMap(Audio.init(rawValue:)) { a.audio = v }
        a.notificar = si(Clave.notificar, a.notificar)
        a.sonido = si(Clave.sonido, a.sonido)
        a.abrirEnFinder = si(Clave.abrirEnFinder, a.abrirEnFinder)
        a.copiarRuta = si(Clave.copiarRuta, a.copiarRuta)
        return a
    }

    var carpetaEsLaDePorDefecto: Bool { carpeta.standardizedFileURL.path == Ajustes.carpetaPorDefecto.standardizedFileURL.path }
}

/// Por qué no vale la carpeta de destino (nil si vale). Una carpeta de un volumen desmontado
/// simplemente no existe: no se crea, porque crearla dejaría una carpeta suelta en /Volumes.
func problemaCarpeta(_ url: URL) -> String? {
    var esCarpeta: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &esCarpeta) else { return "no existe (¿disco desconectado?)" }
    guard esCarpeta.boolValue else { return "no es una carpeta" }
    guard FileManager.default.isWritableFile(atPath: url.path) else { return "no deja escribir" }
    return nil
}

/// Ruta con ~ en vez de la carpeta personal, para enseñarla.
func abreviar(_ ruta: String) -> String { (ruta as NSString).abbreviatingWithTildeInPath }

// MARK: - Ventana

/// Ventana de Ajustes: una sola página con una rejilla (etiqueta a la derecha, control a la
/// izquierda), como los ajustes clásicos de macOS. Ancho fijo de la columna de controles; los textos
/// largos parten línea y la ventana se ajusta a su contenido, así que nada se corta. Mientras hay una
/// grabación en curso (cuenta atrás incluida) los controles se deshabilitan y un aviso lo explica.
final class VentanaAjustes: NSWindowController, NSWindowDelegate {
    private let d = UserDefaults.standard
    /// Ancho de la columna de controles; las notas parten línea dentro de él.
    private let anchoControles: CGFloat = 400

    private let aviso = NSStackView()
    private let rutaCarpeta = NSTextField(labelWithString: "")
    private let avisoCarpeta = NSTextField(wrappingLabelWithString: "")
    private let filaAvisoCarpeta = NSStackView()
    private let botonElegir = NSButton(title: "Elegir…", target: nil, action: nil)
    private let botonPorDefecto = NSButton(title: "Usar ~/Movies", target: nil, action: nil)
    private var radiosCalidad: [NSButton] = []
    private let campoCuenta = NSTextField()
    private let pasoCuenta = NSStepper()
    private let radioHastaDetener = NSButton(radioButtonWithTitle: "Hasta Detener (tope de 30 min)", target: nil, action: nil)
    private let radioDurante = NSButton(radioButtonWithTitle: "Durante", target: nil, action: nil)
    private let campoDuracion = NSTextField()
    private let pasoDuracion = NSStepper()
    private let notaTope = NSTextField(wrappingLabelWithString: "")
    private let checkPuntero = NSButton(checkboxWithTitle: "Mostrar el puntero", target: nil, action: nil)
    private let checkClics = NSButton(checkboxWithTitle: "Marcar los clics", target: nil, action: nil)
    private let menuAudio = NSPopUpButton()
    private let notaAudio = NSTextField(wrappingLabelWithString: "")
    private let checkNotificar = NSButton(checkboxWithTitle: "Mostrar una notificación", target: nil, action: nil)
    private let checkSonido = NSButton(checkboxWithTitle: "Reproducir un sonido", target: nil, action: nil)
    private let checkFinder = NSButton(checkboxWithTitle: "Mostrar el vídeo en Finder", target: nil, action: nil)
    private let checkCopiar = NSButton(checkboxWithTitle: "Copiar la ruta del vídeo", target: nil, action: nil)
    private let checkLogin = NSButton(checkboxWithTitle: "Abrir Grabar pantalla al iniciar sesión", target: nil, action: nil)
    private let estadoLogin = NSTextField(wrappingLabelWithString: "")
    private let botonAprobar = NSButton(title: "Abrir Ajustes del Sistema…", target: nil, action: nil)
    private let errorLogin = NSTextField(wrappingLabelWithString: "")
    /// Hay una grabación en curso: todo deshabilitado.
    private var bloqueada = false

    init() {
        let ventana = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled, .closable],
                               backing: .buffered, defer: true)
        ventana.title = "Ajustes de Grabar pantalla"
        ventana.isReleasedWhenClosed = false
        // El orden de tabulación sigue la posición en pantalla: de arriba abajo y de izquierda a derecha.
        ventana.autorecalculatesKeyViewLoop = true
        super.init(window: ventana)
        ventana.delegate = self
        montar()
        recargar()
        ventana.center()
    }

    required init?(coder: NSCoder) { fatalError("sin storyboard") }

    /// Trae la ventana delante con los valores guardados (pueden haber cambiado con `defaults`).
    func mostrar() {
        recargar()
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Lo llama el controlador en cada cambio de estado: con una grabación en curso no se cambia nada.
    /// Al entrar y al salir vuelve a leer lo guardado: enseña lo que usa la grabación y lo que se
    /// haya cambiado con `defaults` mientras tanto.
    func bloquear(_ si: Bool) {
        guard si != bloqueada else { return }
        bloqueada = si
        recargar()
    }

    func windowDidBecomeKey(_ notification: Notification) { recargar() }

    /// Esc cierra, como en las demás ventanas de ajustes.
    @objc func cancel(_ sender: Any?) { close() }

    // MARK: Construcción

    private func nota(_ t: String, _ campo: NSTextField? = nil, sangria: CGFloat = 0) -> NSTextField {
        let l = campo ?? NSTextField(wrappingLabelWithString: "")
        l.stringValue = t
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = anchoControles - sangria
        return l
    }

    private func etiqueta(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.alignment = .right
        return l
    }

    private func pila(_ vistas: [NSView], vertical: Bool = true, espacio: CGFloat = 6) -> NSStackView {
        let p = NSStackView(views: vistas)
        p.orientation = vertical ? .vertical : .horizontal
        p.alignment = vertical ? .leading : .firstBaseline
        p.spacing = espacio
        return p
    }

    /// La nota de una opción, metida bajo el texto del botón (a la altura del título, no del círculo).
    private func sangrada(_ v: NSView) -> NSStackView {
        let p = pila([v])
        p.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return p
    }

    private func simbolo(_ nombre: String, _ descripcion: String, color: NSColor? = nil) -> NSImageView {
        let v = NSImageView(image: NSImage(systemSymbolName: nombre, accessibilityDescription: descripcion) ?? NSImage())
        if let color { v.contentTintColor = color }
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }

    private func campoNumerico(_ campo: NSTextField, _ paso: NSStepper, ancho: CGFloat, maximo: Int, minimo: Int,
                               etiquetaAccesible: String, accion: Selector) {
        campo.alignment = .right
        campo.translatesAutoresizingMaskIntoConstraints = false
        campo.widthAnchor.constraint(equalToConstant: ancho).isActive = true
        campo.target = self
        campo.action = accion
        // Sale del campo con Tab o con un clic fuera: también guarda, no solo con Intro.
        campo.cell?.sendsActionOnEndEditing = true
        campo.setAccessibilityLabel(etiquetaAccesible)
        paso.minValue = Double(minimo)
        paso.maxValue = Double(maximo)
        paso.increment = 1
        paso.valueWraps = false
        paso.target = self
        paso.action = accion
        paso.setAccessibilityLabel(etiquetaAccesible)
    }

    private func montar() {
        guard let contenido = window?.contentView else { return }
        var filas: [[NSView]] = []
        var separadores: [Int] = []
        func separador() {
            separadores.append(filas.count)
            filas.append([NSBox.separador(), NSGridCell.emptyContentView])
        }

        // Aviso de grabación en curso (oculto normalmente).
        let textoAviso = nota("Hay una grabación en curso: los ajustes se podrán cambiar cuando termine.", sangria: 24)
        textoAviso.textColor = .labelColor
        aviso.setViews([simbolo("record.circle", "Grabando", color: .systemRed), textoAviso], in: .leading)
        aviso.orientation = .horizontal
        aviso.alignment = .firstBaseline
        aviso.spacing = 6
        aviso.isHidden = true

        // Carpeta.
        rutaCarpeta.lineBreakMode = .byTruncatingMiddle
        rutaCarpeta.isSelectable = true
        rutaCarpeta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rutaCarpeta.setAccessibilityLabel("Carpeta de destino")
        let elegir = botonElegir
        elegir.target = self
        elegir.action = #selector(elegirCarpeta)
        elegir.setAccessibilityLabel("Elegir la carpeta de destino")
        botonPorDefecto.target = self
        botonPorDefecto.action = #selector(carpetaPorDefecto)
        botonPorDefecto.setAccessibilityLabel("Guardar en la carpeta Películas, ~/Movies")
        let filaRuta = pila([simbolo("folder", "Carpeta"), rutaCarpeta], vertical: false, espacio: 4)
        avisoCarpeta.textColor = .systemOrange
        avisoCarpeta.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        avisoCarpeta.preferredMaxLayoutWidth = anchoControles - 24
        filaAvisoCarpeta.setViews([simbolo("exclamationmark.triangle.fill", "Aviso", color: .systemOrange), avisoCarpeta], in: .leading)
        filaAvisoCarpeta.orientation = .horizontal
        filaAvisoCarpeta.alignment = .firstBaseline
        filaAvisoCarpeta.spacing = 4
        let carpeta = pila([filaRuta, filaAvisoCarpeta, pila([elegir, botonPorDefecto], vertical: false, espacio: 8)])
        filaRuta.widthAnchor.constraint(lessThanOrEqualToConstant: anchoControles).isActive = true
        filas.append([etiqueta("Guardar en:"), carpeta])

        // Calidad.
        var opciones: [NSView] = []
        for c in Calidad.allCases {
            let r = NSButton(radioButtonWithTitle: c.nombre, target: self, action: #selector(cambiarCalidad(_:)))
            r.identifier = NSUserInterfaceItemIdentifier(c.rawValue)
            r.setAccessibilityHelp(c.descripcion)
            radiosCalidad.append(r)
            opciones.append(pila([r, sangrada(nota(c.descripcion, sangria: 20))], espacio: 1))
        }
        opciones.append(nota("Peso medido con una animación y el escritorio en uso; con la pantalla quieta, mucho menos."))
        filas.append([etiqueta("Calidad:"), pila(opciones, espacio: 8)])
        separador()

        // Cuenta atrás.
        campoNumerico(campoCuenta, pasoCuenta, ancho: 40, maximo: Ajustes.cuentaMaxima, minimo: 0,
                      etiquetaAccesible: "Cuenta atrás en segundos", accion: #selector(cambiarCuenta(_:)))
        let cuenta = pila([pila([campoCuenta, pasoCuenta, NSTextField(labelWithString: "s")], vertical: false, espacio: 4),
                           nota("Con 0 empieza al momento. De 0 a \(Ajustes.cuentaMaxima) s.")])
        filas.append([etiqueta("Cuenta atrás:"), cuenta])

        // Duración.
        radioHastaDetener.target = self
        radioHastaDetener.action = #selector(cambiarModoDuracion(_:))
        radioDurante.target = self
        radioDurante.action = #selector(cambiarModoDuracion(_:))
        campoNumerico(campoDuracion, pasoDuracion, ancho: 56, maximo: Ajustes.duracionMaxima, minimo: 1,
                      etiquetaAccesible: "Duración en segundos", accion: #selector(cambiarDuracion(_:)))
        notaTope.textColor = .systemOrange
        notaTope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notaTope.preferredMaxLayoutWidth = anchoControles
        notaTope.isHidden = true
        let duracion = pila([
            radioHastaDetener,
            pila([radioDurante, campoDuracion, pasoDuracion, NSTextField(labelWithString: "s")], vertical: false, espacio: 4),
            notaTope,
            nota("Al grabar desde el menú, el icono o ⌃⌥⌘R. La terminal sigue con su argumento (grabar-pantalla [segundos], 15 s si no se da)."),
        ])
        filas.append([etiqueta("Duración:"), duracion])
        separador()

        // Puntero y clics.
        checkPuntero.target = self
        checkPuntero.action = #selector(cambiarCasilla(_:))
        checkPuntero.identifier = NSUserInterfaceItemIdentifier(Clave.mostrarPuntero)
        checkClics.target = self
        checkClics.action = #selector(cambiarCasilla(_:))
        checkClics.identifier = NSUserInterfaceItemIdentifier(Clave.marcarClics)
        var puntero: [NSView] = [checkPuntero, checkClics]
        if !hayMacOS15() { puntero.append(sangrada(nota("Marcar los clics necesita macOS 15.", sangria: 20))) }
        filas.append([etiqueta("Puntero:"), pila(puntero)])

        // Audio.
        menuAudio.removeAllItems()
        menuAudio.autoenablesItems = false
        for a in Audio.allCases {
            menuAudio.addItem(withTitle: a.nombre)
            menuAudio.lastItem?.representedObject = a.rawValue
            menuAudio.lastItem?.isEnabled = !a.microfono || hayMacOS15()
        }
        menuAudio.target = self
        menuAudio.action = #selector(cambiarAudio(_:))
        menuAudio.setAccessibilityLabel("Audio")
        filas.append([etiqueta("Audio:"), pila([menuAudio, nota("", notaAudio)])])
        separador()

        // Al terminar.
        for (c, k) in [(checkNotificar, Clave.notificar), (checkSonido, Clave.sonido), (checkFinder, Clave.abrirEnFinder), (checkCopiar, Clave.copiarRuta)] {
            c.target = self
            c.action = #selector(cambiarCasilla(_:))
            c.identifier = NSUserInterfaceItemIdentifier(k)
        }
        filas.append([etiqueta("Al terminar:"), pila([checkNotificar, checkSonido, checkFinder, checkCopiar])])
        separador()

        // Inicio de sesión.
        checkLogin.target = self
        checkLogin.action = #selector(cambiarLogin(_:))
        botonAprobar.target = self
        botonAprobar.action = #selector(abrirItemsDeInicio)
        errorLogin.textColor = .systemRed
        errorLogin.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLogin.preferredMaxLayoutWidth = anchoControles - 20
        errorLogin.isHidden = true
        let login = pila([checkLogin, sangrada(pila([nota("", estadoLogin, sangria: 20), errorLogin, botonAprobar], espacio: 4))], espacio: 2)
        filas.append([etiqueta("Inicio de sesión:"), login])

        // Atajo (informativo).
        let atajo = NSTextField(wrappingLabelWithString: "⌃⌥⌘R empieza y detiene la grabación desde cualquier app.")
        atajo.preferredMaxLayoutWidth = anchoControles
        atajo.isSelectable = true
        filas.append([etiqueta("Atajo:"), atajo])

        let rejilla = NSGridView(views: filas)
        rejilla.rowSpacing = 14
        rejilla.columnSpacing = 10
        rejilla.column(at: 0).xPlacement = .trailing
        rejilla.column(at: 1).xPlacement = .leading
        rejilla.column(at: 1).width = anchoControles
        rejilla.rowAlignment = .firstBaseline
        for i in separadores {
            rejilla.row(at: i).mergeCells(in: NSRange(location: 0, length: 2))
            rejilla.row(at: i).topPadding = 0
            rejilla.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .fill
        }

        let pie = nota("Los cambios se guardan al momento y valen desde la próxima grabación, también la de la terminal.")
        let todo = pila([aviso, rejilla, pie], espacio: 16)
        todo.alignment = .centerX
        todo.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        todo.translatesAutoresizingMaskIntoConstraints = false
        contenido.addSubview(todo)
        NSLayoutConstraint.activate([
            todo.leadingAnchor.constraint(equalTo: contenido.leadingAnchor),
            todo.trailingAnchor.constraint(equalTo: contenido.trailingAnchor),
            todo.topAnchor.constraint(equalTo: contenido.topAnchor),
            todo.bottomAnchor.constraint(equalTo: contenido.bottomAnchor),
        ])
    }

    // MARK: Estado de los controles

    /// Pone cada control con lo guardado y el estado real del sistema (login, permiso de micrófono).
    private func recargar() {
        let a = Ajustes.leer(d)
        // Carpeta: la guardada, aunque no exista; el aviso dice qué pasará.
        rutaCarpeta.stringValue = abreviar(a.carpeta.path)
        rutaCarpeta.toolTip = a.carpeta.path
        if let p = problemaCarpeta(a.carpeta) {
            avisoCarpeta.stringValue = a.carpetaEsLaDePorDefecto ? "La carpeta \(p); se creará al grabar." : "Esta carpeta \(p): mientras siga así, se guarda en ~/Movies."
            filaAvisoCarpeta.isHidden = false
        } else {
            filaAvisoCarpeta.isHidden = true
        }
        botonPorDefecto.isHidden = a.carpetaEsLaDePorDefecto
        for r in radiosCalidad { r.state = r.identifier?.rawValue == a.calidad.rawValue ? .on : .off }
        campoCuenta.integerValue = a.cuentaAtras
        pasoCuenta.integerValue = a.cuentaAtras
        radioHastaDetener.state = a.duracion == 0 ? .on : .off
        radioDurante.state = a.duracion == 0 ? .off : .on
        // Con «Hasta Detener», el campo propone 15 s, lo mismo que la terminal.
        let n = a.duracion == 0 ? 15 : a.duracion
        campoDuracion.integerValue = n
        pasoDuracion.integerValue = n
        checkPuntero.state = a.mostrarPuntero ? .on : .off
        checkClics.state = a.marcarClics && hayMacOS15() ? .on : .off
        menuAudio.selectItem(at: Audio.allCases.firstIndex(of: a.audio) ?? 0)
        checkNotificar.state = a.notificar ? .on : .off
        checkSonido.state = a.sonido ? .on : .off
        checkFinder.state = a.abrirEnFinder ? .on : .off
        checkCopiar.state = a.copiarRuta ? .on : .off
        explicarAudio(a.audio)
        recargarLogin()
        habilitar()
    }

    private func habilitar() {
        let libre = !bloqueada
        aviso.isHidden = libre
        for c: NSControl in [radioHastaDetener, radioDurante, campoCuenta, pasoCuenta, checkPuntero, menuAudio,
                             checkNotificar, checkSonido, checkFinder, checkCopiar, checkLogin, botonAprobar,
                             botonElegir, botonPorDefecto] {
            c.isEnabled = libre
        }
        for r in radiosCalidad { r.isEnabled = libre }
        checkClics.isEnabled = libre && hayMacOS15()
        let durante = radioDurante.state == .on
        campoDuracion.isEnabled = libre && durante
        pasoDuracion.isEnabled = libre && durante
    }

    /// Texto bajo el menú de audio: qué se graba y, con micrófono, si hay permiso o no.
    private func explicarAudio(_ a: Audio) {
        var t: [String] = []
        if !hayMacOS15() { t.append("El micrófono necesita macOS 15.") }
        switch a {
        case .ninguno: t.append("El vídeo sale sin pista de audio.")
        case .sistema: t.append("Lo que suena en el Mac, salvo esta app.")
        case .microfono: t.append("El micrófono por defecto del sistema.")
        case .sistemaYMicrofono:
            t.append("Dos pistas de audio en el mp4: sistema y micrófono. QuickTime las reproduce juntas; algunos reproductores, solo la primera.")
        }
        if a.microfono, hayMacOS15() {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined: t.append("macOS pedirá permiso de micrófono al empezar la primera grabación con micrófono.")
            default: t.append("Sin permiso de micrófono: actívalo en Ajustes del Sistema > Privacidad y seguridad > Micrófono. Mientras, se graba sin él.")
            }
        }
        notaAudio.stringValue = t.joined(separator: " ")
    }

    private func recargarLogin() {
        let st = SMAppService.mainApp.status
        checkLogin.state = st == .enabled || st == .requiresApproval ? .on : .off
        botonAprobar.isHidden = st != .requiresApproval
        switch st {
        case .enabled: estadoLogin.stringValue = "Activado en macOS. Al iniciar sesión queda en espera en la barra de menús, sin grabar."
        case .requiresApproval: estadoLogin.stringValue = "Pendiente de tu aprobación en Ajustes del Sistema > General > Ítems de inicio de sesión."
        // Sin registrar nunca, macOS da `notFound` en vez de `notRegistered`: para quien mira, lo mismo.
        case .notRegistered, .notFound: estadoLogin.stringValue = "Desactivado. Si lo activas, al iniciar sesión queda en espera, sin grabar."
        @unknown default: estadoLogin.stringValue = "Estado desconocido (\(st.rawValue))."
        }
    }

    // MARK: Acciones

    @objc private func elegirCarpeta() {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"
        panel.message = "Carpeta donde se guardan las grabaciones"
        let actual = Ajustes.leer(d).carpeta
        panel.directoryURL = problemaCarpeta(actual) == nil ? actual : Ajustes.carpetaPorDefecto
        panel.beginSheetModal(for: w) { [self] r in
            guard r == .OK, let url = panel.url else { return }
            if url.standardizedFileURL.path == Ajustes.carpetaPorDefecto.standardizedFileURL.path {
                d.removeObject(forKey: Clave.carpeta)
            } else {
                d.set(url.path, forKey: Clave.carpeta)
            }
            recargar()
        }
    }

    @objc private func carpetaPorDefecto() {
        d.removeObject(forKey: Clave.carpeta)
        recargar()
    }

    @objc private func cambiarCalidad(_ b: NSButton) {
        guard let v = b.identifier?.rawValue else { return }
        d.set(v, forKey: Clave.calidad)
        recargar()
    }

    /// Lee un número del campo o del paso, lo deja dentro de [minimo, maximo] y avisa si lo recortó.
    private func numero(_ origen: Any, campo: NSTextField, paso: NSStepper) -> (valor: Int, recortado: Bool) {
        let bruto: Int
        if let p = origen as? NSStepper { bruto = p.integerValue } else { bruto = Int(campo.stringValue.trimmingCharacters(in: .whitespaces)) ?? Int(paso.minValue) }
        let v = min(max(bruto, Int(paso.minValue)), Int(paso.maxValue))
        campo.integerValue = v
        paso.integerValue = v
        return (v, v != bruto)
    }

    @objc private func cambiarCuenta(_ s: Any) {
        let (v, recortado) = numero(s, campo: campoCuenta, paso: pasoCuenta)
        if recortado { NSSound.beep() }
        d.set(v, forKey: Clave.cuentaAtras)
    }

    @objc private func cambiarModoDuracion(_ b: NSButton) {
        radioHastaDetener.state = b === radioHastaDetener ? .on : .off
        radioDurante.state = b === radioDurante ? .on : .off
        notaTope.isHidden = true
        d.set(radioDurante.state == .on ? campoDuracion.integerValue : 0, forKey: Clave.duracion)
        habilitar()
        if radioDurante.state == .on { window?.makeFirstResponder(campoDuracion) }
    }

    @objc private func cambiarDuracion(_ s: Any) {
        guard radioDurante.state == .on else { return }
        let (v, recortado) = numero(s, campo: campoDuracion, paso: pasoDuracion)
        notaTope.stringValue = "Como mucho \(Ajustes.duracionMaxima) s: el tope de seguridad de 30 min."
        notaTope.isHidden = !recortado || v != Ajustes.duracionMaxima
        if recortado { NSSound.beep() }
        d.set(v, forKey: Clave.duracion)
    }

    @objc private func cambiarCasilla(_ b: NSButton) {
        guard let k = b.identifier?.rawValue else { return }
        d.set(b.state == .on, forKey: k)
    }

    @objc private func cambiarAudio(_ p: NSPopUpButton) {
        guard let v = p.selectedItem?.representedObject as? String, let a = Audio(rawValue: v) else { return }
        d.set(v, forKey: Clave.audio)
        explicarAudio(a)
    }

    /// `SMAppService.mainApp`: register/unregister y el estado real que da macOS. Si falla, el error
    /// queda en rojo bajo la casilla y la casilla vuelve a lo que diga macOS.
    @objc private func cambiarLogin(_ b: NSButton) {
        let activar = b.state == .on
        errorLogin.isHidden = true
        do {
            if activar { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorLogin.stringValue = "No se pudo \(activar ? "activar" : "desactivar"): \(error.localizedDescription)"
            errorLogin.isHidden = false
        }
        recargarLogin()
        habilitar()
    }

    @objc private func abrirItemsDeInicio() { SMAppService.openSystemSettingsLoginItems() }
}

private extension NSBox {
    static func separador() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}

// Grabar una región de la pantalla: el selector con el que se elige y el marco que la señala
// mientras se graba. El selector es como el de ⌘⇧5: oscurece todas las pantallas, cursor en cruz,
// arrastrar dibuja el rectángulo con sus medidas en píxeles, Esc o clic derecho cancela y soltar
// confirma. El marco es una ventana de la propia app, así que el filtro de la captura (que deja
// fuera todas sus ventanas) no la graba; tampoco recibe clics.
//
// Coordenadas: AppKit da rectángulos globales con el origen abajo a la izquierda de la pantalla
// principal; ScreenCaptureKit (`sourceRect`) y `grabar-pantalla --region` usan puntos relativos a
// la esquina superior izquierda de la pantalla que se graba. `regionLocal` y `regionGlobal` pasan
// de una a otra.
import AppKit
import Carbon.HIToolbox

/// Lado mínimo, en píxeles, de una región elegida con el ratón: menos (un clic suelto, un arrastre
/// sin querer) se trata como cancelar.
let ladoMinimoRegion = 32

/// Identificador de pantalla de `s` (el de CGGetActiveDisplayList y ScreenCaptureKit).
func idDe(_ s: NSScreen) -> CGDirectDisplayID {
    (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

/// Píxeles por punto de la pantalla `id` en su modo actual (2 en la integrada Retina, 1 en una
/// externa a 1080p): la misma cuenta con la que la captura de la pantalla entera elige su resolución.
func escala(de id: CGDirectDisplayID) -> CGFloat {
    guard let m = CGDisplayCopyDisplayMode(id), m.width > 0 else { return 1 }
    return CGFloat(m.pixelWidth) / CGFloat(m.width)
}

/// `r` (puntos, relativa a la esquina superior izquierda de su pantalla) ajustada a la rejilla de
/// píxeles de escala `k`, con ancho y alto pares en píxeles (H.264 4:2:0 los pide) y dentro de
/// `limite` (el tamaño de la pantalla en puntos). Ancho y alto se redondean hacia abajo: lo grabado
/// nunca pasa de lo pedido.
func ajustarRegion(_ r: CGRect, escala k: CGFloat, limite: CGSize) -> CGRect {
    let maxX = (limite.width * k).rounded(.down), maxY = (limite.height * k).rounded(.down)
    let x = min(max((r.minX * k).rounded(), 0), maxX), y = min(max((r.minY * k).rounded(), 0), maxY)
    let w = CGFloat(Int(min((r.width * k).rounded(.down), maxX - x)) & ~1)
    let h = CGFloat(Int(min((r.height * k).rounded(.down), maxY - y)) & ~1)
    return CGRect(x: x / k, y: y / k, width: w / k, height: h / k)
}

/// Rectángulo global de AppKit → puntos relativos a la esquina superior izquierda de `pantalla`.
func regionLocal(_ global: NSRect, en pantalla: NSScreen) -> CGRect {
    let f = pantalla.frame
    return CGRect(x: global.minX - f.minX, y: f.maxY - global.maxY, width: global.width, height: global.height)
}

/// Puntos relativos a la esquina superior izquierda de `pantalla` → rectángulo global de AppKit.
func regionGlobal(_ local: CGRect, en pantalla: NSScreen) -> NSRect {
    let f = pantalla.frame
    return NSRect(x: f.minX + local.minX, y: f.maxY - local.maxY, width: local.width, height: local.height)
}

// MARK: - Selector

/// Selector de región a pantalla completa, una ventana por pantalla. El rectángulo queda dentro de
/// la pantalla donde empezó el arrastre y se enseña ya ajustado a lo que se va a grabar (píxeles
/// pares), con esas medidas al lado. Para recibir Esc la app se pone delante mientras está abierto;
/// al cerrarse devuelve el foco a la app que lo tenía, que suele ser la que se quiere grabar.
final class SelectorRegion {
    /// Al soltar con un rectángulo válido: la pantalla y la región en puntos locales, ya ajustada.
    var alElegir: (NSScreen, CGRect) -> Void = { _, _ in }
    /// Esc, clic derecho o un rectángulo de menos de `ladoMinimoRegion` píxeles.
    var alCancelar: () -> Void = {}

    private var ventanas: [NSWindow] = []
    private var vistas: [VistaSelector] = []
    private var anterior: NSRunningApplication?
    /// Arrastre en curso: pantalla donde empezó y los dos extremos, en coordenadas globales.
    private var arrastre: (pantalla: NSScreen, desde: NSPoint, hasta: NSPoint)?

    func abrir() {
        let frente = NSWorkspace.shared.frontmostApplication
        anterior = frente?.processIdentifier == getpid() ? nil : frente
        for s in NSScreen.screens {
            let v = VentanaSelector(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            v.setFrame(s.frame, display: false)
            // Por encima de la barra de menús y del Dock, como el selector del sistema.
            v.level = .screenSaver
            v.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            v.isOpaque = false
            v.backgroundColor = .clear
            v.hasShadow = false
            // Explícito: sin esto el servidor de ventanas deja pasar los clics por lo transparente.
            v.ignoresMouseEvents = false
            v.acceptsMouseMovedEvents = true
            v.isReleasedWhenClosed = false
            let vista = VistaSelector(pantalla: s, selector: self)
            vista.frame = NSRect(origin: .zero, size: s.frame.size)
            v.contentView = vista
            v.initialFirstResponder = vista
            ventanas.append(v)
            vistas.append(vista)
        }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let raton = NSEvent.mouseLocation
        for v in ventanas { v.orderFrontRegardless() }
        (ventanas.first { NSMouseInRect(raton, $0.frame, false) } ?? ventanas.first)?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    /// Cierra sin avisar (lo usa también el controlador si empieza otra grabación con el selector
    /// abierto, por el atajo).
    func cerrar() {
        guard !ventanas.isEmpty else { return }
        for v in ventanas { v.orderOut(nil) }
        ventanas = []
        vistas = []
        arrastre = nil
        NSCursor.arrow.set()
        if let a = anterior {
            if #available(macOS 14.0, *) { a.activate() } else { a.activate(options: []) }
        }
        anterior = nil
    }

    func cancelar() {
        cerrar()
        alCancelar()
    }

    func empezar(en pantalla: NSScreen, _ p: NSPoint) {
        arrastre = (pantalla, p, p)
        redibujar()
    }

    /// El extremo sigue al ratón, pero sin salir de la pantalla donde empezó.
    func mover(_ p: NSPoint) {
        guard let a = arrastre else { return }
        let f = a.pantalla.frame
        arrastre?.hasta = NSPoint(x: min(max(p.x, f.minX), f.maxX), y: min(max(p.y, f.minY), f.maxY))
        redibujar()
    }

    func soltar() {
        guard let s = seleccion() else { cancelar(); return }
        guard s.pixeles.ancho >= ladoMinimoRegion, s.pixeles.alto >= ladoMinimoRegion else { cancelar(); return }
        cerrar()
        alElegir(s.pantalla, s.local)
    }

    /// Lo que se grabaría ahora: la pantalla, la región en puntos locales y global (ya ajustada) y
    /// su tamaño en píxeles. nil sin arrastre.
    func seleccion() -> (pantalla: NSScreen, local: CGRect, global: NSRect, pixeles: (ancho: Int, alto: Int))? {
        guard let a = arrastre else { return nil }
        let bruto = NSRect(x: min(a.desde.x, a.hasta.x), y: min(a.desde.y, a.hasta.y),
                           width: abs(a.desde.x - a.hasta.x), height: abs(a.desde.y - a.hasta.y))
        let k = escala(de: idDe(a.pantalla))
        let local = ajustarRegion(regionLocal(bruto, en: a.pantalla), escala: k, limite: a.pantalla.frame.size)
        return (a.pantalla, local, regionGlobal(local, en: a.pantalla),
                (Int((local.width * k).rounded()), Int((local.height * k).rounded())))
    }

    private func redibujar() { for v in vistas { v.needsDisplay = true } }
}

/// Las ventanas sin borde no pasan a ser la ventana activa salvo que lo digan: sin esto no llega Esc.
private final class VentanaSelector: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Lo que se ve en cada pantalla: el velo oscuro, el hueco del rectángulo con su borde y sus medidas
/// y, antes de arrastrar, una pista en el centro. Recoge el ratón y el teclado para el selector.
final class VistaSelector: NSView {
    let pantalla: NSScreen
    weak var selector: SelectorRegion?

    init(pantalla: NSScreen, selector: SelectorRegion) {
        self.pantalla = pantalla
        self.selector = selector
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("sin storyboard") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    /// Punto del evento en coordenadas globales.
    private func global(_ e: NSEvent) -> NSPoint {
        guard let w = e.window else { return NSEvent.mouseLocation }
        return w.convertToScreen(NSRect(origin: e.locationInWindow, size: .zero)).origin
    }

    override func mouseDown(with event: NSEvent) { selector?.empezar(en: pantalla, global(event)) }
    override func mouseDragged(with event: NSEvent) { selector?.mover(global(event)) }
    override func mouseUp(with event: NSEvent) {
        selector?.mover(global(event))
        selector?.soltar()
    }
    override func rightMouseDown(with event: NSEvent) { selector?.cancelar() }
    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { selector?.cancelar() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        guard let selector else { return }
        guard let s = selector.seleccion(), s.pantalla == pantalla else {
            if selector.seleccion() == nil {
                chip("Arrastra para elegir la región. Esc o clic derecho: cancelar.", tamano: 14,
                     en: { t in NSPoint(x: (self.bounds.width - t.width) / 2, y: (self.bounds.height - t.height) / 2) })
            }
            return
        }
        // La ventana ocupa la pantalla entera: su origen es el de la pantalla.
        let r = s.global.offsetBy(dx: -pantalla.frame.minX, dy: -pantalla.frame.minY)
        guard r.width > 0, r.height > 0 else { return }
        NSColor.clear.setFill()
        r.fill(using: .copy)
        let borde = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        borde.lineWidth = 1
        NSColor.white.setStroke()
        borde.stroke()
        // Medidas debajo de la esquina inferior derecha; si no caben, dentro del rectángulo.
        chip("\(s.pixeles.ancho) × \(s.pixeles.alto)", tamano: 12) { t in
            let x = min(max(r.maxX - t.width, 4), self.bounds.width - t.width - 4)
            let y = r.minY - t.height - 6 >= 4 ? r.minY - t.height - 6 : r.minY + 6
            return NSPoint(x: x, y: y)
        }
    }

    /// Texto blanco sobre una píldora oscura, en el origen que diga `en` según su tamaño. Igual en
    /// modo claro y oscuro: va sobre el velo, que siempre es oscuro.
    private func chip(_ texto: String, tamano: CGFloat, en: (NSSize) -> NSPoint) {
        let atributos: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: tamano, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let t = (texto as NSString).size(withAttributes: atributos)
        let caja = NSSize(width: t.width + tamano, height: t.height + tamano * 0.5)
        let o = en(caja)
        let fondo = NSRect(origin: o, size: caja)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: fondo, xRadius: caja.height / 2, yRadius: caja.height / 2).fill()
        (texto as NSString).draw(at: NSPoint(x: o.x + tamano / 2, y: o.y + tamano * 0.25), withAttributes: atributos)
    }
}

// MARK: - Marco

/// Marco fino alrededor de la región mientras se graba (desde la cuenta atrás hasta acabar). Va a
/// caballo del borde, 1 punto fuera y 1 dentro: si la ventana entrara en el vídeo se vería en sus
/// bordes, y así se comprueba en los fotogramas que el filtro la deja fuera. No recibe clics.
final class MarcoRegion {
    private let ventana: NSWindow

    /// `global`: la región en coordenadas globales de AppKit.
    init(region global: NSRect) {
        let marco = global.insetBy(dx: -1, dy: -1)
        ventana = NSWindow(contentRect: marco, styleMask: .borderless, backing: .buffered, defer: false)
        ventana.setFrame(marco, display: false)
        ventana.level = .statusBar
        ventana.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ventana.isOpaque = false
        ventana.backgroundColor = .clear
        ventana.hasShadow = false
        ventana.ignoresMouseEvents = true
        ventana.isReleasedWhenClosed = false
        ventana.contentView = VistaMarco(frame: NSRect(origin: .zero, size: marco.size))
    }

    func mostrar() { ventana.orderFrontRegardless() }
    func cerrar() { ventana.orderOut(nil) }
}

private final class VistaMarco: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        p.lineWidth = 2
        NSColor.systemRed.setStroke()
        p.stroke()
    }
}

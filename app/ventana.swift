// Grabar una sola ventana de otra app: qué ventanas se ofrecen (el submenú «Grabar una ventana» y
// `grabar-pantalla --ventana`), su nombre «App: título», la búsqueda por texto y la pantalla donde
// está. La captura en sí es `SCContentFilter(desktopIndependentWindow:)` en `Grabador` (main.swift),
// que graba la ventana aunque otra la tape.
//
// Coordenadas: el marco de una ventana de ScreenCaptureKit está en puntos globales con el origen
// arriba a la izquierda de la pantalla principal, igual que `CGDisplayBounds`.
import AppKit
import ScreenCaptureKit

/// Lado mínimo, en puntos, de una ventana que se ofrece: lo más pequeño son paletas, tiradores o
/// ventanas auxiliares que nadie quiere grabar.
let ladoMinimoVentana: CGFloat = 50
/// Caracteres del título que se enseñan; el resto se corta con «…».
let largoMaximoTitulo = 60

/// Una ventana que se puede grabar.
struct VentanaGrabable {
    let id: CGWindowID
    let app: String
    let titulo: String
    /// Marco en puntos globales (origen arriba a la izquierda de la pantalla principal).
    let marco: CGRect
    /// «App: título», con el título recortado: lo que enseña el menú y en lo que busca `--ventana`.
    var nombre: String { "\(app): \(recortarTitulo(titulo))" }
}

/// Lo que se mira de una ventana para decidir si se ofrece. Sale de `SCWindow`, pero aparte para que
/// el filtro se pueda probar con ventanas inventadas.
struct CandidataVentana {
    var id: CGWindowID
    var app: String?
    var bundle: String?
    var pid: pid_t
    var titulo: String?
    var capa: Int
    var marco: CGRect
    var enPantalla: Bool

    init(id: CGWindowID, app: String?, bundle: String?, pid: pid_t, titulo: String?, capa: Int, marco: CGRect, enPantalla: Bool = true) {
        self.id = id
        self.app = app
        self.bundle = bundle
        self.pid = pid
        self.titulo = titulo
        self.capa = capa
        self.marco = marco
        self.enPantalla = enPantalla
    }

    init(_ w: SCWindow) {
        self.init(id: w.windowID, app: w.owningApplication?.applicationName, bundle: w.owningApplication?.bundleIdentifier,
                  pid: w.owningApplication?.processID ?? 0, titulo: w.title, capa: w.windowLayer, marco: w.frame, enPantalla: w.isOnScreen)
    }
}

/// El título en una línea y como mucho `largoMaximoTitulo` caracteres.
func recortarTitulo(_ t: String) -> String {
    let linea = t.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return linea.count > largoMaximoTitulo ? String(linea.prefix(largoMaximoTitulo - 1)) + "…" : linea
}

/// Las que se ofrecen: en pantalla, de la capa normal (0; las barras, menús y avisos van en otras),
/// de otras apps (ni esta ni la otra instancia, residente o de terminal: mismo identificador), con
/// título y de al menos `ladoMinimoVentana` de lado. Ordenadas por nombre de app y, dentro de una app,
/// en el orden en que las da el sistema.
func ventanasGrabables(_ candidatas: [CandidataVentana], bundlePropio: String?, pidPropio: pid_t) -> [VentanaGrabable] {
    candidatas.enumerated().compactMap { i, c -> (Int, VentanaGrabable)? in
        guard c.enPantalla, c.capa == 0, c.pid != pidPropio, bundlePropio == nil || c.bundle != bundlePropio,
              let app = c.app?.trimmingCharacters(in: .whitespaces), !app.isEmpty,
              let titulo = c.titulo?.trimmingCharacters(in: .whitespacesAndNewlines), !titulo.isEmpty,
              c.marco.width >= ladoMinimoVentana, c.marco.height >= ladoMinimoVentana else { return nil }
        return (i, VentanaGrabable(id: c.id, app: app, titulo: titulo, marco: c.marco))
    }
    .sorted { a, b in
        let orden = a.1.app.localizedStandardCompare(b.1.app)
        return orden == .orderedSame ? a.0 < b.0 : orden == .orderedAscending
    }
    .map(\.1)
}

/// Las ventanas que se ofrecen ahora mismo, de ScreenCaptureKit. Espera la respuesta hasta `espera`
/// segundos bloqueando el hilo que llama (el del menú: tiene que estar relleno antes de enseñarse; la
/// respuesta llega en otra cola y suele tardar unas decenas de ms). Sin permiso de Grabación de
/// pantalla o sin respuesta, el motivo.
func leerVentanas(espera: Double = 2) -> Result<[VentanaGrabable], ErrorVentanas> {
    let listo = DispatchSemaphore(value: 0)
    var resultado = Result<[VentanaGrabable], ErrorVentanas>.failure(.sinRespuesta)
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { contenido, error in
        if let contenido {
            resultado = .success(ventanasGrabables(contenido.windows.map(CandidataVentana.init),
                                                   bundlePropio: Bundle.main.bundleIdentifier, pidPropio: getpid()))
        } else {
            resultado = .failure(.fallo(error?.localizedDescription ?? "error desconocido"))
        }
        listo.signal()
    }
    guard listo.wait(timeout: .now() + espera) == .success else { return .failure(.sinRespuesta) }
    return resultado
}

/// Por qué no hay lista de ventanas.
enum ErrorVentanas: Error {
    case sinRespuesta
    case fallo(String)

    var texto: String {
        switch self {
        case .sinRespuesta: return "No puedo leer las ventanas: ScreenCaptureKit no responde"
        case .fallo(let m): return "No puedo leer las ventanas (¿falta el permiso de Grabación de pantalla?): \(m)"
        }
    }
}

/// La primera de `ventanas` cuyo «App: título» contiene `texto` sin distinguir mayúsculas ni tildes.
/// Se busca en el título entero, no solo en lo que cabe en el menú.
func buscarVentana(_ texto: String, en ventanas: [VentanaGrabable]) -> VentanaGrabable? {
    let t = texto.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    return ventanas.first { "\($0.app): \($0.titulo)".range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
}

/// Pantalla donde está una ventana: la que tiene más superficie de ella (una ventana a caballo entre
/// dos se graba a la escala de esa). nil si no toca ninguna.
func pantallaDe(_ marco: CGRect, entre ids: [CGDirectDisplayID]) -> CGDirectDisplayID? {
    let area = { (r: CGRect) in r.isNull ? 0 : r.width * r.height }
    return ids.map { ($0, area(CGDisplayBounds($0).intersection(marco))) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
}

/// Tamaño del vídeo de una ventana: su marco al empezar por la escala de su pantalla, en píxeles
/// enteros y pares (H.264 4:2:0).
func pixelesDeVentana(_ tamano: CGSize, escala k: CGFloat) -> (ancho: Int, alto: Int) {
    (Int((tamano.width * k).rounded()) & ~1, Int((tamano.height * k).rounded()) & ~1)
}

/// Rellena el submenú «Grabar una ventana»: una entrada por ventana con `accion` en `destino` y la
/// `VentanaGrabable` en `representedObject`; sin ventanas o sin lista, una fila deshabilitada que lo dice.
func rellenarMenuVentanas(_ menu: NSMenu, con lista: Result<[VentanaGrabable], ErrorVentanas>, destino: AnyObject, accion: Selector) {
    menu.removeAllItems()
    func fila(_ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }
    switch lista {
    case .failure(let e):
        fila(e.texto)
    case .success(let ventanas) where ventanas.isEmpty:
        fila("No hay ventanas de otras apps")
    case .success(let ventanas):
        for v in ventanas {
            let i = NSMenuItem(title: v.nombre, action: accion, keyEquivalent: "")
            i.target = destino
            i.representedObject = v
            menu.addItem(i)
        }
    }
}

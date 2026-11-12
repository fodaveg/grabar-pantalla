// Grabar pantalla: app de barra de menús que graba una pantalla del Mac. La captura es
// ScreenCaptureKit (`SCStream` de la pantalla elegida, sin la propia app) y la escritura,
// `AVAssetWriter` (mp4, H.264 por hardware y audio AAC), todo en este proceso: no hay ffmpeg ni
// script hijo. Deja el vídeo en la carpeta de los Ajustes (por defecto ~/Movies) como
// pantalla-AAAAMMDD-HHMMSS.mp4.
//
// Dos modos, según los argumentos:
// - Residente (sin argumentos: LaunchServices desde Spotlight, Finder, `open` o el inicio de
//   sesión): se queda en la barra de menús en espera y graba una vez por petición, hasta Detener
//   (tope de 30 min) o los segundos de los Ajustes. Abierta normalmente graba al instante; como
//   ítem de inicio de sesión queda en espera. Registra el atajo global y tiene la ventana de Ajustes.
// - Terminal (con argumentos, que pone el script `grabar-pantalla [--region X,Y,ANCHO,ALTO |
//   --ventana TEXTO] [segundos]` al hacer exec): proceso propio de un solo uso. Graba, imprime el
//   resultado y sale con 0 si hay vídeo válido. No toca la residente, pero lee los mismos Ajustes
//   (salvo la duración, que es su argumento).
//
// Qué se graba (la pantalla entera, una región o una ventana de otra app) es un `Destino`; el
// selector de región y el marco que la señala están en region.swift, y la lista de ventanas que se
// ofrecen, en ventana.swift.
//
// Los Ajustes (UserDefaults y ventana) están en ajustes.swift; se leen al empezar cada grabación.
// La memoria de los últimos N segundos (experimento: grabar en segundo plano y guardar bajo
// demanda), en memoria.swift; vive solo en la residente, y en la prueba de
// GRABAR_PANTALLA_PRUEBA_MEMORIA.
import AppKit
import AVFoundation
import Carbon.HIToolbox
import os
import ScreenCaptureKit
import UserNotifications
import VideoToolbox

// MARK: - Arranque

/// Ruta del script `grabar-pantalla` del repo (la pone instalar.sh). Solo sirve para encontrar
/// `fotogramas`, que vive a su lado.
let script = Bundle.main.object(forInfoDictionaryKey: "GrabarPantallaScript") as? String ?? ""
/// Argumentos de la terminal. LaunchServices puede añadir `-psn_…`, y AppKit acepta pares
/// `-NSClave valor` o `-AppleClave valor` (p. ej. `-AppleInterfaceStyle Dark`): ni la opción ni su
/// valor son de la terminal.
let argsTerminal: [String] = {
    var r: [String] = []
    var saltarValor = false
    for a in CommandLine.arguments.dropFirst() {
        if saltarValor { saltarValor = false; continue }
        if a.hasPrefix("-psn_") { continue }
        if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { saltarValor = true; continue }
        r.append(a)
    }
    return r
}()
/// La prueba de la memoria (GRABAR_PANTALLA_PRUEBA_MEMORIA) no es residente: no registra atajos,
/// sale al acabar e ignora los argumentos.
let residente = argsTerminal.isEmpty && pruebaMemoria == nil

/// Calidad de la captura y del vídeo, la que se elige en Ajustes. H.264 en las tres: HEVC pesa menos
/// a igual calidad, pero un vídeo para adjuntar tiene que abrirse en cualquier navegador y sistema.
/// Los fps son los pedidos (`minimumFrameInterval` = 1/fps): ScreenCaptureKit solo entrega cuando
/// cambia algo y como mucho al refresco de la pantalla, así que el vídeo sale con fps variable y las
/// marcas de tiempo de la captura. El peso por minuto lo enseña la ventana: es lo medido en dos
/// tandas de 15 s de la pantalla integrada con una animación en una esquina y el escritorio en uso
/// (README).
enum Calidad: String, CaseIterable {
    case compacta, normal, animaciones

    var nombre: String {
        switch self {
        case .compacta: return "Compacta"
        case .normal: return "Normal"
        case .animaciones: return "Animaciones"
        }
    }

    /// fps pedidos en la pantalla `id`. Animaciones pide todos los que dé: su refresco máximo (120
    /// en la integrada con ProMotion, 75 en una externa a 75 Hz).
    func fps(pantalla id: CGDirectDisplayID) -> Int32 {
        switch self {
        case .compacta: return 30
        case .normal: return 60
        case .animaciones: return Int32(refrescoMaximo(id))
        }
    }

    /// Bitrate medio de H.264 en bits/s. Es un objetivo, no un límite estricto: con poco movimiento
    /// sale mucho menos y en 15 s con mucho detalle puede pasarse algo (Compacta midió 2,9 Mb/s).
    var bitrate: Int {
        switch self {
        case .compacta: return 2_000_000
        case .normal: return 12_000_000
        case .animaciones: return 40_000_000
        }
    }

    /// Lo que pesa un minuto con movimiento en pantalla (medido; ver arriba).
    var pesoPorMinuto: String {
        switch self {
        case .compacta: return "≈ 17-22 MB por minuto"
        case .normal: return "≈ 52-73 MB por minuto"
        case .animaciones: return "≈ 110-210 MB por minuto"
        }
    }

    /// Una línea para la ventana: fps, peso y para qué sirve.
    var descripcion: String {
        switch self {
        case .compacta: return "30 fps, \(pesoPorMinuto). Para adjuntar."
        case .normal: return "60 fps, \(pesoPorMinuto)."
        case .animaciones: return "Todos los fps de la pantalla (120 en la integrada), \(pesoPorMinuto). Para revisar animaciones."
        }
    }
}
/// Tope de seguridad de «hasta Detener» (residente, o `grabar-pantalla 0`) y de la duración de los
/// Ajustes. No se ajusta.
let topeSegundos: Double = 30 * 60
let mensajePermiso = "La captura no arranca. Revisa Ajustes del Sistema > Privacidad y seguridad > Grabación de pantalla y audio del sistema: «Grabar pantalla» debe estar activado"

/// Salida para la terminal (en la residente va a donde la deje LaunchServices). Sin búfer, para
/// que «GRABANDO» salga en su momento.
func decir(_ t: String) { FileHandle.standardOutput.write(Data((t + "\n").utf8)) }
func avisar(_ t: String) { FileHandle.standardError.write(Data((t + "\n").utf8)) }

/// Las pantallas en el orden de CGGetActiveDisplayList (0 = la principal de Ajustes > Pantallas).
/// Es el mismo orden que numeraba ffmpeg con «Capture screen N», así que GRABAR_PANTALLA_INDICE
/// conserva su significado.
func pantallasEnOrden() -> [(id: CGDirectDisplayID, pantalla: NSScreen)] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).compactMap { id in
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }.map { (id, $0) }
    }
}

/// Refresco máximo de la pantalla `id` en Hz: el de ProMotion (`maximumFramesPerSecond`) o, si
/// AppKit no la conoce, el del modo actual; 60 si nadie lo sabe.
func refrescoMaximo(_ id: CGDirectDisplayID) -> Int {
    if let p = pantallasEnOrden().first(where: { $0.id == id })?.pantalla, p.maximumFramesPerSecond > 0 { return p.maximumFramesPerSecond }
    if let hz = CGDisplayCopyDisplayMode(id)?.refreshRate, hz > 0 { return Int(hz.rounded()) }
    return 60
}

/// Pantalla que se graba: la pedida explícitamente (submenú), la que fije GRABAR_PANTALLA_INDICE
/// (a mano desde la terminal) o, si no, la que contiene el puntero. `id` es 0 si el índice pedido
/// no existe; la captura lo convierte en error.
func elegirPantalla(forzada: Int? = nil) -> (indice: Int, nombre: String, id: CGDirectDisplayID) {
    let lista = pantallasEnOrden()
    var pedida = forzada
    if pedida == nil, !residente, let v = ProcessInfo.processInfo.environment["GRABAR_PANTALLA_INDICE"] { pedida = Int(v) }
    if let i = pedida { return i >= 0 && i < lista.count ? (i, lista[i].pantalla.localizedName, lista[i].id) : (i, "pantalla \(i)", 0) }
    let p = NSEvent.mouseLocation
    if let i = lista.firstIndex(where: { NSMouseInRect(p, $0.pantalla.frame, false) }) { return (i, lista[i].pantalla.localizedName, lista[i].id) }
    return (0, lista.first?.pantalla.localizedName ?? "pantalla 0", lista.first?.id ?? CGMainDisplayID())
}

// SIGINT (Ctrl-C), SIGTERM y SIGHUP: el manejador C solo escribe el número de señal en una
// tubería y el hilo principal decide. Ctrl-C detiene la grabación (y cierra el mp4); SIGTERM y
// SIGHUP la cierran y salen.
var tuberiaSenal: [Int32] = [-1, -1]
pipe(&tuberiaSenal)
func alSenal(_ s: Int32) { var b = UInt8(truncatingIfNeeded: s); write(tuberiaSenal[1], &b, 1) }
signal(SIGINT, alSenal)
signal(SIGTERM, alSenal)
signal(SIGHUP, alSenal)

// MARK: - Captura

/// Qué se graba. Pantalla y región comparten filtro (la pantalla sin las ventanas de la app) y
/// difieren en el rectángulo y el tamaño del vídeo (`Grabador.medidas`); la ventana tiene filtro
/// propio. Un destino nuevo es un caso más aquí, en el filtro de `Grabador.arrancar`, en `medidas`
/// y en `Controlador.queSeGraba`.
enum Destino {
    /// La pantalla entera, a su resolución nativa.
    case pantalla
    /// Un rectángulo de la pantalla en puntos, relativo a su esquina superior izquierda (como
    /// `sourceRect` de ScreenCaptureKit y `--region` de la terminal).
    case region(CGRect)
    /// Una ventana de otra app, aunque otra la tape, a la escala de la pantalla donde está.
    case ventana(VentanaGrabable)
}

/// Lo que pide una grabación a la captura, sacado de los Ajustes al empezar.
struct Peticion {
    var destino = Destino.pantalla
    var fps: Int32
    var bitrate: Int
    var puntero = true
    /// Solo en macOS 15 o posterior; antes no existe.
    var clics = true
    var audioSistema = false
    /// Solo en macOS 15 o posterior, y con el permiso de micrófono ya concedido.
    var microfono = false
}

/// Una captura: `SCStream` de una pantalla → `AVAssetWriter`. Todo lo que toca el escritor corre en
/// `cola`, la misma en la que ScreenCaptureKit entrega fotogramas y audio: añadir una muestra y
/// cerrar el fichero no se pisan. Los avisos al controlador (`alEmpezar`, `alAcabar`) llegan por el
/// hilo principal. Cada fotograma se escribe al llegar el siguiente, con su duración real: así el
/// último dura hasta el corte aunque la pantalla llevara un rato quieta (sin esto el mp4 acaba en el
/// último cambio). El audio (sistema y micrófono, cada uno en su pista AAC) lleva las marcas de
/// tiempo del mismo reloj que el vídeo: lo anterior al primer fotograma se descarta.
final class Grabador: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Final { case video(fotogramas: Int, segundos: Double), fallo(String), cancelado }

    let ruta: URL
    let limite: Double
    let peticion: Peticion
    /// Primer fotograma escrito: la grabación ya corre.
    var alEmpezar: () -> Void = {}
    /// Se llama una sola vez, con el mp4 ya cerrado (o borrado si no vale).
    var alAcabar: (Final) -> Void = { _ in }

    private let cola = DispatchQueue(label: "net.fodaveg.grabar-pantalla.captura", qos: .userInteractive)
    private var stream: SCStream?
    private var escritor: AVAssetWriter?
    private var entrada: AVAssetWriterInput?
    /// Pistas de audio: la del sistema y la del micrófono (cada una si se pidió).
    private var entradaSistema: AVAssetWriterInput?
    private var entradaMicro: AVAssetWriterInput?
    /// Muestras de audio que el escritor no pudo aceptar (se avisa al acabar si hay alguna).
    private var audioPerdido = 0
    /// Audio llegado antes del primer fotograma: espera a saber dónde empieza la sesión (64 bloques
    /// como mucho). Medido en un MacBook Pro con macOS 27, el audio del sistema arranca unos 15 ms
    /// después del primer fotograma y esto queda vacío; la pista empieza entonces con ese hueco, en
    /// su sitio.
    private var audioPrevio: [(muestra: CMSampleBuffer, sistema: Bool)] = []
    private var primero: CMTime?
    /// Fotograma completo que espera al siguiente (o al corte) para saber cuánto dura.
    private var retenido: CMSampleBuffer?
    /// Fin del último fotograma escrito (su PTS más su duración).
    private var finEscrito = CMTime.invalid
    private var fotogramas = 0
    /// Detener, cancelar o fallo: ya no entra ningún fotograma más.
    private var cerrado = false

    init(ruta: URL, limite: Double, peticion: Peticion) {
        self.ruta = ruta
        self.limite = limite
        self.peticion = peticion
    }

    /// Pide el contenido compartible, monta filtro, stream y escritor, y arranca. Sin permiso de
    /// Grabación de pantalla falla al momento (sin esperar a que llegue imagen).
    func arrancar(pantalla id: CGDirectDisplayID) {
        // Sin permiso, ScreenCaptureKit falla igual, pero esto no espera al servidor de ventanas.
        // La petición enseña el diálogo del sistema la primera vez y registra la app en la lista
        // de Ajustes; las siguientes no hace nada.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            cola.async { [self] in fallar(mensajePermiso) }
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [self] contenido, error in
            cola.async { [self] in
                guard !cerrado else { return }
                guard let contenido else { fallar(describir(error)); return }
                guard let pantalla = contenido.displays.first(where: { $0.displayID == id }) else {
                    fallar("No encuentro esa pantalla (¿se ha desconectado?)")
                    return
                }
                let propia = Grabador.propias(de: contenido)
                // Pantalla y región: la pantalla entera sin la app (también el marco de la región,
                // que es una ventana suya); la región la recorta `sourceRect` en `montar`.
                // Ventana: solo ella, con lo que tenga encima o no esté en pantalla (desktop
                // independent), del tamaño que tiene ahora.
                switch peticion.destino {
                case .pantalla, .region:
                    montar(filtro: SCContentFilter(display: pantalla, excludingApplications: propia, exceptingWindows: []),
                           id: id, puntos: (pantalla.width, pantalla.height))
                case .ventana(let v):
                    guard let w = contenido.windows.first(where: { $0.windowID == v.id }) else {
                        fallar("La ventana «\(v.nombre)» ya no está")
                        return
                    }
                    montar(filtro: SCContentFilter(desktopIndependentWindow: w), id: id,
                           puntos: (pantalla.width, pantalla.height), ventana: w.frame.size)
                }
            }
        }
    }

    /// Tamaño del vídeo en píxeles y, en una región, el rectángulo de la pantalla que se graba (en
    /// puntos). Siempre a la resolución nativa: la del modo actual (3024x1964 en la integrada; en
    /// puntos sería la mitad), y una región a la misma escala, ajustada a píxeles enteros. Una
    /// ventana, su tamaño en puntos `ventana` al empezar por la escala de su pantalla. H.264 4:2:0
    /// pide medidas pares.
    private func medidas(id: CGDirectDisplayID, puntos: (Int, Int), ventana: CGSize) -> (ancho: Int, alto: Int, fuente: CGRect?) {
        switch peticion.destino {
        case .pantalla:
            let modo = CGDisplayCopyDisplayMode(id)
            return ((modo?.pixelWidth ?? puntos.0) & ~1, (modo?.pixelHeight ?? puntos.1) & ~1, nil)
        case .region(let r):
            let k = escala(de: id)
            let a = ajustarRegion(r, escala: k, limite: CGSize(width: puntos.0, height: puntos.1))
            return (Int((a.width * k).rounded()), Int((a.height * k).rounded()), a)
        case .ventana:
            let p = pixelesDeVentana(ventana, escala: escala(de: id))
            return (p.ancho, p.alto, nil)
        }
    }

    /// La propia app, para dejarla fuera del vídeo: su icono de la barra de menús, el menú abierto y
    /// cualquier ventana suya. Por identificador y no por pid: la residente y la de la terminal
    /// conviven y ninguna de las dos debe salir.
    static func propias(de contenido: SCShareableContent) -> [SCRunningApplication] {
        let yo = Bundle.main.bundleIdentifier
        return contenido.applications.filter { $0.processID == getpid() || (yo != nil && $0.bundleIdentifier == yo) }
    }

    /// Configuración del `SCStream` de `peticion` a `ancho`x`alto` píxeles (y `fuente`, el rectángulo
    /// de una región). La comparte la memoria de los últimos segundos (memoria.swift), que pide sin audio.
    static func configuracion(_ peticion: Peticion, ancho: Int, alto: Int, fuente: CGRect?) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        if let fuente { cfg.sourceRect = fuente }
        cfg.width = ancho
        cfg.height = alto
        // Una ventana que cambia de tamaño mientras se graba se escala dentro del tamaño del
        // principio, sin deformarla (macOS 14; en el 13 se estira a ese tamaño).
        if case .ventana = peticion.destino {
            cfg.scalesToFit = true
            if #available(macOS 14.0, *) { cfg.preservesAspectRatio = true }
        }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: peticion.fps)
        // 8 es el máximo recomendado: el codificador retiene los búferes mientras trabaja y con
        // menos la captura se atasca a 120 fps.
        cfg.queueDepth = 8
        cfg.showsCursor = peticion.puntero
        // Los clics marcados solo los pinta ScreenCaptureKit en BGRA (cabecera de SCStream). Sin
        // marcado (macOS 13-14, o desactivado) se captura en 4:2:0, que es lo que come VideoToolbox.
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if #available(macOS 15.0, *), peticion.clics {
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showMouseClicks = true
        }
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        // Audio del sistema: el de todo el Mac menos esta app (sus sonidos de aviso no se graban).
        if peticion.audioSistema {
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
        }
        // Micrófono: el de por defecto del sistema.
        if #available(macOS 15.0, *), peticion.microfono {
            cfg.captureMicrophone = true
            cfg.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }
        return cfg
    }

    /// Entrada H.264 por hardware de `ancho`x`alto` al bitrate y fps de `peticion`. También la de los
    /// segmentos de la memoria.
    static func entradaVideo(_ peticion: Peticion, ancho: Int, alto: Int) -> AVAssetWriterInput {
        let entrada = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: ancho,
            AVVideoHeightKey: alto,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: peticion.bitrate,
                AVVideoExpectedSourceFrameRateKey: peticion.fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // Sin fotogramas B: con fps variable las marcas de tiempo salen tal cual.
                AVVideoAllowFrameReorderingKey: false,
                // Un fotograma clave por segundo, para que `fotogramas` y los reproductores salten rápido.
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        entrada.expectsMediaDataInRealTime = true
        // Escala fina (1/90000 s) para no redondear las marcas de tiempo de la captura.
        entrada.mediaTimeScale = 90_000
        return entrada
    }

    private func montar(filtro: SCContentFilter, id: CGDirectDisplayID, puntos: (Int, Int), ventana: CGSize = .zero) {
        let (ancho, alto, fuente) = medidas(id: id, puntos: puntos, ventana: ventana)
        guard ancho >= 2, alto >= 2 else { fallar("La región no llega a 2x2 píxeles"); return }
        let cfg = Grabador.configuracion(peticion, ancho: ancho, alto: alto, fuente: fuente)
        do {
            // AVAssetWriter no sobrescribe: si existe (dos grabaciones en el mismo segundo), fuera.
            try? FileManager.default.removeItem(at: ruta)
            let escritor = try AVAssetWriter(outputURL: ruta, fileType: .mp4)
            let entrada = Grabador.entradaVideo(peticion, ancho: ancho, alto: alto)
            guard escritor.canAdd(entrada) else { fallar("El escritor de vídeo no acepta H.264 a \(ancho)x\(alto)"); return }
            escritor.add(entrada)
            // Una pista por fuente y no una mezcla: mezclar exige alinear y remuestrear dos relojes
            // de audio en vivo, y si uno se retrasa se lleva al otro. Con dos pistas cada una lleva
            // sus marcas de tiempo tal cual. QuickTime reproduce las dos a la vez.
            if peticion.audioSistema {
                let e = Grabador.entradaAAC(canales: 2, bitrate: 128_000)
                guard escritor.canAdd(e) else { fallar("El escritor no acepta la pista de audio del sistema"); return }
                escritor.add(e)
                entradaSistema = e
            }
            if peticion.microfono {
                let e = Grabador.entradaAAC(canales: 1, bitrate: 96_000)
                guard escritor.canAdd(e) else { fallar("El escritor no acepta la pista del micrófono"); return }
                escritor.add(e)
                entradaMicro = e
            }
            guard escritor.startWriting() else { fallar("No puedo escribir \(ruta.path): \(describir(escritor.error))"); return }
            let stream = SCStream(filter: filtro, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: cola)
            if peticion.audioSistema { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: cola) }
            if #available(macOS 15.0, *), peticion.microfono { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: cola) }
            self.escritor = escritor
            self.entrada = entrada
            self.stream = stream
            stream.startCapture { [self] error in
                cola.async { [self] in
                    if let error { fallar(describir(error)); return }
                    // La primera imagen llega en unas décimas. Si no llega, error en vez de un
                    // «Iniciando…» eterno.
                    cola.asyncAfter(deadline: .now() + 5) { [self] in
                        if primero == nil { fallar("La captura arrancó pero no llega imagen de la pantalla") }
                    }
                }
            }
        } catch {
            fallar(describir(error))
        }
    }

    /// Detener a mano (clic, atajo, reapertura, Ctrl-C, Salir, SIGTERM): el vídeo dura hasta ahora,
    /// aunque la pantalla llevara un rato quieta y no hubiera fotogramas nuevos.
    func detener() {
        cola.async { [self] in
            guard let primero else { cancelarYa(); return }
            finalizar(hasta: CMTimeMinimum(CMClockGetTime(CMClockGetHostTimeClock()), primero + CMTime(seconds: limite, preferredTimescale: 1_000_000_000)))
        }
    }

    /// Cancelar antes de que haya vídeo (cuenta atrás ya pasada, «Iniciando…»): sin fichero.
    func cancelar() { cola.async { [self] in cancelarYa() } }

    private func cancelarYa() {
        guard !cerrado else { return }
        cerrado = true
        retenido = nil
        stream?.stopCapture { _ in }
        escritor?.cancelWriting()
        try? FileManager.default.removeItem(at: ruta)
        acabar(.cancelado)
    }

    /// Error sin vídeo aprovechable: se borra lo que haya.
    private func fallar(_ mensaje: String) {
        guard !cerrado else { return }
        cerrado = true
        retenido = nil
        stream?.stopCapture { _ in }
        escritor?.cancelWriting()
        try? FileManager.default.removeItem(at: ruta)
        acabar(.fallo(mensaje))
    }

    /// Escribe el fotograma retenido `m` con duración hasta `fin` (el PTS del siguiente o el corte).
    /// Si el codificador no da abasto, se pierde (como se perdía en ffmpeg) y no cuenta.
    private func escribir(_ m: CMSampleBuffer, hasta fin: CMTime) {
        guard let entrada else { return }
        let pts = m.presentationTimeStamp
        // Nunca menos de un intervalo de captura: un fotograma de duración 0 no se vería.
        let duracion = CMTimeMaximum(fin - pts, CMTime(value: 1, timescale: peticion.fps))
        var t = CMSampleTimingInfo(duration: duracion, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copia: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: m, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &t, sampleBufferOut: &copia) == noErr,
              let copia, entrada.isReadyForMoreMediaData else { return }
        if entrada.append(copia) {
            fotogramas += 1
            finEscrito = pts + duracion
        }
    }

    /// Escribe el último fotograma hasta `fin` y cierra el mp4 con `finishWriting` (escribe el
    /// índice; sin él el fichero no se lee).
    private func finalizar(hasta fin: CMTime) {
        guard !cerrado, let escritor, let entrada, let primero else { return }
        cerrado = true
        stream?.stopCapture { _ in }
        if let r = retenido {
            retenido = nil
            // El último no se tira por un codificador ocupado: se le da medio segundo.
            let espera = Date().addingTimeInterval(0.5)
            while !entrada.isReadyForMoreMediaData, escritor.status == .writing, Date() < espera { usleep(5_000) }
            escribir(r, hasta: fin)
        }
        guard escritor.status == .writing, fotogramas > 0 else {
            let motivo = fotogramas == 0 ? "No se escribió ningún fotograma" : "Falló la escritura del vídeo: \(describir(escritor.error))"
            escritor.cancelWriting()
            try? FileManager.default.removeItem(at: ruta)
            acabar(.fallo(motivo))
            return
        }
        let n = fotogramas, fin = finEscrito
        entrada.markAsFinished()
        entradaSistema?.markAsFinished()
        entradaMicro?.markAsFinished()
        if audioPerdido > 0 { avisar("Aviso: el escritor no aceptó \(audioPerdido) bloque(s) de audio; puede haber cortes en el sonido") }
        // El audio que pase del último fotograma se recorta aquí: todas las pistas acaban con el vídeo.
        escritor.endSession(atSourceTime: fin)
        escritor.finishWriting { [self] in
            if escritor.status == .completed {
                acabar(.video(fotogramas: n, segundos: (fin - primero).seconds))
            } else {
                try? FileManager.default.removeItem(at: ruta)
                acabar(.fallo("No se pudo cerrar el vídeo: \(describir(escritor.error))"))
            }
        }
    }

    private func acabar(_ f: Final) { DispatchQueue.main.async { [self] in alAcabar(f) } }

    /// Entrada AAC a 48 kHz. El escritor convierte lo que llegue (PCM de ScreenCaptureKit, con sus
    /// canales y frecuencia) a esto.
    static func entradaAAC(canales: Int, bitrate: Int) -> AVAssetWriterInput {
        var disposicion = AudioChannelLayout()
        disposicion.mChannelLayoutTag = canales == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let e = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: canales,
            AVChannelLayoutKey: Data(bytes: &disposicion, count: MemoryLayout<AudioChannelLayout>.size),
            AVEncoderBitRateKey: bitrate,
        ])
        e.expectsMediaDataInRealTime = true
        return e
    }

    /// Una muestra de audio a su pista, solo si suena entre el primer fotograma y el corte. Antes del
    /// primer fotograma se guarda en `audioPrevio`. Un bloque que empieza antes del primer fotograma y
    /// acaba después entra entero: el escritor deja fuera (lista de edición) lo anterior al inicio
    /// de la sesión, así que el audio de antes se descarta igual y la pista empieza en t = 0.
    private func anadirAudio(_ m: CMSampleBuffer, a entrada: AVAssetWriterInput?) {
        guard !cerrado, let entrada, let escritor, escritor.status == .writing, m.isValid,
              CMSampleBufferGetNumSamples(m) > 0 else { return }
        guard let primero else {
            audioPrevio.append((m, entrada === entradaSistema))
            if audioPrevio.count > 64 { audioPrevio.removeFirst() }
            return
        }
        let pts = m.presentationTimeStamp
        guard pts + m.duration > primero, pts < primero + CMTime(seconds: limite, preferredTimescale: 1_000_000_000) else { return }
        guard entrada.isReadyForMoreMediaData else { audioPerdido += 1; return }
        if !entrada.append(m) { audioPerdido += 1 }
    }

    private func describir(_ e: Error?) -> String {
        guard let e else { return "error desconocido" }
        if (e as NSError).domain == SCStreamErrorDomain, (e as NSError).code == SCStreamError.Code.userDeclined.rawValue { return mensajePermiso }
        return e.localizedDescription
    }

    // MARK: SCStreamOutput, SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer muestra: CMSampleBuffer, of tipo: SCStreamOutputType) {
        if tipo == .audio { anadirAudio(muestra, a: entradaSistema); return }
        if #available(macOS 15.0, *), tipo == .microphone { anadirAudio(muestra, a: entradaMicro); return }
        guard tipo == .screen, !cerrado, let escritor, muestra.isValid else { return }
        // Solo fotogramas completos: los `.idle` (pantalla quieta) y similares no traen imagen nueva.
        guard let info = CMSampleBufferGetSampleAttachmentsArray(muestra, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let bruto = info.first?[.status] as? Int, SCFrameStatus(rawValue: bruto) == .complete else { return }
        let pts = muestra.presentationTimeStamp
        if let primero {
            // N segundos pedidos o tope: corta en el instante exacto, aunque el temporizador llegue tarde.
            let corte = primero + CMTime(seconds: limite, preferredTimescale: 1_000_000_000)
            if pts >= corte { finalizar(hasta: corte); return }
        } else {
            // La sesión empieza en el primer fotograma completo: el vídeo arranca en t = 0 con imagen.
            escritor.startSession(atSourceTime: pts)
            primero = pts
            // El audio que esperaba: entra el que suene desde este fotograma (ver `anadirAudio`).
            let previo = audioPrevio
            audioPrevio = []
            for p in previo { anadirAudio(p.muestra, a: p.sistema ? entradaSistema : entradaMicro) }
            // Con la pantalla quieta no llegan fotogramas que disparen el corte de arriba.
            cola.asyncAfter(deadline: .now() + limite) { [self] in
                finalizar(hasta: pts + CMTime(seconds: limite, preferredTimescale: 1_000_000_000))
            }
            DispatchQueue.main.async { [self] in alEmpezar() }
        }
        if let r = retenido {
            escribir(r, hasta: pts)
            if escritor.status == .failed { fallar("Falló la escritura del vídeo: \(describir(escritor.error))"); return }
        }
        retenido = muestra
    }

    /// La captura se corta sola (pantalla desconectada, permiso retirado, la ventana que se graba
    /// cerrada…): se guarda lo grabado. Al cerrarse la ventana, ScreenCaptureKit da unos fotogramas
    /// en blanco y parado (que no se escriben) y, unas décimas después, este error (-3815, sin
    /// pantalla ni ventana que capturar): medido en macOS 27 con una ventana de prueba.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        cola.async { [self] in
            guard !cerrado else { return }
            if case .ventana = peticion.destino, primero != nil, (error as NSError).code == SCStreamError.Code.noCaptureSource.rawValue {
                avisar("La ventana se ha cerrado: se guarda lo grabado hasta ahí")
            }
            if primero != nil { finalizar(hasta: CMClockGetTime(CMClockGetHostTimeClock())) } else { fallar(describir(error)) }
        }
    }
}

// MARK: - App

enum Estado { case espera, cuenta(Int), iniciando, grabando, guardando, hecho, error }

/// Una grabación: su cuenta atrás, su `Grabador` y lo que acabó dejando. Cada grabación estrena la
/// suya, y lo que llega de una anterior (aviso rezagado) se ignora comparando identidades.
final class Sesion {
    /// Los Ajustes leídos al empezar esta grabación: cambiarlos después no la toca.
    var ajustes = Ajustes.leer()
    /// La carpeta elegida no valía y se guarda en ~/Movies: por qué.
    var avisoCarpeta: String?
    var cuenta: Timer?
    var grabador: Grabador?
    var rutaVideo: String?
    var medida = ""
    var ultimaLinea = ""
    var codigo: Int32 = 0
    var cancelado = false
    /// Título de la notificación al acabar bien.
    var tituloAviso = "Grabación terminada"
    /// Cierre de la app (Salir, SIGTERM) a la espera de que el mp4 quede cerrado.
    var alCerrar: (() -> Void)?
}

/// Atajo global fijo: ⌃⌥⌘R (los ⌘⇧3/4/5 son del sistema).
let atajoTecla = UInt32(kVK_ANSI_R)
/// Atajo global para guardar los últimos N s, con la memoria encendida: ⌃⌥⌘S.
let atajoMemoriaTecla = UInt32(kVK_ANSI_S)
let atajoModificadores = UInt32(controlKey | optionKey | cmdKey)
let categoriaNotificacion = "grabacion-terminada"

final class Controlador: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var estado = Estado.espera
    var sesion: Sesion?
    var inicio = Date()
    var temporizador: Timer?
    var pantalla = (indice: 0, nombre: "", id: CGDirectDisplayID(0))
    /// Qué se graba de `pantalla` en la grabación en curso (o la siguiente).
    var destino = Destino.pantalla
    /// Selector de región abierto (residente, desde el menú).
    var selector: SelectorRegion?
    /// Marco de la región que se graba, de la cuenta atrás al final.
    var marco: MarcoRegion?
    var fuenteSenal: DispatchSourceRead?
    var saliendo = false
    var menuActual = NSMenu()
    var tokenEspera = 0
    var lanzadaPorNotificacion = false
    var atajoRef: EventHotKeyRef?
    /// Última grabación buena, para «Sacar fotogramas» desde la espera.
    var ultimoVideo: String?
    var sacandoFotogramas = false
    /// Modo terminal: salida aplazada hasta que acabe `fotogramas`.
    var salidaPendiente: Int32?
    /// La ventana de Ajustes, creada la primera vez que se abre.
    var ventanaAjustes: VentanaAjustes?
    /// «Ajustes…» del menú principal (⌘, con la ventana delante), para deshabilitarlo grabando.
    var ajustesPrincipal: NSMenuItem?
    /// Memoria de los últimos N s (memoria.swift): nil si está apagada. Siempre empieza apagada.
    var memoria: Memoria?
    /// Una grabación normal la tiene parada; vuelve al acabar esa grabación.
    var memoriaEnPausa = false
    /// La pausa está pedida y ScreenCaptureKit aún no ha parado su stream.
    var parandoMemoria = false
    /// Captura de una grabación normal que espera a que pare la memoria (nunca dos `SCStream`).
    var arranquePendiente: (() -> Void)?
    var guardandoMemoria = false
    /// Por qué la memoria se apagó sola o no se pudo encender, para el menú hasta el próximo intento.
    var avisoMemoria: String?
    var atajoMemoriaRef: EventHotKeyRef?
    /// ⌃⌥⌘S no se pudo registrar (otra app lo tiene): el menú lo dice.
    var errorAtajoMemoria: String?
    /// Segundos de la grabación normal de la prueba de la memoria (sin argumentos de terminal).
    var duracionPedida: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if residente { montarMenuPrincipal() }
        pantalla = elegirPantalla()
        item.button?.target = self
        item.button?.action = #selector(clicEnIcono)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let fuente = DispatchSource.makeReadSource(fileDescriptor: tuberiaSenal[0], queue: .main)
        fuente.setEventHandler { [self] in
            var b: UInt8 = 0
            read(tuberiaSenal[0], &b, 1)
            if Int32(b) == SIGINT { interrumpir(); return }
            guard !saliendo else { return }
            saliendo = true
            cerrarCaptura { [self] in
                memoria?.apagar()
                exit(143)
            }
        }
        fuente.resume()
        fuenteSenal = fuente
        configurarNotificaciones()
        if residente { registrarAtajo() }
        if let p = pruebaMemoria {
            probarMemoria(p)
            return
        }
        guard residente else {
            lanzar()
            return
        }
        estado = .espera
        pintar()
        let comoItem = lanzadaComoItemDeInicio()
        // Queda en el registro del sistema, para comprobar tras iniciar sesión que macOS manda la marca:
        // /usr/bin/log show --last 10m --predicate 'subsystem == "net.fodaveg.grabar-pantalla"'
        let registro = Logger(subsystem: "net.fodaveg.grabar-pantalla", category: "arranque")
        if comoItem { registro.notice("Arranque residente como ítem de inicio de sesión: queda en espera") } else { registro.notice("Arranque residente normal: graba") }
        if comoItem { return }
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

    /// ⌘Q o terminate: si graba, cierra el mp4 antes de salir.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hayCaptura() else { return .terminateNow }
        cerrarCaptura { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Al salir (⌘Q, «Salir»), los segmentos de la memoria se borran.
    func applicationWillTerminate(_ notification: Notification) {
        memoria?.apagar()
        memoria = nil
    }

    func hayCaptura() -> Bool {
        guard sesion != nil else { return false }
        switch estado {
        case .cuenta, .iniciando, .grabando, .guardando: return true
        default: return false
        }
    }

    /// Para salir: detiene la grabación en curso y llama a `luego` con el mp4 ya cerrado (o sin
    /// nada que cerrar). Si el escritor no acaba en 10 s, sale igual y ese vídeo se pierde. No
    /// bloquea el hilo principal: los avisos del grabador llegan por él.
    func cerrarCaptura(luego: @escaping () -> Void) {
        guard hayCaptura(), let s = sesion else { luego(); return }
        var hecho = false
        let una = { if !hecho { hecho = true; luego() } }
        s.alCerrar = una
        s.cuenta?.invalidate()
        switch estado {
        case .grabando:
            estado = .guardando
            pintar()
            s.grabador?.detener()
        case .iniciando:
            s.cancelado = true
            if let g = s.grabador { g.cancelar() } else { una() }
        case .cuenta:
            una()
        default: break
        }
        // En modos comunes: con `terminateLater` AppKit corre el bucle en modo modal y un temporizador
        // del modo por defecto no dispara nunca (medido con la versión de ffmpeg: osascript quit se colgaba).
        let t = Timer(timeInterval: 10, repeats: false) { _ in una() }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Ctrl-C en la terminal (o SIGINT a la residente): detiene si graba, cancela en la cuenta
    /// atrás y, en la terminal, sale sin esperar si ya está en ✓ o ⚠.
    func interrumpir() {
        switch estado {
        case .grabando: detener()
        case .cuenta, .iniciando: cancelar()
        case .hecho, .error: if !residente { salirDeTerminal(con: sesion?.codigo ?? 0) }
        case .espera, .guardando: break
        }
    }

    // MARK: Atajo global

    /// Carbon `RegisterEventHotKey`: no pide permiso de Accesibilidad. Si otra app ya tiene la
    /// combinación, el registro falla y el atajo no funciona (se avisa por stderr; el de la memoria,
    /// también en el menú). Medido en macOS 27 con ⌃⌥⌘S: otro proceso que ya lo tiene no hace
    /// fallar el registro (devuelve 0), así que el aviso queda para los demás errores. Cada atajo
    /// lleva su id: 1, ⌃⌥⌘R; 2, ⌃⌥⌘S.
    func registrarAtajo() {
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, evento, _ in
            var id = EventHotKeyID()
            GetEventParameter(evento, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let cual = id.id
            DispatchQueue.main.async { if cual == 2 { controlador.guardarMemoria() } else { controlador.alternar() } }
            return noErr
        }, 1, &tipo, nil, nil)
        let r = RegisterEventHotKey(atajoTecla, atajoModificadores, EventHotKeyID(signature: OSType(0x4752_4142), id: 1),
                                    GetApplicationEventTarget(), 0, &atajoRef)
        if r != noErr { avisar("No pude registrar el atajo ⌃⌥⌘R (error \(r))") }
        let m = RegisterEventHotKey(atajoMemoriaTecla, atajoModificadores, EventHotKeyID(signature: OSType(0x4752_4142), id: 2),
                                    GetApplicationEventTarget(), 0, &atajoMemoriaRef)
        if m != noErr {
            errorAtajoMemoria = "⌃⌥⌘S no funciona (error \(m) al registrarlo). Usa este menú."
            avisar("No pude registrar el atajo ⌃⌥⌘S (error \(m))")
        }
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

    func notificar(ruta: String, medida: String, sonido: Bool, titulo: String = "Grabación terminada") {
        let c = UNMutableNotificationContent()
        c.title = titulo
        c.subtitle = (ruta as NSString).lastPathComponent
        c.body = medida
        c.sound = sonido ? .default : nil
        c.categoryIdentifier = categoriaNotificacion
        c.userInfo = ["ruta": ruta]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { _ in }
    }

    /// Aviso suelto (carpeta no disponible, micrófono sin permiso): siempre se manda, aunque la
    /// notificación de «Grabación terminada» esté desactivada, porque cambia dónde o qué se graba.
    func notificarAviso(_ titulo: String, _ texto: String) {
        let c = UNMutableNotificationContent()
        c.title = titulo
        c.body = texto
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

    // MARK: Grabación

    /// Nueva grabación desde la espera (menú, atajo, reapertura, arranque normal o el selector de
    /// región). Sin `indice`, la pantalla del puntero; sin `destino`, la pantalla entera. Con el
    /// selector abierto (el atajo, por ejemplo), lo cierra.
    func empezar(indice: Int? = nil, destino: Destino = .pantalla) {
        selector?.cerrar()
        selector = nil
        tokenEspera += 1
        pantalla = elegirPantalla(forzada: indice)
        self.destino = destino
        lanzar()
    }

    /// Lo que se graba, para el menú: la pantalla, «región de» la pantalla o la ventana.
    var queSeGraba: String {
        switch destino {
        case .pantalla: return pantalla.nombre
        case .region: return "región de \(pantalla.nombre)"
        case .ventana(let v): return "ventana \(v.nombre)"
        }
    }

    static let uso = "Uso: grabar-pantalla [--region X,Y,ANCHO,ALTO | --ventana TEXTO] [segundos]   (0 = hasta Detener)"

    /// Segundos de la grabación (0 = hasta Detener), región y texto de la ventana: en la terminal,
    /// sus argumentos (`[--region X,Y,ANCHO,ALTO | --ventana TEXTO] segundos`); en la residente, la
    /// duración de los Ajustes y nada más (región y ventana se eligen en el menú). nil si los
    /// argumentos no se entienden. Con `--region` y `--ventana` a la vez devuelve los dos: el error
    /// lo da `lanzar`, con su propio mensaje.
    func argumentosPedidos(_ a: Ajustes) -> (segundos: Double, region: CGRect?, ventana: String?)? {
        // La prueba de la memoria no lee argumentos (sí los `-clave valor` de UserDefaults, p. ej. `-cuentaAtras 0`).
        guard !argsTerminal.isEmpty, pruebaMemoria == nil else { return (duracionPedida ?? Double(a.duracion), nil, nil) }
        var resto = argsTerminal[...]
        var region: CGRect?
        var ventana: String?
        while let opcion = resto.first, opcion == "--region" || opcion == "--ventana" {
            resto = resto.dropFirst()
            guard let v = resto.first else { return nil }
            resto = resto.dropFirst()
            if opcion == "--ventana" {
                guard ventana == nil, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                ventana = v
                continue
            }
            let n = v.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard region == nil, n.count == 4, let x = n[0], let y = n[1], let w = n[2], let h = n[3],
                  [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
            region = CGRect(x: x, y: y, width: w, height: h)
        }
        if region != nil, ventana != nil { return (0, region, ventana) }
        guard let t = resto.first else { return nil }
        guard let n = Double(t.replacingOccurrences(of: ",", with: ".")), n >= 0, n.isFinite else { return nil }
        return (n, region, ventana)
    }

    /// La ventana de `--ventana`: la primera cuyo «App: título» contiene el texto. Sin coincidencia
    /// (o sin lista), por qué, con las ventanas que sí hay, una por línea.
    func ventanaPedida(_ texto: String) -> (ventana: VentanaGrabable?, problema: String) {
        switch leerVentanas() {
        case .failure(let e): return (nil, e.texto)
        case .success(let lista):
            if let v = buscarVentana(texto, en: lista) { return (v, "") }
            let disponibles = lista.isEmpty ? "No hay ventanas de otras apps." : "Ventanas disponibles:\n" + lista.map { "  \($0.nombre)" }.joined(separator: "\n")
            return (nil, "Ninguna ventana contiene «\(texto)». \(disponibles)")
        }
    }

    /// Índice (en `pantallasEnOrden`) de la pantalla donde está una ventana; la principal si no toca ninguna.
    func indiceDePantalla(de v: VentanaGrabable) -> Int {
        let lista = pantallasEnOrden()
        guard let id = pantallaDe(v.marco, entre: lista.map(\.id)) else { return 0 }
        return lista.firstIndex { $0.id == id } ?? 0
    }

    /// Una región de la terminal tiene que caber en la pantalla elegida (en puntos) y dar al menos
    /// 2x2 píxeles; si no, por qué. Con una pantalla que no existe no se mira: ese error sale después.
    func problemaRegion(_ r: CGRect) -> String? {
        guard pantalla.id != 0 else { return nil }
        let b = CGDisplayBounds(pantalla.id).size
        // Como se escribió: con punto decimal, que la coma separa los cuatro números.
        let pedida = [r.minX, r.minY, r.width, r.height].map { $0.rounded() == $0 ? String(Int($0)) : String(Double($0)) }.joined(separator: ",")
        if r.minX < 0 || r.minY < 0 || r.maxX > b.width || r.maxY > b.height {
            return "La región \(pedida) se sale de la pantalla \(pantalla.indice) («\(pantalla.nombre)», \(Int(b.width))x\(Int(b.height)) puntos)"
        }
        let a = ajustarRegion(r, escala: escala(de: pantalla.id), limite: b)
        if a.width * escala(de: pantalla.id) < 2 || a.height * escala(de: pantalla.id) < 2 {
            return "La región \(pedida) no llega a 2x2 píxeles"
        }
        return nil
    }

    /// Lee los Ajustes y hace la cuenta atrás que digan; al acabar (o al momento, con 0), la captura.
    /// Con una región enseña su marco desde ya. Con `--ventana`, busca la ventana y graba en la
    /// pantalla donde está.
    func lanzar() {
        let s = Sesion()
        sesion = s
        pausarMemoria()
        guard let pedido = argumentosPedidos(s.ajustes) else {
            terminar(s, .fallo(Controlador.uso), codigo: 2)
            return
        }
        if pedido.region != nil, pedido.ventana != nil {
            terminar(s, .fallo("--region y --ventana no van juntos: se graba una región o una ventana.\n\(Controlador.uso)"), codigo: 2)
            return
        }
        if let texto = pedido.ventana {
            let (v, problema) = ventanaPedida(texto)
            guard let v else {
                terminar(s, .fallo(problema), codigo: 2)
                return
            }
            pantalla = elegirPantalla(forzada: indiceDePantalla(de: v))
            destino = .ventana(v)
            decir("Ventana: \(v.nombre)")
        }
        let segundos = pedido.segundos
        if let r = pedido.region {
            if let p = problemaRegion(r) {
                s.ultimaLinea = p
                terminar(s, .fallo(p), codigo: 2)
                return
            }
            destino = .region(r)
        }
        if case .region(let r) = destino, let p = pantallasEnOrden().first(where: { $0.id == pantalla.id })?.pantalla {
            marco?.cerrar()
            let m = MarcoRegion(region: regionGlobal(ajustarRegion(r, escala: escala(de: pantalla.id), limite: p.frame.size), en: p))
            m.mostrar()
            marco = m
        }
        let cuenta = s.ajustes.cuentaAtras
        let cuando = cuenta > 0 ? "en \(cuenta) s" : "sin cuenta atrás"
        decir(segundos == 0 ? "Grabando hasta Detener (máx. 30 min) \(cuando)…" : "Grabando \(formato(segundos, decimales: segundos.rounded() == segundos ? 0 : 1)) s \(cuando)…")
        let limite = segundos == 0 ? topeSegundos : min(segundos, topeSegundos)
        guard cuenta > 0 else {
            capturar(s, segundos: limite)
            return
        }
        estado = .cuenta(cuenta)
        pintar()
        var n = cuenta
        // En modos comunes: con el menú abierto el bucle corre en modo de seguimiento y la cuenta seguiría parada.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, s === self.sesion else { t.invalidate(); return }
            n -= 1
            if n > 0 {
                self.estado = .cuenta(n)
                self.pintar()
            } else {
                t.invalidate()
                self.capturar(s, segundos: limite)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        s.cuenta = t
    }

    /// Carpeta, calidad, puntero y audio de los Ajustes de la sesión → `Grabador`. Si la carpeta
    /// elegida no vale, se graba en ~/Movies y se avisa. Con micrófono y el permiso sin pedir, lo pide
    /// aquí (el diálogo del sistema) y sigue al responder; sin permiso, graba sin micrófono y avisa.
    func capturar(_ s: Sesion, segundos: Double) {
        estado = .iniciando
        pintar()
        let a = s.ajustes
        let carpeta = carpetaDeDestino(s)
        let ruta = carpeta.appendingPathComponent("pantalla-\(sello()).mp4")
        var peticion = Peticion(destino: destino, fps: a.calidad.fps(pantalla: pantalla.id), bitrate: a.calidad.bitrate,
                                puntero: a.mostrarPuntero, clics: a.marcarClics && hayMacOS15(), audioSistema: a.audio.sistema)
        if a.audio.microfono, !hayMacOS15() { avisar("Aviso: el micrófono necesita macOS 15; se graba sin él.") }
        guard a.audio.microfono, hayMacOS15() else {
            arrancar(s, ruta: ruta, segundos: segundos, peticion: peticion)
            return
        }
        let sinPermiso = { [self] in
            let m = "Sin permiso de micrófono: se graba sin él. Actívalo en Ajustes del Sistema > Privacidad y seguridad > Micrófono."
            avisar("Aviso: \(m)")
            notificarAviso("Grabación sin micrófono", m)
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            peticion.microfono = true
            arrancar(s, ruta: ruta, segundos: segundos, peticion: peticion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { [self] in
                    guard s === sesion, !s.cancelado else { return }
                    if ok { peticion.microfono = true } else { sinPermiso() }
                    arrancar(s, ruta: ruta, segundos: segundos, peticion: peticion)
                }
            }
        default:
            sinPermiso()
            arrancar(s, ruta: ruta, segundos: segundos, peticion: peticion)
        }
    }

    /// La carpeta de los Ajustes de `s` o, si no vale, ~/Movies con aviso (stderr, notificación y
    /// `s.avisoCarpeta`). Solo se crea ~/Movies; una carpeta elegida que falte no se crea (sería
    /// otro disco sin montar).
    func carpetaDeDestino(_ s: Sesion) -> URL {
        let a = s.ajustes
        var carpeta = a.carpeta
        if !a.carpetaEsLaDePorDefecto, let p = problemaCarpeta(carpeta) {
            let m = "La carpeta \(abreviar(carpeta.path)) \(p): se guarda en ~/Movies."
            s.avisoCarpeta = m
            avisar("Aviso: \(m)")
            notificarAviso("Carpeta de destino no disponible", m)
            carpeta = Ajustes.carpetaPorDefecto
            pintar()
        }
        if carpeta.standardizedFileURL.path == Ajustes.carpetaPorDefecto.standardizedFileURL.path {
            try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        }
        return carpeta
    }

    /// AAAAMMDD-HHMMSS de ahora, para el nombre del vídeo.
    func sello() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    func arrancar(_ s: Sesion, ruta: URL, segundos: Double, peticion: Peticion) {
        let g = Grabador(ruta: ruta, limite: segundos, peticion: peticion)
        s.grabador = g
        g.alEmpezar = { [weak self] in
            guard let self, s === self.sesion, case .iniciando = self.estado else { return }
            decir("GRABANDO")
            self.inicio = Date()
            self.estado = .grabando
            self.temporizador?.invalidate()
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.pintar() }
            RunLoop.main.add(t, forMode: .common)
            self.temporizador = t
            self.pintar()
        }
        g.alAcabar = { [weak self] final in self?.terminar(s, final) }
        if pantalla.id == 0 {
            terminar(s, .fallo("No hay pantalla \(pantalla.indice) (GRABAR_PANTALLA_INDICE)"))
            return
        }
        let id = pantalla.id
        // Con la memoria aún parando su stream, la captura espera a que pare.
        if parandoMemoria { arranquePendiente = { g.arrancar(pantalla: id) } } else { g.arrancar(pantalla: id) }
    }

    func formato(_ x: Double, decimales: Int = 1) -> String {
        String(format: "%.\(decimales)f", locale: Locale.current, x)
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
        guard case .grabando = estado, let g = sesion?.grabador else { return }
        estado = .guardando
        g.detener()
        pintar()
    }

    @objc func cancelar() {
        guard let s = sesion else { return }
        s.cancelado = true
        s.cuenta?.invalidate()
        if let g = s.grabador { g.cancelar() } else { terminar(s, .cancelado) }
    }

    @objc func grabarPunteroDesdeMenu() { empezar() }

    /// «Grabar una región…»: abre el selector sobre todas las pantallas. Al soltar, la grabación
    /// normal (cuenta atrás y Ajustes) de esa región; al cancelar, de vuelta a espera.
    @objc func grabarRegionDesdeMenu() {
        switch estado {
        case .espera, .hecho, .error: break
        default: return
        }
        selector?.cerrar()
        let sel = SelectorRegion()
        sel.alElegir = { [weak self] pantallaElegida, region in
            guard let self else { return }
            self.selector = nil
            let id = idDe(pantallaElegida)
            guard let i = pantallasEnOrden().firstIndex(where: { $0.id == id }) else { self.volverAEspera(en: 0); return }
            self.empezar(indice: i, destino: .region(region))
        }
        sel.alCancelar = { [weak self] in
            guard let self else { return }
            self.selector = nil
            if case .espera = self.estado { return }
            self.volverAEspera(en: 0)
        }
        selector = sel
        sel.abrir()
    }

    /// Una entrada de «Grabar una ventana»: la grabación normal de esa ventana, en la pantalla donde está.
    @objc func grabarVentanaDesdeMenu(_ i: NSMenuItem) {
        guard let v = i.representedObject as? VentanaGrabable else { return }
        switch estado {
        case .espera, .hecho, .error: empezar(indice: indiceDePantalla(de: v), destino: .ventana(v))
        default: return
        }
    }

    /// El submenú «Grabar una ventana» se rellena al abrirse, con las ventanas que haya en ese momento.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rellenarMenuVentanas(menu, con: leerVentanas(), destino: self, accion: #selector(grabarVentanaDesdeMenu(_:)))
    }

    @objc func grabarPantallaDesdeMenu(_ i: NSMenuItem) { empezar(indice: i.tag) }
    @objc func salir() { NSApp.terminate(nil) }

    @objc func mostrarEnFinder() {
        if let r = sesion?.rutaVideo { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r)]) }
    }

    /// «Cerrar» tras un error: la terminal sale, la residente vuelve a espera.
    @objc func cerrar() {
        if residente { volverAEspera(en: 0) } else { salirDeTerminal(con: sesion?.codigo ?? 1) }
    }

    /// Salida del modo terminal; si `fotogramas` está trabajando, espera a que acabe.
    func salirDeTerminal(con codigo: Int32) {
        if sacandoFotogramas { salidaPendiente = codigo } else { exit(codigo) }
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

    /// La grabación acabó (mp4 cerrado, o nada): hecho, error o cancelación.
    func terminar(_ s: Sesion, _ final: Grabador.Final, codigo: Int32 = 1) {
        guard s === sesion else { return }
        reanudarMemoria()
        temporizador?.invalidate()
        s.cuenta?.invalidate()
        marco?.cerrar()
        marco = nil
        switch final {
        case .video(let n, let segundos):
            let ruta = s.grabador?.ruta.path ?? ""
            s.rutaVideo = ruta
            ultimoVideo = ruta
            let fps = segundos > 0 ? Double(n) / segundos : 0
            s.medida = "\(n) fotogramas, ≈ \(formato(fps)) fps"
            decir("Fotogramas: \(n) (≈ \(formato(fps)) fps en \(formato(segundos)) s)")
            decir("Hecho: \(ruta)")
        case .fallo(let m):
            // En el menú, solo la primera línea (la lista de ventanas de `--ventana` va a stderr).
            s.ultimaLinea = m.split(separator: "\n").first.map(String.init) ?? m
            s.codigo = codigo
            avisar(m)
        case .cancelado:
            s.codigo = 130
        }
        // Cierre de la app: no hay ✓ ni ⚠ que enseñar.
        if let alCerrar = s.alCerrar { alCerrar(); return }
        // La prueba de la memoria vuelve a espera como la residente: sale ella al acabar la prueba.
        let vuelve = residente || pruebaMemoria != nil
        switch final {
        case .cancelado:
            if vuelve { volverAEspera(en: 0) } else { salirDeTerminal(con: 130) }
        case .video:
            estado = .hecho
            pintar()
            alTerminar(s)
            if vuelve { volverAEspera(en: 5) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in salirDeTerminal(con: 0) } }
        case .fallo:
            estado = .error
            pintar()
            if vuelve { volverAEspera(en: 15) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in salirDeTerminal(con: s.codigo) } }
        }
    }

    /// Lo que piden los Ajustes al acabar bien: notificación (con su sonido), sonido suelto si no hay
    /// notificación, mostrar en Finder y copiar la ruta.
    func alTerminar(_ s: Sesion) {
        let a = s.ajustes
        let ruta = s.rutaVideo ?? ""
        let medida = s.avisoCarpeta == nil ? s.medida : "\(s.medida). Guardado en ~/Movies: la carpeta elegida no estaba disponible."
        if a.notificar {
            notificar(ruta: ruta, medida: medida, sonido: a.sonido, titulo: s.tituloAviso)
        } else if a.sonido {
            // El sonido de alerta del sistema, el que haya elegido el usuario.
            NSSound.beep()
        }
        if a.copiarRuta {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ruta, forType: .string)
        }
        if a.abrirEnFinder { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ruta)]) }
    }

    // MARK: Memoria de los últimos segundos

    /// La casilla «Memoria de los últimos N s» del menú: enciende o apaga.
    @objc func alternarMemoria() {
        if memoria != nil { apagarMemoria() } else { encenderMemoria() }
    }

    /// Enciende la memoria en la pantalla del puntero de ahora, con calidad, puntero y clics de los
    /// Ajustes, sin audio y con N de los Ajustes (o `segundos`, en la prueba). `luego`, cuando la
    /// captura ya corre. Si no arranca, se apaga y el menú dice por qué.
    func encenderMemoria(segundos: Int? = nil, luego: @escaping () -> Void = {}) {
        guard memoria == nil else { return }
        switch estado {
        case .espera, .hecho, .error: break
        default: NSSound.beep(); return
        }
        Memoria.borrarRestos()
        let a = Ajustes.leer()
        let p = elegirPantalla()
        let peticion = Peticion(destino: .pantalla, fps: a.calidad.fps(pantalla: p.id), bitrate: a.calidad.bitrate,
                                puntero: a.mostrarPuntero, clics: a.marcarClics && hayMacOS15())
        let m = Memoria(segundos: segundos ?? a.memoria, peticion: peticion, pantalla: p.id)
        m.alFallar = { [weak self, weak m] motivo in
            guard let self, let m, self.memoria === m else { return }
            self.apagarMemoria(aviso: "La memoria se ha apagado: \(motivo)")
        }
        memoria = m
        avisoMemoria = nil
        pintar()
        decir("Memoria: encendiendo en \(p.nombre), \(a.calidad.nombre), últimos \(m.segundos) s")
        m.arrancar { [weak self, weak m] error in
            guard let self, let m, self.memoria === m else { return }
            if let error { self.apagarMemoria(aviso: "No se pudo encender la memoria: \(error)"); return }
            decir("Memoria: encendida")
            luego()
        }
    }

    /// Apaga la memoria y borra sus segmentos. Con `aviso` (se apagó sola), el menú lo enseña; en
    /// la prueba, sale con 1.
    func apagarMemoria(aviso: String? = nil) {
        memoria?.apagar()
        memoria = nil
        memoriaEnPausa = false
        avisoMemoria = aviso
        if let a = arranquePendiente { arranquePendiente = nil; parandoMemoria = false; a() }
        if let aviso {
            avisar(aviso)
            if pruebaMemoria != nil { exit(1) }
        }
        pintar()
    }

    /// Antes de una grabación normal: para el stream de la memoria (la captura de la grabación
    /// espera en `arrancar` hasta que pare).
    func pausarMemoria() {
        guard let m = memoria, !memoriaEnPausa else { return }
        memoriaEnPausa = true
        parandoMemoria = true
        m.pausar { [weak self] in
            guard let self else { return }
            self.parandoMemoria = false
            decir("Memoria: en pausa")
            if let a = self.arranquePendiente { self.arranquePendiente = nil; a() }
        }
    }

    /// Al acabar la grabación normal (bien, mal o cancelada): la memoria vuelve.
    func reanudarMemoria() {
        guard memoriaEnPausa, let m = memoria else { return }
        memoriaEnPausa = false
        m.arrancar { [weak self, weak m] error in
            guard let self, let m, self.memoria === m else { return }
            if let error { self.apagarMemoria(aviso: "La memoria no pudo volver tras la grabación: \(error)"); return }
            decir("Memoria: de vuelta")
        }
        pintar()
    }

    @objc func guardarMemoriaDesdeMenu() { guardarMemoria() }

    /// «Guardar los últimos N s» y ⌃⌥⌘S: solo con la memoria encendida y sin grabación en curso.
    /// Al acabar, lo mismo que una grabación normal (✓, notificación, copiar la ruta… según los
    /// Ajustes). Si había menos de N s, guarda lo que hay y lo dice. `luego` recibe si hubo vídeo.
    func guardarMemoria(luego: @escaping (Bool) -> Void = { _ in }) {
        guard let m = memoria, !memoriaEnPausa, !guardandoMemoria else { NSSound.beep(); luego(false); return }
        switch estado {
        case .espera, .hecho, .error: break
        default: NSSound.beep(); luego(false); return
        }
        let s = Sesion()
        let carpeta = carpetaDeDestino(s)
        guardandoMemoria = true
        pintar()
        m.guardar(en: carpeta, sello: sello()) { [weak self] resultado in
            guard let self else { return }
            self.guardandoMemoria = false
            switch resultado {
            case .fallo(let motivo):
                avisar(motivo)
                self.notificarAviso("No se pudo guardar la memoria", motivo)
                self.pintar()
                luego(false)
            case .video(let ruta, let segundos, let n, let uniones):
                if pruebaMemoria != nil {
                    // Por las cuentas de la memoria; en el mp4, cada unión es el fotograma clave a ±1
                    // fotograma de aquí (el primero de cada segmento).
                    decir("Uniones entre segmentos (s del vídeo, ±1 fotograma): " + uniones.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: " "))
                }
                let corta = segundos < Double(m.segundos) - 0.5
                let pedidos = corta ? "solo había \(self.formato(segundos)) s en memoria, de \(m.segundos)" : "\(self.formato(segundos)) s"
                s.rutaVideo = ruta.path
                s.medida = "\(pedidos), \(n) fotogramas"
                s.tituloAviso = corta ? "Memoria guardada (\(self.formato(segundos, decimales: 0)) s)" : "Últimos \(m.segundos) s guardados"
                self.ultimoVideo = ruta.path
                if corta { decir("Memoria: solo había \(self.formato(segundos)) s de los \(m.segundos) pedidos; se guarda eso") }
                decir("Fotogramas: \(n) (en \(self.formato(segundos)) s)")
                decir("Hecho: \(ruta.path)")
                // Si mientras tanto empezó una grabación, solo el aviso: el ✓ pisaría su estado.
                switch self.estado {
                case .espera, .hecho, .error:
                    self.tokenEspera += 1
                    self.sesion = s
                    self.estado = .hecho
                    self.pintar()
                    self.alTerminar(s)
                    self.volverAEspera(en: 5)
                default:
                    self.alTerminar(s)
                }
                luego(true)
            }
        }
    }

    /// GRABAR_PANTALLA_PRUEBA_MEMORIA (README, para desarrolladores): enciende la memoria, guarda a
    /// los segundos pedidos, enseña los segmentos antes y después de apagarla y sale (por
    /// `NSApp.terminate`, el camino de ⌘Q). Con DESDE+DURANTE graba antes en normal, con la memoria
    /// en pausa. Imprime lo mismo que la terminal, con «Hecho: ruta».
    func probarMemoria(_ p: PruebaMemoria) {
        estado = .espera
        pintar()
        encenderMemoria(segundos: p.segundos) { [self] in
            if let g = p.grabar {
                DispatchQueue.main.asyncAfter(deadline: .now() + g.desde) { [self] in
                    decir("Prueba: grabación normal de \(formato(g.durante)) s con la memoria encendida")
                    duracionPedida = g.durante
                    empezar()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + p.encendida) { [self] in
                // Si la grabación de la prueba sigue, se espera a que acabe.
                func cuandoEnEspera(_ hacer: @escaping () -> Void) {
                    switch estado {
                    case .espera, .hecho, .error: hacer()
                    default: DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { cuandoEnEspera(hacer) }
                    }
                }
                cuandoEnEspera { [self] in
                    guard let m = memoria else { exit(1) }
                    decir("Segmentos antes de guardar: \(m.inventario())")
                    guardarMemoria { [self] ok in
                        guard ok else { exit(1) }
                        decir("Segmentos antes de apagar: \(m.inventario())")
                        apagarMemoria()
                        decir("Segmentos después de apagar: \(m.inventario())")
                        // Y salir con la memoria encendida: se vuelve a encender 3 s y se sale por
                        // el camino de ⌘Q; la carpeta se mira desde fuera cuando el proceso ya no está.
                        encenderMemoria(segundos: p.segundos) { [self] in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                                decir("Segmentos antes de salir: \(memoria?.inventario() ?? "sin memoria")")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Ajustes

    /// «Ajustes…» (⌘,): en cualquier estado salvo grabando. Abierta durante una grabación (por el
    /// atajo, por ejemplo), la ventana deshabilita sus controles hasta que termine.
    @objc func abrirAjustes() {
        if case .grabando = estado { NSSound.beep(); return }
        if ventanaAjustes == nil { ventanaAjustes = VentanaAjustes() }
        ventanaAjustes?.bloquear(hayCaptura())
        ventanaAjustes?.mostrar()
    }

    /// Menú principal de la app. No se ve (es de barra de menús), pero con la ventana de Ajustes
    /// delante es el que da ⌘, ⌘W, ⌘Q y la edición de texto (⌘C, ⌘V, ⌘A, ⌘Z) en sus campos.
    func montarMenuPrincipal() {
        let principal = NSMenu()
        func submenu(_ titulo: String, _ items: [(String, Selector?, String)]) -> NSMenu {
            let m = NSMenu(title: titulo)
            for (t, sel, tecla) in items {
                if t == "-" { m.addItem(.separator()); continue }
                m.addItem(withTitle: t, action: sel, keyEquivalent: tecla)
            }
            let padre = NSMenuItem(title: titulo, action: nil, keyEquivalent: "")
            padre.submenu = m
            principal.addItem(padre)
            return m
        }
        let app = submenu("Grabar pantalla", [("Ajustes…", #selector(abrirAjustes), ","), ("-", nil, ""),
                                              ("Salir de Grabar pantalla", #selector(salir), "q")])
        app.autoenablesItems = false
        for i in app.items where i.action != nil { i.target = self }
        ajustesPrincipal = app.items.first
        _ = submenu("Edición", [("Deshacer", Selector(("undo:")), "z"), ("Rehacer", Selector(("redo:")), "Z"), ("-", nil, ""),
                                ("Cortar", #selector(NSText.cut(_:)), "x"), ("Copiar", #selector(NSText.copy(_:)), "c"),
                                ("Pegar", #selector(NSText.paste(_:)), "v"), ("Seleccionar todo", #selector(NSText.selectAll(_:)), "a")])
        _ = submenu("Ventana", [("Cerrar", #selector(NSWindow.performClose(_:)), "w")])
        NSApp.mainMenu = principal
    }

    // MARK: Fotogramas

    /// «Sacar fotogramas»: `fotogramas <vídeo>` (muestreo por defecto) y abre en Finder la carpeta
    /// que imprime («Carpeta: …»). El script está junto a `grabar-pantalla` en el repo; si falta él
    /// o ffmpeg, un aviso con lo que dijo.
    @objc func sacarFotogramas() {
        guard !sacandoFotogramas, let video = (sesion?.rutaVideo ?? ultimoVideo) else { return }
        let herramienta = ((script as NSString).deletingLastPathComponent as NSString).appendingPathComponent("fotogramas")
        guard !script.isEmpty, FileManager.default.isExecutableFile(atPath: herramienta) else {
            alerta("No encuentro «fotogramas»", "Debería estar en \(script.isEmpty ? "el repo (falta GrabarPantallaScript en el Info.plist; reinstala con app/instalar.sh)" : herramienta).")
            return
        }
        guard FileManager.default.fileExists(atPath: video) else {
            alerta("El vídeo ya no está", video)
            return
        }
        sacandoFotogramas = true
        pintar()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: herramienta)
        p.arguments = [video]
        // LaunchServices deja un PATH sin Homebrew; `fotogramas` lo añade, pero ffmpeg puede estar en otro sitio.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = tubo
        p.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var texto = ""
            do {
                try p.run()
                texto = String(decoding: tubo.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
            } catch {
                texto = "No pude lanzar \(herramienta): \(error.localizedDescription)"
            }
            let ok = p.processIdentifier > 0 && !p.isRunning && p.terminationStatus == 0
            DispatchQueue.main.async { [self] in
                sacandoFotogramas = false
                pintar()
                let lineas = texto.split(separator: "\n").map(String.init)
                if ok, let c = lineas.first(where: { $0.hasPrefix("Carpeta: ") }) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: String(c.dropFirst(9)), isDirectory: true))
                } else {
                    alerta("No pude sacar los fotogramas", lineas.suffix(3).joined(separator: "\n"))
                }
                if let c = salidaPendiente { exit(c) }
            }
        }
    }

    /// Aviso modal. La app es de barra de menús: hay que traerla delante para que se vea.
    func alerta(_ titulo: String, _ texto: String) {
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let a = NSAlert()
        a.messageText = titulo
        a.informativeText = texto
        a.runModal()
    }

    // MARK: Icono y menú

    func tiempo() -> String {
        let s = Int(Date().timeIntervalSince(inicio))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    func simbolo(_ nombre: String) -> NSImage? {
        let img = NSImage(systemSymbolName: nombre, accessibilityDescription: "Grabar pantalla")
        img?.isTemplate = true
        return img
    }

    /// Icono propio de la barra: una circunferencia y, dentro y con el mismo centro exacto del
    /// lienzo, un punto relleno o un ✓ (record.circle, a tamaño de barra en una pantalla 1x,
    /// descentra el punto; checkmark.circle trae otra circunferencia). Sin `rojo` es plantilla y
    /// macOS lo tiñe; con `rojo` el punto va en rojo y la circunferencia en labelColor, que se
    /// resuelve al dibujar con la apariencia de la barra. Con `memoria` (encendida, en espera), la
    /// circunferencia va a trazos y el punto, más pequeño y en rojo: graba en segundo plano, pero
    /// no es una grabación (que lleva el aro entero, el punto grande y el tiempo).
    func iconoGrabar(rojo: Bool = false, hecho: Bool = false, memoria: Bool = false) -> NSImage {
        let lado: CGFloat = 16, grosor: CGFloat = 1.5, radioPunto: CGFloat = memoria ? 2.5 : 3.5
        let color = rojo || memoria
        let img = NSImage(size: NSSize(width: lado, height: lado), flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY)
            let radio = lado / 2 - grosor / 2 - 0.5
            let aro = NSBezierPath(ovalIn: NSRect(x: c.x - radio, y: c.y - radio, width: radio * 2, height: radio * 2))
            aro.lineWidth = grosor
            if memoria {
                // Ocho trazos iguales: la circunferencia mide 2πr ≈ 41 pt.
                let paso = 2 * .pi * radio / 8
                aro.setLineDash([paso * 0.6, paso * 0.4], count: 2, phase: 0)
            }
            (color ? NSColor.labelColor : .black).setStroke()
            aro.stroke()
            if hecho {
                // ✓ dentro de la caja del punto (7 x 7 pt), con el mismo trazo que la circunferencia.
                let v = NSBezierPath()
                v.move(to: NSPoint(x: c.x - 3.25, y: c.y + 0.25))
                v.line(to: NSPoint(x: c.x - 1, y: c.y - 2.25))
                v.line(to: NSPoint(x: c.x + 3.25, y: c.y + 2.5))
                v.lineWidth = grosor
                v.lineCapStyle = .round
                v.lineJoinStyle = .round
                NSColor.black.setStroke()
                v.stroke()
            } else {
                (color ? NSColor.systemRed : .black).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - radioPunto, y: c.y - radioPunto, width: radioPunto * 2, height: radioPunto * 2)).fill()
            }
            return true
        }
        img.isTemplate = !color
        img.accessibilityDescription = "Grabar pantalla"
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
        func fotogramas(_ t: String) {
            if sacandoFotogramas { fila("Sacando fotogramas…") } else { accion(t, #selector(sacarFotogramas)) }
        }
        func pieResidente() {
            guard residente else { return }
            menu.addItem(.separator())
            // Grabando, sin acción: el menú lo deja deshabilitado.
            var grabando = false
            if case .grabando = estado { grabando = true }
            accion("Ajustes…", grabando ? nil : #selector(abrirAjustes), ",")
            accion("Salir", #selector(salir), "q")
            ajustesPrincipal?.isEnabled = !grabando
            ventanaAjustes?.bloquear(hayCaptura())
        }
        /// «Grabar una ventana ▸»: vacío hasta que se abre (`menuNeedsUpdate` lo rellena con las de ese momento).
        func menuVentanas() {
            let sub = NSMenu()
            sub.delegate = self
            sub.addItem(withTitle: "Buscando ventanas…", action: nil, keyEquivalent: "").isEnabled = false
            let padre = NSMenuItem(title: "Grabar una ventana", action: nil, keyEquivalent: "")
            padre.submenu = sub
            menu.addItem(padre)
        }
        boton?.imagePosition = .imageLeft
        switch estado {
        case .espera:
            boton?.image = iconoGrabar(memoria: memoria != nil && !memoriaEnPausa)
            boton?.title = guardandoMemoria ? "Guardando…" : ""
            accion("Grabar", #selector(grabarPunteroDesdeMenu), atajo: true)
            accion("Grabar una región…", #selector(grabarRegionDesdeMenu))
            menuVentanas()
            let sub = NSMenu()
            for (i, p) in pantallasEnOrden().enumerated() {
                let it = NSMenuItem(title: p.pantalla.localizedName, action: #selector(grabarPantallaDesdeMenu(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                sub.addItem(it)
            }
            let padre = NSMenuItem(title: "Grabar pantalla", action: nil, keyEquivalent: "")
            padre.submenu = sub
            menu.addItem(padre)
            // Memoria: la casilla la enciende y la apaga; guardar, solo con ella encendida (sin
            // acción, el menú lo deja deshabilitado). N, el de la memoria encendida o el de los Ajustes.
            menu.addItem(.separator())
            let n = memoria?.segundos ?? Ajustes.leer().memoria
            let casilla = accion("Memoria de los últimos \(n) s", guardandoMemoria ? nil : #selector(alternarMemoria))
            casilla.state = memoria != nil ? .on : .off
            let guardar = accion("Guardar los últimos \(n) s", memoria != nil && !guardandoMemoria ? #selector(guardarMemoriaDesdeMenu) : nil, "s")
            guardar.keyEquivalentModifierMask = [.control, .option, .command]
            if guardandoMemoria { fila("Guardando la memoria…") }
            if let e = errorAtajoMemoria { fila(e) }
            if let a = avisoMemoria { fila(a) }
            if let v = ultimoVideo, FileManager.default.fileExists(atPath: v) {
                menu.addItem(.separator())
                fotogramas("Sacar fotogramas de la última grabación")
            }
            pieResidente()
        case .cuenta(let n):
            boton?.image = nil
            boton?.title = String(n)
            fila("Empieza en \(n)… · \(queSeGraba)")
            accion("Cancelar", #selector(cancelar), atajo: residente)
            fila("Clic en el icono: cancelar")
            pieResidente()
        case .iniciando:
            boton?.image = nil
            boton?.title = "Iniciando…"
            fila("Iniciando… · \(queSeGraba)")
            accion("Cancelar", #selector(cancelar), atajo: residente)
            fila("Clic en el icono: cancelar")
            pieResidente()
        case .grabando:
            boton?.image = iconoGrabar(rojo: true)
            boton?.title = tiempo()
            fila("Grabando \(tiempo()) · \(queSeGraba)")
            if let m = sesion?.avisoCarpeta { fila(m) }
            accion("Detener grabación", #selector(detener), residente ? "" : ".", atajo: residente)
            fila("Clic en el icono: detener")
            pieResidente()
        case .guardando:
            boton?.image = iconoGrabar()
            boton?.title = "Guardando…"
            fila("Guardando…")
            pieResidente()
        case .hecho:
            boton?.image = iconoGrabar(hecho: true)
            boton?.title = ""
            accion("Mostrar en Finder", #selector(mostrarEnFinder))
            fotogramas("Sacar fotogramas")
            if residente {
                accion("Grabar", #selector(grabarPunteroDesdeMenu), atajo: true)
                accion("Grabar una región…", #selector(grabarRegionDesdeMenu))
                menuVentanas()
            }
            pieResidente()
        case .error:
            boton?.image = simbolo("exclamationmark.triangle")
            boton?.title = ""
            fila(sesion?.ultimaLinea ?? "")
            accion("Cerrar", #selector(cerrar))
            if residente {
                accion("Grabar", #selector(grabarPunteroDesdeMenu), atajo: true)
                accion("Grabar una región…", #selector(grabarRegionDesdeMenu))
                menuVentanas()
            }
            pieResidente()
        }
        menuActual = menu
    }
}

let app = NSApplication.shared
let controlador = Controlador()
app.delegate = controlador
app.run()

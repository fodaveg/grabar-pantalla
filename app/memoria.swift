// Memoria de los últimos N segundos (experimento): mientras está encendida, la residente graba en
// segundo plano la pantalla del puntero en trozos cortos y conserva solo los que hacen falta para
// cubrir N s. «Guardar los últimos N s» (menú o ⌃⌥⌘S) los une en un mp4 sin reencodar. Sirve para
// capturar un fallo intermitente después de verlo, sin haber estado grabando a propósito.
//
// - Captura: un `SCStream` propio de la pantalla entera, con la calidad, el puntero y los clics de
//   los Ajustes (`Grabador.configuracion`) y sin audio.
// - Segmentos: un `AVAssetWriter` nuevo cada ~2 s (`duracionSegmento`), cortando en un fotograma:
//   ese fotograma es el primero del escritor nuevo y por eso fotograma clave, y el último del
//   anterior dura justo hasta él, así que entre segmentos no hay hueco. El escritor siguiente se
//   prepara a mitad del segmento, para que el corte no espere al codificador. Viven en
//   ~/Library/Caches/net.fodaveg.grabar-pantalla/memoria/<pid>/.
// - Guardar: cierra el segmento en curso en ese instante (y la memoria sigue, con el mismo
//   fotograma empezando el siguiente), une los segmentos con `AVMutableComposition`, recorta a los
//   últimos N s y exporta en passthrough (`AVAssetExportSession`).
// - Pausa: una grabación normal para el stream de la memoria antes de arrancar el suyo (nunca dos
//   `SCStream` a la vez) y la reanuda al acabar. Los segmentos se unen seguidos: el vídeo guardado
//   salta del antes al después de la grabación, sin hueco negro.
// - Apagar y salir borran los segmentos. Una carpeta de un proceso que ya no existe (muerto de
//   golpe) se borra al encender la memoria la próxima vez.
//
// Todo lo que toca escritores y segmentos corre en `cola`, la misma en la que llegan los fotogramas.
import AppKit
import AVFoundation
import ScreenCaptureKit

/// Lo que pide `GRABAR_PANTALLA_PRUEBA_MEMORIA="S,N[,DESDE+DURANTE]"` (README, para desarrolladores):
/// encender la memoria con N s, guardar a los S s de encendida, apagar y salir. Con DESDE+DURANTE,
/// además, una grabación normal de DURANTE s a los DESDE s, para probar la pausa en el mismo proceso;
/// con DESDE+c, esa grabación se cancela 1 s después de empezar (en la cuenta atrás, si la hay).
/// Una variable mal escrita sale con 2 sin hacer nada.
struct PruebaMemoria {
    var encendida: Double
    var segundos: Int
    var grabar: (desde: Double, durante: Double)?
    /// La grabación de `grabar` se cancela a 1 s de empezar (DESDE+c).
    var cancelar = false
}

let pruebaMemoria: PruebaMemoria? = {
    guard let v = ProcessInfo.processInfo.environment["GRABAR_PANTALLA_PRUEBA_MEMORIA"] else { return nil }
    let partes = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var p: PruebaMemoria?
    if partes.count == 2 || partes.count == 3, let s = Double(partes[0]), s > 0, let n = Int(partes[1]),
       (Ajustes.memoriaMinima...Ajustes.memoriaMaxima).contains(n) {
        p = PruebaMemoria(encendida: s, segundos: n)
        if partes.count == 3 {
            let t = partes[2].split(separator: "+").map(String.init)
            let cancelar = t.count == 2 && t[1] == "c"
            let g = t.compactMap { Double($0) }
            if cancelar, g.count == 1, g[0] >= 0, g[0] < s {
                // La duración no llega a contar: se cancela antes.
                p?.grabar = (g[0], 5)
                p?.cancelar = true
            } else if g.count == 2, g[0] >= 0, g[1] > 0, g[0] < s {
                p?.grabar = (g[0], g[1])
            } else {
                p = nil
            }
        }
    }
    guard let p else {
        avisar("GRABAR_PANTALLA_PRUEBA_MEMORIA=\"SEGUNDOS,N[,DESDE+DURANTE|DESDE+c]\" (N de \(Ajustes.memoriaMinima) a \(Ajustes.memoriaMaxima)), no «\(v)»")
        exit(2)
    }
    return p
}()

/// `@unchecked Sendable`: su estado solo se toca en `cola` (y las propiedades `let`), así que la
/// exportación, que corre en una `Task`, puede volver a ella.
final class Memoria: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Lo que deja «Guardar»: el vídeo, con lo que dura de verdad (menos que N si la memoria lleva
    /// menos tiempo encendida), sus fotogramas y en qué segundos del vídeo empieza cada segmento
    /// salvo el primero (las uniones, para comprobar que no hay hueco), o por qué no.
    enum Guardado { case video(ruta: URL, segundos: Double, fotogramas: Int, uniones: [Double]), fallo(String) }

    /// Lo que dura cada segmento, más o menos: se corta en el primer fotograma que llega pasado este
    /// tiempo (con la pantalla quieta, en el siguiente cambio).
    static let duracionSegmento = 2.0

    /// N: los segundos que se guardan. Se fijan al encender; cambiar el ajuste vale la próxima vez.
    let segundos: Int
    let peticion: Peticion
    let pantalla: CGDirectDisplayID
    let carpeta: URL
    /// La captura se cortó sola (pantalla desconectada, permiso retirado): por qué. Hilo principal.
    var alFallar: (String) -> Void = { _ in }

    /// Un segmento: su escritor mientras se escribe y lo que se sabe de él al cerrarlo.
    private final class Segmento {
        let url: URL
        var escritor: AVAssetWriter?
        var entrada: AVAssetWriterInput?
        var inicio = CMTime.invalid
        /// Hasta dónde llega (endSession). Inválido mientras se escribe.
        var fin = CMTime.invalid
        /// PTS de cada fotograma escrito, en segundos desde `inicio` (para contar los guardados).
        var tiempos: [Double] = []
        /// `finishWriting` terminó bien: el fichero se puede leer.
        var listo = false
        init(url: URL) { self.url = url }
        var duracion: CMTime { fin - inicio }
    }

    private let cola = DispatchQueue(label: "net.fodaveg.grabar-pantalla.memoria", qos: .userInitiated)
    private var stream: SCStream?
    /// Cerrados (listos o terminando de escribirse), del más viejo al más nuevo.
    private var cerrados: [Segmento] = []
    private var actual: Segmento?
    /// El escritor del segmento siguiente, ya arrancado, esperando al corte.
    private var siguiente: Segmento?
    /// Fotograma que espera al siguiente (o al corte) para saber cuánto dura, como en `Grabador`.
    private var retenido: CMSampleBuffer?
    private var numero = 0
    /// Escritores que están cerrando: guardar espera a que acaben.
    private let cierres = DispatchGroup()
    /// Medidas del vídeo de los segmentos. Si la pantalla cambia de resolución entre una pausa y la
    /// vuelta, lo anterior se descarta: una pista no mezcla dos tamaños.
    private var medidas: (ancho: Int, alto: Int)?
    /// Una exportación usa los segmentos: no se borra ninguno hasta que acabe.
    private var exportando = false
    private var apagada = false
    /// `stopCapture` pedido y sin terminar; si llega `reanudar` mientras, espera a que pare.
    private var parando = false
    private var arranquePendiente: (() -> Void)?

    init(segundos: Int, peticion: Peticion, pantalla: CGDirectDisplayID) {
        self.segundos = segundos
        self.peticion = peticion
        self.pantalla = pantalla
        carpeta = Memoria.raiz.appendingPathComponent(String(getpid()), isDirectory: true)
    }

    /// ~/Library/Caches/<identificador>/memoria: una carpeta por proceso dentro.
    static var raiz: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "net.fodaveg.grabar-pantalla", isDirectory: true)
            .appendingPathComponent("memoria", isDirectory: true)
    }

    /// Borra las carpetas de segmentos de procesos que ya no existen (una app muerta de golpe no
    /// pudo borrar las suyas).
    static func borrarRestos() {
        let fm = FileManager.default
        for nombre in (try? fm.contentsOfDirectory(atPath: raiz.path)) ?? [] {
            guard let pid = Int32(nombre), pid != getpid() else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? fm.removeItem(at: raiz.appendingPathComponent(nombre)) }
        }
    }

    /// Cuántos segmentos hay en la carpeta y cuánto ocupan, para la prueba y el README.
    func inventario() -> String {
        let fm = FileManager.default
        let nombres = ((try? fm.contentsOfDirectory(atPath: carpeta.path)) ?? []).filter { $0.hasSuffix(".mp4") }.sorted()
        let bytes = nombres.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: carpeta.appendingPathComponent($1).path)[.size] as? Int) ?? 0) }
        let existe = fm.fileExists(atPath: carpeta.path)
        return "\(nombres.count) segmento(s), \(String(format: "%.1f", Double(bytes) / 1_000_000)) MB en \(abreviar(carpeta.path))\(existe ? "" : " (la carpeta no existe)")"
    }

    // MARK: Encender, pausar, apagar

    /// Arranca la captura (al encender y al volver de una pausa). `luego` llega por el hilo
    /// principal con nil si la captura corre o con el motivo si no.
    func arrancar(luego: @escaping (String?) -> Void) {
        cola.async { [self] in
            if parando { arranquePendiente = { [self] in arrancar(luego: luego) }; return }
            guard !apagada, stream == nil else { return }
            let fallo = { (m: String) in DispatchQueue.main.async { luego(m) } }
            guard CGPreflightScreenCaptureAccess() else {
                DispatchQueue.main.async { CGRequestScreenCaptureAccess() }
                fallo(mensajePermiso)
                return
            }
            try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [self] contenido, error in
                cola.async { [self] in
                    guard !apagada, stream == nil else { return }
                    guard let contenido else { fallo(Memoria.describir(error)); return }
                    guard let d = contenido.displays.first(where: { $0.displayID == pantalla }) else {
                        fallo("No encuentro la pantalla de la memoria (¿se ha desconectado?)")
                        return
                    }
                    let modo = CGDisplayCopyDisplayMode(pantalla)
                    let m = ((modo?.pixelWidth ?? d.width) & ~1, (modo?.pixelHeight ?? d.height) & ~1)
                    if let antes = medidas, antes != m { descartarCerrados() }
                    medidas = m
                    let filtro = SCContentFilter(display: d, excludingApplications: Grabador.propias(de: contenido), exceptingWindows: [])
                    let s = SCStream(filter: filtro, configuration: Grabador.configuracion(peticion, ancho: m.0, alto: m.1, fuente: nil), delegate: self)
                    do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: cola) } catch { fallo(Memoria.describir(error)); return }
                    stream = s
                    s.startCapture { [self] error in
                        cola.async { [self] in
                            if let error {
                                if stream === s { stream = nil }
                                fallo(Memoria.describir(error))
                            } else {
                                DispatchQueue.main.async { luego(nil) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Para el stream (una grabación normal va a empezar) y cierra el segmento en curso en este
    /// instante. `luego` llega por el hilo principal cuando ScreenCaptureKit ha parado de verdad.
    func pausar(luego: @escaping () -> Void) {
        cola.async { [self] in
            guard let s = stream else { DispatchQueue.main.async(execute: luego); return }
            stream = nil
            cerrarActual(en: ahora())
            descartarSiguiente()
            parando = true
            s.stopCapture { [self] _ in
                cola.async { [self] in
                    parando = false
                    DispatchQueue.main.async(execute: luego)
                    if let a = arranquePendiente { arranquePendiente = nil; a() }
                }
            }
        }
    }

    /// Apaga del todo y borra los segmentos (también los de una exportación en curso, que entonces
    /// falla). Síncrono: al volver, la carpeta ya no está. Lo llaman apagar desde el menú y salir.
    func apagar() {
        cola.sync {
            apagada = true
            stream?.stopCapture { _ in }
            stream = nil
            retenido = nil
            for s in [actual, siguiente].compactMap({ $0 }) + cerrados where !s.listo { s.escritor?.cancelWriting() }
            actual = nil
            siguiente = nil
            cerrados = []
        }
        try? FileManager.default.removeItem(at: carpeta)
    }

    // MARK: Guardar

    /// Cierra el segmento en curso ahora mismo (la memoria sigue), espera a que todos estén escritos,
    /// une los de los últimos N s y los exporta sin reencodar a `carpetaDestino` como
    /// pantalla-`sello`-ultimos-Ns.mp4, con N lo que dure de verdad. `luego`, por el hilo principal.
    func guardar(en carpetaDestino: URL, sello: String, luego: @escaping (Guardado) -> Void) {
        cola.async { [self] in
            let fallo = { (m: String) in DispatchQueue.main.async { luego(.fallo(m)) } }
            guard !exportando else { fallo("Ya se está guardando la memoria"); return }
            if stream != nil, let a = actual, let r = retenido {
                let t = ahora()
                escribir(r, en: a, hasta: t)
                cerrar(a, en: t)
                actual = nil
                retenido = nil
                // El mismo fotograma sigue en pantalla: abre el segmento siguiente en este instante,
                // para que la memoria no tenga hueco si se vuelve a guardar luego.
                if let copia = Memoria.copia(r, en: t), let e = siguiente ?? nuevoSegmento() {
                    siguiente = nil
                    empezar(e, en: t)
                    actual = e
                    retenido = copia
                }
            }
            exportando = true
            cierres.notify(queue: cola) { [self] in
                let partes = partesDeLosUltimos()
                guard !partes.isEmpty else {
                    exportando = false
                    fallo("La memoria aún no tiene imagen: espera un momento")
                    return
                }
                let total = partes.reduce(CMTime.zero) { $0 + $1.duracion }
                let fotogramas = partes.reduce(0) { $0 + $1.fotogramas }
                var uniones: [Double] = []
                var t = CMTime.zero
                for p in partes.dropLast() { t = t + p.duracion; uniones.append(t.seconds) }
                let n = max(1, Int(total.seconds.rounded()))
                let ruta = carpetaDestino.appendingPathComponent("pantalla-\(sello)-ultimos-\(n)s.mp4")
                Task.detached { [self] in
                    var error: String?
                    do { try await Memoria.exportar(partes, a: ruta) } catch let e { error = e.localizedDescription }
                    cola.async { [self] in
                        exportando = false
                        podar()
                    }
                    DispatchQueue.main.async {
                        if let error { luego(.fallo("No se pudo guardar la memoria: \(error)")) } else { luego(.video(ruta: ruta, segundos: total.seconds, fotogramas: fotogramas, uniones: uniones)) }
                    }
                }
            }
        }
    }

    /// Un trozo del vídeo guardado: de `desde` (segundos dentro del segmento) a `desde + duracion`.
    private struct Parte { let url: URL; let desde: CMTime; let duracion: CMTime; let fotogramas: Int }

    /// Los segmentos listos que cubren los últimos N s, del más viejo al más nuevo, con el primero
    /// recortado por delante. Si no llegan a N s, todos.
    private func partesDeLosUltimos() -> [Parte] {
        let n = CMTime(seconds: Double(segundos), preferredTimescale: 90_000)
        var falta = n
        var partes: [Parte] = []
        for s in cerrados.reversed() where s.listo && falta > .zero {
            let d = s.duracion
            if d <= falta {
                partes.insert(Parte(url: s.url, desde: .zero, duracion: d, fotogramas: s.tiempos.count), at: 0)
                falta = falta - d
            } else {
                let desde = d - falta
                // El fotograma que se ve en `desde` es el último que empieza antes o en ese instante.
                let x = desde.seconds
                let cuenta = s.tiempos.filter { $0 > x }.count + (s.tiempos.contains { $0 <= x } ? 1 : 0)
                partes.insert(Parte(url: s.url, desde: desde, duracion: falta, fotogramas: cuenta), at: 0)
                falta = .zero
            }
        }
        return partes
    }

    /// Une las partes seguidas en una composición y la exporta en passthrough (sin reencodar) a `ruta`.
    private static func exportar(_ partes: [Parte], a ruta: URL) async throws {
        let comp = AVMutableComposition()
        guard let pista = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Memoria", code: 1, userInfo: [NSLocalizedDescriptionKey: "no se pudo crear la pista"])
        }
        var t = CMTime.zero
        for p in partes {
            let asset = AVURLAsset(url: p.url)
            guard let v = try await asset.loadTracks(withMediaType: .video).first else {
                throw NSError(domain: "Memoria", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(p.url.lastPathComponent) no tiene vídeo"])
            }
            // Lo que dice el fichero manda sobre las cuentas: no pedir más de lo que tiene.
            let rango = try await v.load(.timeRange)
            let duracion = CMTimeMinimum(p.duracion, rango.duration - p.desde)
            try pista.insertTimeRange(CMTimeRange(start: rango.start + p.desde, duration: duracion), of: v, at: t)
            t = t + duracion
        }
        try? FileManager.default.removeItem(at: ruta)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw NSError(domain: "Memoria", code: 3, userInfo: [NSLocalizedDescriptionKey: "no hay exportación passthrough"])
        }
        ex.outputURL = ruta
        ex.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        guard ex.status == .completed else {
            try? FileManager.default.removeItem(at: ruta)
            throw ex.error ?? NSError(domain: "Memoria", code: 4, userInfo: [NSLocalizedDescriptionKey: "la exportación no terminó"])
        }
    }

    // MARK: Segmentos (en `cola`)

    private func ahora() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Un escritor nuevo ya arrancado (`startWriting`), esperando su primer fotograma.
    private func nuevoSegmento() -> Segmento? {
        guard let m = medidas else { return nil }
        numero += 1
        let s = Segmento(url: carpeta.appendingPathComponent(String(format: "segmento-%06d.mp4", numero)))
        try? FileManager.default.removeItem(at: s.url)
        guard let w = try? AVAssetWriter(outputURL: s.url, fileType: .mp4) else { return nil }
        w.movieTimeScale = 90_000
        let e = Grabador.entradaVideo(peticion, ancho: m.ancho, alto: m.alto)
        guard w.canAdd(e) else { return nil }
        w.add(e)
        guard w.startWriting() else { return nil }
        s.escritor = w
        s.entrada = e
        return s
    }

    private func empezar(_ s: Segmento, en t: CMTime) {
        s.escritor?.startSession(atSourceTime: t)
        s.inicio = t
    }

    /// Escribe el fotograma `m` en `s` con duración hasta `fin`. Si el codificador está ocupado, le
    /// da hasta 100 ms antes de perderlo: un fotograma perdido en un corte sería un hueco.
    private func escribir(_ m: CMSampleBuffer, en s: Segmento, hasta fin: CMTime) {
        guard let w = s.escritor, let e = s.entrada, w.status == .writing else { return }
        let pts = m.presentationTimeStamp
        let duracion = CMTimeMaximum(fin - pts, CMTime(value: 1, timescale: peticion.fps))
        var t = CMSampleTimingInfo(duration: duracion, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copia: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: m, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &t, sampleBufferOut: &copia) == noErr, let copia else { return }
        let espera = Date().addingTimeInterval(0.1)
        while !e.isReadyForMoreMediaData, w.status == .writing, Date() < espera { usleep(2_000) }
        if e.isReadyForMoreMediaData, e.append(copia) { s.tiempos.append((pts - s.inicio).seconds) }
    }

    /// El fotograma `m` con su PTS movido a `t` (para abrir el segmento siguiente al guardar).
    private static func copia(_ m: CMSampleBuffer, en t: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var c: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: m, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &c) == noErr else { return nil }
        return c
    }

    /// Cierra `s` en `fin` (endSession) y lo pasa a `cerrados`; queda listo cuando acaba `finishWriting`.
    private func cerrar(_ s: Segmento, en fin: CMTime) {
        guard let w = s.escritor, w.status == .writing, !s.tiempos.isEmpty else {
            s.escritor?.cancelWriting()
            try? FileManager.default.removeItem(at: s.url)
            return
        }
        s.fin = fin
        s.entrada?.markAsFinished()
        w.endSession(atSourceTime: fin)
        cerrados.append(s)
        cierres.enter()
        w.finishWriting { [self] in
            cola.async { [self] in
                if w.status == .completed {
                    s.listo = true
                } else {
                    avisar("Memoria: no se pudo cerrar \(s.url.lastPathComponent): \(Memoria.describir(w.error))")
                    cerrados.removeAll { $0 === s }
                    try? FileManager.default.removeItem(at: s.url)
                }
                s.escritor = nil
                s.entrada = nil
                podar()
                cierres.leave()
            }
        }
    }

    /// Pausa o corte de la captura: el fotograma retenido dura hasta `t` y el segmento se cierra.
    private func cerrarActual(en t: CMTime) {
        if let a = actual {
            if let r = retenido { escribir(r, en: a, hasta: t) }
            cerrar(a, en: t)
        }
        actual = nil
        retenido = nil
    }

    private func descartarSiguiente() {
        siguiente?.escritor?.cancelWriting()
        if let s = siguiente { try? FileManager.default.removeItem(at: s.url) }
        siguiente = nil
    }

    /// Borra los segmentos que ya no hacen falta: los más viejos, en cuanto los más nuevos listos
    /// cubren N s. Mientras se exporta no se borra nada.
    private func podar() {
        guard !exportando else { return }
        let n = CMTime(seconds: Double(segundos), preferredTimescale: 90_000)
        var acumulado = CMTime.zero
        var sobran: [Segmento] = []
        for s in cerrados.reversed() {
            if acumulado >= n, s.listo { sobran.append(s) } else if s.listo { acumulado = acumulado + s.duracion }
        }
        for s in sobran { try? FileManager.default.removeItem(at: s.url) }
        cerrados.removeAll { s in sobran.contains { $0 === s } }
    }

    private func descartarCerrados() {
        for s in cerrados where s.listo { try? FileManager.default.removeItem(at: s.url) }
        cerrados.removeAll { $0.listo }
    }

    private static func describir(_ e: Error?) -> String {
        guard let e else { return "error desconocido" }
        if (e as NSError).domain == SCStreamErrorDomain, (e as NSError).code == SCStreamError.Code.userDeclined.rawValue { return mensajePermiso }
        return e.localizedDescription
    }

    // MARK: SCStreamOutput, SCStreamDelegate

    /// Cada fotograma completo: el retenido se escribe hasta él; si el segmento lleva ya
    /// `duracionSegmento`, se cierra aquí y este fotograma abre el siguiente.
    func stream(_ s: SCStream, didOutputSampleBuffer muestra: CMSampleBuffer, of tipo: SCStreamOutputType) {
        guard tipo == .screen, s === stream, muestra.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(muestra, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let bruto = info.first?[.status] as? Int, SCFrameStatus(rawValue: bruto) == .complete else { return }
        let pts = muestra.presentationTimeStamp
        // Uno capturado antes del corte de «Guardar» pero entregado después: ya está cubierto.
        if let r = retenido, pts <= r.presentationTimeStamp { return }
        if let a = actual {
            if let r = retenido { escribir(r, en: a, hasta: pts) }
            let edad = (pts - a.inicio).seconds
            if edad >= Memoria.duracionSegmento {
                cerrar(a, en: pts)
                actual = nil
            } else if siguiente == nil, edad >= Memoria.duracionSegmento / 2 {
                siguiente = nuevoSegmento()
            }
        }
        if actual == nil {
            guard let e = siguiente ?? nuevoSegmento() else {
                retenido = nil
                avisar("Memoria: no se pudo abrir un segmento nuevo")
                return
            }
            siguiente = nil
            empezar(e, en: pts)
            actual = e
        }
        retenido = muestra
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        cola.async { [self] in
            guard s === stream else { return }
            stream = nil
            cerrarActual(en: ahora())
            descartarSiguiente()
            let m = Memoria.describir(error)
            DispatchQueue.main.async { [self] in alFallar(m) }
        }
    }
}

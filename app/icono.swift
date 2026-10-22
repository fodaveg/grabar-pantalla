// Dibuja el icono de la app (círculo rojo con una pantalla blanca) y escribe el .iconset en la
// carpeta que se pasa como argumento; instalar.sh lo convierte con iconutil. Sin PNG en el repo.
import AppKit

guard CommandLine.arguments.count > 1 else { fatalError("uso: icono <carpeta.iconset>") }
let destino = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destino, withIntermediateDirectories: true)

/// Pinta el icono en un lienzo de `lado` x `lado` píxeles: círculo de ~80 % del lienzo y símbolo
/// «display» blanco de ~50 % del diámetro.
func png(lado: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: lado, pixelsHigh: lado, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let l = CGFloat(lado), d = l * 0.8, m = (l - d) / 2
    let circulo = NSRect(x: m, y: m, width: d, height: d)
    let sombra = NSShadow()
    sombra.shadowColor = NSColor.black.withAlphaComponent(0.3)
    sombra.shadowBlurRadius = l * 0.02
    sombra.shadowOffset = NSSize(width: 0, height: -l * 0.012)
    NSGraphicsContext.saveGraphicsState()
    sombra.set()
    NSGradient(starting: NSColor(red: 1.0, green: 0.36, blue: 0.32, alpha: 1), ending: NSColor(red: 0.85, green: 0.12, blue: 0.14, alpha: 1))!
        .draw(in: NSBezierPath(ovalIn: circulo), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let cfg = NSImage.SymbolConfiguration(pointSize: d * 0.5, weight: .regular).applying(.init(paletteColors: [.white]))
    if let sim = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let t = sim.size
        let k = min(d * 0.5 / t.width, d * 0.5 / t.height)
        let w = t.width * k, h = t.height * k
        sim.draw(in: NSRect(x: (l - w) / 2, y: (l - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try png(lado: base).write(to: URL(fileURLWithPath: "\(destino)/icon_\(base)x\(base).png"))
    try png(lado: base * 2).write(to: URL(fileURLWithPath: "\(destino)/icon_\(base)x\(base)@2x.png"))
}

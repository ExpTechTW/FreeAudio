// Renders Packaging/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
                                                    color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.56, blue: 1, alpha: 1), NSColor(srgbRed: 0.1, green: 0.27, blue: 0.85, alpha: 1)])!
        .draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = root.appendingPathComponent("Packaging/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")

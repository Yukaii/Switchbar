// Renders Switchbar's app icon into an .iconset directory, ready for `iconutil`.
//
//   swift scripts/generate-icon.swift <output.iconset>
//
// Keep the design in sync with `AppIconImage` in SettingsView.swift, which draws
// the same icon for un-bundled development builds.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <output.iconset>\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 1024, height: 1024)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: 824pt rounded square centred on a 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.31, green: 0.56, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.36, green: 0.27, blue: 0.93, alpha: 1)
    )!
    gradient.draw(in: path, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let size = symbol.size
        let origin = NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: size))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]

for (points, scale) in sizes {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let fileURL = outputURL.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try renderIcon(pixels: points * scale).write(to: fileURL)
}

print("Wrote \(sizes.count) icon sizes to \(outputURL.path)")

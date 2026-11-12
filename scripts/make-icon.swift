// Builds Resources/AppIcon.icns and the menu bar icon from two drawings of
// the fig newton:
//   swift scripts/make-icon.swift
// Resources/AppIcon-source.png is the finished 1024 icon, rounded square,
// shadow and margin included (Apple's 1024 grid: 824 pt body, ~185 pt corner
// radius, 100 pt margin), so the app icon is just that image at each size.
// Resources/MenuBarIcon-source.png is the three-quarter newton glyph in black
// on transparent; it becomes a template image (macOS tints it for light and
// dark menu bars), 18 pt tall.
// Both sources are exported from docs/design/newton-icon-mocks.html
// (#export=pap and #export=block); redraw them there, not here.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconURL = root.appendingPathComponent("Resources/AppIcon-source.png")
let glyphURL = root.appendingPathComponent("Resources/MenuBarIcon-source.png")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
guard let icon = NSImage(contentsOf: iconURL) else { fatalError("missing \(iconURL.path)") }
guard let glyph = NSImage(contentsOf: glyphURL) else { fatalError("missing \(glyphURL.path)") }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")

// MARK: Menu bar silhouette

/// The glyph's coverage is its alpha, cropped to the drawn pixels and
/// area-averaged down to the menu bar height.
func silhouette(heightPx: Int) -> Data {
    guard let tiff = glyph.tiffRepresentation, let src = NSBitmapImageRep(data: tiff) else { fatalError("bad glyph") }
    let w = src.pixelsWide, h = src.pixelsHigh
    var minX = w, minY = h, maxX = 0, maxY = 0
    var mask = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            guard let c = src.colorAt(x: x, y: y) else { continue }
            if c.alphaComponent > 0.5 {
                mask[y * w + x] = true
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    let boxW = maxX - minX + 1, boxH = maxY - minY + 1
    let outH = heightPx, outW = Int((Double(boxW) / Double(boxH) * Double(outH)).rounded(.up))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Area-average the mask into each output pixel for smooth edges.
    for oy in 0..<outH {
        for ox in 0..<outW {
            let x0 = minX + ox * boxW / outW, x1 = max(x0 + 1, minX + (ox + 1) * boxW / outW)
            let y0 = minY + oy * boxH / outH, y1 = max(y0 + 1, minY + (oy + 1) * boxH / outH)
            var on = 0, total = 0
            for y in y0..<min(y1, h) { for x in x0..<min(x1, w) { total += 1; if mask[y * w + x] { on += 1 } } }
            let a = total == 0 ? 0 : CGFloat(on) / CGFloat(total)
            rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: a), atX: ox, y: oy)
        }
    }
    return rep.representation(using: .png, properties: [:])!
}

try silhouette(heightPx: 18).write(to: root.appendingPathComponent("Resources/MenuBarIcon.png"))
try silhouette(heightPx: 36).write(to: root.appendingPathComponent("Resources/MenuBarIcon@2x.png"))
try silhouette(heightPx: 256).write(to: root.appendingPathComponent("Resources/MenuBarIcon-preview.png"))
print("wrote menu bar icons")

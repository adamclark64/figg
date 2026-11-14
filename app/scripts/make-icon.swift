// Builds Resources/AppIcon.icns and the menu bar icon from Resources/figg-logo.png.
//   swift scripts/make-icon.swift
// App icon: the logo on a white macOS-style rounded square (Apple's 1024
// grid: 824 pt body, ~185 pt corner radius, 100 pt margin).
// Menu bar icon: a one-colour silhouette of the fig (template image, so
// macOS tints it for light/dark menu bars), 18 pt tall.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let logoURL = root.appendingPathComponent("Resources/figg-logo.png")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
guard let logo = NSImage(contentsOf: logoURL) else { fatalError("missing \(logoURL.path)") }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // Soft drop shadow like system icons.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The logo already sits on white, so it blends into the body.
    shape.addClip()
    logo.draw(in: body.insetBy(dx: -30 * s, dy: -30 * s), from: .zero, operation: .sourceOver, fraction: 1)
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

/// Pixels that belong to the fig: coloured (saturated) or dark. The white
/// background and the grey drop shadow are both unsaturated and light.
func silhouette(heightPx: Int) -> Data {
    guard let tiff = logo.tiffRepresentation, let src = NSBitmapImageRep(data: tiff) else { fatalError("bad logo") }
    let w = src.pixelsWide, h = src.pixelsHigh
    var minX = w, minY = h, maxX = 0, maxY = 0
    var mask = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
            let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
            if hi - lo > 0.12 || hi < 0.45 {
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

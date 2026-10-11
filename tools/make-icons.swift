// Generates the app icon (Resources/AppIcon.icns) and the menu bar glyph
// (Resources/MenuBarIcon.png, @2x) for concept "A — Dot X".
// Usage: swift tools/make-icons.swift   (run from the repository root)
import AppKit
import Foundation

let red = CGColor(red: 0xD7 / 255, green: 0x19 / 255, blue: 0x21 / 255, alpha: 1)

/// Dot X on a 7×7 grid: both diagonals, centre dot highlighted.
func dotXPoints(pitch: CGFloat) -> [(x: CGFloat, y: CGFloat, center: Bool)] {
    var pts: [(CGFloat, CGFloat, Bool)] = []
    for i in 0..<7 { for j in 0..<7 where i == j || i + j == 6 {
        pts.append((CGFloat(j - 3) * pitch, CGFloat(3 - i) * pitch, i == 3 && j == 3))
    } }
    return pts
}

func pngData(size: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Squircle (superellipse, n = 5) like the macOS icon shape.
func squircle(center: CGPoint, half: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 5, steps = 160
    for k in 0..<steps {
        let t = CGFloat(k) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: center.x + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                        y: center.y + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        k == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func drawAppIcon(_ ctx: CGContext, _ size: CGFloat) {
    let u = size / 1024                       // work on a 1024 grid
    let center = CGPoint(x: size / 2, y: size / 2)
    // Body: 824 / 1024 of the canvas, with a soft drop shadow, as in Apple's icon template.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 22 * u, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle(center: center, half: 412 * u))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(squircle(center: center, half: 412 * u))
    ctx.setStrokeColor(CGColor(gray: 0.17, alpha: 1))
    ctx.setLineWidth(3 * u)
    ctx.strokePath()
    // Dots.
    let pitch = 80 * u, radius = 35 * u
    for p in dotXPoints(pitch: pitch) {
        ctx.setFillColor(p.center ? red : CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: center.x + p.x - radius, y: center.y + p.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// Template glyph: black on transparent; macOS tints it for light/dark menu bars.
func drawGlyph(_ ctx: CGContext, _ size: CGFloat) {
    let pitch = size / 7.4, radius = pitch * 0.46
    let c = size / 2
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    for p in dotXPoints(pitch: pitch) {
        ctx.fillEllipse(in: CGRect(x: c + p.x - radius, y: c + p.y - radius, width: radius * 2, height: radius * 2))
    }
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try pngData(size: base, draw: drawAppIcon).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try pngData(size: base * 2, draw: drawAppIcon).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
try pngData(size: 18, draw: drawGlyph).write(to: URL(fileURLWithPath: "Resources/MenuBarIcon.png"))
try pngData(size: 36, draw: drawGlyph).write(to: URL(fileURLWithPath: "Resources/MenuBarIcon@2x.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "Icons written to Resources/" : "iconutil failed")

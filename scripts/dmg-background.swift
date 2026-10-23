// Draws the DMG window background: Claude's cream paper, the app name in serif, and a dashed clay
// arrow from the app (left) to Applications (right). Icon centers must match make-dmg.sh.
//
//     swift scripts/dmg-background.swift OUT_DIR   → OUT_DIR/background.png (1×) and background@2x.png
import AppKit

let width: CGFloat = 600, height: CGFloat = 400
let appCenter = CGPoint(x: 160, y: 205), appsCenter = CGPoint(x: 440, y: 205)   // top-left origin, as Finder counts

func hex(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
}

func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

func centered(_ text: String, font: NSFont, color: NSColor, y: CGFloat, kern: CGFloat = 0) {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    let size = string.size()
    string.draw(at: CGPoint(x: (width - size.width) / 2, y: y))
}

func render(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)   // 72 dpi at 1×, 144 at 2×
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    // Flip, so the layout reads top-down like Finder's icon positions.
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
    let flipped = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.current = flipped

    // Paper, a little lighter at the top.
    NSGradient(starting: hex(0xFBFAF6), ending: hex(0xEFECE2))!.draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: 90)
    // The pet's stage grid, faint.
    hex(0x1F1E1D, 0.05).setFill()
    for y in stride(from: CGFloat(6), to: height, by: 10) {
        for x in stride(from: CGFloat(6), to: width, by: 10) { CGRect(x: x, y: y, width: 1, height: 1).fill() }
    }
    // Soft wells under both icons.
    for center in [appCenter, appsCenter] {
        let glow = NSGradient(colors: [hex(0xD97757, 0.13), hex(0xD97757, 0)])!
        glow.draw(fromCenter: center, radius: 0, toCenter: center, radius: 96, options: [])
    }

    centered("Claude Pet", font: serif(30, .medium), color: hex(0x1F1E1D), y: 40)
    centered("Glisse le pet dans Applications · Drag the pet to Applications",
             font: .systemFont(ofSize: 12.5), color: hex(0x5E5D59), y: 84)

    // Dashed arc from app to Applications, with a hand-drawn head.
    let start = CGPoint(x: appCenter.x + 78, y: appCenter.y - 4)
    let end = CGPoint(x: appsCenter.x - 82, y: appsCenter.y - 4)
    let arc = NSBezierPath()
    arc.move(to: start)
    arc.curve(to: end, controlPoint1: CGPoint(x: start.x + 40, y: start.y - 34), controlPoint2: CGPoint(x: end.x - 40, y: end.y - 34))
    arc.lineWidth = 2.5
    arc.lineCapStyle = .round
    arc.setLineDash([1, 7], count: 2, phase: 0)
    hex(0xC96442).setStroke()
    arc.stroke()
    // Arms at ±32° from the curve's tangent at the end (from its last control point).
    let angle = atan2(34.0, 40.0)
    let head = NSBezierPath()
    for (i, side) in [-1.0, 1.0].enumerated() {
        let a = angle + .pi - side * 0.56
        let arm = CGPoint(x: end.x + 12 * cos(a), y: end.y + 12 * sin(a))
        if i == 0 { head.move(to: arm); head.line(to: end) } else { head.line(to: arm) }
    }
    head.lineWidth = 2.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    centered("Puis ouvre-le depuis Applications · Then open it from Applications",
             font: .systemFont(ofSize: 11), color: hex(0x8F8D85), y: 322)   // clear of a path bar, if Finder shows one

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
render(scale: 1, to: out.appendingPathComponent("background.png"))
render(scale: 2, to: out.appendingPathComponent("background@2x.png"))

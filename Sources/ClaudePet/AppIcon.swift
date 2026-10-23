import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The app icon, drawn from the pet's own idle frame: a cream tile with the pixel pet centered at an
/// integer scale, so every pixel stays a crisp square. `--export-icon DIR` writes an .iconset that
/// scripts/make-icon.sh turns into Resources/AppIcon.icns.
enum AppIcon {
    /// iconutil's names: (points, scale).
    static let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

    static func exportIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (points, scale) in sizes {
            let pixels = points * scale
            guard let image = render(pixels: pixels) else { continue }
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            let url = directory.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// The pet without its bubble, cropped to its opaque pixels (body, legs and ground shadow).
    private static func sprite() -> PixelCanvas {
        let frame = SpriteComposer.frame(state: .idle, tool: nil, t: 0, bubble: false)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<frame.height { for x in 0..<frame.width where frame.alpha(x, y) > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        var crop = PixelCanvas(width: maxX - minX + 1, height: maxY - minY + 1)
        for y in minY...maxY { for x in minX...maxX { crop.set(x - minX, y - minY, frame.pixel(x, y)) } }
        return crop
    }

    static func render(pixels size: Int) -> CGImage? {
        let pet = sprite()
        let s = CGFloat(size)
        // Apple's grid: an 824/1024 tile, centered, leaving room for the drop shadow.
        let tileSide = s * 824 / 1024
        var scale = Int((tileSide * 0.6 / CGFloat(pet.width)).rounded())
        while scale > 1, CGFloat(scale * pet.width) > tileSide * 0.74 { scale -= 1 }
        // Too small for one pixel per pixel (16 px): draw it bigger, then let it be downsampled.
        if scale < 1 {
            guard let big = render(pixels: size * 4) else { return nil }
            return resample(big, to: size)
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let tile = CGRect(x: (s - tileSide) / 2, y: (s - tileSide) / 2 + s * 0.008, width: tileSide, height: tileSide)
        let radius = tileSide * 0.225
        let path = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Soft drop shadow under the tile.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(path)
        ctx.setFillColor(color(0xF0EEE6))
        ctx.fillPath()
        ctx.restoreGState()

        // Cream paper, a little lighter at the top.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let paper = CGGradient(colorsSpace: space, colors: [color(0xFBFAF6), color(0xEDE9DD)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        }
        // The stage's faint pixel grid, only where it can still be seen.
        if size >= 128 {
            let step = tileSide / 22
            let dot = max(1, (s / 512).rounded())
            ctx.setFillColor(color(0x1F1E1D, alpha: 0.06))
            var y = tile.minY + step / 2
            while y < tile.maxY {
                var x = tile.minX + step / 2
                while x < tile.maxX {
                    ctx.fill(CGRect(x: x.rounded(), y: y.rounded(), width: dot, height: dot))
                    x += step
                }
                y += step
            }
        }
        let petSize = CGSize(width: CGFloat(pet.width * scale), height: CGFloat(pet.height * scale))
        // Whole pixels: the sprite's grid lands on the bitmap's.
        let origin = CGPoint(x: ((s - petSize.width) / 2).rounded(), y: ((s - petSize.height) / 2 - tileSide * 0.02).rounded())
        if let glow = CGGradient(colorsSpace: space, colors: [color(0xD97757, alpha: 0.28), color(0xD97757, alpha: 0)] as CFArray,
                                 locations: [0, 1]) {
            let center = CGPoint(x: s / 2, y: origin.y + petSize.height * 0.55)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: tileSide * 0.48, options: [])
        }
        ctx.restoreGState()

        // Hairline edge, so the tile holds on a light Dock.
        ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: s / 1024, dy: s / 1024), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(color(0x000000, alpha: 0.08))
        ctx.setLineWidth(max(1, s / 512))
        ctx.strokePath()

        if let image = pet.makeImage() {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(origin: origin, size: petSize))
        }
        return ctx.makeImage()
    }

    private static func resample(_ image: CGImage, to size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

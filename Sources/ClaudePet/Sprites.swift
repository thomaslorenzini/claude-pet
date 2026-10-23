import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small RGBA pixel grid, rendered nearest-neighbor.
struct PixelCanvas {
    /// Size of the regular (floating) frames.
    static let standardWidth = 24
    static let standardHeight = 22

    let width: Int
    let height: Int
    /// 0xRRGGBBAA, row 0 is the top row.
    private(set) var pixels: [UInt32]

    init(width: Int = PixelCanvas.standardWidth, height: Int = PixelCanvas.standardHeight) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: 0, count: width * height)
    }

    func pixel(_ x: Int, _ y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    mutating func set(_ x: Int, _ y: Int, _ color: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = color
    }

    mutating func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: UInt32) {
        for y in y0...y1 { for x in x0...x1 { set(x, y, color) } }
    }

    mutating func draw(_ glyph: Glyph, at x: Int, _ y: Int, _ color: UInt32) {
        for (dy, row) in glyph.rows.enumerated() {
            for (dx, ch) in row.enumerated() where ch == "#" { set(x + dx, y + dy, color) }
        }
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 {
        UInt8(pixel(x, y) & 0xFF)
    }

    func makeImage() -> CGImage? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(pixels.count * 4)
        for p in pixels {
            let a = p & 0xFF
            // Premultiplied alpha.
            bytes.append(UInt8(((p >> 24) & 0xFF) * a / 255))
            bytes.append(UInt8(((p >> 16) & 0xFF) * a / 255))
            bytes.append(UInt8(((p >> 8) & 0xFF) * a / 255))
            bytes.append(UInt8(a))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

struct Glyph {
    let rows: [[Character]]
    init(_ rows: String...) { self.rows = rows.map(Array.init) }

    static let bang = Glyph("..#..", "..#..", "..#..", ".....", "..#..")
    static let heart = Glyph(".#.#.", "#####", "#####", ".###.", "..#..")
    static let zed = Glyph("#####", "...#.", "..#..", ".#...", "#####")
    static let prompt = Glyph("#....", ".#...", "#....", ".....", ".###.")
    static let pencil = Glyph("...##", "..###", ".###.", "###..", "#....")
    static let magnifier = Glyph(".##..", "#..#.", "#..#.", ".###.", "....#")
    static let globe = Glyph(".###.", "#.#.#", "#####", "#.#.#", ".###.")
    static let agents = Glyph("##.##", "##.##", ".....", "##.##", "##.##")
    static let gear = Glyph("#.#.#", ".###.", "##.##", ".###.", "#.#.#")

    static func forTool(_ tool: ToolKind?) -> Glyph {
        switch tool {
        case .bash: return .prompt
        case .edit: return .pencil
        case .read: return .magnifier
        case .web: return .globe
        case .agent: return .agents
        case .other, .none: return .gear
        }
    }
}

enum Palette {
    static let body: UInt32 = 0xD9_77_57_FF
    static let bodyShade: UInt32 = 0xB5_5A_3C_FF
    static let bodyError: UInt32 = 0xC8_3E_32_FF
    static let eye: UInt32 = 0x1E_1A_18_FF
    static let bubble: UInt32 = 0xFF_FF_FF_F2
    static let outline: UInt32 = 0x3A_34_30_FF
    static let shadow: UInt32 = 0x00_00_00_40
    static let ink: UInt32 = 0x2B_2B_2B_FF
    static let yellow: UInt32 = 0xE8_A3_17_FF
    static let red: UInt32 = 0xD6_33_2B_FF
    static let pink: UInt32 = 0xE8_4D_7A_FF
    static let blue: UInt32 = 0x5B_8F_D9_FF
    static let light: UInt32 = 0xF2_EE_EA_FF
}

/// Builds every frame procedurally. This is the single place to swap in real assets later.
enum SpriteComposer {
    enum Eyes { case open, closed, up, happy, cross }

    /// Compact frames used in the notch: the body cropped from a regular frame, with the status icon
    /// beside it instead of in a bubble above, so the pet can be twice as big in 32 pt.
    static let compactWidth = 27
    static let compactHeight = 13
    /// Where the compact crop starts inside a regular frame.
    static let compactOrigin = (x: 1, y: 8)

    /// `t` advances at `PetController.fps`.
    static func compactFrame(state: PetState, tool: ToolKind?, t: Int) -> PixelCanvas {
        let full = frame(state: state, tool: tool, t: t, bubble: false)
        var c = PixelCanvas(width: compactWidth, height: compactHeight)
        for y in 0..<compactHeight {
            for x in 0..<20 {
                let p = full.pixel(x + compactOrigin.x, y + compactOrigin.y)
                // The ground shadow is pointless on black.
                if p != Palette.shadow { c.set(x, y, p) }
            }
        }
        let iconX = 21, iconY = 4
        switch state {
        case .thinking:
            for i in 0..<((t / 2) % 4) { c.set(iconX + i * 2, iconY + 4, Palette.light) }
        case .working:
            c.draw(Glyph.forTool(tool), at: iconX, iconY, Palette.light)
        case .error:
            c.draw(.bang, at: iconX, iconY, Palette.red)
        case .waiting:
            if t % 4 < 3 { c.draw(.bang, at: iconX, iconY, Palette.yellow) }
        case .happy:
            c.draw(.heart, at: iconX, iconY, Palette.pink)
        case .sleeping:
            c.draw(.zed, at: iconX, iconY - (t / 3) % 2, Palette.blue)
        case .idle:
            break
        }
        return c
    }

    /// `t` advances at `PetController.fps`.
    static func frame(state: PetState, tool: ToolKind?, t: Int, bubble showsBubble: Bool = true) -> PixelCanvas {
        var c = PixelCanvas()
        var dx = 0, dy = 0
        var eyes = Eyes.open
        var leftArmUp = false, rightArmUp = false
        var walking = false
        var color = Palette.body

        switch state {
        case .idle:
            dy = (t / 4) % 2
            eyes = t % 16 == 15 ? .closed : .open
        case .thinking:
            eyes = .up
            dy = (t / 3) % 2
        case .working:
            walking = true
            leftArmUp = t % 2 == 0
            rightArmUp = !leftArmUp
            dy = t % 2 == 0 ? 0 : -1
        case .error:
            eyes = .cross
            dx = t % 2 == 0 ? -1 : 1
            color = t % 4 < 2 ? Palette.bodyError : Palette.body
        case .waiting:
            rightArmUp = t % 2 == 0
            dy = t % 4 == 0 ? -1 : 0
        case .happy:
            eyes = .happy
            leftArmUp = true
            rightArmUp = true
            dy = t % 2 == 0 ? -1 : 0
        case .sleeping:
            eyes = .closed
            dy = 1
        }

        // Leave room above the head for the bubble.
        dy += 2

        // Ground shadow stays put while the body bobs.
        c.fill(5, 21, 16, 21, Palette.shadow)

        // Legs.
        for (i, x) in [5, 7, 14, 16].enumerated() {
            let lifted = walking && (i % 2 == t % 2)
            c.fill(x + dx, 16 + dy, x + dx, lifted ? 16 + dy : 17 + dy, Palette.bodyShade)
        }

        // Body.
        c.fill(4 + dx, 8 + dy, 17 + dx, 15 + dy, color)
        c.fill(4 + dx, 15 + dy, 17 + dx, 15 + dy, Palette.bodyShade)

        // Arms.
        let leftY = leftArmUp ? 8 : 12
        let rightY = rightArmUp ? 8 : 12
        c.fill(2 + dx, leftY + dy, 3 + dx, leftY + 1 + dy, color)
        c.fill(18 + dx, rightY + dy, 19 + dx, rightY + 1 + dy, color)

        drawEyes(eyes, into: &c, dx: dx, dy: dy)
        guard showsBubble else { return c }

        switch state {
        case .thinking:
            bubble(into: &c) { c in
                for i in 0..<((t / 2) % 4) { c.set(17 + i * 2, 4, Palette.ink) }
            }
        case .working:
            bubble(into: &c) { $0.draw(Glyph.forTool(tool), at: 17, 2, Palette.ink) }
        case .error:
            bubble(into: &c) { $0.draw(.bang, at: 17, 2, Palette.red) }
        case .waiting:
            bubble(into: &c) { if t % 4 < 3 { $0.draw(.bang, at: 17, 2, Palette.yellow) } }
        case .happy:
            bubble(into: &c) { $0.draw(.heart, at: 17, 2, Palette.pink) }
        case .sleeping:
            let phase = (t / 3) % 3
            c.draw(.zed, at: 17 + phase, 6 - phase * 2, Palette.blue)
        case .idle:
            break
        }
        return c
    }

    private static func drawEyes(_ eyes: Eyes, into c: inout PixelCanvas, dx: Int, dy: Int) {
        for ex in [7, 14] {
            let x = ex + dx
            switch eyes {
            case .open:
                c.fill(x, 11 + dy, x, 12 + dy, Palette.eye)
            case .up:
                c.fill(x + 1, 10 + dy, x + 1, 11 + dy, Palette.eye)
            case .closed:
                c.fill(x - 1, 12 + dy, x, 12 + dy, Palette.eye)
            case .happy:
                c.set(x - 1, 12 + dy, Palette.eye)
                c.set(x, 11 + dy, Palette.eye)
                c.set(x + 1, 12 + dy, Palette.eye)
            case .cross:
                for (px, py) in [(-1, 10), (1, 10), (0, 11), (-1, 12), (1, 12)] {
                    c.set(x + px, py + dy, Palette.eye)
                }
            }
        }
    }

    /// White speech bubble in the top-right corner, 9×9 with a tail; content area is (17…21, 2…6).
    private static func bubble(into c: inout PixelCanvas, content: (inout PixelCanvas) -> Void) {
        c.fill(15, 1, 23, 7, Palette.outline)
        c.fill(16, 0, 22, 8, Palette.outline)
        c.fill(16, 1, 22, 7, Palette.bubble)
        c.set(15, 9, Palette.outline)
        content(&c)
    }

    /// Writes every state/frame as upscaled PNGs, for previewing or as a base for real assets.
    static func export(to directory: URL, scale: Int = 8, frames: Int = 8) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let variants: [(PetState, ToolKind?)] = PetState.allCases.flatMap { state -> [(PetState, ToolKind?)] in
            state == .working ? ToolKind.allCases.map { (state, $0) } : [(state, nil)]
        }
        for (state, tool) in variants {
            for t in 0..<frames {
                guard let image = frame(state: state, tool: tool, t: t).makeImage(),
                      let scaled = upscale(image, by: scale) else { continue }
                let name = [state.rawValue, tool?.rawValue, String(t)].compactMap { $0 }.joined(separator: "_")
                let url = directory.appendingPathComponent("\(name).png")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, scaled, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    private static func upscale(_ image: CGImage, by scale: Int) -> CGImage? {
        let w = image.width * scale, h = image.height * scale
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

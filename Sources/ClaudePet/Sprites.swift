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
    static let laptopBody: UInt32 = 0x7A_7A_82_FF
    static let laptopEdge: UInt32 = 0x3C_3C_44_FF
    static let laptopKeys: UInt32 = 0xA8_A8_B0_FF
    static let screen: UInt32 = 0xD4_EA_FF_FF
    static let code: UInt32 = 0x4F_7F_C4_FF
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

    /// Frames per second for `t` in this state: typing needs quicker hands.
    static func fps(state: PetState, tool: ToolKind?) -> Double {
        typesOnLaptop(state: state, tool: tool) ? laptopFPS : 4
    }

    /// `t` advances at `fps(state:tool:)`.
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
        // The laptop already says what is going on.
        if typesOnLaptop(state: state, tool: tool) { return c }
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
            // Still on purpose, like the whole sleeping pet: nothing moves while Claude is unused.
            c.draw(.zed, at: iconX, iconY, Palette.blue)
        case .waving:
            break
        case .idle:
            break
        }
        return c
    }

    /// `t` advances at `fps(state:tool:)`.
    static func frame(state: PetState, tool: ToolKind?, t: Int, bubble showsBubble: Bool = true) -> PixelCanvas {
        if typesOnLaptop(state: state, tool: tool) { return laptopFrame(t: t) }
        var c = PixelCanvas()
        var dx = 0, dy = 0
        var eyes = Eyes.open
        var leftArmUp = false, rightArmUp = false
        var walking = false
        var color = Palette.body
        var wave = (x: 0, y: 0)

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
        case .waving:
            eyes = .happy
            rightArmUp = true
            // The raised hand bobs up and down against the body, twice a second.
            wave = t % 2 == 0 ? (0, -1) : (0, 0)
            dy = t % 4 == 0 ? -1 : 0
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
        c.fill(18 + dx + wave.x, rightY + dy + wave.y, 19 + dx + wave.x, rightY + 1 + dy + wave.y, color)

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
            c.draw(.zed, at: 18, 4, Palette.blue)
        case .idle, .waving:
            break
        }
        return c
    }

    // MARK: Laptop

    /// Commands and edits: the pet takes a laptop out once, turns to it, then types until the tool ends.
    static func typesOnLaptop(state: PetState, tool: ToolKind?) -> Bool {
        state == .working && (tool == .bash || tool == .edit)
    }

    /// Frames before the typing loop: out comes the laptop, the pet hops in front of it.
    static let laptopIntro = 10
    private static let laptopLoop = 16
    private static let laptopFPS: Double = 8

    /// The scene keeps the pet's own size: laptop on the left (x 1…7), pet in three-quarter view on the
    /// right (x 6…20), all within the compact crop so it reads the same in the notch.
    private static func laptopFrame(t: Int) -> PixelCanvas {
        var c = PixelCanvas()
        let f = t < laptopIntro ? max(0, t) : laptopIntro + (t - laptopIntro) % laptopLoop
        let k = f - laptopIntro
        c.fill(1, 21, 19, 21, Palette.shadow)

        switch f {
        case 0, 1:
            break
        case 2, 3:
            // Closed, lid on top.
            c.fill(1, 19, 6, 19, Palette.laptopEdge)
            c.fill(1, 18, 6, 18, Palette.laptopBody)
        case 4:
            drawLaptopBase(into: &c)
            for i in 0..<4 { c.set(2 + i, 17 - i, Palette.laptopBody) }
        default:
            drawLaptopBase(into: &c)
            c.fill(1, 11, 1, 18, Palette.laptopEdge)
            c.fill(2, 11, 5, 11, Palette.laptopEdge)
            c.fill(2, 12, 5, 17, f == 5 ? Palette.laptopEdge : Palette.screen)
            if k >= 0 { drawCode(into: &c, k: k) }
            // The key under the hand lights up on each stroke.
            if k >= 0, k % 2 == 0 { c.set(6, 18, Palette.light) }
        }

        switch f {
        case 0:
            drawFrontPet(into: &c, eyesDX: -1, leftArm: 14)
        case 1, 2:
            drawFrontPet(into: &c, eyesDX: -1, leftArm: 16)
        case 3:
            drawFrontPet(into: &c, eyes: .happy, leftArm: 10)
        case 4, 5:
            drawFrontPet(into: &c, eyesDX: -1, leftArm: 14)
        case 6:
            drawSidePet(into: &c, dy: -2, hand: nil)
        case 7:
            drawSidePet(into: &c, hand: nil)
        case 8:
            drawSidePet(into: &c, hand: 15)
        default:
            // Hands take turns on the keys; a blink now and then.
            drawSidePet(into: &c, blink: k == 9, hand: k % 2 == 0 ? 16 : 14)
        }
        return c
    }

    private static func drawLaptopBase(into c: inout PixelCanvas) {
        c.fill(1, 19, 7, 19, Palette.laptopEdge)
        c.fill(2, 18, 7, 18, Palette.laptopKeys)
    }

    /// Lines of code scroll up every 4 frames; the bottom one grows as the pet types, with a cursor.
    private static func drawCode(into c: inout PixelCanvas, k: Int) {
        let widths = [3, 4, 2, 0, 4, 3, 1, 3, 0, 2, 4, 3]
        for row in 0..<5 {
            let i = (row + k / 4) % widths.count
            // Every fourth line is highlighted, like a keyword.
            if widths[i] > 0 { c.fill(2, 12 + row, 1 + widths[i], 12 + row, i % 4 == 1 ? Palette.body : Palette.code) }
        }
        let typed = (k / 2) % 4
        if typed > 0 { c.fill(2, 17, 1 + typed, 17, Palette.code) }
        if k % 4 < 2, typed < 4 { c.set(2 + typed, 17, Palette.ink) }
    }

    /// The usual front pose, standing where every other state stands. `leftArm` is the arm's top row.
    private static func drawFrontPet(into c: inout PixelCanvas, eyes: Eyes = .open, eyesDX: Int = 0, leftArm: Int) {
        for x in [5, 7, 14, 16] { c.fill(x, 18, x, 19, Palette.bodyShade) }
        c.fill(4, 10, 17, 17, Palette.body)
        c.fill(4, 17, 17, 17, Palette.bodyShade)
        c.fill(2, leftArm, 3, leftArm + 1, Palette.body)
        c.fill(18, 14, 19, 15, Palette.body)
        drawEyes(eyes, into: &c, dx: eyesDX, dy: 2)
    }

    /// Facing the laptop: front face plus a shaded flank, eyes on the screen. `hand` is the near hand's
    /// top row (nil: by its side).
    private static func drawSidePet(into c: inout PixelCanvas, dy: Int = 0, blink: Bool = false, hand: Int?) {
        for x in [9, 11, 16, 18] { c.fill(x, 18 + dy, x, dy < 0 ? 18 + dy : 19 + dy, Palette.bodyShade) }
        c.fill(8, 10 + dy, 18, 17 + dy, Palette.body)
        c.fill(19, 10 + dy, 20, 17 + dy, Palette.bodyShade)
        c.fill(8, 17 + dy, 18, 17 + dy, Palette.bodyShade)
        for x in [9, 14] {
            if blink { c.fill(x - 1, 13 + dy, x, 13 + dy, Palette.eye) } else { c.fill(x, 12 + dy, x, 13 + dy, Palette.eye) }
        }
        c.fill(6, (hand ?? 14) + dy, 7, (hand ?? 14) + 1 + dy, Palette.body)
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
            for t in 0..<(typesOnLaptop(state: state, tool: tool) ? laptopIntro + laptopLoop : frames) {
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

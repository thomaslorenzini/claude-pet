// A clean, fake menu bar shown during the take, captured together with the pet: only the pet's
// status icon (at its real x) and a clock, over a darkened copy of the wallpaper.
//
//   menubar <wallpaper.png> <idle sprite.png> <icon x (points)>
//
// The real menu bar can't be captured without everything else in it, so this window takes its
// place in the recording. It sits just above the wallpaper and below every other window: on the
// real screen it is hidden under the real menu bar and lets every click through. Being a real
// window, WindowServer layers the pet above it exactly as it would above the menu bar.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, NSImage(contentsOfFile: args[1]) != nil, NSImage(contentsOfFile: args[2]) != nil, Double(args[3]) != nil else {
    print("usage: menubar <wallpaper.png> <idle sprite.png> <icon x>")
    exit(2)
}
let wallpaper = NSImage(contentsOfFile: args[1])!
let sprite = NSImage(contentsOfFile: args[2])!
let iconX = Double(args[3])!
let clockText = "Sun Oct 25  9:41 AM"
let barHeight: CGFloat = 32

final class BarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let screen = window?.screen else { return }
        // The wallpaper's top band, darkened: a translucent dark bar that never lifts blacks.
        if let cg = wallpaper.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = CGFloat(cg.height) / screen.frame.height
            if let band = cg.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: barHeight * scale)) {
                ctx.draw(band, in: bounds)
            }
        }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.fill(bounds)

        // The status icon: the pet's silhouette with the eyes cut out, one point per sprite pixel,
        // white like a template image on a dark bar (what StatusIcon draws).
        if let cg = sprite.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = cg.dataProvider?.data,
           let bytes = CFDataGetBytePtr(data) {
            let k = cg.width / 24
            var cells: [(Int, Int)] = []
            var minX = 99, maxX = -1, minY = 99, maxY = -1
            for y in 0..<22 { for x in 0..<24 {
                let o = (y * k + k / 2) * cg.bytesPerRow + (x * k + k / 2) * 4
                let r = Int(bytes[o]), g = Int(bytes[o + 1]), b = Int(bytes[o + 2]), a = Int(bytes[o + 3])
                guard a >= 128 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if r + g + b >= 200 { cells.append((x, y)) }  // dark pixels are the eyes
            } }
            let w = CGFloat(maxX - minX + 1), h = CGFloat(maxY - minY + 1)
            let ox = (CGFloat(iconX) - w / 2).rounded(), oy = ((barHeight - h) / 2).rounded()
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            for (x, y) in cells {
                ctx.fill(CGRect(x: ox + CGFloat(x - minX), y: oy + CGFloat(maxY - y), width: 1, height: 1))
            }
        }

        let font = NSFont.menuBarFont(ofSize: 0)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.95)]
        let size = (clockText as NSString).size(withAttributes: attrs)
        (clockText as NSString).draw(at: CGPoint(x: bounds.width - 14 - size.width, y: (barHeight - size.height) / 2), withAttributes: attrs)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
let frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight, width: screen.frame.width, height: barHeight)
let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
// Above the wallpaper window (WindowManager draws it a few levels above the desktop level), under
// the desktop icons and everything else.
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
window.ignoresMouseEvents = true
window.hasShadow = false
window.isOpaque = true
window.contentView = BarView(frame: CGRect(origin: .zero, size: frame.size))
window.setFrame(frame, display: true)
window.orderFrontRegardless()
signal(SIGTERM) { _ in exit(0) }
app.run()

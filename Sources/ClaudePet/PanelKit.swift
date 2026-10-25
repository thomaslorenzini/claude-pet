import AppKit

/// Shared look of the hand-drawn windows (menu bar panel, settings): Claude's colors (cream paper by day,
/// warm charcoal by night), fonts and controls. Everything draws in `draw(_:)` rather than with layers, so
/// `/control` snapshots (`cacheDisplay`) render it too.
struct PanelTheme {
    let background, card, stroke, text, secondary, tertiary, track, accent, knob: NSColor

    static func current(_ appearance: NSAppearance) -> PanelTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    static let dark = PanelTheme(
        background: hex(0x262624), card: hex(0x30302E), stroke: NSColor.white.withAlphaComponent(0.08),
        text: hex(0xFAF9F5), secondary: hex(0xB4B2A7), tertiary: hex(0x85837B),
        track: NSColor.white.withAlphaComponent(0.1), accent: hex(0xD97757), knob: hex(0xFAF9F5)
    )
    static let light = PanelTheme(
        background: hex(0xFAF9F5), card: hex(0xF0EEE6), stroke: NSColor.black.withAlphaComponent(0.08),
        text: hex(0x1F1E1D), secondary: hex(0x5E5D59), tertiary: hex(0x8F8D85),
        track: NSColor.black.withAlphaComponent(0.09), accent: hex(0xC96442), knob: .white
    )

    /// Anthropic's clay, sky and olive, one per gauge.
    static let gaugeColors = [hex(0xD97757), hex(0x6A9BCC), hex(0x788C5D)]
    static let warning = hex(0xE0A43C)
    static let danger = hex(0xD0533F)

    static func hex(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension NSFont {
    /// New York, the system serif: Claude's headings are set in a serif too.
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

extension String {
    func attributed(_ font: NSFont, _ color: NSColor, kern: CGFloat = 0, wraps: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return NSAttributedString(string: self, attributes: [
            .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style,
        ])
    }
}

extension NSAttributedString {
    /// Single line, truncated to `width`, top-left at `point` (flipped views).
    func draw(at point: CGPoint, width: CGFloat) {
        draw(with: CGRect(x: point.x, y: point.y, width: width, height: size().height),
             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Rows and controls

/// Title and subtitle on the left, a control on the right. Clicking anywhere on a toggle's row flips it.
final class SettingRow: NSView {
    let accessory: NSView
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var isEnabled = true {
        didSet {
            needsDisplay = true
            (accessory as? PanelToggle)?.isEnabled = isEnabled
        }
    }
    /// False for rows whose control takes the clicks itself (pickers).
    var isClickable = true
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false {
        didSet { (accessory as? PanelToggle)?.pressed = pressed }
    }

    var rowHeight: CGFloat { accessory is CornerPicker ? 54 : 48 }

    init(accessory: NSView) {
        self.accessory = accessory
        super.init(frame: .zero)
        addSubview(accessory)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let size = accessory.fittingSize
        accessory.frame = CGRect(x: bounds.width - 12 - size.width, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = isClickable && isEnabled }
    override func mouseUp(with event: NSEvent) {
        let fire = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        if hovered, isClickable, isEnabled {
            theme.text.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 3), xRadius: 8, yRadius: 8).fill()
        }
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        let textWidth = accessory.frame.minX - 24
        let titleY = (bounds.height - 32) / 2
        title.attributed(.systemFont(ofSize: 13, weight: .medium), theme.text.withAlphaComponent(alpha))
            .draw(at: CGPoint(x: 12, y: titleY), width: textWidth)
        subtitle.attributed(.systemFont(ofSize: 11), theme.tertiary.withAlphaComponent(alpha))
            .draw(at: CGPoint(x: 12, y: titleY + 18), width: textWidth)
    }
}

/// A switch whose knob springs across, and stretches while held.
final class PanelToggle: NSView {
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            position.target = isOn ? 1 : 0
            if window?.isVisible == true { animate() } else { position.snap(to: position.target) }
            needsDisplay = true
        }
    }
    var isEnabled = true { didSet { needsDisplay = true } }
    var pressed = false {
        didSet {
            stretch.target = pressed ? 1 : 0
            animate()
        }
    }
    private var position = Spring(value: 0, target: 0, stiffness: 420, damping: 30)
    private var stretch = Spring(value: 0, target: 0, stiffness: 500, damping: 34)
    private var timer: Timer?

    override var fittingSize: NSSize { NSSize(width: 34, height: 20) }
    override var isFlipped: Bool { true }
    // The row handles the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func animate() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.position.step(1 / 60)
            self.stretch.step(1 / 60)
            self.needsDisplay = true
            if self.position.isSettled, self.stretch.isSettled {
                timer.invalidate()
                self.timer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let p = min(1, max(0, position.value))
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        // The accent fades in over the translucent track as the knob travels.
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        theme.track.withAlphaComponent(theme.track.alphaComponent * 1.6 * alpha).setFill()
        track.fill()
        theme.accent.withAlphaComponent(p * alpha).setFill()
        track.fill()

        let inset: CGFloat = 2
        let knobSize = bounds.height - 2 * inset
        let knobWidth = knobSize + 5 * stretch.value
        let x = inset + (bounds.width - 2 * inset - knobWidth) * position.value
        let knob = CGRect(x: x, y: inset, width: knobWidth, height: knobSize)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        theme.knob.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knobSize / 2, yRadius: knobSize / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Six pixels growing in size, one per scale (×3…×8): the pet's size, said in its own material.
final class SizePicker: NSView {
    static let scales = Array(3...8)
    var scale = 5 { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    private var hovered: Int? { didSet { needsDisplay = true } }
    private let cell: CGFloat = 20

    override var fittingSize: NSSize { NSSize(width: cell * CGFloat(Self.scales.count), height: 24) }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return nil }
        return min(Self.scales.count - 1, Int(p.x / cell))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseMoved(with event: NSEvent) { hovered = index(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        onPick?(Self.scales[i])
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        for (i, s) in Self.scales.enumerated() {
            let side = CGFloat(4 + 2 * (s - 3))
            let rect = CGRect(x: CGFloat(i) * cell + (cell - side) / 2, y: bounds.height - 4 - side, width: side, height: side)
            let color: NSColor
            if s == scale { color = theme.accent }
            else if i == hovered { color = theme.text.withAlphaComponent(0.7) }
            else { color = theme.tertiary.withAlphaComponent(0.45) }
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// A miniature of the screen: the pet's actual spot, and a ghost in the corner under the cursor.
final class CornerPicker: NSView {
    var spot: CGPoint? { didSet { needsDisplay = true } }
    var docked = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onPick: ((PetController.Corner) -> Void)?
    private var hovered: PetController.Corner? { didSet { needsDisplay = true } }

    override var fittingSize: NSSize { NSSize(width: 60, height: 38) }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func corner(at event: NSEvent) -> PetController.Corner? {
        let p = convert(event.locationInWindow, from: nil)
        guard isEnabled, bounds.contains(p) else { return nil }
        let left = p.x < bounds.midX, top = p.y < bounds.midY
        return top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseMoved(with event: NSEvent) { hovered = corner(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let c = corner(at: event) { onPick?(c) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let alpha: CGFloat = isEnabled || docked ? 1 : 0.45
        let screen = bounds.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: screen, xRadius: 5, yRadius: 5)
        theme.background.withAlphaComponent(alpha).setFill()
        outline.fill()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        // Menu bar strip.
        theme.track.withAlphaComponent(theme.track.alphaComponent * 1.4 * alpha).setFill()
        CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 5).fill()
        NSGraphicsContext.restoreGraphicsState()
        theme.tertiary.withAlphaComponent(0.6 * alpha).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let area = screen.insetBy(dx: 4, dy: 4).offsetBy(dx: 0, dy: 2.5).insetBy(dx: 0, dy: 1.5)
        let pet = CGSize(width: 7, height: 6)
        func rect(for corner: PetController.Corner) -> CGRect {
            let left = corner == .topLeft || corner == .bottomLeft
            let top = corner == .topLeft || corner == .topRight
            return CGRect(x: left ? area.minX : area.maxX - pet.width, y: top ? area.minY : area.maxY - pet.height,
                          width: pet.width, height: pet.height)
        }

        if let hovered {
            theme.accent.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect(for: hovered), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if docked {
            // The notch, and the pet beside it.
            theme.text.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: CGRect(x: screen.midX - 7, y: screen.minY, width: 14, height: 5), xRadius: 2, yRadius: 2).fill()
            theme.accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: screen.midX + 8, y: screen.minY, width: 5, height: 4), xRadius: 1, yRadius: 1).fill()
        } else if let spot {
            let x = area.minX + (area.width - pet.width) * min(1, max(0, spot.x))
            let y = area.minY + (area.height - pet.height) * (1 - min(1, max(0, spot.y)))
            theme.accent.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y, width: pet.width, height: pet.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class FooterButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    let shortcut: String
    /// An accent dot before the title, for news (the update line).
    var showsDot = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    init(title: String, shortcut: String) {
        self.title = title
        self.shortcut = shortcut
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var fittingSize: NSSize {
        let w = title.attributed(.systemFont(ofSize: 12, weight: .medium), .black).size().width
            + shortcut.attributed(.systemFont(ofSize: 11), .black).size().width
        return NSSize(width: ceil(w) + 26 + (showsDot ? 13 : 0), height: 24)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        if hovered {
            theme.card.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let label = title.attributed(.systemFont(ofSize: 12, weight: .medium), hovered ? theme.text : theme.secondary)
        let key = shortcut.attributed(.systemFont(ofSize: 11), theme.tertiary)
        let y = (bounds.height - label.size().height) / 2
        var x: CGFloat = 9
        if showsDot {
            theme.accent.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: 9, width: 6, height: 6)).fill()
            x += 13
        }
        label.draw(at: CGPoint(x: x, y: y))
        key.draw(at: CGPoint(x: x + label.size().width + 7, y: y + 1))
    }
}

/// A hand-drawn push button: filled with the accent (primary), outlined (secondary) or red (danger).
/// `progress` draws a draining bar along its bottom edge, for actions that expire (a pending confirmation).
final class PanelPillButton: NSView {
    enum Style { case primary, secondary, danger }

    var title: String { didSet { needsDisplay = true } }
    var style: Style { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var progress: CGFloat? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    init(title: String, style: Style) {
        self.title = title
        self.style = style
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var fittingSize: NSSize {
        NSSize(width: ceil(title.attributed(Self.font, .black).size().width) + 28, height: 28)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = isEnabled }
    override func mouseUp(with event: NSEvent) {
        let fire = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if fire { onClick?() }
    }

    /// Tests: a click, without the mouse.
    func press() { if isEnabled { onClick?() } }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let textColor: NSColor
        switch style {
        case .primary, .danger:
            (style == .primary ? theme.accent : PanelTheme.danger).withAlphaComponent(alpha).setFill()
            shape.fill()
            textColor = NSColor.white.withAlphaComponent(alpha)
        case .secondary:
            theme.background.withAlphaComponent(alpha).setFill()
            shape.fill()
            theme.text.withAlphaComponent(0.16 * alpha).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            textColor = theme.text.withAlphaComponent(alpha)
        }
        if isEnabled, pressed || hovered {
            // Filled buttons darken, outlined ones take a tint of the text color.
            let tint = style == .secondary ? theme.text.withAlphaComponent(pressed ? 0.1 : 0.05)
                                           : NSColor.black.withAlphaComponent(pressed ? 0.18 : 0.08)
            tint.setFill()
            shape.fill()
        }
        if let progress {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.white.withAlphaComponent(0.5).setFill()
            CGRect(x: rect.minX, y: rect.maxY - 2.5, width: rect.width * min(1, max(0, progress)), height: 2.5).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let label = title.attributed(Self.font, textColor)
        let size = label.size()
        label.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 - 0.5))
    }
}

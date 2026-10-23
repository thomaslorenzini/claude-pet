import AppKit

/// The panel that opens from the menu bar icon: the live pet on its stage, the usage rings and the
/// settings. Everything is drawn by hand in Claude's colors (cream paper by day, warm charcoal by night),
/// and drawn in `draw(_:)` rather than with layers so `/control` snapshots render it too.
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

private extension NSFont {
    /// New York, the system serif: Claude's headings are set in a serif too.
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

private extension String {
    func attributed(_ font: NSFont, _ color: NSColor, kern: CGFloat = 0, wraps: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        return NSAttributedString(string: self, attributes: [
            .font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style,
        ])
    }
}

private extension NSAttributedString {
    /// Single line, truncated to `width`, top-left at `point` (flipped views).
    func draw(at point: CGPoint, width: CGFloat) {
        draw(with: CGRect(x: point.x, y: point.y, width: width, height: size().height),
             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Window and controller

final class ControlPanelWindow: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    // Key, so Escape and ⌘Q reach it; non-activating, so the app in front keeps its own focus.
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
            NSApp.terminate(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Opens the panel under the status item on click, closes it on a click elsewhere or Escape.
final class ControlPanel: NSObject {
    let window = ControlPanelWindow()
    let view = ControlPanelView()
    var modelProvider: (() -> ControlPanelView.Model)?
    private(set) var isOpen = false
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var animationTimer: Timer?
    private var t = 0
    private var shownState: (PetState, ToolKind?)?
    private var closedAt: CFTimeInterval = 0

    override init() {
        super.init()
        window.contentView = view
        window.onCancel = { [weak self] in self?.close() }
    }

    func toggle(from button: NSStatusBarButton) {
        // A click on the icon may reach a monitor first, which already closed the panel: it stays closed.
        if isOpen { close() } else if CACurrentMediaTime() - closedAt > 0.3 { open(from: button) }
    }

    func open(from button: NSStatusBarButton) {
        guard !isOpen, let anchor = button.window?.frame else { return }
        isOpen = true
        self.button = button
        refresh()
        let size = NSSize(width: ControlPanelView.width, height: view.preferredHeight)
        let screen = button.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 - size.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        let frame = CGRect(origin: origin, size: size)

        // Drops in from just under the menu bar.
        window.setFrame(frame.offsetBy(dx: 0, dy: 6), display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
        DispatchQueue.main.async { button.highlight(true) }

        // A click anywhere else closes it, as a menu would. Clicks on the status item toggle it themselves.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.window { self?.close() }
            return event
        } as Any)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        closedAt = CACurrentMediaTime()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        animationTimer?.invalidate()
        animationTimer = nil
        shownState = nil
        button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isOpen else { return }
            self.window.orderOut(nil)
        })
    }

    /// New model from the app; cheap enough to call on every refresh, does nothing while closed.
    func refresh() {
        guard isOpen, let model = modelProvider?() else { return }
        view.model = model
        if shownState.map({ $0.0 != model.state || $0.1 != model.tool }) ?? true {
            shownState = (model.state, model.tool)
            t = 0
            renderSprite()
            syncAnimation()
        }
        let height = view.preferredHeight
        if abs(window.frame.height - height) > 0.5 {
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true)
            window.invalidateShadow()
        }
    }

    /// The stage's pet animates only while the panel is open, and not while it sleeps.
    private func syncAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        guard isOpen, let (state, tool) = shownState, state != .sleeping else { return }
        let interval = 1 / SpriteComposer.fps(state: state, tool: tool)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.t += 1
            self.renderSprite()
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func renderSprite() {
        guard let (state, tool) = shownState else { return }
        view.stage.canvas = SpriteComposer.frame(state: state, tool: tool, t: t)
    }

    func snapshot(to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Content

final class ControlPanelView: NSView {
    struct Model {
        var state: PetState = .idle
        var tool: ToolKind?
        var toolName: String?
        var project: String?
        var sessions = 0
        var gauges: [QuotaStore.Reading] = []
        var usageStatus = ""
        var petVisible = true
        var notch = false
        var notchAvailable = false
        var transitioning = false
        var usageAPI = true
        var scale = 5
        /// Where the pet sits on its screen, 0…1 from the bottom-left corner; nil when unknown.
        var spot: CGPoint?
        var server = ""
        var serverOK = true
    }

    static let width: CGFloat = 320
    private static let pad: CGFloat = 14

    var model = Model() { didSet { apply() } }
    var onToggleVisible: (() -> Void)?
    var onToggleNotch: (() -> Void)?
    var onToggleUsageAPI: (() -> Void)?
    var onScale: ((Int) -> Void)?
    var onCorner: ((PetController.Corner) -> Void)?
    var onPoke: (() -> Void)?
    var onQuit: (() -> Void)?

    let stage = PetStage()
    private let visibleRow = SettingRow(accessory: PanelToggle())
    private let notchRow = SettingRow(accessory: PanelToggle())
    private let usageRow = SettingRow(accessory: PanelToggle())
    private let sizeRow = SettingRow(accessory: SizePicker())
    private let positionRow = SettingRow(accessory: CornerPicker())
    private let quitButton = FooterButton(title: tr("Quitter", "Quit"), shortcut: "⌘Q")
    private var rows: [SettingRow] { [visibleRow, notchRow, usageRow, sizeRow, positionRow] }

    // Layout, top to bottom.
    private static let stageRect = CGRect(x: pad, y: pad, width: width - 2 * pad, height: 112)
    private static let usageTitleY: CGFloat = stageRect.maxY + 18
    private static let ringsY: CGFloat = usageTitleY + 24
    private static let ringSize: CGFloat = 50
    private static let settingsTitleY: CGFloat = ringsY + ringSize + 58
    private static let cardY: CGFloat = settingsTitleY + 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(stage)
        rows.forEach(addSubview)
        addSubview(quitButton)
        stage.onPoke = { [weak self] in self?.onPoke?() }
        visibleRow.onClick = { [weak self] in self?.onToggleVisible?() }
        notchRow.onClick = { [weak self] in self?.onToggleNotch?() }
        usageRow.onClick = { [weak self] in self?.onToggleUsageAPI?() }
        (sizeRow.accessory as! SizePicker).onPick = { [weak self] in self?.onScale?($0) }
        (positionRow.accessory as! CornerPicker).onPick = { [weak self] in self?.onCorner?($0) }
        quitButton.onClick = { [weak self] in self?.onQuit?() }
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cardHeight: CGFloat { rows.map(\.rowHeight).reduce(0, +) }
    private var footerY: CGFloat { Self.cardY + cardHeight + 12 }
    var preferredHeight: CGFloat { footerY + 28 + Self.pad - 4 }

    private func apply() {
        let m = model
        stage.model = m
        visibleRow.title = tr("Afficher le pet", "Show the pet")
        visibleRow.subtitle = m.petVisible ? tr("Visible sur le bureau", "Visible on the desktop") : tr("Masqué : les demandes restent dans Claude", "Hidden: requests stay in Claude")
        (visibleRow.accessory as! PanelToggle).isOn = m.petVisible

        notchRow.title = tr("Vivre dans l'encoche", "Live in the notch")
        notchRow.subtitle = m.notchAvailable ? tr("Se loge à côté de la caméra", "Settles next to the camera") : tr("Aucune encoche sur cet écran", "No notch on this screen")
        notchRow.isEnabled = m.notchAvailable && !m.transitioning
        (notchRow.accessory as! PanelToggle).isOn = m.notch

        usageRow.title = tr("Quotas du compte", "Account quotas")
        usageRow.subtitle = tr("Lus via Claude Code, toutes les 5 min", "Read through Claude Code, every 5 min")
        (usageRow.accessory as! PanelToggle).isOn = m.usageAPI

        sizeRow.title = tr("Taille", "Size")
        sizeRow.subtitle = "Pixels ×\(m.scale)"
        sizeRow.isClickable = false
        (sizeRow.accessory as! SizePicker).scale = m.scale

        positionRow.title = tr("Position", "Position")
        positionRow.subtitle = m.notch ? tr("Fixée par l'encoche", "Set by the notch") : tr("Choisis un coin de l'écran", "Pick a corner of the screen")
        positionRow.isClickable = false
        let corners = positionRow.accessory as! CornerPicker
        corners.spot = m.spot
        corners.docked = m.notch
        corners.isEnabled = !m.notch && !m.transitioning

        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        stage.frame = Self.stageRect
        var y = Self.cardY
        for row in rows {
            row.frame = CGRect(x: Self.pad, y: y, width: bounds.width - 2 * Self.pad, height: row.rowHeight)
            y += row.rowHeight
        }
        let quit = quitButton.fittingSize
        quitButton.frame = CGRect(x: bounds.width - Self.pad - quit.width + 6, y: footerY + 2, width: quit.width, height: quit.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        theme.background.setFill()
        shape.fill()
        theme.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let pad = Self.pad, inner = bounds.width - 2 * pad
        sectionTitle(tr("Utilisation", "Usage"), y: Self.usageTitleY, theme: theme)
        let status = model.usageStatus.attributed(.systemFont(ofSize: 11), theme.tertiary)
        let statusWidth = min(status.size().width + 1, inner - 90)
        status.draw(at: CGPoint(x: bounds.width - pad - statusWidth, y: Self.usageTitleY + 1), width: statusWidth)

        let column = inner / 3
        for (i, gauge) in model.gauges.prefix(3).enumerated() {
            let x = pad + column * CGFloat(i)
            drawRing(gauge, color: PanelTheme.gaugeColors[i], center: CGPoint(x: x + column / 2, y: Self.ringsY + Self.ringSize / 2), theme: theme)
            centered(gauge.title.attributed(.systemFont(ofSize: 12, weight: .medium), theme.text), x: x, width: column, y: Self.ringsY + Self.ringSize + 8)
            centered(gauge.note.attributed(.systemFont(ofSize: 10.5), theme.tertiary), x: x + 4, width: column - 8, y: Self.ringsY + Self.ringSize + 24)
        }

        sectionTitle(tr("Réglages", "Settings"), y: Self.settingsTitleY, theme: theme)
        let card = NSBezierPath(roundedRect: CGRect(x: pad, y: Self.cardY, width: inner, height: cardHeight), xRadius: 11, yRadius: 11)
        theme.card.setFill()
        card.fill()
        // Hairlines between rows, inset like the system's grouped lists.
        theme.stroke.setFill()
        var y = Self.cardY
        for row in rows.dropLast() {
            y += row.rowHeight
            CGRect(x: pad + 12, y: y - 0.5, width: inner - 24, height: 1).fill()
        }

        // Footer: is the hooks' server listening?
        let dot = CGRect(x: pad + 2, y: footerY + 12, width: 6, height: 6)
        (model.serverOK ? PanelTheme.gaugeColors[2] : PanelTheme.danger).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let server = model.server.attributed(.monospacedDigitSystemFont(ofSize: 11, weight: .regular), theme.tertiary)
        server.draw(at: CGPoint(x: dot.maxX + 7, y: footerY + 8), width: quitButton.frame.minX - dot.maxX - 14)
    }

    private func sectionTitle(_ title: String, y: CGFloat, theme: PanelTheme) {
        title.attributed(.systemFont(ofSize: 11, weight: .semibold), theme.tertiary, kern: 0.2)
            .draw(at: CGPoint(x: Self.pad + 2, y: y))
    }

    private func centered(_ text: NSAttributedString, x: CGFloat, width: CGFloat, y: CGFloat) {
        let w = min(text.size().width + 1, width)
        text.draw(at: CGPoint(x: x + (width - w) / 2, y: y), width: w)
    }

    private func drawRing(_ gauge: QuotaStore.Reading, color: NSColor, center: CGPoint, theme: PanelTheme) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lineWidth: CGFloat = 5
        let radius = Self.ringSize / 2 - lineWidth / 2
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(theme.track.cgColor)
        if gauge.value == nil { ctx.setLineDash(phase: 0, lengths: [2, 4]) }
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        ctx.setLineDash(phase: 0, lengths: [])
        if let v = gauge.value, v > 0 {
            // Clockwise from 12 o'clock; the view is flipped, so "clockwise" on screen is counter-clockwise here.
            let fill = v >= 0.9 ? PanelTheme.danger : color
            ctx.setStrokeColor(fill.cgColor)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: radius, startAngle: -.pi / 2,
                       endAngle: -.pi / 2 + 2 * .pi * CGFloat(min(1, max(0.015, v))), clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()

        let number: NSAttributedString
        if let v = gauge.value {
            let text = NSMutableAttributedString(attributedString: "\(Int((v * 100).rounded()))"
                .attributed(.monospacedDigitSystemFont(ofSize: 14, weight: .semibold), theme.text))
            text.append(tr(" %", "%").attributed(.systemFont(ofSize: 9, weight: .medium), theme.secondary))
            number = text
        } else {
            number = "—".attributed(.systemFont(ofSize: 14, weight: .medium), theme.tertiary)
        }
        let size = number.size()
        number.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    /// Tests: the toggles and pickers, by name.
    func press(_ name: String) {
        switch name {
        case "visible": onToggleVisible?()
        case "notch": onToggleNotch?()
        case "usage": onToggleUsageAPI?()
        default: if let scale = Int(name.dropFirst()), name.hasPrefix("x") { onScale?(scale) }
        }
    }
}

// MARK: - Stage

/// The pet, alive, on a dotted pixel canvas, with what Claude is doing beside it. Clicking it wakes it.
final class PetStage: NSView {
    var canvas = PixelCanvas() { didSet { needsDisplay = true } }
    var model = ControlPanelView.Model() { didSet { needsDisplay = true } }
    var onPoke: (() -> Void)?
    private static let spriteScale: CGFloat = 4

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var spriteRect: CGRect {
        let size = CGSize(width: CGFloat(PixelCanvas.standardWidth) * Self.spriteScale,
                          height: CGFloat(PixelCanvas.standardHeight) * Self.spriteScale)
        return CGRect(x: 14, y: (bounds.height - size.height) / 2 + 2, width: size.width, height: size.height)
    }

    override func resetCursorRects() {
        addCursorRect(spriteRect, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        if spriteRect.contains(convert(event.locationInWindow, from: nil)) { onPoke?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = PanelTheme.current(effectiveAppearance)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        theme.card.setFill()
        shape.fill()

        ctx.saveGState()
        shape.addClip()
        // A faint pixel grid, and a warm glow where the pet stands.
        theme.text.withAlphaComponent(0.06).setFill()
        for y in stride(from: CGFloat(6), to: bounds.height, by: 8) {
            for x in stride(from: CGFloat(6), to: bounds.width, by: 8) {
                CGRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        let sprite = spriteRect
        let glowColor = (model.state == .error ? PanelTheme.danger : theme.accent)
        if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [glowColor.withAlphaComponent(model.state == .sleeping ? 0.08 : 0.2).cgColor,
                                          glowColor.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            let center = CGPoint(x: sprite.midX, y: sprite.midY + 8)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 74, options: [])
        }
        ctx.restoreGState()

        if let image = canvas.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // CGImage rows go bottom-up in a flipped view.
            ctx.translateBy(x: 0, y: sprite.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: sprite.minX, y: 0, width: sprite.width, height: sprite.height))
            ctx.restoreGState()
        }

        // Text column.
        let x = sprite.maxX + 14, width = bounds.width - x - 14
        var context: [String] = []
        if let project = model.project { context.append(project) }
        context.append(model.sessions == 0 ? tr("aucune session", "no session") : L10n.plural(model.sessions, "session"))
        // English states run longer ("Claude is waiting for you"): the title may take two lines.
        let titleText = "Claude \(model.state.label)".attributed(.serif(20, weight: .medium), theme.text, wraps: true)
        let titleHeight = ceil(titleText.boundingRect(with: CGSize(width: width, height: 60), options: .usesLineFragmentOrigin).height)
        let blockHeight = 14 + 4 + titleHeight + 4 + 16
        var y = (bounds.height - blockHeight) / 2

        let dot = CGRect(x: x, y: y + 4, width: 6, height: 6)
        stateColor(theme).setFill()
        NSBezierPath(ovalIn: dot).fill()
        context.joined(separator: " · ").attributed(.systemFont(ofSize: 11, weight: .medium), theme.tertiary)
            .draw(at: CGPoint(x: dot.maxX + 6, y: y), width: width - 12)
        y += 18
        titleText.draw(with: CGRect(x: x, y: y, width: width, height: titleHeight), options: .usesLineFragmentOrigin)
        y += titleHeight + 4
        detail.attributed(.systemFont(ofSize: 12), theme.secondary).draw(at: CGPoint(x: x, y: y), width: width)
    }

    private var detail: String {
        switch model.state {
        case .working: return model.toolName.map { tr("Outil : ", "Tool: ") + $0 } ?? tr("Un outil tourne", "A tool is running")
        case .thinking: return tr("Prépare la suite", "Working out what's next")
        case .waiting: return tr("Une réponse est attendue", "Needs your answer")
        case .error: return tr("Le dernier outil a échoué", "The last tool failed")
        case .happy: return tr("Tâche terminée", "Task done")
        case .idle: return tr("En attente d'une consigne", "Waiting for instructions")
        case .sleeping: return tr("Clique dessus pour le réveiller", "Click it to wake it up")
        case .waving: return tr("Bonjour !", "Hello!")
        }
    }

    private func stateColor(_ theme: PanelTheme) -> NSColor {
        switch model.state {
        case .working, .thinking: return theme.accent
        case .waiting: return PanelTheme.warning
        case .error: return PanelTheme.danger
        case .happy, .idle, .waving: return PanelTheme.gaugeColors[2]
        case .sleeping: return theme.tertiary
        }
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
    let title: String
    let shortcut: String
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
        return NSSize(width: ceil(w) + 26, height: 24)
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
        label.draw(at: CGPoint(x: 9, y: y))
        key.draw(at: CGPoint(x: 9 + label.size().width + 7, y: y + 1))
    }
}

// MARK: - Menu bar icon

enum StatusIcon {
    /// The pet's own silhouette as a template image, eyes cut out, one point per pixel.
    static func make() -> NSImage? {
        let frame = SpriteComposer.frame(state: .idle, tool: nil, t: 0, bubble: false)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        func solid(_ x: Int, _ y: Int) -> Bool {
            frame.alpha(x, y) >= 128 && frame.pixel(x, y) != Palette.eye
        }
        for y in 0..<frame.height { for x in 0..<frame.width where frame.alpha(x, y) >= 128 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return nil }
        // Drawn at 2× so each pixel stays a crisp 2×2 block on Retina.
        let width = maxX - minX + 1, height = maxY - minY + 1
        var mask = PixelCanvas(width: width * 2, height: height * 2)
        for y in minY...maxY { for x in minX...maxX where solid(x, y) {
            mask.fill(2 * (x - minX), 2 * (y - minY), 2 * (x - minX) + 1, 2 * (y - minY) + 1, 0x00_00_00_FF)
        } }
        guard let cg = mask.makeImage() else { return nil }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        image.isTemplate = true
        return image
    }
}

import AppKit

/// The panel that opens from the menu bar icon: the live pet on its stage, the usage rings, and a footer
/// that leads to the settings window. Drawn by hand with `PanelTheme` (see PanelKit.swift).

// MARK: - Window and controller

final class ControlPanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    var onSettings: (() -> Void)?

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
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == ",", let onSettings {
            onSettings()
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
        /// Short server line for the footer ("Listening"), the full address goes in its tooltip.
        var server = ""
        var serverDetail = ""
        var serverOK = true
        // Quick settings, one click away from the menu bar.
        var petVisible = true
        var notch = false
        var notchAvailable = false
        var transitioning = false
        /// The update line ("Restart to update to vX"…), nil when there is nothing to install.
        var update: String?
        /// Today's tokens for the statistics row, once the transcripts were read.
        var statsToday: String?
    }

    static let width: CGFloat = 320
    private static let pad: CGFloat = 14

    var model = Model() { didSet { apply() } }
    var onPoke: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleVisible: (() -> Void)?
    var onToggleNotch: (() -> Void)?
    var onUpdate: (() -> Void)?
    var onStats: (() -> Void)?

    let stage = PetStage()
    private let visibleRow = SettingRow(accessory: PanelToggle())
    private let notchRow = SettingRow(accessory: PanelToggle())
    private let statsRow = SettingRow(accessory: ChevronAccessory())
    private let settingsButton = FooterButton(title: tr("Réglages…", "Settings…"), shortcut: "⌘,")
    private let quitButton = FooterButton(title: tr("Quitter", "Quit"), shortcut: "⌘Q")
    private let updateButton: FooterButton = {
        let button = FooterButton(title: "", shortcut: "↻")
        button.showsDot = true
        return button
    }()

    // Layout, top to bottom: stage, usage title, rings and their labels, the quick settings card, the update
    // line (only when there is one), a hairline, the footer.
    private static let stageRect = CGRect(x: pad, y: pad, width: width - 2 * pad, height: 112)
    private static let usageTitleY: CGFloat = stageRect.maxY + 18
    private static let ringsY: CGFloat = usageTitleY + 24
    private static let ringSize: CGFloat = 50
    private static let rowHeight: CGFloat = 48
    private static let cardRect = CGRect(x: pad, y: ringsY + ringSize + 50, width: width - 2 * pad, height: 3 * rowHeight)
    private static let updateY: CGFloat = cardRect.maxY + 8
    private var separatorY: CGFloat { Self.cardRect.maxY + (model.update == nil ? 12 : 8 + 24 + 8) }
    private var footerY: CGFloat { separatorY + 8 }
    var preferredHeight: CGFloat { footerY + 24 + 9 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(stage)
        addSubview(visibleRow)
        addSubview(notchRow)
        addSubview(statsRow)
        addSubview(settingsButton)
        addSubview(quitButton)
        addSubview(updateButton)
        stage.onPoke = { [weak self] in self?.onPoke?() }
        settingsButton.onClick = { [weak self] in self?.onSettings?() }
        visibleRow.onClick = { [weak self] in self?.onToggleVisible?() }
        notchRow.onClick = { [weak self] in self?.onToggleNotch?() }
        statsRow.onClick = { [weak self] in self?.onStats?() }
        quitButton.onClick = { [weak self] in self?.onQuit?() }
        updateButton.onClick = { [weak self] in self?.onUpdate?() }
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func apply() {
        stage.model = model
        visibleRow.title = tr("Afficher le pet", "Show the pet")
        visibleRow.subtitle = model.petVisible ? tr("Visible sur le bureau", "Visible on the desktop")
            : tr("Masqué : les demandes restent dans Claude", "Hidden: requests stay in Claude")
        (visibleRow.accessory as! PanelToggle).isOn = model.petVisible
        notchRow.title = tr("Vivre dans l'encoche", "Live in the notch")
        notchRow.subtitle = model.notchAvailable ? tr("Se loge à côté de la caméra", "Settles next to the camera")
            : tr("Aucune encoche sur cet écran", "No notch on this screen")
        notchRow.isEnabled = model.notchAvailable && !model.transitioning
        (notchRow.accessory as! PanelToggle).isOn = model.notch
        statsRow.title = tr("Statistiques", "Statistics")
        statsRow.subtitle = model.statsToday.map { tr("Aujourd'hui : ", "Today: ") + $0 } ?? tr("Tokens, modèles et activité", "Tokens, models and activity")
        updateButton.isHidden = model.update == nil
        updateButton.title = model.update ?? ""
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        stage.frame = Self.stageRect
        visibleRow.frame = CGRect(x: Self.cardRect.minX, y: Self.cardRect.minY, width: Self.cardRect.width, height: Self.rowHeight)
        notchRow.frame = visibleRow.frame.offsetBy(dx: 0, dy: Self.rowHeight)
        statsRow.frame = notchRow.frame.offsetBy(dx: 0, dy: Self.rowHeight)
        // The footer buttons hang off the right edge, their hover plate aligned with the cards' edge.
        let quit = quitButton.fittingSize, settings = settingsButton.fittingSize
        quitButton.frame = CGRect(x: bounds.width - Self.pad - quit.width + 6, y: footerY, width: quit.width, height: quit.height)
        settingsButton.frame = CGRect(x: quitButton.frame.minX - settings.width - 2, y: footerY,
                                      width: settings.width, height: settings.height)
        // Its dot and text line up with the server's in the footer.
        let update = updateButton.fittingSize
        updateButton.frame = CGRect(x: Self.pad - 7, y: Self.updateY, width: min(update.width, bounds.width - 2 * Self.pad + 7),
                                    height: update.height)
        removeAllToolTips()
        addToolTip(CGRect(x: 0, y: footerY, width: settingsButton.frame.minX, height: 24), owner: self, userData: nil)
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        model.serverDetail
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

        // Quick settings card, hairlines between its rows.
        theme.card.setFill()
        NSBezierPath(roundedRect: Self.cardRect, xRadius: 11, yRadius: 11).fill()
        theme.stroke.setFill()
        for row in 1...2 {
            CGRect(x: Self.cardRect.minX + 12, y: Self.cardRect.minY + CGFloat(row) * Self.rowHeight - 0.5,
                   width: Self.cardRect.width - 24, height: 1).fill()
        }

        // Hairline over the footer, full width like a menu's separator.
        theme.stroke.setFill()
        CGRect(x: pad, y: separatorY - 0.5, width: inner, height: 1).fill()

        // Footer: is the hooks' server listening?
        let dot = CGRect(x: pad + 2, y: footerY + 9, width: 6, height: 6)
        (model.serverOK ? PanelTheme.gaugeColors[2] : PanelTheme.danger).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let server = model.server.attributed(.systemFont(ofSize: 11), theme.tertiary)
        server.draw(at: CGPoint(x: dot.maxX + 7, y: footerY + 5), width: settingsButton.frame.minX - dot.maxX - 12)
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

    /// Tests: the footer buttons and the stage, by name.
    func press(_ name: String) {
        switch name {
        case "settings": onSettings?()
        case "pet": onPoke?()
        case "quit": onQuit?()
        case "visible": onToggleVisible?()
        case "notch": onToggleNotch?()
        case "stats": onStats?()
        case "update": if model.update != nil { onUpdate?() }
        default: break
        }
    }
}

/// A row's "opens something" sign: a small chart glyph and a chevron.
final class ChevronAccessory: NSView {
    override var fittingSize: NSSize { NSSize(width: 34, height: 16) }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        // Three bars, the gauges' colors.
        for (i, h) in [CGFloat(6), 11, 8].enumerated() {
            PanelTheme.gaugeColors[i].setFill()
            NSBezierPath(roundedRect: CGRect(x: CGFloat(i) * 5, y: 14 - h, width: 3.5, height: h), xRadius: 1.2, yRadius: 1.2).fill()
        }
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: bounds.width - 5, y: 3.5))
        chevron.line(to: CGPoint(x: bounds.width - 1.5, y: 8))
        chevron.line(to: CGPoint(x: bounds.width - 5, y: 12.5))
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        theme.tertiary.setStroke()
        chevron.stroke()
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

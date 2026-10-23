import AppKit

/// Borderless, transparent, always-on-top panel that never steals focus.
final class PetPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar and its status items, so the pet can sit in the notch.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    /// Only while the user types an answer in the request panel: a pet that became key on every
    /// click would take the keyboard away from the app in front.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Never push the panel below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class PetView: NSView {
    var canvas = PixelCanvas() {
        didSet { needsDisplay = true }
    }
    /// Where the sprite is drawn, in view coordinates.
    var spriteRect = CGRect.zero { didSet { needsDisplay = true } }
    /// Vertical squash/stretch, applied around the sprite's feet. Width compensates.
    var squash: CGFloat = 1 { didSet { needsDisplay = true } }
    var rotation: CGFloat = 0 { didSet { needsDisplay = true } }
    /// Point (view coordinates) that rotation and squash turn around; the feet when nil. While dragging
    /// it is the point under the cursor, so the pet never slides away from the hand.
    var pivot: CGPoint? { didSet { needsDisplay = true } }
    /// Black notch box, drawn behind the sprite.
    var boxPath: CGPath? { didSet { needsDisplay = true } }

    struct Gauge {
        var rect: CGRect
        /// 0…1, nil when unknown (only the track is drawn).
        var value: Double?
        var color: NSColor
        var lineWidth: CGFloat
        var showsNumber: Bool
        var alpha: CGFloat
    }
    var gauges: [Gauge] = [] { didSet { needsDisplay = true } }
    /// Detail label under the box, centered on `anchor` (its top).
    var tooltip: (text: String, anchor: CGPoint)? { didSet { needsDisplay = true } }
    var contextMenuProvider: (() -> NSMenu)?
    var onMouseDown: (() -> Void)?
    var onMouseDragged: (() -> Void)?
    var onMouseUp: (() -> Void)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let boxPath {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(boxPath)
            ctx.fillPath()
        }
        gauges.forEach { draw($0, in: ctx) }
        if let tooltip { drawTooltip(tooltip.text, anchor: tooltip.anchor) }
        guard let image = canvas.makeImage(), spriteRect.width > 0 else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        let p = pivot ?? CGPoint(x: spriteRect.midX, y: spriteRect.minY)
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: rotation)
        ctx.scaleBy(x: 1 + (1 - squash) * 0.6, y: squash)
        ctx.translateBy(x: -p.x, y: -p.y)
        ctx.draw(image, in: spriteRect)
        ctx.restoreGState()
    }

    private func draw(_ g: Gauge, in ctx: CGContext) {
        guard g.alpha > 0.01, g.rect.width > 2 else { return }
        let r = g.rect.insetBy(dx: g.lineWidth / 2, dy: g.lineWidth / 2)
        ctx.saveGState()
        ctx.setAlpha(g.alpha)
        ctx.setLineWidth(g.lineWidth)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.strokeEllipse(in: r)
        if let v = g.value, v > 0 {
            // Clockwise from 12 o'clock, like the system's own progress rings.
            ctx.setStrokeColor(g.color.cgColor)
            ctx.setLineCap(.round)
            ctx.addArc(
                center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * CGFloat(v), clockwise: true
            )
            ctx.strokePath()
        }
        ctx.restoreGState()
        guard g.showsNumber, let v = g.value else { return }
        let text = NSAttributedString(string: "\(Int((v * 100).rounded()))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: r.width * 0.42, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(g.alpha),
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: g.rect.midX - size.width / 2, y: g.rect.midY - size.height / 2))
    }

    private func drawTooltip(_ string: String, anchor: CGPoint) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        var frame = CGRect(x: anchor.x - size.width / 2 - 8, y: anchor.y - 6 - size.height - 8, width: size.width + 16, height: size.height + 8)
        frame.origin.x = min(max(frame.minX, bounds.minX + 2), bounds.maxX - frame.width - 2)
        NSColor(white: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
        text.draw(at: CGPoint(x: frame.minX + 8, y: frame.minY + 4))
    }

    /// True when `point` (view coordinates) lands on a visible pixel of the sprite.
    func hitsSprite(at point: NSPoint) -> Bool {
        guard spriteRect.contains(point) else { return false }
        let x = Int((point.x - spriteRect.minX) / spriteRect.width * CGFloat(canvas.width))
        let y = canvas.height - 1 - Int((point.y - spriteRect.minY) / spriteRect.height * CGFloat(canvas.height))
        return canvas.alpha(x, y) >= 128
    }

    func hitsBox(at point: NSPoint) -> Bool {
        boxPath?.contains(point) ?? false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?() }
    override func mouseUp(with event: NSEvent) { onMouseUp?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Owns the panel, animates the sprite and makes everything but the sprite click-through.
///
/// Two resting modes: `floating` (the panel is exactly the sprite) and `notch` (the panel covers the
/// black box glued to the notch). Everything in between (`flying` from the menu, `dragging` by hand,
/// `dropping` once released) stretches the panel over the screen(s), so the sprite and the box are
/// drawn by one view and always move in sync.
final class PetController: NSObject {
    private static let originKey = "petOrigin"
    private static let scaleKey = "petScale"
    static let notchKey = "petInNotch"

    enum Mode { case floating, notch, flying, dragging, dropping }

    /// Cursor distance to the notch slot at which the pet is fully docked / starts being attracted.
    private static let dockRadius: CGFloat = 26
    private static let attractRadius: CGFloat = 260
    private static let dragThreshold: CGFloat = 3

    private struct Drag {
        let start: CGPoint
        /// Point of the sprite held under the cursor, as a fraction of its rect.
        let grab: CGPoint
        var rect: CGRect
        var active = false
        var lastMouse: CGPoint
        var inZone: Bool
        var velocity = CGPoint.zero
    }

    private struct Drop {
        let toNotch: Bool
        let from: CGRect
        let to: CGRect
        let grab: CGPoint
        /// Critically damped: no overshoot past the slot (it would poke above the screen), the bounce
        /// comes from the squash and the box instead.
        var progress = Spring(value: 0, target: 1, stiffness: 520, damping: 2 * sqrt(520))
    }

    private struct Flight {
        let toNotch: Bool
        let start: CFTimeInterval
        let from: CGRect
        let to: CGRect
        var boxKicked = false
        static let crouch: CFTimeInterval = 0.16
        static let travel: CFTimeInterval = 0.7
    }

    let panel: PetPanel
    let view: PetView
    private(set) var scale: Int
    private(set) var state: PetState = .idle
    private(set) var tool: ToolKind?
    private(set) var mode = Mode.floating {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    /// Every mode change (the first-run tutorial follows the user's drags with it).
    var onModeChange: ((Mode) -> Void)?
    private var t = 0
    /// When the pet last stopped typing, to skip taking the laptop out again on the next command.
    private var typingStoppedAt: CFTimeInterval?
    private static let typingResumeWindow: CFTimeInterval = 4
    private var animationTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var mousePoll: Timer?
    private var lastMousePosition = NSPoint.zero
    private var stillPolls = 0

    private var notch: NotchGeometry?
    private var flight: Flight?
    private var open = Spring(value: 0, target: 0, stiffness: 320, damping: 22)
    private var expand = Spring(value: 0, target: 0, stiffness: 300, damping: 18)
    private var squash = Spring(value: 1, target: 1, stiffness: 520, damping: 13)
    /// Points per sprite pixel while dragging: shrinks as the pet nears the notch.
    private var size = Spring(value: 5, target: 5, stiffness: 650, damping: 46)
    /// Swing from horizontal speed while dragging.
    private var tilt = Spring(value: 0, target: 0, stiffness: 240, damping: 13)
    private var drag: Drag?
    private var drop: Drop?
    /// A single click (no drag), floating or docked.
    var onClick: (() -> Void)?

    /// Gauge colors, in `QuotaStore.Kind` order: 5 h, week, context.
    private static let gaugeColors = [
        NSColor(srgbRed: 0.29, green: 0.56, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.70, green: 0.42, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.84, blue: 0.55, alpha: 1),
    ]
    private var gaugeValues: [Double?] = [nil, nil, nil]
    private var gaugeDetails = ["", "", ""]
    private var hoveredGauge: Int?
    private var motionTimer: Timer?
    private var lastStep = CACurrentMediaTime()
    private var hovering = false

    /// What Claude is waiting for (permission, questions): around the notch, or in a card above the pet.
    let requestView = RequestView()
    private var request: PendingRequest?
    private var requestHeight: CGFloat = 0
    private let bannerLabel = RequestView.bannerLabel()
    /// Clips the request to the black box, so the box uncovers it as it grows.
    private let requestClip = NSView()
    private lazy var card = RequestCard()
    /// Banner under the notch while a request waits, and the full panel on hover.
    private var attention = Spring(value: 0, target: 0, stiffness: 300, damping: 24)
    /// The request the user has opened once: no more banner or pill for it, only the alert sprite.
    private var seenRequestID: Int?
    private var requestSeen: Bool { request != nil && request?.id == seenRequestID }
    /// Floating: the cursor is over the pet's body, or over the card.
    private var petHovered = false
    private var overCard = false
    private var cardCollapse: DispatchWorkItem?
    /// The "Autre" field has the keyboard: the request stays open whatever the cursor does.
    private var typing = false
    /// Width then height, eased by `requestLayout`.
    private var reveal = Tween(duration: 0.5)

    override init() {
        let saved = UserDefaults.standard.integer(forKey: Self.scaleKey)
        scale = (3...8).contains(saved) ? saved : 5
        let size = Self.size(for: scale)
        panel = PetPanel(size: size)
        view = PetView(frame: NSRect(origin: .zero, size: size))
        super.init()
        panel.contentView = view
        view.autoresizingMask = [.width, .height]
        view.onMouseDown = { [unowned self] in self.mouseDown() }
        view.onMouseDragged = { [unowned self] in self.mouseDragged() }
        view.onMouseUp = { [unowned self] in self.mouseUp() }
        view.addSubview(bannerLabel)
        bannerLabel.alphaValue = 0
        requestView.isHidden = true
        requestClip.wantsLayer = true
        requestClip.layer?.masksToBounds = true
        view.addSubview(requestClip)
        requestView.onResize = { [unowned self] in self.syncRequestUI() }
        requestView.onEditing = { [unowned self] editing in self.setTyping(editing) }
        card.onHover = { [unowned self] inside in
            self.overCard = inside
            self.updateFloatingCard()
        }
        card.onClick = { [unowned self] in
            self.overCard = true
            self.updateFloatingCard()
        }
        restorePosition()
        layoutFloating()
        render()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove), name: NSWindow.didMoveNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        syncAnimation()
        panel.acceptsMouseMovedEvents = true
        listenForMouse()

        if UserDefaults.standard.bool(forKey: Self.notchKey), let geometry = NotchGeometry.find() {
            dock(in: geometry)
        }
    }

    func show() {
        panel.orderFrontRegardless()
        syncRequestUI()
    }

    func hide() {
        panel.orderOut(nil)
        card.hide()
    }
    var isVisible: Bool { panel.isVisible }

    func update(state: PetState, tool: ToolKind?) {
        guard state != self.state || tool != self.tool else { return }
        let now = CACurrentMediaTime()
        if SpriteComposer.typesOnLaptop(state: self.state, tool: self.tool) { typingStoppedAt = now }
        self.state = state
        self.tool = tool
        t = 0
        // Tools one after another: Claude thinks briefly between them, the pet goes straight back to typing.
        if SpriteComposer.typesOnLaptop(state: state, tool: tool),
           let stopped = typingStoppedAt, now - stopped < Self.typingResumeWindow {
            t = SpriteComposer.laptopIntro
        }
        render()
        syncAnimation()
    }

    /// The animation (4 fps, faster while typing) runs only while awake: asleep the frame never changes,
    /// so nothing ticks.
    private func syncAnimation() {
        let interval = 1 / SpriteComposer.fps(state: state, tool: tool)
        if state == .sleeping || animationTimer?.timeInterval != interval {
            animationTimer?.invalidate()
            animationTimer = nil
        }
        if state != .sleeping, animationTimer == nil {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.t += 1
                self.render()
            }
            // Lets macOS batch this wakeup with others; 20 % of a frame of jitter is invisible.
            timer.tolerance = interval * 0.2
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
    }

    // MARK: Requests

    /// The request to show (nil: none), and how many others wait behind it.
    func showRequest(_ request: PendingRequest?, waiting: Int) {
        let had = self.request != nil
        self.request = request
        requestView.show(request, waiting: waiting)
        if request == nil {
            reveal.target = 0
            if had, hovering { expand.target = 1 }
        } else {
            // While a request waits, hovering opens it instead of the gauges.
            expand.target = 0
            reveal.target = hovering ? 1 : 0
            if hovering, mode == .notch { seenRequestID = request?.id }
        }
        attention.target = request == nil || requestSeen ? 0 : 1
        syncRequestUI()
        startMotion()
    }

    /// Opens the request as hovering would (tests drive it through `/control`).
    func revealRequest(_ on: Bool) {
        guard request != nil else { return }
        if mode == .notch {
            // Like a hover: seen on opening, the banner only goes away on closing.
            if on { seenRequestID = request?.id }
            reveal.target = on ? 1 : 0
            if !on { attention.target = requestSeen ? 0 : 1 }
            startMotion()
        } else {
            overCard = on
            updateFloatingCard()
        }
    }

    /// Writes the panel's view to `path`, and the request card to `path` + "-card.png" when shown.
    func snapshot(to path: String) {
        func write(_ view: NSView, _ path: String) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        write(view, path)
        if let content = card.contentView { write(content, path + "-card.png") }
    }

    /// Puts the request where the current mode shows it.
    private func syncRequestUI() {
        switch mode {
        case .notch:
            card.hide()
            guard let geometry = notch else { return }
            if request != nil {
                if requestView.superview !== requestClip { requestClip.addSubview(requestView) }
                requestHeight = requestView.height(for: NotchGeometry.panelWidth - 2 * NotchGeometry.panelPadding)
                let frame = geometry.requestPanelFrame(contentHeight: requestHeight)
                if panel.frame != frame {
                    panel.setFrame(frame, display: false)
                }
            }
            layoutNotch()
        case .floating:
            bannerLabel.alphaValue = 0
            updateFloatingCard()
        case .flying, .dragging, .dropping:
            hideRequestUI()
        }
    }

    /// Floating: the card opens while the cursor is on the pet or on the card. Before the first
    /// opening, a pill says Claude needs you; after it, only the pet's alert sprite does.
    private func updateFloatingCard() {
        guard mode == .floating, request != nil, panel.isVisible else {
            hideCard()
            return
        }
        if overCard || petHovered || typing {
            cardCollapse?.cancel()
            cardCollapse = nil
            seenRequestID = request?.id
            card.show(requestView, near: panel.frame, expanded: true)
        } else if card.isExpanded {
            guard cardCollapse == nil else { return }
            // A short grace period, so crossing from the pet to the card does not close it.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.cardCollapse = nil
                guard !self.overCard, !self.petHovered, !self.typing else { return }
                self.collapseCard()
            }
            cardCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            collapseCard()
        }
    }

    private func setTyping(_ on: Bool) {
        typing = on
        panel.allowsKey = on && mode == .notch
        card.allowsKey = on && mode == .floating
        guard !on else { return }
        // Give the keyboard back to the app in front, then close if the cursor has left meanwhile.
        if panel.isKeyWindow { panel.resignKey() }
        card.resignKey()
        trackMouse()
        updateFloatingCard()
    }

    private func collapseCard() {
        if requestSeen || request == nil { hideCard() } else { card.show(requestView, near: panel.frame, expanded: false) }
    }

    private func hideCard() {
        cardCollapse?.cancel()
        cardCollapse = nil
        overCard = false
        card.hide()
    }

    private func hideRequestUI() {
        hideCard()
        bannerLabel.alphaValue = 0
        if requestView.superview === requestClip { requestView.isHidden = true }
    }

    func setScale(_ newScale: Int) {
        scale = newScale
        UserDefaults.standard.set(newScale, forKey: Self.scaleKey)
        guard mode == .floating else { return }
        // Keep the feet where they were.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: Self.size(for: newScale)), display: true)
        layoutFloating()
        syncRequestUI()
        trackMouse()
    }

    enum Corner { case bottomRight, bottomLeft, topRight, topLeft }

    func move(to corner: Corner) {
        guard mode == .floating, let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size, margin: CGFloat = 24
        let x = (corner == .bottomLeft || corner == .topLeft) ? screen.minX + margin : screen.maxX - size.width - margin
        let y = (corner == .bottomLeft || corner == .bottomRight) ? screen.minY + margin : screen.maxY - size.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        card.follow(panel.frame)
        trackMouse()
    }

    // MARK: Notch

    var notchAvailable: Bool { NotchGeometry.find() != nil }
    /// The user's choice (menu or drag), already true while travelling towards the notch.
    var wantsNotch: Bool { UserDefaults.standard.bool(forKey: Self.notchKey) }
    var isTransitioning: Bool { mode != .floating && mode != .notch }

    func setNotchMode(_ on: Bool) {
        guard !isTransitioning else { return }
        if on, mode == .floating, let geometry = NotchGeometry.find() {
            UserDefaults.standard.set(true, forKey: Self.notchKey)
            notch = geometry
            open.snap(to: 0)
            expand.snap(to: 0)
            let target = Self.regularRect(matching: geometry.layout(open: 1, expand: 0).sprite)
            startFlight(Flight(toNotch: true, start: CACurrentMediaTime(), from: panel.frame, to: target))
        } else if !on, mode == .notch, let geometry = notch {
            UserDefaults.standard.set(false, forKey: Self.notchKey)
            hovering = false
            expand.target = 0
            let from = Self.regularRect(matching: geometry.layout(open: open.value, expand: expand.value).sprite)
            let to = CGRect(origin: savedFloatingOrigin(), size: Self.size(for: scale))
            startFlight(Flight(toNotch: false, start: CACurrentMediaTime(), from: from, to: to))
        }
    }

    /// Live tuning of the box corners, to match the physical notch by eye.
    func tuneNotch(radius: CGFloat?, ear: CGFloat?) {
        if let radius { UserDefaults.standard.set(Double(radius), forKey: NotchGeometry.radiusKey) }
        if let ear { UserDefaults.standard.set(Double(ear), forKey: NotchGeometry.earKey) }
        if mode == .notch { layoutNotch() }
    }

    func updateGauges(_ gauges: [(value: Double?, detail: String)]) {
        let values = gauges.map(\.value), details = gauges.map(\.detail)
        guard values != gaugeValues || details != gaugeDetails else { return }
        gaugeValues = values
        gaugeDetails = details
        if mode == .notch { layoutNotch() }
    }

    /// Box outline and gauges for a layout, in view coordinates.
    private func applyBox(_ geometry: NotchGeometry, _ l: NotchGeometry.Layout, origin: CGPoint) {
        view.boxPath = geometry.path(for: l, origin: origin)
        view.gauges = l.gauges.enumerated().map { i, rect in
            PetView.Gauge(
                rect: rect.offsetBy(dx: -origin.x, dy: -origin.y), value: gaugeValues[i],
                color: Self.gaugeColors[i], lineWidth: l.gaugeLineWidth, showsNumber: l.expand > 0.7,
                alpha: l.gaugeAlpha
            )
        }
    }

    private func dock(in geometry: NotchGeometry, settleBox: Bool = false) {
        notch = geometry
        mode = .notch
        // After a flight the box is still springing open: let it finish its bounce.
        if !settleBox { open.snap(to: 1) }
        panel.setFrame(geometry.panelFrame, display: true)
        render()
        syncRequestUI()
        trackMouse()
    }

    private func undockImmediately() {
        mode = .floating
        notch = nil
        hovering = false
        expand.snap(to: 0)
        panel.setFrame(CGRect(origin: savedFloatingOrigin(), size: Self.size(for: scale)), display: true)
        render()
        layoutFloating()
        if requestView.superview === requestClip { requestView.isHidden = true }
        syncRequestUI()
        trackMouse()
    }

    private func startFlight(_ f: Flight) {
        mode = .flying
        hideRequestUI()
        flight = f
        panel.ignoresMouseEvents = true
        // Cover every screen the trip touches.
        var area = notch?.screen.frame ?? f.from
        for screen in NSScreen.screens where screen.frame.intersects(f.from) || screen.frame.intersects(f.to) {
            area = area.union(screen.frame)
        }
        panel.setFrame(area, display: false)
        render()
        startMotion()
    }

    private func stepFlight(now: CFTimeInterval) {
        guard var f = flight, let geometry = notch else { return }
        let elapsed = now - f.start
        let origin = panel.frame.origin

        if elapsed < Flight.crouch {
            // Anticipation: crouch before jumping.
            let k = CGFloat(elapsed / Flight.crouch)
            view.spriteRect = f.from.offsetBy(dx: -origin.x, dy: -origin.y)
            squash.snap(to: 1 - 0.3 * sin(k * .pi / 2))
            view.rotation = 0
        } else if elapsed < Flight.crouch + Flight.travel {
            let u = CGFloat((elapsed - Flight.crouch) / Flight.travel)
            let p = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
            // Feet follow a quadratic Bézier: up then across towards the notch, across then down when leaving.
            let a = CGPoint(x: f.from.midX, y: f.from.minY)
            let b = CGPoint(x: f.to.midX, y: f.to.minY)
            let c = f.toNotch ? CGPoint(x: a.x, y: b.y) : CGPoint(x: b.x, y: a.y)
            let q = 1 - p
            let feet = CGPoint(
                x: q * q * a.x + 2 * q * p * c.x + p * p * b.x,
                y: q * q * a.y + 2 * q * p * c.y + p * p * b.y
            )
            let w = lerp(f.from.width, f.to.width, p), h = lerp(f.from.height, f.to.height, p)
            view.spriteRect = CGRect(x: feet.x - w / 2 - origin.x, y: feet.y - origin.y, width: w, height: h)
            squash.snap(to: 1 + 0.28 * sin(u * .pi) - 0.3 * max(0, 1 - u / 0.12))
            view.rotation = (b.x > a.x ? -1 : 1) * 0.35 * sin(u * .pi)

            // The box slides out of the notch to catch the pet, or tucks back in once it has left.
            if !f.boxKicked && (f.toNotch ? u > 0.5 : u > 0.25) {
                f.boxKicked = true
                open.target = f.toNotch ? 1 : 0
                flight = f
            }
        } else {
            flight = nil
            view.rotation = 0
            // Landing squash, released into the spring.
            squash.value = 0.7
            squash.velocity = 0
            squash.target = 1
            if f.toNotch {
                open.target = 1
                dock(in: geometry, settleBox: true)
            } else {
                open.snap(to: 0)
                undockImmediately()
            }
            return
        }
        applyBox(geometry, geometry.layout(open: open.value, expand: expand.value), origin: origin)
    }

    private func layoutNotch() {
        guard let geometry = notch else { return }
        let origin = panel.frame.origin
        if request != nil || attention.value > 0.001 {
            let r = geometry.requestLayout(open: open.value, attention: attention.value, reveal: reveal.value, contentHeight: requestHeight)
            applyBox(geometry, r.box, origin: origin)
            view.spriteRect = r.box.sprite.offsetBy(dx: -origin.x, dy: -origin.y)
            let box = r.box.box.offsetBy(dx: -origin.x, dy: -origin.y)
            requestClip.frame = box
            requestView.frame = r.content.offsetBy(dx: -origin.x - box.minX, dy: -origin.y - box.minY)
            requestView.alphaValue = r.contentAlpha
            // Hidden, it cannot swallow clicks meant for the box.
            requestView.isHidden = r.contentAlpha < 0.02
            let h = bannerLabel.intrinsicContentSize.height
            let banner = r.banner.offsetBy(dx: -origin.x, dy: -origin.y)
            bannerLabel.frame = CGRect(x: banner.minX, y: banner.midY - h / 2, width: banner.width, height: h)
            bannerLabel.alphaValue = r.bannerAlpha
        } else {
            let l = geometry.layout(open: open.value, expand: expand.value)
            applyBox(geometry, l, origin: origin)
            view.spriteRect = l.sprite.offsetBy(dx: -origin.x, dy: -origin.y)
            bannerLabel.alphaValue = 0
            if requestView.superview === requestClip { requestView.isHidden = true }
        }
        view.squash = squash.value
    }

    private func layoutFloating() {
        view.boxPath = nil
        view.gauges = []
        view.tooltip = nil
        view.rotation = 0
        view.spriteRect = view.bounds
        view.squash = squash.value
    }

    // MARK: Motion

    private func startMotion() {
        lastStep = CACurrentMediaTime()
        guard motionTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.stepMotion() }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stepMotion() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1 / 30, now - lastStep))
        lastStep = now
        open.step(dt)
        expand.step(dt)
        attention.step(dt)
        reveal.step(dt)
        squash.step(dt)
        tilt.step(dt)
        size.step(dt)

        switch mode {
        case .flying:
            stepFlight(now: now)
            view.squash = squash.value
        case .dragging:
            stepDrag(dt: dt)
        case .dropping:
            stepDrop(dt: dt)
        case .notch:
            layoutNotch()
        case .floating:
            view.squash = squash.value
        }

        if !isTransitioning && open.isSettled && expand.isSettled && squash.isSettled && tilt.isSettled
            && attention.isSettled && reveal.isSettled {
            motionTimer?.invalidate()
            motionTimer = nil
            // The request panel has folded away: back to the small docked panel.
            if mode == .notch, request == nil, let geometry = notch, panel.frame != geometry.panelFrame {
                panel.setFrame(geometry.panelFrame, display: false)
                layoutNotch()
            }
            // The layout just settled under a cursor that may not move: re-check hover and click-through.
            trackMouse()
        }
    }

    // MARK: Drag

    private func mouseDown() {
        guard mode == .floating || mode == .notch else { return }
        let mouse = NSEvent.mouseLocation
        let rect: CGRect
        var grab: CGPoint
        if mode == .notch, let geometry = notch {
            rect = Self.regularRect(matching: geometry.layout(open: open.value, expand: expand.value).sprite)
            grab = CGPoint(x: (mouse.x - rect.minX) / rect.width, y: (mouse.y - rect.minY) / rect.height)
            // Grabbing the empty part of the box still picks the pet up by its body.
            grab = CGPoint(x: min(0.8, max(0.2, grab.x)), y: min(0.6, max(0.15, grab.y)))
        } else {
            rect = panel.frame
            grab = CGPoint(x: (mouse.x - rect.minX) / rect.width, y: (mouse.y - rect.minY) / rect.height)
        }
        drag = Drag(start: mouse, grab: grab, rect: rect, lastMouse: mouse, inZone: mode == .notch)
    }

    private func mouseDragged() {
        guard var d = drag, !d.active else { return }
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - d.start.x, mouse.y - d.start.y) > Self.dragThreshold else { return }
        d.active = true
        drag = d
        mode = .dragging
        hovering = false
        reveal.target = 0
        hideRequestUI()
        notch = notch ?? NotchGeometry.find()
        size.snap(to: d.rect.width / CGFloat(PixelCanvas.standardWidth))
        tilt.snap(to: 0)
        // Pick-up pop: a quick stretch released into the spring.
        squash.velocity = 4
        let area = NSScreen.screens.reduce(panel.frame) { $0.union($1.frame) }
        panel.setFrame(area, display: false)
        render()
        stepDrag(dt: 0)
        startMotion()
    }

    private func mouseUp() {
        guard let d = drag else { return }
        drag = nil
        guard d.active else {
            // A plain click: boop.
            squash.value = 0.78
            squash.velocity = 0
            squash.target = 1
            startMotion()
            onClick?()
            return
        }
        if d.inZone, notch != nil {
            open.target = 1
            expand.target = 1
            drop = Drop(toNotch: true, from: d.rect, to: d.rect, grab: d.grab)
        } else {
            let mouse = NSEvent.mouseLocation
            let size = Self.size(for: scale)
            var to = CGRect(
                x: mouse.x - d.grab.x * size.width, y: mouse.y - d.grab.y * size.height,
                width: size.width, height: size.height
            )
            // Land fully on screen, below the menu bar.
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                to.origin.x = min(max(to.minX, visible.minX), visible.maxX - to.width)
                to.origin.y = min(max(to.minY, visible.minY), visible.maxY - to.height)
            }
            open.target = 0
            expand.target = 0
            drop = Drop(toNotch: false, from: d.rect, to: to, grab: d.grab)
        }
        mode = .dropping
        tilt.target = 0
        panel.ignoresMouseEvents = true
        startMotion()
    }

    private func stepDrag(dt: CGFloat) {
        guard var d = drag else { return }
        let mouse = NSEvent.mouseLocation
        if dt > 0 {
            let v = CGPoint(x: (mouse.x - d.lastMouse.x) / dt, y: (mouse.y - d.lastMouse.y) / dt)
            d.velocity = CGPoint(x: d.velocity.x * 0.75 + v.x * 0.25, y: d.velocity.y * 0.75 + v.y * 0.25)
        }
        d.lastMouse = mouse

        // Proximity to the seat, measured where the held point would sit once docked. The seat is the
        // hovered one: the drop zone looks exactly like the box under the cursor at rest.
        var proximity: CGFloat = 0
        var seat: CGRect?
        if let geometry = notch, geometry.screen.frame.insetBy(dx: 0, dy: -1).contains(mouse) {
            let s = Self.regularRect(matching: geometry.layout(open: 1, expand: 1).sprite)
            let anchor = CGPoint(x: s.minX + d.grab.x * s.width, y: s.minY + d.grab.y * s.height)
            proximity = 1 - smoothstep(Self.dockRadius, Self.attractRadius, hypot(mouse.x - anchor.x, mouse.y - anchor.y))
            seat = s
        }
        // Hysteresis, so the zone does not flicker on its edge.
        let wasInZone = d.inZone
        d.inZone = d.inZone ? proximity > 0.55 : proximity > 0.7
        if d.inZone && !wasInZone { HapticPulse.strong() }

        let floatScale = CGFloat(scale)
        let seatScale = (seat?.width ?? 0) / CGFloat(PixelCanvas.standardWidth)
        let eased = 1 - pow(1 - proximity, 2)
        size.target = seat == nil ? floatScale : lerp(floatScale, seatScale, eased)
        // The held point stays exactly under the cursor, whatever the size.
        let w = CGFloat(PixelCanvas.standardWidth) * size.value
        let h = CGFloat(PixelCanvas.standardHeight) * size.value
        var rect = CGRect(x: mouse.x - d.grab.x * w, y: mouse.y - d.grab.y * h, width: w, height: h)
        // Only the body must stay on screen: the rows above it are empty while dragging.
        if let top = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.frame.maxY {
            let emptyTop = CGFloat(SpriteComposer.compactOrigin.y) * size.value
            rect.origin.y = min(rect.minY, top + emptyTop - rect.height)
        }
        d.rect = rect
        drag = d

        // The box peeks out as the pet approaches, and opens fully, as on hover, inside the zone.
        open.target = seat == nil ? 0 : (d.inZone ? 1 : min(1, proximity * 1.7))
        expand.target = d.inZone ? 1 : 0
        tilt.target = min(0.4, max(-0.4, -d.velocity.x * 0.00045))
        squash.target = 1 + min(0.12, abs(d.velocity.y) * 0.00006)

        let origin = panel.frame.origin
        view.spriteRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        view.pivot = CGPoint(x: rect.minX + d.grab.x * w - origin.x, y: rect.minY + d.grab.y * h - origin.y)
        view.rotation = tilt.value
        view.squash = squash.value
        updateBoxDuringTransition(origin: origin)
    }

    private func stepDrop(dt: CGFloat) {
        guard var dr = drop else { return }
        dr.progress.step(dt)
        drop = dr
        let k = min(1, dr.progress.value)
        // Into the notch, aim at the live seat: the box is still swollen and springing, and landing
        // exactly where the docked layout will draw the pet is what makes the hand-over invisible.
        var to = dr.to
        if dr.toNotch, let geometry = notch {
            to = Self.regularRect(matching: geometry.layout(open: open.value, expand: expand.value).sprite)
        }
        let rect = CGRect(
            x: lerp(dr.from.minX, to.minX, k), y: lerp(dr.from.minY, to.minY, k),
            width: lerp(dr.from.width, to.width, k), height: lerp(dr.from.height, to.height, k)
        )
        let origin = panel.frame.origin
        view.spriteRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        view.pivot = CGPoint(x: rect.minX + dr.grab.x * rect.width - origin.x, y: rect.minY + dr.grab.y * rect.height - origin.y)
        view.rotation = tilt.value
        view.squash = squash.value
        updateBoxDuringTransition(origin: origin)

        guard 1 - dr.progress.value < 0.004, abs(dr.progress.velocity) < 0.05 else { return }
        drop = nil
        tilt.snap(to: 0)
        view.rotation = 0
        view.pivot = nil
        squash.velocity = 0
        squash.target = 1
        if dr.toNotch, let geometry = notch {
            UserDefaults.standard.set(true, forKey: Self.notchKey)
            // Plop into the seat. The cursor is still on the box, so it stays in its hover state and
            // collapses through the normal hover logic once the cursor leaves.
            squash.value = 0.78
            open.target = 1
            hovering = true
            HapticPulse.strong()
            dock(in: geometry, settleBox: true)
        } else {
            UserDefaults.standard.set(false, forKey: Self.notchKey)
            UserDefaults.standard.set(NSStringFromPoint(dr.to.origin), forKey: Self.originKey)
            squash.value = 0.8
            open.snap(to: 0)
            undockImmediately()
        }
    }

    private func updateBoxDuringTransition(origin: CGPoint) {
        view.tooltip = nil
        guard let geometry = notch, open.value > 0.001 else {
            view.boxPath = nil
            view.gauges = []
            return
        }
        applyBox(geometry, geometry.layout(open: open.value, expand: expand.value), origin: origin)
    }

    // MARK: Mouse

    // Hybrid mouse tracking, the cheapest in both cases (measured). Still mouse: one event monitor
    // waits for the first move, costing nothing. Moving mouse: receiving every move event (60–1000 Hz)
    // costs more than looking 30 times a second, so the monitors are removed and a 30 Hz poll runs
    // until the mouse has been still for half a second.
    // Mouse events need no Accessibility permission for a global monitor, only keys do.

    private func listenForMouse() {
        guard mouseMonitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Global: moves sent to other apps. Local: those sent to us.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.mouseStarted() }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.mouseStarted()
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func mouseStarted() {
        guard mousePoll == nil else { return }
        // Removing a monitor from inside its own handler is supported, but do it on the next turn anyway.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mouseMonitors.forEach(NSEvent.removeMonitor)
            self.mouseMonitors.removeAll()
        }
        stillPolls = 0
        lastMousePosition = NSEvent.mouseLocation
        trackMouse()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.pollMouse() }
        RunLoop.main.add(timer, forMode: .common)
        mousePoll = timer
    }

    private func pollMouse() {
        let position = NSEvent.mouseLocation
        if position == lastMousePosition {
            stillPolls += 1
            guard stillPolls >= 15 else { return }
            mousePoll?.invalidate()
            mousePoll = nil
            listenForMouse()
            return
        }
        stillPolls = 0
        lastMousePosition = position
        trackMouse()
    }

    private func trackMouse() {
        guard panel.isVisible else { return }
        let local = view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        switch mode {
        case .flying, .dragging, .dropping:
            return
        case .floating:
            let hit = view.hitsSprite(at: local)
            if panel.ignoresMouseEvents == hit { panel.ignoresMouseEvents = !hit }
            if hit != petHovered {
                petHovered = hit
                if request != nil { updateFloatingCard() }
            }
        case .notch:
            let inBox = view.hitsBox(at: local)
            // The physical notch counts as part of the box for hovering, request or not (clicks there
            // still go through: the box decides what is clickable).
            let underNotch = notch.map {
                CGRect(x: $0.notchMinX, y: $0.top - $0.height, width: $0.notchMaxX - $0.notchMinX, height: $0.height + 1)
                    .contains(NSEvent.mouseLocation)
            } ?? false
            // Leave a little slack before collapsing, so the edge of the box does not flicker.
            let nearBox = underNotch || (view.boxPath?.boundingBoxOfPath.insetBy(dx: -6, dy: -6).contains(local) ?? false)
            if !hovering && (inBox || underNotch) {
                hovering = true
                if request != nil {
                    reveal.target = 1
                    seenRequestID = request?.id
                } else {
                    expand.target = 1
                }
                HapticPulse.strong()
                startMotion()
            } else if hovering && !nearBox && !typing {
                hovering = false
                expand.target = 0
                reveal.target = 0
                // Opened once: the banner does not come back, the alert sprite stays.
                attention.target = request == nil || requestSeen ? 0 : 1
                startMotion()
            }
            if panel.ignoresMouseEvents == inBox { panel.ignoresMouseEvents = !inBox }
            updateTooltip(at: local)
        }
    }

    /// Detail label for the gauge under the cursor, refreshed at the mouse polling rate so the
    /// countdowns stay live.
    private func updateTooltip(at local: CGPoint) {
        let index = hovering ? view.gauges.firstIndex { $0.alpha > 0.5 && $0.rect.insetBy(dx: -3, dy: -3).contains(local) } : nil
        if index != hoveredGauge {
            hoveredGauge = index
            if index != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        guard let index, let bottom = view.boxPath?.boundingBoxOfPath.minY else {
            if view.tooltip != nil { view.tooltip = nil }
            return
        }
        let text = gaugeDetails[index]
        let anchor = CGPoint(x: view.gauges[index].rect.midX, y: bottom)
        if view.tooltip?.text != text || view.tooltip?.anchor != anchor { view.tooltip = (text, anchor) }
    }

    // MARK: Geometry for the tutorial

    /// Where the sprite is drawn right now, in screen coordinates, whatever the mode.
    var spriteFrame: CGRect { view.spriteRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) }

    /// The sprite and, docked or near the notch, its black box: everything the pet shows on screen.
    var visibleFrame: CGRect {
        guard let box = view.boxPath?.boundingBoxOfPath, !box.isEmpty else { return spriteFrame }
        return spriteFrame.union(box.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY))
    }

    var floatingSize: NSSize { Self.size(for: scale) }

    /// A regular (floating-size) frame whose body sits on the docked pet: collapsed, or in its hovered
    /// seat, which is where a drag into the notch lands.
    func dockedRegularRect(hovered: Bool) -> CGRect? {
        guard let geometry = notch ?? NotchGeometry.find() else { return nil }
        return Self.regularRect(matching: geometry.layout(open: 1, expand: hovered ? 1 : 0).sprite)
    }

    // MARK: Helpers

    private static func size(for scale: Int) -> NSSize {
        NSSize(width: PixelCanvas.standardWidth * scale, height: PixelCanvas.standardHeight * scale)
    }

    private func render() {
        switch mode {
        case .floating: view.canvas = SpriteComposer.frame(state: state, tool: tool, t: t)
        case .flying, .dragging, .dropping:
            view.canvas = SpriteComposer.frame(state: state, tool: tool, t: t, bubble: false)
        case .notch: view.canvas = SpriteComposer.compactFrame(state: state, tool: tool, t: t)
        }
    }

    /// Rect for a regular frame whose body lands exactly on a compact frame drawn in `compact`,
    /// so the flight hands over to the docked pet without a jump.
    private static func regularRect(matching compact: CGRect) -> CGRect {
        let s = compact.width / CGFloat(SpriteComposer.compactWidth)
        let top = compact.maxY + CGFloat(SpriteComposer.compactOrigin.y) * s
        let h = CGFloat(PixelCanvas.standardHeight) * s
        return CGRect(
            x: compact.minX - CGFloat(SpriteComposer.compactOrigin.x) * s, y: top - h,
            width: CGFloat(PixelCanvas.standardWidth) * s, height: h
        )
    }

    private func savedFloatingOrigin() -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: Self.size(for: scale))
            if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) { return origin }
        }
        guard let screen = NSScreen.main?.visibleFrame else { return .zero }
        let size = Self.size(for: scale)
        return NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
    }

    private func restorePosition() {
        panel.setFrameOrigin(savedFloatingOrigin())
    }

    @objc private func windowDidMove(_ note: Notification) {
        guard mode == .floating else { return }
        card.follow(panel.frame)
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    @objc private func screensChanged(_ note: Notification) {
        guard mode == .notch else { return }
        // Lid closed, display unplugged, resolution changed: re-dock, or fall back to floating.
        if let geometry = NotchGeometry.find() {
            dock(in: geometry)
        } else {
            undockImmediately()
        }
    }
}

/// `NSHapticFeedbackManager` has no intensity setting and its patterns are all subtle, so a "strong"
/// pulse is a short burst of the firmest one. Only felt while a finger rests on a Force Touch trackpad.
enum HapticPulse {
    static let count = 3
    static let spacing: TimeInterval = 0.04

    static func strong() {
        let performer = NSHapticFeedbackManager.defaultPerformer
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(i)) {
                performer.perform(.levelChange, performanceTime: .now)
            }
        }
    }
}

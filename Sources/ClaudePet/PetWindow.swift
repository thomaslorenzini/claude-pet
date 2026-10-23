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

    override var canBecomeKey: Bool { false }
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
    /// Black notch box, drawn behind the sprite.
    var boxPath: CGPath? { didSet { needsDisplay = true } }
    var allowsDrag = true
    var contextMenuProvider: (() -> NSMenu)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let boxPath {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(boxPath)
            ctx.fillPath()
        }
        guard let image = canvas.makeImage(), spriteRect.width > 0 else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: spriteRect.midX, y: spriteRect.minY)
        ctx.rotate(by: rotation)
        ctx.scaleBy(x: 1 + (1 - squash) * 0.6, y: squash)
        ctx.translateBy(x: -spriteRect.midX, y: -spriteRect.minY)
        ctx.draw(image, in: spriteRect)
        ctx.restoreGState()
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

    override func mouseDown(with event: NSEvent) {
        if allowsDrag { window?.performDrag(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Owns the panel, animates the sprite and makes everything but the sprite click-through.
///
/// Two resting modes: `floating` (the panel is exactly the sprite, draggable) and `notch` (the panel
/// covers the black box glued to the notch). `flying` is the transition between them: the panel is
/// temporarily stretched over the screen(s) and the sprite travels across it.
final class PetController: NSObject {
    static let fps: Double = 4
    private static let originKey = "petOrigin"
    private static let scaleKey = "petScale"
    private static let notchKey = "petInNotch"

    enum Mode { case floating, notch, flying }

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
    private(set) var mode = Mode.floating
    private var t = 0
    private var timers: [Timer] = []

    private var notch: NotchGeometry?
    private var flight: Flight?
    private var open = Spring(value: 0, target: 0, stiffness: 320, damping: 22)
    private var expand = Spring(value: 0, target: 0, stiffness: 300, damping: 18)
    private var squash = Spring(value: 1, target: 1, stiffness: 520, damping: 13)
    private var motionTimer: Timer?
    private var lastStep = CACurrentMediaTime()
    private var hovering = false

    override init() {
        let saved = UserDefaults.standard.integer(forKey: Self.scaleKey)
        scale = (3...8).contains(saved) ? saved : 5
        let size = Self.size(for: scale)
        panel = PetPanel(size: size)
        view = PetView(frame: NSRect(origin: .zero, size: size))
        super.init()
        panel.contentView = view
        view.autoresizingMask = [.width, .height]
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
        timers.append(Timer.scheduledTimer(withTimeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            self?.t += 1
            self?.render()
        })
        // Polling is cheap and needs no Accessibility permission, unlike a global event monitor.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            self?.trackMouse()
        })
        timers.forEach { RunLoop.main.add($0, forMode: .common) }

        if UserDefaults.standard.bool(forKey: Self.notchKey), let geometry = NotchGeometry.find() {
            dock(in: geometry)
        }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }

    func update(state: PetState, tool: ToolKind?) {
        guard state != self.state || tool != self.tool else { return }
        self.state = state
        self.tool = tool
        t = 0
        render()
    }

    func setScale(_ newScale: Int) {
        scale = newScale
        UserDefaults.standard.set(newScale, forKey: Self.scaleKey)
        guard mode == .floating else { return }
        // Keep the feet where they were.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: Self.size(for: newScale)), display: true)
        layoutFloating()
    }

    enum Corner { case bottomRight, bottomLeft, topRight, topLeft }

    func move(to corner: Corner) {
        guard mode == .floating, let screen = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size, margin: CGFloat = 24
        let x = (corner == .bottomLeft || corner == .topLeft) ? screen.minX + margin : screen.maxX - size.width - margin
        let y = (corner == .bottomLeft || corner == .bottomRight) ? screen.minY + margin : screen.maxY - size.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Notch

    var notchAvailable: Bool { NotchGeometry.find() != nil }
    /// The user's choice, also true while flying towards the notch.
    var wantsNotch: Bool { UserDefaults.standard.bool(forKey: Self.notchKey) }
    var isFlying: Bool { mode == .flying }

    func setNotchMode(_ on: Bool) {
        guard mode != .flying else { return }
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

    private func dock(in geometry: NotchGeometry, settleBox: Bool = false) {
        notch = geometry
        mode = .notch
        // After a flight the box is still springing open: let it finish its bounce.
        if !settleBox { open.snap(to: 1) }
        panel.setFrame(geometry.panelFrame, display: true)
        view.allowsDrag = false
        render()
        layoutNotch()
    }

    private func undockImmediately() {
        mode = .floating
        notch = nil
        hovering = false
        expand.snap(to: 0)
        panel.setFrame(CGRect(origin: savedFloatingOrigin(), size: Self.size(for: scale)), display: true)
        render()
        layoutFloating()
    }

    private func startFlight(_ f: Flight) {
        mode = .flying
        flight = f
        view.allowsDrag = false
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
        view.boxPath = geometry.path(for: geometry.layout(open: open.value, expand: expand.value), origin: origin)
    }

    private func layoutNotch() {
        guard let geometry = notch else { return }
        let l = geometry.layout(open: open.value, expand: expand.value)
        let origin = panel.frame.origin
        view.boxPath = geometry.path(for: l, origin: origin)
        view.spriteRect = l.sprite.offsetBy(dx: -origin.x, dy: -origin.y)
        view.squash = squash.value
    }

    private func layoutFloating() {
        view.boxPath = nil
        view.rotation = 0
        view.spriteRect = view.bounds
        view.squash = squash.value
        view.allowsDrag = true
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
        squash.step(dt)

        switch mode {
        case .flying:
            stepFlight(now: now)
            view.squash = squash.value
        case .notch:
            layoutNotch()
        case .floating:
            view.squash = squash.value
        }

        if mode != .flying && open.isSettled && expand.isSettled && squash.isSettled {
            motionTimer?.invalidate()
            motionTimer = nil
        }
    }

    // MARK: Mouse

    private func trackMouse() {
        guard panel.isVisible else { return }
        let local = view.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        switch mode {
        case .flying:
            return
        case .floating:
            let hit = view.hitsSprite(at: local)
            if panel.ignoresMouseEvents == hit { panel.ignoresMouseEvents = !hit }
        case .notch:
            let inBox = view.hitsBox(at: local)
            // Leave a little slack before collapsing, so the edge of the box does not flicker.
            let nearBox = view.boxPath?.boundingBoxOfPath.insetBy(dx: -6, dy: -6).contains(local) ?? false
            if !hovering && inBox {
                hovering = true
                expand.target = 1
                HapticPulse.strong()
                startMotion()
            } else if hovering && !nearBox {
                hovering = false
                expand.target = 0
                startMotion()
            }
            if panel.ignoresMouseEvents == inBox { panel.ignoresMouseEvents = !inBox }
        }
    }

    // MARK: Helpers

    private static func size(for scale: Int) -> NSSize {
        NSSize(width: PixelCanvas.standardWidth * scale, height: PixelCanvas.standardHeight * scale)
    }

    private func render() {
        switch mode {
        case .floating: view.canvas = SpriteComposer.frame(state: state, tool: tool, t: t)
        case .flying: view.canvas = SpriteComposer.frame(state: state, tool: tool, t: t, bubble: false)
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

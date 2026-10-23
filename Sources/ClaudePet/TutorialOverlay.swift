import AppKit

/// First-run tutorial, right after the installation: the notch screen dims around a spotlight on the
/// pet, and a fake cursor shows the two gestures (pull the pet out of the notch, then put it back),
/// looping until the user has done each one for real. Shown once (`doneKey`).
///
/// The overlay sits just below the pet's panel and lets every click through, so the real drag works
/// unchanged; only the caption (with "Passer") takes clicks, in its own small panel. One 60 Hz timer
/// runs while the tutorial is on screen, nothing afterwards.
final class TutorialOverlay: NSObject {
    enum Step: String { case dragOut = "drag_out", dragIn = "drag_in", done }

    static let doneKey = "tutorialDone"

    private(set) var step: Step
    /// Called once everything has faded out and the windows are gone.
    var onFinish: (() -> Void)?

    private unowned let pet: PetController
    private let screen: NSScreen
    private let window: NSPanel
    private let container = NSView()
    private let dim = SpotlightView()
    private let ghost = GhostView()
    private let cursor = FakeCursorView()
    private let captionPanel = CaptionPanel()
    private let caption = CaptionView()
    private var timer: Timer?
    private var keyMonitor: Any?
    private var lastTick = CACurrentMediaTime()
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Spotlight edges (minX, minY, maxX, maxY), each on its own spring: it glides between steps and
    /// trails the real pet while the user drags it.
    private var edges: [Spring]
    /// Whole overlay: fades in, and out at the end.
    private var fade = Spring(value: 0, target: 1, stiffness: 55, damping: 2 * sqrt(55))
    /// Fake cursor and ghost: they get out of the way fast when the user grabs the real pet.
    private var demoAlpha = Spring(value: 1, target: 1, stiffness: 420, damping: 2 * sqrt(420))
    /// The demo loop's clock origin; before it, nothing is shown (a breath between attempts).
    private var demoStart: CFTimeInterval
    /// Caption cross-fade when the step changes.
    private var captionAlpha = Spring(value: 1, target: 1, stiffness: 340, damping: 2 * sqrt(340))
    private var captionStep: Step
    private var finishing = false
    private var doneAt: CFTimeInterval?

    private static let loop: CGFloat = 4.9
    private static let feather: CGFloat = 46
    private static let padding: CGFloat = 26

    /// Starts on the notch screen, from the step that matches where the pet is. Nil without a notch.
    init?(pet: PetController) {
        guard let geometry = NotchGeometry.find(), pet.mode == .notch || pet.mode == .floating else { return nil }
        self.pet = pet
        screen = geometry.screen
        step = pet.mode == .notch ? .dragOut : .dragIn
        captionStep = step
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        demoStart = CACurrentMediaTime() + 0.9
        // Opens from the whole screen down to the pet, as the dim fades in.
        let wide = screen.frame.insetBy(dx: -200, dy: -200)
        edges = [wide.minX, wide.minY, wide.maxX, wide.maxY].map {
            Spring(value: $0, target: $0, stiffness: 120, damping: 0.85 * 2 * sqrt(120))
        }
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Just below the pet's panel (statusBar + 1): the pet stays on top and takes its own clicks.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.alphaValue = 0
        container.frame = CGRect(origin: .zero, size: screen.frame.size)
        container.wantsLayer = true
        window.contentView = container
        dim.frame = container.bounds
        dim.autoresizingMask = [.width, .height]
        container.addSubview(dim)
        container.addSubview(ghost)
        container.addSubview(cursor)
        ghost.isHidden = true
        cursor.isHidden = true

        captionPanel.contentView = caption
        captionPanel.alphaValue = 0
        caption.onSkip = { [weak self] in self?.skip() }
        caption.show(step)
    }

    func start() {
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        layoutCaption(force: true)
        captionPanel.orderFrontRegardless()
        // Escape works while the app is active (it is, right after the onboarding window): a global
        // key monitor would need the Accessibility permission, and taking the keyboard would steal it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, !self.finishing else { return event }
            self.skip()
            return nil
        }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Ends at once, without marking the tutorial as seen (tests).
    func stop() {
        teardown()
    }

    /// "Passer" or Escape: seen, fade out.
    func skip() {
        guard !finishing else { return }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        finishing = true
        demoAlpha.target = 0
        fade.stiffness = 120
        fade.damping = 2 * sqrt(120)
        fade.target = 0
    }

    // MARK: Following the real pet

    func petModeChanged(_ mode: PetController.Mode) {
        guard !finishing, step != .done else { return }
        let now = CACurrentMediaTime()
        switch (step, mode) {
        case (_, .dragging), (_, .flying):
            demoAlpha.target = 0
        case (.dragOut, .floating):
            step = .dragIn
            restartDemo(at: now + 1.1)
        case (.dragIn, .notch):
            step = .done
            doneAt = now
            demoAlpha.target = 0
            UserDefaults.standard.set(true, forKey: Self.doneKey)
        case (.dragOut, .notch), (.dragIn, .floating):
            // Dropped back where it was: show the gesture again, after a short breath.
            restartDemo(at: now + 0.7)
        default:
            break
        }
    }

    private func restartDemo(at time: CFTimeInterval) {
        demoStart = time
        demoAlpha.snap(to: 1)
    }

    /// The demo plays while the pet rests where the current step starts from.
    private var demoActive: Bool {
        !finishing && ((step == .dragOut && pet.mode == .notch) || (step == .dragIn && pet.mode == .floating))
    }

    // MARK: Frame

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1 / 30, now - lastTick))
        lastTick = now

        if let doneAt, !finishing, now - doneAt > 2.0 {
            finishing = true
            fade.stiffness = 70
            fade.damping = 2 * sqrt(70)
            fade.target = 0
        }

        let path = demoPath()
        let target = spotlightTarget(path)
        let targets = [target.minX, target.minY, target.maxX, target.maxY]
        for i in 0..<4 {
            edges[i].target = targets[i]
            if reduceMotion { edges[i].snap(to: targets[i]) } else { edges[i].step(dt) }
        }
        fade.step(dt)
        demoAlpha.step(dt)
        captionAlpha.step(dt)
        if captionStep != step {
            captionAlpha.target = 0
            if captionAlpha.value < 0.04 {
                captionStep = step
                caption.show(step)
                layoutCaption(force: true)
                captionAlpha.target = 1
            }
        }

        window.alphaValue = fade.value
        let spot = CGRect(x: edges[0].value, y: edges[1].value,
                          width: edges[2].value - edges[0].value, height: edges[3].value - edges[1].value)
        dim.setHole(spot.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), feather: Self.feather)

        let pose = demoActive ? path.flatMap { reduceMotion ? staticPose($0) : self.pose(at: CGFloat(now - demoStart), $0) } : nil
        apply(pose)
        layoutCaption(force: false)
        captionPanel.alphaValue = fade.value * max(0, min(1, captionAlpha.value))

        if finishing, fade.target == 0, fade.value < 0.01 { teardown() }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window.orderOut(nil)
        captionPanel.orderOut(nil)
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    // MARK: Spotlight

    private func spotlightTarget(_ path: DemoPath?) -> CGRect {
        var rect = pet.visibleFrame
        // Around the whole gesture while it is shown, around the pet alone while the user moves it.
        if demoActive, let path {
            rect = rect.union(path.from).union(path.to)
            if step == .dragIn, let box = pet.dockedRegularRect(hovered: false) { rect = rect.union(box) }
        }
        return rect.insetBy(dx: -Self.padding, dy: -Self.padding)
    }

    // MARK: Caption

    private func layoutCaption(force: Bool) {
        let size = caption.fittingSize
        let spot = CGRect(x: edges[0].value, y: edges[1].value,
                          width: edges[2].value - edges[0].value, height: edges[3].value - edges[1].value)
        let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        var origin = CGPoint(x: spot.midX - size.width / 2, y: min(spot.minY + 10, screen.frame.maxY - 60) - size.height)
        if origin.y < visible.minY { origin.y = min(spot.maxY + 10, visible.maxY - size.height) }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        let frame = CGRect(origin: origin, size: size).integral
        let current = captionPanel.frame
        guard force || abs(current.minX - frame.minX) > 0.5 || abs(current.minY - frame.minY) > 0.5
                || current.size != frame.size else { return }
        captionPanel.setFrame(frame, display: true)
        if current.size != frame.size { captionPanel.invalidateShadow() }
    }

    // MARK: Demo

    /// The ghost's rect where the drag starts and where it ends, and the cursor's resting point.
    private struct DemoPath {
        let from: CGRect
        let to: CGRect
        let approach: CGPoint
        /// Point of the sprite held under the cursor, as a fraction of its rect (on the body).
        let grab = CGPoint(x: 0.5, y: 0.36)
        func held(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX + grab.x * r.width, y: r.minY + grab.y * r.height) }
    }

    private struct Pose {
        var cursor: CGPoint
        var cursorAlpha: CGFloat
        var press: CGFloat
        var ripple: CGFloat?
        var ghost: CGRect
        var ghostAlpha: CGFloat
        var rotation: CGFloat
        var pivot: CGPoint
    }

    private func demoPath() -> DemoPath? {
        let size = pet.floatingSize
        let visible = screen.visibleFrame.insetBy(dx: 40, dy: 40)
        switch step {
        case .dragOut:
            guard let from = pet.dockedRegularRect(hovered: false) else { return nil }
            let grab = CGPoint(x: from.midX, y: from.minY + 0.36 * from.height)
            // A little down and to the left, well out of the notch: where a hand would naturally go.
            let held = CGPoint(x: grab.x - 70, y: screen.frame.maxY - 230)
            let to = CGRect(x: held.x - 0.5 * size.width, y: held.y - 0.36 * size.height, width: size.width, height: size.height)
            return DemoPath(from: from, to: to, approach: clamp(CGPoint(x: grab.x + 190, y: grab.y - 170), visible))
        case .dragIn:
            guard let to = pet.dockedRegularRect(hovered: true) else { return nil }
            let from = pet.spriteFrame
            let held = CGPoint(x: from.midX, y: from.minY + 0.36 * from.height)
            return DemoPath(from: from, to: to, approach: clamp(CGPoint(x: held.x + 170, y: held.y - 130), visible))
        case .done:
            return nil
        }
    }

    private func clamp(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    /// One loop: the cursor glides in on a curve, presses (ripple), drags the ghost along another curve,
    /// releases, drifts away and fades; a pause, then again. Every move is eased at both ends.
    private func pose(at time: CGFloat, _ p: DemoPath) -> Pose? {
        guard time >= 0 else { return nil }
        let τ = time.truncatingRemainder(dividingBy: Self.loop)
        let start = p.held(p.from), end = p.held(p.to)

        func cursorAt(_ τ: CGFloat) -> CGPoint {
            if τ < 1.5 { return Self.arc(p.approach, start, bend: 0.14, Self.smootherstep(0.12, 1.15, τ)) }
            if τ < 3.05 { return Self.arc(start, end, bend: step == .dragOut ? -0.16 : 0.16, Self.smootherstep(1.5, 2.85, τ)) }
            // Lets go and drifts off, slowing down.
            let k = 1 - pow(1 - min(1, (τ - 3.05) / 0.85), 3)
            return CGPoint(x: end.x + 30 * k, y: end.y - 26 * k)
        }

        let c = cursorAt(τ)
        let u = Self.smootherstep(1.5, 2.85, τ)
        // The real pet grows as soon as it leaves the notch, and shrinks only once it reaches it.
        let grow = step == .dragOut ? smoothstep(0, 0.45, u) : smoothstep(0.55, 1, u)
        let w = lerp(p.from.width, p.to.width, grow), h = lerp(p.from.height, p.to.height, grow)
        let held = τ < 3.05 ? c : end
        let ghost = CGRect(x: held.x - p.grab.x * w, y: held.y - p.grab.y * h, width: w, height: h)
        // A slight swing from the horizontal speed, as the real drag does.
        var rotation: CGFloat = 0
        if τ > 1.5, τ < 2.9 {
            let before = cursorAt(τ - 1 / 60)
            rotation = min(0.22, max(-0.22, -(c.x - before.x) * 60 * 0.0005))
        }
        return Pose(
            cursor: c,
            cursorAlpha: smoothstep(0, 0.35, τ) * (1 - smoothstep(3.3, 3.9, τ)),
            press: smoothstep(1.17, 1.35, τ) - smoothstep(2.88, 3.04, τ),
            ripple: τ >= 1.22 && τ < 1.87 ? (τ - 1.22) / 0.65 : nil,
            ghost: ghost,
            ghostAlpha: 0.5 * smoothstep(1.2, 1.45, τ) * (1 - smoothstep(3.05, 3.6, τ)),
            rotation: rotation,
            pivot: held
        )
    }

    /// Reduced motion: no cursor, the ghost waits where the pet should go.
    private func staticPose(_ p: DemoPath) -> Pose {
        Pose(cursor: .zero, cursorAlpha: 0, press: 0, ripple: nil, ghost: p.to, ghostAlpha: 0.4, rotation: 0, pivot: p.held(p.to))
    }

    private func apply(_ pose: Pose?) {
        let origin = screen.frame.origin
        let alpha = max(0, min(1, demoAlpha.value))
        guard let pose, alpha > 0.01 else {
            ghost.isHidden = true
            cursor.isHidden = true
            return
        }
        // Ghost: drawn in a view a bit larger than the sprite, so the swing never clips it.
        let g = pose.ghost.offsetBy(dx: -origin.x, dy: -origin.y)
        let frame = g.insetBy(dx: -g.width * 0.3, dy: -g.height * 0.3).integral
        ghost.isHidden = pose.ghostAlpha * alpha < 0.01
        if !ghost.isHidden {
            if ghost.frame != frame { ghost.frame = frame }
            ghost.update(sprite: g.offsetBy(dx: -frame.minX, dy: -frame.minY),
                         pivot: CGPoint(x: pose.pivot.x - origin.x - frame.minX, y: pose.pivot.y - origin.y - frame.minY),
                         rotation: pose.rotation)
            ghost.alphaValue = pose.ghostAlpha * alpha
        }
        cursor.isHidden = pose.cursorAlpha * alpha < 0.01
        if !cursor.isHidden {
            let s = FakeCursorView.side
            let tip = CGPoint(x: pose.cursor.x - origin.x, y: pose.cursor.y - origin.y)
            // Whole points: a cursor sliding by fractions of a pixel would shimmer.
            let frame = CGRect(x: (tip.x - s / 2).rounded(), y: (tip.y - s / 2).rounded(), width: s, height: s)
            if cursor.frame != frame { cursor.frame = frame }
            cursor.update(tip: CGPoint(x: tip.x - frame.minX, y: tip.y - frame.minY), press: pose.press, ripple: pose.ripple)
            cursor.alphaValue = pose.cursorAlpha * alpha
        }
    }

    // MARK: Easing

    private static func smootherstep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    /// Quadratic curve from `a` to `b`, bowed sideways by `bend` × the distance: hands never move straight.
    private static func arc(_ a: CGPoint, _ b: CGPoint, bend: CGFloat, _ t: CGFloat) -> CGPoint {
        let c = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * bend, y: (a.y + b.y) / 2 + (b.x - a.x) * bend)
        let q = 1 - t
        return CGPoint(x: q * q * a.x + 2 * q * t * c.x + t * t * b.x, y: q * q * a.y + 2 * q * t * c.y + t * t * b.y)
    }

    // MARK: Tests

    var stateName: String { step.rawValue }

    /// The overlay as it stands, caption included, even with the display asleep.
    func snapshot(to path: String) {
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        if let captionRep = caption.bitmapImageRepForCachingDisplay(in: caption.bounds),
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            caption.cacheDisplay(in: caption.bounds, to: captionRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let f = captionPanel.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            captionRep.draw(in: f, from: .zero, operation: .sourceOver, fraction: captionPanel.alphaValue, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Views

/// The dimmed screen, with a soft-edged hole. Only the region the hole leaves or enters is redrawn.
final class SpotlightView: NSView {
    private(set) var hole: CGRect?
    private var feather: CGFloat = 40
    private static let dim = NSColor.black.withAlphaComponent(0.3)

    func setHole(_ rect: CGRect, feather: CGFloat) {
        // Whole points: the soft edge is built from strips and corners that must meet without seams.
        let r = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
        guard r != hole || feather != self.feather else { return }
        let old = hole.map { $0.insetBy(dx: -self.feather - 2, dy: -self.feather - 2) }
        hole = r
        self.feather = feather
        let new = r.insetBy(dx: -feather - 2, dy: -feather - 2)
        setNeedsDisplay(old.map { $0.union(new) } ?? bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Self.dim.cgColor)
        ctx.fill(dirtyRect)
        guard let hole, hole.width > 0, hole.height > 0 else { return }
        ctx.setBlendMode(.destinationOut)
        Self.clearSoftRect(hole, radius: min(30, hole.width / 2, hole.height / 2).rounded(), feather: feather, in: ctx)
    }

    /// Clears a rounded rect fully and fades the clearing out over `feather` points around it: linear
    /// gradients along the sides, radial ones at the corners (exact, and cheap compared to a blur).
    private static func clearSoftRect(_ c: CGRect, radius r: CGFloat, feather f: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(roundedRect: c, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        guard let gradient = falloff else { return }
        let w = c.width - 2 * r, h = c.height - 2 * r
        func strip(_ clip: CGRect, _ from: CGPoint, _ to: CGPoint) {
            guard clip.width > 0, clip.height > 0 else { return }
            ctx.saveGState()
            ctx.clip(to: clip)
            ctx.drawLinearGradient(gradient, start: from, end: to, options: [])
            ctx.restoreGState()
        }
        strip(CGRect(x: c.minX + r, y: c.maxY, width: w, height: f), CGPoint(x: 0, y: c.maxY), CGPoint(x: 0, y: c.maxY + f))
        strip(CGRect(x: c.minX + r, y: c.minY - f, width: w, height: f), CGPoint(x: 0, y: c.minY), CGPoint(x: 0, y: c.minY - f))
        strip(CGRect(x: c.minX - f, y: c.minY + r, width: f, height: h), CGPoint(x: c.minX, y: 0), CGPoint(x: c.minX - f, y: 0))
        strip(CGRect(x: c.maxX, y: c.minY + r, width: f, height: h), CGPoint(x: c.maxX, y: 0), CGPoint(x: c.maxX + f, y: 0))
        let corners = [
            (CGPoint(x: c.minX + r, y: c.maxY - r), CGPoint(x: -1, y: 1)),
            (CGPoint(x: c.maxX - r, y: c.maxY - r), CGPoint(x: 1, y: 1)),
            (CGPoint(x: c.minX + r, y: c.minY + r), CGPoint(x: -1, y: -1)),
            (CGPoint(x: c.maxX - r, y: c.minY + r), CGPoint(x: 1, y: -1)),
        ]
        for (center, dir) in corners {
            let s = r + f
            let clip = CGRect(x: dir.x < 0 ? center.x - s : center.x, y: dir.y < 0 ? center.y - s : center.y, width: s, height: s)
            ctx.saveGState()
            ctx.clip(to: clip)
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: r, endCenter: center, endRadius: s, options: [])
            ctx.restoreGState()
        }
    }

    /// Opaque to clear, eased (smoothstep), so the edge has no visible start or end.
    private static let falloff: CGGradient? = {
        let n = 10
        var colors: [CGColor] = [], locations: [CGFloat] = []
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            locations.append(t)
            colors.append(NSColor.black.withAlphaComponent(1 - t * t * (3 - 2 * t)).cgColor)
        }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
    }()
}

/// The pet's translucent double, carried by the fake cursor.
final class GhostView: NSView {
    private let image = SpriteComposer.frame(state: .idle, tool: nil, t: 0, bubble: false).makeImage()
    private var sprite = CGRect.zero
    private var pivot = CGPoint.zero
    private var rotation: CGFloat = 0

    func update(sprite: CGRect, pivot: CGPoint, rotation: CGFloat) {
        guard sprite != self.sprite || pivot != self.pivot || rotation != self.rotation else { return }
        self.sprite = sprite
        self.pivot = pivot
        self.rotation = rotation
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        ctx.interpolationQuality = .none
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: rotation)
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        ctx.draw(image, in: sprite)
    }
}

/// An arrow cursor with a soft shadow, that shrinks a little and sends a ripple when it presses.
final class FakeCursorView: NSView {
    static let side: CGFloat = 96
    private var tip = CGPoint.zero
    private var press: CGFloat = 0
    private var ripple: CGFloat?

    func update(tip: CGPoint, press: CGFloat, ripple: CGFloat?) {
        guard tip != self.tip || press != self.press || ripple != self.ripple else { return }
        self.tip = tip
        self.press = press
        self.ripple = ripple
        needsDisplay = true
    }

    /// The system arrow's outline, tip at the origin, y going down.
    private static let arrow: CGPath = {
        let p = CGMutablePath()
        let points: [CGPoint] = [
            .init(x: 0, y: 0), .init(x: 0, y: 16.6), .init(x: 3.9, y: 12.9), .init(x: 6.5, y: 18.8),
            .init(x: 9.1, y: 17.7), .init(x: 6.6, y: 12.0), .init(x: 11.9, y: 12.0),
        ]
        p.addLines(between: points.map { CGPoint(x: $0.x, y: -$0.y) })
        p.closeSubpath()
        return p
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let k = ripple {
            let e = 1 - pow(1 - k, 3)
            let radius = 5 + 24 * e
            let ring = CGRect(x: tip.x - radius, y: tip.y - radius, width: 2 * radius, height: 2 * radius)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.16 * (1 - k)).cgColor)
            ctx.fillEllipse(in: ring)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75 * (1 - k) * (1 - k)).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: ring.insetBy(dx: 0.75, dy: 0.75))
        }
        ctx.saveGState()
        ctx.translateBy(x: tip.x, y: tip.y)
        let s = 1.08 * (1 - 0.13 * press)
        ctx.scaleBy(x: s, y: s)
        ctx.setLineJoin(.round)
        // Softer, closer shadow when pressed, as if the cursor came down onto the screen.
        ctx.setShadow(offset: CGSize(width: 0, height: -2 + press), blur: 7 - 3 * press,
                      color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.addPath(Self.arrow)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.6)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(Self.arrow)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// The caption's own small panel: the only part of the tutorial that takes clicks ("Passer").
final class CaptionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A pill: step badge, the instruction in Claude's serif, and a discreet "Passer · esc".
final class CaptionView: NSView {
    var onSkip: (() -> Void)?
    private var step = TutorialOverlay.Step.dragOut
    private var skipHovered = false { didSet { needsDisplay = true } }
    private var skipPressed = false { didSet { needsDisplay = true } }
    private static let height: CGFloat = 40

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ step: TutorialOverlay.Step) {
        self.step = step
        skipHovered = false
        setFrameSize(fittingSize)
        needsDisplay = true
    }

    private var title: String {
        switch step {
        case .dragOut: return tr("Attrape le pet et sors-le de l'encoche", "Grab the pet and pull it out of the notch")
        case .dragIn: return tr("Maintenant, ramène-le dans l'encoche", "Now drag it back into the notch")
        case .done: return tr("C'est tout !", "That's it!")
        }
    }

    private var badge: String? {
        switch step {
        case .dragOut: return "1/2"
        case .dragIn: return "2/2"
        case .done: return nil
        }
    }

    private var skippable: Bool { step != .done }

    private func parts(_ theme: PanelTheme) -> (badge: NSAttributedString?, title: NSAttributedString, skip: NSAttributedString, key: NSAttributedString) {
        (
            badge.map { $0.attributed(.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), theme.accent) },
            title.attributed(.serif(15), theme.text),
            tr("Passer", "Skip").attributed(.systemFont(ofSize: 12, weight: .medium), skipHovered ? theme.text : theme.secondary),
            "esc".attributed(.systemFont(ofSize: 10, weight: .medium), theme.tertiary)
        )
    }

    /// x of each part, and the total width.
    private func layout(_ theme: PanelTheme) -> (badge: CGFloat, title: CGFloat, divider: CGFloat, skip: CGFloat, key: CGFloat, width: CGFloat) {
        let p = parts(theme)
        var x: CGFloat = 16
        let badgeX = x
        if let b = p.badge { x += b.size().width + 14 + 10 }
        if step == .done { x += 22 }
        let titleX = x
        x += p.title.size().width
        guard skippable else { return (badgeX, titleX, 0, 0, 0, x + 18) }
        x += 16
        let dividerX = x
        x += 1 + 14
        let skipX = x
        x += p.skip.size().width + 7
        let keyX = x
        x += p.key.size().width + 10 + 14
        return (badgeX, titleX, dividerX, skipX, keyX, x)
    }

    override var fittingSize: NSSize {
        NSSize(width: ceil(layout(PanelTheme.current(effectiveAppearance)).width), height: Self.height)
    }

    private var skipRect: CGRect {
        let l = layout(PanelTheme.current(effectiveAppearance))
        return skippable ? CGRect(x: l.divider, y: 0, width: bounds.width - l.divider, height: bounds.height) : .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let p = parts(theme), l = layout(theme)
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.height / 2, yRadius: Self.height / 2)
        theme.background.setFill()
        pill.fill()
        theme.stroke.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        let mid = bounds.height / 2

        if let b = p.badge {
            let size = b.size()
            let capsule = CGRect(x: l.badge, y: mid - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
            theme.accent.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
            b.draw(at: CGPoint(x: capsule.minX + 7, y: capsule.minY + 3))
        }
        if step == .done {
            // A small accent disc with a tick, the same mark as the onboarding's success.
            let disc = CGRect(x: 16, y: mid - 8, width: 16, height: 16)
            theme.accent.setFill()
            NSBezierPath(ovalIn: disc).fill()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: disc.minX + 4.5, y: disc.midY + 0.2))
            tick.line(to: CGPoint(x: disc.minX + 7, y: disc.midY + 2.7))
            tick.line(to: CGPoint(x: disc.minX + 11.6, y: disc.midY - 2.6))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        }
        let titleSize = p.title.size()
        p.title.draw(at: CGPoint(x: l.title, y: mid - titleSize.height / 2))

        guard skippable else { return }
        theme.stroke.setFill()
        CGRect(x: l.divider, y: mid - 8, width: 1, height: 16).fill()
        if skipHovered || skipPressed {
            theme.text.withAlphaComponent(skipPressed ? 0.09 : 0.05).setFill()
            let r = CGRect(x: l.divider + 6, y: 5, width: bounds.width - l.divider - 11, height: bounds.height - 10)
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
        let skipSize = p.skip.size()
        p.skip.draw(at: CGPoint(x: l.skip, y: mid - skipSize.height / 2))
        let keySize = p.key.size()
        let cap = CGRect(x: l.key, y: mid - keySize.height / 2 - 1.5, width: keySize.width + 10, height: keySize.height + 3)
        let capPath = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        theme.tertiary.withAlphaComponent(0.5).setStroke()
        capPath.lineWidth = 1
        capPath.stroke()
        p.key.draw(at: CGPoint(x: cap.minX + 5, y: cap.minY + 1.5))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { skipHovered = skipRect.contains(local(event)) }
    override func mouseEntered(with event: NSEvent) { skipHovered = skipRect.contains(local(event)) }
    override func mouseExited(with event: NSEvent) { skipHovered = false }
    override func mouseDown(with event: NSEvent) { skipPressed = skipRect.contains(local(event)) }
    override func mouseUp(with event: NSEvent) {
        let fire = skipPressed && skipRect.contains(local(event))
        skipPressed = false
        if fire { onSkip?() }
    }

    /// Tests: as a click on "Passer".
    func pressSkip() { if skippable { onSkip?() } }
}

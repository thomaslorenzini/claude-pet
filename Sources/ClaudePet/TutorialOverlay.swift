import AppKit

/// First-run tutorial, right after the installation: the notch screen dims around a spotlight on the
/// pet, and a fake cursor shows the two gestures (pull the pet out of the notch, then put it back),
/// looping until the user has done each one for real. Shown once (`doneKey`).
///
/// The overlay sits just below the pet's panel and lets every click through, so the real drag works
/// unchanged; only the caption (with "Passer") takes clicks, in its own small panel. One 60 Hz timer
/// runs while the tutorial is on screen, nothing afterwards.
final class TutorialOverlay: NSObject {
    /// 1/4 the pet in the notch and its "Claude needs you", 2/4 pull it out, 3/4 floating and its alert,
    /// 4/4 put it back.
    enum Step: String {
        case notchIntro = "notch_intro", dragOut = "drag_out", floatingIntro = "floating_intro", dragIn = "drag_in", done
    }

    static let doneKey = "tutorialDone"

    private(set) var step: Step
    /// Called once everything has faded out and the windows are gone.
    var onFinish: (() -> Void)?

    private unowned let pet: PetController
    private let screen: NSScreen
    /// The dim, just below the pet's panel (statusBar + 1): the pet stays bright and takes its own clicks.
    private let window: NSPanel
    private let container = NSView()
    /// Fake cursor and ghost, just above the pet's panel: a pointer always passes over everything,
    /// including the pet and its black notch box.
    private let pointerWindow: NSPanel
    private let pointerContainer = NSView()
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
    /// Explanation steps: when the demo's "Claude needs you" shows (a breath after the step starts).
    private var alertFrom: CFTimeInterval

    /// The pet's panel is at statusBar + 1.
    static let aboveThePet = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
    private static let loop: CGFloat = 4.9
    private static let feather: CGFloat = 46
    private static let padding: CGFloat = 26

    /// Starts on the notch screen, from the step that matches where the pet is. Nil without a notch.
    init?(pet: PetController) {
        guard let geometry = NotchGeometry.find(), pet.mode == .notch || pet.mode == .floating else { return nil }
        self.pet = pet
        screen = geometry.screen
        step = pet.mode == .notch ? .notchIntro : .floatingIntro
        captionStep = step
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pointerWindow = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        demoStart = CACurrentMediaTime() + 0.9
        alertFrom = CACurrentMediaTime() + 1.0
        // Opens from the whole screen down to the pet, as the dim fades in.
        let wide = screen.frame.insetBy(dx: -200, dy: -200)
        edges = [wide.minX, wide.minY, wide.maxX, wide.maxY].map {
            Spring(value: $0, target: $0, stiffness: 120, damping: 0.85 * 2 * sqrt(120))
        }
        super.init()

        // Both click-through: the user's real drag goes to the pet.
        for (panel, level) in [(window, NSWindow.Level.statusBar), (pointerWindow, Self.aboveThePet)] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = level
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.alphaValue = 0
        }
        for (panel, view) in [(window, container), (pointerWindow, pointerContainer)] {
            view.frame = CGRect(origin: .zero, size: screen.frame.size)
            view.wantsLayer = true
            panel.contentView = view
        }
        dim.frame = container.bounds
        dim.autoresizingMask = [.width, .height]
        container.addSubview(dim)
        pointerContainer.addSubview(ghost)
        pointerContainer.addSubview(cursor)
        ghost.isHidden = true
        cursor.isHidden = true

        captionPanel.contentView = caption
        captionPanel.alphaValue = 0
        caption.onSkip = { [weak self] in self?.skip() }
        caption.onUnderstood = { [weak self] in self?.understood() }
        caption.show(step)
    }

    func start() {
        window.setFrame(screen.frame, display: false)
        window.orderFrontRegardless()
        pointerWindow.setFrame(screen.frame, display: false)
        pointerWindow.orderFrontRegardless()
        layoutCaption(force: true)
        captionPanel.orderFrontRegardless()
        // Escape works while the app is active (it is, right after the onboarding window): a global
        // key monitor would need the Accessibility permission, and taking the keyboard would steal it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.finishing else { return event }
            switch event.keyCode {
            case 53: self.skip()
            case 36, 76: self.caption.pressUnderstood()
            default: return event
            }
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
        pet.setDemoAlert(false)
        finishing = true
        demoAlpha.target = 0
        fade.stiffness = 120
        fade.damping = 2 * sqrt(120)
        fade.target = 0
    }

    /// "J'ai compris" (or Return) on an explanation step: on to the gesture.
    func understood() {
        guard !finishing else { return }
        let now = CACurrentMediaTime()
        switch step {
        case .notchIntro: step = .dragOut
        case .floatingIntro: step = .dragIn
        default: return
        }
        pet.setDemoAlert(false)
        restartDemo(at: now + 0.7)
    }

    /// Tests: "Je n'ai pas compris".
    func confused() { caption.pressConfused() }

    // MARK: Following the real pet

    func petModeChanged(_ mode: PetController.Mode) {
        guard !finishing, step != .done else { return }
        let now = CACurrentMediaTime()
        switch (step, mode) {
        case (_, .dragging), (_, .flying):
            demoAlpha.target = 0
            pet.setDemoAlert(false)
        case (.notchIntro, .floating), (.dragOut, .floating):
            // Out of the notch: show what floating is for, once it has landed.
            step = .floatingIntro
            alertFrom = now + 0.6
        case (.floatingIntro, .notch), (.dragIn, .notch):
            step = .done
            doneAt = now
            demoAlpha.target = 0
            pet.setDemoAlert(false)
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

        // The demo's "Claude needs you", on explanation steps while the pet rests where they expect it.
        let alert = !finishing && now >= alertFrom
            && ((step == .notchIntro && pet.mode == .notch) || (step == .floatingIntro && pet.mode == .floating))
        if alert != pet.demoAlert { pet.setDemoAlert(alert) }

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
        pointerWindow.alphaValue = fade.value
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
        pet.setDemoAlert(false)
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window.orderOut(nil)
        pointerWindow.orderOut(nil)
        captionPanel.orderOut(nil)
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    // MARK: Spotlight

    private func spotlightTarget(_ path: DemoPath?) -> CGRect {
        var rect = pet.visibleFrame
        // The pill above the floating pet belongs with it.
        if let card = pet.alertCardFrame { rect = rect.union(card) }
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
        case .notchIntro, .floatingIntro, .done:
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
        if let pointerRep = pointerContainer.bitmapImageRepForCachingDisplay(in: pointerContainer.bounds),
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            pointerContainer.cacheDisplay(in: pointerContainer.bounds, to: pointerRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            pointerRep.draw(in: pointerContainer.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
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
        // Over the pet and its notch box too, like the cursor.
        level = TutorialOverlay.aboveThePet
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The tutorial's text. Gesture steps: a pill (step badge, the instruction in Claude's serif, a discreet
/// "Passer · esc"). Explanation steps: a bubble with a title, a short text and "Je n'ai pas compris" /
/// "J'ai compris"; the first one swaps the text for a longer, clearer one.
final class CaptionView: NSView {
    var onSkip: (() -> Void)?
    var onUnderstood: (() -> Void)?
    private var step = TutorialOverlay.Step.notchIntro
    /// "Je n'ai pas compris" was pressed: the longer explanation shows.
    private(set) var detailed = false
    private enum Hit { case skip, understood, confused }
    private var hovered: Hit? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Hit? { didSet { needsDisplay = true } }
    private static let pillHeight: CGFloat = 40
    private static let bubbleWidth: CGFloat = 380
    private static let pad: CGFloat = 20
    private static let buttonHeight: CGFloat = 30

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ step: TutorialOverlay.Step) {
        self.step = step
        detailed = false
        hovered = nil
        setFrameSize(fittingSize)
        needsDisplay = true
    }

    private var isBubble: Bool { step == .notchIntro || step == .floatingIntro }
    private var skippable: Bool { step != .done }

    private var badge: String? {
        switch step {
        case .notchIntro: return "1/4"
        case .dragOut: return "2/4"
        case .floatingIntro: return "3/4"
        case .dragIn: return "4/4"
        case .done: return nil
        }
    }

    private var title: String {
        switch step {
        case .notchIntro: return tr("Claude Pet vit dans ton encoche", "Claude Pet lives in your notch")
        case .dragOut: return tr("Attrape Claude Pet et sors-le de l'encoche", "Grab Claude Pet and pull it out of the notch")
        case .floatingIntro: return tr("Flottant, il te suit partout", "Floating, it goes anywhere")
        case .dragIn: return tr("Maintenant, ramène-le dans l'encoche", "Now drag it back into the notch")
        case .done: return tr("C'est tout !", "That's it!")
        }
    }

    private var body: String {
        switch (step, detailed) {
        case (.notchIntro, false):
            return tr("Son apparence te montre ce que fait Claude. Et quand Claude a besoin de toi, il te le fait savoir, comme ici.",
                      "Its look shows what Claude is doing. And when Claude needs you, it lets you know, like here.")
        case (.notchIntro, true):
            return tr("""
                Le pet change selon ce que fait Claude : il réfléchit, tape sur son ordinateur pendant les commandes et se réjouit quand une tâche est finie.

                Quand Claude attend ta réponse (une autorisation, une question), le bandeau « Claude a besoin de vous » sort sous l'encoche, comme maintenant. Passe la souris dessus : la demande s'ouvre, et tu réponds directement depuis le pet.
                """, """
                The pet changes with what Claude is doing: it thinks, types on its laptop while commands run, and cheers when a task is done.

                When Claude waits for your answer (a permission, a question), the "Claude needs you" banner slides out under the notch, like now. Hover it: the request opens and you answer right from the pet.
                """)
        case (.floatingIntro, false):
            return tr("Pose-le où tu veux sur l'écran. Quand Claude a besoin de toi, il te le fait savoir là aussi.",
                      "Put it anywhere on screen. When Claude needs you, it lets you know there too.")
        case (.floatingIntro, true):
            return tr("""
                Hors de l'encoche, le pet reste là où tu le poses : dans un coin, à côté de ta fenêtre, sur n'importe quel écran.

                Quand Claude attend ta réponse, une pastille « Claude a besoin de vous » apparaît au-dessus de lui, comme maintenant. Passe la souris sur le pet : la demande s'ouvre, et tu y réponds sans quitter ce que tu fais.
                """, """
                Out of the notch, the pet stays wherever you drop it: in a corner, next to your window, on any screen.

                When Claude waits for your answer, a "Claude needs you" pill appears above it, like now. Hover the pet: the request opens and you answer without leaving what you're doing.
                """)
        default:
            return ""
        }
    }

    // MARK: Pieces

    private func badgeText(_ theme: PanelTheme) -> NSAttributedString? {
        badge.map { $0.attributed(.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), theme.accent) }
    }

    private func skipText(_ theme: PanelTheme) -> (NSAttributedString, NSAttributedString) {
        (tr("Passer", "Skip").attributed(.systemFont(ofSize: 12, weight: .medium), hovered == .skip ? theme.text : theme.secondary),
         "esc".attributed(.systemFont(ofSize: 10, weight: .medium), theme.tertiary))
    }

    private func bodyText(_ theme: PanelTheme) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        return NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.secondary, .paragraphStyle: style,
        ])
    }

    private func titleText(_ theme: PanelTheme, size: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: title, attributes: [.font: NSFont.serif(size), .foregroundColor: theme.text, .paragraphStyle: style])
    }

    private func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: 2000), options: .usesLineFragmentOrigin).height)
    }

    private func buttonWidth(_ text: NSAttributedString) -> CGFloat { ceil(text.size().width) + 30 }

    // MARK: Layout

    private struct Bubble {
        var badge: CGRect?
        var skip: CGRect
        var title: CGRect
        var body: CGRect
        var understood: CGRect
        var confused: CGRect?
        var height: CGFloat
    }

    private func bubbleLayout(_ theme: PanelTheme) -> Bubble {
        let pad = Self.pad, inner = Self.bubbleWidth - 2 * pad
        var y = pad
        var badgeRect: CGRect?
        if let b = badgeText(theme) {
            let s = b.size()
            badgeRect = CGRect(x: pad, y: y, width: s.width + 14, height: s.height + 6)
        }
        let (skip, key) = skipText(theme)
        let skipWidth = skip.size().width + 7 + key.size().width + 10 + 20
        let skipRect = CGRect(x: Self.bubbleWidth - pad - skipWidth + 10, y: y - 4, width: skipWidth, height: 26)
        y += (badgeRect?.height ?? 18) + 10
        let t = titleText(theme, size: 19)
        let titleRect = CGRect(x: pad, y: y, width: inner, height: height(of: t, width: inner))
        y = titleRect.maxY + 6
        let bodyRect = CGRect(x: pad, y: y, width: inner, height: height(of: bodyText(theme), width: inner))
        y = bodyRect.maxY + 18
        let understood = buttonWidth(tr("J'ai compris", "Got it").attributed(.systemFont(ofSize: 12.5, weight: .semibold), theme.text))
        let understoodRect = CGRect(x: Self.bubbleWidth - pad - understood, y: y, width: understood, height: Self.buttonHeight)
        var confusedRect: CGRect?
        if !detailed {
            let w = buttonWidth(tr("Je n'ai pas compris", "I don't get it").attributed(.systemFont(ofSize: 12.5, weight: .medium), theme.text))
            confusedRect = CGRect(x: understoodRect.minX - 8 - w, y: y, width: w, height: Self.buttonHeight)
        }
        return Bubble(badge: badgeRect, skip: skipRect, title: titleRect, body: bodyRect, understood: understoodRect,
                      confused: confusedRect, height: understoodRect.maxY + pad)
    }

    /// Pill: x of each part, and the total width.
    private func pillLayout(_ theme: PanelTheme) -> (badge: CGFloat, title: CGFloat, divider: CGFloat, skip: CGFloat, key: CGFloat, width: CGFloat) {
        var x: CGFloat = 16
        let badgeX = x
        if let b = badgeText(theme) { x += b.size().width + 14 + 10 }
        if step == .done { x += 22 }
        let titleX = x
        x += titleText(theme, size: 15).size().width
        guard skippable else { return (badgeX, titleX, 0, 0, 0, x + 18) }
        let (skip, key) = skipText(theme)
        x += 16
        let dividerX = x
        x += 1 + 14
        let skipX = x
        x += skip.size().width + 7
        let keyX = x
        x += key.size().width + 10 + 14
        return (badgeX, titleX, dividerX, skipX, keyX, x)
    }

    override var fittingSize: NSSize {
        let theme = PanelTheme.current(effectiveAppearance)
        if isBubble { return NSSize(width: Self.bubbleWidth, height: bubbleLayout(theme).height) }
        return NSSize(width: ceil(pillLayout(theme).width), height: Self.pillHeight)
    }

    private func hit(at point: CGPoint) -> Hit? {
        let theme = PanelTheme.current(effectiveAppearance)
        if isBubble {
            let b = bubbleLayout(theme)
            if b.understood.contains(point) { return .understood }
            if let c = b.confused, c.contains(point) { return .confused }
            if b.skip.contains(point) { return .skip }
            return nil
        }
        let l = pillLayout(theme)
        return skippable && point.x >= l.divider ? .skip : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let radius = isBubble ? 18 : Self.pillHeight / 2
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        theme.background.setFill()
        shape.fill()
        theme.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        isBubble ? drawBubble(theme) : drawPill(theme)
    }

    private func drawBadge(_ theme: PanelTheme, in capsule: CGRect) {
        guard let b = badgeText(theme) else { return }
        theme.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        b.draw(at: CGPoint(x: capsule.minX + 7, y: capsule.minY + 3))
    }

    /// "Passer" and its esc key cap, from `x`, centered on `mid`.
    private func drawSkip(_ theme: PanelTheme, x: CGFloat, mid: CGFloat) {
        let (skip, key) = skipText(theme)
        let skipSize = skip.size(), keySize = key.size()
        skip.draw(at: CGPoint(x: x, y: mid - skipSize.height / 2))
        let cap = CGRect(x: x + skipSize.width + 7, y: mid - keySize.height / 2 - 1.5, width: keySize.width + 10, height: keySize.height + 3)
        let capPath = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        theme.tertiary.withAlphaComponent(0.5).setStroke()
        capPath.lineWidth = 1
        capPath.stroke()
        key.draw(at: CGPoint(x: cap.minX + 5, y: cap.minY + 1.5))
    }

    private func drawHoverPlate(_ theme: PanelTheme, _ rect: CGRect, _ hit: Hit) {
        guard hovered == hit || pressed == hit else { return }
        theme.text.withAlphaComponent(pressed == hit ? 0.09 : 0.05).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private func drawBubble(_ theme: PanelTheme) {
        let b = bubbleLayout(theme)
        if let badge = b.badge { drawBadge(theme, in: badge) }
        drawHoverPlate(theme, b.skip, .skip)
        drawSkip(theme, x: b.skip.minX + 10, mid: b.skip.midY)
        titleText(theme, size: 19).draw(with: b.title, options: .usesLineFragmentOrigin)
        bodyText(theme).draw(with: b.body, options: .usesLineFragmentOrigin)

        if let confused = b.confused {
            let lift: CGFloat = pressed == .confused ? 0.14 : hovered == .confused ? 0.11 : 0.07
            theme.text.withAlphaComponent(lift).setFill()
            NSBezierPath(roundedRect: confused, xRadius: confused.height / 2, yRadius: confused.height / 2).fill()
            let text = tr("Je n'ai pas compris", "I don't get it").attributed(.systemFont(ofSize: 12.5, weight: .medium), theme.text)
            let s = text.size()
            text.draw(at: CGPoint(x: confused.midX - s.width / 2, y: confused.midY - s.height / 2))
        }
        let lift: CGFloat = pressed == .understood ? 0.08 : hovered == .understood ? 0.14 : 0
        (theme.accent.blended(withFraction: lift, of: .white) ?? theme.accent).setFill()
        NSBezierPath(roundedRect: b.understood, xRadius: b.understood.height / 2, yRadius: b.understood.height / 2).fill()
        let text = tr("J'ai compris", "Got it").attributed(.systemFont(ofSize: 12.5, weight: .semibold), NSColor(white: 0.08, alpha: 1))
        let s = text.size()
        text.draw(at: CGPoint(x: b.understood.midX - s.width / 2, y: b.understood.midY - s.height / 2))
    }

    private func drawPill(_ theme: PanelTheme) {
        let l = pillLayout(theme)
        let mid = bounds.height / 2
        if let b = badgeText(theme) {
            let size = b.size()
            drawBadge(theme, in: CGRect(x: l.badge, y: mid - size.height / 2 - 3, width: size.width + 14, height: size.height + 6))
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
        let title = titleText(theme, size: 15)
        title.draw(at: CGPoint(x: l.title, y: mid - title.size().height / 2))

        guard skippable else { return }
        theme.stroke.setFill()
        CGRect(x: l.divider, y: mid - 8, width: 1, height: 16).fill()
        drawHoverPlate(theme, CGRect(x: l.divider + 6, y: 5, width: bounds.width - l.divider - 11, height: bounds.height - 10), .skip)
        drawSkip(theme, x: l.skip, mid: mid)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    private func local(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) { hovered = hit(at: local(event)) }
    override func mouseEntered(with event: NSEvent) { hovered = hit(at: local(event)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) { pressed = hit(at: local(event)) }
    override func mouseUp(with event: NSEvent) {
        let target = hit(at: local(event))
        let fire = pressed != nil && pressed == target ? target : nil
        pressed = nil
        guard let fire else { return }
        perform(fire)
    }

    private func perform(_ hit: Hit) {
        switch hit {
        case .skip: if skippable { onSkip?() }
        case .understood: onUnderstood?()
        case .confused:
            detailed = true
            hovered = nil
            // The bubble grows downward from where it is: the overlay re-places it on the next frame.
            setFrameSize(fittingSize)
            needsDisplay = true
        }
    }

    /// Tests and keys: the buttons by name.
    func pressSkip() { perform(.skip) }
    func pressUnderstood() { if isBubble { perform(.understood) } }
    func pressConfused() { if isBubble, !detailed { perform(.confused) } }
}

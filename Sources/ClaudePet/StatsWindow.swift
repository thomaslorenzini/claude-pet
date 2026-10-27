import AppKit

/// The statistics window: tokens used in Claude Code per period, model and token type, as charts
/// ("Charts") or as a summary with a calendar heatmap ("Overview"). Opened from the menu bar panel.
/// A regular titled window drawn by hand with `PanelTheme`, like the settings.
final class StatsWindow: NSWindow {
    var onPage: ((Int) -> Void)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 800),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: true)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = tr("Statistiques de Claude Pet", "Claude Pet Statistics")
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 980, height: 760)
        backgroundColor = NSColor(name: nil) { PanelTheme.current($0).background }
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        setFrameAutosaveName("ClaudePetStats")
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // No main menu in an accessory app: the usual shortcuts are handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "w": close()
        case "q": NSApp.terminate(nil)
        case "m": miniaturize(nil)
        case "1": onPage?(0)
        case "2": onPage?(1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class StatsController: NSObject, NSWindowDelegate {
    let window = StatsWindow()
    let view = StatsView()
    private let ledger: TokenLedger
    private var liveTimer: Timer?
    private var animationTimer: Timer?
    private var placed = false
    private var shownCount = -1
    var isOpen: Bool { window.isVisible }

    init(ledger: TokenLedger) {
        self.ledger = ledger
        super.init()
        window.contentView = view
        window.delegate = self
        window.onPage = { [weak self] in self?.view.setPage($0) }
        view.onChange = { [weak self] in self?.recompute(animated: true) }
    }

    func open() {
        if !placed {
            placed = true
            if window.frame.origin == .zero { window.center() }
        }
        recompute(animated: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reload(animated: true)
        // New responses show up while the window is open: an incremental read only costs the new lines.
        liveTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.reload(animated: true) }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        ledger.flush()
        liveTimer?.invalidate()
        liveTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        DispatchQueue.main.async { NSApp.deactivate() }
    }

    private func reload(animated: Bool) {
        view.loading = !ledger.isLoaded
        ledger.refresh { [weak self] in
            guard let self else { return }
            self.view.loading = false
            // Unchanged: no new summary, no animation.
            let count = self.ledger.entries.count
            guard count != self.shownCount else { return }
            self.recompute(animated: animated && self.shownCount >= 0)
        }
    }

    /// A new summary for the current choices, morphing from what is on screen.
    func recompute(animated: Bool) {
        let entries = ledger.entries
        shownCount = ledger.isLoaded ? entries.count : -1
        // Model colors follow the all-time ranking, so a filter never repaints them.
        var totals: [String: Int] = [:]
        for e in entries { totals[e.model, default: 0] += e.input + e.output + e.cacheWrite + e.cacheRead }
        let ranked = totals.sorted { $0.value > $1.value }.map(\.key)
        view.allModels = ranked.map { (id: $0, tokens: totals[$0]!) }
        view.modelColors = Dictionary(uniqueKeysWithValues: ranked.enumerated().map {
            ($1, PanelTheme.hex(StatsFormat.modelPalette[min($0, StatsFormat.modelPalette.count - 1)]))
        })
        view.ledgerInfo = (entries.count, entries.first?.time)
        view.show(StatsSummary(entries: entries, query: view.query), animated: animated && window.isVisible)
        if animated && window.isVisible { animate() }
    }

    private func animate() {
        guard animationTimer == nil else { return }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, CGFloat((CACurrentMediaTime() - start) / 0.55))
            self.view.setProgress(t)
            if t >= 1 {
                timer.invalidate()
                self.animationTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func snapshot(to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Animation state shared by the cards

/// What every card draws from: the summary before and after a change, and how far along the morph is.
struct StatsFrame {
    var from = StatsSummary()
    var to = StatsSummary()
    var t: CGFloat = 1
    var colors: [String: NSColor] = [:]
    var byModel = false

    var eased: Double { Double(1 - pow(1 - t, 3)) }
    func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * eased }
    func mix(_ a: Int, _ b: Int) -> Double { mix(Double(a), Double(b)) }

    func color(_ model: String) -> NSColor { colors[model] ?? PanelTheme.hex(0x8F8D85) }
}

// MARK: - Root view

final class StatsView: NSView {
    var query = StatsQuery()
    var onChange: (() -> Void)?
    var allModels: [(id: String, tokens: Int)] = [] { didSet { applyControls() } }
    var modelColors: [String: NSColor] = [:]
    var ledgerInfo: (count: Int, first: Date?) = (0, nil) { didSet { needsDisplay = true } }
    var loading = false { didSet { if oldValue != loading { needsDisplay = true; pages.forEach { $0.needsDisplay = true } } } }
    private(set) var page = 0
    private var frame_ = StatsFrame()
    private var growNext = false

    private let pagePicker = SegmentedPicker(options: [tr("Graphiques", "Charts"), tr("Aperçu", "Overview")])
    private let periodPicker = SegmentedPicker(options: StatsPeriod.allCases.map(\.title))
    private let modelPill = MenuPill()
    private let chips = TokenKind.allCases.map { KindChip(kind: $0) }
    let charts = StatsChartsPage()
    let overview = StatsOverviewPage()
    private var pages: [StatsPage] { [charts, overview] }

    static let pad: CGFloat = 28
    private static let headerHeight: CGFloat = 136

    override init(frame: NSRect) {
        super.init(frame: frame)
        [pagePicker, periodPicker, modelPill].forEach(addSubview)
        chips.forEach(addSubview)
        pages.forEach(addSubview)
        periodPicker.selected = query.period.rawValue
        pagePicker.onSelect = { [weak self] in self?.setPage($0) }
        periodPicker.onSelect = { [weak self] in
            guard let self, let period = StatsPeriod(rawValue: $0) else { return }
            self.query.period = period
            self.onChange?()
        }
        for chip in chips {
            chip.onClick = { [weak self] in self?.toggle(chip.kind) }
        }
        modelPill.onClick = { [weak self] in self?.showModelMenu() }
        charts.onToggleKind = { [weak self] in self?.toggle($0) }
        charts.onByModel = { [weak self] in
            guard let self else { return }
            self.frame_.byModel = $0
            // The bands change identity: they grow again from the baseline.
            self.growNext = true
            self.onChange?()
        }
        overview.isHidden = true
        applyControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func setPage(_ index: Int) {
        guard index != page || pagePicker.selected != index else { return }
        page = index
        pagePicker.selected = index
        charts.isHidden = index != 0
        overview.isHidden = index != 1
        // The page that appears grows its marks from nothing.
        growNext = true
        onChange?()
    }

    private func toggle(_ kind: TokenKind) {
        if query.kinds.contains(kind) {
            // At least one type stays counted.
            guard query.kinds.count > 1 else { return NSSound.beep() }
            query.kinds.remove(kind)
        } else {
            query.kinds.insert(kind)
        }
        applyControls()
        onChange?()
    }

    func show(_ summary: StatsSummary, animated: Bool) {
        if animated {
            frame_.from = growNext ? StatsSummary() : current()
            growNext = false
            frame_.t = 0
        } else {
            frame_.t = 1
        }
        frame_.to = summary
        frame_.colors = modelColors
        pushFrame()
        applyControls()
        needsDisplay = true
    }

    /// The summary as drawn right now, mid-morph included, approximated by the closer end.
    private func current() -> StatsSummary {
        frame_.t < 0.5 && frame_.from.hasData ? frame_.from : frame_.to
    }

    func setProgress(_ t: CGFloat) {
        frame_.t = t
        pushFrame()
    }

    private func pushFrame() {
        for page in pages where !page.isHidden { page.frameData = frame_ }
    }

    private func applyControls() {
        periodPicker.selected = query.period.rawValue
        for chip in chips { chip.isOn = query.kinds.contains(chip.kind) }
        if let models = query.models {
            let names = allModels.map(\.id).filter(models.contains).map(StatsFormat.model)
            modelPill.title = names.count > 1 ? "\(names[0]) + \(names.count - 1)" : names.first ?? ""
            modelPill.colors = allModels.map(\.id).filter(models.contains).compactMap { modelColors[$0] }
        } else {
            modelPill.title = tr("Tous les modèles", "All models")
            modelPill.colors = allModels.prefix(4).compactMap { modelColors[$0.id] }
        }
        charts.kinds = query.kinds
        needsLayout = true
    }

    // MARK: Model menu

    private func showModelMenu() {
        let menu = NSMenu()
        let all = ClosureMenuItem(title: tr("Tous les modèles", "All models"), key: "") { [weak self] in self?.pickModel(nil) }
        all.state = query.models == nil ? .on : .off
        menu.addItem(all)
        menu.addItem(.separator())
        for model in allModels {
            let item = ClosureMenuItem(title: StatsFormat.model(model.id), key: "") { [weak self] in self?.pickModel(model.id) }
            item.state = query.models?.contains(model.id) == true ? .on : .off
            item.image = Self.dot(modelColors[model.id] ?? .gray)
            let detail = "  " + StatsFormat.compact(Double(model.tokens))
            let title = NSMutableAttributedString(string: StatsFormat.model(model.id), attributes: [.font: NSFont.menuFont(ofSize: 13)])
            title.append(NSAttributedString(string: detail, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            item.toolTip = model.id
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: modelPill.bounds.height + 4), in: modelPill)
    }

    /// From "all", a model alone; then each pick adds or removes one. Nothing left means all again.
    func pickModel(_ id: String?) {
        guard let id else {
            query.models = nil
            applyControls()
            onChange?()
            return
        }
        var set = query.models ?? []
        if query.models == nil { set = [id] } else if set.contains(id) { set.remove(id) } else { set.insert(id) }
        query.models = set.isEmpty || set.count == allModels.count ? nil : set
        applyControls()
        onChange?()
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        let pad = Self.pad
        let pageSize = pagePicker.fittingSize
        pagePicker.frame = CGRect(x: bounds.width - pad - pageSize.width, y: 42, width: pageSize.width, height: pageSize.height)
        let periodSize = periodPicker.fittingSize
        periodPicker.frame = CGRect(x: pad, y: 92, width: periodSize.width, height: periodSize.height)
        var x = bounds.width - pad
        for chip in chips.reversed() {
            let size = chip.fittingSize
            x -= size.width
            chip.frame = CGRect(x: x, y: 93, width: size.width, height: size.height)
            x -= 8
        }
        let pill = modelPill.fittingSize
        modelPill.frame = CGRect(x: x - 8 - pill.width, y: 93, width: pill.width, height: pill.height)
        let content = CGRect(x: pad, y: Self.headerHeight, width: bounds.width - 2 * pad, height: bounds.height - Self.headerHeight - 24)
        pages.forEach { $0.frame = content }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        theme.background.setFill()
        bounds.fill()
        let pad = Self.pad
        tr("Statistiques", "Statistics").attributed(.serif(28, weight: .medium), theme.text)
            .draw(at: CGPoint(x: pad, y: 34), width: 400)
        var info = "Claude Code · "
        if loading && ledgerInfo.count == 0 {
            info += tr("lecture des transcripts…", "reading transcripts…")
        } else {
            info += StatsFormat.full(ledgerInfo.count) + " " + tr(ledgerInfo.count > 1 ? "réponses" : "réponse", ledgerInfo.count == 1 ? "response" : "responses")
            if let first = ledgerInfo.first {
                info += tr(" depuis le ", " since ") + StatsFormat.date(first, "d MMMM yyyy")
            }
        }
        info.attributed(.systemFont(ofSize: 12), theme.tertiary).draw(at: CGPoint(x: pad + 1, y: 70), width: 600)
    }

    /// Tests: the controls by name.
    func press(_ name: String) {
        switch name {
        case "charts": setPage(0)
        case "overview": setPage(1)
        case "by_model": charts.setByModel(true)
        case "by_type": charts.setByModel(false)
        case "models:all": pickModel(nil)
        default:
            if let period = ["today", "week", "month", "all"].firstIndex(of: name) {
                periodPicker.selected = period
                periodPicker.onSelect?(period)
            } else if name.hasPrefix("kind:"), let i = Int(name.dropFirst(5)), let kind = TokenKind(rawValue: i) {
                toggle(kind)
            } else if name.hasPrefix("model:") {
                pickModel(String(name.dropFirst(6)))
            }
        }
    }

    /// Tests: a hover at a point of the window's content (top-left origin), as the mouse would.
    func hover(at point: CGPoint?) {
        for page in pages where !page.isHidden {
            for card in page.subviews.compactMap({ $0 as? StatsCard }) {
                let local = point.map { card.convert($0, from: self) }
                card.hover = local.flatMap { card.bounds.contains($0) ? $0 : nil }
            }
        }
    }
}

/// A page of cards; lays them out from its own bounds.
class StatsPage: NSView {
    var frameData = StatsFrame() {
        didSet {
            subviews.compactMap { $0 as? StatsCard }.forEach { $0.frameData = frameData }
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }
}

// MARK: - Controls

/// Segments in a recessed track, the selected one on a raised knob that springs across.
final class SegmentedPicker: NSView {
    var options: [String] { didSet { needsLayout = true; needsDisplay = true } }
    var selected = 0 {
        didSet {
            guard oldValue != selected else { return }
            moveKnob(animated: window?.isVisible == true)
        }
    }
    var compact = false
    var onSelect: ((Int) -> Void)?
    private var knobX = Spring(value: 0, target: 0, stiffness: 420, damping: 34)
    private var knobW = Spring(value: 0, target: 0, stiffness: 420, damping: 34)
    private var placed = false
    private var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var timer: Timer?

    init(options: [String]) {
        self.options = options
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var font: NSFont { .systemFont(ofSize: compact ? 11.5 : 12.5, weight: .medium) }
    private var widths: [CGFloat] {
        options.map { ceil($0.attributed(font, .black).size().width) + (compact ? 22 : 30) }
    }
    override var fittingSize: NSSize { NSSize(width: widths.reduce(0, +) + 6, height: compact ? 26 : 32) }

    private func rect(_ i: Int) -> CGRect {
        let w = widths
        let x = 3 + w.prefix(i).reduce(0, +)
        return CGRect(x: x, y: 3, width: w[i], height: bounds.height - 6)
    }

    private func moveKnob(animated: Bool) {
        guard selected < options.count, bounds.width > 0 else { return }
        let r = rect(selected)
        knobX.target = r.minX
        knobW.target = r.width
        if !animated || !placed {
            knobX.snap(to: r.minX)
            knobW.snap(to: r.width)
            placed = true
            needsDisplay = true
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.knobX.step(1 / 60)
            self.knobW.step(1 / 60)
            self.needsDisplay = true
            if self.knobX.isSettled, self.knobW.isSettled {
                timer.invalidate()
                self.timer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func layout() {
        super.layout()
        if !placed || timer == nil { placed = false; moveKnob(animated: false) }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return options.indices.first { rect($0).insetBy(dx: 0, dy: -3).contains(p) }
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
        guard let i = index(at: event), i != selected else { return }
        selected = i
        onSelect?(i)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let dark = theme.background == PanelTheme.dark.background
        let radius = bounds.height / 2
        theme.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let knob = CGRect(x: knobX.value, y: 3, width: knobW.value, height: bounds.height - 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.14)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        (dark ? PanelTheme.hex(0x484743) : NSColor.white).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.height / 2, yRadius: knob.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        for (i, option) in options.enumerated() {
            let r = rect(i)
            let color = i == selected ? theme.text : i == hovered ? theme.text.withAlphaComponent(0.8) : theme.secondary
            let label = option.attributed(font, color)
            let size = label.size()
            label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2 - 0.5))
        }
    }
}

/// A token type that counts or not: tinted with its color when on, outlined when off.
final class KindChip: NSView {
    let kind: TokenKind
    var isOn = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    init(kind: TokenKind) {
        self.kind = kind
        super.init(frame: .zero)
        toolTip = tr("Compter ou non ce type de tokens", "Count this token type or not")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var fittingSize: NSSize {
        NSSize(width: ceil(kind.title.attributed(Self.font, .black).size().width) + 36, height: 30)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isOn {
            kind.color.withAlphaComponent(hovered ? 0.24 : 0.16).setFill()
            shape.fill()
        } else {
            (hovered ? theme.text.withAlphaComponent(0.05) : .clear).setFill()
            shape.fill()
            theme.text.withAlphaComponent(0.14).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let dot = CGRect(x: 12, y: bounds.midY - 4, width: 8, height: 8)
        if isOn {
            kind.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        } else {
            kind.color.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let label = kind.title.attributed(Self.font, isOn ? theme.text : theme.tertiary)
        label.draw(at: CGPoint(x: dot.maxX + 7, y: (bounds.height - label.size().height) / 2 - 0.5))
    }
}

/// The model filter: its color dots and name, a chevron, a menu on click.
final class MenuPill: NSView {
    var title = "" { didSet { needsDisplay = true; superview?.needsLayout = true } }
    var colors: [NSColor] = [] { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var dotsWidth: CGFloat { colors.isEmpty ? 0 : 8 + CGFloat(colors.count - 1) * 5 + 8 }
    override var fittingSize: NSSize {
        NSSize(width: ceil(title.attributed(Self.font, .black).size().width) + 14 + dotsWidth + 28, height: 30)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        theme.card.setFill()
        shape.fill()
        if hovered {
            theme.text.withAlphaComponent(0.05).setFill()
            shape.fill()
        }
        theme.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // Overlapping dots, like avatars.
        var x: CGFloat = 13
        for color in colors {
            let dot = CGRect(x: x, y: bounds.midY - 4, width: 8, height: 8)
            theme.card.setStroke()
            let path = NSBezierPath(ovalIn: dot)
            path.lineWidth = 2
            path.stroke()
            color.setFill()
            path.fill()
            x += 5
        }
        let textX = 14 + dotsWidth
        let label = title.attributed(Self.font, theme.text)
        label.draw(at: CGPoint(x: textX, y: (bounds.height - label.size().height) / 2 - 0.5))
        // Chevron.
        let c = CGPoint(x: bounds.width - 15, y: bounds.midY + 0.5)
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: c.x - 3.5, y: c.y - 2))
        chevron.line(to: CGPoint(x: c.x, y: c.y + 1.5))
        chevron.line(to: CGPoint(x: c.x + 3.5, y: c.y - 2))
        chevron.lineWidth = 1.5
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        theme.secondary.setStroke()
        chevron.stroke()
    }
}

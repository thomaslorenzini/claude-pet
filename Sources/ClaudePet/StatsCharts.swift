import AppKit

/// The statistics window's cards and charts, all drawn in `draw(_:)` from a `StatsFrame` (the summary
/// before and after a change, and the morph between them).

// MARK: - Card

class StatsCard: NSView {
    var frameData = StatsFrame() { didSet { needsDisplay = true } }
    var hover: CGPoint? { didSet { if oldValue != hover { needsDisplay = true } } }
    var title = ""
    var subtitle = ""
    var drawsBackground = true

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { hover = nil }

    var f: StatsFrame { frameData }
    var summary: StatsSummary { frameData.to }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        if drawsBackground {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
            theme.card.setFill()
            shape.fill()
            theme.stroke.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        if !title.isEmpty {
            title.attributed(.serif(17, weight: .medium), theme.text).draw(at: CGPoint(x: 20, y: 16), width: bounds.width - 40)
            headerSubtitle.attributed(.systemFont(ofSize: 11.5), theme.tertiary).draw(at: CGPoint(x: 20, y: 40), width: bounds.width - 40)
        }
        drawContent(theme)
    }

    /// Under the title; cards whose subtitle follows the data override it.
    var headerSubtitle: String { subtitle }

    func drawContent(_ theme: PanelTheme) {}

    /// A list of values that morphs element by element, or grows from zero when its shape changed.
    func morph(_ a: [Double], _ b: [Double]) -> [Double] {
        a.count == b.count ? zip(a, b).map { f.mix($0, $1) } : b.map { $0 * f.eased }
    }

    func centered(_ text: NSAttributedString, in rect: CGRect) {
        let size = text.size()
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    func empty(_ theme: PanelTheme, in rect: CGRect, _ text: String = tr("Aucune activité sur cette période", "No activity in this period")) {
        centered(text.attributed(.systemFont(ofSize: 12.5), theme.tertiary), in: rect)
    }

    /// A floating label near `anchor`, kept inside the card: a title, then colored rows.
    func tooltip(at anchor: CGPoint, title: String, rows: [(color: NSColor?, label: String, value: String)],
                 footer: String? = nil, theme: PanelTheme) {
        let dark = theme.background == PanelTheme.dark.background
        let titleText = title.attributed(.systemFont(ofSize: 11.5, weight: .semibold), theme.text)
        let labels = rows.map { $0.label.attributed(.systemFont(ofSize: 11.5), theme.secondary) }
        let values = rows.map { $0.value.attributed(.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), theme.text) }
        let footerText = footer?.attributed(.systemFont(ofSize: 11), theme.tertiary)
        let labelWidth = labels.map { $0.size().width }.max() ?? 0
        let valueWidth = values.map { $0.size().width }.max() ?? 0
        let width = ceil(max(titleText.size().width, 14 + labelWidth + 18 + valueWidth, footerText?.size().width ?? 0)) + 24
        let height = CGFloat(30 + rows.count * 19 + (footerText == nil ? 0 : 20)) + 4
        var x = anchor.x + 16
        if x + width > bounds.width - 8 { x = anchor.x - 16 - width }
        let y = min(max(8, anchor.y - height / 2), bounds.height - height - 8)
        let rect = CGRect(x: max(8, x), y: y, width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.16)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowBlurRadius = 12
        shadow.set()
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        (dark ? PanelTheme.hex(0x1C1C1A) : NSColor.white).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        theme.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        titleText.draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + 9), width: rect.width - 24)
        var rowY = rect.minY + 32
        for (i, row) in rows.enumerated() {
            var labelX = rect.minX + 12
            if let color = row.color {
                color.setFill()
                NSBezierPath(roundedRect: CGRect(x: labelX, y: rowY + 4, width: 8, height: 8), xRadius: 2.5, yRadius: 2.5).fill()
                labelX += 14
            }
            labels[i].draw(at: CGPoint(x: labelX, y: rowY))
            values[i].draw(at: CGPoint(x: rect.maxX - 12 - values[i].size().width, y: rowY))
            rowY += 19
        }
        if let footerText {
            theme.stroke.setFill()
            CGRect(x: rect.minX + 12, y: rowY + 3, width: rect.width - 24, height: 1).fill()
            footerText.draw(at: CGPoint(x: rect.minX + 12, y: rowY + 7))
        }
    }
}

// MARK: - Paths

enum ChartPath {
    /// A smooth curve through `points` that never overshoots them (monotone cubic, Fritsch–Carlson):
    /// a stacked band never dips below the one under it.
    static func add(_ points: [CGPoint], to path: NSBezierPath, move: Bool) {
        guard let first = points.first else { return }
        if move { path.move(to: first) } else { path.line(to: first) }
        let n = points.count
        guard n > 1 else { return }
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<n - 1 {
            let h = points[i + 1].x - points[i].x
            d[i] = h == 0 ? 0 : (points[i + 1].y - points[i].y) / h
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for i in 1..<n - 1 { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        }
        for i in 0..<n - 1 {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 {
                let t = 3 / sqrt(s)
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        for i in 0..<n - 1 {
            let h = points[i + 1].x - points[i].x
            path.curve(to: points[i + 1],
                       controlPoint1: CGPoint(x: points[i].x + h / 3, y: points[i].y + m[i] * h / 3),
                       controlPoint2: CGPoint(x: points[i + 1].x - h / 3, y: points[i + 1].y - m[i + 1] * h / 3))
        }
    }

    static func fillGradient(_ path: NSBezierPath, color: NSColor, top: CGFloat, bottom: CGFloat, alphas: (CGFloat, CGFloat)) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [color.withAlphaComponent(alphas.0).cgColor, color.withAlphaComponent(alphas.1).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        ctx.saveGState()
        path.addClip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// 1, 2, 2.5 or 5 times a power of ten, at least `value`.
    static func niceCeil(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let power = pow(10, floor(log10(value)))
        for step in [1, 2, 2.5, 5, 10] where step * power >= value { return step * power }
        return 10 * power
    }

    static func sparkline(_ values: [Double], in rect: CGRect, color: NSColor, maxValue: Double? = nil) {
        guard values.count > 0 else { return }
        let top = max(maxValue ?? values.max() ?? 0, 1)
        let pts: [CGPoint] = values.count == 1
            ? [CGPoint(x: rect.minX, y: rect.maxY - rect.height * CGFloat(values[0] / top)),
               CGPoint(x: rect.maxX, y: rect.maxY - rect.height * CGFloat(values[0] / top))]
            : values.enumerated().map { i, v in
                CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1), y: rect.maxY - rect.height * CGFloat(v / top))
            }
        let area = NSBezierPath()
        area.move(to: CGPoint(x: pts[0].x, y: rect.maxY))
        add(pts, to: area, move: false)
        area.line(to: CGPoint(x: pts.last!.x, y: rect.maxY))
        area.close()
        fillGradient(area, color: color, top: rect.minY, bottom: rect.maxY, alphas: (0.32, 0))
        let line = NSBezierPath()
        add(pts, to: line, move: true)
        line.lineWidth = 1.6
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()
    }
}

// MARK: - Charts page

final class StatsChartsPage: StatsPage {
    var kinds = Set(TokenKind.allCases) { didSet { kpis.forEach { $0.isOn = $0.kind.map(kinds.contains) ?? true } } }
    var onToggleKind: ((TokenKind) -> Void)?
    var onByModel: ((Bool) -> Void)?
    private(set) var byModel = false
    private let kpis = [KpiCard(kind: nil)] + TokenKind.allCases.map { KpiCard(kind: $0) }
    private let timeline = TimelineCard()
    private let models = ModelsCard()
    private let hours = HoursCard()
    private let projects = ProjectsCard()

    override init(frame: NSRect) {
        super.init(frame: frame)
        kpis.forEach(addSubview)
        [timeline, models, hours, projects].forEach(addSubview)
        for card in kpis {
            card.onClick = { [weak self] in if let kind = card.kind { self?.onToggleKind?(kind) } }
        }
        timeline.picker.onSelect = { [weak self] in
            self?.byModel = $0 == 1
            self?.onByModel?($0 == 1)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setByModel(_ on: Bool) {
        timeline.picker.selected = on ? 1 : 0
        byModel = on
        onByModel?(on)
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 14, kpiHeight: CGFloat = 128, bottomHeight: CGFloat = 248
        // The total is half again as wide as a type.
        let unit = (bounds.width - 4 * gap) / 5.5
        var x: CGFloat = 0
        for (i, card) in kpis.enumerated() {
            let w = i == 0 ? unit * 1.5 : unit
            card.frame = CGRect(x: x, y: 0, width: w, height: kpiHeight)
            x += w + gap
        }
        let timelineHeight = max(220, bounds.height - kpiHeight - bottomHeight - 2 * gap)
        timeline.frame = CGRect(x: 0, y: kpiHeight + gap, width: bounds.width, height: timelineHeight)
        let y = timeline.frame.maxY + gap
        let third = (bounds.width - 2 * gap) / 3
        models.frame = CGRect(x: 0, y: y, width: third * 1.15, height: bottomHeight)
        hours.frame = CGRect(x: models.frame.maxX + gap, y: y, width: third * 0.95, height: bottomHeight)
        projects.frame = CGRect(x: hours.frame.maxX + gap, y: y, width: bounds.width - hours.frame.maxX - gap, height: bottomHeight)
    }
}

/// The total, or one token type: its number, its share, a sparkline. A type's card toggles it.
final class KpiCard: StatsCard {
    let kind: TokenKind?
    var isOn = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(kind: TokenKind?) {
        self.kind = kind
        super.init(frame: .zero)
        if let kind { toolTip = kind.detail + " · " + tr("cliquer pour compter ou non ce type", "click to count this type or not") }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { if kind != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func series(_ s: StatsSummary) -> [Double] {
        s.buckets.map { b in
            if let kind { return b.kinds[kind.rawValue] }
            return s.query.kinds.reduce(0) { $0 + b.kinds[$1.rawValue] }
        }
    }

    override func drawContent(_ theme: PanelTheme) {
        let alpha: CGFloat = isOn ? 1 : 0.42
        let hovered = hover != nil && kind != nil
        if hovered {
            theme.text.withAlphaComponent(0.03).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15).fill()
        }
        let color = kind?.color ?? theme.accent
        let label = kind?.title ?? tr("Total", "Total")
        var x: CGFloat = 18
        if kind != nil {
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: 20, width: 9, height: 9), xRadius: 3, yRadius: 3).fill()
            x += 16
        }
        label.attributed(.systemFont(ofSize: 12.5, weight: .medium), theme.secondary.withAlphaComponent(alpha))
            .draw(at: CGPoint(x: x, y: 16), width: bounds.width - x - 40)

        // The type's switch: a filled check when counted, an empty ring when not.
        if kind != nil {
            let box = CGRect(x: bounds.width - 32, y: 15, width: 16, height: 16)
            if isOn {
                color.setFill()
                NSBezierPath(ovalIn: box).fill()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: box.minX + 4.5, y: box.midY + 0.5))
                check.line(to: CGPoint(x: box.minX + 7, y: box.midY + 3))
                check.line(to: CGPoint(x: box.maxX - 4, y: box.midY - 2.5))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                theme.text.withAlphaComponent(hovered ? 0.4 : 0.22).setStroke()
                let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }

        let value: Double, all = f.mix(f.from.kindTotals.reduce(0, +), f.to.kindTotals.reduce(0, +))
        if let kind {
            value = f.mix(f.from.kindTotals[kind.rawValue], f.to.kindTotals[kind.rawValue])
        } else {
            value = f.mix(f.from.total, f.to.total)
        }
        let big = StatsFormat.compact(value).attributed(.serif(kind == nil ? 32 : 26, weight: .medium), theme.text.withAlphaComponent(alpha))
        big.draw(at: CGPoint(x: 18, y: 36), width: bounds.width - 36)

        let noteY: CGFloat = kind == nil ? 78 : 72
        if let kind {
            let share = all > 0 ? value / all : 0
            let note = isOn ? StatsFormat.percent(share) + tr(" du total", " of all") : tr("Non compté", "Not counted")
            note.attributed(.systemFont(ofSize: 11), theme.tertiary).draw(at: CGPoint(x: 18, y: noteY), width: bounds.width - 36)
        } else if let previous = summary.previousTotal, summary.query.period != .all {
            drawDelta(current: summary.total, previous: previous, y: noteY, theme: theme)
        } else {
            (StatsFormat.full(summary.total) + " tokens").attributed(.systemFont(ofSize: 11), theme.tertiary)
                .draw(at: CGPoint(x: 18, y: noteY), width: bounds.width - 36)
        }

        let spark = CGRect(x: 18, y: bounds.height - 34, width: bounds.width - 36, height: 22)
        let values = morph(series(f.from), series(f.to))
        if values.contains(where: { $0 > 0 }) {
            ChartPath.sparkline(values, in: spark, color: color.withAlphaComponent(isOn ? 1 : 0.4))
        } else {
            theme.track.setFill()
            CGRect(x: spark.minX, y: spark.maxY - 1, width: spark.width, height: 1).fill()
        }
    }

    private func drawDelta(current: Int, previous: Int, y: CGFloat, theme: PanelTheme) {
        guard previous > 0 else {
            (current > 0 ? tr("Rien la période d'avant", "Nothing the period before") : "")
                .attributed(.systemFont(ofSize: 11), theme.tertiary).draw(at: CGPoint(x: 18, y: y), width: bounds.width - 36)
            return
        }
        let change = Double(current - previous) / Double(previous)
        let up = change >= 0
        let color = up ? PanelTheme.gaugeColors[2] : PanelTheme.danger
        let text = (up ? "↑ " : "↓ ") + StatsFormat.percent(abs(change))
        let pill = text.attributed(.systemFont(ofSize: 11, weight: .semibold), color)
        let size = pill.size()
        let rect = CGRect(x: 18, y: y - 2, width: size.width + 14, height: size.height + 4)
        color.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        pill.draw(at: CGPoint(x: rect.minX + 7, y: y))
        summary.query.period.comparison.attributed(.systemFont(ofSize: 11), theme.tertiary)
            .draw(at: CGPoint(x: rect.maxX + 8, y: y), width: bounds.width - rect.maxX - 26)
    }
}

// MARK: - Timeline

/// Stacked smooth bands over time, by token type or by model, with a crosshair on hover.
final class TimelineCard: StatsCard {
    let picker: SegmentedPicker = {
        let picker = SegmentedPicker(options: [tr("Par type", "By type"), tr("Par modèle", "By model")])
        picker.compact = true
        return picker
    }()

    private struct Series { var key: String; var label: String; var color: NSColor; var values: [Double] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = tr("Évolution", "Over time")
        addSubview(picker)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = picker.fittingSize
        picker.frame = CGRect(x: bounds.width - 18 - size.width, y: 18, width: size.width, height: size.height)
    }

    private static func unitLength(_ unit: StatsSummary.Unit) -> TimeInterval {
        switch unit {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 86400
        case .week: return 7 * 86400
        }
    }

    /// Bottom band first: the largest.
    private func series(_ s: StatsSummary) -> [Series] {
        if f.byModel {
            return s.models.map { m in
                Series(key: "m:" + m.id, label: StatsFormat.model(m.id), color: f.color(m.id),
                       values: s.buckets.map { $0.models[m.id] ?? 0 })
            }
        }
        return TokenKind.allCases.filter(s.query.kinds.contains)
            .sorted { s.kindTotals[$0.rawValue] > s.kindTotals[$1.rawValue] }
            .map { k in Series(key: "k:\(k.rawValue)", label: k.title, color: k.color, values: s.buckets.map { $0.kinds[k.rawValue] }) }
    }

    override var headerSubtitle: String {
        switch summary.unit {
        case .hour: return tr("Tokens par heure", "Tokens per hour")
        case .sixHours: return tr("Tokens par tranche de 6 h", "Tokens per 6 hours")
        case .day: return tr("Tokens par jour", "Tokens per day")
        case .week: return tr("Tokens par semaine", "Tokens per week")
        }
    }

    override func drawContent(_ theme: PanelTheme) {
        let s = summary

        let plot = CGRect(x: 72, y: 76, width: bounds.width - 72 - 26, height: bounds.height - 76 - 62)
        let old = Dictionary(series(f.from).map { ($0.key, $0.values) }, uniquingKeysWith: { a, _ in a })
        let shown = series(s).map { serie -> Series in
            var serie = serie
            serie.values = morph(old[serie.key] ?? [], serie.values)
            return serie
        }
        let count = s.buckets.count
        var stacks = [[Double]](repeating: [Double](repeating: 0, count: count), count: shown.count + 1)
        for (i, serie) in shown.enumerated() {
            for j in 0..<count { stacks[i + 1][j] = stacks[i][j] + serie.values[j] }
        }
        // The axis glides with the data.
        let peak = stacks.last?.max() ?? 0
        let oldPeak = series(f.from).reduce(into: [Double](repeating: 0, count: f.from.buckets.count)) { acc, serie in
            for j in acc.indices where j < serie.values.count { acc[j] += serie.values[j] }
        }.max() ?? 0
        let top = ChartPath.niceCeil(max(peak, f.mix(oldPeak, peak), 1))

        // Grid and y labels.
        for i in 0...4 {
            let y = plot.maxY - plot.height * CGFloat(i) / 4
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.line(to: CGPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            if i > 0 { line.setLineDash([2, 4], count: 2, phase: 0) }
            (i == 0 ? theme.text.withAlphaComponent(0.14) : theme.stroke).setStroke()
            line.stroke()
            let label = StatsFormat.compact(top * Double(i) / 4).attributed(.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), theme.tertiary)
            label.draw(at: CGPoint(x: plot.minX - 12 - label.size().width, y: y - label.size().height / 2))
        }

        let length = Self.unitLength(s.unit)
        func x(_ date: Date) -> CGFloat {
            plot.minX + plot.width * CGFloat(date.timeIntervalSince(s.domain.start) / s.domain.duration)
        }
        func y(_ v: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(min(1, v / top)) }
        let centers = s.buckets.map { x($0.start.addingTimeInterval(length / 2)) }
        drawXLabels(s, plot: plot, theme: theme, x: x)

        guard s.hasData, count > 0 else {
            if count >= 0 { empty(theme, in: plot) }
            drawLegend(shown, theme: theme)
            return
        }
        // One bucket: a flat band over its whole width.
        let xs = count == 1 ? [x(s.buckets[0].start), x(s.buckets[0].start.addingTimeInterval(length))] : centers
        func points(_ values: [Double]) -> [CGPoint] {
            count == 1 ? xs.map { CGPoint(x: $0, y: y(values[0])) } : zip(xs, values).map { CGPoint(x: $0, y: y($1)) }
        }
        for i in shown.indices {
            let upper = points(stacks[i + 1]), lower = points(stacks[i])
            let band = NSBezierPath()
            ChartPath.add(upper, to: band, move: true)
            ChartPath.add(lower.reversed(), to: band, move: false)
            band.close()
            ChartPath.fillGradient(band, color: shown[i].color, top: plot.minY, bottom: plot.maxY, alphas: (0.9, 0.5))
            let edge = NSBezierPath()
            ChartPath.add(upper, to: edge, move: true)
            edge.lineWidth = 1.6
            edge.lineJoinStyle = .round
            shown[i].color.setStroke()
            edge.stroke()
        }
        drawLegend(shown, theme: theme)

        // Crosshair on the nearest bucket.
        guard let hover, plot.insetBy(dx: -8, dy: -8).contains(hover) else { return }
        let index = centers.enumerated().min { abs($0.element - hover.x) < abs($1.element - hover.x) }?.offset ?? 0
        let cx = centers[index]
        let rule = NSBezierPath()
        rule.move(to: CGPoint(x: cx, y: plot.minY))
        rule.line(to: CGPoint(x: cx, y: plot.maxY))
        rule.lineWidth = 1
        rule.setLineDash([3, 3], count: 2, phase: 0)
        theme.text.withAlphaComponent(0.35).setStroke()
        rule.stroke()
        for i in shown.indices where shown[i].values[index] > 0 {
            let dot = CGRect(x: cx - 4.5, y: y(stacks[i + 1][index]) - 4.5, width: 9, height: 9)
            theme.card.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2)).fill()
            shown[i].color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        let bucket = s.buckets[index]
        let real = series(s)
        var rows = real.reversed().filter { $0.values[index] > 0 }.map { (color: Optional($0.color), label: $0.label, value: StatsFormat.compact($0.values[index])) }
        rows.append((color: nil, label: tr("Total", "Total"), value: StatsFormat.compact(real.reduce(0) { $0 + $1.values[index] })))
        tooltip(at: CGPoint(x: cx, y: hover.y), title: bucketTitle(bucket.start, s.unit), rows: rows,
                footer: L10n.plural(bucket.messages, tr("réponse", "response")), theme: theme)
    }

    private func bucketTitle(_ start: Date, _ unit: StatsSummary.Unit) -> String {
        let hour = Calendar.current.component(.hour, from: start)
        switch unit {
        case .hour: return StatsFormat.hour(hour) + " – " + StatsFormat.hour((hour + 1) % 24)
        case .sixHours: return StatsFormat.date(start, "EEE d MMM") + ", " + StatsFormat.hour(hour) + " – " + StatsFormat.hour((hour + 6) % 24)
        case .day: return StatsFormat.date(start, "EEEE d MMMM")
        case .week: return tr("Semaine du ", "Week of ") + StatsFormat.date(start, "d MMM yyyy")
        }
    }

    private func drawXLabels(_ s: StatsSummary, plot: CGRect, theme: PanelTheme, x: (Date) -> CGFloat) {
        let calendar = Calendar.current
        var marks: [(Date, String)] = []
        switch s.query.period {
        case .today:
            marks = stride(from: 0, through: 24, by: 3).map {
                let d = calendar.date(byAdding: .hour, value: $0, to: s.domain.start)!
                return (d, $0 == 24 ? "" : StatsFormat.hour($0))
            }
        case .week:
            marks = (0..<7).map {
                let d = calendar.date(byAdding: .day, value: $0, to: s.domain.start)!
                return (d.addingTimeInterval(43200), StatsFormat.date(d, "EEE d"))
            }
        case .month:
            marks = stride(from: 0, to: 30, by: 5).map {
                let d = calendar.date(byAdding: .day, value: $0 + 2, to: s.domain.start)!
                return (d.addingTimeInterval(43200), StatsFormat.date(d, "d MMM"))
            }
        case .all:
            let days = max(1, Int(s.domain.duration / 86400))
            let step = max(1, days / 6)
            marks = stride(from: step / 2, to: days, by: step).map {
                let d = calendar.date(byAdding: .day, value: $0, to: s.domain.start)!
                return (d, StatsFormat.date(d, days > 300 ? "MMM yyyy" : "d MMM"))
            }
        }
        for (date, text) in marks where !text.isEmpty {
            let label = text.attributed(.systemFont(ofSize: 10.5), theme.tertiary)
            let w = label.size().width
            let cx = min(max(x(date), plot.minX + w / 2), plot.maxX - w / 2)
            label.draw(at: CGPoint(x: cx - w / 2, y: plot.maxY + 9))
        }
    }

    private func drawLegend(_ shown: [Series], theme: PanelTheme) {
        var x: CGFloat = 72
        let y = bounds.height - 28
        for serie in shown.reversed() {
            serie.color.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: y + 3.5, width: 9, height: 9), xRadius: 3, yRadius: 3).fill()
            let label = serie.label.attributed(.systemFont(ofSize: 11.5), theme.secondary)
            label.draw(at: CGPoint(x: x + 15, y: y))
            x += 15 + label.size().width + 20
            if x > bounds.width - 100 { break }
        }
    }
}

// MARK: - Models

/// A donut of the models' shares, and their list.
final class ModelsCard: StatsCard {
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = tr("Modèles", "Models")
    }

    required init?(coder: NSCoder) { fatalError() }

    private struct Slice { var id: String; var label: String; var color: NSColor; var tokens: Double; var messages: Int }

    private func slices(_ s: StatsSummary) -> [Slice] {
        var list = s.models.prefix(5).map { Slice(id: $0.id, label: StatsFormat.model($0.id), color: f.color($0.id), tokens: Double($0.tokens), messages: $0.messages) }
        let rest = s.models.dropFirst(5)
        if !rest.isEmpty {
            list.append(Slice(id: "", label: tr("Autres", "Others"), color: PanelTheme.hex(0x8F8D85),
                              tokens: Double(rest.reduce(0) { $0 + $1.tokens }), messages: rest.reduce(0) { $0 + $1.messages }))
        }
        return list
    }

    override var headerSubtitle: String {
        summary.models.first.map { tr("Préféré : ", "Favorite: ") + StatsFormat.model($0.id) } ?? tr("Aucun modèle", "No model")
    }

    override func drawContent(_ theme: PanelTheme) {
        let s = summary
        let body = CGRect(x: 0, y: 66, width: bounds.width, height: bounds.height - 66)
        guard s.hasData else { return empty(theme, in: body) }

        let list = slices(s)
        let old = Dictionary(slices(f.from).map { ($0.id, $0.tokens) }, uniquingKeysWith: { a, _ in a })
        let values = list.map { f.mix(old[$0.id] ?? 0, $0.tokens) }
        let sum = max(values.reduce(0, +), 1)
        let radius = min(64, (body.height - 30) / 2)
        let center = CGPoint(x: 22 + radius, y: body.midY - 4)

        // Which slice is under the cursor: on the ring, or on its row.
        var hovered: Int?
        let rowX = center.x + radius + 26, rowWidth = bounds.width - rowX - 20, rowTop = center.y - CGFloat(list.count) * 13
        if let hover {
            let dx = hover.x - center.x, dy = hover.y - center.y, dist = hypot(dx, dy)
            if dist > radius - 22, dist < radius + 6 {
                var angle = atan2(dy, dx) + .pi / 2
                if angle < 0 { angle += 2 * .pi }
                var acc: CGFloat = 0
                for (i, v) in values.enumerated() {
                    acc += CGFloat(v / sum) * 2 * .pi
                    if angle <= acc { hovered = i; break }
                }
            } else if hover.x >= rowX - 6, hover.y >= rowTop {
                let i = Int((hover.y - rowTop) / 26)
                if i < list.count { hovered = i }
            }
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var start = -CGFloat.pi / 2
        let gap: CGFloat = list.count > 1 ? 0.025 : 0
        for (i, v) in values.enumerated() {
            let sweep = CGFloat(v / sum) * 2 * .pi
            guard sweep > gap else { start += sweep; continue }
            let width: CGFloat = hovered == i ? 20 : 15
            ctx.setLineWidth(width)
            ctx.setLineCap(.butt)
            ctx.setStrokeColor(list[i].color.withAlphaComponent(hovered == nil || hovered == i ? 1 : 0.45).cgColor)
            ctx.addArc(center: center, radius: radius - 8, startAngle: start + gap / 2, endAngle: start + sweep - gap / 2, clockwise: false)
            ctx.strokePath()
            start += sweep
        }
        let focus = hovered.map { list[$0] }
        let number = StatsFormat.compact(focus.map { $0.tokens } ?? Double(s.total)).attributed(.serif(19, weight: .medium), theme.text)
        let caption = (focus.map { StatsFormat.percent($0.tokens / Double(max(s.total, 1))) } ?? "tokens")
            .attributed(.systemFont(ofSize: 10.5), theme.tertiary)
        number.draw(at: CGPoint(x: center.x - number.size().width / 2, y: center.y - 15))
        caption.draw(at: CGPoint(x: center.x - caption.size().width / 2, y: center.y + 7))

        for (i, slice) in list.enumerated() {
            let y = rowTop + CGFloat(i) * 26
            let dim: CGFloat = hovered == nil || hovered == i ? 1 : 0.5
            slice.color.withAlphaComponent(dim).setFill()
            NSBezierPath(roundedRect: CGRect(x: rowX, y: y + 4.5, width: 9, height: 9), xRadius: 3, yRadius: 3).fill()
            let value = StatsFormat.compact(values[i]).attributed(.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), theme.text.withAlphaComponent(dim))
            let share = StatsFormat.percent(values[i] / sum).attributed(.monospacedDigitSystemFont(ofSize: 11, weight: .regular), theme.tertiary)
            let shareX = rowX + rowWidth - 38
            share.draw(at: CGPoint(x: rowX + rowWidth - share.size().width, y: y + 1))
            value.draw(at: CGPoint(x: shareX - 8 - value.size().width, y: y))
            slice.label.attributed(.systemFont(ofSize: 12.5, weight: .medium), theme.text.withAlphaComponent(dim))
                .draw(at: CGPoint(x: rowX + 16, y: y), width: shareX - 8 - value.size().width - rowX - 24)
        }
        if let i = hovered, let hover {
            let slice = list[i]
            tooltip(at: hover, title: slice.label, rows: [
                (color: slice.color, label: tr("Tokens", "Tokens"), value: StatsFormat.full(Int(slice.tokens))),
                (color: nil, label: tr("Réponses", "Responses"), value: StatsFormat.full(slice.messages)),
            ], footer: slice.id.isEmpty ? nil : slice.id, theme: theme)
        }
    }
}

// MARK: - Hours

/// Tokens by hour of the day, the peak hour in full color.
final class HoursCard: StatsCard {
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = tr("Heures d'activité", "Hours of activity")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var headerSubtitle: String {
        summary.peakHour.map { tr("Pointe vers ", "Peak around ") + StatsFormat.hour($0) } ?? tr("Pas encore de pointe", "No peak yet")
    }

    override func drawContent(_ theme: PanelTheme) {
        let s = summary
        let plot = CGRect(x: 20, y: 78, width: bounds.width - 40, height: bounds.height - 78 - 40)
        guard s.hasData else { return empty(theme, in: plot) }
        let values = morph(f.from.hours, s.hours)
        let top = max(values.max() ?? 0, 1)
        let slot = plot.width / 24, barWidth = max(3, slot - 3)
        var hovered: Int?
        if let hover, plot.insetBy(dx: 0, dy: -10).contains(hover) { hovered = min(23, Int((hover.x - plot.minX) / slot)) }
        for (h, v) in values.enumerated() {
            let height = max(2, plot.height * CGFloat(v / top))
            let bar = CGRect(x: plot.minX + CGFloat(h) * slot + (slot - barWidth) / 2, y: plot.maxY - height, width: barWidth, height: height)
            let color = h == s.peakHour ? theme.accent : theme.accent.withAlphaComponent(hovered == h ? 0.85 : 0.42)
            if v <= 0 { theme.track.setFill() } else { color.setFill() }
            NSBezierPath(roundedRect: bar, xRadius: min(3, barWidth / 2), yRadius: min(3, barWidth / 2)).fill()
        }
        for h in [0, 6, 12, 18] {
            let label = StatsFormat.hour(h).attributed(.systemFont(ofSize: 10.5), theme.tertiary)
            label.draw(at: CGPoint(x: plot.minX + CGFloat(h) * slot, y: plot.maxY + 9))
        }
        if let h = hovered, let hover {
            tooltip(at: CGPoint(x: plot.minX + (CGFloat(h) + 0.5) * slot, y: hover.y),
                    title: StatsFormat.hour(h) + " – " + StatsFormat.hour((h + 1) % 24),
                    rows: [(color: theme.accent, label: "Tokens", value: StatsFormat.compact(s.hours[h]))], theme: theme)
        }
    }
}

// MARK: - Projects

/// The five folders that used the most tokens.
final class ProjectsCard: StatsCard {
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = tr("Projets", "Projects")
        subtitle = tr("Les plus gourmands", "The hungriest")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ theme: PanelTheme) {
        let s = summary
        let body = CGRect(x: 20, y: 72, width: bounds.width - 40, height: bounds.height - 72 - 16)
        guard !s.projects.isEmpty else { return empty(theme, in: body, tr("Aucun projet sur cette période", "No project in this period")) }
        let old = Dictionary(f.from.projects.map { ($0.name, Double($0.tokens)) }, uniquingKeysWith: { a, _ in a })
        let top = Double(s.projects.first?.tokens ?? 1)
        for (i, project) in s.projects.enumerated() {
            let y = body.minY + CGFloat(i) * 33
            let value = f.mix(old[project.name] ?? 0, Double(project.tokens))
            let number = StatsFormat.compact(value).attributed(.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), theme.secondary)
            number.draw(at: CGPoint(x: body.maxX - number.size().width, y: y))
            project.name.attributed(.systemFont(ofSize: 12.5, weight: .medium), theme.text)
                .draw(at: CGPoint(x: body.minX, y: y - 1), width: body.width - number.size().width - 12)
            let track = CGRect(x: body.minX, y: y + 19, width: body.width, height: 5)
            theme.track.setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            var bar = track
            bar.size.width = max(5, track.width * CGFloat(value / max(top, 1)))
            PanelTheme.gaugeColors[i % 3].setFill()
            NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}

// MARK: - Overview page

final class StatsOverviewPage: StatsPage {
    private let tiles = TilesCard()
    private let heatmap = HeatmapCard()
    private let records = RecordsCard()

    override init(frame: NSRect) {
        super.init(frame: frame)
        [tiles, heatmap, records].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let gap: CGFloat = 14
        tiles.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 2 * 86 + gap)
        heatmap.frame = CGRect(x: 0, y: tiles.frame.maxY + gap, width: bounds.width, height: 258)
        records.frame = CGRect(x: 0, y: heatmap.frame.maxY + gap, width: bounds.width, height: 100)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A comparison to close on, under the cards.
        let theme = PanelTheme.current(effectiveAppearance)
        let s = frameData.to
        guard s.total > 0 else { return }
        let book = 160_000.0
        let ratio = frameData.mix(frameData.from.total, s.total) / book
        let text: String
        if ratio >= 1.5 {
            let times = StatsFormat.full(Int(ratio.rounded()))
            text = tr("Vous avez utilisé environ \(times) fois plus de tokens qu'Orgueil et Préjugés.",
                      "You've used about \(times)× more tokens than Pride and Prejudice.")
        } else {
            let share = StatsFormat.percent(ratio)
            text = tr("Ces tokens représentent environ \(share) d'Orgueil et Préjugés.",
                      "That's about \(share) of Pride and Prejudice in tokens.")
        }
        let line = text.attributed(.serif(15).withTraits(.italic), theme.secondary)
        let y = records.frame.maxY + 22
        let size = line.size()
        line.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: y))
    }
}

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}

/// Eight numbers in two rows, each on its own little card.
final class TilesCard: StatsCard {
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ theme: PanelTheme) {
        let s = summary
        let days = { (n: Int) in L10n.plural(n, tr("jour", "day")) }
        let favorite = s.models.first
        let tiles: [(String, String, NSColor?)] = [
            (tr("Sessions", "Sessions"), StatsFormat.full(Int(f.mix(f.from.sessions, s.sessions))), nil),
            (tr("Réponses", "Responses"), StatsFormat.full(Int(f.mix(f.from.messages, s.messages))), nil),
            (tr("Tokens comptés", "Tokens counted"), StatsFormat.compact(f.mix(f.from.total, s.total)), nil),
            (tr("Jours actifs", "Active days"), StatsFormat.full(Int(f.mix(f.from.activeDays, s.activeDays))), nil),
            (tr("Heure de pointe", "Peak hour"), s.peakHour.map(StatsFormat.hour) ?? "—", nil),
            (tr("Modèle préféré", "Favorite model"), favorite.map { StatsFormat.model($0.id) } ?? "—", favorite.map { f.color($0.id) }),
            (tr("Série en cours", "Current streak"), days(s.currentStreak), nil),
            (tr("Plus longue série", "Longest streak"), days(s.longestStreak), nil),
        ]
        let gap: CGFloat = 14, w = (bounds.width - 3 * gap) / 4, h = (bounds.height - gap) / 2
        for (i, tile) in tiles.enumerated() {
            let rect = CGRect(x: CGFloat(i % 4) * (w + gap), y: CGFloat(i / 4) * (h + gap), width: w, height: h)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
            theme.card.setFill()
            shape.fill()
            theme.stroke.setStroke()
            shape.stroke()
            tile.0.attributed(.systemFont(ofSize: 12, weight: .medium), theme.tertiary).draw(at: CGPoint(x: rect.minX + 18, y: rect.minY + 16), width: w - 36)
            var x = rect.minX + 18
            if let color = tile.2 {
                color.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: rect.minY + 47, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
                x += 17
            }
            tile.1.attributed(.serif(24, weight: .medium), theme.text).draw(at: CGPoint(x: x, y: rect.minY + 36), width: rect.maxX - x - 14)
        }
    }
}

/// One square per day, a year of them, tinted by the tokens counted that day.
final class HeatmapCard: StatsCard {
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = tr("Activité", "Activity")
        subtitle = tr("Un carré par jour, teinté selon les tokens comptés", "One square per day, tinted by the tokens counted")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Quartiles of the active days: five steps from empty to the busiest.
    private func levels(_ s: StatsSummary) -> [Int] {
        let values = s.daily.values.map(\.tokens).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { values[min(values.count - 1, Int(Double(values.count) * $0))] }
    }

    private func level(_ tokens: Int, _ cuts: [Int]) -> Int {
        guard tokens > 0 else { return 0 }
        return 1 + cuts.filter { tokens > $0 }.count
    }

    override func drawContent(_ theme: PanelTheme) {
        let s = summary
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: s.now)
        let gap: CGFloat = 3, left: CGFloat = 52
        let available = bounds.width - left - 22
        // From a little before the first transcript (half a year at least) up to a year: no wall of empty weeks.
        let weeks = s.firstDay.map { (calendar.dateComponents([.day], from: $0, to: today).day ?? 0) / 7 + 3 } ?? 26
        let columns = max(1, min(Int((available + gap) / (13 + gap)), min(53, max(26, weeks))))
        let cell = min(17, floor((available + gap) / CGFloat(columns) - gap))
        let gridWidth = CGFloat(columns) * (cell + gap) - gap
        let originX = left + (available - gridWidth) / 2, originY: CGFloat = 92

        // Columns are weeks; the last one holds today.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstColumn = calendar.date(byAdding: .day, value: -7 * (columns - 1), to: weekStart)!
        let cuts = levels(s), oldCuts = levels(f.from)
        let periodStart = s.domain.start
        var hovered: (Date, CGRect)?

        // Legend, top right.
        var lx = bounds.width - 22
        let more = tr("Plus", "More").attributed(.systemFont(ofSize: 10.5), theme.tertiary)
        lx -= more.size().width
        more.draw(at: CGPoint(x: lx, y: 44))
        for step in (0...4).reversed() {
            lx -= 4 + 11
            fill(step, theme).setFill()
            NSBezierPath(roundedRect: CGRect(x: lx, y: 46, width: 11, height: 11), xRadius: 3, yRadius: 3).fill()
        }
        let less = tr("Moins", "Less").attributed(.systemFont(ofSize: 10.5), theme.tertiary)
        less.draw(at: CGPoint(x: lx - 6 - less.size().width, y: 44))

        // Weekday labels: every other row.
        for row in [0, 2, 4] {
            let date = calendar.date(byAdding: .day, value: row, to: weekStart)!
            StatsFormat.date(date, "EEE").attributed(.systemFont(ofSize: 10), theme.tertiary)
                .draw(at: CGPoint(x: originX - 36, y: originY + CGFloat(row) * (cell + gap) + (cell - 13) / 2), width: 32)
        }

        var lastMonth = -1
        for column in 0..<columns {
            let columnStart = calendar.date(byAdding: .day, value: 7 * column, to: firstColumn)!
            let month = calendar.component(.month, from: columnStart)
            let x = originX + CGFloat(column) * (cell + gap)
            if month != lastMonth {
                if lastMonth != -1 || calendar.component(.day, from: columnStart) <= 7 {
                    StatsFormat.date(columnStart, "MMM").attributed(.systemFont(ofSize: 10.5), theme.tertiary)
                        .draw(at: CGPoint(x: x, y: originY - 19))
                }
                lastMonth = month
            }
            for row in 0..<7 {
                let day = calendar.date(byAdding: .day, value: row, to: columnStart)!
                guard day <= today else { continue }
                let rect = CGRect(x: x, y: originY + CGFloat(row) * (cell + gap), width: cell, height: cell)
                let tokens = s.daily[day]?.tokens ?? 0
                let target = level(tokens, cuts), before = level(f.from.daily[day]?.tokens ?? 0, oldCuts)
                let mixed = CGFloat(f.mix(Double(before), Double(target)))
                let inPeriod = s.query.period == .all || day >= periodStart
                var color = blend(mixed, theme)
                if !inPeriod { color = color.withAlphaComponent(color.alphaComponent * 0.35) }
                color.setFill()
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                path.fill()
                if day == today {
                    theme.text.withAlphaComponent(0.55).setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 4, yRadius: 4)
                    ring.lineWidth = 1.2
                    ring.stroke()
                }
                if let hover, rect.insetBy(dx: -gap / 2, dy: -gap / 2).contains(hover) { hovered = (day, rect) }
            }
        }

        let gridBottom = originY + 7 * (cell + gap)
        let first = s.firstDay.map { tr("Transcripts lus depuis le ", "Transcripts read since ") + StatsFormat.date($0, "d MMMM yyyy") } ?? ""
        first.attributed(.systemFont(ofSize: 10.5), theme.tertiary).draw(at: CGPoint(x: originX, y: gridBottom + 10), width: gridWidth)

        if let (day, rect) = hovered {
            theme.text.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3.5, yRadius: 3.5)
            ring.lineWidth = 1.5
            ring.stroke()
            let data = s.daily[day] ?? StatsSummary.Day()
            tooltip(at: CGPoint(x: rect.midX, y: rect.midY), title: StatsFormat.date(day, "EEEE d MMMM yyyy"), rows: [
                (color: data.tokens > 0 ? theme.accent : nil, label: tr("Tokens", "Tokens"), value: StatsFormat.compact(Double(data.tokens))),
                (color: nil, label: tr("Réponses", "Responses"), value: StatsFormat.full(data.messages)),
            ], theme: theme)
        }
    }

    private func fill(_ step: Int, _ theme: PanelTheme) -> NSColor {
        step == 0 ? theme.track : theme.accent.withAlphaComponent([0, 0.3, 0.52, 0.76, 1][step])
    }

    /// Between two steps, for the morph.
    private func blend(_ level: CGFloat, _ theme: PanelTheme) -> NSColor {
        let low = Int(floor(level)), high = min(4, low + 1), t = level - CGFloat(low)
        guard t > 0.01 else { return fill(low, theme) }
        return fill(low, theme).blended(withFraction: t, of: fill(high, theme)) ?? fill(high, theme)
    }
}

/// The period's records: the biggest day, the longest answer, the hungriest session.
final class RecordsCard: StatsCard {
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func drawContent(_ theme: PanelTheme) {
        let s = summary
        let items: [(String, String, String, NSColor)] = [
            (tr("Journée record", "Biggest day"),
             s.biggestDay.map { StatsFormat.compact(Double($0.tokens)) } ?? "—",
             s.biggestDay.map { StatsFormat.date($0.date, "EEEE d MMMM") } ?? "",
             PanelTheme.gaugeColors[0]),
            (tr("Réponse la plus longue", "Longest response"),
             s.biggestResponse.map { StatsFormat.compact(Double($0.output)) + tr(" en sortie", " out") } ?? "—",
             s.biggestResponse.map { StatsFormat.model($0.model) } ?? "",
             PanelTheme.gaugeColors[1]),
            (tr("Session la plus gourmande", "Hungriest session"),
             s.biggestSession.map { StatsFormat.compact(Double($0.tokens)) } ?? "—",
             s.biggestSession.map { $0.project.isEmpty ? "" : $0.project } ?? "",
             PanelTheme.gaugeColors[2]),
        ]
        let gap: CGFloat = 14, w = (bounds.width - 2 * gap) / 3
        for (i, item) in items.enumerated() {
            let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
            theme.card.setFill()
            shape.fill()
            theme.stroke.setStroke()
            shape.stroke()
            // A colored rail on the left edge.
            item.3.setFill()
            NSBezierPath(roundedRect: CGRect(x: rect.minX + 16, y: rect.minY + 18, width: 3, height: rect.height - 36), xRadius: 1.5, yRadius: 1.5).fill()
            let x = rect.minX + 32
            item.0.attributed(.systemFont(ofSize: 12, weight: .medium), theme.tertiary).draw(at: CGPoint(x: x, y: rect.minY + 16), width: w - 48)
            item.1.attributed(.serif(22, weight: .medium), theme.text).draw(at: CGPoint(x: x, y: rect.minY + 36), width: w - 48)
            item.2.attributed(.systemFont(ofSize: 11.5), theme.secondary).draw(at: CGPoint(x: x, y: rect.minY + 68), width: w - 48)
        }
    }
}

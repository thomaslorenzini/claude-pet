import AppKit

/// What Claude is waiting for, with the buttons to answer: a permission (allow / deny) or the
/// questions of `AskUserQuestion`, one at a time. Light text on black: it lives in the notch box or
/// in the floating card, which draw the background.
final class RequestView: NSView, NSTextFieldDelegate {
    var onAllow: ((Int) -> Void)?
    var onDeny: ((Int) -> Void)?
    var onAnswer: ((Int, [String: String]) -> Void)?
    /// Leave it to Claude Code's own dialog.
    var onDismiss: ((Int) -> Void)?
    /// The "Autre" field wants the keyboard (true) or is done with it. The container lets its window
    /// become key only meanwhile: a pet that took the keyboard on every click would steal typing.
    var onEditing: ((Bool) -> Void)?

    private(set) var request: PendingRequest?
    /// Other requests waiting behind this one.
    private var waiting = 0
    private var questionIndex = 0
    private var answers: [String: String] = [:]
    private var selected = Set<Int>()
    /// "Autre": a free answer typed in, like the last row of Claude's own question dialog.
    private var other = false
    private var otherText = ""
    private weak var otherField: NSTextField?
    private weak var confirmButton: PillButton?
    /// The "Autre" field has the keyboard: the panel must stay open even if the cursor leaves it.
    private(set) var isEditing = false
    private var laidOutWidth: CGFloat = 0

    static let accent = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Clicks between the buttons must not pick the pet up.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    func show(_ request: PendingRequest?, waiting: Int) {
        if request?.id != self.request?.id {
            if isEditing {
                window?.makeFirstResponder(nil)
                stopEditing()
            }
            questionIndex = 0
            answers = [:]
            selected = []
            other = false
            otherText = ""
        }
        self.request = request
        self.waiting = waiting
        laidOutWidth = 0
        needsLayout = true
    }

    /// Height of the content for `width`, building the subviews if needed.
    func height(for width: CGFloat) -> CGFloat {
        if width != laidOutWidth { build(width: width) }
        return subviews.map(\.frame.maxY).max() ?? 0
    }

    override func layout() {
        super.layout()
        if bounds.width != laidOutWidth { build(width: bounds.width) }
    }

    // MARK: Building

    private func build(width: CGFloat) {
        laidOutWidth = width
        subviews.forEach { $0.removeFromSuperview() }
        guard let request, width > 40 else { return }
        var y: CGFloat = 0
        let more = waiting > 0 ? " · " + tr("\(waiting) autre\(waiting > 1 ? "s" : "") en attente", "\(waiting) more waiting") : ""

        switch request.kind {
        case let .permission(tool, title, body, note):
            y = addLabel(caption([request.project, tool].filter { !$0.isEmpty }.joined(separator: " · ") + more), y: y, width: width)
            y = addLabel(heading(tr("Claude veut : ", "Claude wants to: ") + title.lowercased(with: .current)), y: y + 2, width: width)
            if !body.isEmpty { y = addCode(body, y: y + 8, width: width) }
            if let note { y = addLabel(detail(note), y: y + 6, width: width, lines: 3) }
            y += 12
            let id = request.id
            addButtons([
                PillButton(title: tr("Ignorer", "Ignore"), style: .plain) { [weak self] in self?.onDismiss?(id) },
                PillButton(title: tr("Refuser", "Deny"), style: .secondary) { [weak self] in self?.onDeny?(id) },
                PillButton(title: tr("Autoriser", "Allow"), style: .primary) { [weak self] in self?.onAllow?(id) },
            ], y: y, width: width)

        case let .questions(questions):
            let index = min(questionIndex, questions.count - 1)
            let q = questions[index]
            var parts = [request.project]
            if questions.count > 1 { parts.append("Question \(index + 1)/\(questions.count)") }
            if !q.header.isEmpty { parts.append(q.header) }
            y = addLabel(caption(parts.filter { !$0.isEmpty }.joined(separator: " · ") + more), y: y, width: width)
            y = addLabel(heading(q.text), y: y + 2, width: width, lines: 6)
            y += 8
            for (i, option) in q.options.enumerated() {
                let button = PillButton(
                    title: option.label, detail: option.detail, style: .option,
                    checked: q.multiSelect ? selected.contains(i) : nil
                ) { [weak self] in self?.pick(i) }
                let h = button.height(for: width)
                button.frame = CGRect(x: 0, y: y, width: width, height: h)
                addSubview(button)
                y += h + 6
            }
            let otherRow = PillButton(
                title: tr("Autre", "Other"), style: .option, checked: q.multiSelect ? other : nil, selected: other
            ) { [weak self] in self?.pickOther() }
            otherRow.frame = CGRect(x: 0, y: y, width: width, height: otherRow.height(for: width))
            addSubview(otherRow)
            y = otherRow.frame.maxY + 6
            if other { y = addOtherField(y: y, width: width) + 6 }
            y += 6
            let id = request.id
            var buttons = [PillButton(title: tr("Ignorer", "Ignore"), style: .plain) { [weak self] in self?.onDismiss?(id) }]
            if q.multiSelect || other {
                let confirm = PillButton(title: tr("Valider", "Submit"), style: .primary, enabled: canConfirm) { [weak self] in self?.confirm() }
                confirmButton = confirm
                buttons.append(confirm)
            }
            addButtons(buttons, y: y, width: width)
        }
    }

    private func pick(_ option: Int) {
        guard case let .questions(questions)? = request?.kind else { return }
        let q = questions[min(questionIndex, questions.count - 1)]
        if q.multiSelect {
            if selected.remove(option) == nil { selected.insert(option) }
            rebuild()
        } else {
            selected = [option]
            other = false
            confirm()
        }
    }

    private func pickOther() {
        guard case let .questions(questions)? = request?.kind else { return }
        let q = questions[min(questionIndex, questions.count - 1)]
        if q.multiSelect {
            other.toggle()
        } else {
            other = true
            selected = []
        }
        rebuild()
        if other { focusOther() }
    }

    private var canConfirm: Bool {
        let typed = !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return other ? typed || !selected.isEmpty : !selected.isEmpty
    }

    private func confirm() {
        guard let request, case let .questions(questions) = request.kind, canConfirm || !other else { return }
        let q = questions[min(questionIndex, questions.count - 1)]
        var labels = selected.sorted().map { q.options[$0].label }
        let typed = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        if other, !typed.isEmpty { labels.append(typed) }
        answers[q.text] = labels.joined(separator: ", ")
        selected = []
        other = false
        otherText = ""
        if questionIndex + 1 < questions.count {
            questionIndex += 1
            rebuild()
        } else {
            onAnswer?(request.id, answers)
        }
    }

    /// Height may change (next question): the container asks again through `onResize`.
    var onResize: (() -> Void)?
    private func rebuild() {
        build(width: laidOutWidth)
        onResize?()
    }

    // MARK: "Autre"

    private func addOtherField(y: CGFloat, width: CGFloat) -> CGFloat {
        let field = OtherField()
        field.stringValue = otherText
        field.delegate = self
        field.onClick = { [weak self] in self?.focusOther() }
        field.frame = CGRect(x: 0, y: y, width: width, height: 30)
        addSubview(field)
        otherField = field
        return field.frame.maxY
    }

    private func focusOther() {
        guard let field = otherField else { return }
        isEditing = true
        onEditing?(true)
        field.window?.makeKey()
        field.window?.makeFirstResponder(field)
    }

    private func stopEditing() {
        guard isEditing else { return }
        isEditing = false
        onEditing?(false)
    }

    func controlTextDidChange(_ note: Notification) {
        otherText = otherField?.stringValue ?? ""
        confirmButton?.enabled = canConfirm
    }

    func controlTextDidEndEditing(_ note: Notification) {
        // A rebuild replaces the field while it has the keyboard: focusOther takes it back.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.otherField?.currentEditor() == nil else { return }
            self.stopEditing()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if canConfirm {
                window?.makeFirstResponder(nil)
                confirm()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// Tests: types into the "Autre" field.
    func typeOther(_ text: String) {
        guard otherField != nil else { return }
        otherField?.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    /// Tests: the button with this title, anywhere in the view.
    func press(_ title: String) {
        func find(_ view: NSView) -> PillButton? {
            if let button = view as? PillButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        find(self)?.press()
    }

    // MARK: Pieces

    private func caption(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ])
    }

    private func heading(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ])
    }

    private func detail(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ])
    }

    @discardableResult
    private func addLabel(_ text: NSAttributedString, y: CGFloat, width: CGFloat, lines: Int = 2) -> CGFloat {
        let label = Self.label(text, lines: lines)
        let h = Self.height(of: label, width: width)
        label.frame = CGRect(x: 0, y: y, width: width, height: h)
        addSubview(label)
        return y + h
    }

    /// Command, path or URL, in a dark well. Long ones are cut after 8 lines.
    private func addCode(_ code: String, y: CGFloat, width: CGFloat) -> CGFloat {
        let well = NSView()
        well.wantsLayer = true
        well.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        well.layer?.cornerRadius = 8
        let text = NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        let label = Self.label(text, lines: 8)
        label.lineBreakMode = .byCharWrapping
        let h = Self.height(of: label, width: width - 20)
        well.frame = CGRect(x: 0, y: y, width: width, height: h + 14)
        label.frame = CGRect(x: 10, y: 7, width: width - 20, height: h)
        well.addSubview(label)
        addSubview(well)
        return well.frame.maxY
    }

    /// Right-aligned, except `plain` buttons which sit on the left.
    private func addButtons(_ buttons: [PillButton], y: CGFloat, width: CGFloat) {
        var right = width
        for button in buttons.reversed() where button.style != .plain {
            let w = button.fittingWidth
            right -= w
            button.frame = CGRect(x: right, y: y, width: w, height: 28)
            right -= 8
            addSubview(button)
        }
        var left: CGFloat = 0
        for button in buttons where button.style == .plain {
            let w = button.fittingWidth
            button.frame = CGRect(x: left, y: y, width: w, height: 28)
            left += w + 8
            addSubview(button)
        }
    }

    private static func label(_ text: NSAttributedString, lines: Int) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = lines
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        return label
    }

    private static func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 16)
    }
}

/// Rounded button drawn by hand, readable on black. `option` rows carry a description and, for
/// multiple choice, a check mark.
final class PillButton: NSView {
    enum Style { case primary, secondary, plain, option }

    let style: Style
    let title: String
    private let detail: String
    private let checked: Bool?
    /// Highlighted like a checked row, without a check box (single choice).
    private let selected: Bool
    var enabled: Bool { didSet { needsDisplay = true } }
    private let action: () -> Void
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(title: String, detail: String = "", style: Style, checked: Bool? = nil, selected: Bool = false,
         enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.style = style
        self.checked = checked
        self.selected = selected
        self.enabled = enabled
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var titleFont: NSFont { .systemFont(ofSize: style == .option ? 12.5 : 12, weight: style == .plain ? .regular : .semibold) }
    private let detailFont = NSFont.systemFont(ofSize: 11)
    private var checkInset: CGFloat { checked == nil ? 0 : 22 }

    var fittingWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: titleFont]).width) + (style == .plain ? 12 : 28)
    }

    func height(for width: CGFloat) -> CGFloat {
        guard style == .option else { return 28 }
        let textWidth = width - 24 - checkInset
        var h = 16 + ceil((title as NSString).boundingRect(
            with: CGSize(width: textWidth, height: 1000), options: .usesLineFragmentOrigin, attributes: [.font: titleFont]
        ).height)
        if !detail.isEmpty {
            h += 2 + min(30, ceil((detail as NSString).boundingRect(
                with: CGSize(width: textWidth, height: 1000), options: .usesLineFragmentOrigin, attributes: [.font: detailFont]
            ).height))
        }
        return max(30, h)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func press() { if enabled { action() } }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = enabled }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && inside
        pressed = false
        if fire { action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lift: CGFloat = pressed ? 0.06 : (hovered && enabled ? 0.1 : 0)
        let (fill, text): (NSColor, NSColor) = switch style {
        case .primary: (RequestView.accent.blended(withFraction: lift * 2, of: .white) ?? RequestView.accent, NSColor(white: 0.08, alpha: 1))
        case .secondary: (NSColor.white.withAlphaComponent(0.14 + lift), .white)
        case .plain: (NSColor.white.withAlphaComponent(lift), NSColor.white.withAlphaComponent(0.6))
        case .option: (NSColor.white.withAlphaComponent((checked == true || selected ? 0.16 : 0.07) + lift), .white)
        }
        let alpha: CGFloat = enabled ? 1 : 0.4
        fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: style == .option ? 9 : 14, yRadius: style == .option ? 9 : 14).fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: text.withAlphaComponent(text.alphaComponent * alpha)]

        guard style == .option else {
            let size = (title as NSString).size(withAttributes: titleAttributes)
            (title as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: titleAttributes)
            return
        }
        if let checked {
            let box = CGRect(x: 12, y: 9, width: 14, height: 14)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            if checked {
                RequestView.accent.setFill()
                path.fill()
                let mark = NSBezierPath()
                mark.move(to: CGPoint(x: box.minX + 3.5, y: box.midY))
                mark.line(to: CGPoint(x: box.minX + 6, y: box.maxY - 3.5))
                mark.line(to: CGPoint(x: box.maxX - 3, y: box.minY + 3.5))
                mark.lineWidth = 1.8
                NSColor(white: 0.08, alpha: 1).setStroke()
                mark.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.4).setStroke()
                path.lineWidth = 1.2
                path.stroke()
            }
        }
        let x = 12 + checkInset, w = bounds.width - 24 - checkInset
        let titleRect = (title as NSString).boundingRect(with: CGSize(width: w, height: 1000), options: .usesLineFragmentOrigin, attributes: titleAttributes)
        (title as NSString).draw(with: CGRect(x: x, y: 8, width: w, height: ceil(titleRect.height)), options: .usesLineFragmentOrigin, attributes: titleAttributes)
        guard !detail.isEmpty else { return }
        let detailAttributes: [NSAttributedString.Key: Any] = [.font: detailFont, .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
        (detail as NSString).draw(
            with: CGRect(x: x, y: 10 + ceil(titleRect.height), width: w, height: 30),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: detailAttributes
        )
    }
}

extension RequestView {
    /// "Claude a besoin de vous", with an orange dot: the collapsed form, in the notch and the card.
    static func bannerLabel() -> NSTextField {
        let text = NSMutableAttributedString(string: "●  ", attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: accent, .baselineOffset: 1,
        ])
        text.append(NSAttributedString(string: tr("Claude a besoin de vous", "Claude needs you"), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ]))
        let label = NSTextField(labelWithAttributedString: text)
        label.alignment = .center
        return label
    }
}

/// Floating mode: the request in a black card above the pet (below it near the top of the screen).
/// Collapsed into a pill saying Claude needs you; hovering or clicking it opens the whole request.
final class RequestCard {
    static let width: CGFloat = 380
    static let padding: CGFloat = 14

    private let panel: KeyablePanel
    private let background = CardBackground()
    private let banner = RequestView.bannerLabel()
    private weak var content: RequestView?
    private var anchor = CGRect.zero
    private var expanded = false

    /// Cursor over the card, and clicks on it (the pill opens on click too). The pet decides.
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    init() {
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = background
        background.addSubview(banner)
        background.onHover = { [weak self] inside in self?.onHover?(inside) }
        background.onClick = { [weak self] in self?.onClick?() }
    }

    var isVisible: Bool { panel.isVisible }
    /// On screen, nil when hidden (the tutorial lights it up with the pet).
    var frame: CGRect? { panel.isVisible ? panel.frame : nil }
    /// While typing in "Autre" only.
    var allowsKey: Bool {
        get { panel.allowsKey }
        set { panel.allowsKey = newValue }
    }
    func resignKey() { if panel.isKeyWindow { panel.resignKey() } }
    var isExpanded: Bool { panel.isVisible && expanded }
    var contentView: NSView? { panel.isVisible ? background : nil }

    /// `anchor`: the pet's frame on screen. Collapsed, the card is the "Claude a besoin de vous" pill.
    func show(_ content: RequestView, near anchor: CGRect, expanded: Bool) {
        self.content = content
        self.anchor = anchor
        self.expanded = expanded
        if content.superview !== background { background.addSubview(content) }
        // The notch fades the view with its panel: coming from there, it may still be transparent.
        content.alphaValue = 1
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        expanded = false
        panel.orderOut(nil)
    }

    /// The pet moved.
    func follow(_ anchor: CGRect) {
        guard panel.isVisible else { return }
        self.anchor = anchor
        layout()
    }

    /// The content changed height (next question).
    func contentResized() {
        guard panel.isVisible else { return }
        layout()
    }

    private func layout() {
        guard let content else { return }
        let pad = Self.padding
        var size: CGSize
        if expanded {
            let h = content.height(for: Self.width - 2 * pad)
            content.frame = CGRect(x: pad, y: pad, width: Self.width - 2 * pad, height: h)
            size = CGSize(width: Self.width, height: h + 2 * pad)
        } else {
            size = CGSize(width: ceil(banner.intrinsicContentSize.width) + 32, height: 30)
        }
        let bannerHeight = banner.intrinsicContentSize.height
        banner.frame = CGRect(x: 0, y: (30 - bannerHeight) / 2, width: size.width, height: bannerHeight)
        content.isHidden = !expanded
        banner.isHidden = expanded
        background.radius = expanded ? 16 : 15
        size.width = max(size.width, 40)

        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? anchor
        var frame = CGRect(x: anchor.midX - size.width / 2, y: anchor.maxY + 2, width: size.width, height: size.height)
        if frame.maxY > visible.maxY { frame.origin.y = anchor.minY - 2 - size.height }
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height)
        // Straight to the new size: a window frame animation waits on the display, and stalls while it sleeps.
        panel.setFrame(frame, display: true)
        background.needsDisplay = true
    }
}

/// Black rounded background of the card, which reports hover and clicks.
final class CardBackground: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var radius: CGFloat = 16

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(white: 0.04, alpha: 0.97).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The "Autre" text field: dark, borderless, and it asks for the keyboard when clicked, since its
/// window only accepts it while typing.
final class OtherField: NSTextField {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The cell first: replacing it later would drop everything set below.
        cell = InsetTextFieldCell(textCell: "")
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        textColor = .white
        font = .systemFont(ofSize: 12.5)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        layer?.cornerRadius = 8
        placeholderAttributedString = NSAttributedString(string: tr("Tapez votre propre réponse ici", "Type your own answer here"), attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.white.withAlphaComponent(0.4),
        ])
        isEditable = true
        isSelectable = true
        (cell as? NSTextFieldCell)?.isScrollable = true
        (cell as? NSTextFieldCell)?.wraps = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// Text inset inside the field's rounded background, vertically centered.
final class InsetTextFieldCell: NSTextFieldCell {
    private func inset(_ rect: NSRect) -> NSRect {
        let h = cellSize(forBounds: rect).height
        return NSRect(x: rect.minX + 10, y: rect.minY + (rect.height - h) / 2, width: rect.width - 20, height: h)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { inset(rect) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: inset(rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
}

/// A panel that becomes key (gets the keyboard, without activating the app) only when allowed.
final class KeyablePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

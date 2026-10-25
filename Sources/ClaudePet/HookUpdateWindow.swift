import AppKit

/// Offered at launch when the hooks in settings.json come from another version of the app: what an
/// install would change, then Update or Later. Nothing is written before Update, which goes through
/// `HookSetup.install` (backup included), as the settings' button does. Drawn like the settings window.
final class HookUpdateController: NSObject, NSWindowDelegate {
    enum Phase: Equatable {
        case idle, updating, error(String), success(String)
    }

    /// Runs the install; returns the line to show once done, or throws.
    var onUpdate: (() throws -> String)?
    /// Later, Esc, ⌘W or the close button: the integrator remembers it for this version.
    var onLater: (() -> Void)?
    /// The window is gone, whatever the reason.
    var onFinish: (() -> Void)?

    let window = HookUpdateWindow()
    let view = HookUpdateView()
    let footer = HookUpdateFooter()
    private let scrollView = NSScrollView()
    private let strip = TitlebarStrip()
    private(set) var phase = Phase.idle
    /// Set once Update or Later has been chosen (or the window is closed by the app), so that closing
    /// the window does not count as Later a second time.
    private var decided = false
    private var placed = false
    /// Quitting closes the window too, and that is no answer.
    private var terminating = false

    var stateName: String {
        switch phase {
        case .idle: return "open"
        case .updating: return "updating"
        case .error: return "failed"
        case .success: return "updated"
        }
    }

    init(changes: [HookSetup.Change], version: String, settingsPath: String) {
        super.init()
        view.changes = changes
        view.version = version
        view.settingsPath = settingsPath
        view.onResize = { [weak self] in self?.resize() }
        scrollView.documentView = view
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // The view leaves room for the titlebar itself: an automatic inset would make it taller than its window.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.scrollerInsets = NSEdgeInsets(top: TitlebarStrip.height, left: 0, bottom: 0, right: 0)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: HookUpdateView.width, height: 400))
        footer.frame = CGRect(x: 0, y: 0, width: HookUpdateView.width, height: HookUpdateFooter.height)
        scrollView.frame = CGRect(x: 0, y: HookUpdateFooter.height, width: HookUpdateView.width, height: 400 - HookUpdateFooter.height)
        strip.frame = CGRect(x: 0, y: 400 - TitlebarStrip.height, width: HookUpdateView.width, height: TitlebarStrip.height)
        footer.autoresizingMask = [.width, .maxYMargin]
        scrollView.autoresizingMask = [.width, .height]
        strip.autoresizingMask = [.width, .minYMargin]
        [scrollView, footer, strip].forEach(container.addSubview)
        window.contentView = container
        window.delegate = self
        window.onCancel = { [weak self] in self?.later() }
        window.onReturn = { [weak self] in self?.update() }
        footer.updateButton.onClick = { [weak self] in self?.update() }
        footer.laterButton.onClick = { [weak self] in self?.later() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.terminating = true
        }
        apply()
    }

    func show() {
        resize()
        if !placed {
            placed = true
            window.center()
        }
        // An accessory app is never active by itself: bring it forward, or the window opens behind.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes without counting as Later (the hooks were updated elsewhere, or a test).
    func dismiss() {
        decided = true
        window.close()
    }

    /// The settings' own buttons may have changed the file meanwhile.
    func update(changes: [HookSetup.Change]) {
        guard phase == .idle || isError else { return }
        view.changes = changes
        resize()
    }

    /// Tests: the controls by name, as clicks would.
    func press(_ name: String) {
        switch name {
        case "update": footer.updateButton.press()
        case "later": footer.laterButton.press()
        case "details": view.detailsButton.onClick?()
        // The close button (or Esc): counts as Later.
        case "close": window.performClose(nil)
        default: break
        }
    }

    /// The window as it is on screen; the content scrolls if it is taller than the screen.
    func snapshot(to path: String) {
        resize()
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Flow

    private var isError: Bool { if case .error = phase { return true } else { return false } }

    private func update() {
        guard phase == .idle || isError else { return }
        setPhase(.updating)
        // Draw "updating" before the (synchronous) install blocks the main thread.
        window.display()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            do {
                let note = try self.onUpdate?() ?? ""
                self.decided = true
                self.setPhase(.success(note))
                // Long enough to read the backup's name.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.window.close() }
            } catch {
                self.setPhase(.error(error.localizedDescription))
            }
        }
    }

    private func later() {
        guard phase == .idle || isError else { return }
        decided = true
        onLater?()
        window.close()
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        apply()
    }

    private func apply() {
        footer.phase = phase
        view.locked = !(phase == .idle || isError)
        if case .error(let message) = phase { view.error = message } else { view.error = nil }
        resize()
    }

    /// All of the content when it fits, or a shorter window that scrolls. Grows downwards.
    private func resize() {
        view.frame = CGRect(x: 0, y: 0, width: HookUpdateView.width, height: view.preferredHeight)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 800)
        let height = min(view.preferredHeight + HookUpdateFooter.height, visible.height - 60)
        guard abs(window.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = CGSize(width: HookUpdateView.width, height: height)
        // Grown past the bottom of the screen (the details): slide up, buttons always on screen.
        frame.origin.y = min(max(frame.origin.y, visible.minY + 20), visible.maxY - height)
        window.setFrame(frame, display: window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing it without choosing means "not now", like Later. Later in the run loop: when the app
        // quits, willTerminate comes first and the closing is not an answer.
        let closedWithoutAnswer = !decided && (phase == .idle || isError)
        decided = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminating else { return }
            if closedWithoutAnswer { self.onLater?() }
            NSApp.deactivate()
            self.onFinish?()
        }
    }
}

// MARK: - Window

final class HookUpdateWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: HookUpdateView.width, height: 400),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = tr("Mise à jour des hooks", "Hook update")
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = NSColor(name: nil) { PanelTheme.current($0).background }
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        // Return and Enter update, like a default button.
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }

    // No main menu in an accessory app: the usual shortcuts are handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "w": onCancel?()
        case "q": NSApp.terminate(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

// MARK: - Content

final class HookUpdateView: NSView {
    static let width = SettingsView.width
    private static let pad: CGFloat = 24
    private static let tileSize: CGFloat = 46
    private static let rowHeight: CGFloat = 48

    var changes: [HookSetup.Change] = [] { didSet { changed() } }
    var version = "dev" { didSet { needsDisplay = true } }
    var settingsPath = "" { didSet { changed() } }
    /// While updating or done: the details stay where they are.
    var locked = false
    /// The last failed update, in full (paths are long for the footer).
    var error: String? { didSet { if oldValue != error { changed() } } }
    var onResize: (() -> Void)?
    let detailsButton = FooterButton(title: "", shortcut: "")
    private var showsDetails = false { didSet { changed() } }
    private let petIcon = SpriteComposer.frame(state: .idle, tool: nil, t: 0, bubble: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(detailsButton)
        detailsButton.onClick = { [weak self] in
            guard let self, !self.locked else { return }
            self.showsDetails.toggle()
        }
        changed()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private var inner: CGFloat { Self.width - 2 * Self.pad }

    private func changed() {
        detailsButton.title = showsDetails ? tr("Masquer les commandes", "Hide the commands") : tr("Voir les commandes", "Show the commands")
        needsLayout = true
        needsDisplay = true
        onResize?()
    }

    // MARK: Layout

    private struct Layout {
        /// Where the settings' header sits on screen (40 under the traffic lights, plus the titlebar).
        var headerY: CGFloat = 40 + TitlebarStrip.height
        var introY: CGFloat = 0, introHeight: CGFloat = 0
        var banner: CGRect?
        var sectionY: CGFloat = 0, cardY: CGFloat = 0, cardHeight: CGFloat = 0
        /// Top of each row, and the height of its diff (0 when hidden).
        var rows: [(y: CGFloat, diff: CGFloat)] = []
        var noteY: CGFloat = 0, noteHeight: CGFloat = 0
        var height: CGFloat = 0
    }

    private var diffWidth: CGFloat { inner - 24 - 16 }

    private func computeLayout() -> Layout {
        let theme = PanelTheme.light
        var l = Layout()
        l.introY = l.headerY + Self.tileSize + 18
        l.introHeight = textHeight(introText(theme), width: inner - 4)
        l.sectionY = l.introY + l.introHeight + 22
        if let error {
            let h = textHeight(rich(error, size: 12, theme.secondary), width: inner - 24)
            l.banner = CGRect(x: Self.pad, y: l.sectionY - 6, width: inner, height: 12 + 17 + 2 + h + 12)
            l.sectionY = l.banner!.maxY + 18
        }
        l.cardY = l.sectionY + 24
        var y = l.cardY
        for change in changes {
            let diff = showsDetails ? textHeight(diffText(change, theme), width: diffWidth) : 0
            l.rows.append((y, diff))
            y += Self.rowHeight + (showsDetails ? diff + 16 + 10 : 0)
        }
        l.cardHeight = y - l.cardY
        l.noteY = y + 12
        l.noteHeight = textHeight(noteText(theme), width: inner - 4)
        l.height = l.noteY + l.noteHeight + 20
        return l
    }

    var preferredHeight: CGFloat { ceil(computeLayout().height) }

    private func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: 10000), options: .usesLineFragmentOrigin).height)
    }

    override func layout() {
        super.layout()
        let l = computeLayout(), size = detailsButton.fittingSize
        detailsButton.frame = CGRect(x: Self.pad + inner - size.width + 6, y: l.sectionY - 5, width: size.width, height: size.height)
    }

    // MARK: Text

    private func introText(_ theme: PanelTheme) -> NSAttributedString {
        rich(tr("Les hooks de `\(settingsPath)` ont été écrits par une autre version du pet : sans mise à jour, il peut mal suivre Claude. Rien n'est écrit sans ton accord, et le fichier est sauvegardé avant, comme à chaque installation. Les hooks des autres apps ne sont pas touchés.",
                "The hooks in `\(settingsPath)` were written by another version of the pet: without an update, it may follow Claude badly. Nothing is written without your consent, and the file is backed up first, as for every install. Other apps' hooks are left alone."),
             size: 12.5, theme.secondary)
    }

    private func noteText(_ theme: PanelTheme) -> NSAttributedString {
        tr("Plus tard : redemandé à la prochaine version. D'ici là, le bouton de Réglages › Claude Code fait la même chose. Les sessions déjà ouvertes ne voient les changements qu'après redémarrage.",
           "Later: asked again with the next version. Until then, the button in Settings › Claude Code does the same. Sessions already open only see changes after a restart.")
            .attributed(.systemFont(ofSize: 11.5), theme.tertiary, wraps: true)
    }

    private func name(_ change: HookSetup.Change) -> String {
        switch change.target {
        case HookSetup.Change.statusLine: return tr("Ligne de statut", "Status line")
        case HookSetup.Change.bridge: return tr("Script du relais", "Bridge script")
        default: return change.target
        }
    }

    private func detail(_ change: HookSetup.Change) -> String {
        switch (change.target, change.kind) {
        case (HookSetup.Change.statusLine, _): return tr("Repasse par le relais du pet, puis lance ta commande", "Goes through the pet's bridge again, then runs your command")
        case (HookSetup.Change.bridge, .added): return tr("Absent : il sera réécrit", "Missing: it will be written again")
        case (HookSetup.Change.bridge, _): return tr("Contenu mis à jour", "Contents updated")
        case (_, .added): return tr("Nouveau hook de cette version", "New hook in this version")
        case (_, .removed): return tr("Plus utilisé par cette version : retiré", "No longer used by this version: removed")
        case (_, .modified):
            let fields = change.fields.map { field -> String in
                switch field {
                case "command": return tr("commande", "command")
                case "timeout": return tr("délai", "timeout")
                case "matcher": return tr("filtre d'outils", "tool matcher")
                case "count": return tr("nombre d'entrées", "number of entries")
                default: return tr("autres champs", "other fields")
                }
            }
            return tr("Modifié : ", "Changed: ") + fields.joined(separator: ", ")
        }
    }

    private func badge(_ kind: HookSetup.Change.Kind) -> (String, NSColor) {
        switch kind {
        case .added: return (tr("Ajouté", "Added"), PanelTheme.gaugeColors[2])
        case .removed: return (tr("Retiré", "Removed"), PanelTheme.danger)
        case .modified: return (tr("Modifié", "Changed"), PanelTheme.warning)
        }
    }

    /// Old and new, line by line: removed lines in red, added ones in green, the rest dimmed.
    private func diffText(_ change: HookSetup.Change, _ theme: PanelTheme) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let style = NSMutableParagraphStyle()
        // Commands are long single lines: wrap anywhere, under the text rather than the sign.
        style.lineBreakMode = .byCharWrapping
        style.headIndent = ("+ " as NSString).size(withAttributes: [.font: font]).width
        style.paragraphSpacing = 3
        let lines = Self.diff(lines(change.old), lines(change.new))
        let text = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let color: NSColor
            switch line.sign {
            case "-": color = PanelTheme.danger
            case "+": color = PanelTheme.gaugeColors[2]
            default: color = theme.tertiary
            }
            let sign = line.sign == "-" ? "−" : line.sign == "+" ? "+" : " "
            text.append(NSAttributedString(string: sign + " " + line.text + (i < lines.count - 1 ? "\n" : ""),
                                           attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        return text
    }

    private func lines(_ text: String?) -> [String] {
        guard let text else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// A plain longest-common-subsequence diff: a handful of lines at most.
    static func diff(_ a: [String], _ b: [String]) -> [(sign: Character, text: String)] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [(sign: Character, text: String)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                out.append((" ", a[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append(("-", a[i])); i += 1
            } else {
                out.append(("+", b[j])); j += 1
            }
        }
        out += a[i...].map { ("-", $0) }
        out += b[j...].map { ("+", $0) }
        return out
    }

    /// Wrapping text where `backticks` mark paths, set in monospace.
    private func rich(_ string: String, size: CGFloat, _ color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        let result = NSMutableAttributedString()
        for (i, part) in string.components(separatedBy: "`").enumerated() {
            result.append(NSAttributedString(string: part, attributes: [
                .font: i % 2 == 1 ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color, .paragraphStyle: style,
            ]))
        }
        return result
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        theme.background.setFill()
        bounds.fill()
        let l = computeLayout(), pad = Self.pad

        drawHeader(theme, y: l.headerY)
        introText(theme).draw(with: CGRect(x: pad + 2, y: l.introY, width: inner - 4, height: l.introHeight + 2), options: .usesLineFragmentOrigin)

        if let banner = l.banner, let error {
            NSBezierPath(roundedRect: banner, xRadius: 11, yRadius: 11).fill(with: PanelTheme.danger.withAlphaComponent(0.12))
            tr("La mise à jour n'a pas abouti", "The update did not complete")
                .attributed(.systemFont(ofSize: 13, weight: .semibold), theme.text)
                .draw(at: CGPoint(x: banner.minX + 12, y: banner.minY + 12), width: banner.width - 24)
            rich(error, size: 12, theme.secondary)
                .draw(with: CGRect(x: banner.minX + 12, y: banner.minY + 31, width: banner.width - 24, height: banner.height - 40),
                      options: .usesLineFragmentOrigin)
        }

        let count = changes.count
        (tr("Ce qui change", "What changes") + " · \(count)")
            .attributed(.systemFont(ofSize: 11, weight: .semibold), theme.tertiary, kern: 0.2)
            .draw(at: CGPoint(x: pad + 2, y: l.sectionY))
        NSBezierPath(roundedRect: CGRect(x: pad, y: l.cardY, width: inner, height: l.cardHeight), xRadius: 11, yRadius: 11).fill(with: theme.card)

        for (i, (change, row)) in zip(changes, l.rows).enumerated() {
            if i > 0 {
                theme.stroke.setFill()
                CGRect(x: pad + 12, y: row.y - 0.5, width: inner - 24, height: 1).fill()
            }
            let (label, color) = badge(change.kind)
            let tag = label.attributed(.systemFont(ofSize: 10.5, weight: .semibold), color.blended(withFraction: 0.25, of: theme.text) ?? color)
            let tagRect = CGRect(x: pad + 12, y: row.y + 10, width: max(62, tag.size().width + 14), height: 18)
            NSBezierPath(roundedRect: tagRect, xRadius: 9, yRadius: 9).fill(with: color.withAlphaComponent(0.18))
            tag.draw(at: CGPoint(x: tagRect.midX - tag.size().width / 2, y: tagRect.minY + (18 - tag.size().height) / 2))

            let x = tagRect.maxX + 12, width = pad + inner - 12 - x
            let isEvent = change.target != HookSetup.Change.statusLine && change.target != HookSetup.Change.bridge
            name(change).attributed(isEvent ? .monospacedSystemFont(ofSize: 12.5, weight: .medium) : .systemFont(ofSize: 13, weight: .medium), theme.text)
                .draw(at: CGPoint(x: x, y: row.y + 9), width: width)
            detail(change).attributed(.systemFont(ofSize: 11), theme.tertiary)
                .draw(at: CGPoint(x: x, y: row.y + 27), width: width)

            guard showsDetails else { continue }
            let box = CGRect(x: pad + 12, y: row.y + Self.rowHeight, width: inner - 24, height: row.diff + 16)
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill(with: theme.background)
            diffText(change, theme).draw(with: CGRect(x: box.minX + 8, y: box.minY + 8, width: diffWidth, height: row.diff + 2),
                                         options: .usesLineFragmentOrigin)
        }

        noteText(theme).draw(with: CGRect(x: pad + 2, y: l.noteY, width: inner - 4, height: l.noteHeight + 2), options: .usesLineFragmentOrigin)
    }

    /// The pet on its little stage tile, then the title in the serif, as in the settings window.
    private func drawHeader(_ theme: PanelTheme, y: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pad = Self.pad
        let tile = CGRect(x: pad, y: y, width: Self.tileSize, height: Self.tileSize)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12)
        theme.card.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [PanelTheme.warning.withAlphaComponent(0.25).cgColor, PanelTheme.warning.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            let center = CGPoint(x: tile.midX, y: tile.midY + 6)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 30, options: [])
        }
        NSGraphicsContext.restoreGraphicsState()
        if let image = petIcon.makeImage() {
            let size = CGSize(width: CGFloat(petIcon.width) * 2, height: CGFloat(petIcon.height) * 2)
            let rect = CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2 + 1, width: size.width, height: size.height)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
        }
        theme.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let x = tile.maxX + 16
        tr("Mettre à jour les hooks ?", "Update the hooks?").attributed(.serif(24, weight: .medium), theme.text)
            .draw(at: CGPoint(x: x, y: y - 2), width: pad + inner - x)
        tr("Claude Pet \(version) les écrit un peu autrement", "Claude Pet \(version) writes them a little differently")
            .attributed(.systemFont(ofSize: 12.5), theme.tertiary)
            .draw(at: CGPoint(x: x, y: y + 29), width: pad + inner - x)
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

// MARK: - Footer

/// Stays at the bottom while the content scrolls: the outcome on the left, Later and Update on the right.
final class HookUpdateFooter: NSView {
    static let height: CGFloat = 60
    let laterButton = PanelPillButton(title: tr("Plus tard", "Later"), style: .secondary)
    let updateButton = PanelPillButton(title: "", style: .primary)
    var phase = HookUpdateController.Phase.idle { didSet { apply() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [laterButton, updateButton].forEach(addSubview)
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private func apply() {
        switch phase {
        case .idle: updateButton.title = tr("Mettre à jour", "Update")
        case .updating: updateButton.title = tr("Mise à jour…", "Updating…")
        case .error: updateButton.title = tr("Réessayer", "Try again")
        case .success: updateButton.title = tr("Mis à jour", "Updated")
        }
        let open: Bool
        switch phase {
        case .idle, .error: open = true
        case .updating, .success: open = false
        }
        updateButton.isEnabled = open
        laterButton.isEnabled = open
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let update = updateButton.fittingSize, later = laterButton.fittingSize
        let updateWidth = max(120, update.width), laterWidth = max(96, later.width)
        updateButton.frame = CGRect(x: bounds.width - 24 - updateWidth, y: (bounds.height - update.height) / 2, width: updateWidth, height: update.height)
        laterButton.frame = CGRect(x: updateButton.frame.minX - 8 - laterWidth, y: updateButton.frame.minY, width: laterWidth, height: later.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        theme.background.setFill()
        bounds.fill()
        theme.stroke.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let text: NSAttributedString
        switch phase {
        case .idle:
            text = tr("Rien n'est écrit avant « Mettre à jour ».", "Nothing is written before “Update”.")
                .attributed(.systemFont(ofSize: 11.5), theme.tertiary, wraps: true)
        case .updating:
            text = tr("Écriture des réglages de Claude Code…", "Writing Claude Code's settings…")
                .attributed(.systemFont(ofSize: 11.5, weight: .medium), theme.secondary, wraps: true)
        case .error:
            // In full above the list.
            text = tr("Échec : détails ci-dessus.", "Failed: details above.").attributed(.systemFont(ofSize: 11.5), PanelTheme.danger, wraps: true)
        case .success(let note):
            let done = NSMutableAttributedString(attributedString: "✓  ".attributed(.systemFont(ofSize: 11.5, weight: .bold), PanelTheme.gaugeColors[2], wraps: true))
            done.append(note.attributed(.systemFont(ofSize: 11.5), theme.secondary, wraps: true))
            text = done
        }
        let width = laterButton.frame.minX - 24 - 16
        let height = min(bounds.height - 8, ceil(text.boundingRect(with: CGSize(width: width, height: 200), options: .usesLineFragmentOrigin).height))
        text.draw(with: CGRect(x: 26, y: (bounds.height - height) / 2, width: width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

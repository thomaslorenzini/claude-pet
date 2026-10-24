import AppKit

/// What the first-launch window describes. Filled in by the integrator from the real settings, so
/// the text matches what the installation will actually do.
struct OnboardingPlan {
    var settingsPath: String          // "~/.claude/settings.json" (display form)
    var existingStatusLine: String?   // the user's current status line command, nil if none
    var hookCount: Int                // 13
}

/// The first-launch window: says plainly what the installation changes, then Accept or Refuse.
/// Nothing is written before Accept. Drawn by hand in the menu bar panel's colors (`PanelTheme`),
/// all in `draw(_:)`, so `snapshot(to:)` renders it even off screen.
final class OnboardingWindowController: NSObject {
    enum Phase: Equatable {
        case idle, installing, error(String), success
    }

    /// Runs the installation with the two checkboxes. Return nil on success, or an error message to show.
    var onAccept: ((_ readQuotas: Bool, _ launchAtLogin: Bool) -> String?)?
    var onRefuse: (() -> Void)?

    let window = OnboardingPanel()
    let view: OnboardingView
    private var animationTimer: Timer?
    private var t = 0
    private var shownState: PetState?

    init(plan: OnboardingPlan) {
        view = OnboardingView(plan: plan)
        super.init()
        window.contentView = view
        window.onCancel = { [weak self] in self?.refuse() }
        window.onReturn = { [weak self] in self?.accept() }
        view.onAccept = { [weak self] in self?.accept() }
        view.onRefuse = { [weak self] in self?.refuse() }
        resize(center: true)
        renderSprite()
    }

    func show() {
        resize(center: true)
        // The app is an accessory (no Dock icon): it must come forward itself for the window to get the keyboard.
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        window.invalidateShadow()
        syncAnimation()
    }

    /// Shows the confirmation for a moment, fades the window out, then calls `completion`.
    func showSuccessAndClose(completion: @escaping () -> Void) {
        setPhase(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return completion() }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.window.animator().alphaValue = 0
            }, completionHandler: {
                self.animationTimer?.invalidate()
                self.animationTimer = nil
                self.window.orderOut(nil)
                self.window.alphaValue = 1
                completion()
            })
        }
    }

    /// Renders the window content to PNG, even off screen (tests, `--onboarding-snapshot`).
    func snapshot(to path: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Tests: puts the window in a given state without running anything.
    func preview(_ phase: Phase, readQuotas: Bool = false, launchAtLogin: Bool = true) {
        view.readQuotas = readQuotas
        view.launchAtLogin = launchAtLogin
        setPhase(phase)
    }

    // MARK: Flow

    private func accept() {
        switch view.phase {
        case .idle, .error: break
        case .installing, .success: return
        }
        setPhase(.installing)
        // Draw "installing" before the (synchronous) installation blocks the main thread.
        view.display()
        let readQuotas = view.readQuotas, launchAtLogin = view.launchAtLogin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let error = self.onAccept?(readQuotas, launchAtLogin) ?? nil
            if let error {
                self.setPhase(.error(error))
            } else if self.view.phase == .installing {
                // The integrator then calls `showSuccessAndClose`; the confirmation is already on screen.
                self.setPhase(.success)
            }
        }
    }

    private func refuse() {
        // Once written, refusing means nothing: uninstalling lives in the settings.
        guard view.phase != .installing, view.phase != .success else { return }
        onRefuse?()
    }

    private func setPhase(_ phase: Phase) {
        view.phase = phase
        resize(center: false)
        renderSprite()
        syncAnimation()
    }

    /// Tests: pretends the screen leaves this much height (`--max-height`).
    var heightLimit: CGFloat?

    /// Keeps the top edge in place when the error banner changes the height, and the whole window on screen.
    private func resize(center: Bool) {
        let visible = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 12
        view.availableHeight = heightLimit ?? visible.height - 2 * margin
        let size = NSSize(width: OnboardingView.width, height: view.preferredHeight)
        var frame = window.frame
        if center || frame.width == 0 {
            // A little above center, like system alerts.
            frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.06,
                           width: size.width, height: size.height)
        } else {
            guard abs(frame.height - size.height) > 0.5 else { return }
            frame.origin.y += frame.height - size.height
            frame.size = size
        }
        // Top first: if it still cannot fit, the title stays visible and Return still accepts.
        frame.origin.y = max(frame.origin.y, visible.minY + margin)
        frame.origin.y = min(frame.origin.y, visible.maxY - margin - size.height)
        window.setFrame(frame, display: window.isVisible)
        view.frame = CGRect(origin: .zero, size: size)
        window.invalidateShadow()
    }

    // MARK: Pet

    private var petState: PetState {
        switch view.phase {
        case .idle, .error: return .waving
        case .installing: return .thinking
        case .success: return .happy
        }
    }

    private func syncAnimation() {
        if shownState != petState {
            shownState = petState
            t = 0
            renderSprite()
        }
        animationTimer?.invalidate()
        animationTimer = nil
        guard window.isVisible else { return }
        let interval = 1 / SpriteComposer.fps(state: petState, tool: nil)
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
        view.canvas = SpriteComposer.frame(state: petState, tool: nil, t: t, bubble: false)
    }
}

// MARK: - Window

final class OnboardingPanel: NSWindow {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        // Return and Enter accept, like a default button.
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Q and ⌘W both mean "not now": the app quits and asks again next time.
        if event.modifierFlags.contains(.command), ["q", "w"].contains(event.charactersIgnoringModifiers ?? "") {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Content

final class OnboardingView: NSView {
    static let width: CGFloat = 560
    private static let pad: CGFloat = 24

    /// How tightly the window is packed. It must fit the screen, buttons included: a screen of 900 pt with
    /// the Dock leaves about 800, and the regular layout is taller.
    private struct Density {
        var header: CGFloat = 128
        var spriteScale: CGFloat = 4
        var kicker = true
        var sectionGap: CGFloat = 24
        var itemGap: CGFloat = 11
        /// Last resort: the list keeps its titles, the checkboxes keep their text (they ask for consent).
        var bodies = true
        var optionPad: CGFloat = 14

        static let regular = Density()
        static let compact = Density(header: 96, spriteScale: 3, kicker: false, sectionGap: 16, itemGap: 6, optionPad: 10)
        static let minimal = Density(header: 96, spriteScale: 3, kicker: false, sectionGap: 16, itemGap: 9, bodies: false, optionPad: 10)
    }

    /// Set by the controller from the screen; the densest layout that fits wins.
    var availableHeight = CGFloat.greatestFiniteMagnitude {
        didSet { if oldValue != availableHeight { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    }

    private var density: Density {
        let theme = PanelTheme.current(effectiveAppearance)
        return [Density.regular, .compact].first { layout(theme, $0).height <= availableHeight } ?? .minimal
    }

    var canvas = PixelCanvas() { didSet { setNeedsDisplay(spriteRect.insetBy(dx: -4, dy: -4)) } }
    var phase = OnboardingWindowController.Phase.idle { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var readQuotas = false { didSet { needsDisplay = true } }
    /// Suggested, so checked by default: closed after a restart, the pet would miss everything without a word.
    var launchAtLogin = true { didSet { needsDisplay = true } }
    var onAccept: (() -> Void)?
    var onRefuse: (() -> Void)?

    private let plan: OnboardingPlan
    private var hovered: Control? { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var pressed: Control? { didSet { if oldValue != pressed { needsDisplay = true } } }

    private enum Control { case accept, refuse, login, quotas }

    init(plan: OnboardingPlan) {
        self.plan = plan
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Text

    private struct Item {
        let icon: Pixels
        let title: String
        let body: String
    }

    private var items: [Item] {
        let statusLine: String
        if let command = plan.existingStatusLine?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            let shown = command.count > 48 ? String(command.prefix(47)) + "…" : command
            statusLine = tr("Il passe au pet les quotas et le contexte, puis lance ta commande actuelle (`\(shown)`) : la ligne affiche la même chose qu'avant.",
                            "It hands quotas and context to the pet, then runs your current command (`\(shown)`): the line shows the same thing as before.")
        } else {
            statusLine = tr("Il passe au pet les quotas et le contexte. Tu n'as pas de ligne de statut aujourd'hui : elle n'affichera rien de plus.",
                            "It hands quotas and context to the pet. You have no status line today: it will show nothing extra.")
        }
        return [
            Item(icon: .plug,
                 title: tr("\(plan.hookCount) hooks dans les réglages de Claude Code", "\(plan.hookCount) hooks in Claude Code's settings"),
                 body: tr("Ajoutés à `\(plan.settingsPath)`, pour toutes les sessions : terminal et onglet Code de Claude Desktop. Chacun est marqué pour pouvoir être retiré ; les hooks des autres apps ne sont pas touchés. Le fichier est sauvegardé avant chaque écriture, et sa version d'origine peut être remise à tout moment depuis Réglages\u{00A0}›\u{00A0}Claude\u{00A0}Code\u{00A0}›\u{00A0}Restaurer.",
                          "Added to `\(plan.settingsPath)`, for every session: terminal and the Code tab of Claude Desktop. Each one is tagged so it can be removed; other apps' hooks are left alone. The file is backed up before each write, and its original version can be put back any time from Settings\u{00A0}›\u{00A0}Claude\u{00A0}Code\u{00A0}›\u{00A0}Restore.")),
            Item(icon: .terminal,
                 title: tr("La ligne de statut passe par un petit relais", "The status line goes through a small bridge"),
                 body: statusLine),
            Item(icon: .folder,
                 title: tr("Quelques fichiers à lui", "A few files of its own"),
                 body: tr("Dans `~/Library/Application Support/claude-pet/` : l'adresse du pet, le script relais et ta ligne de statut d'origine, mise de côté.",
                          "In `~/Library/Application Support/claude-pet/`: the pet's address, the bridge script and your original status line, set aside.")),
            Item(icon: .lock,
                 title: tr("Les hooks restent sur ton Mac", "The hooks stay on your Mac"),
                 body: tr("Pet fermé, ils s'arrêtent aussitôt, sans rien lancer. Sinon, ils ne parlent qu'au pet, sur `127.0.0.1`.",
                          "With the pet closed, they exit at once without starting anything. Otherwise they only talk to the pet, on `127.0.0.1`.")),
            Item(icon: .bubble,
                 title: tr("Tu pourras répondre à Claude depuis le pet", "You can answer Claude from the pet"),
                 body: tr("Les demandes de permission et les questions de Claude s'y affichent aussi. Répondre dans Claude marche toujours : la première réponse l'emporte.",
                          "Claude's permission requests and questions show up there too. Answering in Claude still works: the first answer wins.")),
            Item(icon: .undo,
                 title: tr("Tout se désinstalle", "Everything can be uninstalled"),
                 body: tr("Depuis les réglages du pet : les hooks sont retirés et ta ligne de statut d'origine est remise.",
                          "From the pet's settings: the hooks are removed and your original status line is put back.")),
        ]
    }

    private struct Option {
        let control: Control
        let title: String
        let tag: String
        let body: String
    }

    private var options: [Option] {
        [Option(control: .login,
                title: tr("Ouvrir au démarrage du Mac", "Open at login"),
                tag: tr("conseillé", "recommended"),
                body: tr("Sinon, après un redémarrage, le pet ne voit plus rien jusqu'à ce que tu l'ouvres.",
                         "Otherwise, after a restart, the pet sees nothing until you open it.")),
         Option(control: .quotas,
                title: tr("Lire les quotas avec le compte Claude Code", "Read quotas with the Claude Code account"),
                tag: tr("facultatif", "optional"),
                body: quotasBody)]
    }

    private func isOn(_ control: Control) -> Bool { control == .login ? launchAtLogin : readQuotas }

    private func flip(_ control: Control) {
        if control == .login { launchAtLogin.toggle() } else if control == .quotas { readQuotas.toggle() }
    }

    private var quotasBody: String {
        tr("Le pet lit le jeton de Claude Code dans le Trousseau (macOS te demandera l'accès) pour demander ton utilisation à `api.anthropic.com`, toutes les 5 min. Le jeton reste en mémoire, jamais écrit. S'il a expiré, le pet lance `claude` en arrière-plan pour qu'il le renouvelle, sans consommer de quota.",
           "The pet reads Claude Code's token from the Keychain (macOS will ask for access) to fetch your usage from `api.anthropic.com`, every 5 min. The token stays in memory, never written. If it has expired, the pet runs `claude` in the background to renew it, without using any quota.")
    }

    private var acceptTitle: String {
        switch phase {
        case .error: return tr("Réessayer", "Try again")
        case .installing: return tr("Installation…", "Installing…")
        default: return tr("Accepter", "Accept")
        }
    }
    private var refuseTitle: String { tr("Refuser", "Refuse") }

    // MARK: Layout

    private struct Layout {
        var items: [(icon: CGRect, title: CGPoint, body: CGRect)] = []
        var sectionY: CGFloat = 0
        var options: [(card: CGRect, checkbox: CGRect, text: CGRect)] = []
        var banner: CGRect?
        var accept = CGRect.zero
        var refuse = CGRect.zero
        var footerY: CGFloat = 0
        var height: CGFloat = 0
    }

    private var textX: CGFloat { Self.pad + 30 + 14 }
    private var textWidth: CGFloat { Self.width - textX - Self.pad }

    private func layout(_ theme: PanelTheme) -> Layout { layout(theme, density) }

    private func layout(_ theme: PanelTheme, _ d: Density) -> Layout {
        var l = Layout()
        let pad = Self.pad
        var y = pad + d.header + d.sectionGap
        l.sectionY = y
        y += 26
        for item in items {
            let h = d.bodies ? height(of: rich(item.body, size: 12, theme.secondary, theme: theme), width: textWidth) : 0
            l.items.append((icon: CGRect(x: pad, y: y, width: 30, height: 30),
                            // Alone, the title sits level with its icon.
                            title: CGPoint(x: textX, y: h > 0 ? y - 1 : y + 6),
                            body: CGRect(x: textX, y: y + 18, width: textWidth, height: h)))
            y += max(30, 18 + h) + d.itemGap
        }
        y += 3
        let optionTextWidth = Self.width - 2 * pad - 14 - 20 - 12 - 14
        for option in options {
            let bodyHeight = height(of: rich(option.body, size: 11.5, theme.tertiary, theme: theme), width: optionTextWidth)
            let optionHeight = d.optionPad + 18 + bodyHeight + d.optionPad
            let checkbox = CGRect(x: pad + 14, y: y + d.optionPad, width: 20, height: 20)
            l.options.append((card: CGRect(x: pad, y: y, width: Self.width - 2 * pad, height: optionHeight),
                              checkbox: checkbox,
                              text: CGRect(x: checkbox.maxX + 12, y: y + d.optionPad, width: optionTextWidth, height: 18 + bodyHeight)))
            y += optionHeight + 8
        }
        y += d.optionPad - 4

        if case .error(let message) = phase {
            let text = rich(message, size: 12, theme.text, theme: theme)
            let h = height(of: text, width: Self.width - 2 * pad - 28 - 30)
            l.banner = CGRect(x: pad, y: y, width: Self.width - 2 * pad, height: 12 + 17 + 2 + h + 12)
            y += l.banner!.height + 16
        }

        l.footerY = y
        let accept = buttonWidth(acceptTitle, shortcut: "↩")
        let refuse = buttonWidth(refuseTitle, shortcut: "esc")
        l.accept = CGRect(x: Self.width - pad - accept, y: y, width: accept, height: 34)
        l.refuse = CGRect(x: l.accept.minX - 10 - refuse, y: y, width: refuse, height: 34)
        l.height = y + 34 + pad
        return l
    }

    var preferredHeight: CGFloat { ceil(layout(PanelTheme.current(effectiveAppearance)).height) }

    private var spriteRect: CGRect {
        let d = density
        let size = CGSize(width: CGFloat(PixelCanvas.standardWidth) * d.spriteScale,
                          height: CGFloat(PixelCanvas.standardHeight) * d.spriteScale)
        return CGRect(x: Self.pad + 14, y: Self.pad + (d.header - size.height) / 2 + 2, width: size.width, height: size.height)
    }

    private func buttonWidth(_ title: String, shortcut: String) -> CGFloat {
        let w = attributed(title, .systemFont(ofSize: 13, weight: .semibold), .black).size().width
            + attributed(shortcut, .systemFont(ofSize: 11, weight: .medium), .black).size().width
        return max(96, ceil(w) + 18 * 2 + 8)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        let l = layout(theme)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        theme.background.setFill()
        shape.fill()
        theme.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        drawHeader(theme)

        attributed(tr("Ce que l'installation va faire", "What the installation will do").uppercased(),
                   .systemFont(ofSize: 11, weight: .semibold), theme.tertiary, kern: 0.6)
            .draw(at: CGPoint(x: Self.pad + 2, y: l.sectionY))

        for (item, frame) in zip(items, l.items) {
            drawIconTile(item.icon, in: frame.icon, theme: theme)
            attributed(item.title, .systemFont(ofSize: 13, weight: .semibold), theme.text)
                .draw(at: frame.title)
            if frame.body.height > 0 {
                rich(item.body, size: 12, theme.secondary, theme: theme)
                    .draw(with: frame.body, options: [.usesLineFragmentOrigin])
            }
        }

        for (option, frame) in zip(options, l.options) { drawOption(option, frame, theme: theme) }
        if let banner = l.banner, case .error(let message) = phase { drawBanner(message, in: banner, theme: theme) }
        drawFooter(l, theme: theme)
    }

    private func drawHeader(_ theme: PanelTheme) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let d = density
        let card = CGRect(x: Self.pad, y: Self.pad, width: Self.width - 2 * Self.pad, height: d.header)
        let shape = NSBezierPath(roundedRect: card, xRadius: 13, yRadius: 13)
        theme.card.setFill()
        shape.fill()

        // Same stage as the menu bar panel: a faint pixel grid, a warm glow where the pet stands.
        ctx.saveGState()
        shape.addClip()
        theme.text.withAlphaComponent(0.06).setFill()
        for y in stride(from: card.minY + 6, to: card.maxY, by: 8) {
            for x in stride(from: card.minX + 6, to: card.maxX, by: 8) {
                CGRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        let sprite = spriteRect
        let glowColor = phase == .success ? PanelTheme.gaugeColors[2] : theme.accent
        if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [glowColor.withAlphaComponent(0.22).cgColor, glowColor.withAlphaComponent(0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            let center = CGPoint(x: sprite.midX, y: sprite.midY + 8)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 80, options: [])
        }
        ctx.restoreGState()

        if let image = canvas.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: sprite.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: sprite.minX, y: 0, width: sprite.width, height: sprite.height))
            ctx.restoreGState()
        }

        let x = sprite.maxX + 18, width = card.maxX - x - 20
        let kicker = attributed(tr("Claude Pet · premier lancement", "Claude Pet · first launch"),
                                .systemFont(ofSize: 11, weight: .medium), theme.tertiary)
        let title = attributed(tr("Bonjour ! Avant de commencer…", "Hi! Before we start…"),
                               onboardingSerif(24, weight: .medium), theme.text)
        let subtitle = attributed(tr("Pour suivre Claude, le pet doit changer quelques réglages. Voici exactement lesquels. Rien n'est écrit avant que tu acceptes.",
                                     "To follow Claude, the pet needs to change a few settings. Here is exactly which. Nothing is written until you accept."),
                                  .systemFont(ofSize: 12.5), theme.secondary, wraps: true, lineSpacing: 2)
        let subtitleHeight = height(of: subtitle, width: width)
        let kickerHeight: CGFloat = d.kicker ? 14 + 6 : 0
        let block = kickerHeight + title.size().height + 5 + subtitleHeight
        var y = card.minY + (card.height - block) / 2
        if d.kicker {
            let dot = CGRect(x: x, y: y + 4, width: 6, height: 6)
            theme.accent.setFill()
            NSBezierPath(ovalIn: dot).fill()
            kicker.draw(at: CGPoint(x: dot.maxX + 6, y: y))
        }
        y += kickerHeight
        title.draw(at: CGPoint(x: x - 1, y: y))
        y += title.size().height + 5
        subtitle.draw(with: CGRect(x: x, y: y, width: width, height: subtitleHeight), options: [.usesLineFragmentOrigin])
    }

    private func drawIconTile(_ icon: Pixels, in rect: CGRect, theme: PanelTheme) {
        theme.accent.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        // Pixel icons, 2 pt per pixel: the same material as the pet.
        let size = CGFloat(icon.rows.count) * 2
        let origin = CGPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
        theme.accent.setFill()
        for (y, row) in icon.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                CGRect(x: origin.x + CGFloat(x) * 2, y: origin.y + CGFloat(y) * 2, width: 2, height: 2).fill()
            }
        }
    }

    private func drawOption(_ option: Option, _ l: (card: CGRect, checkbox: CGRect, text: CGRect), theme: PanelTheme) {
        let enabled = phase == .idle || isError
        let card = NSBezierPath(roundedRect: l.card, xRadius: 11, yRadius: 11)
        theme.card.setFill()
        card.fill()
        if hovered == option.control, enabled {
            theme.text.withAlphaComponent(0.035).setFill()
            card.fill()
        }
        let alpha: CGFloat = enabled ? 1 : 0.5

        // Checkbox: an outlined square that fills with the accent, and a hand-drawn tick.
        let box = NSBezierPath(roundedRect: l.checkbox.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
        if isOn(option.control) {
            theme.accent.withAlphaComponent(alpha).setFill()
            box.fill()
            let tick = NSBezierPath()
            let r = l.checkbox
            tick.move(to: CGPoint(x: r.minX + 5, y: r.midY + 0.5))
            tick.line(to: CGPoint(x: r.minX + 8.5, y: r.maxY - 6))
            tick.line(to: CGPoint(x: r.maxX - 5, y: r.minY + 6))
            tick.lineWidth = 2
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.withAlphaComponent(alpha).setStroke()
            tick.stroke()
        } else {
            theme.background.withAlphaComponent(alpha).setFill()
            box.fill()
            (pressed == option.control ? theme.accent : theme.tertiary.withAlphaComponent(0.7 * alpha)).setStroke()
            box.lineWidth = 1.5
            box.stroke()
        }

        let title = attributed(option.title, .systemFont(ofSize: 13, weight: .semibold), theme.text.withAlphaComponent(alpha))
        title.draw(at: CGPoint(x: l.text.minX, y: l.text.minY + 1))
        let tag = attributed(option.tag, .systemFont(ofSize: 10.5, weight: .medium), theme.tertiary)
        let tagX = l.text.minX + title.size().width + 8
        let tagRect = CGRect(x: tagX, y: l.text.minY + 1.5, width: tag.size().width + 12, height: 16)
        theme.track.setFill()
        NSBezierPath(roundedRect: tagRect, xRadius: 8, yRadius: 8).fill()
        tag.draw(at: CGPoint(x: tagRect.minX + 6, y: tagRect.minY + (16 - tag.size().height) / 2))
        rich(option.body, size: 11.5, theme.tertiary, theme: theme)
            .draw(with: CGRect(x: l.text.minX, y: l.text.minY + 20, width: l.text.width, height: l.text.height - 18),
                  options: [.usesLineFragmentOrigin])
    }

    private func drawBanner(_ message: String, in rect: CGRect, theme: PanelTheme) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        PanelTheme.danger.withAlphaComponent(0.12).setFill()
        shape.fill()
        PanelTheme.danger.withAlphaComponent(0.35).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // A round "!" marker.
        let mark = CGRect(x: rect.minX + 14, y: rect.minY + 13, width: 18, height: 18)
        PanelTheme.danger.setFill()
        NSBezierPath(ovalIn: mark).fill()
        NSColor.white.setFill()
        CGRect(x: mark.midX - 1, y: mark.minY + 4, width: 2, height: 6.5).fill()
        CGRect(x: mark.midX - 1, y: mark.minY + 12, width: 2, height: 2).fill()

        let x = mark.maxX + 10, width = rect.maxX - x - 14
        attributed(tr("L'installation n'a pas abouti", "The installation did not complete"),
                   .systemFont(ofSize: 13, weight: .semibold), theme.text)
            .draw(at: CGPoint(x: x, y: rect.minY + 12))
        let text = rich(message, size: 12, theme.secondary, theme: theme)
        text.draw(with: CGRect(x: x, y: rect.minY + 12 + 19, width: width, height: height(of: text, width: width)),
                  options: [.usesLineFragmentOrigin])
    }

    private var isError: Bool { if case .error = phase { return true } else { return false } }

    private func drawFooter(_ l: Layout, theme: PanelTheme) {
        let leftWidth = l.refuse.minX - Self.pad - 16
        let midY = l.footerY + 17
        switch phase {
        case .idle, .error:
            let note = attributed(tr("Refuser ferme l'app sans rien changer.", "Refusing quits without changing anything."),
                                  .systemFont(ofSize: 11.5), theme.tertiary, wraps: true)
            let h = height(of: note, width: leftWidth)
            note.draw(with: CGRect(x: Self.pad + 2, y: midY - h / 2, width: leftWidth, height: h), options: [.usesLineFragmentOrigin])
            drawButton(refuseTitle, shortcut: "esc", in: l.refuse, primary: false, enabled: true, control: .refuse, theme: theme)
            drawButton(acceptTitle, shortcut: "↩", in: l.accept, primary: true, enabled: true, control: .accept, theme: theme)
        case .installing:
            drawSpinner(center: CGPoint(x: Self.pad + 9, y: midY), theme: theme)
            attributed(tr("Écriture des réglages de Claude Code…", "Writing Claude Code's settings…"),
                       .systemFont(ofSize: 12, weight: .medium), theme.secondary)
                .draw(at: CGPoint(x: Self.pad + 26, y: midY - 8))
            drawButton(refuseTitle, shortcut: "esc", in: l.refuse, primary: false, enabled: false, control: .refuse, theme: theme)
            drawButton(acceptTitle, shortcut: "", in: l.accept, primary: true, enabled: false, control: .accept, theme: theme)
        case .success:
            let green = PanelTheme.gaugeColors[2]
            let mark = CGRect(x: Self.pad, y: midY - 10, width: 20, height: 20)
            green.setFill()
            NSBezierPath(ovalIn: mark).fill()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: mark.minX + 5.5, y: mark.midY + 0.5))
            tick.line(to: CGPoint(x: mark.minX + 8.5, y: mark.maxY - 6))
            tick.line(to: CGPoint(x: mark.maxX - 5.5, y: mark.minY + 6.5))
            tick.lineWidth = 2
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
            let width = Self.width - 2 * Self.pad - 30
            attributed(tr("C'est installé.", "All set."), .systemFont(ofSize: 13, weight: .semibold), theme.text)
                .draw(at: CGPoint(x: mark.maxX + 10, y: midY - 17))
            attributed(tr("Les sessions déjà ouvertes verront les hooks après redémarrage (ou via /hooks).",
                          "Sessions already open will see the hooks after a restart (or through /hooks)."),
                       .systemFont(ofSize: 12), theme.secondary)
                .draw(with: CGRect(x: mark.maxX + 10, y: midY + 1, width: width, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawSpinner(center: CGPoint, theme: PanelTheme) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(theme.track.cgColor)
        ctx.strokeEllipse(in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
        ctx.setStrokeColor(theme.accent.cgColor)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: 7, startAngle: -.pi / 2, endAngle: .pi * 0.25, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawButton(_ title: String, shortcut: String, in rect: CGRect, primary: Bool, enabled: Bool,
                            control: Control, theme: PanelTheme) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let hot = enabled && hovered == control
        let down = enabled && pressed == control
        let alpha: CGFloat = enabled ? 1 : 0.55
        let label: NSColor
        if primary {
            var fill = theme.accent
            if down { fill = fill.blended(withFraction: 0.18, of: .black) ?? fill }
            else if hot { fill = fill.blended(withFraction: 0.08, of: .black) ?? fill }
            fill.withAlphaComponent(alpha).setFill()
            shape.fill()
            label = NSColor.white.withAlphaComponent(alpha)
        } else {
            (down ? theme.track : hot ? theme.text.withAlphaComponent(0.06) : theme.card).withAlphaComponent(alpha).setFill()
            shape.fill()
            theme.stroke.setStroke()
            shape.lineWidth = 1
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5).stroke()
            label = theme.text.withAlphaComponent(alpha)
        }
        let text = attributed(title, .systemFont(ofSize: 13, weight: .semibold), label)
        let key = attributed(shortcut, .systemFont(ofSize: 11, weight: .medium), label.withAlphaComponent(label.alphaComponent * 0.6))
        let gap: CGFloat = shortcut.isEmpty ? 0 : 7
        let total = text.size().width + gap + (shortcut.isEmpty ? 0 : key.size().width)
        let x = rect.midX - total / 2
        text.draw(at: CGPoint(x: x, y: rect.midY - text.size().height / 2))
        if !shortcut.isEmpty {
            key.draw(at: CGPoint(x: x + text.size().width + gap, y: rect.midY - key.size().height / 2 + 0.5))
        }
    }

    // MARK: Mouse

    private func control(at point: CGPoint) -> Control? {
        let l = layout(PanelTheme.current(effectiveAppearance))
        switch phase {
        case .installing, .success: return nil
        case .idle, .error: break
        }
        if l.accept.contains(point) { return .accept }
        if l.refuse.contains(point) { return .refuse }
        if let i = l.options.firstIndex(where: { $0.card.contains(point) }) { return options[i].control }
        return nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        guard phase == .idle || isError else { return }
        let l = layout(PanelTheme.current(effectiveAppearance))
        ([l.accept, l.refuse] + l.options.map(\.card)).forEach { addCursorRect($0, cursor: .pointingHand) }
    }

    override func mouseMoved(with event: NSEvent) { hovered = control(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let c = control(at: point) {
            pressed = c
        } else {
            // A borderless window has no title bar: the background moves it.
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let target = pressed
        pressed = nil
        guard let target, control(at: convert(event.locationInWindow, from: nil)) == target else { return }
        switch target {
        case .accept: onAccept?()
        case .refuse: onRefuse?()
        case .login, .quotas: flip(target)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Space flips the option under the cursor, as it would a focused checkbox.
        if event.charactersIgnoringModifiers == " ", phase == .idle || isError, let hovered, hovered == .login || hovered == .quotas {
            flip(hovered)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Text helpers

    private func attributed(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0,
                            wraps: Bool = false, lineSpacing: CGFloat = 0) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        style.lineSpacing = lineSpacing
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style])
    }

    /// Wrapping body text where `backticks` mark paths and commands, set in monospace.
    private func rich(_ string: String, size: CGFloat, _ color: NSColor, theme: PanelTheme) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        let result = NSMutableAttributedString()
        for (i, part) in string.components(separatedBy: "`").enumerated() {
            let code = i % 2 == 1
            result.append(NSAttributedString(string: part, attributes: [
                .font: code ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]))
        }
        return result
    }

    private func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: 1000), options: [.usesLineFragmentOrigin]).height)
    }

    private func onboardingSerif(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

/// 8×8 pixel icons for the list, in the pet's own blocky style.
private struct Pixels {
    let rows: [String]

    static let plug = Pixels(rows: [
        "..#..#..",
        "..#..#..",
        ".######.",
        ".######.",
        "..####..",
        "...##...",
        "...##...",
        "...##...",
    ])
    static let terminal = Pixels(rows: [
        "########",
        "#......#",
        "#.#....#",
        "#..#...#",
        "#.#....#",
        "#...##.#",
        "#......#",
        "########",
    ])
    static let folder = Pixels(rows: [
        "###.....",
        "#..#....",
        "#...####",
        "#......#",
        "#......#",
        "#......#",
        "#......#",
        "########",
    ])
    static let lock = Pixels(rows: [
        "..####..",
        ".#....#.",
        ".#....#.",
        "########",
        "########",
        "###..###",
        "###..###",
        "########",
    ])
    static let bubble = Pixels(rows: [
        ".######.",
        "#......#",
        "#......#",
        "#.#.#.##",
        "#......#",
        ".######.",
        ".#......",
        "#.......",
    ])
    static let undo = Pixels(rows: [
        "..#.....",
        ".##.....",
        "######..",
        ".##...#.",
        "..#....#",
        ".......#",
        "......#.",
        "..####..",
    ])
}

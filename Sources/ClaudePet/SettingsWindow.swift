import AppKit

/// The settings window: the pet's own settings, the account quotas and the Claude Code integration
/// (hooks and status line). A regular titled window, so it can take the keyboard and sit behind other
/// apps, but drawn by hand like the menu bar panel (`PanelTheme`), titlebar included.
final class SettingsWindow: NSWindow {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: SettingsView.width, height: 600),
                   styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: true)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = tr("Réglages de Claude Pet", "Claude Pet Settings")
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // Seen for a frame while resizing, and behind the titlebar: the same paper as the view.
        backgroundColor = NSColor(name: nil) { PanelTheme.current($0).background }
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // No main menu in an accessory app: the usual shortcuts are handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "w", ",": close()
        case "q": NSApp.terminate(nil)
        case "m": miniaturize(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class SettingsController: NSObject, NSWindowDelegate {
    let window = SettingsWindow()
    let view = SettingsView()
    var modelProvider: (() -> SettingsView.Model)?
    /// The window came to the front: a good moment to re-read what may have changed outside the app.
    var onActivate: (() -> Void)?
    var isOpen: Bool { window.isVisible }
    private var placed = false

    override init() {
        super.init()
        window.contentView = view
        window.delegate = self
    }

    func open() {
        onActivate?()
        refresh(force: true)
        if !placed {
            placed = true
            window.center()
        }
        // An accessory app is never active by itself: bring it forward, or the window opens behind.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    /// Cheap enough on every app refresh; does nothing while closed.
    func refresh(force: Bool = false) {
        guard force || isOpen, let model = modelProvider?() else { return }
        view.model = model
        let height = view.preferredHeight
        if abs(window.frame.height - height) > 0.5 {
            // Grows downwards: the titlebar stays where it was.
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size = CGSize(width: SettingsView.width, height: height)
            window.setFrame(frame, display: true)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onActivate?()
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        view.cancelConfirmation()
        // Back to whatever app was in front before: an accessory app has nothing else to show.
        DispatchQueue.main.async { NSApp.deactivate() }
    }

    func snapshot(to path: String) {
        refresh(force: true)
        view.frame = CGRect(origin: .zero, size: CGSize(width: SettingsView.width, height: view.preferredHeight))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Content

final class SettingsView: NSView {
    struct Model {
        var petVisible = true
        var notch = false
        var notchAvailable = false
        var transitioning = false
        var scale = 5
        var login = LoginItem.State.off
        var loginMessage: String?
        /// Where the pet sits on its screen, 0…1 from the bottom-left corner; nil when unknown.
        var spot: CGPoint?
        var usageAPI = true
        var usageStatus = ""
        /// Nil while the source is off.
        var usageHealthy: Bool?
        var update = UpdateChecker.State.notChecked
        var updateCurrent: String?
        var updateLastCheck: Date?
        /// When "Check now" can be used again; nil when it can be used now.
        var updateManualAt: Date?
        var hooks: HookSetup.Status?
        var settingsPath = ""
        /// Outcome of the last install or uninstall.
        var hookMessage: String?
        var hookMessageIsError = false
        /// The copy made before Claude Pet's first change; nil if there was no settings.json then.
        var originalBackup: HookSetup.Backup?
        /// The newest timestamped copy; nil when missing or the same file as the original.
        var latestBackup: HookSetup.Backup?
        var version = "dev"
        var server = ""
        var serverOK = true
    }

    static let width: CGFloat = 520
    private static let pad: CGFloat = 24
    private static let confirmDuration: TimeInterval = 4

    var model = Model() { didSet { apply() } }
    var onToggleVisible: (() -> Void)?
    var onToggleNotch: (() -> Void)?
    var onToggleLogin: (() -> Void)?
    var onToggleUsageAPI: (() -> Void)?
    var onToggleUpdates: (() -> Void)?
    var onOpenUpdate: (() -> Void)?
    var onCheckUpdatesNow: (() -> Void)?
    var onScale: ((Int) -> Void)?
    var onCorner: ((PetController.Corner) -> Void)?
    var onInstall: (() -> Void)?
    var onUninstall: (() -> Void)?
    var onRestore: ((HookSetup.Backup) -> Void)?

    private let visibleRow = SettingRow(accessory: PanelToggle())
    private let notchRow = SettingRow(accessory: PanelToggle())
    private let sizeRow = SettingRow(accessory: SizePicker())
    private let positionRow = SettingRow(accessory: CornerPicker())
    private let loginRow = SettingRow(accessory: PanelToggle())
    private let usageRow = SettingRow(accessory: PanelToggle())
    private let updateRow = SettingRow(accessory: PanelToggle())
    /// While the check is on: "Check now", or, once a newer version exists, a button to its release page.
    private let releaseRow = SettingRow(accessory: PanelPillButton(title: "", style: .primary))
    private let installButton = PanelPillButton(title: "", style: .primary)
    private let uninstallButton = PanelPillButton(title: "", style: .secondary)
    private let restoreOriginalButton = PanelPillButton(title: "", style: .secondary)
    private let restoreLatestButton = PanelPillButton(title: "", style: .secondary)
    private var petRows: [SettingRow] { [visibleRow, notchRow, sizeRow, positionRow, loginRow] }
    private var dataRows: [SettingRow] {
        switch model.update {
        case .off, .unavailable: return [usageRow, updateRow]
        default: return [usageRow, updateRow, releaseRow]
        }
    }
    private let petIcon = SpriteComposer.frame(state: .idle, tool: nil, t: 0, bubble: false)

    /// Destructive actions ask twice: the first click arms them for a few seconds, one at a time.
    private enum Confirmable { case uninstall, restoreOriginal, restoreLatest }
    private var pending: Confirmable?
    private var confirmUntil: Date?
    private var confirmTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        (petRows + [usageRow, updateRow, releaseRow]).forEach(addSubview)
        [installButton, uninstallButton, restoreOriginalButton, restoreLatestButton].forEach(addSubview)
        visibleRow.onClick = { [weak self] in self?.onToggleVisible?() }
        notchRow.onClick = { [weak self] in self?.onToggleNotch?() }
        loginRow.onClick = { [weak self] in self?.onToggleLogin?() }
        usageRow.onClick = { [weak self] in self?.onToggleUsageAPI?() }
        updateRow.onClick = { [weak self] in self?.onToggleUpdates?() }
        releaseRow.onClick = { [weak self] in self?.releaseAction() }
        (releaseRow.accessory as! PanelPillButton).onClick = { [weak self] in self?.releaseAction() }
        (sizeRow.accessory as! SizePicker).onPick = { [weak self] in self?.onScale?($0) }
        (positionRow.accessory as! CornerPicker).onPick = { [weak self] in self?.onCorner?($0) }
        installButton.onClick = { [weak self] in
            self?.cancelConfirmation()
            self?.onInstall?()
        }
        uninstallButton.onClick = { [weak self] in self?.confirmableClicked(.uninstall) }
        restoreOriginalButton.onClick = { [weak self] in self?.confirmableClicked(.restoreOriginal) }
        restoreLatestButton.onClick = { [weak self] in self?.confirmableClicked(.restoreLatest) }
        apply()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Dragging the paper moves the window, but not when the drag starts on a control.
    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: Layout

    private struct Layout {
        var headerY: CGFloat = 0
        var petTitleY: CGFloat = 0, petCardY: CGFloat = 0, petCardHeight: CGFloat = 0
        var dataTitleY: CGFloat = 0, dataCardY: CGFloat = 0, dataCardHeight: CGFloat = 0
        var hooksTitleY: CGFloat = 0, hooksCardY: CGFloat = 0
        var actionsY: CGFloat = 0, messageY: CGFloat = 0, messageHeight: CGFloat = 0
        var hooksCardHeight: CGFloat = 0
        var backupsTitleY: CGFloat = 0, backupsCardY: CGFloat = 0, backupRows = 1
        var warningY: CGFloat = 0, warningHeight: CGFloat = 0
        var footerY: CGFloat = 0
        var height: CGFloat = 0
    }

    private static let statusBlockHeight: CGFloat = 64
    private static let tileSize: CGFloat = 46
    private static let backupRowHeight: CGFloat = 50

    private var inner: CGFloat { Self.width - 2 * Self.pad }

    private func computeLayout() -> Layout {
        var l = Layout()
        // Under the traffic lights.
        l.headerY = 40
        l.petTitleY = l.headerY + Self.tileSize + 24
        l.petCardY = l.petTitleY + 22
        l.petCardHeight = petRows.map(\.rowHeight).reduce(0, +)
        l.dataTitleY = l.petCardY + l.petCardHeight + 24
        l.dataCardY = l.dataTitleY + 22
        l.dataCardHeight = dataRows.map(\.rowHeight).reduce(0, +)
        l.hooksTitleY = l.dataCardY + l.dataCardHeight + 24
        l.hooksCardY = l.hooksTitleY + 22
        l.actionsY = l.hooksCardY + Self.statusBlockHeight
        l.messageY = l.actionsY + 12 + 28 + 10
        l.messageHeight = textHeight(messageText(PanelTheme.light), width: inner - 24)
        l.hooksCardHeight = l.messageY + l.messageHeight + 14 - l.hooksCardY
        l.backupsTitleY = l.hooksCardY + l.hooksCardHeight + 16
        l.backupsCardY = l.backupsTitleY + 20
        l.backupRows = model.latestBackup == nil ? 1 : 2
        l.warningY = l.backupsCardY + CGFloat(l.backupRows) * Self.backupRowHeight + 8
        l.warningHeight = textHeight(warningText(PanelTheme.light), width: inner - 4)
        l.footerY = l.warningY + l.warningHeight + 22
        l.height = l.footerY + 16 + 18
        return l
    }

    var preferredHeight: CGFloat { computeLayout().height }

    private func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: 200), options: .usesLineFragmentOrigin).height)
    }

    override func layout() {
        super.layout()
        let l = computeLayout(), pad = Self.pad
        var y = l.petCardY
        for row in petRows {
            row.frame = CGRect(x: pad, y: y, width: inner, height: row.rowHeight)
            y += row.rowHeight
        }
        y = l.dataCardY
        for row in dataRows {
            row.frame = CGRect(x: pad, y: y, width: inner, height: row.rowHeight)
            y += row.rowHeight
        }
        releaseRow.isHidden = !dataRows.contains(releaseRow)

        let install = installButton.fittingSize
        installButton.frame = CGRect(x: pad + 12, y: l.actionsY + 12, width: max(104, install.width), height: install.height)
        let uninstall = uninstallButton.fittingSize
        uninstallButton.frame = CGRect(x: installButton.frame.maxX + 8, y: l.actionsY + 12,
                                       width: max(104, uninstall.width), height: uninstall.height)

        for (i, button) in [restoreOriginalButton, restoreLatestButton].enumerated() {
            let size = button.fittingSize, width = max(92, size.width)
            button.isHidden = i >= l.backupRows
            button.frame = CGRect(x: pad + inner - 12 - width, y: l.backupsCardY + CGFloat(i) * Self.backupRowHeight + (Self.backupRowHeight - size.height) / 2,
                                  width: width, height: size.height)
        }
    }

    // MARK: Model

    private enum HookState { case complete, outdated, partial, missing }

    private var hookState: HookState? {
        guard let s = model.hooks else { return nil }
        if s.isComplete { return s.upToDate ? .complete : .outdated }
        return s.installedHooks == 0 && !s.statusLineBridged ? .missing : .partial
    }

    private func apply() {
        let m = model
        visibleRow.title = tr("Afficher le pet", "Show the pet")
        visibleRow.subtitle = m.petVisible ? tr("Visible sur le bureau", "Visible on the desktop") : tr("Masqué : les demandes restent dans Claude", "Hidden: requests stay in Claude")
        (visibleRow.accessory as! PanelToggle).isOn = m.petVisible

        notchRow.title = tr("Vivre dans l'encoche", "Live in the notch")
        notchRow.subtitle = m.notchAvailable ? tr("Se loge à côté de la caméra", "Settles next to the camera") : tr("Aucune encoche sur cet écran", "No notch on this screen")
        notchRow.isEnabled = m.notchAvailable && !m.transitioning
        (notchRow.accessory as! PanelToggle).isOn = m.notch

        sizeRow.title = tr("Taille", "Size")
        sizeRow.subtitle = tr("Pixels ×\(m.scale)", "Pixels ×\(m.scale)")
        sizeRow.isClickable = false
        (sizeRow.accessory as! SizePicker).scale = m.scale

        positionRow.title = tr("Position", "Position")
        positionRow.subtitle = m.notch ? tr("Fixée par l'encoche", "Set by the notch") : tr("Choisis un coin de l'écran", "Pick a corner of the screen")
        positionRow.isClickable = false
        let corners = positionRow.accessory as! CornerPicker
        corners.spot = m.spot
        corners.docked = m.notch
        corners.isEnabled = !m.notch && !m.transitioning

        loginRow.title = tr("Ouvrir au démarrage du Mac", "Open at login")
        if let message = m.loginMessage {
            loginRow.subtitle = tr("Échec : ", "Failed: ") + message
        } else {
            switch m.login {
            case .on: loginRow.subtitle = tr("Le pet s'ouvre avec ta session", "The pet opens with your session")
            case .off: loginRow.subtitle = tr("À ouvrir à la main après un redémarrage", "Open it by hand after a restart")
            // Turned off by the user in System Settings: only they can allow it again, from there.
            case .needsApproval: loginRow.subtitle = tr("À autoriser dans les Réglages Système", "Allow it in System Settings")
            case .unavailable: loginRow.subtitle = tr("Seulement pour l'app installée", "Only for the installed app")
            }
        }
        loginRow.isEnabled = m.login != .unavailable
        (loginRow.accessory as! PanelToggle).isOn = m.login == .on

        usageRow.title = tr("Quotas du compte", "Account quotas")
        usageRow.subtitle = tr("Lus via Claude Code, toutes les 5 min · accès au Trousseau", "Read through Claude Code, every 5 min · Keychain access")
        (usageRow.accessory as! PanelToggle).isOn = m.usageAPI

        updateRow.title = tr("Vérifier les mises à jour", "Check for updates")
        updateRow.subtitle = updateSubtitle()
        updateRow.isEnabled = m.update != .unavailable
        (updateRow.accessory as! PanelToggle).isOn = m.update != .off && m.update != .unavailable
        let releaseButton = releaseRow.accessory as! PanelPillButton
        if case .available(let version, _) = m.update {
            releaseRow.title = tr("Version \(version) disponible", "Version \(version) available")
            releaseRow.subtitle = tr("Ouvre sa page sur GitHub : rien n'est téléchargé tout seul", "Opens its page on GitHub: nothing downloads by itself")
            releaseButton.title = tr("Voir sur GitHub", "View on GitHub")
            releaseButton.style = .primary
            releaseButton.isEnabled = true
        } else {
            releaseRow.title = tr("Vérifier maintenant", "Check now")
            if m.update == .checking {
                releaseRow.subtitle = tr("Demande en cours à GitHub", "Asking GitHub")
            } else if let at = m.updateManualAt {
                // Rounded up: "in 1 min" while nearly two are left would be a lie.
                let minutes = max(1, Int((at.timeIntervalSinceNow / 60).rounded(.up)))
                releaseRow.subtitle = tr("De nouveau possible dans \(minutes) min, pour ménager GitHub", "Available again in \(minutes) min, to go easy on GitHub")
            } else {
                releaseRow.subtitle = tr("Sans attendre la vérification du jour", "Without waiting for the daily check")
            }
            releaseButton.title = m.update == .checking ? tr("Vérification…", "Checking…") : tr("Vérifier", "Check")
            releaseButton.style = .secondary
            releaseButton.isEnabled = m.update != .checking && m.updateManualAt == nil
        }

        switch hookState {
        case .complete: installButton.title = tr("Réinstaller", "Reinstall")
        case .outdated: installButton.title = tr("Mettre à jour", "Update")
        case .partial: installButton.title = tr("Réparer", "Repair")
        case .missing, nil: installButton.title = tr("Installer", "Install")
        }
        installButton.style = hookState == .complete ? .secondary : .primary
        uninstallButton.isEnabled = hookState != .missing && hookState != nil
        restoreOriginalButton.isEnabled = m.originalBackup != nil
        restoreLatestButton.isEnabled = m.latestBackup != nil
        if let pending, !button(for: pending).isEnabled { cancelConfirmation() }
        syncConfirmables()

        needsLayout = true
        needsDisplay = true
    }

    private func updateSubtitle() -> String {
        let m = model
        let checked = m.updateLastCheck.map {
            Date().timeIntervalSince($0) < 60
                ? tr(" · vérifié à l'instant", " · checked just now")
                : tr(" · vérifié il y a \(QuotaStore.duration($0, Date()))", " · checked \(QuotaStore.duration($0, Date())) ago")
        } ?? ""
        let current = m.updateCurrent ?? "?"
        switch m.update {
        case .off: return tr("Désactivée : aucune requête vers GitHub", "Off: no requests to GitHub")
        case .unavailable: return tr("Seulement pour l'app installée", "Only for the installed app")
        case .notChecked: return tr("Une fois par jour, sur GitHub · pas encore vérifié", "Once a day, on GitHub · not checked yet")
        case .checking: return tr("Vérification sur GitHub…", "Checking on GitHub…")
        case .upToDate: return tr("À jour (v\(current))", "Up to date (v\(current))") + checked
        // The row below says which version is out.
        case .available: return tr("Tu as la v\(current)", "You have v\(current)") + checked
        case .failed(let message): return tr("Échec : \(message) · nouvel essai demain", "Failed: \(message) · retrying tomorrow")
        }
    }

    private func button(for action: Confirmable) -> PanelPillButton {
        switch action {
        case .uninstall: return uninstallButton
        case .restoreOriginal: return restoreOriginalButton
        case .restoreLatest: return restoreLatestButton
        }
    }

    /// Titles, colors and the draining bar of the buttons that ask twice.
    private func syncConfirmables() {
        for action in [Confirmable.uninstall, .restoreOriginal, .restoreLatest] {
            let button = button(for: action)
            let armed = pending == action
            switch action {
            case .uninstall: button.title = armed ? tr("Confirmer la désinstallation", "Confirm uninstall") : tr("Désinstaller", "Uninstall")
            case .restoreOriginal, .restoreLatest: button.title = armed ? tr("Confirmer", "Confirm") : tr("Restaurer", "Restore")
            }
            button.style = armed ? .danger : .secondary
            button.progress = armed ? CGFloat(max(0, (confirmUntil ?? Date()).timeIntervalSinceNow) / Self.confirmDuration) : nil
        }
        needsLayout = true
    }

    // MARK: Confirmation

    private func confirmableClicked(_ action: Confirmable) {
        guard pending == action else { return arm(action) }
        cancelConfirmation()
        switch action {
        case .uninstall: onUninstall?()
        case .restoreOriginal: if let backup = model.originalBackup { onRestore?(backup) }
        case .restoreLatest: if let backup = model.latestBackup { onRestore?(backup) }
        }
    }

    private func arm(_ action: Confirmable) {
        pending = action
        confirmUntil = Date().addingTimeInterval(Self.confirmDuration)
        confirmTimer?.invalidate()
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self, let until = self.confirmUntil else { return }
            if until.timeIntervalSinceNow <= 0 { self.cancelConfirmation() } else { self.syncConfirmables() }
        }
        RunLoop.main.add(timer, forMode: .common)
        confirmTimer = timer
        syncConfirmables()
        needsDisplay = true
    }

    func cancelConfirmation() {
        confirmTimer?.invalidate()
        confirmTimer = nil
        guard pending != nil else { return }
        pending = nil
        confirmUntil = nil
        syncConfirmables()
        needsDisplay = true
    }

    /// The release row's button: open the newer version's page, or check now if that's allowed yet.
    private func releaseAction() {
        if case .available = model.update {
            onOpenUpdate?()
            return
        }
        guard model.update != .checking, model.updateManualAt == nil else { return }
        onCheckUpdatesNow?()
    }

    /// Tests: the controls by name, as clicks would.
    func press(_ name: String) {
        switch name {
        case "visible": onToggleVisible?()
        case "notch": if notchRow.isEnabled { onToggleNotch?() }
        case "usage": onToggleUsageAPI?()
        case "updates": if updateRow.isEnabled { onToggleUpdates?() }
        case "update_open", "update_check": if !releaseRow.isHidden { releaseAction() }
        case "login": if loginRow.isEnabled { onToggleLogin?() }
        case "reinstall", "install": installButton.press()
        // First click arms the confirmation, a second one (or "confirm_uninstall") goes through.
        case "uninstall": uninstallButton.press()
        case "confirm_uninstall": if pending == .uninstall { uninstallButton.press() }
        case "restore_original": restoreOriginalButton.press()
        case "confirm_restore_original": if pending == .restoreOriginal { restoreOriginalButton.press() }
        case "restore_latest": restoreLatestButton.press()
        case "confirm_restore_latest": if pending == .restoreLatest { restoreLatestButton.press() }
        case "cancel", "cancel_uninstall": cancelConfirmation()
        case "bottom_right": onCorner?(.bottomRight)
        case "bottom_left": onCorner?(.bottomLeft)
        case "top_right": onCorner?(.topRight)
        case "top_left": onCorner?(.topLeft)
        default: if name.hasPrefix("x"), let scale = Int(name.dropFirst()) { onScale?(scale) }
        }
    }

    // MARK: Drawing

    private func messageText(_ theme: PanelTheme) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11.5)
        if pending == .uninstall {
            return tr("Retire les hooks du pet et rend la ligne de statut d'origine. Une sauvegarde est faite avant.",
                      "Removes the pet's hooks and restores the original status line. A backup is made first.")
                .attributed(font, PanelTheme.danger, wraps: true)
        }
        guard let message = model.hookMessage else {
            return tr("Les sessions déjà ouvertes ne voient les changements qu'après redémarrage.",
                      "Sessions already open only see changes after a restart.")
                .attributed(font, theme.tertiary, wraps: true)
        }
        let text = NSMutableAttributedString(
            attributedString: (model.hookMessageIsError ? "✕  " : "✓  ")
                .attributed(.systemFont(ofSize: 11.5, weight: .bold), model.hookMessageIsError ? PanelTheme.danger : PanelTheme.gaugeColors[2], wraps: true))
        text.append(message.attributed(font, model.hookMessageIsError ? PanelTheme.danger : theme.secondary, wraps: true))
        return text
    }

    private func warningText(_ theme: PanelTheme) -> NSAttributedString {
        tr("Restaurer remplace settings.json : ce qui a changé depuis cette date est perdu. Le fichier actuel est copié avant.",
           "Restoring replaces settings.json: anything changed since that date is lost. The current file is copied first.")
            .attributed(.systemFont(ofSize: 11), pending == .restoreOriginal || pending == .restoreLatest ? PanelTheme.danger : theme.tertiary, wraps: true)
    }

    /// Medium date and short time, in the interface's language and the system's region.
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        let region = Locale.current.region?.identifier
        formatter.locale = Locale(identifier: (L10n.isFrench ? "fr" : "en") + (region.map { "_" + $0 } ?? ""))
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func drawBackups(_ theme: PanelTheme, _ l: Layout) {
        let pad = Self.pad
        tr("Copies de settings.json", "Copies of settings.json")
            .attributed(.systemFont(ofSize: 11, weight: .medium), theme.tertiary)
            .draw(at: CGPoint(x: pad + 2, y: l.backupsTitleY))
        drawCard(CGRect(x: pad, y: l.backupsCardY, width: inner, height: CGFloat(l.backupRows) * Self.backupRowHeight), theme: theme)
        var rows: [(String, String, Bool)] = []
        if let original = model.originalBackup {
            rows.append((tr("Copie d'origine", "Original copy"), tr("Avant Claude Pet · ", "Before Claude Pet · ") + Self.format(original.date), true))
        } else {
            rows.append((tr("Copie d'origine", "Original copy"),
                         tr("Aucune copie d'origine : elle est faite à l'installation depuis l'app", "No original copy: the app makes one when it installs"), false))
        }
        if let latest = model.latestBackup {
            rows.append((tr("Avant la dernière modification", "Before the last change"), Self.format(latest.date), true))
        }
        for (i, row) in rows.enumerated() {
            let y = l.backupsCardY + CGFloat(i) * Self.backupRowHeight
            if i > 0 { hairline(y, theme: theme) }
            let width = restoreOriginalButton.frame.minX - pad - 24
            let alpha: CGFloat = row.2 ? 1 : 0.6
            row.0.attributed(.systemFont(ofSize: 13, weight: .medium), theme.text.withAlphaComponent(alpha))
                .draw(at: CGPoint(x: pad + 12, y: y + 9), width: width)
            row.1.attributed(.systemFont(ofSize: 11), theme.tertiary).draw(at: CGPoint(x: pad + 12, y: y + 27), width: width)
        }
        warningText(theme).draw(with: CGRect(x: pad + 2, y: l.warningY, width: inner - 4, height: l.warningHeight + 2),
                                options: .usesLineFragmentOrigin)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = PanelTheme.current(effectiveAppearance)
        theme.background.setFill()
        bounds.fill()
        let l = computeLayout(), pad = Self.pad

        drawHeader(theme, y: l.headerY)

        // Pet.
        sectionTitle(tr("Pet", "Pet"), y: l.petTitleY, theme: theme)
        drawCard(CGRect(x: pad, y: l.petCardY, width: inner, height: l.petCardHeight), theme: theme)
        var y = l.petCardY
        for row in petRows.dropLast() {
            y += row.rowHeight
            hairline(y, theme: theme)
        }

        // Data.
        sectionTitle(tr("Données", "Data"), y: l.dataTitleY, theme: theme)
        drawCard(CGRect(x: pad, y: l.dataCardY, width: inner, height: l.dataCardHeight), theme: theme)
        y = l.dataCardY
        for row in dataRows.dropLast() {
            y += row.rowHeight
            hairline(y, theme: theme)
        }
        // The source's state, at the right of the section title, as in the menu bar panel.
        let usage = model.usageStatus.attributed(.systemFont(ofSize: 11), theme.tertiary)
        let usageWidth = min(usage.size().width + 1, inner - 120)
        let usageX = pad + inner - 2 - usageWidth
        usage.draw(at: CGPoint(x: usageX, y: l.dataTitleY + 1), width: usageWidth)
        let usageColor: NSColor
        switch model.usageHealthy {
        case true?: usageColor = PanelTheme.gaugeColors[2]
        case false?: usageColor = PanelTheme.warning
        case nil: usageColor = theme.tertiary.withAlphaComponent(0.6)
        }
        usageColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: usageX - 12, y: l.dataTitleY + 5.5, width: 6, height: 6)).fill()

        // Claude Code.
        sectionTitle("Claude Code", y: l.hooksTitleY, theme: theme)
        // The file every action reads and writes.
        let path = model.settingsPath.attributed(.monospacedSystemFont(ofSize: 10.5, weight: .regular), theme.tertiary)
        let pathWidth = min(path.size().width + 1, inner - 120)
        path.draw(at: CGPoint(x: pad + inner - 2 - pathWidth, y: l.hooksTitleY + 1.5), width: pathWidth)
        drawCard(CGRect(x: pad, y: l.hooksCardY, width: inner, height: l.hooksCardHeight), theme: theme)
        drawHookStatus(theme, y: l.hooksCardY)
        hairline(l.actionsY, theme: theme)
        messageText(theme).draw(with: CGRect(x: pad + 12, y: l.messageY, width: inner - 24, height: l.messageHeight + 2),
                                options: .usesLineFragmentOrigin)
        drawBackups(theme, l)

        // Footer: version on the left, the hooks' server on the right.
        let version = "Claude Pet \(model.version)".attributed(.systemFont(ofSize: 11), theme.tertiary)
        version.draw(at: CGPoint(x: pad + 2, y: l.footerY))
        let server = model.server.attributed(.systemFont(ofSize: 11), theme.tertiary)
        let serverWidth = min(server.size().width + 1, inner - version.size().width - 40)
        let serverX = pad + inner - 2 - serverWidth
        server.draw(at: CGPoint(x: serverX, y: l.footerY), width: serverWidth)
        (model.serverOK ? PanelTheme.gaugeColors[2] : PanelTheme.danger).setFill()
        NSBezierPath(ovalIn: CGRect(x: serverX - 13, y: l.footerY + 4.5, width: 6, height: 6)).fill()
    }

    /// The pet's face on a little stage tile, then the window's title in the serif.
    private func drawHeader(_ theme: PanelTheme, y: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pad = Self.pad
        let tile = CGRect(x: pad, y: y, width: Self.tileSize, height: Self.tileSize)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12)
        theme.card.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        theme.text.withAlphaComponent(0.07).setFill()
        for gy in stride(from: tile.minY + 4, to: tile.maxY, by: 6) {
            for gx in stride(from: tile.minX + 4, to: tile.maxX, by: 6) {
                CGRect(x: gx, y: gy, width: 1, height: 1).fill()
            }
        }
        if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: [theme.accent.withAlphaComponent(0.22).cgColor, theme.accent.withAlphaComponent(0).cgColor] as CFArray,
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
        tr("Réglages", "Settings").attributed(.serif(24, weight: .medium), theme.text)
            .draw(at: CGPoint(x: x, y: y), width: inner - x)
        tr("Ta mascotte, et son lien avec Claude Code", "Your pet, and how it hears from Claude Code")
            .attributed(.systemFont(ofSize: 12.5), theme.tertiary)
            .draw(at: CGPoint(x: x, y: y + 31), width: inner - x)
    }

    private func drawHookStatus(_ theme: PanelTheme, y: CGFloat) {
        let pad = Self.pad
        let badge = CGRect(x: pad + 14, y: y + (Self.statusBlockHeight - 28) / 2, width: 28, height: 28)
        let color: NSColor, title: String, detail: String
        let s = model.hooks
        let counts = s.map { tr("\($0.installedHooks) hooks sur \($0.expectedHooks)", "\($0.installedHooks) of \($0.expectedHooks) hooks") } ?? ""
        var line = s.map { $0.statusLineBridged ? tr("ligne de statut reliée", "status line bridged") : tr("ligne de statut non reliée", "status line not bridged") } ?? ""
        if let s, s.statusLineBridged, !s.bridgeScriptPresent { line += tr(" · script du pont absent", " · bridge script missing") }
        switch hookState {
        case .complete:
            color = PanelTheme.gaugeColors[2]
            title = tr("Installée et à jour", "Installed and up to date")
            detail = counts + " · " + line
        case .outdated:
            color = PanelTheme.warning
            title = tr("Mise à jour à faire", "Needs an update")
            detail = counts + " · " + tr("une installation changerait des entrées", "installing would change some entries")
        case .partial:
            color = PanelTheme.warning
            title = tr("Installation partielle", "Partially installed")
            detail = counts + " · " + line
        case .missing:
            color = theme.tertiary
            title = tr("Pas installée", "Not installed")
            detail = tr("Sans ses hooks, le pet ne voit rien de ce que fait Claude", "Without its hooks, the pet can't see what Claude does")
        case nil:
            color = theme.tertiary
            title = tr("État inconnu", "Unknown state")
            detail = ""
        }
        color.setFill()
        NSBezierPath(ovalIn: badge).fill()
        drawGlyph(hookState, in: badge)

        let x = badge.maxX + 12, width = inner - (x - pad) - 12
        tr("Intégration : ", "Integration: ").appending(title)
            .attributed(.systemFont(ofSize: 13, weight: .medium), theme.text)
            .draw(at: CGPoint(x: x, y: y + 15), width: width)
        detail.attributed(.systemFont(ofSize: 11), theme.tertiary).draw(at: CGPoint(x: x, y: y + 34), width: width)
    }

    /// Check, exclamation mark or dash, stroked in white with round caps.
    private func drawGlyph(_ state: HookState?, in rect: CGRect) {
        let path = NSBezierPath()
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let c = CGPoint(x: rect.midX, y: rect.midY)
        switch state {
        case .complete:
            path.move(to: CGPoint(x: c.x - 5.5, y: c.y + 0.5))
            path.line(to: CGPoint(x: c.x - 1.5, y: c.y + 4.5))
            path.line(to: CGPoint(x: c.x + 6, y: c.y - 4))
        case .outdated, .partial:
            path.move(to: CGPoint(x: c.x, y: c.y - 6))
            path.line(to: CGPoint(x: c.x, y: c.y + 1.5))
            path.move(to: CGPoint(x: c.x, y: c.y + 5.5))
            path.line(to: CGPoint(x: c.x, y: c.y + 5.6))
        case .missing, nil:
            path.move(to: CGPoint(x: c.x - 5, y: c.y))
            path.line(to: CGPoint(x: c.x + 5, y: c.y))
        }
        NSColor.white.setStroke()
        path.stroke()
    }

    private func sectionTitle(_ title: String, y: CGFloat, theme: PanelTheme) {
        title.attributed(.systemFont(ofSize: 11, weight: .semibold), theme.tertiary, kern: 0.2)
            .draw(at: CGPoint(x: Self.pad + 2, y: y))
    }

    private func drawCard(_ rect: CGRect, theme: PanelTheme) {
        let card = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        theme.card.setFill()
        card.fill()
    }

    /// Between rows, inset like the system's grouped lists.
    private func hairline(_ y: CGFloat, theme: PanelTheme) {
        theme.stroke.setFill()
        CGRect(x: Self.pad + 12, y: y - 0.5, width: inner - 24, height: 1).fill()
    }
}

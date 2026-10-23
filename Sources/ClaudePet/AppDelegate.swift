import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let defaultPort: UInt16 = 47319

    private let tracker = SessionTracker()
    private let quotas = QuotaStore()
    private let usageAPI = OAuthUsageSource()
    private let requests = RequestCenter()
    private var pet: PetController!
    private var server: EventServer!
    private var statusItem: NSStatusItem!
    private let panel = ControlPanel()
    private let settings = SettingsController()
    /// Read when the settings window comes forward and after each action, not on every refresh.
    private var hookStatus: HookSetup.Status?
    private var hookBackups: (original: HookSetup.Backup?, latest: HookSetup.Backup?)
    private var hookMessage: (text: String, isError: Bool)?
    private var serverStatus = tr("démarrage…", "starting…")
    /// One-shot timer to the next moment something changes on its own (see `scheduleWake`).
    private var wakeTimer: Timer?
    private var lastHistoryCheck = Date.distantPast
    /// Clicking the sleeping pet wakes it with a wave, until this date.
    private var wavingUntil: Date?
    private static let waveDuration: TimeInterval = 2.5
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill`/`pkill` send SIGTERM, which skips applicationWillTerminate: route it through a normal quit
        // so the endpoint file is removed.
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { NSApp.terminate(nil) }
        termSource?.resume()

        pet = PetController()
        pet.view.contextMenuProvider = { [unowned self] in self.buildMenu() }
        pet.onClick = { [unowned self] in self.wakeUp() }
        pet.show()
        requests.onChange = { [unowned self] in
            self.pet.showRequest(self.requests.current, waiting: max(0, self.requests.queue.count - 1))
        }
        pet.requestView.onAllow = { [unowned self] in self.requests.allow($0) }
        pet.requestView.onDeny = { [unowned self] in self.requests.deny($0) }
        pet.requestView.onAnswer = { [unowned self] in self.requests.answer($0, $1) }
        pet.requestView.onDismiss = { [unowned self] id in
            // "Ignorer": Claude's dialog keeps the request, the pet stops alerting for it.
            if let request = self.requests.queue.first(where: { $0.id == id }),
               !self.requests.queue.contains(where: { $0.session == request.session && $0.id != id }) {
                self.tracker.setAside(session: request.session, toolName: request.tool)
            }
            self.requests.dismiss(id)
            self.refresh()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusIcon.make() ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)
            button.setAccessibilityLabel("Claude Pet")
            button.target = self
            button.action = #selector(statusItemClicked)
            // On press, like a menu.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        setUpPanel()
        setUpSettings()

        let port = ProcessInfo.processInfo.environment["CLAUDE_PET_PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        server = EventServer(preferredPort: port)
        // CLAUDE_PET_NO_PUBLISH=1 runs a dev instance (with another CLAUDE_PET_PORT) that hooks never reach.
        let publishes = ProcessInfo.processInfo.environment["CLAUDE_PET_NO_PUBLISH"] == nil
        server.onReady = { port in if publishes { Endpoint.publish(port: port) } }
        server.onDuplicate = { port in
            NSLog("claude-pet: une autre instance tourne déjà sur le port %d, on quitte", Int(port))
            NSApp.terminate(nil)
        }
        server.onEvent = { [unowned self] event in
            self.tracker.handle(event)
            if let id = event["session_id"] as? String {
                self.requests.sessionMoved(id, event: event)
                if event["hook_event_name"] as? String == "SessionEnd" {
                    self.quotas.forget(session: id)
                } else if let transcript = event["transcript_path"] as? String {
                    TranscriptUsage.read(transcript) { tokens in
                        self.quotas.estimateContext(session: id, tokens: tokens)
                        self.refresh()
                    }
                }
            }
            self.refresh()
        }
        usageAPI.onUpdate = { [unowned self] five, week in
            self.quotas.offer(five: five, week: week)
            self.refresh()
        }
        usageAPI.start()

        server.onAsk = { [unowned self] payload, respond in
            // The permission hook is the blocking one now: it also tells the tracker Claude waits.
            if payload["hook_event_name"] as? String == "PermissionRequest" {
                self.tracker.handle(payload)
                self.refresh()
            }
            // Hidden pet: nobody would see it, leave it all to Claude's own dialog.
            guard self.pet.isVisible else {
                respond(nil)
                return nil
            }
            return self.requests.add(payload, respond: respond)
        }
        server.onAskCancelled = { [unowned self] id in self.requests.cancel(id) }

        server.onStatus = { [unowned self] status in
            self.quotas.handleStatus(status)
            self.refresh()
        }
        server.onControl = { [unowned self] control in
            if let notch = control["notch"] as? Bool { self.pet.setNotchMode(notch) }
            let radius = (control["notch_radius"] as? Double).map { CGFloat($0) }
            let ear = (control["notch_ear"] as? Double).map { CGFloat($0) }
            if radius != nil || ear != nil { self.pet.tuneNotch(radius: radius, ear: ear) }
            if control["renew_usage_token"] as? Bool == true { self.usageAPI.renewNow() }
            // Tests: open or close the request panel as a hover would.
            if let reveal = control["reveal"] as? Bool { self.pet.revealRequest(reveal) }
            // Tests: renders the pet's windows to PNG, even with the display asleep.
            if let path = control["snapshot"] as? String { self.pet.snapshot(to: path) }
            // Tests: presses a request button by its title, as a click would.
            if let title = control["press"] as? String { self.pet.requestView.press(title) }
            if let text = control["type"] as? String { self.pet.requestView.typeOther(text) }
            // Tests: opens the menu bar panel, renders it, presses one of its controls.
            if let open = control["panel"] as? Bool, let button = self.statusItem.button {
                open ? self.panel.open(from: button) : self.panel.close()
            }
            if let path = control["panel_snapshot"] as? String { self.panel.snapshot(to: path) }
            if let name = control["panel_press"] as? String { self.panel.view.press(name) }
            // Tests: "light" / "dark" for the panel only, "" follows the system again.
            if let look = control["panel_appearance"] as? String {
                self.panel.window.appearance = look.isEmpty ? nil : NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
                Self.redraw(self.panel.view)
            }
            // Tests: the settings window, the same way.
            if let open = control["settings"] as? Bool { open ? self.openSettings() : self.settings.close() }
            if let look = control["settings_appearance"] as? String {
                self.settings.window.appearance = look.isEmpty ? nil : NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
                Self.redraw(self.settings.view)
            }
            if let name = control["settings_press"] as? String { self.settings.view.press(name) }
            if let path = control["settings_snapshot"] as? String { self.settings.snapshot(to: path) }
        }
        server.stateProvider = { [unowned self] in
            var snapshot = self.tracker.snapshot()
            snapshot["port"] = self.server.port.map { Int($0) } ?? NSNull()
            // What the pet actually shows (a click's wave wins over the tracker's state).
            snapshot["shown"] = self.shownDisplay().state.rawValue
            snapshot["quotas"] = self.quotas.snapshot()
            snapshot["usage_api"] = self.usageAPI.status
            snapshot["usage_token_expires_at"] = self.usageAPI.tokenExpiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
            snapshot["notch"] = self.pet.mode != .floating
            snapshot["click_through"] = self.pet.panel.ignoresMouseEvents
            snapshot["requests"] = self.requests.queue.map { ["id": $0.id, "session": $0.session, "tool": $0.tool] }
            snapshot["notch_radius"] = Double(NotchGeometry.bottomRadius)
            snapshot["notch_ear"] = Double(NotchGeometry.earRadius)
            return snapshot
        }
        server.onStatusChange = { [unowned self] status in
            self.serverStatus = status
            NSLog("claude-pet: %@", status)
        }
        server.start()

        wake()
    }

    /// Runs whatever changes on its own (transient states, sleep, timeouts, minute countdowns), then
    /// schedules itself for the next such moment. Hooks and clicks refresh directly.
    private func wake() {
        let now = Date()
        // Claude Desktop rewrites its usage history at most every 270 s: a stat every 30 s is plenty.
        if now.timeIntervalSince(lastHistoryCheck) >= 30 {
            lastHistoryCheck = now
            quotas.reloadDesktopHistory()
        }
        tracker.tick(now: now)
        refresh()
    }

    private func scheduleWake() {
        let now = Date()
        // At least once a minute, for the countdowns and data ages in the gauge tooltips.
        var next = now.addingTimeInterval(60)
        if let deadline = tracker.nextDeadline(now: now), deadline < next { next = deadline }
        if let until = wavingUntil, until > now, until < next { next = until }
        // Deadlines are strict comparisons: land just after them.
        let delay = max(0.05, next.timeIntervalSince(now) + 0.05)
        wakeTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [unowned self] _ in self.wake() }
        timer.tolerance = min(1, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        wakeTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        Endpoint.unpublish()
    }

    private func refresh() {
        let display = shownDisplay()
        pet.update(state: display.state, tool: display.tool)
        let leader = tracker.leader
        pet.updateGauges(quotas.gauges(
            leader: leader?.id,
            leaderFolder: leader?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        ).map { ($0.value, $0.detail) })
        panel.refresh()
        settings.refresh()
        scheduleWake()
    }

    /// What the pet shows: the tracker's state, unless a click made it wave, which wins for a moment
    /// whatever Claude is doing.
    private func shownDisplay() -> (state: PetState, tool: ToolKind?) {
        if let until = wavingUntil, Date() < until { return (.waving, nil) }
        return tracker.display()
    }

    /// A click on the pet (or its picture in the panel) makes it say hello, then it goes back to its
    /// state. Asleep, it wakes up and falls asleep again 10 s later if nothing happens.
    private func wakeUp() {
        if tracker.display().state == .sleeping { tracker.poke() }
        wavingUntil = Date().addingTimeInterval(Self.waveDuration)
        refresh()
    }

    // MARK: Menu bar panel

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        panel.toggle(from: button)
    }

    private func setUpPanel() {
        panel.modelProvider = { [unowned self] in self.panelModel() }
        panel.view.onPoke = { [unowned self] in self.wakeUp() }
        panel.view.onSettings = { [unowned self] in self.openSettings() }
        panel.window.onSettings = { [unowned self] in self.openSettings() }
        panel.view.onQuit = { NSApp.terminate(nil) }
    }

    private static func redraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(redraw)
    }

    private func panelModel() -> ControlPanelView.Model {
        var m = ControlPanelView.Model()
        let display = shownDisplay()
        let leader = tracker.leader
        let folder = leader?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        m.state = display.state
        m.tool = display.tool
        m.toolName = display.state == .working ? leader?.toolName : nil
        m.project = folder
        m.sessions = tracker.sessions.count
        m.gauges = quotas.gauges(leader: leader?.id, leaderFolder: folder)
        m.usageStatus = usageLine()
        m.serverOK = server.port != nil
        m.server = server.port == nil ? serverLine() : tr("En écoute", "Listening")
        m.serverDetail = serverLine()
        return m
    }

    private func usageLine() -> String {
        var usage = tr("Compte : ", "Account: ") + usageAPI.status
        if let last = usageAPI.lastSuccess, !usageAPI.isUpToDate {
            usage += tr(" · il y a \(QuotaStore.duration(last, Date()))", " · \(QuotaStore.duration(last, Date())) ago")
        }
        return usage
    }

    private func serverLine() -> String {
        if let port = server.port { return tr("En écoute", "Listening") + " · 127.0.0.1:\(port)" }
        return serverStatus.prefix(1).uppercased() + serverStatus.dropFirst()
    }

    // MARK: Settings window

    private func openSettings() {
        panel.close()
        settings.open()
    }

    private func reloadHooks() {
        let setup = HookSetup.standard
        hookStatus = setup.status()
        let original = setup.originalBackup(), latest = setup.latestBackup()
        // The same file twice would offer the same restore twice.
        hookBackups = (original, latest.flatMap { $0.url == original?.url ? nil : $0 })
    }

    private func setUpSettings() {
        settings.modelProvider = { [unowned self] in self.settingsModel() }
        settings.onActivate = { [unowned self] in self.reloadHooks() }
        let view = settings.view
        view.onToggleVisible = { [unowned self] in
            self.pet.isVisible ? self.pet.hide() : self.pet.show()
            self.settings.refresh()
        }
        view.onToggleNotch = { [unowned self] in
            self.pet.setNotchMode(!self.pet.wantsNotch)
            self.settings.refresh()
            // The flight takes about a second: show where the pet landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.settings.refresh() }
        }
        view.onToggleUsageAPI = { [unowned self] in
            OAuthUsageSource.isEnabled.toggle()
            OAuthUsageSource.isEnabled ? self.usageAPI.start() : self.usageAPI.stop()
            self.settings.refresh()
        }
        view.onScale = { [unowned self] in
            self.pet.setScale($0)
            self.settings.refresh()
        }
        view.onCorner = { [unowned self] in
            self.pet.move(to: $0)
            self.settings.refresh()
        }
        view.onInstall = { [unowned self] in
            let wasInstalled = (self.hookStatus?.installedHooks ?? 0) > 0
            self.runHookAction { try HookSetup.standard.install() } done: { report in
                guard report.changed else { return tr("Déjà à jour : rien n'a changé", "Already up to date: nothing changed") }
                return (wasInstalled ? tr("Réinstallé", "Reinstalled") : tr("Installé", "Installed")) + Self.backupNote(report)
            }
        }
        view.onUninstall = { [unowned self] in
            self.runHookAction { try HookSetup.standard.uninstall() } done: { report in
                report.changed ? tr("Désinstallé", "Uninstalled") + Self.backupNote(report) : tr("Rien à désinstaller", "Nothing to uninstall")
            }
        }
        view.onRestore = { [unowned self] backup in
            self.runHookAction { try HookSetup.standard.restore(backup) } done: { report in
                let what = backup.isOriginal ? tr("Copie d'origine restaurée", "Original copy restored")
                                             : tr("Copie du \(SettingsView.format(backup.date)) restaurée", "Copy from \(SettingsView.format(backup.date)) restored")
                return what + (report.backupURL.map { tr(" · fichier actuel copié dans ", " · current file copied to ") + $0.lastPathComponent } ?? "")
            }
        }
    }

    private static func backupNote(_ report: HookSetup.Report) -> String {
        report.backupURL.map { tr(" · sauvegarde : ", " · backup: ") + $0.lastPathComponent } ?? ""
    }

    /// Runs an install, uninstall or restore, then shows its outcome and the new state.
    private func runHookAction(_ action: () throws -> HookSetup.Report, done: (HookSetup.Report) -> String) {
        do {
            hookMessage = (done(try action()), false)
        } catch {
            hookMessage = (tr("Échec : ", "Failed: ") + error.localizedDescription, true)
        }
        reloadHooks()
        settings.refresh()
    }

    private func settingsModel() -> SettingsView.Model {
        var m = SettingsView.Model()
        m.petVisible = pet.isVisible
        m.notch = pet.wantsNotch
        m.notchAvailable = pet.notchAvailable
        m.transitioning = pet.isTransitioning
        m.scale = pet.scale
        if pet.mode == .floating, let screen = pet.panel.screen ?? NSScreen.main {
            let area = screen.visibleFrame, frame = pet.panel.frame
            let free = CGSize(width: max(1, area.width - frame.width), height: max(1, area.height - frame.height))
            m.spot = CGPoint(x: (frame.minX - area.minX) / free.width, y: (frame.minY - area.minY) / free.height)
        }
        m.usageAPI = OAuthUsageSource.isEnabled
        m.usageStatus = usageLine()
        m.usageHealthy = OAuthUsageSource.isEnabled ? usageAPI.isUpToDate : nil
        m.hooks = hookStatus
        m.settingsPath = (HookSetup.standard.settingsURL.path as NSString).abbreviatingWithTildeInPath
        m.hookMessage = hookMessage?.text
        m.hookMessageIsError = hookMessage?.isError ?? false
        m.originalBackup = hookBackups.original
        m.latestBackup = hookBackups.latest
        m.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        m.server = serverLine()
        m.serverOK = server.port != nil
        return m
    }

    // MARK: Pet's context menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let display = tracker.display()
        var status = "Claude \(display.state.label)"
        if let tool = tracker.leader?.toolName, display.state == .working { status += " (\(tool))" }
        menu.addItem(disabled: status)
        let count = tracker.sessions.count
        menu.addItem(disabled: tr(count == 1 ? "1 session suivie" : "\(count) sessions suivies", count == 1 ? "1 session tracked" : "\(count) sessions tracked"))
        menu.addItem(disabled: tr("Serveur : ", "Server: ") + serverStatus)
        var quotaStatus = tr("Quotas (API) : ", "Quotas (API): ") + usageAPI.status
        if let last = usageAPI.lastSuccess, !usageAPI.isUpToDate {
            quotaStatus += tr(", dernier succès il y a \(QuotaStore.duration(last, Date()))", ", last success \(QuotaStore.duration(last, Date())) ago")
        }
        menu.addItem(disabled: quotaStatus)
        menu.addItem(.separator())

        menu.addItem(action: pet.isVisible ? tr("Masquer", "Hide") : tr("Afficher", "Show"), key: "h") { [unowned self] in
            self.pet.isVisible ? self.pet.hide() : self.pet.show()
        }

        let notchAvailable = pet.notchAvailable
        let notchItem = menu.addItem(action: notchAvailable ? tr("Vivre dans l'encoche", "Live in the notch") : tr("Vivre dans l'encoche (aucune encoche)", "Live in the notch (no notch)"), key: "n") { [unowned self] in
            self.pet.setNotchMode(!self.pet.wantsNotch)
        }
        notchItem.state = pet.wantsNotch ? .on : .off
        notchItem.isEnabled = notchAvailable && !pet.isTransitioning

        let apiItem = menu.addItem(action: tr("Lire les quotas avec le compte Claude Code", "Read quotas with the Claude Code account")) { [unowned self] in
            OAuthUsageSource.isEnabled.toggle()
            OAuthUsageSource.isEnabled ? self.usageAPI.start() : self.usageAPI.stop()
        }
        apiItem.state = OAuthUsageSource.isEnabled ? .on : .off

        let docked = pet.mode != .floating
        let position = NSMenu()
        let corners: [(String, PetController.Corner)] = [
            (tr("En bas à droite", "Bottom right"), .bottomRight), (tr("En bas à gauche", "Bottom left"), .bottomLeft),
            (tr("En haut à droite", "Top right"), .topRight), (tr("En haut à gauche", "Top left"), .topLeft),
        ]
        for (title, corner) in corners {
            position.addItem(action: title) { [unowned self] in self.pet.move(to: corner) }
        }
        menu.addItem(submenu: position, title: tr("Position", "Position")).isEnabled = !docked

        let size = NSMenu()
        for scale in 3...8 {
            let item = size.addItem(action: "×\(scale)") { [unowned self] in self.pet.setScale(scale) }
            item.state = scale == pet.scale ? .on : .off
        }
        menu.addItem(submenu: size, title: tr("Taille", "Size"))

        menu.addItem(.separator())
        menu.addItem(action: tr("Réglages…", "Settings…"), key: ",") { [unowned self] in self.openSettings() }
        menu.addItem(action: tr("Quitter Claude Pet", "Quit Claude Pet"), key: "q") { NSApp.terminate(nil) }
        return menu
    }
}

/// Closure-backed menu items, to keep the menu code declarative.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }

    @discardableResult
    func addItem(action title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, key: key, handler: handler)
        addItem(item)
        return item
    }

    @discardableResult
    func addItem(submenu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return item
    }
}

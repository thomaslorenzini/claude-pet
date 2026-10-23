import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let defaultPort: UInt16 = 47319

    private let tracker = SessionTracker()
    private let quotas = QuotaStore()
    private let usageAPI = OAuthUsageSource()
    private var pet: PetController!
    private var server: EventServer!
    private var statusItem: NSStatusItem!
    private var serverStatus = "démarrage…"
    private var tickTimer: Timer?
    private var ticks = 0
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
        pet.show()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Claude Pet")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        let port = ProcessInfo.processInfo.environment["CLAUDE_PET_PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        server = EventServer(preferredPort: port)
        server.onReady = { port in Endpoint.publish(port: port) }
        server.onDuplicate = { port in
            NSLog("claude-pet: une autre instance tourne déjà sur le port %d, on quitte", Int(port))
            NSApp.terminate(nil)
        }
        server.onEvent = { [unowned self] event in
            self.tracker.handle(event)
            if let id = event["session_id"] as? String {
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

        server.onStatus = { [unowned self] status in
            self.quotas.handleStatus(status)
            self.refresh()
        }
        server.onControl = { [unowned self] control in
            if let notch = control["notch"] as? Bool { self.pet.setNotchMode(notch) }
            let radius = (control["notch_radius"] as? Double).map { CGFloat($0) }
            let ear = (control["notch_ear"] as? Double).map { CGFloat($0) }
            if radius != nil || ear != nil { self.pet.tuneNotch(radius: radius, ear: ear) }
        }
        server.stateProvider = { [unowned self] in
            var snapshot = self.tracker.snapshot()
            snapshot["port"] = self.server.port.map { Int($0) } ?? NSNull()
            snapshot["quotas"] = self.quotas.snapshot()
            snapshot["usage_api"] = self.usageAPI.status
            snapshot["notch"] = self.pet.mode != .floating
            snapshot["notch_radius"] = Double(NotchGeometry.bottomRadius)
            snapshot["notch_ear"] = Double(NotchGeometry.earRadius)
            return snapshot
        }
        server.onStatusChange = { [unowned self] status in
            self.serverStatus = status
            NSLog("claude-pet: %@", status)
        }
        server.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [unowned self] _ in
            self.ticks += 1
            // Claude Desktop rewrites its usage history at most every 270 s: a stat every 30 s is plenty.
            if self.ticks % 120 == 0 { self.quotas.reloadDesktopHistory() }
            self.tracker.tick()
            self.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Endpoint.unpublish()
    }

    private func refresh() {
        let display = tracker.display()
        pet.update(state: display.state, tool: display.tool)
        let leader = tracker.leader
        pet.updateGauges(quotas.gauges(
            leader: leader?.id,
            leaderFolder: leader?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        ))
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu().items.forEach { item in
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let display = tracker.display()
        var status = "Claude \(display.state.label)"
        if let tool = tracker.leader?.toolName, display.state == .working { status += " (\(tool))" }
        menu.addItem(disabled: status)
        let count = tracker.sessions.count
        menu.addItem(disabled: count == 1 ? "1 session suivie" : "\(count) sessions suivies")
        menu.addItem(disabled: "Serveur : \(serverStatus)")
        var quotaStatus = "Quotas (API) : \(usageAPI.status)"
        if let last = usageAPI.lastSuccess, usageAPI.status != "à jour" {
            quotaStatus += ", dernier succès il y a \(QuotaStore.duration(last, Date()))"
        }
        menu.addItem(disabled: quotaStatus)
        menu.addItem(.separator())

        menu.addItem(action: pet.isVisible ? "Masquer" : "Afficher", key: "h") { [unowned self] in
            self.pet.isVisible ? self.pet.hide() : self.pet.show()
        }

        let notchAvailable = pet.notchAvailable
        let notchItem = menu.addItem(action: notchAvailable ? "Vivre dans l'encoche" : "Vivre dans l'encoche (aucune encoche)", key: "n") { [unowned self] in
            self.pet.setNotchMode(!self.pet.wantsNotch)
        }
        notchItem.state = pet.wantsNotch ? .on : .off
        notchItem.isEnabled = notchAvailable && !pet.isTransitioning

        let apiItem = menu.addItem(action: "Lire les quotas avec le compte Claude Code") { [unowned self] in
            OAuthUsageSource.isEnabled.toggle()
            OAuthUsageSource.isEnabled ? self.usageAPI.start() : self.usageAPI.stop()
        }
        apiItem.state = OAuthUsageSource.isEnabled ? .on : .off

        let docked = pet.mode != .floating
        let position = NSMenu()
        let corners: [(String, PetController.Corner)] = [
            ("En bas à droite", .bottomRight), ("En bas à gauche", .bottomLeft),
            ("En haut à droite", .topRight), ("En haut à gauche", .topLeft),
        ]
        for (title, corner) in corners {
            position.addItem(action: title) { [unowned self] in self.pet.move(to: corner) }
        }
        menu.addItem(submenu: position, title: "Position").isEnabled = !docked

        let size = NSMenu()
        for scale in 3...8 {
            let item = size.addItem(action: "×\(scale)") { [unowned self] in self.pet.setScale(scale) }
            item.state = scale == pet.scale ? .on : .off
        }
        menu.addItem(submenu: size, title: "Taille")

        menu.addItem(.separator())
        menu.addItem(action: "Quitter Claude Pet", key: "q") { NSApp.terminate(nil) }
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

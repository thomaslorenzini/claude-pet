import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let defaultPort: UInt16 = 47319

    private let tracker = SessionTracker()
    private var pet: PetController!
    private var server: EventServer!
    private var statusItem: NSStatusItem!
    private var serverStatus = "démarrage…"
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        server = EventServer(port: port)
        server.onEvent = { [unowned self] event in
            self.tracker.handle(event)
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
            self.tracker.tick()
            self.refresh()
        }
    }

    private func refresh() {
        let display = tracker.display()
        pet.update(state: display.state, tool: display.tool)
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

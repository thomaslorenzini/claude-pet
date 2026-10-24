import AppKit
import ServiceManagement

/// Opening the app at login, through `SMAppService.mainApp`. The truth is the system's, never a saved
/// flag of ours: the user can remove the item from System Settings › General › Login Items at any time.
enum LoginItem {
    enum State: String { case on, off, needsApproval, unavailable }

    /// Only a real `.app` can be a login item: `swift run` and the debug binary cannot.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var state: State {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    /// Returns an error message to show, or nil.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard isAvailable else { return tr("Seulement pour l'app installée", "Only for the installed app") }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("claude-pet: ouverture au démarrage (%@) : %@", on ? "on" : "off", error.localizedDescription)
            // Already in the requested state is not a failure.
            if (on && state == .on) || (!on && state == .off) { return nil }
            return error.localizedDescription
        }
        // Disabled by the user in System Settings: only they can allow it again, from there.
        if on, state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
        return nil
    }
}

import AppKit
import Sparkle

/// Self-updates, through Sparkle. Once a day it reads the appcast attached to the latest GitHub release;
/// a newer version is downloaded in the background, checked, and installed when the app quits, or at
/// once from "Restart to update" (panel, settings, the pet's menu).
///
/// Why it is safe although the app is only ad hoc signed (its Apple signature changes with every build):
/// - the archive must carry an EdDSA signature made with the private key that only Thomas holds; the
///   public key is in Info.plist (`SUPublicEDKey`), and Sparkle checks it **before** opening the disk
///   image (`SUVerifyUpdateBeforeExtraction`). A wrong signature rejects the update, whoever serves it;
/// - the appcast itself is signed with the same key (`SURequireSignedFeed`): a changed feed is refused;
/// - HTTPS only, no system profile sent (`SUEnableSystemProfiling` is off by default).
/// Sparkle's own rule (SUUpdateValidator): a valid EdDSA signature is enough, the new app's Apple
/// signature only has to be valid, not identical.
final class UpdateChecker: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// The old "check once a day" switch (0.1.1): carried over once into Sparkle's own setting.
    private static let legacyEnabledKey = "updateCheckEnabled"
    static let releasesPage = URL(string: "https://github.com/thomaslorenzini/claude-pet/releases/latest")!

    enum State: Equatable {
        /// No Sparkle: the bare debug binary is not an app bundle.
        case unavailable
        case notChecked
        case checking
        case upToDate
        /// Found, not downloaded yet (downloading, or automatic updates are off).
        case available(version: String)
        /// Downloaded and verified: installed when the app quits, or now from "Restart".
        case ready(version: String)
        case failed(String)

        var name: String {
            switch self {
            case .unavailable: return "unavailable"
            case .notChecked: return "not_checked"
            case .checking: return "checking"
            case .upToDate: return "up_to_date"
            case .available: return "available"
            case .ready: return "ready"
            case .failed: return "failed"
            }
        }
    }

    var onChange: (() -> Void)?
    let currentVersion: String? = Bundle.main.bundleURL.pathExtension == "app"
        ? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String : nil
    private var controller: SPUStandardUpdaterController?
    private var checking = false
    private var found: String?
    /// The last failure, in Sparkle's words (also in `GET /state`, `update_error`).
    private(set) var lastError: String?
    /// Sparkle's way to install a downloaded update now instead of at quit.
    private var installNow: (() -> Void)?

    private var updater: SPUUpdater? { controller?.updater }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }
    var latestVersion: String? { found }

    /// Daily check plus background download. Off: nothing happens until "Check now".
    var isAutomatic: Bool {
        get { updater.map { $0.automaticallyChecksForUpdates && $0.automaticallyDownloadsUpdates } ?? false }
        set {
            updater?.automaticallyChecksForUpdates = newValue
            updater?.automaticallyDownloadsUpdates = newValue
            onChange?()
        }
    }

    var state: State {
        guard updater != nil else { return .unavailable }
        if let found, installNow != nil { return .ready(version: found) }
        // A download that failed its checks says so, rather than offering to install it.
        if let lastError { return .failed(lastError) }
        if let found { return .available(version: found) }
        if checking { return .checking }
        return lastCheck == nil ? .notChecked : .upToDate
    }

    func start() {
        guard currentVersion != nil, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        do {
            try controller.updater.start()
        } catch {
            NSLog("claude-pet: mises à jour : Sparkle n'a pas démarré (%@)", error.localizedDescription)
            self.controller = nil
            return
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.legacyEnabledKey) as? Bool == false { isAutomatic = false }
        defaults.removeObject(forKey: Self.legacyEnabledKey)
        // Left by 0.1.x's GitHub check: Sparkle says what is newer now.
        for key in ["updateNextCheck", "updateLastCheck", "updateLatestVersion", "updateLatestURL", "updateLastRequest", "updateBlockedUntil"] {
            defaults.removeObject(forKey: key)
        }
        onChange?()
    }

    /// "Check now": Sparkle's own window (checking, then the release notes and "Install", or "up to date").
    func checkManually() {
        guard let updater, updater.canCheckForUpdates else { return }
        // An accessory app is never active by itself: Sparkle's window would open behind.
        NSApp.activate(ignoringOtherApps: true)
        checking = true
        lastError = nil
        onChange?()
        updater.checkForUpdates()
    }

    /// `POST /control {"check_updates": true}`: a check without any window, as the daily one.
    func checkInBackground() {
        guard let updater, updater.canCheckForUpdates else { return }
        checking = true
        onChange?()
        updater.checkForUpdatesInBackground()
    }

    /// The button next to "Version X ready" or "available": install now, or show Sparkle's window to do so.
    func install() {
        if let installNow {
            NSLog("claude-pet: mises à jour : installation de la v%@ et relance", found ?? "?")
            installNow()
        } else if found != nil {
            checkManually()
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Tests only: CLAUDE_PET_FEED_URL (environment or defaults) points at a local feed. The EdDSA key
    /// still has to match, so this can't install anything Thomas didn't sign.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["CLAUDE_PET_FEED_URL"] ?? UserDefaults.standard.string(forKey: "CLAUDE_PET_FEED_URL")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found = item.displayVersionString
        lastError = nil
        NSLog("claude-pet: mises à jour : v%@ disponible (installée : %@)", found ?? "?", currentVersion ?? "?")
        onChange?()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        found = nil
        installNow = nil
        lastError = nil
        onChange?()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        found = item.displayVersionString
        installNow = immediateInstallationBlock
        NSLog("claude-pet: mises à jour : v%@ téléchargée et vérifiée, installée à la fermeture", found ?? "?")
        onChange?()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        // "No update" and "cancelled by the user" also end here: not failures.
        guard code != Int(SUError.noUpdateError.rawValue), code != Int(SUError.installationCanceledError.rawValue) else { return }
        lastError = error.localizedDescription
        NSLog("claude-pet: mises à jour : échec (%@)", error.localizedDescription)
        onChange?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        checking = false
        onChange?()
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A background app: Sparkle doesn't pop a window on its own for a scheduled check; the panel, the
    /// settings and the pet's menu say an update is there instead.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

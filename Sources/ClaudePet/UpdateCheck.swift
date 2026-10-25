import AppKit

/// Once a day, asks GitHub which version is the latest release, to say "Update available" in the panel
/// and the settings. It never downloads or installs anything: the app is only ad hoc signed, so replacing
/// itself without checking a signature would be a hole. A click opens the release page, nothing more.
///
/// Safety rules, as in `OAuthUsageSource`:
/// - GET only, to one fixed URL, no redirects, no cookies, no cache, no account.
/// - One request a day at most, across relaunches (the next date is saved); failures wait for the next
///   daily slot, a rate limit (403/429) waits at least as long as GitHub asks.
/// - The page opened on click is only ever on the project's GitHub: anything else falls back to the
///   releases page.
final class UpdateChecker: NSObject, URLSessionTaskDelegate {
    static let enabledKey = "updateCheckEnabled"
    private static let nextCheckKey = "updateNextCheck"
    private static let lastCheckKey = "updateLastCheck"
    private static let latestVersionKey = "updateLatestVersion"
    private static let latestURLKey = "updateLatestURL"

    private static let apiURL = URL(string: "https://api.github.com/repos/thomaslorenzini/claude-pet/releases/latest")!
    private static let pagePrefix = "https://github.com/thomaslorenzini/claude-pet/"
    static let releasesPage = URL(string: "https://github.com/thomaslorenzini/claude-pet/releases/latest")!
    private static let interval: TimeInterval = 24 * 3600
    private static let launchDelay: TimeInterval = 60

    enum State: Equatable {
        /// Turned off in the settings.
        case off
        /// No version to compare with: the bare debug binary has no bundle.
        case unavailable
        case notChecked
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)

        var name: String {
            switch self {
            case .off: return "off"
            case .unavailable: return "unavailable"
            case .notChecked: return "not_checked"
            case .checking: return "checking"
            case .upToDate: return "up_to_date"
            case .available: return "available"
            case .failed: return "failed"
            }
        }
    }

    var onChange: (() -> Void)?
    /// The running version: CLAUDE_PET_VERSION_OVERRIDE (tests), else the bundle's. Nil for the debug binary.
    let currentVersion: String? = {
        let env = ProcessInfo.processInfo.environment["CLAUDE_PET_VERSION_OVERRIDE"]
        return env.flatMap { $0.isEmpty ? nil : $0 } ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }()
    private var checking = false
    private var lastError: String?
    /// `POST /control {"fake_latest": "9.9.9"}`: pretends GitHub answered this, in memory only.
    private var fakeLatest: String?
    private var timer: Timer?
    private var wakeObserver: Any?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date }

    /// The newest version known, from the last successful check (or the fake one).
    var latestVersion: String? { fakeLatest ?? UserDefaults.standard.string(forKey: Self.latestVersionKey) }

    var state: State {
        guard Self.isEnabled else { return .off }
        guard let current = currentVersion else { return .unavailable }
        if checking { return .checking }
        if let latest = latestVersion, Self.isNewer(latest, than: current) {
            let page = fakeLatest == nil ? UserDefaults.standard.string(forKey: Self.latestURLKey).flatMap(Self.trustedPage) : nil
            return .available(version: latest, page: page ?? Self.releasesPage)
        }
        if let lastError { return .failed(lastError) }
        return latestVersion == nil ? .notChecked : .upToDate
    }

    /// At launch: the first check about a minute later, unless the last one is less than a day old.
    func start(soon: Bool = false) {
        guard Self.isEnabled, currentVersion != nil else { return }
        if wakeObserver == nil {
            // A long timer may fire late after the Mac slept: look again at the saved date on wake.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.reschedule() }
        }
        if soon { reschedule(minimum: 2) } else { reschedule() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        lastError = nil
        onChange?()
    }

    /// `POST /control {"check_updates": true}`: checks now, whatever the saved date.
    func checkNow() {
        guard Self.isEnabled, currentVersion != nil else { return }
        fetch()
    }

    /// Tests: "" goes back to what GitHub said last.
    func fake(latest: String) {
        fakeLatest = latest.isEmpty ? nil : Self.cleanVersion(latest)
        onChange?()
    }

    func openPage() {
        if case .available(_, let page) = state { NSWorkspace.shared.open(page) }
    }

    /// Never sooner than a minute after launch or wake: the network may not be back yet.
    private func reschedule(minimum: TimeInterval = UpdateChecker.launchDelay) {
        guard Self.isEnabled, currentVersion != nil else { return }
        let next = UserDefaults.standard.object(forKey: Self.nextCheckKey) as? Date
        // Clamped to a day: a clock set back must not push the check months away.
        let delay = min(Self.interval, max(minimum, next?.timeIntervalSinceNow ?? 0))
        schedule(after: delay)
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.fetch() }
        // A daily check can drift by minutes: let the system batch it with other wake-ups.
        timer.tolerance = min(3600, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Saves the next slot before the request goes out, so a crash or a quit never makes it retry sooner.
    private func setNextCheck(after delay: TimeInterval) {
        UserDefaults.standard.set(Date().addingTimeInterval(delay), forKey: Self.nextCheckKey)
        schedule(after: delay)
    }

    private func fetch() {
        guard Self.isEnabled, let current = currentVersion, !checking else { return }
        checking = true
        setNextCheck(after: Self.interval)
        onChange?()
        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudePet/\(current)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, _ in
            self?.handle(data: data, response: response as? HTTPURLResponse)
        }.resume()
    }

    private func handle(data: Data?, response: HTTPURLResponse?) {
        checking = false
        defer { onChange?() }
        guard let response else {
            return fail(tr("réseau indisponible", "network unavailable"))
        }
        switch response.statusCode {
        case 200:
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let version = Self.cleanVersion(tag) else {
                return fail(tr("réponse illisible", "unreadable response"))
            }
            lastError = nil
            let defaults = UserDefaults.standard
            defaults.set(Date(), forKey: Self.lastCheckKey)
            defaults.set(version, forKey: Self.latestVersionKey)
            defaults.set((json["html_url"] as? String).flatMap(Self.trustedPage)?.absoluteString, forKey: Self.latestURLKey)
            NSLog("claude-pet: mises à jour : dernière version %@, installée %@", version, currentVersion ?? "?")
        case 403, 429:
            // Rate limited (60 requests an hour without an account): wait at least until GitHub says so.
            let headers = response.allHeaderFields
            func header(_ name: String) -> TimeInterval? {
                (headers.first { ($0.key as? String)?.lowercased() == name }?.value as? String).flatMap(TimeInterval.init)
            }
            let wait = header("retry-after") ?? header("x-ratelimit-reset").map { $0 - Date().timeIntervalSince1970 } ?? 0
            if wait > Self.interval { setNextCheck(after: wait) }
            fail(tr("GitHub limite les requêtes", "rate limited by GitHub"))
        default:
            fail(tr("erreur HTTP", "HTTP error") + " \(response.statusCode)")
        }
    }

    /// The next try is already saved for tomorrow: nothing to do but say why.
    private func fail(_ message: String) {
        lastError = message
        NSLog("claude-pet: mises à jour : échec (%@), nouvel essai dans 24 h", message)
    }

    // Redirects are never followed: the request only ever goes to the one URL above.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: Versions

    /// "v0.1.10" → "0.1.10". Only digits and dots, a few components: anything else is not shown.
    static func cleanVersion(_ tag: String) -> String? {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return s
    }

    /// Numeric, component by component, missing ones count as 0: 0.1.10 > 0.1.9, 0.2 == 0.2.0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func numbers(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func trustedPage(_ string: String) -> URL? {
        guard string.hasPrefix(pagePrefix), let url = URL(string: string), url.host == "github.com" else { return nil }
        return url
    }
}

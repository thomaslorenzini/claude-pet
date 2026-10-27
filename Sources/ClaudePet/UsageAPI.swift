import CryptoKit
import Foundation
import Security

/// Subscription quotas from Anthropic's OAuth usage endpoint, the way other usage monitors do it
/// (ccusage / clanker-usage, claude-hud…), with the login Claude Code already holds.
///
/// Safety rules:
/// - The token is read from the Keychain item Claude Code owns ("Claude Code-credentials"), through
///   `/usr/bin/security` like Claude Code does (see `readWithSecurityTool`). It stays in memory only,
///   is never logged or written.
/// - It is never refreshed or written here: rewriting Claude Code's credentials could break its own
///   login. When it has expired (Claude Desktop sessions use their own auth and never renew it), the
///   app asks Claude Code to renew it the way any new session would: `claude -p /usage` (see
///   `CLIRenewal`), then reads the Keychain again.
/// - GET only, to one fixed URL, no redirects, no cookies, every 5 minutes, backing off on errors.
final class OAuthUsageSource: NSObject, URLSessionTaskDelegate {
    static let enabledKey = "usageAPIEnabled"
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Anthropic's edge answers 403 to other User-Agents.
    private static let userAgent = "claude-code/2.1.300"
    private static let interval: TimeInterval = 5 * 60

    var onUpdate: ((QuotaStore.Window?, QuotaStore.Window?) -> Void)?
    /// Changes of `needsLogin`, for the settings' "Connect Claude Code" row.
    var onLoginNeed: (() -> Void)?
    private(set) var status = tr("pas encore interrogée", "not queried yet")
    /// Claude Code holds no usable login (no Keychain item, or one without a token): only a new sign-in,
    /// which only the user can start, brings the quotas back. An expired token is not this case.
    private(set) var needsLogin = false {
        didSet { if oldValue != needsLogin { onLoginNeed?() } }
    }
    private(set) var lastSuccess: Date?
    private static let upToDate = tr("à jour", "up to date")
    var isUpToDate: Bool { status == Self.upToDate }
    /// Expiry of the token last read from the Keychain (not secret), for diagnostics.
    private(set) var tokenExpiresAt: Date?
    /// While the token is expired, only the Keychain is re-read (local, free): no request is sent.
    private static let expiredRecheck: TimeInterval = 60

    private var token: (value: String, expiresAt: Date?)?
    private var timer: Timer?
    private var backoff: TimeInterval = 0
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func start() {
        guard Self.isEnabled else {
            status = tr("désactivée", "off")
            return
        }
        schedule(after: 2)
    }

    /// Asks Claude Code to renew its token now (`POST /control {"renew_usage_token": true}`), for tests.
    func renewNow() {
        token = nil
        CLIRenewal.run(force: true) { [weak self] in self?.schedule(after: 1) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        token = nil
        needsLogin = false
        status = tr("désactivée", "off")
    }

    /// Reads the Keychain again now, after a sign-in.
    func reload() {
        guard Self.isEnabled else { return }
        token = nil
        backoff = 0
        schedule(after: 0.5)
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.fetch() }
        // A few seconds either way does not matter for a 5-minute poll.
        timer.tolerance = min(10, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fail(_ message: String, retryIn delay: TimeInterval? = nil) {
        status = message
        backoff = min(3600, max(Self.interval, backoff * 2))
        schedule(after: delay ?? backoff)
    }

    private func fetch() {
        guard Self.isEnabled else { return }
        if let token, let expiry = token.expiresAt, expiry < Date() { self.token = nil }
        if token == nil {
            switch Self.readToken() {
            case .success(let t):
                token = t
                needsLogin = false
            case .signedOut(let message):
                needsLogin = true
                // Local and free to check: soon after a sign-in from the terminal, the quotas come back.
                fail(message, retryIn: Self.expiredRecheck)
                return
            case .failure(let message):
                fail(message)
                return
            }
        }
        guard let token else { return }
        tokenExpiresAt = token.expiresAt
        if let expiry = token.expiresAt, expiry < Date() {
            // Not a server failure: no backoff. Let Claude Code renew it, then look at the Keychain again.
            self.token = nil
            status = tr("jeton expiré depuis \(QuotaStore.duration(expiry, Date())), renouvellement par Claude Code…", "token expired \(QuotaStore.duration(expiry, Date())) ago, Claude Code is renewing it…")
            if !CLIRenewal.run(completion: { [weak self] in self?.schedule(after: 1) }) {
                schedule(after: Self.expiredRecheck)
            }
            return
        }
        var request = URLRequest(url: Self.url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, error in
            self?.handle(data: data, response: response as? HTTPURLResponse, error: error)
        }.resume()
    }

    private func handle(data: Data?, response: HTTPURLResponse?, error: Error?) {
        guard let response else {
            fail(tr("réseau indisponible", "network unavailable"))
            return
        }
        switch response.statusCode {
        case 200:
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fail(tr("réponse illisible", "unreadable response"))
                return
            }
            let (five, week) = Self.parse(json, now: Date())
            guard five != nil || week != nil else {
                fail(tr("réponse sans quotas (format changé ?)", "response without quotas (format changed?)"))
                return
            }
            backoff = 0
            lastSuccess = Date()
            status = Self.upToDate
            onUpdate?(five, week)
            schedule(after: Self.interval)
        case 401:
            // Claude Code may have renewed the token since: read it again soon.
            token = nil
            status = tr("jeton refusé, en attente que Claude Code le renouvelle", "token refused, waiting for Claude Code to renew it")
            schedule(after: Self.expiredRecheck)
        case 403:
            fail(tr("pas d'abonnement Pro/Max, ou OAuth désactivé par l'organisation", "no Pro/Max plan, or OAuth turned off by the organization"), retryIn: 3600)
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            fail(tr("trop de requêtes, nouvel essai plus tard", "too many requests, retrying later"), retryIn: retry.map { max($0, Self.interval) })
        default:
            fail(tr("erreur HTTP", "HTTP error") + " \(response.statusCode)")
        }
    }

    // Redirects are never followed: the token must only ever go to the one URL above.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    // MARK: Parsing

    /// Reads both shapes seen in the wild: the `limits` array (`session`, `weekly_all`) and the older
    /// flat `five_hour` / `seven_day` objects with `utilization`.
    static func parse(_ json: [String: Any], now: Date) -> (QuotaStore.Window?, QuotaStore.Window?) {
        func date(_ value: Any?) -> Date? {
            guard let s = value as? String else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        func window(_ percent: Any?, _ reset: Any?) -> QuotaStore.Window? {
            guard let p = (percent as? NSNumber)?.doubleValue, p.isFinite, (0...100).contains(p) else { return nil }
            return QuotaStore.Window(usedPercentage: p, resetsAt: date(reset), updated: now, source: .oauthAPI)
        }
        var five: QuotaStore.Window?, week: QuotaStore.Window?
        if let limits = json["limits"] as? [[String: Any]] {
            for entry in limits {
                switch entry["kind"] as? String {
                case "session": five = five ?? window(entry["percent"], entry["resets_at"])
                case "weekly_all": week = week ?? window(entry["percent"], entry["resets_at"])
                default: break
                }
            }
        }
        if five == nil, let f = json["five_hour"] as? [String: Any] { five = window(f["utilization"], f["resets_at"]) }
        if week == nil, let w = json["seven_day"] as? [String: Any] { week = window(w["utilization"], w["resets_at"]) }
        return (five, week)
    }

    // MARK: Keychain

    private enum TokenResult {
        case success((value: String, expiresAt: Date?))
        /// Nothing a renewal can fix: Claude Code must be signed in again.
        case signedOut(String)
        case failure(String)
    }

    private static let notSignedIn = tr("Claude Code n'est pas connecté", "Claude Code isn't signed in")

    private static func readToken() -> TokenResult {
        var data: Data
        switch readWithSecurityTool() {
        case .some(.some(let d)): data = d
        case .some(.none): return .signedOut(notSignedIn)
        case .none:
            switch readWithSecItem() {
            case .success(let d): data = d
            case .missing: return .signedOut(notSignedIn)
            case .failure(let message): return .failure(message)
            }
        }
        // `security -w` prints the secret as hex when it holds bytes it won't print as text.
        if data.first != UInt8(ascii: "{"), let decoded = hexDecoded(data) { data = decoded }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(tr("identifiants Claude Code illisibles", "unreadable Claude Code credentials"))
        }
        // Signed in with a Console API key: there are no subscription quotas to read.
        guard let login = json["claudeAiOauth"] as? [String: Any] else {
            return .signedOut(tr("Claude Code n'est pas connecté à un abonnement Claude", "Claude Code isn't signed in to a Claude plan"))
        }
        // Seen in the wild: the item left in place with its tokens emptied.
        guard let value = login["accessToken"] as? String, !value.isEmpty else {
            return .signedOut(tr("Claude Code est déconnecté", "Claude Code is signed out"))
        }
        let expiry = (login["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return .success((value, expiry))
    }

    private static func hexDecoded(_ data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count.isMultiple(of: 2), !text.isEmpty else { return nil }
        var bytes = [UInt8](), index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Reads the item through `/usr/bin/security`, the way Claude Code reads it itself. Claude Code
    /// rewrites the item with `security add-generic-password -U` on every token refresh, which resets its
    /// partition list to `apple-tool:` and drops our "Always Allow": a direct read would ask for the
    /// Keychain password again after each refresh, while the `security` tool stays allowed.
    /// Returns nil when the tool fails (the caller falls back to a direct read), `.some(nil)` when
    /// there is no such item.
    private static func readWithSecurityTool() -> Data?? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", ClaudeCodeCLI.keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 44 is errSecItemNotFound's exit status.
        if process.terminationStatus == 44 { return .some(nil) }
        guard process.terminationStatus == 0 else { return nil }
        var trimmed = data
        while trimmed.last == 0x0A { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : .some(trimmed)
    }

    private enum DataResult {
        case success(Data)
        case missing
        case failure(String)
    }

    private static func readWithSecItem() -> DataResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ClaudeCodeCLI.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return .missing
        case errSecUserCanceled, errSecAuthFailed: return .failure(tr("accès au Trousseau refusé", "Keychain access denied"))
        default: return .failure(tr("Trousseau indisponible", "Keychain unavailable") + " (\(status))")
        }
        guard let data = item as? Data else {
            return .failure(tr("identifiants Claude Code illisibles", "unreadable Claude Code credentials"))
        }
        return .success(data)
    }
}

/// Lets Claude Code renew its own OAuth token by running `claude -p /usage`: the same code path as any
/// new CLI session, no model request (/usage only reads the quotas), no hooks, no saved session.
/// The environment is clean on purpose: inherited from a Claude Desktop session, the CLI would use
/// Desktop's auth instead of its own Keychain login.
enum CLIRenewal {
    /// At most one run per 10 minutes, whatever happens.
    private static let minInterval: TimeInterval = 10 * 60
    private static var lastRun: Date?
    private static var running = false

    /// Returns false when nothing was started (already running, too soon, or no `claude` found).
    @discardableResult
    static func run(force: Bool = false, completion: @escaping () -> Void) -> Bool {
        guard !running, force || lastRun.map({ Date().timeIntervalSince($0) >= minInterval }) ?? true,
              let claude = ClaudeCodeCLI.executable() else { return false }
        running = true
        lastRun = Date()
        let process = Process()
        process.executableURL = claude
        process.arguments = ["-p", "/usage", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#]
        process.environment = ClaudeCodeCLI.environment(for: claude)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // The output (quotas, account) is not needed: the app reads the API itself afterwards.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                running = false
                completion()
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
        return true
    }

}

/// Where Claude Code is and how to run it outside any session: shared by the renewal and the sign-in.
enum ClaudeCodeCLI {
    /// Tests only: a separate Claude Code config, hence a separate Keychain item, never the real login.
    static let configDir = AppDelegate.devSetting("CLAUDE_PET_CLAUDE_CONFIG_DIR")

    /// Claude Code names its item after its config folder when one is set: `-<sha256(folder)[0:8]>`.
    static var keychainService: String {
        guard let configDir else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }

    /// The terminal's `claude` first, then the copy Claude Desktop ships for its Code tab (newest
    /// version), so a Desktop-only user can sign in too.
    static func executable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        if let cli = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first(where: fm.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: cli)
        }
        let root = "\(home)/Library/Application Support/Claude/claude-code"
        let versions = ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            for build in (try? fm.contentsOfDirectory(atPath: "\(root)/\(version)")) ?? [] {
                let path = "\(root)/\(version)/\(build)/claude.app/Contents/MacOS/claude"
                if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// Clean on purpose: inherited from a Claude Desktop session, the CLI would use Desktop's auth.
    static func environment(for claude: URL) -> [String: String] {
        let user = NSUserName()
        var environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "USER": user, "LOGNAME": user, "TERM": "dumb",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + claude.deletingLastPathComponent().path,
        ]
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir }
        return environment
    }
}

/// Signs Claude Code in, on the user's click only: runs `claude auth login --claudeai`, which opens the
/// browser and stores the login in the Keychain itself (verified 2026-10-27 with Desktop's copy, no
/// terminal, no code to paste). The app never sees or writes the credentials.
final class ClaudeLogin {
    enum State: Equatable {
        case idle
        case waiting
        /// The account's email, when `claude auth status` gave it.
        case done(String?)
        case failed(String)
    }

    private(set) var state = State.idle { didSet { if oldValue != state { onChange?() } } }
    var onChange: (() -> Void)?
    /// After a successful sign-in: the quotas can be read again.
    var onSignedIn: (() -> Void)?
    private var process: Process?
    /// Long enough to create an account in the browser; then the wait stops.
    private static let timeout: TimeInterval = 10 * 60

    func start() {
        guard process == nil else { return }
        guard let claude = ClaudeCodeCLI.executable() else {
            state = .failed(tr("Claude Code introuvable : installe Claude Code ou Claude Desktop", "Claude Code not found: install Claude Code or Claude Desktop"))
            return
        }
        let process = Process()
        process.executableURL = claude
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = ClaudeCodeCLI.environment(for: claude)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Its output carries the sign-in URL's one-time state: not kept.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let ok = finished.terminationStatus == 0 && finished.terminationReason == .exit
            DispatchQueue.main.async { self?.finished(ok: ok, claude: claude) }
        }
        do {
            try process.run()
        } catch {
            state = .failed(tr("Claude Code n'a pas pu être lancé", "Claude Code couldn't be started"))
            return
        }
        self.process = process
        state = .waiting
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func cancel() { process?.terminate() }

    /// Once the quotas came back: a later sign-out shows the plain "Connect" row again.
    func reset() { if process == nil { state = .idle } }

    /// Before the app quits: no sign-in left waiting in the background.
    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func finished(ok: Bool, claude: URL) {
        process = nil
        guard ok else {
            state = .failed(tr("Connexion annulée ou refusée", "Sign-in cancelled or refused"))
            return
        }
        state = .done(nil)
        onSignedIn?()
        // Shows which account was signed in, so a wrong one is seen at once.
        let status = Process()
        status.executableURL = claude
        status.arguments = ["auth", "status"]
        status.environment = ClaudeCodeCLI.environment(for: claude)
        status.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        status.standardOutput = output
        status.standardError = FileHandle.nullDevice
        status.standardInput = FileHandle.nullDevice
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard (try? status.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            status.waitUntilExit()
            let email = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["email"] as? String
            DispatchQueue.main.async {
                if case .done = self?.state { self?.state = .done(email) }
            }
        }
    }
}

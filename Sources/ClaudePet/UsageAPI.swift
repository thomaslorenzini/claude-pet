import Foundation
import Security

/// Subscription quotas from Anthropic's OAuth usage endpoint, the way other usage monitors do it
/// (ccusage / clanker-usage, claude-hud…), with the login Claude Code already holds.
///
/// Safety rules:
/// - The token is read from the Keychain item Claude Code owns ("Claude Code-credentials"); macOS
///   asks the user before the first read. It stays in memory only, is never logged or written.
/// - It is never refreshed here: rewriting Claude Code's credentials could break its own login. An
///   expired token just means waiting until Claude Code renews it.
/// - GET only, to one fixed URL, no redirects, no cookies, every 5 minutes, backing off on errors.
final class OAuthUsageSource: NSObject, URLSessionTaskDelegate {
    static let enabledKey = "usageAPIEnabled"
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    /// Anthropic's edge answers 403 to other User-Agents.
    private static let userAgent = "claude-code/2.1.300"
    private static let interval: TimeInterval = 5 * 60

    var onUpdate: ((QuotaStore.Window?, QuotaStore.Window?) -> Void)?
    private(set) var status = "pas encore interrogée"
    private(set) var lastSuccess: Date?

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
            status = "désactivée"
            return
        }
        schedule(after: 2)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        token = nil
        status = "désactivée"
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.fetch() }
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
            case .success(let t): token = t
            case .failure(let message):
                fail(message)
                return
            }
        }
        guard let token else { return }
        if let expiry = token.expiresAt, expiry < Date() {
            self.token = nil
            fail("jeton expiré, en attente que Claude Code le renouvelle")
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
            fail("réseau indisponible")
            return
        }
        switch response.statusCode {
        case 200:
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fail("réponse illisible")
                return
            }
            let (five, week) = Self.parse(json, now: Date())
            guard five != nil || week != nil else {
                fail("réponse sans quotas (format changé ?)")
                return
            }
            backoff = 0
            lastSuccess = Date()
            status = "à jour"
            onUpdate?(five, week)
            schedule(after: Self.interval)
        case 401:
            // Claude Code may have renewed the token since: read it again next time.
            token = nil
            fail("jeton refusé, en attente que Claude Code le renouvelle")
        case 403:
            fail("pas d'abonnement Pro/Max, ou OAuth désactivé par l'organisation", retryIn: 3600)
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            fail("trop de requêtes, nouvel essai plus tard", retryIn: retry.map { max($0, Self.interval) })
        default:
            fail("erreur HTTP \(response.statusCode)")
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
        case failure(String)
    }

    private static func readToken() -> TokenResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return .failure("Claude Code n'est pas connecté (rien dans le Trousseau)")
        case errSecUserCanceled, errSecAuthFailed: return .failure("accès au Trousseau refusé")
        default: return .failure("Trousseau indisponible (\(status))")
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["claudeAiOauth"] as? [String: Any],
              let value = login["accessToken"] as? String, !value.isEmpty else {
            return .failure("identifiants Claude Code illisibles")
        }
        let expiry = (login["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return .success((value, expiry))
    }
}

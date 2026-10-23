import Foundation

/// Usage gauges: the 5-hour and weekly subscription quotas, and the context window of each session.
///
/// Nothing official stores these numbers, so several read-only sources feed the store and the
/// most recent reading wins:
/// - Anthropic's OAuth usage endpoint (`OAuthUsageSource`), like other usage monitors: fresh quotas
///   everywhere, polled every 5 minutes;
/// - the Claude Code status line JSON (`POST /status`, CLI sessions only): quotas and exact context;
/// - Claude Desktop's `plan-usage-history.json` (quotas, written by Desktop at most every 270 s,
///   when it writes at all);
/// - the session transcript (context estimate, works for Desktop sessions too).
/// A reading too old for its window is shown as unknown, never as 0 %.
final class QuotaStore {
    enum Source: String, Codable {
        case statusLine, desktopHistory, oauthAPI

        var label: String {
            switch self {
            case .statusLine: return tr("ligne de statut", "status line")
            case .desktopHistory: return "Claude Desktop"
            case .oauthAPI: return tr("API Anthropic", "Anthropic API")
            }
        }
    }

    struct Window: Codable, Equatable {
        var usedPercentage: Double
        var resetsAt: Date?
        var updated: Date
        var source: Source
    }

    struct Context {
        var usedPercentage: Double
        var size: Int?
        var updated: Date
        /// From the transcript: the window size is guessed and fixed overheads may be missed.
        var estimated: Bool
    }

    enum Kind: Int, CaseIterable { case fiveHour, week, context }

    private static let defaultsKey = "quotaWindows.v2"
    static let desktopHistory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

    private(set) var fiveHour: Window?
    private(set) var week: Window?
    private var contexts: [String: Context] = [:]
    private var historyModified: Date?
    /// Top-level keys of the last status line payload, to see what a given Claude client sends.
    private var lastStatusKeys: [String] = []
    private var lastStatusAt: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            fiveHour = saved.fiveHour
            week = saved.week
        }
        reloadDesktopHistory()
    }

    // MARK: Sources

    func handleStatus(_ json: [String: Any], now: Date = Date()) {
        lastStatusKeys = json.keys.sorted()
        lastStatusAt = now
        if let limits = json["rate_limits"] as? [String: Any] {
            func window(_ value: Any?) -> Window? {
                guard let dict = value as? [String: Any], let used = Self.number(dict["used_percentage"]) else { return nil }
                return Window(
                    usedPercentage: used, resetsAt: Self.number(dict["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                    updated: now, source: .statusLine
                )
            }
            offer(five: window(limits["five_hour"]), week: window(limits["seven_day"]))
        }
        if let id = json["session_id"] as? String,
           let window = json["context_window"] as? [String: Any],
           let used = Self.number(window["used_percentage"]) {
            let size = Self.number(window["context_window_size"]).map { Int($0) }
            contexts[id] = Context(usedPercentage: used, size: size, updated: now, estimated: false)
        }
    }

    /// Re-reads Desktop's history file if it changed. Cheap enough to call on a timer (one stat).
    @discardableResult
    func reloadDesktopHistory() -> Bool {
        let url = Self.desktopHistory
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != historyModified else { return false }
        historyModified = modified
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = json["samples"] as? [[String: Any]],
              let last = samples.max(by: { (Self.number($0["t"]) ?? 0) < (Self.number($1["t"]) ?? 0) }),
              let t = Self.number(last["t"]) else { return false }
        let at = Date(timeIntervalSince1970: t / 1000)
        // v2 nests the buckets under "u", v1 had them at the top level.
        let buckets = last["u"] as? [String: Any] ?? last
        func window(_ value: Any?) -> Window? {
            if let used = Self.number(value) {
                return Window(usedPercentage: used, resetsAt: nil, updated: at, source: .desktopHistory)
            }
            guard let dict = value as? [String: Any], let used = Self.number(dict["utilization"]) else { return nil }
            let reset = (dict["resets_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return Window(usedPercentage: used, resetsAt: reset, updated: at, source: .desktopHistory)
        }
        offer(five: window(buckets["fh"]), week: window(buckets["sd"]))
        return true
    }

    /// Context estimate from the transcript's last API usage, for sessions without a status line.
    func estimateContext(session id: String, tokens: Int, now: Date = Date()) {
        if let existing = contexts[id], !existing.estimated, now.timeIntervalSince(existing.updated) < 120 { return }
        // The transcript does not say the window size: take it from a status line report of this
        // session if there was one (never from an earlier guess), else 1M. Claude Code's current models
        // run with a 1M window (an Opus session went past 540k): a 200k guess showed 5× too much.
        let known = contexts[id].flatMap { $0.estimated ? nil : $0.size }
        let size = known ?? 1_000_000
        contexts[id] = Context(
            usedPercentage: Double(tokens) / Double(size) * 100, size: size, updated: now, estimated: known == nil
        )
    }

    func forget(session id: String) {
        contexts[id] = nil
    }

    func offer(five: Window?, week: Window?) {
        if let five, five.updated >= (fiveHour?.updated ?? .distantPast) { fiveHour = five }
        if let week, week.updated >= (self.week?.updated ?? .distantPast) { self.week = week }
        save()
    }

    // MARK: Display

    /// The context shown: the session the pet follows if it reported one, else the latest report.
    func context(for session: String?) -> Context? {
        if let session, let c = contexts[session] { return c }
        return contexts.values.max { $0.updated < $1.updated }
    }

    /// One gauge: fraction 0…1 (nil when unknown), the detail line under the notch box, and a short
    /// title and note for the menu bar panel.
    struct Reading {
        var title: String
        var value: Double?
        var detail: String
        var note: String
    }

    func gauges(leader: String?, leaderFolder: String?, now: Date = Date()) -> [Reading] {
        func quota(_ name: String, _ title: String, _ w: Window?, length: TimeInterval) -> Reading {
            guard let w else { return Reading(title: title, detail: name + tr(" : pas encore de données", ": no data yet"), note: tr("pas de données", "no data")) }
            let age = now.timeIntervalSince(w.updated)
            if let reset = w.resetsAt, reset <= now {
                return Reading(title: title, detail: name + tr(" : fenêtre réinitialisée, en attente de nouvelles données", ": window reset, waiting for new data"), note: tr("réinitialisé", "reset"))
            }
            if w.resetsAt == nil, age > length {
                return Reading(title: title, detail: name + tr(" : pas de donnée récente", ": no recent data") + " (\(Self.duration(w.updated, now)), \(w.source.label))",
                               note: tr("donnée périmée", "stale data"))
            }
            var text = name + tr(" : ", ": ") + Self.percent(w.usedPercentage)
            var note = tr("à jour", "up to date")
            if let reset = w.resetsAt {
                text += tr(" · reset dans ", " · resets in ") + Self.duration(now, reset)
                note = tr("reset · ", "resets in ") + Self.duration(now, reset)
            }
            if age > 10 * 60 { text += tr(" · il y a \(Self.duration(w.updated, now))", " · \(Self.duration(w.updated, now)) ago") + " (\(w.source.label))" }
            return Reading(title: title, value: min(1, w.usedPercentage / 100), detail: text, note: note)
        }

        let five = quota(tr("Quota 5 h", "5-hour quota"), tr("5 heures", "5 hours"), fiveHour, length: 5 * 3600)
        let weekly = quota(tr("Quota semaine", "Weekly quota"), tr("Semaine", "Week"), week, length: 7 * 86400)
        let ctx: Reading
        if let c = context(for: leader) {
            var text = tr("Contexte : ", "Context: ") + (c.estimated ? "≈ " : "") + Self.percent(c.usedPercentage)
            var size = ""
            if let s = c.size { size = s >= 1_000_000 ? "\(s / 1_000_000)M" : "\(s / 1000)k" }
            if !size.isEmpty { text += tr(" de ", " of ") + size }
            if c.estimated { text += tr(" (estimé)", " (estimated)") }
            if let leaderFolder { text += " · \(leaderFolder)" }
            let note = [c.estimated ? tr("estimé", "estimated") : nil, size.isEmpty ? nil : tr("sur ", "of ") + size].compactMap { $0 }.joined(separator: " ")
            ctx = Reading(title: tr("Contexte", "Context"), value: min(1, c.usedPercentage / 100), detail: text, note: note)
        } else {
            ctx = Reading(title: tr("Contexte", "Context"), detail: tr("Contexte : pas encore de données", "Context: no data yet"), note: tr("pas de données", "no data"))
        }
        return [five, weekly, ctx]
    }

    func snapshot() -> [String: Any] {
        func w(_ w: Window?) -> Any {
            guard let w else { return NSNull() }
            let reset: Any = w.resetsAt.map { $0.timeIntervalSince1970 } ?? NSNull()
            return ["used_percentage": w.usedPercentage, "resets_at": reset,
                    "updated": w.updated.timeIntervalSince1970, "source": w.source.rawValue]
        }
        return [
            "five_hour": w(fiveHour), "seven_day": w(week),
            "last_status": ["keys": lastStatusKeys, "at": lastStatusAt.map { $0.timeIntervalSince1970 } ?? 0],
            "contexts": contexts.mapValues { ["used_percentage": $0.usedPercentage, "estimated": $0.estimated] },
        ]
    }

    // MARK: Helpers

    private struct Saved: Codable {
        var fiveHour: Window?
        var week: Window?
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(fiveHour: fiveHour, week: week)) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func percent(_ value: Double) -> String {
        value > 0 && value < 1 ? tr("<1 %", "<1%") : "\(Int(value.rounded()))" + tr(" %", "%")
    }

    /// "45 min", "2 h 05", "3 j 4 h" (English: "45 min", "2h 05", "3d 4h").
    static func duration(_ from: Date, _ to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? tr("\(d) j \(h) h", "\(d)d \(h)h") : tr("\(d) j", "\(d)d") }
        if h > 0 { return String(format: tr("%d h %02d", "%dh %02d"), h, m) }
        return "\(max(1, m)) min"
    }
}

/// Reads the last API usage of a session from the tail of its transcript (JSONL).
enum TranscriptUsage {
    private static let queue = DispatchQueue(label: "claude-pet.transcript", qos: .utility)
    private static var lastRead: [String: Date] = [:]

    /// Calls back on the main queue with the context tokens of the last assistant turn: input plus
    /// cache reads and writes (output tokens join the next turn's input). Throttled per transcript.
    static func read(_ path: String, completion: @escaping (Int) -> Void) {
        queue.async {
            if let last = lastRead[path], Date().timeIntervalSince(last) < 3 { return }
            lastRead[path] = Date()
            guard let handle = FileHandle(forReadingAtPath: path) else { return }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: end > 512 * 1024 ? end - 512 * 1024 : 0)
            guard let data = try? handle.readToEnd() else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
            where line.contains("\"usage\"") && line.contains("\"assistant\"") {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
                let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
                guard tokens > 0 else { continue }
                DispatchQueue.main.async { completion(tokens) }
                return
            }
        }
    }
}

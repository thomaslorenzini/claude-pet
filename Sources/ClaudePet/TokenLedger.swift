import Foundation

/// Every Claude response found in Claude Code's transcripts (`~/.claude/projects/*/*.jsonl`, subagents
/// included), with its model and token usage: the statistics window's data. Read only, never sent anywhere.
///
/// - A response takes one transcript line per content block, all with the same `message.id` and
///   `requestId`; streamed lines may carry a partial `output_tokens`. Responses are keyed by both ids and
///   keep their largest output. Forked or resumed sessions copy lines into several files: the key merges them.
/// - Files are read incrementally (an offset per file, complete lines only), and what was read is kept in
///   `token-stats.json`: launches stay cheap, and responses survive Claude Code deleting old transcripts.
/// - Nothing runs until the statistics are first needed (the window or the panel's row). The store is
///   rewritten whole, so at most once a minute while new lines come in, and once more on `flush()`.
final class TokenLedger {
    struct Entry: Codable {
        var time: Date
        var model: String
        var input: Int
        var output: Int
        var cacheWrite: Int
        var cacheRead: Int
        var session: String
        var project: String
    }

    static let shared = TokenLedger()

    /// Main queue only: the latest snapshot, sorted by time.
    private(set) var entries: [Entry] = []
    private(set) var isLoaded = false
    private(set) var lastRefresh: Date?

    private let queue = DispatchQueue(label: "claude-pet.tokens", qos: .utility)
    // Queue only.
    private var byKey: [String: Entry] = [:]
    private var offsets: [String: UInt64] = [:]
    private var restored = false
    private var isLoadedOnQueue = false
    /// Read past what the store holds: written by the next `save` that is due, or by `flush()`.
    private var dirty = false
    private var lastSave = Date.distantPast
    private static let saveInterval: TimeInterval = 60
    // Main queue only.
    private var running = false
    private var waiters: [() -> Void] = []

    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var store: URL { Endpoint.directory.appendingPathComponent("token-stats.json") }

    private struct Saved: Codable {
        var version = 1
        var offsets: [String: UInt64]
        var keys: [String]
        var entries: [Entry]
    }

    /// Reads what was appended since the last call, then calls back on the main queue. Calls made while
    /// a read runs share its result.
    func refresh(_ completion: (() -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        guard !running else { return }
        running = true
        queue.async {
            if !self.restored { self.restore() }
            let (moved, added) = self.scan()
            if moved { self.dirty = true }
            if self.dirty, Date().timeIntervalSince(self.lastSave) >= Self.saveInterval { self.save() }
            // Lines without a response (tool results, prompts) leave the list as it was.
            let snapshot = added || !self.isLoadedOnQueue ? self.byKey.values.sorted { $0.time < $1.time } : nil
            self.isLoadedOnQueue = true
            DispatchQueue.main.async {
                if let snapshot { self.entries = snapshot }
                self.isLoaded = true
                self.lastRefresh = Date()
                self.running = false
                let waiters = self.waiters
                self.waiters = []
                waiters.forEach { $0() }
            }
        }
    }

    /// Writes what the last reads found and the store does not hold yet. `wait`: before the app quits.
    func flush(wait: Bool = false) {
        let work = { if self.dirty { self.save() } }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    // MARK: Reading

    private func transcripts() -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        for project in projects {
            guard let items = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "jsonl" { files.append(item); continue }
                let subagents = item.appendingPathComponent("subagents")
                if let subs = try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil) {
                    files += subs.filter { $0.pathExtension == "jsonl" }
                }
            }
        }
        return files
    }

    /// `moved`: some file was read further; `added`: a response is new or grew.
    private func scan() -> (moved: Bool, added: Bool) {
        var moved = false, added = false
        for file in transcripts() {
            let path = file.path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else { continue }
            var offset = offsets[path] ?? 0
            // Rewritten from scratch: read it again (the keys drop what was already counted).
            if offset > size { offset = 0 }
            guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            // A line still being written waits for the next read.
            offsets[path] = offset + UInt64(lastNewline - data.startIndex + 1)
            moved = true
            var start = data.startIndex
            while start < lastNewline {
                let end = data[start...lastNewline].firstIndex(of: 0x0A) ?? lastNewline
                if end > start, parse(data[start..<end]) { added = true }
                start = end + 1
            }
        }
        return (moved, added)
    }

    private static let usageKey = Data("\"usage\"".utf8)
    private static let assistantKey = Data("\"assistant\"".utf8)
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// True when the line brought a new response, or a larger output for a known one.
    private func parse(_ line: Data) -> Bool {
        // Keys only match unescaped, so text quoted inside a message never passes for one.
        guard line.range(of: Self.usageKey) != nil, line.range(of: Self.assistantKey) != nil,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let id = message["id"] as? String,
              let stamp = json["timestamp"] as? String,
              let time = Self.isoFractional.date(from: stamp) ?? Self.iso.date(from: stamp)
        else { return false }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let key = id + "|" + (json["requestId"] as? String ?? "")
        let entry = Entry(time: time, model: model, input: int("input_tokens"), output: int("output_tokens"),
                          cacheWrite: int("cache_creation_input_tokens"), cacheRead: int("cache_read_input_tokens"),
                          session: json["sessionId"] as? String ?? "",
                          project: (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
        if let known = byKey[key], known.output >= entry.output { return false }
        byKey[key] = entry
        return true
    }

    // MARK: Store

    private func restore() {
        restored = true
        guard let data = try? Data(contentsOf: store),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == 1, saved.keys.count == saved.entries.count else { return }
        offsets = saved.offsets
        byKey = Dictionary(zip(saved.keys, saved.entries), uniquingKeysWith: { a, _ in a })
    }

    private func save() {
        dirty = false
        lastSave = Date()
        let keys = Array(byKey.keys)
        let saved = Saved(offsets: offsets, keys: keys, entries: keys.map { byKey[$0]! })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        do {
            try FileManager.default.createDirectory(at: Endpoint.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: store, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
        } catch {
            NSLog("claude-pet: impossible d'écrire %@ : %@", store.path, "\(error)")
        }
    }
}

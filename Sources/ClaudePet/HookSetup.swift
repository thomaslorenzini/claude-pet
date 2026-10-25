import Foundation

/// Hooks and status line of Claude Pet in Claude Code's settings.json: a native port of
/// scripts/install-hooks.py (macOS no longer ships Python). Same rules, same output byte for byte:
/// our entries carry `marker`, are removed first then re-added (idempotent), other hooks are left
/// untouched, the file is backed up before any write, and the original status line keeps running
/// behind the bridge.
struct HookSetup {
    struct Status: Equatable {
        /// Our hook entries found in settings.json.
        var installedHooks: Int
        /// What install writes.
        var expectedHooks: Int
        /// The status line points at our bridge.
        var statusLineBridged: Bool
        var bridgeScriptPresent: Bool
        /// Install would change nothing.
        var upToDate: Bool
        var isComplete: Bool { installedHooks == expectedHooks && statusLineBridged && bridgeScriptPresent }
    }

    struct Report {
        var changed: Bool
        var backupURL: URL?
    }

    /// A copy of settings.json the user can put back from the settings window.
    struct Backup: Equatable {
        let url: URL
        /// When the copy was made.
        let date: Date
        /// The copy made once, at the first install, before Claude Pet's changes. Never overwritten.
        let isOriginal: Bool
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let standard: HookSetup = {
        // Tests: CLAUDE_PET_HOOKS_HOME=<dir> points the installer at a fake home, never at the real settings.
        let home = AppDelegate.devSetting("CLAUDE_PET_HOOKS_HOME").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return HookSetup(
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            supportDir: home.appendingPathComponent("Library/Application Support/claude-pet")
        )
    }()

    let settingsURL: URL
    let supportDir: URL

    static let marker = "# claude-pet-hook"
    static let statusMarker = "# claude-pet-statusline"
    /// Expanded by the hook's shell, not here: the file the app writes once its server listens.
    private static let endpoint = "$HOME/Library/Application Support/claude-pet/endpoint"
    /// Events whose matcher filters on tool name; the others take no matcher.
    private static let toolEvents = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]
    private static let otherEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "Notification", "Stop", "StopFailure",
        "SubagentStart", "SubagentStop", "PreCompact",
    ]
    /// Blocking hooks answered from the pet. Claude Code keeps the first decision and kills the
    /// other hooks, so the limit only matters if nobody answers anywhere.
    private static let askHooks = [(event: "PermissionRequest", matcher: "*")]
    private static let askTimeout = 86400
    static var expectedHooks: Int { toolEvents.count + otherEvents.count + askHooks.count }

    private var bridgeURL: URL { supportDir.appendingPathComponent("statusline.sh") }
    private var originalURL: URL { supportDir.appendingPathComponent("statusline-original") }

    // MARK: Commands (identical to install-hooks.py: existing installs stay "up to date")

    /// Finds the pet with shell builtins only (read, kill -0): pet closed, no process is started.
    /// Synchronous on purpose: in the background, a large PostToolUse would overtake the next
    /// PreToolUse. "Expect:" stops curl waiting for a 100-continue on bodies over 1 MB.
    static var hookCommand: String {
        "/bin/sh -c 'f=\"\(endpoint)\"; read -r port pid < \"$f\" 2>/dev/null && kill -0 \"$pid\" 2>/dev/null && "
            + "curl -s -m 1 --connect-timeout 0.2 -H \"Expect:\" -H \"Content-Type: application/json\" "
            + "--data-binary @- \"http://127.0.0.1:$port/event\" >/dev/null 2>&1; exit 0' \(marker)"
    }

    /// Blocks until the user answers in the pet and prints the decision. No output (pet closed, no
    /// answer, any error) lets Claude Code go on with its own dialog; -f keeps error pages out.
    static var askCommand: String {
        "/bin/sh -c 'f=\"\(endpoint)\"; read -r port pid < \"$f\" 2>/dev/null && kill -0 \"$pid\" 2>/dev/null && "
            + "curl -sf -m \(askTimeout) --connect-timeout 0.2 -H \"Expect:\" -H \"Content-Type: application/json\" "
            + "--data-binary @- \"http://127.0.0.1:$port/ask\" 2>/dev/null; exit 0' \(marker)"
    }

    private var statusLineCommand: String { "/bin/sh \"\(bridgeURL.path)\" \(Self.statusMarker)" }

    /// Copy of scripts/statusline-bridge.sh: forwards the status line JSON to the pet, then runs the
    /// original command with the same input, so what the terminal shows is unchanged.
    static let bridgeScript = """
        #!/bin/sh
        # Claude Pet status line bridge, installed by install-hooks.py in place of the status line command.
        # Forwards the status line JSON (quotas, context window) to the pet, then runs the original status
        # line command, saved next to this script, with the same input: what the terminal shows is unchanged.
        d="$HOME/Library/Application Support/claude-pet"
        p=$(cat)
        if read -r port pid < "$d/endpoint" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
          printf '%s' "$p" | curl -s -m 0.5 --connect-timeout 0.2 -H "Expect:" -H "Content-Type: application/json" \\
            --data-binary @- "http://127.0.0.1:$port/status" >/dev/null 2>&1
        fi
        [ -s "$d/statusline-original" ] && printf '%s' "$p" | /bin/sh -c "$(cat "$d/statusline-original")"
        exit 0

        """

    // MARK: Public

    func status() -> Status {
        let settings = (try? load().settings) ?? .object([])
        var count = 0
        if case let .object(hooks)? = settings["hooks"] {
            for (_, groups) in hooks {
                guard case let .array(groups) = groups else { continue }
                for case let .object(group) in groups {
                    if case let .array(entries)? = JSON.object(group)["hooks"] {
                        count += entries.filter(Self.isOurs).count
                    }
                }
            }
        }
        let bridgeOK = (try? String(contentsOf: bridgeURL, encoding: .utf8)) == Self.bridgeScript
        var installed = settings
        Self.stripOurs(&installed)
        Self.addOurs(&installed)
        _ = wrapStatusLine(&installed)
        return Status(
            installedHooks: count, expectedHooks: Self.expectedHooks,
            statusLineBridged: Self.isWrapped(settings),
            bridgeScriptPresent: FileManager.default.fileExists(atPath: bridgeURL.path),
            upToDate: installed == settings && bridgeOK
        )
    }

    /// One difference between our entries in settings.json and what this version's install writes.
    struct Change: Equatable {
        enum Kind: String { case added, removed, modified }
        let kind: Kind
        /// The hook's event, or `statusLine` / `bridge` for the status line command and its script.
        let target: String
        /// As in the file today / as an install would write it: one line per field, then the command.
        let old: String?
        let new: String?
        /// For a modified hook: which of "command", "timeout", "matcher", "count", "other" differ.
        let fields: [String]

        static let statusLine = "statusLine", bridge = "bridge"
    }

    /// What an install would change in our own entries: nil when they were never installed (or were
    /// uninstalled), empty when an install would change none of them. Other apps' hooks and a mere
    /// reordering don't count: the point is to tell an app update that brings different hooks.
    func pendingChanges() -> [Change]? {
        guard let settings = try? load().settings else { return nil }
        let installed = Self.ourEntries(settings)
        let wrapped = Self.isWrapped(settings)
        guard !installed.isEmpty || wrapped else { return nil }
        var fresh = JSON.object([])
        Self.addOurs(&fresh)
        let wanted = Self.ourEntries(fresh)
        let current = Dictionary(installed.map { ($0.event, $0.entries) }, uniquingKeysWith: +)
        var changes: [Change] = []
        for (event, entries) in wanted {
            guard let now = current[event] else {
                changes.append(Change(kind: .added, target: event, old: nil, new: Self.describe(entries), fields: []))
                continue
            }
            if now != entries {
                changes.append(Change(kind: .modified, target: event, old: Self.describe(now), new: Self.describe(entries),
                                      fields: Self.differingFields(now, entries)))
            }
        }
        for (event, entries) in installed where !wanted.contains(where: { $0.event == event }) {
            changes.append(Change(kind: .removed, target: event, old: Self.describe(entries), new: nil, fields: []))
        }
        // The status line: install wraps it again when it no longer goes through the bridge. Once wrapped
        // (marker found), install leaves its text alone, so a different text is not a change to offer.
        if !wrapped {
            var line: String?
            if case let .object(fields)? = settings["statusLine"], case let .string(command)? = JSON.object(fields)["command"] { line = command }
            changes.append(Change(kind: .added, target: Change.statusLine, old: line, new: statusLineCommand, fields: []))
        }
        // The bridge script is rewritten by every install.
        let script = try? String(contentsOf: bridgeURL, encoding: .utf8)
        if script != Self.bridgeScript {
            changes.append(Change(kind: script == nil ? .added : .modified, target: Change.bridge,
                                  old: script, new: Self.bridgeScript, fields: script == nil ? [] : ["command"]))
        }
        return changes
    }

    private struct Entry: Equatable {
        let matcher: JSON?
        let hook: JSON
    }

    /// Our entries by event, in file order, with their group's matcher.
    private static func ourEntries(_ settings: JSON) -> [(event: String, entries: [Entry])] {
        guard case let .object(hooks)? = settings["hooks"] else { return [] }
        var out: [(event: String, entries: [Entry])] = []
        for (event, groups) in hooks {
            guard case let .array(list) = groups else { continue }
            for group in list {
                guard case let .array(entries)? = group["hooks"] else { continue }
                let ours = entries.filter(isOurs).map { Entry(matcher: group["matcher"], hook: $0) }
                guard !ours.isEmpty else { continue }
                if let i = out.firstIndex(where: { $0.event == event }) { out[i].entries += ours } else { out.append((event, ours)) }
            }
        }
        return out
    }

    private static func describe(_ entries: [Entry]) -> String {
        entries.map { entry in
            var head: [String] = []
            if let matcher = entry.matcher { head.append("matcher " + (matcher.stringValue ?? matcher.serialized())) }
            if let timeout = entry.hook["timeout"] { head.append("timeout " + (timeout.stringValue ?? timeout.serialized())) }
            let command = entry.hook["command"]?.stringValue ?? entry.hook.serialized()
            return (head.isEmpty ? "" : head.joined(separator: " · ") + "\n") + command
        }.joined(separator: "\n")
    }

    private static func differingFields(_ old: [Entry], _ new: [Entry]) -> [String] {
        guard old.count == new.count else { return ["count"] }
        var fields: [String] = []
        func add(_ field: String) { if !fields.contains(field) { fields.append(field) } }
        for (a, b) in zip(old, new) where a != b {
            if a.matcher != b.matcher { add("matcher") }
            if a.hook["command"] != b.hook["command"] { add("command") }
            if a.hook["timeout"] != b.hook["timeout"] { add("timeout") }
            var restA = a.hook, restB = b.hook
            for key in ["command", "timeout"] { restA[key] = nil; restB[key] = nil }
            if restA != restB { add("other") }
        }
        return fields
    }

    /// The user's own status line command (the saved original once bridged), nil when there is none.
    func existingStatusLine() -> String? {
        guard let settings = try? load().settings else { return nil }
        if Self.isWrapped(settings) {
            let saved = (try? String(contentsOf: originalURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return saved?.isEmpty == false ? saved : nil
        }
        guard case let .object(line)? = settings["statusLine"], JSON.object(line)["type"] == .string("command"),
              case let .string(command)? = JSON.object(line)["command"], !command.isEmpty else { return nil }
        return command
    }

    @discardableResult
    func install() throws -> Report {
        let (url, text, settings) = try load()
        if let hooks = settings["hooks"], case .object = hooks {} else if settings["hooks"] != nil {
            throw Failure(message: tr("« hooks » n'est pas un objet dans \(url.path) : rien n'a été modifié.",
                                      "\"hooks\" is not an object in \(url.path): nothing was changed."))
        }
        if let text { try keepOriginal(text, of: url) }
        var updated = settings
        Self.stripOurs(&updated)
        Self.addOurs(&updated)
        let original = wrapStatusLine(&updated)
        guard updated != settings else {
            try installBridge()
            return Report(changed: false, backupURL: nil)
        }
        let backup = try self.backup(url, exists: text != nil)
        try installBridge()
        if let original { try write(original + "\n", to: originalURL) }
        try save(updated, to: url, replacing: text != nil)
        return Report(changed: true, backupURL: backup)
    }

    @discardableResult
    func uninstall() throws -> Report {
        let (url, text, settings) = try load()
        var updated = settings
        Self.stripOurs(&updated)
        unwrapStatusLine(&updated)
        // The bridge files go in any case: an uninstall is also how one cleans up after a bug.
        defer { for file in [bridgeURL, originalURL] { try? FileManager.default.removeItem(at: file) } }
        guard updated != settings else { return Report(changed: false, backupURL: nil) }
        let backup = try self.backup(url, exists: text != nil)
        try save(updated, to: url, replacing: text != nil)
        return Report(changed: true, backupURL: backup)
    }

    /// settings.json as it was at the first install; nil when there was no file then.
    func originalBackup() -> Backup? {
        let url = originalCopyURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let date = attributes[.creationDate] as? Date ?? attributes[.modificationDate] as? Date ?? Date()
        return Backup(url: url, date: date, isOriginal: true)
    }

    /// The newest timestamped copy, made before Claude Pet's last write.
    func latestBackup() -> Backup? {
        let real = settingsURL.resolvingSymlinksInPath()
        let dir = real.deletingLastPathComponent()
        let prefix = real.lastPathComponent + Self.backupInfix
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let copies: [(Backup, Int)] = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
            guard name.hasPrefix(prefix), !name.hasSuffix(Self.statusLineSuffix) else { return nil }
            let stamp = name.dropFirst(prefix.count)
            let parts = stamp.split(separator: "-")
            guard parts.count >= 2, let date = formatter.date(from: "\(parts[0])-\(parts[1])") else { return nil }
            let order = parts.count > 2 ? Int(parts[2]) ?? 1 : 1
            return (Backup(url: dir.appendingPathComponent(name), date: date, isOriginal: false), order)
        }
        return copies.max { ($0.0.date, $0.1) < ($1.0.date, $1.1) }?.0
    }

    /// Puts a copy back, byte for byte. The current file is copied aside first, so a restore can be
    /// undone too; the status line command saved with the copy comes back with it.
    @discardableResult
    func restore(_ backup: Backup) throws -> Report {
        guard let text = try? String(contentsOf: backup.url, encoding: .utf8) else {
            throw Failure(message: tr("Copie illisible : \(backup.url.path).", "Unreadable copy: \(backup.url.path)."))
        }
        let restored: JSON
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restored = .object([])
        } else if let json = try? JSON.parse(text), case .object = json {
            restored = json
        } else {
            throw Failure(message: tr("La copie n'est pas un JSON valide : rien n'a été modifié.",
                                      "The copy is not valid JSON: nothing was changed."))
        }
        let (url, current, _) = try load()
        let aside = try self.backup(url, exists: current != nil)
        let sidecar = URL(fileURLWithPath: backup.url.path + Self.statusLineSuffix)
        if Self.isWrapped(restored) {
            try installBridge()
            if let saved = try? Data(contentsOf: sidecar) { try? saved.write(to: originalURL, options: .atomic) }
        } else if !hasOurHooks(restored) {
            for file in [bridgeURL, originalURL] { try? FileManager.default.removeItem(at: file) }
        }
        try save(text: text, to: url, replacing: current != nil)
        return Report(changed: true, backupURL: aside)
    }

    private static let backupInfix = ".claude-pet-backup-"
    private static let statusLineSuffix = ".statusline-original"
    private var originalCopyURL: URL { URL(fileURLWithPath: settingsURL.resolvingSymlinksInPath().path + ".claude-pet-original") }

    private func hasOurHooks(_ settings: JSON) -> Bool {
        guard case let .object(hooks)? = settings["hooks"] else { return false }
        return hooks.contains { _, groups in
            guard case let .array(list) = groups else { return false }
            return list.contains { group in
                guard case let .array(entries)? = group["hooks"] else { return false }
                return entries.contains(where: Self.isOurs)
            }
        }
    }

    /// The one-time copy made before the first install changes anything. Same permissions as the
    /// original: settings.json can hold secrets (env).
    private func keepOriginal(_ text: String, of url: URL) throws {
        let copy = originalCopyURL
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        do {
            try Data(text.utf8).write(to: copy, options: .withoutOverwriting)
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: copy.path)
            keepStatusLine(beside: copy)
        } catch {
            throw Failure(message: tr("Copie d'origine impossible, rien n'a été modifié : \(error.localizedDescription)",
                                      "Could not make the original copy, nothing was changed: \(error.localizedDescription)"))
        }
    }

    /// A copy taken while the status line was bridged needs the saved original command to work again.
    private func keepStatusLine(beside copy: URL) {
        guard let saved = try? Data(contentsOf: originalURL) else { return }
        try? saved.write(to: URL(fileURLWithPath: copy.path + Self.statusLineSuffix), options: .atomic)
    }

    // MARK: Editing

    private static func isOurs(_ hook: JSON) -> Bool {
        guard case let .object(fields) = hook, case let .string(command)? = JSON.object(fields)["command"] else { return false }
        return command.contains(marker)
    }

    private static func stripOurs(_ settings: inout JSON) {
        guard case var .object(hooks)? = settings["hooks"] else { return }
        hooks = hooks.compactMap { event, groups in
            guard case let .array(list) = groups else { return (event, groups) }
            let kept: [JSON] = list.compactMap { group in
                guard case var .object(fields) = group, case let .array(entries)? = JSON.object(fields)["hooks"] else { return group }
                let remaining = entries.filter { !isOurs($0) }
                if remaining.isEmpty { return nil }
                fields.set("hooks", .array(remaining))
                return .object(fields)
            }
            return kept.isEmpty ? nil : (event, .array(kept))
        }
        settings["hooks"] = hooks.isEmpty ? nil : .object(hooks)
    }

    private static func addOurs(_ settings: inout JSON) {
        var hooks: [(String, JSON)]
        if case let .object(existing)? = settings["hooks"] { hooks = existing } else { hooks = [] }
        func append(_ event: String, _ group: JSON) {
            if let i = hooks.firstIndex(where: { $0.0 == event }), case let .array(list) = hooks[i].1 {
                hooks[i].1 = .array(list + [group])
            } else if let i = hooks.firstIndex(where: { $0.0 == event }) {
                // Python's setdefault().append() would fail on a non-list too: replace it like an empty one.
                hooks[i].1 = .array([group])
            } else {
                hooks.append((event, .array([group])))
            }
        }
        let entry = JSON.object([("type", .string("command")), ("command", .string(hookCommand)), ("timeout", .number("5"))])
        for event in toolEvents + otherEvents {
            var group: [(String, JSON)] = [("hooks", .array([entry]))]
            if toolEvents.contains(event) { group.insert(("matcher", .string("*")), at: 0) }
            append(event, .object(group))
        }
        for (event, matcher) in askHooks {
            let ask = JSON.object([("type", .string("command")), ("command", .string(askCommand)), ("timeout", .number("\(askTimeout)"))])
            append(event, .object([("matcher", .string(matcher)), ("hooks", .array([ask]))]))
        }
        settings["hooks"] = .object(hooks)
    }

    private static func isWrapped(_ settings: JSON) -> Bool {
        guard case let .object(line)? = settings["statusLine"], case let .string(command)? = JSON.object(line)["command"] else { return false }
        return command.contains(statusMarker)
    }

    /// Points the status line at the bridge. Returns the original command to save, or nil when it was
    /// already wrapped (the saved original is then kept).
    private func wrapStatusLine(_ settings: inout JSON) -> String? {
        if Self.isWrapped(settings) { return nil }
        var fields: [(String, JSON)] = []
        var original = ""
        if case let .object(line)? = settings["statusLine"] {
            fields = line
            if JSON.object(line)["type"] == .string("command"), case let .string(command)? = JSON.object(line)["command"] {
                original = command
            }
        }
        fields.set("type", .string("command"))
        fields.set("command", .string(statusLineCommand))
        settings["statusLine"] = .object(fields)
        return original
    }

    private func unwrapStatusLine(_ settings: inout JSON) {
        guard Self.isWrapped(settings), case var .object(line)? = settings["statusLine"] else { return }
        let original = ((try? String(contentsOf: originalURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if original.isEmpty {
            settings["statusLine"] = nil
        } else {
            line.set("command", .string(original))
            settings["statusLine"] = .object(line)
        }
    }

    // MARK: Files

    /// The real file (symlinks resolved, as Python's realpath), its text (nil when missing) and content.
    private func load() throws -> (url: URL, text: String?, settings: JSON) {
        let url = settingsURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return (url, nil, .object([])) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(message: tr("Impossible de lire \(url.path).", "Cannot read \(url.path)."))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (url, text, .object([])) }
        guard let json = try? JSON.parse(text), case .object = json else {
            throw Failure(message: tr("\(url.path) n'est pas un objet JSON valide : rien n'a été modifié.",
                                      "\(url.path) is not a valid JSON object: nothing was changed."))
        }
        return (url, text, json)
    }

    private func backup(_ url: URL, exists: Bool) throws -> URL? {
        guard exists else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // Two copies in the same second get a suffix: the second must never replace the first.
        let base = url.path + Self.backupInfix + formatter.string(from: Date())
        var backup = URL(fileURLWithPath: base)
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = URL(fileURLWithPath: "\(base)-\(n)")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            keepStatusLine(beside: backup)
        } catch {
            throw Failure(message: tr("Sauvegarde impossible, rien n'a été modifié : \(error.localizedDescription)",
                                      "Backup failed, nothing was changed: \(error.localizedDescription)"))
        }
        return backup
    }

    /// Atomic: a temporary file next to the target, given the target's permissions, then renamed.
    private func save(_ settings: JSON, to url: URL, replacing: Bool) throws {
        try save(text: settings.serialized() + "\n", to: url, replacing: replacing)
    }

    private func save(text: String, to url: URL, replacing: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".settings.\(UUID().uuidString).json")
        do {
            try Data(text.utf8).write(to: tmp)
            let mode = replacing ? (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600 : 0o600
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
            guard rename(tmp.path, url.path) == 0 else { throw Failure(message: String(cString: strerror(errno))) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw Failure(message: tr("Écriture de \(url.path) impossible : \(error.localizedDescription)",
                                      "Cannot write \(url.path): \(error.localizedDescription)"))
        }
    }

    private func installBridge() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(Self.bridgeScript, to: bridgeURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeURL.path)
    }

    private func write(_ text: String, to url: URL) throws {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Failure(message: tr("Écriture de \(url.path) impossible : \(error.localizedDescription)",
                                      "Cannot write \(url.path): \(error.localizedDescription)"))
        }
    }
}

// MARK: - Order-preserving JSON

/// JSON that keeps object keys in file order (JSONSerialization does not, and would reshuffle the
/// user's settings on every write). Serialized like Python's `json.dumps(indent=2, ensure_ascii=False)`;
/// numbers keep their source text.
indirect enum JSON: Equatable {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    /// Objects compare as dictionaries (key order ignored), like Python's `==`.
    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            let lookup = Dictionary(y, uniquingKeysWith: { _, last in last })
            return x.allSatisfy { key, value in lookup[key].map { $0 == value } ?? false }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return Double(x) == Double(y) || x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    /// Field of an object (the last one, if a key repeats, as Python keeps); setting nil removes it.
    subscript(key: String) -> JSON? {
        get {
            guard case let .object(fields) = self else { return nil }
            return fields.last { $0.0 == key }?.1
        }
        set {
            guard case var .object(fields) = self else { return }
            if let newValue { fields.set(key, newValue) } else { fields.removeAll { $0.0 == key } }
            self = .object(fields)
        }
    }

    var stringValue: String? {
        switch self {
        case let .string(s), let .number(s): return s
        default: return nil
        }
    }

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1), end = String(repeating: "  ", count: indent)
        switch self {
        case let .object(fields):
            if fields.isEmpty { return "{}" }
            let items = fields.map { pad + Self.quote($0.0) + ": " + $0.1.serialized(indent: indent + 1) }
            return "{\n" + items.joined(separator: ",\n") + "\n" + end + "}"
        case let .array(items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { pad + $0.serialized(indent: indent + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case let .string(s): return Self.quote(s)
        case let .number(n): return n
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    struct ParseError: Error {}

    static func parse(_ text: String) throws -> JSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.scalars.count else { throw ParseError() }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func skipSpace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func value() throws -> JSON {
            skipSpace()
            guard index < scalars.count else { throw ParseError() }
            switch scalars[index] {
            case "{":
                index += 1
                var fields: [(String, JSON)] = []
                skipSpace()
                if peek("}") { index += 1; return .object(fields) }
                while true {
                    skipSpace()
                    guard peek("\"") else { throw ParseError() }
                    let key = try string()
                    skipSpace()
                    guard peek(":") else { throw ParseError() }
                    index += 1
                    fields.append((key, try value()))
                    skipSpace()
                    if peek(",") { index += 1; continue }
                    if peek("}") { index += 1; return .object(fields) }
                    throw ParseError()
                }
            case "[":
                index += 1
                var items: [JSON] = []
                skipSpace()
                if peek("]") { index += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipSpace()
                    if peek(",") { index += 1; continue }
                    if peek("]") { index += 1; return .array(items) }
                    throw ParseError()
                }
            case "\"": return .string(try string())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default: return try number()
            }
        }

        private func peek(_ c: Unicode.Scalar) -> Bool { index < scalars.count && scalars[index] == c }

        private mutating func literal(_ word: String) throws {
            for c in word.unicodeScalars {
                guard peek(c) else { throw ParseError() }
                index += 1
            }
        }

        private mutating func number() throws -> JSON {
            let start = index
            while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[start..<index])
            guard !text.isEmpty, Double(text) != nil else { throw ParseError() }
            return .number(text)
        }

        private mutating func string() throws -> String {
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                switch c {
                case "\"": return String(out)
                case "\\":
                    guard index < scalars.count else { throw ParseError() }
                    let e = scalars[index]
                    index += 1
                    switch e {
                    case "\"", "\\", "/": out.append(e)
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        var code = try hex4()
                        // Surrogate pair: a character outside the BMP.
                        if (0xD800..<0xDC00).contains(code), peek("\\"), index + 1 < scalars.count, scalars[index + 1] == "u" {
                            index += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: throw ParseError()
                    }
                default: out.append(c)
                }
            }
            throw ParseError()
        }

        private mutating func hex4() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw ParseError() }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[index..<index + 4])
            guard let code = UInt32(text, radix: 16) else { throw ParseError() }
            index += 4
            return code
        }
    }
}

private extension Array where Element == (String, JSON) {
    /// Replaces the value in place (keeps the key's position, as a Python dict does), or appends it.
    mutating func set(_ key: String, _ value: JSON) {
        if let i = lastIndex(where: { $0.0 == key }) { self[i].1 = value } else { append((key, value)) }
    }
}

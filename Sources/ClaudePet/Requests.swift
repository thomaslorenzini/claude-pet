import Foundation

/// A Claude Code `PermissionRequest` hook waiting for the user: a permission to grant, or the
/// questions of `AskUserQuestion`, which goes through the same permission flow. The hook's HTTP
/// request stays open until it is answered here (see `EventServer`), and whatever we send back is the
/// hook's output.
///
/// Claude Code shows its own dialog at the same time and keeps the first decision: answering in the
/// terminal, in Claude Desktop or in another app kills our hook, which closes the connection and
/// drops the request (`cancel`). Measured with `claude -p` on 2026-10-23.
struct PendingRequest {
    struct Question {
        let text: String
        let header: String
        let options: [(label: String, detail: String)]
        let multiSelect: Bool
    }

    enum Kind {
        /// `title` says what Claude wants to do, `body` is the command, file or URL, `note` its description.
        case permission(tool: String, title: String, body: String, note: String?)
        case questions([Question])
        /// The first-run tutorial, shown by the pet like a request; nothing goes to Claude. `detail` replaces
        /// `body` after "Je n'ai pas compris".
        case explanation(title: String, body: String, detail: String)
    }

    let id: Int
    let session: String
    let tool: String
    /// Last component of the session's working directory.
    let project: String
    let kind: Kind
    /// The tool input, sent back with the answers.
    let toolInput: [String: Any]
}

final class RequestCenter {
    /// Oldest first; the UI shows the first one.
    private(set) var queue: [PendingRequest] = []
    private var responders: [Int: (Data?) -> Void] = [:]
    private var nextID = 1
    var onChange: (() -> Void)?

    var current: PendingRequest? { queue.first }

    /// Queues a hook payload. `respond` sends the hook's output (nil: no decision, Claude Code carries
    /// on with its own dialog). Returns nil and answers at once for payloads we do not handle.
    @discardableResult
    func add(_ payload: [String: Any], respond: @escaping (Data?) -> Void) -> Int? {
        guard let kind = Self.kind(of: payload) else {
            respond(nil)
            return nil
        }
        let id = nextID
        nextID += 1
        let cwd = payload["cwd"] as? String ?? ""
        queue.append(PendingRequest(
            id: id, session: payload["session_id"] as? String ?? "", tool: payload["tool_name"] as? String ?? "",
            project: (cwd as NSString).lastPathComponent, kind: kind,
            toolInput: payload["tool_input"] as? [String: Any] ?? [:]
        ))
        responders[id] = respond
        onChange?()
        return id
    }

    func allow(_ id: Int) {
        finish(id, output: ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest", "decision": ["behavior": "allow"],
        ]])
    }

    func deny(_ id: Int) {
        finish(id, output: ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "deny", "message": tr("Refusé par l'utilisateur depuis Claude Pet.", "Denied by the user from Claude Pet.")],
        ]])
    }

    /// `answers` maps each question's text to the chosen label(s), comma-separated when several.
    func answer(_ id: Int, _ answers: [String: String]) {
        guard let request = queue.first(where: { $0.id == id }) else { return }
        var input = request.toolInput
        input["answers"] = answers
        // Answering AskUserQuestion takes "allow" plus the questions echoed back with the answers.
        // Through PermissionRequest, Claude's own dialog shows at the same time (verified 2026-10-23).
        finish(id, output: ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest", "decision": ["behavior": "allow", "updatedInput": input],
        ]])
    }

    /// Leaves the decision to Claude Code's own dialog.
    func dismiss(_ id: Int) { finish(id, output: nil) }

    /// The hook went away (answered elsewhere, Claude Code quit): nothing to send.
    func cancel(_ id: Int) {
        guard responders.removeValue(forKey: id) != nil else { return }
        queue.removeAll { $0.id == id }
        onChange?()
    }

    /// A later hook of the same session shows its request was answered elsewhere: the tool ran or
    /// failed, or the turn ended. A safety net in case a killed hook leaves its connection open.
    func sessionMoved(_ session: String, event: [String: Any]) {
        let tool = event["tool_name"] as? String
        let input = event["tool_input"] as? [String: Any] ?? [:]
        for request in queue where request.session == session {
            switch event["hook_event_name"] as? String {
            case "PostToolUse", "PostToolUseFailure":
                // Only the tool call that was asked about: others may run in parallel.
                if tool == request.tool, NSDictionary(dictionary: input).isEqual(to: request.toolInput) { dismiss(request.id) }
            case "UserPromptSubmit", "Stop", "StopFailure", "SessionEnd":
                dismiss(request.id)
            default:
                break
            }
        }
    }

    private func finish(_ id: Int, output: [String: Any]?) {
        guard let respond = responders.removeValue(forKey: id) else { return }
        queue.removeAll { $0.id == id }
        respond(output.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
        onChange?()
    }

    // MARK: Payloads

    private static func kind(of payload: [String: Any]) -> PendingRequest.Kind? {
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        // Anything else gets no decision at once: an older install also asked from PreToolUse, which
        // held Claude's question dialog back until the pet answered.
        guard payload["hook_event_name"] as? String == "PermissionRequest" else { return nil }
        if tool == "AskUserQuestion" {
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap(question)
            return questions.isEmpty ? nil : .questions(questions)
        }
        return permission(tool: tool, input: input)
    }

    private static func question(_ q: [String: Any]) -> PendingRequest.Question? {
        guard let text = q["question"] as? String else { return nil }
        let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> (String, String)? in
            guard let label = o["label"] as? String else { return nil }
            return (label, o["description"] as? String ?? "")
        }
        guard !options.isEmpty else { return nil }
        return PendingRequest.Question(
            text: text, header: q["header"] as? String ?? "", options: options,
            multiSelect: q["multiSelect"] as? Bool ?? false
        )
    }

    private static func permission(tool: String, input: [String: Any]) -> PendingRequest.Kind {
        func string(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func path(_ key: String) -> String {
            let p = string(key) ?? "?"
            return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        }
        switch tool {
        case "Bash":
            return .permission(tool: tool, title: tr("Exécuter une commande", "Run a command"), body: string("command") ?? "?", note: string("description"))
        case "Edit", "MultiEdit":
            return .permission(tool: tool, title: tr("Modifier un fichier", "Edit a file"), body: path("file_path"), note: nil)
        case "Write":
            return .permission(tool: tool, title: tr("Écrire un fichier", "Write a file"), body: path("file_path"), note: nil)
        case "NotebookEdit":
            return .permission(tool: tool, title: tr("Modifier un notebook", "Edit a notebook"), body: path("notebook_path"), note: nil)
        case "WebFetch":
            return .permission(tool: tool, title: tr("Ouvrir une page web", "Open a web page"), body: string("url") ?? "?", note: string("prompt"))
        case "WebSearch":
            return .permission(tool: tool, title: tr("Chercher sur le web", "Search the web"), body: string("query") ?? "?", note: nil)
        case "ExitPlanMode":
            return .permission(tool: tool, title: tr("Passer à l'action avec ce plan", "Go ahead with this plan"), body: string("plan") ?? "", note: nil)
        default:
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return .permission(tool: tool, title: tr("Utiliser \(tool)", "Use \(tool)"), body: json, note: nil)
        }
    }
}

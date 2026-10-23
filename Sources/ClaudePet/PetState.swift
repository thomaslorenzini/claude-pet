import Foundation

/// What the pet is currently showing.
enum PetState: String, CaseIterable {
    case idle, thinking, working, error, waiting, happy, sleeping

    /// Used to pick which session wins when several run in parallel.
    var priority: Int {
        switch self {
        case .waiting: return 6
        case .error: return 5
        case .working: return 4
        case .thinking: return 3
        case .happy: return 2
        case .idle: return 1
        case .sleeping: return 0
        }
    }

    var label: String {
        switch self {
        case .idle: return "au repos"
        case .thinking: return "réfléchit"
        case .working: return "travaille"
        case .error: return "erreur"
        case .waiting: return "t'attend"
        case .happy: return "content"
        case .sleeping: return "dort"
        }
    }
}

/// Variant of the `working` state, derived from the tool name.
enum ToolKind: String, CaseIterable {
    case bash, edit, read, web, agent, other

    init(toolName: String) {
        let name = toolName.lowercased()
        switch name {
        case "bash", "bashoutput", "killshell", "killbash": self = .bash
        case "edit", "write", "multiedit", "notebookedit": self = .edit
        case "read", "grep", "glob", "ls", "lsp": self = .read
        case "webfetch", "websearch": self = .web
        case "task", "agent": self = .agent
        default:
            if name.contains("browser") || name.contains("chrome") || name.contains("fetch") {
                self = .web
            } else {
                self = .other
            }
        }
    }
}

struct SessionInfo {
    let id: String
    var state: PetState
    var tool: ToolKind?
    var toolName: String?
    var cwd: String?
    var lastEvent: Date
    /// Transient states (happy, error) revert to `stateAfter` at this date.
    var transientUntil: Date?
    var stateAfter: PetState = .idle
}

/// Turns hook events into per-session states, then aggregates them into one display state.
///
/// Aggregation rule: the session with the highest-priority state wins
/// (waiting > error > working > thinking > happy > idle), ties go to the most recently active one.
/// A session asking for the user is never hidden behind one that is just working.
final class SessionTracker {
    static let happyDuration: TimeInterval = 5
    static let errorDuration: TimeInterval = 3
    /// Busy states with no event for this long fall back to idle (an interrupt with Esc fires no Stop hook).
    static let busyTimeout: TimeInterval = 10 * 60
    /// Sessions with no event for this long are forgotten (SessionEnd does not always fire).
    static let forgetAfter: TimeInterval = 3 * 60 * 60
    static let sleepAfter: TimeInterval = 5 * 60

    private(set) var sessions: [String: SessionInfo] = [:]
    private(set) var lastActivity = Date()

    func handle(_ event: [String: Any], now: Date = Date()) {
        let name = event["hook_event_name"] as? String ?? ""
        let id = event["session_id"] as? String ?? "default"
        lastActivity = now

        if name == "SessionEnd" {
            sessions[id] = nil
            return
        }

        var s = sessions[id] ?? SessionInfo(id: id, state: .idle, lastEvent: now)
        s.lastEvent = now
        if let cwd = event["cwd"] as? String { s.cwd = cwd }
        let toolName = event["tool_name"] as? String

        func set(_ state: PetState, tool: ToolKind? = nil) {
            s.state = state
            s.tool = tool
            s.toolName = tool == nil ? nil : toolName
            s.transientUntil = nil
        }
        func flash(_ state: PetState, for duration: TimeInterval, then after: PetState) {
            set(state)
            s.transientUntil = now.addingTimeInterval(duration)
            s.stateAfter = after
        }

        // Generic override, so a future mod (or anything else) can drive the pet directly.
        if let forced = (event["pet_state"] as? String).flatMap(PetState.init(rawValue:)) {
            set(forced, tool: (event["pet_tool"] as? String).flatMap(ToolKind.init(rawValue:)))
            if let duration = event["pet_duration"] as? Double {
                s.transientUntil = now.addingTimeInterval(duration)
                s.stateAfter = .idle
            }
            sessions[id] = s
            return
        }

        switch name {
        case "SessionStart":
            set(.idle)
        case "UserPromptSubmit", "PreCompact":
            set(.thinking)
        case "PreToolUse":
            set(.working, tool: ToolKind(toolName: toolName ?? ""))
        case "SubagentStart":
            set(.working, tool: .agent)
        case "PostToolUse", "SubagentStop":
            set(.thinking)
        case "PostToolUseFailure":
            flash(.error, for: Self.errorDuration, then: .thinking)
        case "StopFailure":
            flash(.error, for: Self.errorDuration, then: .idle)
        case "PermissionRequest":
            set(.waiting)
        case "Notification":
            // idle_prompt fires ~60 s after a finished turn: Stop already celebrated it, stay idle.
            // Other types (permission_prompt, elicitation_dialog…) mean Claude is blocked on the user.
            let type = event["notification_type"] as? String
            if type == "idle_prompt" || type == "auth_success" {
                if s.state != .waiting { set(.idle) }
            } else {
                set(.waiting)
            }
        case "Stop":
            flash(.happy, for: Self.happyDuration, then: .idle)
        default:
            break
        }
        sessions[id] = s
    }

    /// Resolves expired transient states and stale sessions. Returns true if anything changed.
    @discardableResult
    func tick(now: Date = Date()) -> Bool {
        var changed = false
        for (id, var s) in sessions {
            let idleFor = now.timeIntervalSince(s.lastEvent)
            if idleFor > Self.forgetAfter {
                sessions[id] = nil
                changed = true
                continue
            }
            if let until = s.transientUntil, now >= until {
                s.state = s.stateAfter
                s.transientUntil = nil
                s.tool = nil
                changed = true
            } else if (s.state == .working || s.state == .thinking) && idleFor > Self.busyTimeout {
                s.state = .idle
                s.tool = nil
                changed = true
            }
            sessions[id] = s
        }
        return changed
    }

    /// The session currently driving the display, if any.
    var leader: SessionInfo? {
        sessions.values.max { a, b in
            if a.state.priority != b.state.priority { return a.state.priority < b.state.priority }
            return a.lastEvent < b.lastEvent
        }
    }

    func display(now: Date = Date()) -> (state: PetState, tool: ToolKind?) {
        let lead = leader
        let state = lead?.state ?? .idle
        if state == .idle && now.timeIntervalSince(lastActivity) > Self.sleepAfter {
            return (.sleeping, nil)
        }
        return (state, state == .working ? lead?.tool : nil)
    }

    func snapshot(now: Date = Date()) -> [String: Any] {
        let d = display(now: now)
        return [
            "state": d.state.rawValue,
            "tool": jsonValue(d.tool?.rawValue),
            "leader": jsonValue(leader?.id),
            "sessions": sessions.values.sorted { $0.lastEvent > $1.lastEvent }.map { s in
                [
                    "session_id": s.id,
                    "state": s.state.rawValue,
                    "tool_name": jsonValue(s.toolName),
                    "cwd": jsonValue(s.cwd),
                    "seconds_since_event": Int(now.timeIntervalSince(s.lastEvent)),
                ] as [String: Any]
            },
        ]
    }
}

/// JSONSerialization cannot encode a boxed nil.
private func jsonValue(_ value: String?) -> Any {
    if let value { return value }
    return NSNull()
}

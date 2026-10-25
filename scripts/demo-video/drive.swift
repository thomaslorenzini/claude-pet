// Plays the demo storyboard on a private Claude Pet instance: fake hook events over HTTP, and real
// mouse moves, clicks and drags with CGEvent (the pet only reacts to real input). Every cursor
// position is logged with its host time, so the render can draw a fake cursor exactly on it.
//
//   drive take <log.jsonl>          the whole storyboard
//   drive windows                   the pet's windows (CG coordinates, points)
//   drive move x y [seconds]        helpers for rehearsals
//   drive click x y
//   drive drag x0 y0 x1 y1 [seconds]
//
// Coordinates are CG global points: origin at the top left of the main display.
import AppKit
import CoreGraphics
import Foundation
import QuartzCore

setbuf(stdout, nil)
let port = ProcessInfo.processInfo.environment["CLAUDE_PET_PORT"] ?? "47400"
let base = "http://127.0.0.1:\(port)"

// MARK: Log

var logHandle: FileHandle?
func log(_ fields: [String: Any]) {
    var f = fields
    f["t"] = CACurrentMediaTime()
    guard let h = logHandle, let data = try? JSONSerialization.data(withJSONObject: f) else { return }
    h.write(data)
    h.write("\n".data(using: .utf8)!)
}
func mark(_ name: String) { log(["mark": name]); print(String(format: "%6.2f  %@", CACurrentMediaTime() - t0, name)) }

// MARK: HTTP

func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 2, wait: Bool = true) {
    var req = URLRequest(url: URL(string: base + path)!)
    req.httpMethod = "POST"
    req.timeoutInterval = timeout
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, _, error in
        if let error, wait { print("POST \(path) failed: \(error.localizedDescription)") }
        sem.signal()
    }.resume()
    if wait { _ = sem.wait(timeout: .now() + timeout + 0.5) }
}

func getState() -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(string: base + "/state")!),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return json
}

let session = "my-app"
let cwd = "/Users/you/Code/my-app"
func hook(_ name: String, _ extra: [String: Any] = [:]) {
    var body: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": cwd]
    body.merge(extra) { $1 }
    post("/event", body)
}
func preTool(_ tool: String, _ input: [String: Any]) { hook("PreToolUse", ["tool_name": tool, "tool_input": input]) }
func postTool(_ tool: String, _ input: [String: Any]) { hook("PostToolUse", ["tool_name": tool, "tool_input": input, "tool_response": [:]]) }

/// A permission request: the pet holds the connection until it is answered, so it never blocks us.
func ask(_ command: String, _ description: String) {
    let body: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session, "cwd": cwd,
                               "tool_name": "Bash", "tool_input": ["command": command, "description": description]]
    post("/ask", body, timeout: 300, wait: false)
}

/// Fake status line: quotas and context for the gauges and the menu bar panel's rings.
func status() {
    let now = Date().timeIntervalSince1970
    post("/status", [
        "session_id": session,
        "rate_limits": ["five_hour": ["used_percentage": 34, "resets_at": now + 2.2 * 3600],
                        "seven_day": ["used_percentage": 21, "resets_at": now + 3.5 * 86400]],
        "context_window": ["used_percentage": 18, "context_window_size": 1_000_000],
    ])
}

// MARK: Mouse

var cursor: CGPoint = {
    CGEvent(source: nil)?.location ?? .zero
}()
var buttonDown = false

func postMouse(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func easeInOut(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }

/// Moves along a gently curved path with an ease-in-out, at 60 Hz, dragging if the button is down.
/// `arc` bends the path sideways (fraction of its length), like a hand does.
func move(to target: CGPoint, duration: Double, arc: Double = 0.08) {
    let start = cursor
    let dx = target.x - start.x, dy = target.y - start.y
    let len = hypot(dx, dy)
    let normal = len > 0 ? CGPoint(x: -dy / len, y: dx / len) : .zero
    let control = CGPoint(x: start.x + dx / 2 + normal.x * len * arc, y: start.y + dy / 2 + normal.y * len * arc)
    let steps = max(1, Int(duration * 60))
    let begin = CACurrentMediaTime()
    for i in 1...steps {
        let u = easeInOut(Double(i) / Double(steps))
        let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u
        let p = CGPoint(x: a * start.x + b * control.x + c * target.x, y: a * start.y + b * control.y + c * target.y)
        cursor = p
        postMouse(buttonDown ? .leftMouseDragged : .mouseMoved, p)
        log(["x": p.x, "y": p.y, "ev": buttonDown ? "drag" : "move"])
        // Scheduled on absolute times, so a slow event post never accumulates drift.
        let next = begin + Double(i) / 60
        let wait = next - CACurrentMediaTime()
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
    }
}

func press() {
    // A click needs a mouseMoved first, or the pet's window lets it through.
    postMouse(.mouseMoved, cursor)
    usleep(30_000)
    postMouse(.leftMouseDown, cursor)
    buttonDown = true
    log(["x": cursor.x, "y": cursor.y, "ev": "down"])
}
func release() {
    postMouse(.leftMouseUp, cursor)
    buttonDown = false
    log(["x": cursor.x, "y": cursor.y, "ev": "up"])
}
func click() { press(); usleep(90_000); release() }

func hold(_ seconds: Double) {
    // Keeps logging the (still) cursor, so the render has samples everywhere.
    let end = CACurrentMediaTime() + seconds
    while CACurrentMediaTime() < end {
        log(["x": cursor.x, "y": cursor.y, "ev": buttonDown ? "drag" : "move"])
        usleep(100_000)
    }
}

// MARK: Pet geometry

struct PetWindow { let id: Int; let frame: CGRect; let layer: Int }
func petWindows() -> [PetWindow] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        guard (w[kCGWindowOwnerName as String] as? String) == "ClaudePet",
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
        return PetWindow(id: w[kCGWindowNumber as String] as? Int ?? 0, frame: frame, layer: w[kCGWindowLayer as String] as? Int ?? 0)
    }
}

/// The floating pet's window: 24×22 sprite pixels times the scale.
func floatingPet() -> CGRect? {
    petWindows().first { abs($0.frame.width / $0.frame.height - 24.0 / 22.0) < 0.01 && $0.layer > 0 }?.frame
}
/// A point on the body (an opaque pixel: a transparent one lets the click through).
func body(of rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + rect.width * 11 / 24, y: rect.minY + rect.height * 14 / 22) }

// MARK: Storyboard

var t0 = CACurrentMediaTime()
func at(_ t: Double) {
    let wait = t0 + t - CACurrentMediaTime()
    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) } else if wait < -0.15 { print(String(format: "  late by %.2f s", -wait)) }
}

func take(logPath: String, statusIcon: CGPoint) {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    logHandle = FileHandle(forWritingAtPath: logPath)
    let rest = CGPoint(x: 1185, y: 640)
    let banner = CGPoint(x: 800, y: 46)
    let allow = CGPoint(x: 979, y: 156)
    let notchPet = CGPoint(x: 874, y: 17)
    let dropAt = CGPoint(x: 560, y: 468)
    let away = CGPoint(x: 1000, y: 250)

    hook("SessionStart", ["source": "startup"])
    status()
    t0 = CACurrentMediaTime()
    mark("start")
    cursor = rest
    postMouse(.mouseMoved, rest)
    hold(0.5)
    at(0.6); hook("UserPromptSubmit", ["prompt": "Add validation to the signup form"]); mark("thinking")
    at(3.0); preTool("Bash", ["command": "npm test"]); mark("laptop")
    hold(3.3)
    at(6.6); postTool("Bash", ["command": "npm test"]); mark("thinking2")
    at(7.4); ask("npm install zod", "Add zod for form validation"); mark("request1")
    hold(0.9)
    at(8.4); move(to: banner, duration: 1.3, arc: 0.1); mark("hover_notch")
    hold(0.9)
    at(10.6); move(to: allow, duration: 0.8, arc: -0.12); mark("on_allow")
    hold(0.35)
    at(11.8); click(); mark("allow1")
    hold(0.3)
    at(12.2); preTool("Bash", ["command": "npm install zod"])
    move(to: away, duration: 0.9, arc: 0.1)
    hold(1.0)
    at(14.2); postTool("Bash", ["command": "npm install zod"])
    at(14.6); hook("Stop"); mark("happy1")
    hold(0.8)
    at(15.6); move(to: notchPet, duration: 1.0, arc: -0.1); mark("on_notch_pet")
    hold(0.5)
    at(17.2); press(); mark("grab1")
    move(to: dropAt, duration: 1.6, arc: 0.12)
    hold(0.12)
    release(); mark("drop1")
    hold(0.35)
    // Off the pet, or the card would open at once and skip the "Claude needs you" pill.
    move(to: CGPoint(x: dropAt.x + 150, y: dropAt.y + 120), duration: 0.8, arc: 0.1)
    at(20.3); ask("git push origin signup-validation", "Push the branch for review"); mark("request2")
    hold(0.9)
    guard let pet = floatingPet() else { print("no floating pet"); return }
    at(21.3); move(to: body(of: pet), duration: 0.9, arc: 0.1); mark("hover_pet")
    hold(0.6)
    // The card opens above the pet: its Allow button is found from the card's window.
    let card = petWindows().filter { $0.frame != pet && $0.frame.maxY <= pet.minY + 40 && $0.frame.width > 200 && $0.frame.width < 600 }
        .min { $0.frame.minY > $1.frame.minY }
    var allow2 = CGPoint(x: pet.midX + 120, y: pet.minY - 30)
    if let card { allow2 = CGPoint(x: card.frame.maxX - cardAllowInset.x, y: card.frame.maxY - cardAllowInset.y) }
    print("card \(card.map { "\($0.frame)" } ?? "none") allow at \(allow2)")
    at(22.8); move(to: allow2, duration: 0.7, arc: -0.1); mark("on_allow2")
    hold(0.3)
    at(23.8); click(); mark("allow2")
    at(24.1); preTool("Bash", ["command": "git push origin signup-validation"])
    hold(0.3)
    at(24.5); move(to: statusIcon, duration: 1.1, arc: -0.08); mark("on_icon")
    hold(0.25)
    at(25.9); click(); mark("panel_open")
    at(26.5); postTool("Bash", ["command": "git push origin signup-validation"])
    at(27.0); preTool("Read", ["file_path": cwd + "/src/signup.ts"])
    hold(1.5)
    at(29.1); click(); mark("panel_close")
    hold(0.3)
    guard let pet2 = floatingPet() else { print("no floating pet"); return }
    at(29.8); move(to: body(of: pet2), duration: 1.0, arc: 0.1); mark("on_float_pet")
    hold(0.4)
    at(31.3); press(); mark("grab2")
    move(to: CGPoint(x: notchPet.x, y: notchPet.y + 4), duration: 1.5, arc: -0.12)
    hold(0.15)
    release(); mark("dock")
    hold(0.6)
    at(33.5); postTool("Read", ["file_path": cwd + "/src/signup.ts"])
    move(to: CGPoint(x: 1120, y: 560), duration: 1.1, arc: 0.1); mark("leave")
    at(34.8); hook("Stop"); mark("happy2")
    hold(3.2)
    at(39.6); mark("end")
    logHandle?.closeFile()
}

/// Where Allow sits from the card's bottom right corner (measured on a rehearsal still).
var cardAllowInset = CGPoint(x: 45, y: 28)

// MARK: Main

let args = CommandLine.arguments
func num(_ i: Int) -> Double { Double(args[i])! }
switch args.count > 1 ? args[1] : "" {
case "take":
    // The menu bar icon is passed in: the panel opens centered under it.
    let icon = CGPoint(x: num(3), y: num(4))
    if args.count > 6 { cardAllowInset = CGPoint(x: num(5), y: num(6)) }
    take(logPath: args[2], statusIcon: icon)
case "windows":
    for w in petWindows() { print(w.id, w.layer, w.frame) }
case "move":
    move(to: CGPoint(x: num(2), y: num(3)), duration: args.count > 4 ? num(4) : 0.8)
case "click":
    move(to: CGPoint(x: num(2), y: num(3)), duration: 0.3)
    click()
case "drag":
    move(to: CGPoint(x: num(2), y: num(3)), duration: 0.3)
    press()
    move(to: CGPoint(x: num(4), y: num(5)), duration: args.count > 6 ? num(6) : 1.2)
    hold(0.1)
    release()
case "state":
    print(getState())
case "status":
    status()
default:
    print("usage: drive take <log> <iconX> <iconY> [allowInsetX allowInsetY] | windows | move | click | drag")
    exit(2)
}

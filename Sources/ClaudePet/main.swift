import AppKit

let arguments = CommandLine.arguments

/// The value after `flag`, if any.
func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// `ClaudePet --export-sprites DIR` writes every frame as PNG and exits.
if let index = arguments.firstIndex(of: "--export-sprites") {
    let path = index + 1 < arguments.count ? arguments[index + 1] : "sprites-export"
    do {
        try SpriteComposer.export(to: URL(fileURLWithPath: path))
        print(tr("Sprites exportés dans ", "Sprites exported to ") + path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((tr("Export impossible : ", "Export failed: ") + "\(error)\n").utf8))
        exit(1)
    }
}

// `ClaudePet --export-icon DIR.iconset` writes the app icon at every size (scripts/make-icon.sh).
if let path = argument(after: "--export-icon") {
    do {
        try AppIcon.exportIconset(to: URL(fileURLWithPath: path))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

// `ClaudePet --onboarding-snapshot PATH [--state idle|installing|error|success] [--appearance light|dark]
// [--no-statusline] [--checked] [--no-login] [--max-height PT]` renders the first-launch window to PNG and exits, without starting the app.
if let path = argument(after: "--onboarding-snapshot") {
    _ = NSApplication.shared
    let plan = OnboardingPlan(settingsPath: "~/.claude/settings.json",
                              existingStatusLine: arguments.contains("--no-statusline") ? nil : "bash ~/.claude/statusline-command.sh",
                              hookCount: 13)
    let onboarding = OnboardingWindowController(plan: plan)
    switch argument(after: "--appearance") {
    case "dark": onboarding.window.appearance = NSAppearance(named: .darkAqua)
    case "light": onboarding.window.appearance = NSAppearance(named: .aqua)
    default: break
    }
    let phase: OnboardingWindowController.Phase
    switch argument(after: "--state") ?? "idle" {
    case "installing": phase = .installing
    case "success": phase = .success
    case "error": phase = .error(tr("`~/.claude/settings.json` n'est pas un JSON valide (ligne 12) : rien n'a été modifié.",
                                    "`~/.claude/settings.json` is not valid JSON (line 12): nothing was changed."))
    default: phase = .idle
    }
    onboarding.heightLimit = argument(after: "--max-height").flatMap(Double.init).map { CGFloat($0) }
    onboarding.preview(phase, readQuotas: arguments.contains("--checked"), launchAtLogin: !arguments.contains("--no-login"))
    onboarding.snapshot(to: path)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no app menu: the pet lives in the overlay and the menu bar extra.
app.setActivationPolicy(.accessory)
app.run()

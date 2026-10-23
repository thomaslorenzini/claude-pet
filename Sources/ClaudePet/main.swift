import AppKit

let arguments = CommandLine.arguments

// `ClaudePet --export-sprites DIR` writes every frame as PNG and exits.
if let index = arguments.firstIndex(of: "--export-sprites") {
    let path = index + 1 < arguments.count ? arguments[index + 1] : "sprites-export"
    do {
        try SpriteComposer.export(to: URL(fileURLWithPath: path))
        print("Sprites exportés dans \(path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Export impossible : \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// No Dock icon, no app menu: the pet lives in the overlay and the menu bar extra.
app.setActivationPolicy(.accessory)
app.run()

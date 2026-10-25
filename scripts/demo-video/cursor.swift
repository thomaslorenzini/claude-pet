// Saves the system arrow cursor at its largest resolution, for the fake cursor drawn in post.
//   cursor <out.png>   prints the hot spot and the size in points as JSON
import AppKit
_ = NSApplication.shared  // without an app, NSCursor's images come back empty
let out = CommandLine.arguments[1]
let cursor = NSCursor.arrow
let reps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }
guard let best = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) else { print("no cursor image"); exit(1) }
try! best.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("{\"hot_x\": \(cursor.hotSpot.x), \"hot_y\": \(cursor.hotSpot.y), \"width\": \(cursor.image.size.width), \"height\": \(cursor.image.size.height)}")

import Foundation
import CoreGraphics
// move x0 y0 x1 y1 seconds : real mouseMoved events along a line (CG global coords)
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
let steps = max(1, Int(a[4] * 60))
for i in 0...steps {
    let u = Double(i) / Double(steps)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: a[0] + (a[2] - a[0]) * u, y: a[1] + (a[3] - a[1]) * u), mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(16_666)
}

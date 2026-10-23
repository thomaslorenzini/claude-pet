import AppKit

/// Damped spring stepped by the motion timer. Slightly underdamped, so things overshoot and settle.
struct Spring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var stiffness: CGFloat = 260
    var damping: CGFloat = 19

    mutating func step(_ dt: CGFloat) {
        // Two semi-implicit Euler substeps keep stiff springs stable at 60 Hz.
        for _ in 0..<2 {
            let h = dt / 2
            velocity += (-stiffness * (value - target) - damping * velocity) * h
            value += velocity * h
        }
    }

    var isSettled: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.0005 }

    mutating func snap(to v: CGFloat) {
        value = v
        target = v
        velocity = 0
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// Where the notch is, and the black "ear" box glued to its right side.
///
/// The box starts `overlap` points *inside* the notch: there are no pixels there, so the junction
/// with the physical notch (and its rounded bottom corner) is invisible.
struct NotchGeometry {
    static let overlap: CGFloat = 14
    static let expandedScale: CGFloat = 4

    let screen: NSScreen
    /// Global x of the notch's right edge.
    let notchMaxX: CGFloat
    /// Global y of the top of the screen.
    let top: CGFloat
    let height: CGFloat
    /// Points per sprite pixel when collapsed, aligned on device pixels so nearest-neighbor stays crisp.
    let collapsedScale: CGFloat

    static func find() -> NotchGeometry? {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0, let right = screen.auxiliaryTopRightArea else { continue }
            // These areas are expressed in the screen's own space on current macOS; guard against global.
            let offset = right.maxX > screen.frame.width + 1 ? 0 : screen.frame.minX
            let height = screen.safeAreaInsets.top
            let backing = screen.backingScaleFactor
            let fit = (height - 4) / CGFloat(SpriteComposer.compactHeight)
            return NotchGeometry(
                screen: screen,
                notchMaxX: right.minX + offset,
                top: screen.frame.maxY,
                height: height,
                collapsedScale: max(1 / backing, (fit * backing).rounded(.down) / backing)
            )
        }
        return nil
    }

    struct Layout {
        var box: CGRect
        var sprite: CGRect
        var bottomRadius: CGFloat
        var fillet: CGFloat
    }

    /// `open` slides the box out of the notch (0 = hidden inside it), `expand` is the hover state.
    func layout(open: CGFloat, expand: CGFloat) -> Layout {
        let e = max(-0.2, expand)
        let o = max(0, open)
        let scale = max(collapsedScale * 0.8, lerp(collapsedScale, Self.expandedScale, e))
        let spriteSize = CGSize(width: CGFloat(SpriteComposer.compactWidth) * scale, height: CGFloat(SpriteComposer.compactHeight) * scale)
        let pad = lerp(6, 14, e)
        let boxHeight = max(height, lerp(height, spriteSize.height + 16, e))
        let visibleWidth = (pad * 2 + spriteSize.width) * o
        let box = CGRect(
            x: notchMaxX - Self.overlap, y: top - boxHeight,
            width: Self.overlap + visibleWidth, height: boxHeight
        )
        let sprite = CGRect(
            x: notchMaxX + pad, y: box.minY + (boxHeight - spriteSize.height) / 2,
            width: spriteSize.width, height: spriteSize.height
        )
        let radius = min(lerp(9, 18, e), visibleWidth / 2, boxHeight / 2)
        return Layout(box: box, sprite: sprite, bottomRadius: max(0, radius), fillet: lerp(6, 9, max(0, e)) * min(1, o))
    }

    /// Compact panel used while docked: big enough for the expanded box plus spring overshoot.
    var panelFrame: CGRect {
        let full = layout(open: 1, expand: 1.25)
        return CGRect(x: full.box.minX - 12, y: full.box.minY - 8, width: full.box.width + 36, height: full.box.height + 8)
    }

    /// Box outline in the coordinates of a view whose origin sits at `origin` on screen.
    func path(for l: Layout, origin: CGPoint) -> CGPath {
        let box = l.box.offsetBy(dx: -origin.x, dy: -origin.y)
        let L = box.minX, R = box.maxX, T = box.maxY, B = box.minY
        let notchBottom = T - height
        let depth = max(0, notchBottom - B)
        let r = l.bottomRadius
        // Left side only shows once the box hangs below the notch: round it, and blend it into the
        // notch's bottom edge with a concave fillet.
        let leftRadius = min(r, depth / 2)
        let g = min(8, depth / 2)
        let f = l.fillet

        let p = CGMutablePath()
        p.move(to: CGPoint(x: L - g, y: notchBottom))
        p.addLine(to: CGPoint(x: L - g, y: T))
        p.addLine(to: CGPoint(x: R + f, y: T))
        p.addQuadCurve(to: CGPoint(x: R, y: T - f), control: CGPoint(x: R, y: T))
        p.addLine(to: CGPoint(x: R, y: B + r))
        p.addQuadCurve(to: CGPoint(x: R - r, y: B), control: CGPoint(x: R, y: B))
        p.addLine(to: CGPoint(x: L + leftRadius, y: B))
        p.addQuadCurve(to: CGPoint(x: L, y: B + leftRadius), control: CGPoint(x: L, y: B))
        p.addLine(to: CGPoint(x: L, y: notchBottom - g))
        p.addQuadCurve(to: CGPoint(x: L - g, y: notchBottom), control: CGPoint(x: L, y: notchBottom))
        p.closeSubpath()
        return p
    }
}

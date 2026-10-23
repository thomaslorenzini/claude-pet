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

/// 0 below `edge0`, 1 above `edge1`, smooth in between.
func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// Where the notch is, and the black "ear" box glued to its right side.
///
/// The box starts `overlap` points *inside* the notch: there are no pixels there, so the junction
/// with the physical notch (and its rounded bottom corner) is invisible.
struct NotchGeometry {
    static let overlap: CGFloat = 14
    static let expandedScale: CGFloat = 4

    let screen: NSScreen
    /// Global x of the notch's left and right edges.
    let notchMinX: CGFloat
    let notchMaxX: CGFloat
    /// Global y of the top of the screen.
    let top: CGFloat
    let height: CGFloat
    /// Points per sprite pixel when collapsed, aligned on device pixels so nearest-neighbor stays crisp.
    let collapsedScale: CGFloat

    static func find() -> NotchGeometry? {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0, let right = screen.auxiliaryTopRightArea,
                  let left = screen.auxiliaryTopLeftArea else { continue }
            // These areas are expressed in the screen's own space on current macOS; guard against global.
            let offset = right.maxX > screen.frame.width + 1 ? 0 : screen.frame.minX
            let height = screen.safeAreaInsets.top
            let backing = screen.backingScaleFactor
            let fit = (height - 4) / CGFloat(SpriteComposer.compactHeight)
            return NotchGeometry(
                screen: screen,
                notchMinX: left.maxX + offset,
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
        /// Gauge circles, in `QuotaStore.Kind` order: 5 h (bottom left of the pet), week (bottom
        /// right), context (top right). They move with the box.
        var gauges: [CGRect]
        var gaugeLineWidth: CGFloat
        /// Hover progress, used to show the numbers inside the gauges once they are big enough.
        var expand: CGFloat
        /// Gauges fade in late in the hover expansion, once they have room.
        var gaugeAlpha: CGFloat
    }

    // Apple does not expose the notch's shape: these defaults are eyeballed on a 14" MacBook Pro and
    // can be tuned live with `POST /control {"notch_radius": r, "notch_ear": r}`.
    static let radiusKey = "notchBottomRadius"
    static let earKey = "notchEarRadius"
    /// Radius of the notch's bottom corners, reused for every convex and concave corner of the box.
    static var bottomRadius: CGFloat { stored(radiusKey, default: 10) }
    /// Radius of the small concave "ears" where the notch meets the top of the screen.
    static var earRadius: CGFloat { stored(earKey, default: 6) }

    private static func stored(_ key: String, default value: CGFloat) -> CGFloat {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? CGFloat(v) : value
    }

    /// `open` slides the box out from under the notch (0 = fully hidden behind it), `expand` is the
    /// hover state. Corner radii never change: they are the notch's own, whatever the size.
    func layout(open: CGFloat, expand: CGFloat) -> Layout {
        let e = max(-0.2, expand)
        let scale = max(collapsedScale * 0.8, lerp(collapsedScale, Self.expandedScale, e))
        let spriteSize = CGSize(width: CGFloat(SpriteComposer.compactWidth) * scale, height: CGFloat(SpriteComposer.compactHeight) * scale)
        let pad = lerp(6, 12, e)
        // Gauges only exist on hover: collapsed, they take no room and the box is the pet alone.
        let shown = min(1, max(0, e))
        let gap = 8 * shown
        let ring = 20 * shown
        let inset = 9 * shown
        let boxHeight = max(height, lerp(height, spriteSize.height + 16, e))
        let r = Self.bottomRadius, ear = Self.earRadius
        let fullWidth = pad + ring + gap + spriteSize.width + gap + ring + pad
        // Sliding rather than widening keeps the corners intact while the box comes out. Overshoot is
        // ignored here: past 1 the box's left edge would leave the notch and reveal a gap. Nor may it
        // slide past the notch's left edge, where it would show.
        let overlap = max(Self.overlap, r + 4)
        let slide = min(max(0, 1 - open) * (fullWidth + ear + 1), notchMaxX - overlap - notchMinX)
        let box = CGRect(
            x: notchMaxX - overlap - slide, y: top - boxHeight,
            width: overlap + fullWidth, height: boxHeight
        )
        // The seat does not move with the box: a pet landing while the box is still settling stays put.
        let sprite = CGRect(
            x: notchMaxX + pad + ring + gap, y: box.minY + (boxHeight - spriteSize.height) / 2,
            width: spriteSize.width, height: spriteSize.height
        )
        let left = box.minX + overlap + pad, right = box.maxX - pad - ring
        let gauges = [
            CGRect(x: left, y: box.minY + inset, width: ring, height: ring),
            CGRect(x: right, y: box.minY + inset, width: ring, height: ring),
            CGRect(x: right, y: box.maxY - inset - ring, width: ring, height: ring),
        ]
        return Layout(
            box: box, sprite: sprite, bottomRadius: min(r, boxHeight / 2, fullWidth / 2), fillet: ear,
            gauges: gauges, gaugeLineWidth: 3 * shown, expand: e,
            gaugeAlpha: smoothstep(0.35, 0.9, e)
        )
    }

    /// Compact panel used while docked: big enough for the expanded box plus spring overshoot, the box
    /// sliding back under the notch, and the gauge tooltips below the box.
    var panelFrame: CGRect {
        let full = layout(open: 1, expand: 1.25)
        let minX = notchMinX - 12
        let minY = full.box.minY - 44
        return CGRect(x: minX, y: minY, width: full.box.maxX + 240 - minX, height: top - minY)
    }

    /// Box outline in the coordinates of a view whose origin sits at `origin` on screen.
    func path(for l: Layout, origin: CGPoint) -> CGPath {
        let box = l.box.offsetBy(dx: -origin.x, dy: -origin.y)
        let L = box.minX, R = box.maxX, T = box.maxY, B = box.minY
        let notchBottom = T - height
        let depth = max(0, notchBottom - B)
        let r = l.bottomRadius
        // Below the notch, the left side is rounded and joins the notch's bottom edge with a concave
        // corner, both with the notch's radius, as if the notch itself had grown.
        let leftRadius = min(r, depth / 2)
        let g = min(r, depth / 2)
        let f = l.fillet

        let p = CGMutablePath()
        func corner(_ at: CGPoint, _ next: CGPoint, _ radius: CGFloat) {
            if radius < 0.01 { p.addLine(to: at) } else { p.addArc(tangent1End: at, tangent2End: next, radius: radius) }
        }
        p.move(to: CGPoint(x: L - g, y: notchBottom))
        p.addLine(to: CGPoint(x: L - g, y: T))
        p.addLine(to: CGPoint(x: R + f, y: T))
        corner(CGPoint(x: R, y: T), CGPoint(x: R, y: T - f), f)
        corner(CGPoint(x: R, y: B), CGPoint(x: R - r, y: B), r)
        corner(CGPoint(x: L, y: B), CGPoint(x: L, y: B + leftRadius), leftRadius)
        corner(CGPoint(x: L, y: notchBottom), CGPoint(x: L - g, y: notchBottom), g)
        p.closeSubpath()
        return p
    }
}

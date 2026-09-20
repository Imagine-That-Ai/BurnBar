import SwiftUI

// MARK: - 2. Ignis (Real-Fire Canvas Flame)
//
// A real fire — not a stack of gradient teardrops. We simulate ~28
// luminance particles that spawn at the wick, drift up + inward in a
// cone, expand and cool over their lifetime, and expire near the tip.
// Every particle is stamped twice (a large blurred halo + a sharp inner
// core), all blended `.plusLighter` so overlapping density brightens
// the silhouette into a continuous flame body. Sharper coral sparks
// shoot above the cone and fade.
//
// Off-state: the flame is never dead. A static outlined ember silhouette
// holds a slow coal pulse at the base + occasional drifting embers.
//
// Geometry conventions:
//   • baseY:      tapered base of the flame
//   • waistY:     widest belly
//   • neckY:      narrow neck above the belly
//   • tipY:       sharp upper tip
// Each layer scales the silhouette inward + animates wobble independently.

/// One teardrop flame layer. `tier` (0 outer / 1 mid / 2 core) selects how
/// Legacy teardrop silhouette — kept ONLY because the icon glow halo and
/// off-state outline reference it. The real fire is rendered by
/// `LivingFireCanvas` below.
struct IgnisFlameShape: Shape {
    var tier: Int
    var flicker: CGFloat

    var animatableData: CGFloat {
        get { flicker }
        set { flicker = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = w / 2

        // Per-tier scaling — each inner layer is tighter and shorter.
        let scale: CGFloat
        let topYOffset: CGFloat
        switch tier {
        case 0:  scale = 1.00; topYOffset = 0.00
        case 1:  scale = 0.78; topYOffset = 0.06
        default: scale = 0.50; topYOffset = 0.14
        }

        // Wobble: waist shifts left/right + tip leans, slightly off-phase
        // per tier so the layers aren't synchronized.
        let waistShift = sin(flicker * .pi * 2 + CGFloat(tier) * 0.7) * (0.025 * scale)
        let tipShift   = sin(flicker * .pi * 2 + CGFloat(tier) * 1.3 + 0.4) * (0.04 * scale)
        let breathe    = 0.95 + 0.05 * sin(flicker * .pi * 2 + CGFloat(tier) * 0.9)

        let baseY = h * 0.86
        let waistY = h * (0.56 + topYOffset * 0.5)
        let neckY = h * (0.30 + topYOffset)
        let tipY  = h * (0.08 + topYOffset)

        let baseHalfW = w * 0.16 * scale
        let waistHalfW = w * 0.30 * scale * breathe
        let neckHalfW  = w * 0.14 * scale

        let baseL = CGPoint(x: cx - baseHalfW, y: baseY)
        let baseR = CGPoint(x: cx + baseHalfW, y: baseY)
        let waistL = CGPoint(x: cx - waistHalfW + w * waistShift, y: waistY)
        let waistR = CGPoint(x: cx + waistHalfW + w * waistShift, y: waistY)
        let neckL = CGPoint(x: cx - neckHalfW + w * waistShift * 0.6, y: neckY)
        let neckR = CGPoint(x: cx + neckHalfW + w * waistShift * 0.6, y: neckY)
        let tip = CGPoint(x: cx + w * tipShift, y: tipY)

        var path = Path()
        path.move(to: baseL)
        path.addCurve(to: waistL,
                      control1: CGPoint(x: cx - w * 0.10 * scale, y: baseY - h * 0.04),
                      control2: CGPoint(x: cx - w * 0.36 * scale + w * waistShift, y: h * 0.68))
        path.addCurve(to: neckL,
                      control1: CGPoint(x: cx - w * 0.30 * scale + w * waistShift, y: h * 0.44),
                      control2: CGPoint(x: cx - w * 0.22 * scale + w * waistShift * 0.6, y: h * (0.34 + topYOffset)))
        path.addQuadCurve(to: tip,
                          control: CGPoint(x: cx - w * 0.14 * scale + w * tipShift * 0.3,
                                           y: h * (0.14 + topYOffset)))
        path.addQuadCurve(to: neckR,
                          control: CGPoint(x: cx + w * 0.20 * scale + w * tipShift * 0.3,
                                           y: h * (0.16 + topYOffset)))
        path.addCurve(to: waistR,
                      control1: CGPoint(x: cx + w * 0.24 * scale + w * waistShift * 0.6, y: h * (0.34 + topYOffset)),
                      control2: CGPoint(x: cx + w * 0.32 * scale + w * waistShift, y: h * 0.44))
        path.addCurve(to: baseR,
                      control1: CGPoint(x: cx + w * 0.36 * scale + w * waistShift, y: h * 0.68),
                      control2: CGPoint(x: cx + w * 0.10 * scale, y: baseY - h * 0.04))
        path.closeSubpath()
        return path
    }
}

/// Compatibility shim — the icon glow halo continues to reference the
/// outermost flame silhouette by this name.
struct IgnisOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        IgnisFlameShape(tier: 0, flicker: 0).path(in: rect)
    }
}

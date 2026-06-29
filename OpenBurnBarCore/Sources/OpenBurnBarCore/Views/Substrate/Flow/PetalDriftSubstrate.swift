import SwiftUI
import CoreGraphics

/// Petal Drift — faithful port of imaginethat `flow/petal-drift.ts` drawBody.
///
/// Each silhouette point is ONE soft cherry-blossom petal: a filled bezier
/// teardrop (two quadratic curves) in the point's own color, with a cached
/// cream→transparent sheen sprite floated on top. The local curl-wind tilts
/// each petal's long axis (`windAngle`), a tiny ≤3px curl orbit drifts the
/// centroid around its locked target, and a per-point flutter oscillates the
/// width so the petal flips edge-on↔broadside (~0.3 Hz). A fixed top-left key
/// light dims back-facing petals via `shade()` toward a mauve/cool fold.
///
/// Compositing mirrors the source exactly: the colored teardrop BASE is
/// source-over on BOTH polarities; the white sheen sprite is additive
/// (`.plusLighter`) on DARK only, `.normal` on light — never a blow-out.
///
/// `frame.reduced` → a poised STILL bloom (no orbit/spin, full broadside,
/// static wind angle, `f = 1`). `frame.batteryThrottled` → drop the sheen pass,
/// keeping just the colored teardrops. Discrete petals (not a stroke), so glyph
/// particles still draw on top — no `suppressesGlyphs`. Allocates one resolved
/// sprite per frame, then draws it many times.
public final class PetalDriftSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // Cached white soft-gradient petal sprite (teardrop-clipped cream radial +
    // specular sheen arc + mauve base-fold tint). Long axis points along +X,
    // tip at +X. Baked once via CoreGraphics; nil if no bitmap backend.
    private var sheen: Image?
    private var sheenTried = false
    private let SPRITE = 96

    /// Cheap divergence-free-ish curl wind: the flow ANGLE at (x,y,phase).
    /// Two layered sinusoids whose ratio reads as a coherent swirling current.
    @inline(__always)
    private func windAngle(_ x: Double, _ y: Double, _ phase: Double) -> Double {
        let a = sin(x * 0.013 + phase) + cos(y * 0.011 - phase * 0.7)
        let b = sin((x + y) * 0.008 - phase * 0.5)
        return atan2(a, b + 1.35)
    }

    /// Bake the soft petal sheen sprite ONCE (source `ensureSheen`): clip to the
    /// teardrop, fill the cream core→rim radial, stroke the specular sheen arc
    /// along the upper flank, then overlay the faint mauve base-fold tint. Long
    /// axis points along +X with the base at sprite (0.32·spriteSide, 0.5·spriteSide). Cached.
    private func ensureSheen() -> Image? {
        if sheenTried { return sheen }
        sheenTried = true

        let spriteSide = SPRITE
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let g = CGContext(
            data: nil, width: spriteSide, height: spriteSide, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Flip into a top-left-origin (canvas) coordinate system so the source
        // coordinates port verbatim — upper flank stays upper in the final image.
        g.translateBy(x: 0, y: CGFloat(spriteSide))
        g.scaleBy(x: 1, y: -1)

        let spriteSideD = Double(spriteSide)
        let cx = spriteSideD * 0.32       // petal base x (occupies the right ~3/4)
        let cy = spriteSideD * 0.5
        let len = spriteSideD * 0.62      // tip distance from base
        let halfW = spriteSideD * 0.27    // max half-width

        // Teardrop path: upper flank base→tip, lower flank tip→base (two quads).
        let tipX = cx + len
        let petal = CGMutablePath()
        petal.move(to: CGPoint(x: cx, y: cy))
        petal.addQuadCurve(to: CGPoint(x: tipX, y: cy),
                           control: CGPoint(x: cx + len * 0.45, y: cy - halfW))
        petal.addQuadCurve(to: CGPoint(x: cx, y: cy),
                           control: CGPoint(x: cx + len * 0.45, y: cy + halfW))
        petal.closeSubpath()
        g.addPath(petal)
        g.clip()

        // 1) Soft core→rim radial: warm cream/white core fading to translucent.
        let cream = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95),
            CGColor(srgbRed: 1, green: 250.0 / 255, blue: 252.0 / 255, alpha: 0.62),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray, locations: [0, 0.28, 0.62, 1])!
        let creamC = CGPoint(x: cx + len * 0.34, y: cy)
        g.drawRadialGradient(cream, startCenter: creamC, startRadius: 0,
                             endCenter: creamC, endRadius: len * 0.95, options: [])

        // 2) A single soft specular sheen arc along the upper flank — a linear
        //    white 0→0.5→0 gradient clipped to the stroked quad arc.
        g.saveGState()
        let arc = CGMutablePath()
        arc.move(to: CGPoint(x: cx + len * 0.1, y: cy - halfW * 0.45))
        arc.addQuadCurve(to: CGPoint(x: cx + len * 0.92, y: cy - halfW * 0.1),
                         control: CGPoint(x: cx + len * 0.55, y: cy - halfW * 0.78))
        g.addPath(arc)
        g.setLineWidth(spriteSideD * 0.05)
        g.setLineCap(.butt)
        g.replacePathWithStrokedPath()
        g.clip()
        let spec = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray, locations: [0, 0.5, 1])!
        g.drawLinearGradient(spec, start: CGPoint(x: cx, y: cy - halfW),
                             end: CGPoint(x: cx + len, y: cy + halfW * 0.2), options: [])
        g.restoreGState()

        // 3) A faint darker mauve tint at the base (the fold/shadow where petals
        //    overlap), source-over within the teardrop clip.
        let mr = 120.0 / 255, mg = 70.0 / 255, mb = 95.0 / 255
        let fold = CGGradient(colorsSpace: cs, colors: [
            CGColor(srgbRed: mr, green: mg, blue: mb, alpha: 0.30),
            CGColor(srgbRed: mr, green: mg, blue: mb, alpha: 0.05),
            CGColor(srgbRed: mr, green: mg, blue: mb, alpha: 0.0)
        ] as CFArray, locations: [0, 0.7, 1])!
        let foldC = CGPoint(x: cx, y: cy)
        g.drawRadialGradient(fold, startCenter: foldC, startRadius: 0,
                             endCenter: foldC, endRadius: len * 0.5, options: [])

        guard let cg = g.makeImage() else { return nil }
        sheen = Image(decorative: cg, scale: 1)
        return sheen
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let t = frame.t

        // f eases the bloom in with assembly (settleProgress == source `formed`).
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1)
        // Slow current drift; frozen to a fixed phase under reduced motion.
        let phase = reduced ? 1.1 : t * 0.22

        // Petal scale: a touch below inter-point spacing so petals cluster into a
        // readable blossom-mosaic. R / sqrt(count) ≈ inter-point spacing.
        let spacing = frame.cloudRadius / max(8, (Double(count)).squareRoot())
        let petalLen = clampD(frame.sizePx * 3.0 + spacing * 0.9, 5, 11)

        // Fixed top-left key light for the back-facing orientation cull.
        let lightX = -0.62, lightY = -0.78

        // Fold tints the petal cools toward when back-lit (source `shade`).
        let fold = dark
            ? RGBA(r: 70.0 / 255, g: 40.0 / 255, b: 58.0 / 255, a: 1)
            : RGBA(r: 150.0 / 255, g: 120.0 / 255, b: 140.0 / 255, a: 1)

        // Base teardrop is always source-over (both polarities). The colored
        // body sits on this context; the sheen gets its own per-petal copy.
        var ctx = baseCtx
        ctx.blendMode = .normal

        // Cached cream→transparent teardrop sheen (soft pastel petal gradient +
        // specular streak + mauve fold). Baked ONCE, then resolved once per frame
        // and drawn many times — never re-baked per dot.
        let sheenImg: Image? = lite ? nil : ensureSheen()
        let sheen: GraphicsContext.ResolvedImage? = sheenImg.map { ctx.resolve($0) }

        for i in 0..<count {
            let d = frame.dots[i]
            let tx = d.x, ty = d.y
            let seed = shash(Double(i) * 1.93 + 0.27)
            let ph = seed * TAU

            // Local wind orients the petal's long axis along the current.
            let wind = windAngle(tx, ty, phase + seed * 0.6)

            // Tiny curl orbit (≤3px), flutter (edge-on↔broadside), slow spin.
            var ox = 0.0, oy = 0.0, flutter = 1.0, spin = 0.0
            if !reduced {
                let orbT = t * 0.55 + ph
                let amp = 2.2 * f
                ox = cos(orbT) * amp
                oy = sin(orbT * 1.13 + 0.7) * amp * 0.8
                flutter = sin(t * 1.9 + ph)
                spin = sin(t * 0.5 + ph * 1.7) * 0.22
            }
            let x = tx + ox, y = ty + oy
            let ang = wind + spin

            // |flutter| maps edge-on (thin) → broadside (full), with a floor.
            let broad = 0.32 + 0.68 * abs(flutter)

            // Orientation cull: broadside normal vs the key light. A petal tipped
            // away from the light (and near edge-on) reads darker/edge-lit.
            let nx = cos(ang + .pi / 2), ny = sin(ang + .pi / 2)
            let facing = nx * lightX + ny * lightY
            let lit = 0.6 + 0.4 * smoothstep(-1, 1, facing * (flutter >= 0 ? 1 : -1))

            let len = petalLen * (0.85 + 0.3 * seed)
            let halfW = len * 0.42 * broad

            // Body alpha eases in with assembly; back-facing petals lift lighter.
            let aBody = clampD((0.62 + 0.34 * lit) * f, 0, 1) * d.rgba.a

            // 1) Colored teardrop BASE — brand-tinted petal body, shaded toward
            //    the cool fold when back-lit. One filled path per petal.
            let cc: RGBA = lit >= 0.999 ? d.rgba
                : d.rgba.mix(with: fold, amount: 1 - clampD(lit, 0.4, 1))

            var petal = Path()
            petal.move(to: .zero)
            petal.addQuadCurve(to: CGPoint(x: len, y: 0),
                               control: CGPoint(x: len * 0.45, y: -halfW))
            petal.addQuadCurve(to: .zero,
                               control: CGPoint(x: len * 0.45, y: halfW))
            petal.closeSubpath()
            let xform = CGAffineTransform(translationX: x, y: y).rotated(by: ang)
            ctx.fill(petal.applying(xform),
                     with: .color(cc.withOpacity(aBody).color))

            // 2) Soft sheen sprite over the base → the pastel gradient + highlight.
            //    Additive on dark, source-over on light; narrows with `broad` so
            //    an edge-on petal sheds its sheen. Dropped under battery throttle.
            //    Placement mirrors the source: scale local space, then draw the
            //    SPRITE-square so its internal base (0.32·spriteSide, 0.5·spriteSide) lands at (0,0).
            if let sheen {
                let aSheen = clampD((dark ? 0.5 : 0.4) * lit * f, 0, 0.7)
                if aSheen > 0.003 {
                    let spriteSide = Double(SPRITE)
                    let scaleX = (len / (spriteSide * 0.62)) * 1.04
                    let scaleY = scaleX * broad
                    var sctx = ctx
                    sctx.translateBy(x: x, y: y)
                    sctx.rotate(by: .radians(ang))
                    sctx.scaleBy(x: scaleX, y: scaleY)
                    sctx.blendMode = dark ? .plusLighter : .normal
                    sctx.opacity = aSheen
                    sctx.draw(sheen, in: CGRect(x: -spriteSide * 0.32, y: -spriteSide * 0.5,
                                                width: spriteSide, height: spriteSide))
                }
            }
        }

        return true
    }
}

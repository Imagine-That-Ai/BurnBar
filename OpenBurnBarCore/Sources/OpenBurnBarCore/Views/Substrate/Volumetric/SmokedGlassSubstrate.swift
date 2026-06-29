import SwiftUI

/// Smoked Glass Slab — faithful port of imaginethat `volumetric/smoked-glass.ts`
/// `drawBody` (the only SOLID material in the family).
///
/// Each silhouette point is a small extruded glass CHIP: a rotated rounded quad
/// with a static per-point facet normal (outward bearing from the cloud centroid +
/// per-seed ±0.85rad jitter — the "facet tree" look) and a baked depth = screen
/// altitude. A single slow top-light rakes the slab — `lightAng = -1.05 + 0.5·sin(t·0.04)`
/// — so the per-chip `lit = clamp(n·light·0.5+0.5)` migrates and specular rims crawl.
/// Chips draw DEPTH-SORTED back→front (the load-bearing correctness detail) so the
/// cluster reads as one carved, semi-transparent solid. Per chip, back→front:
///   1. a colored smoked rounded-quad BASE (.normal) — `lerp(color, cool-slate, smoke)`
///      darkened by depth `·(0.62+0.28·depth)`, alpha `clamp((dark .52/light .6)·f, …, .85)`;
///   2. a white facet-shading overlay quad (additive on dark / source-over on light)
///      at alpha `clamp((dark .5/light .34)·(0.5+0.7·lit)·f, …, .9)` — the lit form;
///   3. a soft inner trapped-glow radial when `lit>0.42`, gated by a 1.8s breath
///      (dropped under battery throttle).
/// A second face-culled pass strokes a thin near-white specular rim on the lit edge
/// of facets whose `n·light ≥ 0.45`, twinkling on `t·1.7+phase` (dropped under throttle).
/// Sub-pixel sway (`sin/cos(t·~0.5+phase)`) breathes the volume without blurring the
/// silhouette. `reduced` → a poised STILL slab (light frozen at -1.05, breath 0.6,
/// no sway, twinkle 0.7). Normals/depth/phase/rotation and the depth draw-order are
/// baked once per count; the exact alpha/cool/smoke constants ARE the look.
///
/// Faithful simplification vs. source: the source bakes 12 linear-gradient chip
/// sprites (a cool→rim luminance ramp along the lit diagonal). Here the in-chip
/// gradient — sub-pixel at the 1.4…7px chip footprint — is collapsed to one uniform
/// white overlay quad keyed to `lit`, so the dominant per-chip brightness + the
/// depth sort + the crawling rims (the actual readable signals) are preserved with
/// ≤2 fills + 1 stroke per chip and zero per-frame gradient allocation.
public final class SmokedGlassSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // ── baked per-point facet field (rebuilt only when the point count changes) ──
    private var n = -1
    private var nxA: [Double] = []    // facet normal x
    private var nyA: [Double] = []    // facet normal y
    private var depthA: [Double] = [] // 0 far → 1 near (== screen altitude)
    private var phaseA: [Double] = [] // per-seed sway / twinkle phase
    private var rotC: [Double] = []   // cos(atan2(ny,nx)·0.5) — quad rotation
    private var rotS: [Double] = []   // sin(atan2(ny,nx)·0.5)
    private var orderA: [Int] = []    // draw order: back (low depth) → front (high)
    // ── per-frame scratch (reused across passes; no per-frame allocation) ──
    private var swX: [Double] = []
    private var swY: [Double] = []
    private var litA: [Double] = []

    /// Bake normals, depth, phase, per-chip rotation and the back→front draw order.
    /// Purely a function of i + screen position (matches source `ensureField`).
    private func buildField(_ frame: SwarmSubstrateFrame) {
        let count = frame.dots.count
        n = count
        nxA = [Double](repeating: 0, count: count)
        nyA = [Double](repeating: 0, count: count)
        depthA = [Double](repeating: 0, count: count)
        phaseA = [Double](repeating: 0, count: count)
        rotC = [Double](repeating: 0, count: count)
        rotS = [Double](repeating: 0, count: count)
        orderA = Array(0..<count)
        swX = [Double](repeating: 0, count: count)
        swY = [Double](repeating: 0, count: count)
        litA = [Double](repeating: 0, count: count)
        guard count > 0 else { return }

        let cx = frame.cx, cy = frame.cy
        var minY = frame.dots[0].y, maxY = frame.dots[0].y
        for d in frame.dots {
            if d.y < minY { minY = d.y }
            if d.y > maxY { maxY = d.y }
        }
        let span = (maxY - minY) == 0 ? 1 : (maxY - minY)

        for i in 0..<count {
            let d = frame.dots[i]
            let fi = Double(i)
            let seed = shash(fi * 1.37 + 0.5)
            // facet normal: outward bearing from the centroid (faces fan like a cut
            // crystal) + per-seed jitter so neighbours catch light at slight angles.
            let bearing = atan2(d.y - cy, d.x - cx)
            let jit = (shash(fi * 2.71 + 0.13) - 0.5) * 1.7
            let a = bearing + jit
            nxA[i] = cos(a)
            nyA[i] = sin(a)
            // depth = altitude: lower-on-screen chips are NEARER (drawn last).
            depthA[i] = (d.y - minY) / span
            phaseA[i] = seed * TAU
            let half = atan2(nyA[i], nxA[i]) * 0.5
            rotC[i] = cos(half)
            rotS[i] = sin(half)
        }
        // depth-order is stable (altitude is static), so sort once per count change.
        orderA.sort { depthA[$0] < depthA[$1] }
    }

    /// A rotated rounded-quad chip path centred at (cx,cy); `rc`,`rs` = cos/sin of
    /// the chip's (pre-baked) `ang·0.5` rotation. Matches the source roundRect quad.
    @inline(__always)
    private func chipPath(_ cx: Double, _ cy: Double, _ r: Double, _ rc: Double, _ rs: Double) -> Path {
        let xf = CGAffineTransform(a: rc, b: rs, c: -rs, d: rc, tx: cx, ty: cy)
        let rect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        return Path(roundedRect: rect, cornerRadius: r * 0.42).applying(xf)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }
        if n != count { buildField(frame) }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let t = frame.t
        let radius = frame.cloudRadius
        let sizePx = frame.sizePx
        // fade-in × (no in-place fracture in the substrate): formGate 0.5…1.
        let f = clampD(frame.settleProgress, 0, 1) * 0.5 + 0.5

        // single global top-light direction (frozen in a poised pose under reduced).
        let lightAng = reduced ? -1.05 : -1.05 + 0.5 * sin(t * 0.04)
        let lx = cos(lightAng), ly = sin(lightAng)
        // 1.8s breath modulates the trapped-glow alpha (the medium inhaling).
        let breath = reduced ? 0.6 : 0.5 + 0.5 * sin(t * (TAU / 1.8))
        // chip footprint scales with the cloud so it stays a packed solid.
        let chipR = clampD(sizePx * 1.85 + radius * 0.012, 1.4, 7)

        // smoked, low-saturation cool slate the base is pulled toward.
        let smoke = dark ? 0.32 : 0.18
        let coolR = dark ? 120.0 / 255 : 70.0 / 255
        let coolG = dark ? 140.0 / 255 : 84.0 / 255
        let coolB = dark ? 175.0 / 255 : 116.0 / 255

        // ── per-frame preloop: sub-pixel sway + facet lighting (reused by all passes)
        for i in 0..<count {
            let d = frame.dots[i]
            var x = d.x, y = d.y
            if !reduced {
                // nearer chips (high depth) sway a touch more; never enough to blur.
                let swAmp = 0.5 + 0.7 * depthA[i]
                x += sin(t * 0.5 + phaseA[i]) * swAmp
                y += cos(t * 0.46 + phaseA[i] * 1.3) * swAmp * 0.7
            }
            swX[i] = x
            swY[i] = y
            let ndl = nxA[i] * lx + nyA[i] * ly        // -1…1
            litA[i] = clampD(ndl * 0.5 + 0.5, 0, 1)    // 0 away → 1 toward light
        }

        // ── pass 1: depth-sorted chips — colored smoked BASE + white facet overlay
        //            + soft trapped glow, painted back→front (matches source pass 1) ──
        let baseA = clampD((dark ? 0.52 : 0.6) * f, 0, 0.85)
        let drawR = chipR * 1.18
        // trapped-glow sprite: soft inner white radial (resolved ONCE per frame).
        let trapImg = baseCtx.resolve(sprites.radial(diameter: 40, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.95)),
            (0.4, RGBA(r: 1, g: 1, b: 1, a: 0.34)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))

        // colored smoked base fill for chip `i` (the glass body mass).
        func paintBase(_ ctx: inout GraphicsContext, _ i: Int) {
            let base = frame.dots[i].rgba
            let dep = depthA[i]
            let r0 = lerp(base.r, coolR, smoke) * (0.62 + 0.28 * dep)
            let g0 = lerp(base.g, coolG, smoke) * (0.62 + 0.28 * dep)
            let b0 = lerp(base.b, coolB, smoke) * (0.62 + 0.30 * dep)
            let col = RGBA(r: clampD(r0, 0, 1), g: clampD(g0, 0, 1), b: clampD(b0, 0, 1), a: baseA)
            ctx.fill(chipPath(swX[i], swY[i], chipR, rotC[i], rotS[i]), with: .color(col.color))
        }
        // white facet-shading overlay + breathing trapped glow for chip `i`.
        // `ctx`'s blend mode is set by the caller (additive on dark / source-over on light).
        func paintFacet(_ ctx: inout GraphicsContext, _ i: Int) {
            let lit = litA[i]
            let facetA = clampD((dark ? 0.5 : 0.34) * (0.5 + 0.7 * lit) * f, 0, 0.9)
            if facetA > 0.004 {
                ctx.fill(chipPath(swX[i], swY[i], drawR, rotC[i], rotS[i]),
                         with: .color(.white.opacity(facetA)))
            }
            // soft inner trapped glow — light caught in the medium, breathing.
            // An extra halo pass: dropped when battery-throttled.
            if !lite && lit > 0.42 {
                let tg = (lit - 0.42) / 0.58
                let ta = clampD((dark ? 0.3 : 0.16) * tg * (0.6 + 0.4 * breath) * f, 0, 0.55)
                if ta > 0.01 {
                    let tr = chipR * (0.85 + 0.4 * tg)
                    var g = ctx
                    g.opacity = ta
                    g.draw(trapImg, in: CGRect(x: swX[i] - tr, y: swY[i] - tr, width: tr * 2, height: tr * 2))
                }
            }
        }

        if dark {
            // Dark: the overlay is additive (.plusLighter), which COMMUTES across
            // layers, so we may split into two whole-field passes (cheaper state
            // churn) without changing the composite — base pass then glow pass.
            var fillCtx = baseCtx
            fillCtx.blendMode = .normal
            for oi in 0..<count { paintBase(&fillCtx, orderA[oi]) }
            var overlayCtx = baseCtx
            overlayCtx.blendMode = .plusLighter
            for oi in 0..<count { paintFacet(&overlayCtx, orderA[oi]) }
        } else {
            // Light: the overlay is source-over (.normal), which does NOT commute —
            // a split would let a FARTHER chip's facet land over a NEARER chip's
            // base. Fuse base+facet+trap into one back→front loop on a single
            // .normal ctx so a nearer base correctly occludes a farther facet
            // (matches the source's per-chip back-to-front draw).
            var ctx = baseCtx
            ctx.blendMode = .normal
            for oi in 0..<count {
                let i = orderA[oi]
                paintBase(&ctx, i)
                paintFacet(&ctx, i)
            }
        }

        // ── pass 2: thin specular rim strokes on light-facing facets (face-culled) ──
        // Orientation culling so the slab catches a coherent specular sheet, not every
        // chip. An extra pass: dropped when battery-throttled.
        if !lite {
            var specCtx = baseCtx
            specCtx.blendMode = dark ? .plusLighter : .normal
            let specCap = dark ? 0.95 : 0.7
            let lineW = dark ? 1.1 : 1.0
            for oi in 0..<count {
                let i = orderA[oi]
                let ndl = nxA[i] * lx + nyA[i] * ly
                if ndl < 0.45 { continue }                 // facet faces away → no rim
                let spec = (ndl - 0.45) / 0.55             // 0…1 over the lit band
                // faint per-chip twinkle so glints scintillate as the light drifts.
                let tw = reduced ? 0.7 : 0.65 + 0.35 * sin(t * 1.7 + phaseA[i] * 1.7)
                let a = clampD((dark ? 0.5 : 0.4) * spec * tw * f, 0, specCap)
                if a < 0.02 { continue }
                let x = swX[i], y = swY[i]
                // rim runs along the lit edge (perpendicular to the light dir),
                // offset toward the light so the highlight sits on the lit corner.
                let px = -ly, py = lx
                let len = chipR * (0.85 + 0.5 * spec)
                let ex = x + lx * chipR * 0.55
                let ey = y + ly * chipR * 0.55
                let white = 0.55 + 0.45 * spec
                let col = frame.dots[i].rgba.toWhite(white).withOpacity(a)
                var p = Path()
                p.move(to: CGPoint(x: ex - px * len, y: ey - py * len))
                p.addLine(to: CGPoint(x: ex + px * len, y: ey + py * len))
                specCtx.stroke(p, with: .color(col.color),
                               style: StrokeStyle(lineWidth: lineW, lineCap: .round))
            }
        }

        return true
    }
}

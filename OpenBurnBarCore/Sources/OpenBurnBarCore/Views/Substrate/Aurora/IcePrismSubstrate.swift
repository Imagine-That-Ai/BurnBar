import SwiftUI

/// Polar Ice Prism — faithful port of imaginethat `aurora/ice-prism.ts` drawBody (L170-331).
///
/// Each silhouette point becomes one oversized, irregular 4-vertex shard of
/// glacial ice — the facets overlap into a single continuous, hard-edged mass
/// (the only SOLID, cut-gemstone member of the aurora family). A shared aurora
/// LIGHT VECTOR orbits ~12s (`lightAng = t*(TAU/12) + 0.5*sin(t*0.21+1.3)`); each
/// facet's `glint` is the alignment of its fixed surface-normal angle with that
/// vector, so a teal→violet glint BAND migrates diagonally across the whole logo.
/// Per facet, in z-order (painter-sorted back→front by screen y):
///   • (dark only, additive) a faint cached icy backlit-bloom under high-glint
///     facets for translucency — dropped when battery-throttled;
///   • the relit facet fill (SOURCE-OVER on BOTH stages — ice is solid): the
///     point's own color brightened toward icy-white on the lit side and pulled
///     toward polar BACK_BLUE on the shadow side, alpha `(dark?0.9:0.96)*f`;
///   • a white specular WEDGE on the lit corner when `glint>0.62` (additive on
///     dark / source-over on light);
///   • a thin cold frost RIM stroking the facet contour (dropped under throttle).
/// Micro-rotation `±~3°` per facet (`0.052*sin(t*0.4+fphase)`) lets edges catch &
/// release. `reduced` → frozen light (lt=0.7, warp=0, rot=0): a poised still ice
/// mass with one frozen diagonal glint band. Per-facet vertex offsets, normals
/// and phases are precomputed once per count; the depth order is reused. Exact
/// alpha/relight constants ARE the look.
public final class IcePrismSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // verts per facet (irregular quad reads as cut ice without polygon churn).
    private static let VERTS = 4
    // cool frost-rim color (deterministic, theme-agnostic edge).
    private static let rimCold = RGBA(r: 176.0 / 255, g: 226.0 / 255, b: 240.0 / 255)
    // translucent polar blue a back-facing facet dims toward.
    private static let backBlue = (r: 70.0 / 255, g: 120.0 / 255, b: 168.0 / 255)
    // icy-white the lit side brightens toward.
    private static let iceWhite = (r: 235.0 / 255, g: 245.0 / 255, b: 255.0 / 255)

    // prismatic frost-rim tints — cool cyan on the lit edge, violet in the
    // shadow, so each facet edge disperses light like real glacier ice.
    private static let prismCyan = RGBA(r: 150.0 / 255, g: 232.0 / 255, b: 255.0 / 255)
    private static let prismViolet = RGBA(r: 176.0 / 255, g: 158.0 / 255, b: 255.0 / 255)
    // coverage scale — shards overlap a touch more into one continuous ice mass.
    private static let coverScale = 1.16

    // precomputed per-facet geometry (built once per count).
    private var n = -1
    private var vcos: [Double] = []   // unit vertex dir x, [i*VERTS + v]
    private var vsin: [Double] = []   // unit vertex dir y
    private var vrad: [Double] = []   // vertex radius (× facet size)
    private var fsize: [Double] = []  // per-facet base radius (×sizePx)
    private var fnorm: [Double] = []  // facet "surface normal" angle (glint)
    private var fphase: [Double] = [] // micro-rotation phase
    private var order: [Int] = []     // painter's-sort order (back→front)
    // per-frame scratch (reused; sized to count) so passes share one glint solve.
    private var glintS: [Double] = [] // 0…1 light alignment per facet
    private var litS: [Double] = []   // glint² (biased to the lit band)

    /// Deterministic facet geometry sized for the current point count.
    private func buildGeometry(_ count: Int) {
        let vertexCount = Self.VERTS
        n = count
        vcos = [Double](repeating: 0, count: count * vertexCount)
        vsin = [Double](repeating: 0, count: count * vertexCount)
        vrad = [Double](repeating: 0, count: count * vertexCount)
        fsize = [Double](repeating: 0, count: count)
        fnorm = [Double](repeating: 0, count: count)
        fphase = [Double](repeating: 0, count: count)
        order = Array(0..<count)
        for i in 0..<count {
            let fi = Double(i)
            let s0 = shash(fi * 2.17 + 0.31)
            let s1 = shash(fi * 3.91 + 1.77)
            let base = s0 * TAU
            for v in 0..<vertexCount {
                // jittered angular slot → irregular (non-regular) polygon.
                let jit = (shash(fi * 7.3 + Double(v) * 11.9 + 4.1) - 0.5) * 0.7
                let a = base + (Double(v) / Double(vertexCount)) * TAU + jit
                let r = 0.78 + shash(fi * 5.5 + Double(v) * 2.3 + 0.9) * 0.46 // 0.78…1.24
                let k = i * vertexCount + v
                vcos[k] = cos(a)
                vsin[k] = sin(a)
                vrad[k] = r
            }
            // facet radius oversized vs. spacing so shards overlap into a mass.
            fsize[i] = 2.0 + s1 * 1.3
            fnorm[i] = s0 * TAU       // pretend surface tilt → glint selectivity
            fphase[i] = s1 * TAU
        }
        glintS = [Double](repeating: 0, count: count)
        litS = [Double](repeating: 0, count: count)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }
        if n != count { buildGeometry(count) }

        let vertexCount = Self.VERTS
        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let f = clampD(frame.settleProgress, 0, 1) * 0.7 + 0.3 // assembly fade-in

        // Painter's depth sort back→front by screen y (lower facets in front).
        // Subtle stacking cue under near-opaque fills — skip the sort under load.
        if !lite {
            order.sort { frame.dots[$0].y < frame.dots[$1].y }
        }

        // shared aurora light vector: a slow domain-warped orbit (~12s primary).
        let lt = reduced ? 0.7 : t * (TAU / 12)
        let warp = reduced ? 0 : 0.5 * sin(t * 0.21 + 1.3)
        let lightAng = lt + warp
        let lcos = cos(lightAng)
        let lsin = sin(lightAng)

        // prismatic glow tints pulled from the live aurora theme (teal → violet).
        let glowCyan = frame.stage.accent
        let glowViolet = frame.stage.accent2

        // ── solve every facet's glint once; the rest of the passes share it.
        for i in 0..<count {
            let fn = fnorm[i]
            let g = 0.5 + 0.5 * (cos(fn) * lcos + sin(fn) * lsin)  // 0…1 band
            glintS[i] = g
            litS[i] = g * g
        }

        // ─────────────────────────────────────────────────────────────────────
        // PASS A — PRESENCE UNDERGLOW (dark only): a cached icy halo under every
        // facet, additive, so the whole silhouette reads as ONE continuous,
        // luminous ice mass (never confetti, never near-empty). Brighter along
        // the lit band, still present in the shadow so no facet floats alone.
        if dark {
            let icy = sprites.radial(diameter: 64, stops: [
                (0.0, RGBA(r: 224.0 / 255, g: 246.0 / 255, b: 255.0 / 255, a: 0.95)),
                (0.32, RGBA(r: 158.0 / 255, g: 214.0 / 255, b: 245.0 / 255, a: 0.40)),
                (1.0, RGBA(r: 120.0 / 255, g: 178.0 / 255, b: 232.0 / 255, a: 0.0))
            ])
            var glowCtx = baseCtx
            glowCtx.blendMode = .plusLighter
            let glow = glowCtx.resolve(icy)
            for i in order {
                let r = sizePx * fsize[i] * Self.coverScale * 1.55
                var g = glowCtx
                g.opacity = clampD((0.09 + 0.20 * litS[i]) * f, 0, 0.5)
                let d = frame.dots[i]
                g.draw(glow, in: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2))
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // PASS B — TRUE GAUSSIAN BLOOM (dark, not throttled): the headline lever.
        // Bright per-facet cores for the lit band are drawn into ONE blurred,
        // additive layer → an Apple-grade luminous glint band that drifts across
        // the logo. Cores keep the point's own hue so the bloom is coloured, not
        // white mush. Dropped under battery throttle (the single heaviest pass).
        if dark && !lite {
            let bloomR = max(2.0, sizePx * 2.3)
            let bloomCtx = baseCtx
            bloomCtx.drawLayer { layer in
                layer.addFilter(.blur(radius: bloomR))
                layer.blendMode = .plusLighter
                for i in order {
                    let lit = litS[i]
                    if lit < 0.20 { continue }   // only the band blooms
                    let d = frame.dots[i]
                    let sz = sizePx * fsize[i] * Self.coverScale
                    // hot tinted core: the dot's colour pushed hard toward white.
                    let core = d.rgba.toWhite(0.40 + 0.50 * lit)
                    let a = clampD((0.22 + 0.55 * lit) * f, 0, 0.95)
                    let cr = sz * 0.62
                    layer.fill(
                        Path(ellipseIn: CGRect(x: d.x - cr, y: d.y - cr, width: cr * 2, height: cr * 2)),
                        with: .color(core.withOpacity(a).color))
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // PASS C — the faceted ice shards + their cut-gem depth and refractive
        // glints. Bodies are SOLID (source-over both stages); specular and spark
        // are additive on dark / source-over on light.
        var fillCtx = baseCtx
        fillCtx.blendMode = .normal
        var specCtx = baseCtx
        specCtx.blendMode = dark ? .plusLighter : .normal
        let specCap = dark ? 0.95 : 0.72
        let bodyAlpha = clampD((dark ? 0.92 : 0.97) * f, 0, 1)

        for i in order {
            let d = frame.dots[i]
            let x = d.x, y = d.y

            // micro-rotation: ±~3° on a long per-facet sine.
            let rot = reduced ? 0 : 0.052 * sin(t * 0.4 + fphase[i])
            let rc2 = cos(rot), rs = sin(rot)
            let sz = sizePx * fsize[i] * Self.coverScale

            let glint = glintS[i]
            let facing = glint
            let lit = litS[i]
            let back = 1 - facing

            // relight: brighten toward icy-white on the lit side …
            let base = d.rgba
            var rr = base.r + (Self.iceWhite.r - base.r) * (0.20 + 0.64 * lit)
            var gg = base.g + (Self.iceWhite.g - base.g) * (0.20 + 0.64 * lit)
            var bb = base.b + (Self.iceWhite.b - base.b) * (0.18 + 0.55 * lit)
            // … sink dark-facing facets toward translucent polar blue (depth).
            rr += (Self.backBlue.r - rr) * back * 0.42
            gg += (Self.backBlue.g - gg) * back * 0.42
            bb += (Self.backBlue.b - bb) * back * 0.42

            let fill = RGBA(r: clampD(rr, 0, 1), g: clampD(gg, 0, 1), b: clampD(bb, 0, 1), a: bodyAlpha)

            // build the irregular facet polygon (verts rotated by hand).
            let o = i * vertexCount
            var poly = Path()
            for v in 0..<vertexCount {
                let k = o + v
                let vr = vrad[k] * sz
                let lx = vcos[k] * vr, ly = vsin[k] * vr
                let px = x + lx * rc2 - ly * rs
                let py = y + lx * rs + ly * rc2
                if v == 0 { poly.move(to: CGPoint(x: px, y: py)) } else { poly.addLine(to: CGPoint(x: px, y: py)) }
            }
            poly.closeSubpath()
            fillCtx.fill(poly, with: .color(fill.color))

            // lit corner = the vertex most aligned with the light direction;
            // opposite corner = the shadowed side (for cut-gem two-tone depth).
            var bestV = 0, bestD = -2.0
            for v in 0..<vertexCount {
                let k = o + v
                let dd = vcos[k] * lcos + vsin[k] * lsin
                if dd > bestD { bestD = dd; bestV = v }
            }
            @inline(__always) func corner(_ kk: Int, _ scale: Double) -> CGPoint {
                let vr = vrad[kk] * sz * scale
                let lx = vcos[kk] * vr, ly = vsin[kk] * vr
                return CGPoint(x: x + lx * rc2 - ly * rs, y: y + lx * rs + ly * rc2)
            }

            // SHADOW WEDGE — a darker triangle on the unlit corner so each facet
            // reads as a cut crystal with a shaded internal plane, not a flat
            // chip. Source-over, subtle; skipped under throttle.
            if !lite && back > 0.30 {
                let shV = (bestV + 2) % vertexCount
                let s0 = corner(o + shV, 1)
                let s1 = corner(o + ((shV + vertexCount - 1) % vertexCount), 0.50)
                let s2 = corner(o + ((shV + 1) % vertexCount), 0.50)
                var shade = Path()
                shade.move(to: s0); shade.addLine(to: s1)
                shade.addLine(to: CGPoint(x: x, y: y)); shade.addLine(to: s2)
                shade.closeSubpath()
                let shA = clampD((0.16 + 0.20 * (back - 0.30)) * f, 0, 0.4)
                let shadeColor = RGBA(r: Self.backBlue.r, g: Self.backBlue.g, b: Self.backBlue.b, a: shA)
                fillCtx.fill(shade, with: .color(shadeColor.color))
            }

            // SPECULAR WEDGE — the hot refractive catch on the lit corner. More
            // facets sparkle than before and they burn brighter on dark.
            let spec = clampD((glint - 0.50) / 0.50, 0, 1)
            if spec > 0.02 {
                let c0 = corner(o + bestV, 1)
                let c1 = corner(o + ((bestV + vertexCount - 1) % vertexCount), 0.46)
                let c2 = corner(o + ((bestV + 1) % vertexCount), 0.46)
                var wedge = Path()
                wedge.move(to: c0); wedge.addLine(to: c1)
                wedge.addLine(to: CGPoint(x: x, y: y)); wedge.addLine(to: c2)
                wedge.closeSubpath()
                let sa = clampD((dark ? 0.58 : 0.40) * spec * f, 0, specCap)
                specCtx.fill(wedge, with: .color(.white.opacity(sa)))

                // BRIGHT REFRACTIVE GLINT — a tiny hot spark on the lit vertex,
                // flanked by a cyan + violet micro-glint so the brightest facets
                // disperse light like a real prism. Additive on dark only.
                if dark && spec > 0.40 {
                    let sparkA = clampD((spec - 0.40) / 0.60 * f, 0, 1)
                    let pr = max(0.6, sz * 0.16)
                    specCtx.fill(Path(ellipseIn: CGRect(x: c0.x - pr, y: c0.y - pr, width: pr * 2, height: pr * 2)),
                                 with: .color(.white.opacity(0.85 * sparkA)))
                    if !lite {
                        let off = sz * 0.22
                        let cp = CGPoint(x: c0.x - off, y: c0.y)
                        let vp = CGPoint(x: c0.x + off, y: c0.y)
                        let dr = pr * 0.8
                        specCtx.fill(Path(ellipseIn: CGRect(x: cp.x - dr, y: cp.y - dr, width: dr * 2, height: dr * 2)),
                                     with: .color(glowCyan.withOpacity(0.55 * sparkA).color))
                        specCtx.fill(Path(ellipseIn: CGRect(x: vp.x - dr, y: vp.y - dr, width: dr * 2, height: dr * 2)),
                                     with: .color(glowViolet.withOpacity(0.55 * sparkA).color))
                    }
                }
            }

            // PRISMATIC FROST RIM — redraws the contour, dispersed cyan on the
            // lit edge and violet in the shadow. An extra pass, gated under throttle.
            if !lite {
                var rim = Self.rimCold
                rim = rim.mix(with: Self.prismCyan, amount: 0.55 * lit)
                rim = rim.mix(with: Self.prismViolet, amount: 0.45 * back)
                let rimA = clampD((dark ? 0.34 : 0.42) + 0.46 * lit, 0, 0.96) * f
                fillCtx.stroke(poly, with: .color(rim.withOpacity(rimA).color),
                               style: StrokeStyle(lineWidth: dark ? 1.0 : 1.1, lineCap: .round, lineJoin: .round))
            }
        }

        return true
    }
}

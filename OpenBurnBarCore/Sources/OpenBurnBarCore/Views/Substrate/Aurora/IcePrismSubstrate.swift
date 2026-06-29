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

    // precomputed per-facet geometry (built once per count).
    private var n = -1
    private var vcos: [Double] = []   // unit vertex dir x, [i*VERTS + v]
    private var vsin: [Double] = []   // unit vertex dir y
    private var vrad: [Double] = []   // vertex radius (× facet size)
    private var fsize: [Double] = []  // per-facet base radius (×sizePx)
    private var fnorm: [Double] = []  // facet "surface normal" angle (glint)
    private var fphase: [Double] = [] // micro-rotation phase
    private var order: [Int] = []     // painter's-sort order (back→front)

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

        // ── pass A (dark, not throttled): faint additive icy backlit bloom.
        if dark && !lite {
            let icy = sprites.radial(diameter: 48, stops: [
                (0.0, RGBA(r: 214.0 / 255, g: 244.0 / 255, b: 255.0 / 255, a: 0.9)),
                (0.4, RGBA(r: 150.0 / 255, g: 210.0 / 255, b: 240.0 / 255, a: 0.3)),
                (1.0, RGBA(r: 120.0 / 255, g: 180.0 / 255, b: 230.0 / 255, a: 0.0))
            ])
            var bloomCtx = baseCtx
            bloomCtx.blendMode = .plusLighter
            let glow = bloomCtx.resolve(icy)
            for i in order {
                let fn = fnorm[i]
                let glint = 0.5 + 0.5 * (cos(fn) * lcos + sin(fn) * lsin)
                let br = glint * glint
                if br < 0.18 { continue }
                let r = sizePx * fsize[i] * 2.1
                var g = bloomCtx
                g.opacity = clampD(0.16 * br * f, 0, 0.4)
                let d = frame.dots[i]
                g.draw(glow, in: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2))
            }
        }

        // ── pass B: the faceted ice shards (solid — source-over on both stages).
        var fillCtx = baseCtx
        fillCtx.blendMode = .normal
        // specular wedge: additive on dark for backlit sparkle, source-over on light.
        var specCtx = baseCtx
        specCtx.blendMode = dark ? .plusLighter : .normal
        let specCap = dark ? 0.85 : 0.7

        for i in order {
            let d = frame.dots[i]
            let x = d.x, y = d.y

            // micro-rotation: ±~3° on a long per-facet sine.
            let rot = reduced ? 0 : 0.052 * sin(t * 0.4 + fphase[i])
            let rc2 = cos(rot), rs = sin(rot)
            let sz = sizePx * fsize[i]

            // facet glint from light alignment (the migrating band).
            let fn = fnorm[i]
            let dotL = cos(fn) * lcos + sin(fn) * lsin // -1…1
            let glint = 0.5 + 0.5 * dotL               // 0…1
            let facing = clampD(glint, 0, 1)
            let lit = facing * facing                  // biased to the lit band

            // relight: brighten toward icy-white on the lit side …
            let base = d.rgba
            var rr = base.r + (Self.iceWhite.r - base.r) * (0.18 + 0.6 * lit)
            var gg = base.g + (Self.iceWhite.g - base.g) * (0.18 + 0.6 * lit)
            var bb = base.b + (Self.iceWhite.b - base.b) * (0.16 + 0.5 * lit)
            // … sink dark-facing facets toward translucent polar blue.
            let back = 1 - facing
            rr += (Self.backBlue.r - rr) * back * 0.45
            gg += (Self.backBlue.g - gg) * back * 0.45
            bb += (Self.backBlue.b - bb) * back * 0.45

            let alpha = clampD((dark ? 0.9 : 0.96) * f, 0, 1)
            let fill = RGBA(r: clampD(rr, 0, 1), g: clampD(gg, 0, 1), b: clampD(bb, 0, 1), a: alpha)

            // build & fill the irregular facet polygon (verts rotated by hand).
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

            // specular wedge: a bright white triangle on the lit corner.
            let spec = clampD((glint - 0.62) / 0.38, 0, 1)
            if spec > 0.02 {
                // lit corner = the vertex most aligned with the light direction.
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
                let c0 = corner(o + bestV, 1)
                let c1 = corner(o + ((bestV + vertexCount - 1) % vertexCount), 0.46)
                let c2 = corner(o + ((bestV + 1) % vertexCount), 0.46)
                var wedge = Path()
                wedge.move(to: c0)
                wedge.addLine(to: c1)
                wedge.addLine(to: CGPoint(x: x, y: y))
                wedge.addLine(to: c2)
                wedge.closeSubpath()
                let sa = clampD(0.42 * spec * f, 0, specCap)
                specCtx.fill(wedge, with: .color(.white.opacity(sa)))
            }

            // frosted cool rim: redraws the contour, brightened on the lit band.
            // An extra pass — gated off when battery-throttled.
            if !lite {
                let rimA = clampD((0.3 + 0.45 * lit) * f, 0, 0.95)
                fillCtx.stroke(poly, with: .color(Self.rimCold.withOpacity(rimA).color),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }

        return true
    }
}

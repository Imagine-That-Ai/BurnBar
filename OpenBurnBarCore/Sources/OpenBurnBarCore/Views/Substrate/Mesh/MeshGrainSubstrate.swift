import SwiftUI

/// Living Grain — faithful port of imaginethat `glyph/stage/styles/mesh/mesh-grain.ts` drawBody.
///
/// The brand mark rendered as a drifting cloud of iridescent micro-grain: a
/// PER-GRAIN particle system (≤ `GRAIN_BUDGET` motes, ~1.6 per silhouette point)
/// that perpetually CONDENSES onto the mark and sheds back out. Each grain owns a
/// HOME (a silhouette point → inherits that point's resolved brand color) and a
/// persistent DRIFT offset integrated every frame: a spring toward home scaled by
/// a global COHESION that breathes 0.35→1.0 at ~0.12 Hz, an analytic divergence-
/// free curl "breeze" that advects loose grain, a tiny perpetual orbit, drag, plus
/// a non-accumulating sub-pixel film-grain jitter refreshed at ~24 Hz. Settled
/// grains keep their bright brand hue (the dense stipple = the shape); grains that
/// wander lerp by far² toward a cool iris jewel tint and dim.
///
/// DARK canvas → additive `.plusLighter`: a cached soft white mote bloom sprite +
/// a small colored body + a whitened lifted core on settled grain. LIGHT canvas →
/// `.normal` cool ink motes (colored body + faint settled halo), never blown out.
/// `reduced` → cohesion fixed 0.92, no integration/jitter, static brightness — a
/// poised settled stipple. `batteryThrottled` → drops the white bloom sprite pass.
/// Persistent grain arrays are seeded ONCE per point-count; nothing allocates in
/// the hot loop. Destruction inputs (dissolve/melt/armed) are absent here, so the
/// held look defaults them to 0 with all homes alive.
public final class MeshGrainSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // Tuning constants (verbatim from the source).
    private static let grainsPerPoint = 1.6
    private static let grainBudget = 520
    private static let cohesionFloor = 0.35

    // Persistent grain state — seeded ONCE (lazily), sized to the live point count.
    private var n = 0
    private var home: [Int] = []
    private var dx: [Double] = []
    private var dy: [Double] = []
    private var dvx: [Double] = []
    private var dvy: [Double] = []
    private var gseed: [Double] = []
    private var builtFor = -1

    /// Analytic divergence-free curl of a sum-of-sines stream function — the dust
    /// "breeze" that advects loose grain. Allocation-free, deterministic.
    @inline(__always) private func curlX(_ x: Double, _ y: Double, _ t: Double) -> Double {
        cos(x * 0.013 + t * 0.20) * cos(y * 0.017 - t * 0.15) * 0.9 + cos(y * 0.029 + t * 0.27) * 0.5
    }
    @inline(__always) private func curlY(_ x: Double, _ y: Double, _ t: Double) -> Double {
        sin(x * 0.013 + t * 0.20) * sin(y * 0.017 - t * 0.15) * 0.9 + sin(x * 0.023 - t * 0.24) * 0.5
    }

    /// Cool jewel sweep (violet→teal→rose) in 0…1 channels — tints wandering dust.
    @inline(__always) private func iris(_ phase: Double) -> (Double, Double, Double) {
        ((150 + 95 * sin(phase)) / 255,
         (150 + 95 * sin(phase + 2.2)) / 255,
         (170 + 85 * sin(phase + 4.3)) / 255)
    }

    /// (Re)seed the persistent grain arrays for `count` silhouette points (once).
    private func ensureGrains(_ count: Int) {
        if builtFor == count && !home.isEmpty { return }
        let want = min(Self.grainBudget, max(1, Int((Double(count) * Self.grainsPerPoint).rounded())))
        n = want
        home = [Int](repeating: 0, count: want)
        dvx = [Double](repeating: 0, count: want)
        dvy = [Double](repeating: 0, count: want)
        dx = [Double](repeating: 0, count: want)
        dy = [Double](repeating: 0, count: want)
        gseed = [Double](repeating: 0, count: want)
        for i in 0..<want {
            // round-robin homes so every point is covered, extras pile on dense regions.
            home[i] = i % count
            let s = shash(Double(i) * 1.713 + 0.31)
            gseed[i] = s
            // start in a loose haze so the first frames visibly condense.
            let a = s * TAU
            let r = 6 + s * 22
            dx[i] = cos(a) * r
            dy[i] = sin(a) * r
        }
        builtFor = count
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        ensureGrains(count)

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let t = frame.t
        let radius = frame.cloudRadius
        let sizePx = frame.sizePx

        // assembly fade-in: grain kindles as the mark forms (fade = 1, no dissolve).
        let form = reduced ? 1.0 : (clampD(frame.settleProgress, 0, 1) * 0.45 + 0.55)

        // ── global cohesion: breathes 0.35→1.0 at ~0.12Hz, floor-clamped so the
        //    mark holds. (No bespoke gust/click kicks in the held substrate look.)
        let cohesion: Double
        if reduced {
            cohesion = 0.92 // a poised, settled stipple
        } else {
            let breath = 0.5 + 0.5 * sin(t * (0.12 * TAU))
            let c = Self.cohesionFloor + (1 - Self.cohesionFloor) * (0.55 + 0.45 * breath)
            cohesion = clampD(c, Self.cohesionFloor * 0.6, 1.15)
        }

        // spring + drag tuned by cohesion; loose grain feels more curl swirl.
        let dtf = reduced ? 0 : clampD(frame.dt, 0, 3)
        let spring = (0.05 + 0.22 * cohesion) * dtf
        let drag = pow(0.86, dtf)
        let curlGain = (1 - cohesion) * 1.6
        let looseR = radius * (0.10 + 0.42 * (1 - cohesion))
        let irisPhase = t * (TAU / 14)
        let jf = floor(t * 24) // ~24Hz grain refresh

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Resolve the additive soft white mote ONCE per frame, draw it many times.
        // Skip on light canvas and when battery-throttled.
        let mote: GraphicsContext.ResolvedImage? = (dark && !lite)
            ? ctx.resolve(sprites.radial(diameter: 32, stops: [
                (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.85)),
                (0.28, RGBA(r: 1, g: 1, b: 1, a: 0.42)),
                (0.6, RGBA(r: 1, g: 1, b: 1, a: 0.12)),
                (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
              ]))
            : nil

        for i in 0..<n {
            let hi = home[i]
            let d = frame.dots[hi]
            let hx = d.x
            let hy = d.y
            let seed = gseed[i]
            let phase = seed * TAU

            var ox = dx[i]
            var oy = dy[i]

            if !reduced && dtf > 0 {
                var vx = dvx[i] + (-ox * spring)
                var vy = dvy[i] + (-oy * spring)

                // curl breeze (scaled by looseness so settled grain barely moves).
                if curlGain > 0.001 {
                    vx += curlX(hx + ox, hy + oy, t) * curlGain * dtf
                    vy += curlY(hx + ox, hy + oy, t) * curlGain * dtf
                }

                // tiny perpetual orbit so even tight grain is never perfectly still.
                let wob = t * (0.9 + seed * 0.7) + phase
                vx += cos(wob) * 0.10 * dtf
                vy += sin(wob * 1.07 + 0.6) * 0.10 * dtf

                vx *= drag
                vy *= drag
                ox += vx * dtf
                oy += vy * dtf

                dvx[i] = vx
                dvy[i] = vy
                dx[i] = ox
                dy[i] = oy
            }

            // sub-pixel film-grain jitter (non-accumulating; keeps silhouette anchored).
            var jx = 0.0, jy = 0.0
            if !reduced {
                jx = (shash(Double(i) * 2.13 + jf) - 0.5) * 0.9
                jy = (shash(Double(i) * 3.71 + jf * 1.7) - 0.5) * 0.9
            }

            let x = hx + ox + jx
            let y = hy + oy + jy

            // distance-from-home → 0 settled .. 1 far in the haze.
            let dist = (ox * ox + oy * oy).squareRoot()
            let far = clampD(dist / (looseR + 1), 0, 1)

            // brand color settled; iris tint when wandering (eased so most show brand).
            let brand = d.rgba
            let tint = iris(irisPhase + phase * 0.3 + far * 1.4)
            let mixT = far * far
            let cr = brand.r + (tint.0 - brand.r) * mixT
            let cg = brand.g + (tint.1 - brand.g) * mixT
            let cb = brand.b + (tint.2 - brand.b) * mixT

            // brightness: settled bright, far dim; own breathe phase keeps it shimmering.
            let br = reduced ? 0.5 + 0.5 * sin(phase * 11) : 0.5 + 0.5 * sin(t * 1.7 + phase)
            let k = clampD((0.5 + 0.5 * br) * (1 - 0.62 * far) * form, 0, 1.6)

            // honor the engine's per-dot opacity (folded into the resolved alpha).
            let oa = brand.a
            let grainSz = sizePx * (0.7 + 0.5 * seed) * (1 - 0.25 * far)

            if dark {
                // soft additive white mote bloom (cached sprite).
                if let mote {
                    let r = grainSz * (2.0 + 0.8 * (1 - far))
                    var g = ctx
                    g.opacity = clampD(0.16 * k, 0, 0.5) * oa
                    g.draw(mote, in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
                // colored grain body — small, keeps the stipple read.
                let bodyR = max(0.5, grainSz * 0.8)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR, width: bodyR * 2, height: bodyR * 2)),
                         with: .color(Color(red: cr, green: cg, blue: cb).opacity(clampD(0.5 * k, 0, 0.8) * oa)))
                // a tiny lifted (whitened) core on settled grain so the silhouette reads crisp.
                if far < 0.35 {
                    let coreR = max(0.4, grainSz * 0.42)
                    let wr = cr + (1 - cr) * 0.5, wg = cg + (1 - cg) * 0.5, wb = cb + (1 - cb) * 0.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                             with: .color(Color(red: wr, green: wg, blue: wb)
                                .opacity(clampD(0.55 * k * (1 - far / 0.35), 0, 0.9) * oa)))
                }
            } else {
                // LIGHT canvas: cool ink motes, source-over, never blown out.
                let bodyR = max(0.5, grainSz * 0.92)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR, width: bodyR * 2, height: bodyR * 2)),
                         with: .color(Color(red: cr, green: cg, blue: cb)
                            .opacity(clampD((0.32 + 0.5 * (1 - far)) * k, 0, 0.92) * oa)))
                // a soft halo only on settled grain so the dense core feathers gently.
                if far < 0.4 {
                    let haloR = grainSz * 1.8
                    ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR, width: haloR * 2, height: haloR * 2)),
                             with: .color(Color(red: cr, green: cg, blue: cb)
                                .opacity(clampD(0.1 * k * (1 - far / 0.4), 0, 0.18) * oa)))
                }
            }
        }

        return true
    }
}

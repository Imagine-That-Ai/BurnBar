#if canImport(SwiftUI)
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
/// DARK canvas → additive `.plusLighter`, four layered passes for real depth and
/// PRESENCE: a WIDE Gaussian bloom BED (`.blur` + `.plusLighter`, broad radius)
/// whose ~880 overlapping discs fuse into one continuous luminous iridescent wash
/// that lifts the whole silhouette off the black, a tighter per-mote bloom halo on
/// top, then saturated brand-hued bodies, then hot whitened cores. The field glows
/// rather than whispers — density, sizes and alphas are pushed for real presence.
/// LIGHT canvas →
/// `.normal`: a soft blurred colored haze under + crisp cool ink motes with a deep
/// micro-core, never blown out. `reduced` → cohesion fixed 0.92, no integration/
/// jitter, static brightness — a poised, still settled stipple (bloom still drawn).
/// `batteryThrottled` → drops only the heaviest extra pass (the blur layer); the
/// crisp luminous motes still carry full presence.
/// Persistent grain arrays are seeded ONCE per point-count; nothing allocates in
/// the hot loop. Destruction inputs (dissolve/melt/armed) are absent here, so the
/// held look defaults them to 0 with all homes alive.
public final class MeshGrainSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // Tuning constants. Density raised over the web source so the mote-cloud
    // clearly FILLS its silhouette (the web port read too sparse/dim): more
    // grains per point and a higher budget pack the field for real presence.
    private static let grainsPerPoint = 2.6
    private static let grainBudget = 880
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

    // Reusable per-grain draw scratch (computed in the integration pass, consumed
    // by the bloom + crisp passes). Allocated ONCE per point-count alongside the
    // grain state, so the multi-pass render never allocates in the hot loop.
    private var px: [Double] = []   // final screen x
    private var py: [Double] = []   // final screen y
    private var pk: [Double] = []   // brightness 0…1.6
    private var pfar: [Double] = [] // distance-from-home 0…1
    private var psz: [Double] = []  // grain size px
    private var pcr: [Double] = []  // iridescent body color r
    private var pcg: [Double] = []  // g
    private var pcb: [Double] = []  // b
    private var poa: [Double] = []  // engine per-dot opacity

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
        px = [Double](repeating: 0, count: want)
        py = [Double](repeating: 0, count: want)
        pk = [Double](repeating: 0, count: want)
        pfar = [Double](repeating: 0, count: want)
        psz = [Double](repeating: 0, count: want)
        pcr = [Double](repeating: 0, count: want)
        pcg = [Double](repeating: 0, count: want)
        pcb = [Double](repeating: 0, count: want)
        poa = [Double](repeating: 0, count: want)
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

        // Accent / iris tint for the bloom haze: settled grain blooms in its brand
        // hue, wandering grain shifts toward the cool jewel accent — the field reads
        // iridescent, never grey.
        let accent = frame.stage.accent

        // ── PASS 1 — integrate the particle system & bake per-grain draw state into
        //    the reusable scratch arrays. No drawing here, no allocation.
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

            // distance-from-home → 0 settled .. 1 far in the haze.
            let dist = (ox * ox + oy * oy).squareRoot()
            let far = clampD(dist / (looseR + 1), 0, 1)

            // brand color settled; iris tint when wandering (eased so most show brand).
            let brand = d.rgba
            let tint = iris(irisPhase + phase * 0.3 + far * 1.4)
            let mixT = far * far
            // pull the wandering hue toward the stage accent so the haze is a cohesive
            // iridescent jewel sweep rather than scattered confetti.
            let jr = tint.0 + (accent.r - tint.0) * 0.30
            let jg = tint.1 + (accent.g - tint.1) * 0.30
            let jb = tint.2 + (accent.b - tint.2) * 0.30
            let cr = brand.r + (jr - brand.r) * mixT
            let cg = brand.g + (jg - brand.g) * mixT
            let cb = brand.b + (jb - brand.b) * mixT

            // brightness: settled bright, far dim; own breathe phase keeps it
            // shimmering. Lifted floor (0.72 base) + gentler far falloff so the
            // whole field reads luminous instead of whispering — it should glow.
            let br = reduced ? 0.5 + 0.5 * sin(phase * 11) : 0.5 + 0.5 * sin(t * 1.7 + phase)
            let k = clampD((0.72 + 0.5 * br) * (1 - 0.34 * far) * form, 0, 1.8)

            px[i] = hx + ox + jx
            py[i] = hy + oy + jy
            pk[i] = k
            pfar[i] = far
            // larger motes so the dense cloud reads with body, not pinpricks.
            psz[i] = sizePx * (1.05 + 0.6 * seed) * (1 - 0.18 * far)
            pcr[i] = cr
            pcg[i] = cg
            pcb[i] = cb
            poa[i] = brand.a
        }

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        if dark {
            // ── PASS 2a (dark) — WIDE BLOOM BED. A heavily-blurred, broad-radius
            //    additive wash whose overlapping discs fuse into one continuous
            //    iridescent glow that fills the WHOLE silhouette and lifts it off
            //    the black — the additive bed that makes the field read instantly.
            //    This is the single heaviest pass, so it (and only it) is dropped
            //    under battery throttling; the tighter bloom below keeps the glow.
            if !lite {
                let bedR = max(8.0, sizePx * 6.5)
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: bedR))
                    layer.blendMode = .plusLighter
                    for i in 0..<n {
                        let k = pk[i]
                        if k <= 0.02 { continue }
                        let sz = psz[i]
                        let r = sz * 4.4
                        // bed hue: grain color lifted toward white so the wash reads
                        // as light. Broad + low-alpha → a smooth luminous floor.
                        let gr = pcr[i] + (1 - pcr[i]) * 0.34
                        let gg = pcg[i] + (1 - pcg[i]) * 0.34
                        let gb = pcb[i] + (1 - pcb[i]) * 0.34
                        let a = clampD(0.16 * k, 0, 0.4) * poa[i]
                        layer.fill(
                            Path(ellipseIn: CGRect(x: px[i] - r, y: py[i] - r, width: r * 2, height: r * 2)),
                            with: .color(Color(red: gr, green: gg, blue: gb).opacity(a)))
                    }
                }
            }

            // ── PASS 2b (dark) — TIGHTER GRAIN BLOOM. The per-mote glow that gives
            //    each grain its own halo on top of the bed. Kept even under battery
            //    throttle so the field still glows.
            do {
                let bloomR = max(3.0, sizePx * 2.6)
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: bloomR))
                    layer.blendMode = .plusLighter
                    for i in 0..<n {
                        let k = pk[i]
                        if k <= 0.02 { continue }
                        let far = pfar[i]
                        let sz = psz[i]
                        // wide soft glow radius — bigger for settled grain so the
                        // core anchors brightest, looser dust feathers out.
                        let r = sz * (2.9 + 1.5 * (1 - far))
                        // bloom hue: the grain color lifted toward white so it reads
                        // as light, not paint. Settled grain glows hotter.
                        let lift = 0.34 + 0.32 * (1 - far)
                        let gr = pcr[i] + (1 - pcr[i]) * lift
                        let gg = pcg[i] + (1 - pcg[i]) * lift
                        let gb = pcb[i] + (1 - pcb[i]) * lift
                        let a = clampD(0.5 * k, 0, 0.95) * poa[i]
                        layer.fill(
                            Path(ellipseIn: CGRect(x: px[i] - r, y: py[i] - r, width: r * 2, height: r * 2)),
                            with: .color(Color(red: gr, green: gg, blue: gb).opacity(a)))
                    }
                }
            }

            // ── PASS 3 (dark) — crisp saturated bodies + hot whitened cores ON TOP of
            //    the bloom, so each grain reads as a real lit mote with depth:
            //    soft glow under → saturated body → hot core.
            for i in 0..<n {
                let k = pk[i]
                if k <= 0.02 { continue }
                let far = pfar[i]
                let sz = psz[i]
                let oa = poa[i]
                let x = px[i], y = py[i]

                // saturated iridescent body — fuller alpha so the stipple has real
                // weight against the bloom bed.
                let bodyR = max(0.6, sz * 1.0)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR, width: bodyR * 2, height: bodyR * 2)),
                         with: .color(Color(red: pcr[i], green: pcg[i], blue: pcb[i])
                            .opacity(clampD(0.82 * k, 0, 1.0) * oa)))

                // hot whitened core on settled grain — keeps the silhouette crisp.
                if far < 0.55 {
                    let coreR = max(0.4, sz * 0.52)
                    let wr = pcr[i] + (1 - pcr[i]) * 0.74
                    let wg = pcg[i] + (1 - pcg[i]) * 0.74
                    let wb = pcb[i] + (1 - pcb[i]) * 0.74
                    ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                             with: .color(Color(red: wr, green: wg, blue: wb)
                                .opacity(clampD(0.92 * k * (1 - far / 0.55), 0, 1.0) * oa)))
                }
            }
        } else {
            // ── PASS 2 (light) — soft colored HAZE: a blurred under-layer (normal
            //    blend, never blown out) gives the dense core depth and atmosphere.
            //    Dropped first under battery throttling.
            if !lite {
                let hazeR = max(3.0, sizePx * 2.0)
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: hazeR))
                    layer.opacity = 0.55
                    for i in 0..<n {
                        let k = pk[i]
                        if k <= 0.02 { continue }
                        let far = pfar[i]
                        let r = psz[i] * (1.8 + 0.9 * (1 - far))
                        let a = clampD(0.22 * k * (1 - 0.4 * far), 0, 0.4) * poa[i]
                        layer.fill(
                            Path(ellipseIn: CGRect(x: px[i] - r, y: py[i] - r, width: r * 2, height: r * 2)),
                            with: .color(Color(red: pcr[i], green: pcg[i], blue: pcb[i]).opacity(a)))
                    }
                }
            }

            // ── PASS 3 (light) — crisp cool ink motes on top, saturated + readable.
            for i in 0..<n {
                let k = pk[i]
                if k <= 0.02 { continue }
                let far = pfar[i]
                let sz = psz[i]
                let oa = poa[i]
                let x = px[i], y = py[i]

                let bodyR = max(0.6, sz * 0.98)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR, width: bodyR * 2, height: bodyR * 2)),
                         with: .color(Color(red: pcr[i], green: pcg[i], blue: pcb[i])
                            .opacity(clampD((0.42 + 0.5 * (1 - far)) * k, 0, 0.95) * oa)))

                // a deep saturated micro-core on settled grain so the stipple bites.
                if far < 0.45 {
                    let coreR = max(0.4, sz * 0.46)
                    let dr = pcr[i] * 0.7, dg = pcg[i] * 0.7, db = pcb[i] * 0.7
                    ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                             with: .color(Color(red: dr, green: dg, blue: db)
                                .opacity(clampD(0.4 * k * (1 - far / 0.45), 0, 0.6) * oa)))
                }
            }
        }

        return true
    }
}

#endif

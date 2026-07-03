#if canImport(SwiftUI)
import SwiftUI

/// Drift Motes — faithful port of imaginethat `aurora/drift-motes.ts` drawBody.
///
/// The only aurora member whose grains genuinely MOVE. ~1.6 luminescent motes
/// per silhouette point (cap 900): the first `count` map 1:1 as a bright
/// foreground layer (depth 0.62–0.92), the rest scatter as a dim background haze
/// (depth 0.30–0.64). Each mote orbits its anchor on its own slow Lissajous loop
/// (period 4–9s), clamped well below point spacing so the density map always
/// reproduces the mark, while the whole field rides one shared 2-octave
/// domain-warped ribbon drift with depth-lag parallax. A slow per-mote twinkle
/// modulates brightness.
///
/// DARK (additive `.plusLighter`): per mote (1) a colored disc that tints the
/// bloom beneath it, (2) a cached soft white grain sprite bloom, (3) a whitened
/// hot core (the legible point), (4) for ~5% the brightest a slowly-rotating
/// white diffraction cross (batched, dropped under battery throttle).
/// LIGHT (`.normal`): a soft colored disc + crisp colored core, never blown out.
/// `reduced` freezes the orbit at phase with no drift (a poised still dust
/// field); `batteryThrottled` drops the grain bloom + sparkle passes. Exact
/// alpha/radius constants ARE the look.
public final class DriftMotesSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    // Per-mote geometry, precomputed once per silhouette point count.
    private var builtCount = -1
    private var anchor: [Int] = []
    private var depth: [Double] = []
    private var orad: [Double] = []
    private var ofx: [Double] = []
    private var ofy: [Double] = []
    private var opx: [Double] = []
    private var opy: [Double] = []
    private var twk: [Double] = []
    private var spark: [Bool] = []
    private var msz: [Double] = []

    // Per-frame scratch (reused across frames; resized only when count changes) so
    // the multi-pass paint computes each mote's orbit/drift/twinkle exactly once.
    private var mx: [Double] = []
    private var my: [Double] = []
    private var mb: [Double] = []

    private static let motesPerPoint = 1.6
    private static let maxMotes = 900

    public init() {}

    /// Cheap 2-octave value-noise flow field — smooth domain warp, ~[-2.4, 2.4].
    @inline(__always) private func flow(_ x: Double, _ y: Double, _ t: Double) -> Double {
        let a = sin(x * 0.012 + t * 0.55) + cos(y * 0.016 - t * 0.4)
        let b = sin((x + y) * 0.02 - t * 0.33) * 0.45
        return a + b
    }

    /// Build deterministic per-mote params for the current point count.
    private func buildMotes(_ count: Int) {
        if count == builtCount { return }
        builtCount = count
        let m = count <= 0 ? 0 : min(Self.maxMotes, Int((Double(count) * Self.motesPerPoint).rounded()))
        anchor = [Int](repeating: 0, count: m)
        depth = [Double](repeating: 0, count: m)
        orad = [Double](repeating: 0, count: m)
        ofx = [Double](repeating: 0, count: m)
        ofy = [Double](repeating: 0, count: m)
        opx = [Double](repeating: 0, count: m)
        opy = [Double](repeating: 0, count: m)
        twk = [Double](repeating: 0, count: m)
        spark = [Bool](repeating: false, count: m)
        msz = [Double](repeating: 0, count: m)
        mx = [Double](repeating: 0, count: m)
        my = [Double](repeating: 0, count: m)
        mb = [Double](repeating: 0, count: m)
        guard count > 0 else { return }

        for k in 0..<m {
            let kd = Double(k)
            // first `count` motes map 1:1 (silhouette never gaps); rest scatter.
            let fore = k < count
            anchor[k] = fore ? k : Int(shash(kd * 1.93 + 0.7) * Double(count)) % count

            let s0 = shash(kd * 2.11 + 0.13)
            let s1 = shash(kd * 3.77 + 1.31)
            let s2 = shash(kd * 5.39 + 2.57)
            let s3 = shash(kd * 7.13 + 3.91)

            // depth → atmospheric parallax (foreground bright, background haze).
            depth[k] = fore ? 0.62 + s0 * 0.3 : 0.3 + s0 * 0.34
            // orbit radius (× sizePx), clamped small so motes stay in their cell.
            orad[k] = fore ? 0.7 + s1 * 1.1 : 1.0 + s1 * 1.6
            // Lissajous: independent x/y angular freqs (period 4–9s) + phases.
            ofx[k] = TAU / (4 + s2 * 5)
            ofy[k] = TAU / (4 + s3 * 5)
            opx[k] = s2 * TAU
            opy[k] = s3 * TAU
            twk[k] = s0 * TAU
            spark[k] = s1 > 0.95
            msz[k] = 0.7 + s3 * 0.7
        }
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }
        buildMotes(count)
        let m = anchor.count
        guard m > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let stage = frame.stage
        let cyc = frame.cy
        let RR = max(1.0, frame.cloudRadius)

        // assembly fade-in: the dust ignites as the mark forms.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.45 + 0.55
        // shared ribbon-drift amplitude, frozen under reduced motion.
        let driftAmp = reduced ? 0.0 : clampD(frame.cloudRadius * 0.02, 1.6, 5.0)

        // ── Pass 0: resolve every mote's live orbit + drift + twinkle ONCE ─────
        // (the layered premium passes below each reuse mx/my/mb, no re-trig).
        for k in 0..<m {
            let ai = anchor[k]
            let hx = frame.dots[ai].x
            let hy = frame.dots[ai].y
            let d = depth[k]

            // Lissajous orbit around the anchor (the per-mote shimmer).
            let r = orad[k] * sizePx
            let ox: Double, oy: Double
            if reduced {
                ox = cos(opx[k]) * r
                oy = sin(opy[k]) * r * 0.85
            } else {
                ox = cos(t * ofx[k] + opx[k]) * r
                oy = sin(t * ofy[k] + opy[k]) * r * 0.85
            }

            // Shared domain-warped ribbon drift; deeper motes lag for parallax.
            var dx = 0.0, dy = 0.0
            if !reduced {
                let lag = (1 - d) * 0.9
                let fv = flow(hx, hy, t - lag)
                let par = 0.45 + d * 0.7
                dx = sin(fv + opx[k] * 0.3) * driftAmp * par
                dy = cos(fv * 0.7 + opy[k] * 0.3) * driftAmp * 0.55 * par
            }

            mx[k] = hx + ox + dx
            my[k] = hy + oy + dy
            mb[k] = reduced
                ? 0.6 + 0.4 * (0.5 + 0.5 * sin(twk[k]))
                : 0.62 + 0.38 * (0.5 + 0.5 * sin(t * 1.3 + twk[k]))
        }

        if dark {
            paintDark(frame, into: baseCtx, m: m, sizePx: sizePx, t: t, f: f,
                      reduced: reduced, lite: lite, stage: stage, cyc: cyc, RR: RR)
        } else {
            paintLight(frame, into: baseCtx, m: m, sizePx: sizePx, f: f)
        }
        return true
    }

    // MARK: - Dark: layered luminous spore-motes (glow → body → hot core)

    private func paintDark(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext,
                           m: Int, sizePx: Double, t: Double, f: Double,
                           reduced: Bool, lite: Bool, stage: SubstrateStage,
                           cyc: Double, RR: Double) {
        @inline(__always) func disc(_ x: Double, _ y: Double, _ rr: Double) -> Path {
            Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2))
        }
        // Per-mote aurora glow tint: warm accent low → cool accent2 high, nudged
        // toward each mote's own hue so the bloom field reads as branded aurora.
        @inline(__always) func glowTint(_ ai: Int, _ d: Double) -> RGBA {
            let hy = frame.dots[ai].y
            let vT = clampD((hy - (cyc - RR)) / (2 * RR), 0, 1)        // 0 top … 1 bottom
            let aurora = stage.accent2.mix(with: stage.accent, amount: vT)
            return frame.dots[ai].rgba.mix(with: aurora, amount: 0.34)
        }

        // ── Pass A — TRUE GAUSSIAN under-glow (the premium lever). One blurred,
        //    additive layer: soft colored discs bloom together into a continuous
        //    luminous aurora haze that fills the silhouette. Dropped under battery
        //    throttle (heaviest pass) — the body bloom below still carries it.
        if !lite {
            var glowCtx = baseCtx
            glowCtx.blendMode = .plusLighter
            let blurR = max(3.0, sizePx * 2.6)
            glowCtx.drawLayer { layer in
                layer.addFilter(.blur(radius: blurR))
                layer.blendMode = .plusLighter
                for k in 0..<m {
                    let ai = anchor[k]
                    let d = depth[k]
                    let bright = mb[k]
                    let sz = sizePx * msz[k] * (1.1 + 0.45 * d)
                    let gR = sz * (1.5 + 0.9 * bright)
                    let gA = clampD(0.12 + 0.20 * d * bright, 0, 0.6) * f
                    layer.fill(disc(mx[k], my[k], gR),
                               with: .color(glowTint(ai, d).withOpacity(gA).color))
                }
            }
        }

        // ── Body + core passes (additive). Resolve the soft-grain bloom sprite
        //    once; draw it many. Dropped under throttle; discs + cores keep presence.
        var ctx = baseCtx
        ctx.blendMode = .plusLighter
        let grain: GraphicsContext.ResolvedImage?
        if lite {
            grain = nil
        } else {
            grain = ctx.resolve(sprites.radial(diameter: 48, stops: [
                (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
                (0.22, RGBA(r: 1, g: 1, b: 1, a: 0.62)),
                (0.5, RGBA(r: 1, g: 1, b: 1, a: 0.16)),
                (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
            ]))
        }

        var crossPath = Path()
        var crossK = 0.0
        var crossN = 0

        for k in 0..<m {
            let ai = anchor[k]
            let d = depth[k]
            let bright = mb[k]
            let col = frame.dots[ai].rgba
            let x = mx[k], y = my[k]
            let sz = sizePx * msz[k] * (1.1 + 0.45 * d)

            // (1) saturated colored body disc — the material's hue, tinting the
            //     white grain bloom above it via additive compositing.
            let discA = clampD(0.20 + 0.22 * d * bright, 0, 0.62) * f
            let discR = sz * 1.25
            ctx.fill(disc(x, y, discR), with: .color(col.withOpacity(discA).color))

            // (2) soft-grain bloom (cached sprite) — the white-hot pollen halo.
            if let grain {
                let bloomR = sz * (2.5 + 1.5 * bright)
                var g = ctx
                g.opacity = clampD(0.16 + 0.26 * d * bright, 0, 0.7) * f
                g.draw(grain, in: CGRect(x: x - bloomR, y: y - bloomR,
                                         width: bloomR * 2, height: bloomR * 2))
            }

            // (3) hot grain core — the crisp legible silhouette point, whitened.
            let coreA = clampD((0.52 + 0.5 * d) * bright, 0, 1) * f
            let w = 0.48 + 0.32 * bright
            let coreR = max(0.7, sz * 0.52)
            ctx.fill(disc(x, y, coreR),
                     with: .color(col.toWhite(w).withOpacity(coreA).color))

            // (4) ~5% sparkle: faint additive diffraction cross (batched; dropped
            //     first under throttle).
            if !lite && spark[k] && bright > 0.7 {
                let len = sz * (2.4 + 2.2 * (bright - 0.5))
                let ang = reduced ? twk[k] : t * 0.18 + twk[k]
                let cx0 = cos(ang) * len, cy0 = sin(ang) * len
                let cx1 = cos(ang + .pi / 2) * len, cy1 = sin(ang + .pi / 2) * len
                crossPath.move(to: CGPoint(x: x - cx0, y: y - cy0))
                crossPath.addLine(to: CGPoint(x: x + cx0, y: y + cy0))
                crossPath.move(to: CGPoint(x: x - cx1, y: y - cy1))
                crossPath.addLine(to: CGPoint(x: x + cx1, y: y + cy1))
                crossK += clampD(0.18 * d * bright, 0, 0.4) * f
                crossN += 1
            }
        }

        if crossN > 0 {
            ctx.stroke(crossPath,
                       with: .color(.white.opacity(clampD(crossK / Double(crossN), 0, 0.5))),
                       style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
    }

    // MARK: - Light: soft luminous pollen, source-over (never blown out)

    private func paintLight(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext,
                            m: Int, sizePx: Double, f: Double) {
        @inline(__always) func disc(_ x: Double, _ y: Double, _ rr: Double) -> Path {
            Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2))
        }
        var ctx = baseCtx
        ctx.blendMode = .normal
        for k in 0..<m {
            let ai = anchor[k]
            let d = depth[k]
            let bright = mb[k]
            let col = frame.dots[ai].rgba
            let x = mx[k], y = my[k]
            let sz = sizePx * msz[k] * (1.1 + 0.45 * d)

            // (1) soft outer halo — the gentle glow of suspended pollen.
            let haloA = clampD(0.10 + 0.11 * d * bright, 0, 0.26) * f
            let haloR = sz * 2.2
            ctx.fill(disc(x, y, haloR), with: .color(col.withOpacity(haloA).color))

            // (2) saturated body — gives the grain real presence on a light field.
            let bodyA = clampD(0.16 + 0.18 * d * bright, 0, 0.5) * f
            let bodyR = sz * 1.1
            ctx.fill(disc(x, y, bodyR), with: .color(col.withOpacity(bodyA).color))

            // (3) crisp core — a slightly deepened hue anchors the silhouette
            //     point with real contrast against the pale background.
            let coreA = clampD((0.50 + 0.5 * d) * bright, 0, 0.95) * f
            let coreR = max(0.6, sz * 0.5)
            ctx.fill(disc(x, y, coreR),
                     with: .color(col.darkened(by: 0.12).withOpacity(coreA).color))
        }
    }
}

#endif

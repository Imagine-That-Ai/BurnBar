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

        // assembly fade-in: the dust ignites as the mark forms.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.45 + 0.55
        // shared ribbon-drift amplitude, frozen under reduced motion.
        let driftAmp = reduced ? 0.0 : clampD(frame.cloudRadius * 0.02, 1.6, 5.0)

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Resolve the additive soft-grain bloom sprite ONCE per frame, draw many.
        // Source 48px stops: bright tight core, long gentle falloff (no hard edge).
        let grain: GraphicsContext.ResolvedImage? = (dark && !lite)
            ? ctx.resolve(sprites.radial(diameter: 48, stops: [
                (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
                (0.25, RGBA(r: 1, g: 1, b: 1, a: 0.5)),
                (0.55, RGBA(r: 1, g: 1, b: 1, a: 0.12)),
                (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
            ]))
            : nil

        // Batched diffraction-cross path (dark, brightest ~5%, not throttled).
        var crossPath = Path()
        var crossK = 0.0
        var crossN = 0

        for k in 0..<m {
            let ai = anchor[k]
            let hx = frame.dots[ai].x
            let hy = frame.dots[ai].y
            let d = depth[k]

            // ── Lissajous orbit around the anchor (per-mote shimmer) ──────────
            let r = orad[k] * sizePx
            let ox: Double
            let oy: Double
            if reduced {
                ox = cos(opx[k]) * r
                oy = sin(opy[k]) * r * 0.85
            } else {
                ox = cos(t * ofx[k] + opx[k]) * r
                oy = sin(t * ofy[k] + opy[k]) * r * 0.85
            }

            // ── shared domain-warped ribbon drift; deeper motes lag (parallax) ─
            var dx = 0.0
            var dy = 0.0
            if !reduced {
                let lag = (1 - d) * 0.9
                let fv = flow(hx, hy, t - lag)
                let par = 0.45 + d * 0.7
                dx = sin(fv + opx[k] * 0.3) * driftAmp * par
                dy = cos(fv * 0.7 + opy[k] * 0.3) * driftAmp * 0.55 * par
            }

            let x = hx + ox + dx
            let y = hy + oy + dy

            // ── per-mote brightness twinkle (slow) ────────────────────────────
            let bright: Double = reduced
                ? 0.6 + 0.4 * (0.5 + 0.5 * sin(twk[k]))
                : 0.62 + 0.38 * (0.5 + 0.5 * sin(t * 1.3 + twk[k]))

            let col = frame.dots[ai].rgba
            let sz = sizePx * msz[k] * (1.1 + 0.45 * d)

            if dark {
                // (1) colored disc — tints the bloom drawn over it (additive).
                let discA = clampD(0.18 * d * bright, 0, 0.5) * f
                let discR = sz * 1.15
                ctx.fill(Path(ellipseIn: CGRect(x: x - discR, y: y - discR,
                                                width: discR * 2, height: discR * 2)),
                         with: .color(col.withOpacity(discA).color))
                // (2) additive soft-grain bloom (cached sprite) — white, tinted
                //     by the disc beneath via additive compositing.
                if let grain {
                    let bloomR = sz * (2.6 + 1.4 * bright)
                    var g = ctx
                    g.opacity = clampD(0.1 + 0.2 * d * bright, 0, 0.6) * f
                    g.draw(grain, in: CGRect(x: x - bloomR, y: y - bloomR,
                                             width: bloomR * 2, height: bloomR * 2))
                }
                // (3) hot grain core — the legible silhouette point, whitened.
                let coreA = clampD((0.42 + 0.5 * d) * bright, 0, 1) * f
                let w = 0.45 + 0.3 * bright
                let coreR = max(0.5, sz * 0.42)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(col.toWhite(w).withOpacity(coreA).color))
                // (4) ~5% sparkle: faint additive diffraction cross (batched).
                if !lite && spark[k] && bright > 0.7 {
                    let len = sz * (2.2 + 2.0 * (bright - 0.5))
                    let ang = reduced ? twk[k] : t * 0.18 + twk[k]
                    let cx0 = cos(ang) * len, cy0 = sin(ang) * len
                    let cx1 = cos(ang + .pi / 2) * len, cy1 = sin(ang + .pi / 2) * len
                    crossPath.move(to: CGPoint(x: x - cx0, y: y - cy0))
                    crossPath.addLine(to: CGPoint(x: x + cx0, y: y + cy0))
                    crossPath.move(to: CGPoint(x: x - cx1, y: y - cy1))
                    crossPath.addLine(to: CGPoint(x: x + cx1, y: y + cy1))
                    crossK += clampD(0.14 * d * bright, 0, 0.32) * f
                    crossN += 1
                }
            } else {
                // LIGHT canvas: soft colored grain + crisp core (source-over).
                let haloA = clampD(0.1 * d * bright, 0, 0.22) * f
                let haloR = sz * 2.0
                ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR,
                                                width: haloR * 2, height: haloR * 2)),
                         with: .color(col.withOpacity(haloA).color))
                let coreA = clampD((0.45 + 0.5 * d) * bright, 0, 0.95) * f
                let coreR = max(0.55, sz * 0.46)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(col.withOpacity(coreA).color))
            }
        }

        // One batched stroke for all diffraction spikes (white, additive).
        if crossN > 0 {
            ctx.stroke(crossPath,
                       with: .color(.white.opacity(crossK / Double(crossN))),
                       style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
        }

        return true
    }
}

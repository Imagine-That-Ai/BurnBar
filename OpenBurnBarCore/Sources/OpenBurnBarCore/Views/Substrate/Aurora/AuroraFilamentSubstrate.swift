import SwiftUI

/// Aurora Filament — faithful port of imaginethat `aurora/filament.ts` drawBody.
///
/// The whole mark is drawn as ONE continuous glowing thread — a single luminous
/// wire snaking through every silhouette point in nearest-neighbour order (from
/// `frame.structure.order`), so the logo reads as one living line of cold light
/// rather than a field of dots. Hence `suppressesGlyphs = true`.
///
/// Per frame the NN walk's vertices ride a 2-octave domain-warped flow field at
/// LOW amplitude (clamped below point spacing so the wire never self-crosses),
/// accumulating arc length; any segment far longer than the local mean is BROKEN
/// (a new sub-path) so the wire never slashes a bright chord across empty space.
/// That single broken polyline is then stroked in stacked passes:
///   DARK (additive `.plusLighter`): wide aurora halo → mid glow → hot near-white
///   core → a crawling "charge" (animated dash phase) in gradient + white head.
///   LIGHT (`.normal`): soft gradient under-glow → crisp `stage.ink` core → a
///   travelling accent sheen.
/// The stroke colour is a screen-space vertical warm→cool gradient (amber crown →
/// teal mid → violet hem, brand accents woven in), so hue shifts down the wire.
/// The core alpha breathes and the charge crawls — both driven purely by `frame.t`
/// (charge lap ≈ 5 s). `reduced` → a poised straight still wire (no undulation, no
/// crawl, breath fixed 0.9). `batteryThrottled` drops the wide halo + charge pass.
/// `count < 2` degenerates to a single soft aurora seed dot. Reaction-only states
/// (slack / recoil / flare / spark crawl) collapse to their rest values.
public final class AuroraFilamentSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    // Aurora hue stops woven into the wire's vertical gradient (0…1 sRGB).
    private static let hueCrown = RGBA(r: 255.0 / 255, g: 196.0 / 255, b: 120.0 / 255) // amber
    private static let hueMid   = RGBA(r: 120.0 / 255, g: 240.0 / 255, b: 210.0 / 255) // teal
    private static let hueHem   = RGBA(r: 150.0 / 255, g: 170.0 / 255, b: 255.0 / 255) // violet-blue

    // Per-frame vertex scaffolding, reused across frames (resized on count change).
    private var px: [Double] = []
    private var py: [Double] = []
    private var brk: [Bool] = []

    public init() {}

    public var suppressesGlyphs: Bool { true }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let t = frame.t
        let stage = frame.stage

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // count < 2 — a single soft aurora seed so it's never blank / never throws.
        if count < 2 {
            drawSeed(frame, ctx)
            return true
        }

        // Nearest-neighbour walk order (cached by topology in the provider).
        let s = frame.structure.structure(for: frame.dots, k: 6)
        let order: [Int] = (s.order.count == count) ? s.order : Array(0..<count)

        // formed gate: while assembling, fade the wire in (settleProgress == source `formed`).
        let formGate = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1)

        // Undulation amplitude — clamped below point spacing so the wire never
        // self-crosses. spacing ≈ R / sqrt(count); cap to ~42% of it (max 5.5px).
        let spacing = max(2.0, frame.cloudRadius / max(1.0, Double(count).squareRoot()))
        let amp = reduced ? 0.0 : min(spacing * 0.42, 5.5)

        if px.count != count {
            px = [Double](repeating: 0, count: count)
            py = [Double](repeating: 0, count: count)
            brk = [Bool](repeating: false, count: count)
        }

        // ── undulate every vertex along the walk + accumulate arc length ──
        var prevX = 0.0, prevY = 0.0
        var total = 0.0
        for step in 0..<count {
            let d = frame.dots[order[step]]
            var vx = d.x, vy = d.y
            if amp > 0 {
                let f = flow(d.x, d.y, t)
                vx = d.x + f.0 * amp
                vy = d.y + f.1 * amp
            }
            px[step] = vx
            py[step] = vy
            if step > 0 {
                let dx = vx - prevX, dy = vy - prevY
                total += (dx * dx + dy * dy).squareRoot()
            }
            prevX = vx; prevY = vy
        }
        let arcTotal = total > 0 ? total : 1

        // Break any segment far longer than the mean step (greedy-NN leap guard).
        let meanStep = total / Double(max(1, count - 1))
        let breakThresh = max(meanStep * 3.4, spacing * 4)
        brk[0] = false
        for step in 1..<count {
            let dx = px[step] - px[step - 1], dy = py[step] - py[step - 1]
            brk[step] = (dx * dx + dy * dy).squareRoot() > breakThresh
        }

        // Build the single broken polyline once; every pass strokes the same path.
        var path = Path()
        path.move(to: CGPoint(x: px[0], y: py[0]))
        for step in 1..<count {
            let p = CGPoint(x: px[step], y: py[step])
            if brk[step] { path.move(to: p) } else { path.addLine(to: p) }
        }

        // Screen-space vertical warm→cool gradient, brand accents woven in.
        let top = max(0.0, frame.cy - frame.cloudRadius * 1.15)
        let bot = frame.cy + frame.cloudRadius * 1.15
        let crown = Self.hueCrown.mix(with: stage.accent, amount: smoothstep(0, 1, 0.32))
        let mid   = Self.hueMid.mix(with: stage.accent2, amount: smoothstep(0, 1, 0.32))
        let hem   = Self.hueHem.mix(with: stage.accent, amount: smoothstep(0, 1, 0.28))
        let gradShading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: crown.color, location: 0.0),
                .init(color: mid.color, location: 0.5),
                .init(color: hem.color, location: 1.0)
            ]),
            startPoint: CGPoint(x: 0, y: top),
            endPoint: CGPoint(x: 0, y: bot))

        // Core breathing + crawling charge phase — driven purely from `t`.
        let breath = reduced ? 0.9 : 0.78 + 0.22 * (0.5 + 0.5 * sin(t * 0.9))
        let chargePhase = reduced ? 0.0 : frac(t * 0.2)  // ~5s / lap

        let w = max(1.0, frame.sizePx)

        if dark {
            // pass 1 — wide soft aurora halo (dropped when battery-throttled).
            if !lite {
                strokePass(ctx, path, gradShading, width: w * 3.6,
                           alpha: clampD(0.1 * formGate, 0, 0.3))
            }
            // pass 2 — mid glow.
            strokePass(ctx, path, gradShading, width: w * 1.7,
                       alpha: clampD(0.26 * formGate, 0, 0.6))
            // pass 3 — hot near-white core (the legible silhouette skeleton).
            strokePass(ctx, path, .color(.white.opacity(0.96)), width: max(0.8, w * 0.62),
                       alpha: clampD(0.92 * formGate * breath, 0, 1))
            // pass 4 — travelling "charge": a bright dash crawling the wire.
            if !reduced && !lite && arcTotal > 4 {
                let dash = max(14.0, arcTotal * 0.07)
                let phase = -chargePhase * arcTotal
                strokePass(ctx, path, gradShading, width: max(1.0, w * 1.3),
                           alpha: clampD(0.5 * formGate, 0, 0.7),
                           dash: (dash, arcTotal - dash), phase: phase)
                strokePass(ctx, path, .color(.white.opacity(0.95)), width: max(0.8, w * 0.7),
                           alpha: clampD(0.55 * formGate, 0, 0.8),
                           dash: (dash, arcTotal - dash), phase: phase)
            }
        } else {
            // LIGHT stage (source-over): a darker ink thread, no blow-out.
            // soft colored under-glow so it still feels like light.
            strokePass(ctx, path, gradShading, width: w * 2.6,
                       alpha: clampD(0.18 * formGate, 0, 0.32))
            // crisp dark ink core — the legible line on a bright canvas.
            strokePass(ctx, path, .color(stage.ink.color), width: max(0.9, w * 0.7),
                       alpha: clampD(0.85 * formGate * breath, 0, 1))
            // a subtle travelling sheen so the wire still breathes.
            if !reduced && arcTotal > 4 {
                let dash = max(14.0, arcTotal * 0.06)
                strokePass(ctx, path, gradShading, width: max(0.9, w * 0.85),
                           alpha: clampD(0.4 * formGate, 0, 0.6),
                           dash: (dash, arcTotal - dash), phase: -chargePhase * arcTotal)
            }
        }

        return true
    }

    // MARK: - helpers

    /// One stroke pass: alpha is applied via a local context's `opacity`, so a
    /// gradient shading honors the source's per-pass `globalAlpha`. Dash optional.
    private func strokePass(_ base: GraphicsContext, _ path: Path,
                            _ shading: GraphicsContext.Shading,
                            width: Double, alpha: Double,
                            dash: (Double, Double)? = nil, phase: Double = 0) {
        guard alpha > 0.001, width > 0 else { return }
        var g = base
        g.opacity = alpha
        let style: StrokeStyle
        if let dash {
            style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                                dash: [dash.0, max(0.001, dash.1)], dashPhase: phase)
        } else {
            style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        }
        g.stroke(path, with: shading, style: style)
    }

    /// Two-octave domain-warped flow displacement (deterministic, alloc-free).
    @inline(__always)
    private func flow(_ x: Double, _ y: Double, _ t: Double) -> (Double, Double) {
        let k1 = 0.012, k2 = 0.027
        // octave 1 — broad sway
        let a1 = sin(x * k1 + t * 0.55) + cos(y * k1 * 1.3 - t * 0.4)
        let b1 = cos(x * k1 * 1.1 - t * 0.45) + sin(y * k1 - t * 0.5)
        // octave 2 — fine shimmer, warped by octave 1
        let a2 = sin((x + b1 * 30) * k2 + t * 0.9)
        let b2 = cos((y + a1 * 30) * k2 - t * 0.8)
        return (a1 * 0.7 + a2 * 0.45, b1 * 0.7 + b2 * 0.45)
    }

    /// count == 1 degenerate — a single soft aurora seed (never blank, never throws).
    private func drawSeed(_ frame: SwarmSubstrateFrame, _ ctx: GraphicsContext) {
        let d = frame.dots[0]
        let dark = frame.dark
        let k = frame.reduced ? 0.9 : 0.7 + 0.3 * (0.5 + 0.5 * sin(frame.t * 1.2))
        let glow = Self.hueMid.mix(with: frame.stage.accent2, amount: smoothstep(0, 1, 0.3))
        let gr = frame.sizePx * 3 * k
        var g = ctx
        g.opacity = 0.3 * k
        g.fill(Path(ellipseIn: CGRect(x: d.x - gr, y: d.y - gr, width: gr * 2, height: gr * 2)),
               with: .color(glow.color))
        let cr = max(0.9, frame.sizePx * 0.7)
        let core: Color = dark ? .white.opacity(0.95) : frame.stage.ink.color
        var c = ctx
        c.opacity = dark ? 0.95 : 0.85
        c.fill(Path(ellipseIn: CGRect(x: d.x - cr, y: d.y - cr, width: cr * 2, height: cr * 2)),
               with: .color(core))
    }
}

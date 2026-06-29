import SwiftUI

/// Wisp Plasma — ported from imaginethat `glyph/stage/styles/aurora/wisp.ts`.
///
/// Idiom: every silhouette point is a soft will-o-the-wisp orb — an outer aurora
/// bloom + a coloured mid halo wrapped around a near-white hot core. The dense
/// lattice of pin-sharp cores holds the mark pixel-locked while ONLY the halos
/// drift on a slow 2-octave domain-warped flow field, so the logo reads as a
/// crisp constellation of cold flame breathing inside a swaying curtain.
///
/// Faithful to drawBody: a screen-centred bloom vignette (dark only, additive,
/// drawn BEFORE the points), three stacked layers per orb (white bloom sprite,
/// coloured halo, whitened core), candle-flicker on core size/brightness, and a
/// travelling "gust" crest swept across the cloud (dark, not reduced) AFTER the
/// orbs. Perf-tuned: ONE cached white glow sprite (resolve once, draw many),
/// alpha baked into fill colours, blend flipped once per frame, ≤4 ops/dot.
/// Reduced → a poised still lantern field (no drift, static flicker, no gust).
/// Battery-throttled → drops the vignette, outer bloom, and gust.
public final class WispSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    /// Cheap 2-octave value-noise flow field (matches source `flow`): coherent
    /// vertical ribbons, allocation-free, three trig calls.
    @inline(__always) private func flow(_ x: Double, _ y: Double, _ t: Double) -> Double {
        let a = sin(x * 0.013 + t * 0.9) + cos(y * 0.017 - t * 0.6)
        let b = sin((x + y) * 0.021 - t * 0.5) * 0.5
        return a + b
    }

    public func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool {
        let dots = frame.dots
        guard !dots.isEmpty else { return false }

        let dark = frame.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t

        // assembly fade-in: orbs ignite as the mark forms.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.45 + 0.55
        // drift amplitude clamped well below inter-point spacing → cores never cross-read.
        let amp = reduced ? 0.0 : clampD(frame.cloudRadius * 0.018, 1.4, 4.2)

        // Single additive pass on dark, source-over on light — flip blend once.
        var pctx = ctx
        pctx.blendMode = dark ? .plusLighter : .normal

        // Resolve the white bloom sprite ONCE (exact source stops: 0→1, .28→.42, .6→.1, 1→0).
        let glow = pctx.resolve(sprites.radial(diameter: 64, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.28, RGBA(r: 1, g: 1, b: 1, a: 0.42)),
            (0.6, RGBA(r: 1, g: 1, b: 1, a: 0.1)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))

        @inline(__always) func drawGlow(_ x: Double, _ y: Double, _ r: Double, _ alpha: Double) {
            guard alpha > 0.001, r > 0 else { return }
            pctx.opacity = alpha
            pctx.draw(glow, in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            pctx.opacity = 1
        }

        // ── global bloom vignette — a screen-centred fake of camera glow (dark) ──
        if dark && !throttled {
            let tint = frame.stage.accent.mix(with: frame.stage.accent2, amount: 0.5)
            let vig = pctx.resolve(sprites.radial(diameter: 256, stops: [
                (0.0, tint.withOpacity(1.0)),
                (0.5, tint.withOpacity(0.35)),
                (1.0, tint.withOpacity(0.0))
            ]))
            let breath = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 0.55)
            pctx.opacity = (0.05 + 0.03 * breath) * f
            pctx.draw(vig, in: CGRect(origin: .zero, size: frame.size))
            pctx.opacity = 1
        }

        // ── per-orb: bloom (drifts) + halo (drifts) + hot core (pinned) ─────────
        for i in 0..<dots.count {
            let hx = dots[i].x
            let hy = dots[i].y
            let seed = shash(Double(i) * 1.37 + 0.5)

            // domain-warped ribbon sway — only the halo drifts; core stays put.
            var bx = hx
            var by = hy
            if !reduced {
                let fv = flow(hx, hy, t)
                bx = hx + sin(fv + seed * TAU) * amp
                by = hy + cos(fv * 0.7 + seed * 4.3) * amp * 0.45
            }

            // candle flicker: core radius / brightness pulse on per-point phase.
            let flick = reduced
                ? 0.5 + 0.5 * sin(seed * 19)
                : sin(t * 1.7 + seed * TAU) * 0.5 + 0.5
            var k = 0.85 + 0.15 * (flick * 2 - 1) // ±15% candle shimmer
            if !reduced {
                let s = sin(t * (0.8 + seed) + seed * 11.0) // rare bright tongue
                if s > 0.95 { k += ((s - 0.95) / 0.05) * 0.55 }
            }
            k = clampD(k, 0.45, 1.7) * f

            let col = dots[i].rgba

            if dark {
                // outer soft bloom — white additive sprite, no hard edge.
                if !throttled {
                    let bloomR = sizePx * (3.4 + 1.1 * (k - 0.5)) + 4
                    drawGlow(bx, by, bloomR, clampD(0.16 * k, 0, 0.4))
                }
                // mid coloured halo gives the orb its aurora body.
                let hr = sizePx * 1.55
                pctx.fill(Path(ellipseIn: CGRect(x: bx - hr, y: by - hr, width: hr * 2, height: hr * 2)),
                          with: .color(col.withOpacity(clampD(0.26 * k, 0, 0.55)).color))
                // hot near-white core — the legible silhouette point (does NOT drift).
                let cr = max(0.8, sizePx * (0.6 + 0.12 * (k - 0.85)))
                pctx.fill(Path(ellipseIn: CGRect(x: hx - cr, y: hy - cr, width: cr * 2, height: cr * 2)),
                          with: .color(col.toWhite(0.62).withOpacity(clampD(0.9 * k, 0, 1)).color))
            } else {
                // LIGHT canvas: soft coloured wisps, source-over (never blow out).
                let r1 = sizePx * 2.4
                pctx.fill(Path(ellipseIn: CGRect(x: bx - r1, y: by - r1, width: r1 * 2, height: r1 * 2)),
                          with: .color(col.withOpacity(clampD(0.12 * k, 0, 0.24)).color))
                let r2 = sizePx * 1.3
                pctx.fill(Path(ellipseIn: CGRect(x: bx - r2, y: by - r2, width: r2 * 2, height: r2 * 2)),
                          with: .color(col.withOpacity(clampD(0.2 * k, 0, 0.38)).color))
                // crisp coloured core anchors the silhouette.
                let cr = max(0.85, sizePx * 0.68)
                pctx.fill(Path(ellipseIn: CGRect(x: hx - cr, y: hy - cr, width: cr * 2, height: cr * 2)),
                          with: .color(col.withOpacity(clampD(0.95 * f, 0, 1)).color))
            }
        }

        // ── gust crest: a slow brightness band sweeping the curtain left-to-right ───
        if dark && !reduced && !throttled {
            let radius = frame.cloudRadius
            let span = radius * 2.6
            let crestX = frame.cx - radius * 1.3 + (t * (span / 9)).truncatingRemainder(dividingBy: span)
            let band = radius * 0.32
            if band > 0 {
                for i in 0..<dots.count {
                    let d = dots[i].x - crestX
                    if d < -band || d > band { continue }
                    let w = 1 - abs(d) / band
                    let r = sizePx * (2.2 + 2.4 * w)
                    drawGlow(dots[i].x, dots[i].y, r, 0.1 * w * w * f)
                }
            }
        }

        return true
    }
}

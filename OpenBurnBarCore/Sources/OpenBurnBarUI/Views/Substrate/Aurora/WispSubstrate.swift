import SwiftUI
import OpenBurnBarKernel

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
        let sizePx = max(0.8, frame.sizePx)
        let t = frame.t

        // assembly fade-in: orbs ignite as the mark forms.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.45 + 0.55
        // drift amplitude clamped well below inter-point spacing → cores never cross-read.
        let amp = reduced ? 0.0 : clampD(frame.cloudRadius * 0.018, 1.4, 4.2)

        // Aurora glow tint — blooms lean toward the stage accent/iris band.
        let accentMix = frame.stage.accent.mix(with: frame.stage.accent2, amount: 0.5)

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
        // Accent-tinted soft glow — the colored orb body when the gaussian bed is
        // dropped (battery throttle), resolved once (single bucket, never per-dot).
        let tinted = pctx.resolve(sprites.tintedGlow(accentMix.withOpacity(1.0), diameter: 64))

        @inline(__always) func drawGlow(_ img: GraphicsContext.ResolvedImage,
                                        _ x: Double, _ y: Double, _ r: Double, _ alpha: Double) {
            guard alpha > 0.001, r > 0 else { return }
            pctx.opacity = alpha
            pctx.draw(img, in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            pctx.opacity = 1
        }

        // Per-orb kinematics: bloom/halo drift on the flow field; core stays pinned;
        // `k` is the candle-flicker brightness. Allocation-free, reused every pass.
        @inline(__always) func orb(_ i: Int) -> (bx: Double, by: Double, k: Double) {
            let hx = dots[i].x, hy = dots[i].y
            let seed = shash(Double(i) * 1.37 + 0.5)
            var bx = hx, by = hy
            if !reduced {
                let fv = flow(hx, hy, t)
                bx = hx + sin(fv + seed * TAU) * amp
                by = hy + cos(fv * 0.7 + seed * 4.3) * amp * 0.45
            }
            let flick = reduced
                ? 0.5 + 0.5 * sin(seed * 19)
                : sin(t * 1.7 + seed * TAU) * 0.5 + 0.5
            var k = 0.85 + 0.15 * (flick * 2 - 1) // ±15% candle shimmer
            if !reduced {
                let s = sin(t * (0.8 + seed) + seed * 11.0) // rare bright tongue of flame
                if s > 0.95 { k += ((s - 0.95) / 0.05) * 0.55 }
            }
            return (bx, by, clampD(k, 0.45, 1.7) * f)
        }

        if dark {
            // ── global bloom vignette — a screen-centred fake of camera glow ──────
            if !throttled {
                let vig = pctx.resolve(sprites.radial(diameter: 256, stops: [
                    (0.0, accentMix.withOpacity(1.0)),
                    (0.5, accentMix.withOpacity(0.35)),
                    (1.0, accentMix.withOpacity(0.0))
                ]))
                let breath = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 0.55)
                pctx.opacity = (0.06 + 0.04 * breath) * f
                pctx.draw(vig, in: CGRect(origin: .zero, size: frame.size))
                pctx.opacity = 1
            }

            // ── LAYER 1 · GAUSSIAN PLASMA BED (the premium presence lever) ────────
            // One real blurred additive layer: per-orb coloured discs are pushed
            // toward the aurora accent, blurred into a continuous luminous field, so
            // the silhouette is filled by glowing gas — not faint isolated specks.
            if !throttled {
                pctx.drawLayer { layer in
                    layer.blendMode = .plusLighter
                    layer.addFilter(.blur(radius: sizePx * 2.4))
                    for i in 0..<dots.count {
                        let o = orb(i)
                        let glowCol = dots[i].rgba.mix(with: accentMix, amount: 0.34)
                        let r = sizePx * 1.85
                        layer.fill(
                            Path(ellipseIn: CGRect(x: o.bx - r, y: o.by - r, width: r * 2, height: r * 2)),
                            with: .color(glowCol.withOpacity(clampD(0.46 * o.k, 0, 0.85)).color))
                    }
                }
            }

            // ── LAYER 2..4 · per-orb bright bloom → saturated halo → hot core ─────
            for i in 0..<dots.count {
                let o = orb(i)
                let col = dots[i].rgba

                if throttled {
                    // Throttle fallback: the colored bed is gone, so paint a single
                    // accent-tinted glow sprite per orb to keep the field luminous.
                    drawGlow(tinted, o.bx, o.by, sizePx * 2.6, clampD(0.30 * o.k, 0, 0.62))
                } else {
                    // Bright white-hot bloom sprite sits over the colored bed.
                    let bloomR = sizePx * (2.8 + 0.9 * (o.k - 0.5)) + 3
                    drawGlow(glow, o.bx, o.by, bloomR, clampD(0.24 * o.k, 0, 0.5))
                }

                // saturated coloured halo — the orb's aurora body (drifts).
                let hr = sizePx * 1.5
                pctx.fill(Path(ellipseIn: CGRect(x: o.bx - hr, y: o.by - hr, width: hr * 2, height: hr * 2)),
                          with: .color(col.mix(with: accentMix, amount: 0.18)
                                          .withOpacity(clampD((throttled ? 0.40 : 0.34) * o.k, 0, 0.7)).color))

                // hot near-white core — pinned legible silhouette point (does NOT drift).
                let hx = dots[i].x, hy = dots[i].y
                let cr = max(1.0, sizePx * (0.64 + 0.12 * (o.k - 0.85)))
                pctx.fill(Path(ellipseIn: CGRect(x: hx - cr, y: hy - cr, width: cr * 2, height: cr * 2)),
                          with: .color(col.toWhite(0.7).withOpacity(clampD(0.98 * o.k, 0, 1)).color))
            }

            // ── gust crest: a slow brightness band sweeping the curtain L→R ───────
            if !reduced && !throttled {
                let radius = frame.cloudRadius
                let span = radius * 2.6
                let crestX = frame.cx - radius * 1.3 + (t * (span / 9)).truncatingRemainder(dividingBy: span)
                let band = radius * 0.32
                if band > 0 {
                    for i in 0..<dots.count {
                        let d = dots[i].x - crestX
                        if d < -band || d > band { continue }
                        let w = 1 - abs(d) / band
                        let r = sizePx * (2.2 + 2.6 * w)
                        drawGlow(glow, dots[i].x, dots[i].y, r, 0.12 * w * w * f)
                    }
                }
            }
        } else {
            // ── LIGHT canvas: soft gas haze + crisp legible cores (never blown out).
            // LAYER 1 · blurred coloured haze gives the will-o-wisp its body without
            // additive blow-out (source-over inside, low alpha).
            if !throttled {
                pctx.drawLayer { layer in
                    layer.blendMode = .normal
                    layer.addFilter(.blur(radius: sizePx * 1.8))
                    for i in 0..<dots.count {
                        let o = orb(i)
                        let r = sizePx * 1.8
                        layer.fill(
                            Path(ellipseIn: CGRect(x: o.bx - r, y: o.by - r, width: r * 2, height: r * 2)),
                            with: .color(dots[i].rgba.withOpacity(clampD(0.22 * o.k, 0, 0.4)).color))
                    }
                }
            }

            for i in 0..<dots.count {
                let o = orb(i)
                let col = dots[i].rgba
                // mid coloured wisp (drifts) — a touch of presence around each core.
                let r2 = sizePx * (throttled ? 1.7 : 1.25)
                pctx.fill(Path(ellipseIn: CGRect(x: o.bx - r2, y: o.by - r2, width: r2 * 2, height: r2 * 2)),
                          with: .color(col.withOpacity(clampD((throttled ? 0.26 : 0.22) * o.k, 0, 0.42)).color))
                // crisp coloured core (pinned) — nudged toward ink for contrast.
                let hx = dots[i].x, hy = dots[i].y
                let cr = max(0.9, sizePx * 0.7)
                pctx.fill(Path(ellipseIn: CGRect(x: hx - cr, y: hy - cr, width: cr * 2, height: cr * 2)),
                          with: .color(col.mix(with: frame.stage.ink, amount: 0.12)
                                          .withOpacity(clampD(0.96 * f, 0, 1)).color))
            }
        }

        return true
    }
}

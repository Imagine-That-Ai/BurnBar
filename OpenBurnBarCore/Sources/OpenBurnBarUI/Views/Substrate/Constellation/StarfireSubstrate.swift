import SwiftUI

/// Stellar Plasma — faithful port of imaginethat `constellation/starfire.ts` drawBody (L75-147).
///
/// Each silhouette point is a long-exposure star. On a DARK canvas (additive
/// `.plusLighter`) every point stacks, in z-order: (1) a cached 64px white
/// radial-glow bloom; (2) a chromatic plasma disc in the point's own color;
/// (3) a near-white hot core (the legible silhouette point); (4) for the
/// brightest ~20% (seed>0.8) a slowly-rotating pure-white diffraction cross.
/// On a LIGHT canvas (`.normal`) it collapses to a soft colored halo + colored
/// core. Twinkle is brightness/size only — no positional drift — driven purely
/// from `frame.t` + a per-point seed, with an occasional sharp scintillation
/// flare. `reduced` freezes to a poised still star-field; `batteryThrottled`
/// drops the bloom + cross passes. Exact alpha/radius constants ARE the look.
public final class StarfireSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        // forming gain — settleProgress is the source `formed` (0…1).
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.5 + 0.5

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Resolve the additive bloom sprite ONCE per frame, draw it many times.
        let glow = (dark && !lite) ? ctx.resolve(sprites.whiteGlow(diameter: 64)) : nil

        // (0) DEEP GAUSSIAN BLOOM — a real blurred under-glow, the premium depth
        // layer the silhouette sits in. Each star's color, pushed toward the
        // stage accent and lifted slightly toward white, is drawn additively into
        // a single blurred layer, so the whole field rests in one cohesive
        // luminous wash beneath the crisp sprite bloom and hot cores. This is the
        // heaviest extra pass → dropped when batteryThrottled, where the cached
        // sprite bloom alone still reads richly.
        if dark, !lite {
            let accent = frame.stage.accent
            let bloomDisc = sizePx * 1.85
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: sizePx * 2.6))
                layer.blendMode = .plusLighter
                for i in 0..<count {
                    let d = frame.dots[i]
                    let seed = shash(Double(i) * 1.37 + 0.5)
                    var k = 0.82 + 0.18 * (reduced ? 0.5 + 0.5 * sin(seed * 19) : sin(t * 1.6 + seed * TAU))
                    if !reduced {
                        let s = sin(t * (1.1 + seed) + seed * 7.0)
                        if s > 0.93 { k += (s - 0.93) / 0.07 * 0.7 }
                    }
                    k = clampD(k, 0.35, 1.7) * f
                    // glow hue: brand color biased to accent, kissed toward white.
                    let glowCol = d.rgba.mix(with: accent, amount: 0.34).toWhite(0.16)
                    layer.fill(
                        Path(ellipseIn: CGRect(x: d.x - bloomDisc, y: d.y - bloomDisc,
                                               width: bloomDisc * 2, height: bloomDisc * 2)),
                        with: .color(glowCol.withOpacity(clampD(0.20 * k, 0, 0.5)).color))
                }
            }
        }

        // Bucketed diffraction-cross paths (dark, brightest ~20%, not throttled).
        // Source strokes each star's cross with its OWN alpha clamp(0.16*k,0,0.4) so
        // bright stars flare and dim ones stay faint. We preserve that per-star
        // twinkle by binning crosses into a few alpha tiers and stroking one white,
        // additive Path per tier — cheap (N is ~20% of dots) but never collapses the
        // whole field to a single mean alpha.
        let crossTiers = 5
        let crossAlphaMax = 0.4
        var crossPaths = [Path](repeating: Path(), count: crossTiers)
        var crossUsed = false

        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let seed = shash(Double(i) * 1.37 + 0.5)

            // per-star twinkle: gentle breathe + occasional scintillation flare.
            var k = 0.82 + 0.18 * (reduced ? 0.5 + 0.5 * sin(seed * 19) : sin(t * 1.6 + seed * TAU))
            if !reduced {
                let s = sin(t * (1.1 + seed) + seed * 7.0)
                if s > 0.93 { k += (s - 0.93) / 0.07 * 0.7 }
            }
            k = clampD(k, 0.35, 1.7) * f

            let col = d.rgba

            if dark {
                // (1) additive white bloom (cached sprite) — skip when throttled.
                if let glow {
                    let bloomR = sizePx * 3.4 * (0.7 + 0.5 * k)
                    var g = ctx
                    g.opacity = 0.13 * k
                    g.draw(glow, in: CGRect(x: x - bloomR, y: y - bloomR,
                                            width: bloomR * 2, height: bloomR * 2))
                }
                // (2) chromatic plasma disc.
                let discR = sizePx * 1.5
                ctx.fill(Path(ellipseIn: CGRect(x: x - discR, y: y - discR,
                                                width: discR * 2, height: discR * 2)),
                         with: .color(col.withOpacity(clampD(0.30 * k, 0, 0.6)).color))
                // (3) near-white hot core — the legible silhouette point.
                let coreR = max(0.8, sizePx * 0.62)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(col.toWhite(0.6).withOpacity(clampD(0.85 * k, 0, 1)).color))
                // (4) diffraction cross for the brightest ~20%, slowly rotating.
                if !lite && seed > 0.8 {
                    let len = sizePx * (3 + 3 * (k - 0.5))
                    let a = reduced ? seed * TAU : t * 0.05 + seed * TAU
                    let cx0 = cos(a) * len, cy0 = sin(a) * len
                    let cx1 = cos(a + .pi / 2) * len, cy1 = sin(a + .pi / 2) * len
                    // per-star spike alpha (source L121) — bin into a tier so the
                    // bright stars keep their flare instead of the field average.
                    let crossA = clampD(0.16 * k, 0, crossAlphaMax)
                    var tier = Int(crossA / crossAlphaMax * Double(crossTiers))
                    if tier >= crossTiers { tier = crossTiers - 1 }
                    if tier < 0 { tier = 0 }
                    crossPaths[tier].move(to: CGPoint(x: x - cx0, y: y - cy0))
                    crossPaths[tier].addLine(to: CGPoint(x: x + cx0, y: y + cy0))
                    crossPaths[tier].move(to: CGPoint(x: x - cx1, y: y - cy1))
                    crossPaths[tier].addLine(to: CGPoint(x: x + cx1, y: y + cy1))
                    crossUsed = true
                }
            } else {
                // LIGHT canvas: soft colored halo + colored core (source-over).
                let haloR = sizePx * 2.2
                ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR,
                                                width: haloR * 2, height: haloR * 2)),
                         with: .color(col.withOpacity(clampD(0.16 * k, 0, 0.3)).color))
                let coreR = max(0.9, sizePx * 0.72)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(col.withOpacity(clampD(0.95 * f, 0, 1)).color))
            }
        }

        // One batched stroke per alpha tier — preserves per-star spike twinkle
        // (white, additive) without a stroke call per dot.
        if crossUsed {
            for tier in 0..<crossTiers where !crossPaths[tier].isEmpty {
                let a = (Double(tier) + 0.5) / Double(crossTiers) * crossAlphaMax
                ctx.stroke(crossPaths[tier],
                           with: .color(.white.opacity(a)),
                           style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }
        }

        return true
    }
}

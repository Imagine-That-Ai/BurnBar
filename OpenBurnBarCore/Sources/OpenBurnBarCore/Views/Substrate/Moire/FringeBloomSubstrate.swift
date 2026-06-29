import SwiftUI

/// Fringe Bloom — faithful port of imaginethat `moire/fringe-bloom.ts` drawBody (L143-283).
///
/// Every silhouette point is a soft emissive node whose brightness is the PRODUCT
/// of two slowly-drifting sinusoidal gratings — two laser interferograms beating
/// against each other. Phase is sampled in node-space (`px,py = x-cx, y-cy`) so the
/// bands stay locked to the mark. Grating A drifts `+t*0.55`, grating B drifts
/// `-t*0.44` (rotated ~10°): the ~0.8× speed mismatch is the beat envelope, so
/// luminous moiré bands crawl diagonally and beat in and out. Contrast (γ=1.9) pops
/// the antinodes; a 0.16 FLOOR lift keeps the whole silhouette continuously lit —
/// the moiré only MODULATES an already-complete mark, never punches holes.
///
/// DARK canvas (additive `.plusLighter`), per hot node in z-order: (1) a cached
/// 64px white→clear radial bloom sized by `k`; (2) a colored body disc carrying the
/// brand hue; (3) for the brightest nodes (`k>0.85`) a second wide faint antinode
/// bloom (dropped when `batteryThrottled`). LIGHT canvas (`.normal`): a soft colored
/// halo + crisp colored core whose alpha IS the fringe, so a bright canvas never
/// blows out. `reduced` freezes phases (phA=0.6, phB=-0.9, no carrier breathing)
/// into a poised still interferogram. No per-frame gradients, no wall clock — driven
/// purely by `frame.t` and node-space phase. Exact alpha/radius constants ARE the look.
public final class FringeBloomSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // ── tunables (mirror the source) ────────────────────────────────────────
    private static let FLOOR = 0.22   // legibility glow every node always emits (lifted so the mark FILLS)
    private static let GAMMA = 1.7    // contrast on the fringe product (eased so bands stay luminous, antinodes still pop)
    private static let DRIFT_A = 0.55 // primary grating temporal drift (rad/s)
    private static let DRIFT_B = 0.44 // second grating drift (~0.8×) → the beat envelope
    private static let BEAT = 0.085   // slow whole-mark breathing of the carrier freq

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let cx = frame.cx, cy = frame.cy, radius = frame.cloudRadius

        // Assembly fade so the fringes bloom in as the mark forms (vis/armPulse fold
        // to 1 for the held substrate look). reduced → treat as fully formed.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        // Grating geometry: spatial frequency scales with cloud size so the band
        // count reads the same on any logo. Two gratings at slightly different
        // orientation + frequency beat into the crawling moiré.
        let base = 5.6 / max(radius, 1)
        let beat = reduced ? 0 : sin(t * Self.BEAT) * 0.5
        let kx = base * (1 + 0.05 * beat)
        let ky = base * (1 + 0.05 * beat) * 0.92
        let ang2 = 0.18 // ~10° rotation for the second grating → diagonal bands
        let c2 = cos(ang2)
        let s2 = sin(ang2)
        let k2 = base * 1.06
        let phA = reduced ? 0.6 : t * Self.DRIFT_A
        let phB = reduced ? -0.9 : -t * Self.DRIFT_B

        let floor = Self.FLOOR
        let gamma = Self.GAMMA

        // Spectral interferogram palette: real two-grating fringes carry a thin-film
        // rainbow, so the moiré bands are tinted across the iris jewel ramp (not just
        // brightness). The local fringe phase indexes the ramp → adjacent antinodes
        // shimmer cyan/mint/gold/rose as the gratings crawl. The dot's own brand hue
        // is preserved and only nudged toward this spectral tint, never overwritten.
        let iris = SubstrateRamp.iris
        let accent = frame.stage.accent

        // The interference field, sampled in the mark's own frame. Returns the
        // floor-lifted, contrast-shaped, form-gated intensity plus the blended
        // grating value that indexes the spectral ramp. Captures the grating
        // constants; allocates nothing (recomputed in both passes, cheap sin math).
        @inline(__always)
        func fringe(_ px: Double, _ py: Double) -> (inten: Double, gmix: Double) {
            let g1 = 0.5 + 0.5 * sin(px * kx + py * ky * 0.18 + phA)
            let u2 = px * c2 - py * s2
            let g2 = 0.5 + 0.5 * sin(u2 * k2 + phB)
            var inten = pow(g1 * g2, gamma)
            inten = floor + (1 - floor) * inten
            inten *= form
            return (inten, g1 * 0.5 + g2 * 0.5)
        }

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Resolve the additive bloom sprite ONCE per frame (dark only), draw many.
        // Exact source stops: white@0 → .62@.18 → .22@.42 → .05@.72 → clear@1.
        let glow = dark ? ctx.resolve(sprites.radial(diameter: 64, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.18, RGBA(r: 1, g: 1, b: 1, a: 0.62)),
            (0.42, RGBA(r: 1, g: 1, b: 1, a: 0.22)),
            (0.72, RGBA(r: 1, g: 1, b: 1, a: 0.05)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ])) : nil

        // ── (0) TRUE GAUSSIAN BLOOM — the premium depth layer ────────────────────
        // One real blurred wash the whole interferogram rests in, so the field
        // clearly FILLS its silhouette and the antinode bands GLOW instead of
        // reading as faint dots. Every node deposits a spectral-tinted, intensity-
        // scaled disc into a single blurred layer; on dark it's additive
        // (`.plusLighter`), on light it's `.normal` (overlap saturates into soft
        // colored haze without blowing the bright canvas out). This is the heaviest
        // extra pass → dropped under battery throttle, where the crisp passes below
        // still read richly.
        if !lite {
            let bloomR = sizePx * (dark ? 2.9 : 2.1)
            let blurRad = sizePx * (dark ? 3.4 : 2.3)
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: blurRad))
                layer.blendMode = dark ? .plusLighter : .normal
                for i in 0..<count {
                    let d = frame.dots[i]
                    let (inten, gmix) = fringe(d.x - cx, d.y - cy)
                    let k = clampD(inten, 0, 1.9)
                    if k < 0.05 { continue }
                    let spec = SubstrateRamp.sample(iris, frac(gmix + d.colorIndex * 0.2))
                    // glow hue: brand color pushed hard toward the spectral fringe tint,
                    // kissed toward the stage accent + white so antinodes go luminous and
                    // the band rainbow clearly tints the wash (richer spectral presence).
                    let glowCol = d.rgba.mix(with: spec, amount: 0.62)
                        .mix(with: accent, amount: dark ? 0.22 : 0.05)
                        .toWhite(dark ? 0.16 : 0.0)
                    let r = bloomR * (0.6 + 0.9 * min(k, 1.4))
                    let a = dark ? clampD(0.42 * k, 0, 0.88) : clampD(0.24 * k, 0, 0.5)
                    layer.fill(Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r,
                                                      width: r * 2, height: r * 2)),
                               with: .color(glowCol.withOpacity(a).color))
                }
            }
        }

        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            // node-space coords keep the grating phase locked to the mark's frame.
            let px = x - cx
            let py = y - cy

            let (inten, gmix) = fringe(px, py)
            if inten <= 0 { continue }

            // spectral fringe tint for this node, blended off its own brand hue.
            let spec = SubstrateRamp.sample(iris, frac(gmix + d.colorIndex * 0.2))

            if dark {
                let k = clampD(inten, 0, 1.9)
                // (1) primary emissive node — cached white bloom sized by k. Boosted
                //     opacity + reach so even floor-lit nodes carry strong glow (no faint
                //     gaps) and antinodes flare hard — the field reads as light, not dots.
                let r0 = sizePx * (2.4 + 2.8 * min(k, 1.0))
                if let glow {
                    var g = ctx
                    g.opacity = clampD(0.44 + 0.72 * k, 0, 1.0)
                    g.draw(glow, in: CGRect(x: x - r0, y: y - r0, width: r0 * 2, height: r0 * 2))
                }
                // (2) saturated spectral body — the brand hue carried through the
                //     bloom, pushed harder toward the fringe tint for richer spectral
                //     presence (the band rainbow clearly colors each node).
                let bodyCol = d.rgba.mix(with: spec, amount: 0.46)
                let bodyR = max(1.0, sizePx * 1.5)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR,
                                                width: bodyR * 2, height: bodyR * 2)),
                         with: .color(bodyCol.withOpacity(clampD(0.64 * k, 0, 0.95)).color))
                // (3) hot core ON TOP — crisp luminous point that whitens at antinodes
                //     (depth: blur wash → spectral body → hot core). Dim floor nodes
                //     stay colored; bright bands punch white-hot with extra contrast.
                let coreR = max(0.72, sizePx * 0.62)
                let coreCol = bodyCol.toWhite(0.36 + 0.55 * min(k, 1.0))
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(coreCol.withOpacity(clampD(0.42 + 0.6 * (k - 0.4), 0.28, 1.0)).color))
                // (4) antinode bloom: bright nodes get a wide spectral-white disc — wider,
                //     more of them, and brighter so the moiré antinodes clearly blaze.
                //     Dropped under battery throttle (the expendable extra pass).
                if !lite, k > 0.7, let glow {
                    let rb = sizePx * (4.8 + 3.6 * (k - 0.7))
                    var g = ctx
                    g.opacity = clampD(0.2 * (k - 0.7) * 2.6, 0, 0.46)
                    g.draw(glow, in: CGRect(x: x - rb, y: y - rb, width: rb * 2, height: rb * 2))
                }
            } else {
                // LIGHT canvas: source-over discs; alpha IS the fringe so the bands
                // read as tonal modulation and never blow the canvas to white. The
                // spectral tint + boosted alpha give crisp, saturated presence.
                let k = clampD(inten, 0, 1.4)
                // soft outer halo — a touch wider + richer spectral tint for presence.
                let haloCol = d.rgba.mix(with: spec, amount: 0.36)
                let haloR = sizePx * (2.0 + 1.4 * min(k, 1.0))
                ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR,
                                                width: haloR * 2, height: haloR * 2)),
                         with: .color(haloCol.withOpacity(clampD(0.26 * k, 0, 0.5)).color))
                // crisp saturated core that keeps the silhouette dense.
                let coreCol = d.rgba.mix(with: spec, amount: 0.26)
                let coreR = max(0.92, sizePx * 0.82)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(coreCol.withOpacity(clampD(0.6 + 0.42 * (k - floor), 0.4, 0.97)).color))
            }
        }

        return true
    }
}

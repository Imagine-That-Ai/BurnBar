import SwiftUI

/// Dendritic Frost — premium port of imaginethat `constellation/rimefrost.ts`
/// drawBody (L81–274, held "melt 0" look).
///
/// Each silhouette point nucleates a six-armed rime crystal. The field is built
/// in depth-ordered passes so it reads as luminous frost spreading across cold
/// glass — never a scatter of flat specks:
///   0. DEEP GAUSSIAN BLOOM (dark, the premium presence lever) — every crystal's
///      own brand color, only lightly iced (NOT whitened away), is filled into ONE
///      real `.blur`-filtered, additive `.plusLighter` layer, so each cluster rests
///      in a single cohesive wash that glows in *its* hue rather than white noise.
///   1. ICY BODY BLOOM — a cached 48px white-blue radial frost sprite drawn per
///      crystal, `colorMultiply`-tinted to the dot's brand color (the brand-tinted
///      glow), with a smaller untinted white-blue sheen on top so the very center
///      stays a frost-blue/white core sitting inside the colored bloom.
///   2. SIX DENDRITE ARMS — 3 tapering spines (1.5→0.9→0.4) + two forward
///      side-branches each, batched per alpha-bin × width-group into a handful of
///      strokes so the feathery six-fold structure stays crisp and cheap.
///   3. HOT FROZEN CORE — the legible silhouette point, whitened on dark.
///   4. FROST GLINT — a twinkling near-white cross on the brightest seeds (dark).
///
/// Crystals "grow & melt" on a slow `sin(0.5·t + seed·TAU + posPhase)` wave so the
/// cloud crystallizes in soft travelling waves under an imperceptible global
/// rotation (`t·0.03`). Per-point brand colors are lifted toward ice (224,238,255);
/// the under-wash also leans toward `stage.accent`. Honors `frame.dark` (additive
/// `.plusLighter` vs source-over `.normal`), `frame.reduced` (a poised, mostly-grown
/// still frost-field), and `frame.batteryThrottled` (drops only the heaviest pass —
/// the gaussian under-wash — while the cached sprite bloom keeps the field rich).
/// The meltwater beads are destruction-only and omitted from the held look.
public final class RimefrostSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let accent = frame.stage.accent

        // assembly gain — fade the crystal field in as the mark forms.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.45 + 0.55

        // cap arm length below inter-point spacing so feathering never smears.
        let spacing = frame.cloudRadius / max(2.0, sqrt(Double(count)))
        let armCap = clampD(spacing * 0.42, sizePx * 2.4, sizePx * 6)
        let armMin = clampD(spacing * 0.16, sizePx * 1.2, armCap)
        // imperceptible global rotation of the whole field.
        let spin = reduced ? 0.0 : t * 0.03

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // cached white-blue frost-bloom sprite (resolved once; drawn many).
        let bloom = ctx.resolve(sprites.radial(diameter: 48, stops: [
            (0.0, RGBA(r: 232.0 / 255, g: 244.0 / 255, b: 1.0, a: 1.0)),
            (0.26, RGBA(r: 210.0 / 255, g: 230.0 / 255, b: 1.0, a: 0.62)),
            (0.55, RGBA(r: 182.0 / 255, g: 214.0 / 255, b: 1.0, a: 0.20)),
            (1.0, RGBA(r: 180.0 / 255, g: 212.0 / 255, b: 1.0, a: 0.0))
        ]))

        // ice target the per-point brand color is lifted toward.
        let iceR = 224.0 / 255, iceG = 238.0 / 255, iceB = 1.0
        let ice = RGBA(r: iceR, g: iceG, b: iceB, a: 1)

        // ── precompute per-crystal state once (shared by every pass) ─────────────
        struct Crystal {
            let x, y: Double
            let grow, g: Double
            let frost: RGBA          // ice-lifted brand color (dendrite arms)
            let glow: RGBA           // brand-colored under-wash hue (bloom layer)
            let bodyTint: RGBA       // brand tint multiplied into the body sprite
            let radius, baseRot: Double
            let seed, seed2: Double
            let br, bodyA, coreSheenA: Double  // body sprite size + opacity + white core sheen
        }
        var xs = [Crystal](); xs.reserveCapacity(count)

        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let seed = shash(Double(i) * 1.37 + 0.5)
            let seed2 = shash(Double(i) * 2.91 + 7.3)

            // grow & melt loop with a per-point phase tied to seed AND position →
            // frost crystallizes in slow travelling waves, not in lockstep.
            let phase = seed * TAU + (x * 0.012 + y * 0.016)
            let grow = reduced ? 0.84 + 0.12 * sin(seed * 9.1)
                               : 0.5 + 0.5 * sin(t * 0.5 + phase)
            let g = clampD(0.22 + grow * grow * 0.78, 0, 1) * f // ease-in growth

            // frost tint: lift the brand color toward white-blue ice (the dendrite
            // arms read as crisp frost while still carrying a hint of the hue).
            let c = d.rgba
            let frost = RGBA(r: c.r + (iceR - c.r) * 0.55,
                             g: c.g + (iceG - c.g) * 0.55,
                             b: c.b + (iceB - c.b) * 0.60, a: 1)
            // under-wash hue: the dot's OWN brand color, only lightly iced and a
            // touch lifted by the cold accent — so the deep bloom glows in-hue and
            // each cluster is unmistakably its color, never a white-noise field.
            let glow = c.mix(with: ice, amount: 0.16).mix(with: accent, amount: 0.10)
            // body-sprite tint: brand kept saturated but lifted just enough to stay
            // luminous when multiplied into the bright white-blue sprite (dark adds).
            let bodyTint = c.mix(with: ice, amount: 0.28).toWhite(0.08)

            let radius = lerp(armMin, armCap, 0.45 + seed2 * 0.55) * (0.6 + 0.4 * grow)
            let br = (sizePx * 2.8 + radius * 0.52) * (0.72 + 0.28 * grow)
            // body sprite carries the saturated brand glow; on throttled stages
            // (no under-wash) it leans brighter so presence never collapses.
            let bodyBase = dark ? (throttled ? 0.54 : 0.42) : 0.26
            let bodyA = clampD(bodyBase * (0.5 + g), 0, dark ? 0.74 : 0.50)
            // frost-blue/white core sheen — small untinted white-blue cap drawn over
            // the colored body so the very center stays icy (richer on dark).
            let coreSheenA = dark ? clampD(0.34 * (0.45 + g), 0, 0.6)
                                  : clampD(0.13 * (0.4 + g), 0, 0.22)

            xs.append(Crystal(x: x, y: y, grow: grow, g: g, frost: frost, glow: glow,
                              bodyTint: bodyTint, radius: radius, baseRot: spin + seed * TAU,
                              seed: seed, seed2: seed2, br: br, bodyA: bodyA, coreSheenA: coreSheenA))
        }

        // ── 0. DEEP GAUSSIAN UNDER-WASH (dark, premium presence) ─────────────────
        // One blurred additive layer of accent-biased icy discs → the whole
        // silhouette glows as a single cohesive frost field. Heaviest pass; dropped
        // when throttled, where the cached sprite bloom alone still reads richly.
        if dark, !throttled {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: sizePx * 2.4))
                layer.blendMode = .plusLighter
                for c in xs {
                    let r = (sizePx * 2.0 + c.radius * 0.40) * (0.7 + 0.3 * c.grow)
                    let a = clampD(0.44 * c.g, 0, 0.7)
                    layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                      width: r * 2, height: r * 2)),
                               with: .color(c.glow.withOpacity(a).color))
                }
            }
        }

        // ── 1. body bloom — cached frost sprite tinted to the dot's brand color ──
        // colorMultiply turns the bright white-blue sprite into a brand-hued glow
        // (the "brand-tinted glow"); a smaller untinted white-blue cap on top keeps
        // the very center a frost-blue/white core. Two cheap sprite draws per dot.
        for c in xs {
            var gc = ctx
            gc.opacity = c.bodyA
            gc.addFilter(.colorMultiply(c.bodyTint.color))
            gc.draw(bloom, in: CGRect(x: c.x - c.br, y: c.y - c.br,
                                      width: c.br * 2, height: c.br * 2))

            var wc = ctx
            wc.opacity = c.coreSheenA
            let wr = c.br * 0.42
            wc.draw(bloom, in: CGRect(x: c.x - wr, y: c.y - wr,
                                      width: wr * 2, height: wr * 2))
        }

        // ── 2. six feathery dendrite spines (batched by alpha × width-group) ─────
        let bins = 4
        let widths: [Double] = [1.5, 0.9, 0.4, 0.55] // spine0, spine1, spine2, branches
        var armPaths = [[Path]](repeating: [Path(), Path(), Path(), Path()], count: bins)
        var binR = [Double](repeating: 0, count: bins)
        var binG = [Double](repeating: 0, count: bins)
        var binB = [Double](repeating: 0, count: bins)
        var binA = [Double](repeating: 0, count: bins)
        var binN = [Int](repeating: 0, count: bins)
        let armAlphaBase = dark ? 0.40 : 0.30

        // batched glint crosses (dark, brightest seeds), near-white + additive.
        var glintPath = Path()
        var glintA = 0.0
        var glintN = 0

        struct Core { let x, y, r: Double; let rgba: RGBA }
        var cores = [Core](); cores.reserveCapacity(count)

        for (i, c) in xs.enumerated() {
            let x = c.x, y = c.y, grow = c.grow, g = c.g
            let radius = c.radius, baseRot = c.baseRot, seed = c.seed, seed2 = c.seed2

            let armAlpha = clampD(armAlphaBase * g, 0, 0.66)
            if armAlpha > 0.01, radius > sizePx * 0.55 {
                let bin = min(bins - 1, Int(armAlpha / 0.66 * Double(bins)))
                let r0 = radius * grow
                for a in 0..<6 {
                    let jitter = (shash(Double(i) * 3.1 + Double(a) * 1.7) - 0.5) * 0.18
                    let ang = baseRot + (Double(a) / 6.0) * TAU + jitter
                    let ca = cos(ang), sa = sin(ang)
                    let x45 = x + ca * r0 * 0.45, y45 = y + sa * r0 * 0.45
                    let x78 = x + ca * r0 * 0.78, y78 = y + sa * r0 * 0.78
                    let x100 = x + ca * r0, y100 = y + sa * r0
                    armPaths[bin][0].move(to: CGPoint(x: x, y: y))
                    armPaths[bin][0].addLine(to: CGPoint(x: x45, y: y45))
                    armPaths[bin][1].move(to: CGPoint(x: x45, y: y45))
                    armPaths[bin][1].addLine(to: CGPoint(x: x78, y: y78))
                    armPaths[bin][2].move(to: CGPoint(x: x78, y: y78))
                    armPaths[bin][2].addLine(to: CGPoint(x: x100, y: y100))
                    // two short forward side-branches, symmetric ±.
                    let perpC = -sa, perpS = ca, fwd = 0.5
                    for bI in 0..<2 {
                        let along = (bI == 0 ? 0.42 : 0.66) * r0
                        let bx = x + ca * along, by = y + sa * along
                        let blen = r0 * (0.2 - Double(bI) * 0.06) * (0.7 + seed2 * 0.6)
                        armPaths[bin][3].move(to: CGPoint(x: bx, y: by))
                        armPaths[bin][3].addLine(to: CGPoint(
                            x: bx + (perpC * 0.83 + ca * fwd) * blen,
                            y: by + (perpS * 0.83 + sa * fwd) * blen))
                        armPaths[bin][3].move(to: CGPoint(x: bx, y: by))
                        armPaths[bin][3].addLine(to: CGPoint(
                            x: bx + (-perpC * 0.83 + ca * fwd) * blen,
                            y: by + (-perpS * 0.83 + sa * fwd) * blen))
                    }
                }
                binR[bin] += c.frost.r; binG[bin] += c.frost.g; binB[bin] += c.frost.b
                binA[bin] += armAlpha; binN[bin] += 1
            }

            // ── 3. bright frozen core — the legible silhouette point ────────────
            let coreA = clampD((dark ? 0.94 : 0.96) * f * (0.7 + 0.3 * g), 0, 1)
            let fr = c.frost.r, fg = c.frost.g, fb = c.frost.b
            let coreCol: RGBA = dark
                ? RGBA(r: fr + (1 - fr) * 0.55, g: fg + (1 - fg) * 0.55,
                       b: fb + (1 - fb) * 0.50, a: coreA)
                : frame.dots[i].rgba.withOpacity(coreA)
            cores.append(Core(x: x, y: y, r: max(0.9, sizePx * 0.7), rgba: coreCol))

            // ── 4. frost glint for the brightest seeds (dark only) ──────────────
            if dark, seed > 0.86 {
                let tw = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 2.2 + seed * 31)
                let len = sizePx * (1.7 + 1.5 * tw)
                let ga = baseRot * 0.5
                let cga = cos(ga), sga = sin(ga)
                let cga2 = cos(ga + .pi / 2), sga2 = sin(ga + .pi / 2)
                glintPath.move(to: CGPoint(x: x - cga * len, y: y - sga * len))
                glintPath.addLine(to: CGPoint(x: x + cga * len, y: y + sga * len))
                glintPath.move(to: CGPoint(x: x - cga2 * len, y: y - sga2 * len))
                glintPath.addLine(to: CGPoint(x: x + cga2 * len, y: y + sga2 * len))
                glintA += clampD(0.34 * g * (0.4 + tw), 0, 0.55)
                glintN += 1
            }
        }

        // ── batched arm strokes: ≤ bins × 4 strokes total ───────────────────────
        for bin in 0..<bins where binN[bin] > 0 {
            let n = Double(binN[bin])
            let col = RGBA(r: binR[bin] / n, g: binG[bin] / n, b: binB[bin] / n, a: binA[bin] / n)
            let shading = GraphicsContext.Shading.color(col.color)
            for wg in 0..<4 {
                ctx.stroke(armPaths[bin][wg], with: shading,
                           style: StrokeStyle(lineWidth: widths[wg], lineCap: .round, lineJoin: .round))
            }
        }

        // ── cores on top ────────────────────────────────────────────────────────
        for core in cores {
            ctx.fill(Path(ellipseIn: CGRect(x: core.x - core.r, y: core.y - core.r,
                                            width: core.r * 2, height: core.r * 2)),
                     with: .color(core.rgba.color))
        }

        // ── one batched glint stroke (near-white) ───────────────────────────────
        if glintN > 0 {
            ctx.stroke(glintPath,
                       with: .color(Color(red: 244.0 / 255, green: 250.0 / 255, blue: 1.0)
                           .opacity(glintA / Double(glintN))),
                       style: StrokeStyle(lineWidth: 0.7, lineCap: .round, lineJoin: .round))
        }

        return true
    }
}

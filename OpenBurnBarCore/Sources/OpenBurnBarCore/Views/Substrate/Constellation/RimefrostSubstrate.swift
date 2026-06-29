import SwiftUI

/// Dendritic Frost — faithful port of imaginethat `constellation/rimefrost.ts`
/// drawBody (L81–274, held "melt 0" look).
///
/// Each silhouette point nucleates a six-armed rime crystal. Per crystal, in
/// z-order: (1) a cached 48px white-blue radial frost-bloom anchoring the center;
/// (2) six feathery dendrite spines (3 tapering segments 1.5→0.9→0.4 each, plus
/// two short forward side-branches) stroked in a low-alpha ice tint; (3) a bright
/// frozen core marking the exact logo point; (4) for the brightest seeds (>0.86)
/// a pure-white twinkling glint cross (dark only). Crystals "grow & melt" on a
/// slow `sin(0.5·t + seed·TAU + posPhase)` wave so the cloud crystallizes in soft
/// travelling waves, under an imperceptible global rotation (`t·0.03`). Per-point
/// brand colors are lifted 55/55/60% toward ice (224,238,255); the core is
/// whitened a further 45/45/40% on dark, raw brand on light.
///
/// Perf: the ~60 line-segments-per-crystal dendrite field would be ruinous to
/// stroke individually for ~1k points, so arms are batched into ONE Path per
/// (alpha-bin × spine-width-group) and stroked a fixed ≤16 times per frame; the
/// glint crosses batch into a single white stroke. The frost-bloom is a cached
/// sprite (resolved once, drawn many), cores stay cheap circles. Honors
/// `frame.dark` (additive `.plusLighter` vs source-over), `frame.reduced` (a
/// poised, mostly-grown still frost-field), and `frame.batteryThrottled` (drops
/// the bloom halo + glint passes). The meltwater beads are destruction-only and
/// omitted from the held look.
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

        // assembly gain — fade the crystal field in as the mark forms.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.45 + 0.55

        // cap arm length below inter-point spacing so feathering never smears.
        let spacing = frame.R / max(2.0, sqrt(Double(count)))
        let armCap = clampD(spacing * 0.42, sizePx * 2.4, sizePx * 6)
        let armMin = clampD(spacing * 0.16, sizePx * 1.2, armCap)
        // imperceptible global rotation of the whole field.
        let spin = reduced ? 0.0 : t * 0.03

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // cached white-blue frost-bloom sprite (resolved once; drawn many).
        let bloom: GraphicsContext.ResolvedImage? = throttled ? nil : ctx.resolve(
            sprites.radial(diameter: 48, stops: [
                (0.0, RGBA(r: 232.0 / 255, g: 244.0 / 255, b: 1.0, a: 1.0)),
                (0.28, RGBA(r: 206.0 / 255, g: 228.0 / 255, b: 1.0, a: 0.5)),
                (0.6, RGBA(r: 180.0 / 255, g: 212.0 / 255, b: 1.0, a: 0.12)),
                (1.0, RGBA(r: 180.0 / 255, g: 212.0 / 255, b: 1.0, a: 0.0)),
            ]))

        // ice target the per-point brand color is lifted toward.
        let iceR = 224.0 / 255, iceG = 238.0 / 255, iceB = 1.0

        // batched dendrite arms: bin by alpha, split by spine-width-group so a
        // single uniform stroke per bucket reproduces the taper + per-point glow.
        let bins = 4
        let widths: [Double] = [1.5, 0.9, 0.4, 0.55] // spine0, spine1, spine2, branches
        var armPaths = [[Path]](repeating: [Path(), Path(), Path(), Path()], count: bins)
        var binR = [Double](repeating: 0, count: bins)
        var binG = [Double](repeating: 0, count: bins)
        var binB = [Double](repeating: 0, count: bins)
        var binA = [Double](repeating: 0, count: bins)
        var binN = [Int](repeating: 0, count: bins)
        let armAlphaBase = dark ? 0.34 : 0.26

        // batched glint crosses (dark, brightest seeds), white + additive.
        var glintPath = Path()
        var glintA = 0.0
        var glintN = 0

        // cores deferred so they paint on top of the arms on light stages.
        struct Core { let x, y, r: Double; let rgba: RGBA }
        var cores = [Core](); cores.reserveCapacity(count)

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

            // frost tint: lift the brand color toward white-blue ice.
            let c = d.rgba
            let fr = c.r + (iceR - c.r) * 0.55
            let fg = c.g + (iceG - c.g) * 0.55
            let fb = c.b + (iceB - c.b) * 0.60

            let radius = lerp(armMin, armCap, 0.45 + seed2 * 0.55) * (0.6 + 0.4 * grow)
            let baseRot = spin + seed * TAU

            // ── 1. soft frost-bloom under the center ───────────────────────────
            if let bloom {
                let br = (sizePx * 2.6 + radius * 0.5) * (0.7 + 0.3 * grow)
                var gc = ctx
                gc.opacity = clampD((dark ? 0.16 : 0.1) * (0.5 + g), 0, 0.4)
                gc.draw(bloom, in: CGRect(x: x - br, y: y - br, width: br * 2, height: br * 2))
            }

            // ── 2. six feathery dendrite spines (accumulate into batched paths) ─
            let armAlpha = clampD(armAlphaBase * g, 0, 0.6)
            if armAlpha > 0.01, radius > sizePx * 0.6 {
                let bin = min(bins - 1, Int(armAlpha / 0.6 * Double(bins)))
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
                binR[bin] += fr; binG[bin] += fg; binB[bin] += fb
                binA[bin] += armAlpha; binN[bin] += 1
            }

            // ── 3. bright frozen core — the legible silhouette point ────────────
            let coreA = clampD((dark ? 0.92 : 0.96) * f * (0.7 + 0.3 * g), 0, 1)
            let coreCol: RGBA = dark
                ? RGBA(r: fr + (1 - fr) * 0.45, g: fg + (1 - fg) * 0.45,
                       b: fb + (1 - fb) * 0.40, a: coreA)
                : c.withOpacity(coreA)
            cores.append(Core(x: x, y: y, r: max(0.85, sizePx * 0.66), rgba: coreCol))

            // ── 4. frost glint for the brightest seeds (dark only) ──────────────
            if dark, !throttled, seed > 0.86 {
                let tw = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 2.2 + seed * 31)
                let len = sizePx * (1.6 + 1.4 * tw)
                let ga = baseRot * 0.5
                let cga = cos(ga), sga = sin(ga)
                let cga2 = cos(ga + .pi / 2), sga2 = sin(ga + .pi / 2)
                glintPath.move(to: CGPoint(x: x - cga * len, y: y - sga * len))
                glintPath.addLine(to: CGPoint(x: x + cga * len, y: y + sga * len))
                glintPath.move(to: CGPoint(x: x - cga2 * len, y: y - sga2 * len))
                glintPath.addLine(to: CGPoint(x: x + cga2 * len, y: y + sga2 * len))
                glintA += clampD(0.3 * g * (0.4 + tw), 0, 0.5)
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

import SwiftUI
import Foundation

/// Lattice Facet — ported from imaginethat `glyph/stage/styles/moire/lattice-facet.ts`.
///
/// A breathing crystal lattice. Each silhouette point is a small **opaque faceted
/// pentagon gem cell** tiled on the mark's coordinates. A KEY LIGHT direction
/// rotates one way (`lightA = t·0.18`) while an offset virtual-lattice phase drifts
/// the OTHER way (`latPhase = -t·0.42`); where the two slightly-detuned lattice
/// projections (freqA 9.5 / freqB 8.2) beat together AND a facet faces the light,
/// the cell catches a bright glint — so a diagonal ribbon of lit facets marches
/// across the solid mark as a faceted moiré while the whole lattice inhales ±3%.
///
/// Two passes, faithful to the source compositing:
///   • PASS 1 — opaque gem bodies, `.normal` (source-over) on **both** stages (a
///     solid crystal is never a bloom). Each cell is one closed pentagon filled
///     with a cross-facet linear gradient along the pseudo-normal (dark cut → gem
///     body → lit edge) plus a thin dark edge stroke (the cut).
///   • PASS 2 — specular white triangles on lit facets, `.plusLighter` on dark /
///     `.normal` on light.
///
/// Per-point color = `dots[i].rgba`, pushed toward white for the three gem tones
/// (no stage.accent — only `stage.dark` sets the shadow floor + glint blend). The
/// gem bodies own the silhouette opaquely, so glyph particles still draw on top.
public final class LatticeFacetSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    /// One precomputed per-cell crystal descriptor, shared across the bloom /
    /// body / specular passes so the moiré math (facet normal, lit band, gem
    /// tones) is evaluated exactly once per frame, not three times.
    private struct Cell {
        var x: Double; var y: Double
        var cosN: Double; var sinN: Double   // facet pseudo-normal (the "cut" axis)
        var ca: Double; var sa: Double        // per-cell pentagon spin
        var lit: Double; var litQ: Double     // raw + quantized facet brightness
        var facing: Double; var band: Double
        var spec: Double                      // specular strength on the lit ribbon
        var col: RGBA                         // brand point color
        var jit: Double
    }
    private var cells: [Cell] = []

    /// Unit pentagon corner directions (cos/sin), pointing "up" (−90°) so the flat
    /// table sits low like a cut gem. Precomputed once; scaled+spun per cell.
    private let pent: [(cx: Double, cy: Double)] = {
        let sides = 5
        var out: [(Double, Double)] = []
        out.reserveCapacity(sides)
        for k in 0..<sides {
            let a = -Double.pi / 2 + (Double(k) / Double(sides)) * TAU
            out.append((cos(a), sin(a)))
        }
        return out
    }()

    public init() {}

    public func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        let radius = frame.cloudRadius
        guard count > 0, radius > 0 else { return false }

        let dark = frame.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let cx = frame.cx, cy = frame.cy
        let sizePx = frame.sizePx
        let accent = frame.stage.accent

        // assembly reveal — cells grow into place as the cloud forms.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1)
        let reveal = 0.25 + 0.75 * form

        // resting clock: KEY LIGHT rotates one way; offset-lattice phase drifts the
        // OTHER way → the lit-facet ribbon marches across the mark (the moiré).
        let lightA = reduced ? -0.7 : frame.t * 0.18
        let latPhase = reduced ? 1.1 : -frame.t * 0.42
        // whole-lattice "inhale": ±3% slow sine.
        let inhale = reduced ? 1.0 : 1.0 + 0.03 * sin(frame.t * 0.7)
        let lx = cos(lightA), ly = sin(lightA)

        // gem radius — clamped so cells never bloat across negative space. Nudged a
        // touch larger than the source so the faceted crust reads as a continuous
        // luminous lattice rather than scattered confetti.
        let rad = clampD(sizePx * 1.7, 1.5, radius * 0.06) * reveal
        let r = rad * inhale
        guard r > 0.01 else { return true }

        // moiré carrier frequencies (cloud-normalized). The slight detune is what
        // makes the bright band a moiré, not a plain sweep.
        let freqA = 9.5, freqB = 8.2
        let invR = radius > 0 ? 1.0 / radius : 0

        let edgeAlpha = dark ? 0.55 : 0.34

        // ── precompute every cell's crystal state once (shared by all passes) ───
        cells.removeAll(keepingCapacity: true)
        cells.reserveCapacity(count)
        for i in 0..<count {
            let d = frame.dots[i]
            let sd = shash(Double(i) * 1.731 + 0.37)
            // stable facet pseudo-normal: coarse 8-way orientation + per-cell jitter.
            let na = (floor(sd * 8) / 8) * TAU + (sd - 0.5) * 0.9
            let spin = sd * TAU
            let jit = shash(Double(i) * 2.91 + 1.13)
            let ux = (d.x - cx) * invR, uy = (d.y - cy) * invR
            let latA = ux * freqA + uy * (freqA * 0.18)
            let latB = ux * (freqB * 0.16) + uy * freqB
            let cosN = cos(na), sinN = sin(na)
            let facing = cosN * lx + sinN * ly                  // −1…1
            let band = 0.5 + 0.5 * sin(latA + latPhase) * sin(latB - latPhase)
            let lit = clampD(0.5 + 0.5 * facing, 0, 1) * (0.45 + 0.55 * band)
            // Quantize lit into 4 buckets so the gem tones snap to a few stable
            // levels — a low-poly faceted crust, not a per-cell gradient smear.
            let litQ = min(3.0, floor(lit * 4.0)) / 3.0   // 0, ⅓, ⅔, 1
            let spec = facing > 0.2 ? clampD((facing - 0.2) / 0.8, 0, 1) * band : 0
            cells.append(Cell(x: d.x, y: d.y, cosN: cosN, sinN: sinN,
                              ca: cos(spin), sa: sin(spin),
                              lit: lit, litQ: litQ, facing: facing, band: band,
                              spec: spec, col: d.rgba, jit: jit))
        }

        var ctx = ctx

        // shared facet geometry constants (kept inside the pentagon so wedges never
        // spike past the silhouette edge).
        let nOut = r * 0.80, baseHalf = r * 0.6, baseBack = r * 0.05
        let edgeWidth = max(0.6, r * 0.13)

        // ── PASS 0: REAL Gaussian under-bloom — the silhouette glows ────────────
        // Soft colored halos, blurred into one transparency layer, then composited
        // additively on dark (a luminous crystal crust) / as a subtle accent wash
        // on light (depth without blowing out the page). Heaviest pass → dropped
        // first under battery throttle. This is what kills the "flat dots" read.
        if !throttled {
            let bloomR = max(2.0, r * 1.25)
            let rg = r * 1.95
            ctx.blendMode = dark ? .plusLighter : .normal
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: bloomR))
                layer.blendMode = dark ? .plusLighter : .normal
                for c in cells {
                    // glow tone: brand color leaning toward the stage accent, lifted
                    // toward white on the lit ribbon for a hot core under the gem.
                    let base = c.col.mix(with: accent, amount: 0.32)
                    let glow = base.toWhite(0.12 + 0.5 * c.litQ)
                    let a = dark
                        ? clampD(0.16 + 0.62 * c.lit, 0, 0.85)
                        : clampD(0.07 + 0.16 * c.lit, 0, 0.34)
                    let disc = Path(ellipseIn: CGRect(x: c.x - rg, y: c.y - rg,
                                                      width: rg * 2, height: rg * 2))
                    layer.fill(disc, with: .color(glow.withOpacity(a).color))
                }
            }
        }

        // ── PASS 1: opaque faceted gem bodies (the cut crystal) ─────────────────
        // source-over on BOTH stages (a solid crystal is never a bloom). Each cell:
        //   dark-cut facet  →  mid body  →  lit top facet, plus a crisp cut stroke
        //   and a bright edge glint on lit cells. Three quantized tones = a visibly
        //   faceted low-poly gem, never a flat disc.
        ctx.blendMode = .normal
        for c in cells {
            let x = c.x, y = c.y
            let col = c.col
            let shadow = RGBA(r: col.r * 0.30 + 6.0 / 255,
                              g: col.g * 0.30 + 6.0 / 255,
                              b: col.b * 0.34 + 10.0 / 255)
            let body = col.toWhite(0.20 + 0.30 * c.litQ + 0.10 * c.jit)
            let top  = col.toWhite(0.48 + 0.50 * c.litQ)

            // pentagon outline, spun per cell so the lattice reads as cut crystal.
            let ca = c.ca, sa = c.sa
            var path = Path()
            for k in 0..<pent.count {
                let px = pent[k].cx, py = pent[k].cy
                let vx = (px * ca - py * sa) * r
                let vy = (px * sa + py * ca) * r
                if k == 0 { path.move(to: CGPoint(x: x + vx, y: y + vy)) }
                else { path.addLine(to: CGPoint(x: x + vx, y: y + vy)) }
            }
            path.closeSubpath()

            // 1) opaque body fill (owns the silhouette).
            ctx.fill(path, with: .color(body.color))

            // facet axes: pseudo-normal = the cut direction; perp = the base line.
            let cosN = c.cosN, sinN = c.sinN
            let perpX = -sinN, perpY = cosN

            // 2) SHADOW facet — a wedge on the side turned away from the light. This
            //    is the dark "cut" that gives the gem real depth (restored).
            var shadowFacet = Path()
            shadowFacet.move(to: CGPoint(x: x - cosN * nOut, y: y - sinN * nOut))
            shadowFacet.addLine(to: CGPoint(x: x + perpX * baseHalf + cosN * baseBack,
                                            y: y + perpY * baseHalf + sinN * baseBack))
            shadowFacet.addLine(to: CGPoint(x: x - perpX * baseHalf + cosN * baseBack,
                                            y: y - perpY * baseHalf + sinN * baseBack))
            shadowFacet.closeSubpath()
            ctx.fill(shadowFacet, with: .color(shadow.color))

            // 3) TOP facet — the lit wedge toward the light. Brightest tone on top.
            var topFacet = Path()
            let topApex = CGPoint(x: x + cosN * nOut, y: y + sinN * nOut)
            let topB1 = CGPoint(x: x + perpX * baseHalf - cosN * baseBack,
                                y: y + perpY * baseHalf - sinN * baseBack)
            let topB2 = CGPoint(x: x - perpX * baseHalf - cosN * baseBack,
                                y: y - perpY * baseHalf - sinN * baseBack)
            topFacet.move(to: topApex)
            topFacet.addLine(to: topB1)
            topFacet.addLine(to: topB2)
            topFacet.closeSubpath()
            ctx.fill(topFacet, with: .color(top.color))

            // 4) the cut — a thin dark edge stroke pinning the cell silhouette.
            ctx.stroke(path,
                       with: .color(shadow.withOpacity(edgeAlpha).color),
                       style: StrokeStyle(lineWidth: edgeWidth, lineJoin: .round))

            // 5) bright edge GLINT on the two lit top-facet edges (lit cells only) —
            //    the crisp catch of light along the cut, dropped under throttle.
            if !throttled && c.lit > 0.34 {
                let glint = col.toWhite(0.86)
                var edge = Path()
                edge.move(to: topB1)
                edge.addLine(to: topApex)
                edge.addLine(to: topB2)
                ctx.stroke(edge,
                           with: .color(glint.withOpacity(0.35 + 0.5 * c.lit).color),
                           style: StrokeStyle(lineWidth: max(0.6, r * 0.10),
                                              lineCap: .round, lineJoin: .round))
            }
        }

        // ── PASS 2: specular hot glints riding the moiré ribbon ─────────────────
        // Dark: a cached white-glow sprite (soft hot core, additive) UNDER a crisp
        // white triangle. Light: just the crisp soft triangle (.plusLighter would
        // blow out the page). The sprite bloom is the throttle-droppable extra.
        ctx.blendMode = dark ? .plusLighter : .normal
        let glowSprite = (dark && !throttled) ? ctx.resolve(sprites.whiteGlow(diameter: 48)) : nil
        let specColor: Color = dark ? .white : Color(red: 252.0 / 255, green: 253.0 / 255, blue: 1.0)
        let sr = r * 0.58
        for c in cells {
            let spec = c.spec
            if spec <= 0.05 { continue }
            let x = c.x, y = c.y
            let cosN = c.cosN, sinN = c.sinN
            let perpX = -sinN, perpY = cosN
            // glint sits on the lit edge of the top facet.
            let ex = x + cosN * r * 0.46
            let ey = y + sinN * r * 0.46

            // soft hot core (cached sprite, additive) — the bloom under the glint.
            if let glow = glowSprite {
                let gr = r * (1.1 + 1.3 * spec)
                var sctx = ctx
                sctx.opacity = clampD(0.30 + 0.55 * spec, 0, 0.95)
                sctx.draw(glow, in: CGRect(x: ex - gr, y: ey - gr, width: gr * 2, height: gr * 2))
            }

            // crisp specular triangle near the lit edge — the sharp catch.
            var tri = Path()
            tri.move(to: CGPoint(x: ex + cosN * sr * 0.5, y: ey + sinN * sr * 0.5))
            tri.addLine(to: CGPoint(x: ex + perpX * sr * 0.42 - cosN * sr * 0.28,
                                    y: ey + perpY * sr * 0.42 - sinN * sr * 0.28))
            tri.addLine(to: CGPoint(x: ex - perpX * sr * 0.42 - cosN * sr * 0.28,
                                    y: ey - perpY * sr * 0.42 - sinN * sr * 0.28))
            tri.closeSubpath()
            let alpha = clampD((dark ? 0.70 : 0.46) * spec, 0, 0.92)
            ctx.fill(tri, with: .color(specColor.opacity(alpha)))
        }

        return true
    }
}

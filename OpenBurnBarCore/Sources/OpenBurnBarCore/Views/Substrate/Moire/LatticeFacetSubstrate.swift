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

    /// Opt-in nicety: render each gem body with a per-cell cross-facet
    /// `Gradient` along the pseudo-normal. OFF by default — at this style's
    /// 2–4k pentagon cells that is one `Gradient(stops:)` allocation + one
    /// `.linearGradient` Shading resolve *per cell, per frame*, exactly the
    /// "never build a gradient per dot" cost the contract forbids. The default
    /// path uses allocation-free quantized flat fills + a directional top-facet
    /// wedge, which preserves the faceted "cut" look at 60fps.
    private let useCrossFacetGradient = false

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

        // gem radius — clamped so cells never bloat across negative space.
        let rad = clampD(sizePx * 1.55, 1.3, radius * 0.055) * reveal
        let r = rad * inhale
        guard r > 0.01 else { return true }

        // moiré carrier frequencies (cloud-normalized). The slight detune is what
        // makes the bright band a moiré, not a plain sweep.
        let freqA = 9.5, freqB = 8.2
        let invR = radius > 0 ? 1.0 / radius : 0

        let sh = dark ? 0.34 : 0.5             // shadow floor (solid silhouette on light)
        let edgeAlpha = (dark ? 0.5 : 0.34)
        let specBlend: GraphicsContext.BlendMode = dark ? .plusLighter : .normal
        let specColor: Color = dark ? .white : Color(red: 252.0 / 255, green: 253.0 / 255, blue: 1.0)

        // gradient direction unit vectors along the per-cell pseudo-normal.
        var ctx = ctx
        ctx.blendMode = .normal

        // ── PASS 1: opaque faceted gem bodies + cut edge ────────────────────────
        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y

            // stable facet pseudo-normal: coarse 8-way orientation + per-cell jitter.
            let sd = shash(Double(i) * 1.731 + 0.37)
            let na = (floor(sd * 8) / 8) * TAU + (sd - 0.5) * 0.9
            let spin = sd * TAU
            let jit = shash(Double(i) * 2.91 + 1.13)

            // two lattice projections at a few degrees' offset — their beat is the band.
            let ux = (x - cx) * invR, uy = (y - cy) * invR
            let latA = ux * freqA + uy * (freqA * 0.18)
            let latB = ux * (freqB * 0.16) + uy * freqB

            // facet brightness = dot(normal, light), biased by the offset-lattice
            // phase so lit cells fall on a marching diagonal band (the moiré).
            let cosN = cos(na), sinN = sin(na)
            let facing = cosN * lx + sinN * ly                      // −1…1
            let band = 0.5 + 0.5 * sin(latA + latPhase) * sin(latB - latPhase)
            let lit = clampD(0.5 + 0.5 * facing, 0, 1) * (0.45 + 0.55 * band)
            // Quantize lit into 4 buckets so the gem tones snap to a few stable
            // levels — this is what lets the body/top fills stay flat (no per-cell
            // gradient) while the cells still read as a low-poly faceted crust.
            let litQ = min(3.0, floor(lit * 4.0)) / 3.0   // 0, ⅓, ⅔, 1

            // gem tones from the brand point color: dark cut, mid body, lit top.
            let col = d.rgba
            let shadow = RGBA(r: col.r * 0.3 + 6.0 / 255,
                              g: col.g * 0.3 + 6.0 / 255,
                              b: col.b * 0.34 + 10.0 / 255)
            let body = col.toWhite(0.18 + 0.34 * litQ + 0.1 * jit)
            let top = col.toWhite(0.45 + 0.5 * litQ)

            // pentagon geometry, rotated per-cell so the lattice reads as cut crystal.
            let ca = cos(spin), sa = sin(spin)
            var path = Path()
            for k in 0..<pent.count {
                let px = pent[k].cx, py = pent[k].cy
                let vx = (px * ca - py * sa) * r
                let vy = (px * sa + py * ca) * r
                if k == 0 { path.move(to: CGPoint(x: x + vx, y: y + vy)) } else { path.addLine(to: CGPoint(x: x + vx, y: y + vy)) }
            }
            path.closeSubpath()

            if useCrossFacetGradient && !throttled {
                // OPT-IN nicety only — per-cell cross-facet gradient along the
                // "cut" axis (the pseudo-normal). Allocates a Gradient + Shading
                // per cell, so it is gated off by default (see property comment).
                let gx = cosN * r, gy = sinN * r
                let stop0 = shadow.mix(with: body, amount: 1 - sh)
                let grad = Gradient(stops: [
                    .init(color: stop0.color, location: 0.0),
                    .init(color: body.color, location: 0.55),
                    .init(color: top.color, location: 1.0)
                ])
                ctx.fill(path, with: .linearGradient(
                    grad,
                    startPoint: CGPoint(x: x - gx, y: y - gy),
                    endPoint: CGPoint(x: x + gx, y: y + gy)))
            } else {
                // DEFAULT path — allocation-free. Flat (quantized) body fill, then
                // a single directional "top facet" wedge toward the lit (+normal)
                // edge so the cross-facet cut still reads as a faceted gem. No
                // Gradient/Shading is built per cell. The wedge is dropped under
                // battery throttle (flat body only).
                ctx.fill(path, with: .color(body.color))
                if !throttled && lit > 0.15 {
                    // perpendicular to the pseudo-normal, for the wedge base.
                    let perpX = -sinN, perpY = cosN
                    let apexR = r * 0.62, baseR = r * 0.5, backR = r * 0.15
                    var cap = Path()
                    cap.move(to: CGPoint(x: x + cosN * apexR, y: y + sinN * apexR))
                    cap.addLine(to: CGPoint(x: x + perpX * baseR - cosN * backR,
                                            y: y + perpY * baseR - sinN * backR))
                    cap.addLine(to: CGPoint(x: x - perpX * baseR - cosN * backR,
                                            y: y - perpY * baseR - sinN * backR))
                    cap.closeSubpath()
                    ctx.fill(cap, with: .color(top.color))
                }
            }

            // thin dark edge stroke — the cut. Pins the silhouette on either stage.
            ctx.stroke(path,
                       with: .color(shadow.withOpacity(edgeAlpha).color),
                       style: StrokeStyle(lineWidth: max(0.5, r * 0.12), lineJoin: .round))
        }

        // ── PASS 2: specular glints on lit facets ───────────────────────────────
        // (additive on dark, soft over light; skipped under battery throttle.)
        if !throttled {
            ctx.blendMode = specBlend
            let sr = r * 0.62
            let hx = cos(lightA) * sr * 0.5
            let hy = sin(lightA) * sr * 0.5
            for i in 0..<count {
                let sd = shash(Double(i) * 1.731 + 0.37)
                let na = (floor(sd * 8) / 8) * TAU + (sd - 0.5) * 0.9
                let facing = cos(na) * lx + sin(na) * ly
                if facing <= 0.2 { continue }

                let d = frame.dots[i]
                let ux = (d.x - cx) * invR, uy = (d.y - cy) * invR
                let latA = ux * freqA + uy * (freqA * 0.18)
                let latB = ux * (freqB * 0.16) + uy * freqB
                let band = 0.5 + 0.5 * sin(latA + latPhase) * sin(latB - latPhase)
                let spec = clampD((facing - 0.2) / 0.8, 0, 1) * band
                if spec <= 0.04 { continue }

                let x = d.x, y = d.y
                var tri = Path()
                tri.move(to: CGPoint(x: x + hx, y: y + hy - sr * 0.7))
                tri.addLine(to: CGPoint(x: x + hx + sr * 0.55, y: y + hy + sr * 0.45))
                tri.addLine(to: CGPoint(x: x + hx - sr * 0.55, y: y + hy + sr * 0.45))
                tri.closeSubpath()
                let alpha = clampD((dark ? 0.5 : 0.42) * spec, 0, 0.85)
                ctx.fill(tri, with: .color(specColor.opacity(alpha)))
            }
        }

        return true
    }
}

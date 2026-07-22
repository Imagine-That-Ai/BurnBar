import SwiftUI
import OpenBurnBarKernel
import CoreGraphics

/// Film Bubble — premium port of imaginethat `moire/film-bubble.ts` drawBody (L189-339).
///
/// Every silhouette point is a tiny iridescent soap bubble. Surface color comes
/// from thin-film interference: a virtual film thickness = the SUM of two slightly
/// detuned wave fields sampled in node-space (`rx,ry = x-cx, y-cy`). Because the two
/// carriers beat (rates +0.55 and -0.42, frequencies aFx/aFy vs bFx/bFy), rainbow
/// moiré sheets drift across the cluster exactly like color sweeping a real bubble.
/// Thickness → a 256-entry thin-film spectrum LUT (cyan/magenta-heavy iridescent
/// ramp, precomputed once); the rim hue is blended 62% spectrum / 38% per-point
/// brand color so the mark stays on-brand while the rainbow only RECOLORS an
/// already-complete shape.
///
/// PREMIUM build — layered, luminous depth per bubble (allocation-free hot loop;
/// per-dot values are precomputed once into reused scratch arrays):
///   1. DARK — a true GAUSSIAN bloom field (one `drawLayer` with `.blur` +
///      `.plusLighter`) lays an iridescent glow UNDER the whole cloud so it clearly
///      fills the silhouette and glows; then per bubble: a saturated colored body
///      disc → a glassy translucent sphere sprite (clear core → bright rim) → a
///      bright iridescent RIM RING (the soap-film tell, pushed toward white) → a
///      crisp white specular catchlight. The bloom is the only throttled pass.
///   2. LIGHT (`.normal`, no additive blowout) — a soft colored under-halo for
///      presence, a darkened lower-lip disc for real sphere volume, the glassy
///      sphere, a crisp saturated rim ring for edge definition, and a specular dot.
///
/// A slow lissajous micro-drift + radius wobble + the two beating waves are all
/// driven purely by `frame.t`; `reduced` pins the thickness phase to 1.7 and drops
/// drift/wobble → a poised still frozen-film frame (the bloom field stays). No wall
/// clock; no Date()/random — per-point phase is `shash(i)`.
public final class FilmBubbleSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // Reused per-dot scratch (resized only when the cloud count changes) so the
    // bloom pass and the crisp pass share one cheap precompute — no per-frame churn.
    private var pxs: [Double] = []
    private var pys: [Double] = []
    private var rads: [Double] = []
    private var rims: [RGBA] = []

    // Continuous thin-film field: a coarse canvas grid whose cells carry a low-
    // frequency iridescent thickness (the connecting "oily sheen" between bubbles),
    // modulated by a cheap splatted particle-density buffer so it INTENSIFIES under
    // clusters and feathers to nothing where the sparse swarm is absent. Reallocated
    // only when the grid dimensions change.
    private var filmDensity: [Double] = []
    private var filmGridW = 0
    private var filmGridH = 0

    // ── thin-film spectrum LUT (built once; the hot loop never touches HSL math) ──
    private static let spectrumN = 256
    private static let spectrum: [RGBA] = {
        var out = [RGBA]()
        out.reserveCapacity(spectrumN)
        for i in 0..<spectrumN {
            let u = Double(i) / Double(spectrumN)
            // thin-film hue loops with shifting saturation, heavy in cyan/magenta —
            // pushed a touch richer/brighter so the iridescence reads as luminous.
            let hue = frac(0.58 + 0.92 * u)            // start near cyan, sweep > 1 cycle
            let sat = clampD(0.62 + 0.34 * sin(u * TAU * 2 + 0.4), 0.32, 0.98)
            let lit = clampD(0.60 + 0.12 * sin(u * TAU + 1.1), 0.46, 0.80)
            let (r, g, b) = FilmBubbleSubstrate.hslToRgb(hue, sat, lit)
            out.append(RGBA(r: r, g: g, b: b, a: 1))
        }
        return out
    }()

    /// HSL → sRGB (channels 0…1). Mirrors the source `hslToRgb`.
    private static func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = frac(h) * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        if hp < 1 { r = c; g = x } else if hp < 2 { r = x; g = c } else if hp < 3 { g = c; b = x } else if hp < 4 { g = x; b = c } else if hp < 5 { r = x; b = c } else { r = c; b = x }
        let m = l - c / 2
        return (r + m, g + m, b + m)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled        // drop only the heaviest pass (the bloom field)
        let sizePx = frame.sizePx
        let t = frame.t
        let cx = frame.cx, cy = frame.cy, radius = frame.cloudRadius

        // Global film bloom-in: fades the film in as the mark forms (vis/armed fold
        // to 1 for the held substrate look). reduced → treat as fully formed.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        // Two interfering thickness wave fields. Slightly different spatial freq +
        // temporal rate → they beat, rolling rainbow moiré bands across the cluster.
        let invR = 1 / max(1, radius)
        let tt = reduced ? 1.7 : t                // frozen-but-pretty phase under reduced motion
        let aFx = 2.1 * invR
        let aFy = 1.3 * invR
        let bFx = 2.55 * invR                     // detuned → moiré
        let bFy = 1.05 * invR
        let aRate = 0.55
        let bRate = -0.42
        // Extra LOW-frequency octave — long wavelength so its hue sweeps slowly across
        // the whole canvas, giving the continuous film a single connected iridescent
        // sheen (rather than per-cell confetti) that the two faster carriers ripple over.
        let cFx = 0.78 * invR
        let cFy = 0.55 * invR
        let cRate = 0.21
        let specN = Double(Self.spectrumN)

        // ── pass 0: precompute drift, radius + iridescent rim hue per bubble once ──
        if pxs.count != count {
            pxs = .init(repeating: 0, count: count)
            pys = .init(repeating: 0, count: count)
            rads = .init(repeating: 0, count: count)
            rims = .init(repeating: RGBA(r: 1, g: 1, b: 1), count: count)
        }
        for i in 0..<count {
            let d = frame.dots[i]
            let px = d.x, py = d.y
            let seed = shash(Double(i) * 1.37 + 0.5)

            // surface-tension micro-drift on a slow lissajous (±~1px) + radius wobble.
            var dxo = 0.0, dyo = 0.0, wob = 1.0
            if !reduced {
                let ph = seed * TAU
                dxo = sin(t * 0.6 + ph) * 0.9
                dyo = sin(t * 0.47 + ph * 1.7 + 1.3) * 0.9
                wob = 0.9 + 0.12 * sin(t * 1.3 + ph * 2.3)
            }

            // virtual film thickness = sum of two detuned waves (the beating pair).
            let rx = px - cx, ry = py - cy
            let thick = sin(rx * aFx + ry * aFy * 0.6 + tt * aRate)
                + sin(rx * bFx * 0.7 + ry * bFy + tt * bRate + seed * 1.1)
            let u = frac(thick * 0.25 + 0.5)
            let si = min(Self.spectrumN - 1, max(0, Int(u * specN)))

            // rim hue: 62% iridescent spectrum / 38% per-point brand color so the
            // mark stays on-brand and legible while the rainbow only recolors it.
            pxs[i] = px + dxo
            pys[i] = py + dyo
            rads[i] = max(0.6, sizePx * 2.5 * wob * (0.74 + 0.26 * f))
            rims[i] = d.rgba.mix(with: Self.spectrum[si], amount: 0.62)
        }

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Cached sprites resolved ONCE per frame, drawn many. Sphere: clear core →
        // bright iridescent-able rim → clear (white glass body, tinted from beneath).
        // Spec: crisp white catchlight with a hot center for sparkle.
        let sphereImg = ctx.resolve(sprites.radial(diameter: 64, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.05)),
            (0.42, RGBA(r: 1, g: 1, b: 1, a: 0.12)),
            (0.74, RGBA(r: 1, g: 1, b: 1, a: 0.42)),
            (0.92, RGBA(r: 1, g: 1, b: 1, a: 0.95)),   // bright iridescent rim
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))
        let specImg = ctx.resolve(sprites.radial(diameter: 32, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.34, RGBA(r: 1, g: 1, b: 1, a: 0.78)),
            (0.7, RGBA(r: 1, g: 1, b: 1, a: 0.22)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))

        // On the full-bleed Atelier backdrop the swarm is SPARSE and free (no shape
        // target): without a connecting material the bubbles read as disconnected
        // specks on near-black. Detect that regime and (a) lay a continuous iridescent
        // thin-film under everything, (b) lift the bloom ~1.5× so the field glows.
        let sparse = !frame.isShapeMode

        // ── continuous thin-film density grid (sparse regime only) ─────────────────
        // Coarse canvas grid; each dot splats a small falloff into its 3×3 neighbours.
        // Cell size is bounded in absolute screen px (never cloudRadius) so a wide
        // sparse field keeps the same fine film as a thumbnail.
        let cell = clampD(sizePx * 17, 30, 56)
        let invCell = 1.0 / cell
        if sparse && !lite {
            let gw = max(2, Int((frame.size.width * invCell).rounded(.up)) + 1)
            let gh = max(2, Int((frame.size.height * invCell).rounded(.up)) + 1)
            if filmGridW != gw || filmGridH != gh {
                filmGridW = gw; filmGridH = gh
                filmDensity = .init(repeating: 0, count: gw * gh)
            } else {
                for k in 0..<filmDensity.count { filmDensity[k] = 0 }
            }
            for d in frame.dots {
                let gx = d.x * invCell, gy = d.y * invCell
                let ci = min(gw - 1, max(0, Int(gx)))
                let cj = min(gh - 1, max(0, Int(gy)))
                var jj = max(0, cj - 1)
                while jj <= min(gh - 1, cj + 1) {
                    var ii = max(0, ci - 1)
                    while ii <= min(gw - 1, ci + 1) {
                        let ddx = Double(ii) + 0.5 - gx
                        let ddy = Double(jj) + 0.5 - gy
                        let w = 1.0 - (ddx * ddx + ddy * ddy) * 0.55
                        if w > 0 { filmDensity[jj * gw + ii] += w }
                        ii += 1
                    }
                    jj += 1
                }
            }
        }

        // ── BLOOM FIELD (the biggest premium lever) ───────────────────────────────
        // One real Gaussian-blurred layer of iridescent cores → a luminous haze that
        // fills the silhouette and glows. Dark: additive `.plusLighter`. Light: a
        // gentle `.normal` colored halo for presence (never blown out). At sparse
        // density the same layer first paints the connected thin-film sheet (cells
        // smear together under the blur), then the bubble cores glow ~1.5× brighter.
        // Throttle drops ONLY this pass (the heaviest); everything else still reads.
        if !lite {
            let bloomBoost = sparse ? 1.5 : 1.0
            let blurScale = (dark ? 1.15 : 0.9) * (sparse ? 1.35 : 1.0)
            let haloR = dark ? 1.35 : 1.1
            let haloA = (dark ? 0.24 : 0.16) * f * bloomBoost
            // film blur is generous so neighbouring cells fuse into one oily sheet.
            let filmBlur = max(2.0, sizePx * 2.0 * blurScale + (sparse ? cell * 0.42 : 0))
            ctx.drawLayer { layer in
                layer.blendMode = dark ? .plusLighter : .normal
                layer.addFilter(.blur(radius: filmBlur))

                // (a) continuous iridescent film — one disc per occupied cell, hue from
                // the low-frequency octave + the two beating carriers, opacity feathered
                // by particle density so it fades to nothing where the swarm is absent.
                if sparse {
                    let gw = filmGridW, gh = filmGridH
                    let filmA = (dark ? 0.13 : 0.085) * f
                    let fr = cell * 0.95
                    var j = 0
                    while j < gh {
                        let cyp = (Double(j) + 0.5) * cell
                        let ry = cyp - cy
                        var i = 0
                        while i < gw {
                            let dens = filmDensity[j * gw + i]
                            if dens > 0.004 {
                                let cxp = (Double(i) + 0.5) * cell
                                let rx = cxp - cx
                                let thick = sin(rx * aFx + ry * aFy * 0.6 + tt * aRate)
                                    + sin(rx * bFx * 0.7 + ry * bFy + tt * bRate)
                                    + 0.9 * sin(rx * cFx + ry * cFy + tt * cRate)
                                let u = frac(thick * 0.16 + 0.5)
                                let si = min(Self.spectrumN - 1, max(0, Int(u * specN)))
                                let a = clampD(filmA * smoothstep(0.0, 1.5, dens), 0, dark ? 0.5 : 0.4)
                                layer.fill(
                                    Path(ellipseIn: CGRect(x: cxp - fr, y: cyp - fr, width: fr * 2, height: fr * 2)),
                                    with: .color(Self.spectrum[si].withOpacity(a).color))
                            }
                            i += 1
                        }
                        j += 1
                    }
                }

                // (b) per-bubble iridescent cores → the luminous bloom haze.
                for i in 0..<count {
                    let r = rads[i] * haloR
                    // glow leans iridescent (toward the rim hue's lit color), kept
                    // saturated so the field glows in rainbow sheets, not grey mush.
                    let glow = rims[i].withOpacity(clampD(haloA, 0, 1))
                    layer.fill(
                        Path(ellipseIn: CGRect(x: pxs[i] - r, y: pys[i] - r, width: r * 2, height: r * 2)),
                        with: .color(glow.color))
                }
            }
        }

        // ── per-bubble crisp passes (layered depth: body → glass → rim → spark) ────
        for i in 0..<count {
            let x = pxs[i], y = pys[i]
            let rad = rads[i]
            let r2 = rad
            let rim = rims[i]

            if dark {
                // (1) saturated colored BODY disc — carries the iridescent hue.
                let rc = rad * 0.95
                ctx.fill(Path(ellipseIn: CGRect(x: x - rc, y: y - rc, width: rc * 2, height: rc * 2)),
                         with: .color(rim.withOpacity(clampD(0.5 * f, 0, 1)).color))
                // (2) glassy translucent sphere → bright iridescent edge + glass body.
                var sg = ctx
                sg.opacity = clampD(0.66 * f, 0, 1)
                sg.draw(sphereImg, in: CGRect(x: x - r2, y: y - r2, width: r2 * 2, height: r2 * 2))
                // (3) bright iridescent RIM RING (the soap-film tell), pushed to white.
                let rr = rad * 0.84
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)),
                    with: .color(rim.toWhite(0.32).withOpacity(clampD(0.7 * f, 0, 1)).color),
                    lineWidth: max(0.6, rad * 0.3))
            } else {
                // LIGHT canvas: source-over, real volume + crisp edge, no blowout.
                // (1) darkened lower-lip disc (offset down) → sphere shadow/volume.
                let lipR = rad * 0.92
                ctx.fill(Path(ellipseIn: CGRect(x: x - lipR, y: y + rad * 0.16 - lipR, width: lipR * 2, height: lipR * 2)),
                         with: .color(rim.darkened(by: 0.45).withOpacity(clampD(0.22 * f, 0, 1)).color))
                // (2) saturated colored body disc.
                let rd = rad * 1.0
                ctx.fill(Path(ellipseIn: CGRect(x: x - rd, y: y - rd, width: rd * 2, height: rd * 2)),
                         with: .color(rim.withOpacity(clampD(0.4 * f, 0, 1)).color))
                // (3) glassy sphere sprite.
                var sg = ctx
                sg.opacity = clampD(0.8 * f, 0, 1)
                sg.draw(sphereImg, in: CGRect(x: x - r2, y: y - r2, width: r2 * 2, height: r2 * 2))
                // (4) crisp saturated rim ring → defines the edge against the cream.
                let rr = rad * 0.86
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)),
                    with: .color(rim.darkened(by: 0.12).withOpacity(clampD(0.55 * f, 0, 1)).color),
                    lineWidth: max(0.6, rad * 0.26))
            }

            // (5) crisp white specular catchlight, upper-left — the hot glass spark.
            let sr = max(0.4, rad * 0.4)
            let ox = x - rad * 0.34
            let oy = y - rad * 0.36
            var sp = ctx
            sp.blendMode = dark ? .plusLighter : .normal
            sp.opacity = clampD((dark ? 0.95 : 0.7) * f, 0, 1)
            sp.draw(specImg, in: CGRect(x: ox - sr, y: oy - sr, width: sr * 2, height: sr * 2))
        }

        return true
    }
}

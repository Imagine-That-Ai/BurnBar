import SwiftUI

/// Film Bubble — faithful port of imaginethat `moire/film-bubble.ts` drawBody (L189-339).
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
/// Each bubble = TWO cached sprites + cheap discs (allocation-free hot loop):
///   • a white sphere sprite (clear core → bright iridescent rim → clear) drawn
///     OVER a colored disc, so the translucent rim reads as the film hue — the
///     tinted-sphere trick, no per-point gradient;
///   • a small white specular catchlight, upper-left.
/// DARK (additive `.plusLighter`): colored bloom halo (rad*1.35, 0.16f) → colored
/// core disc (rad*0.92, 0.5f) → white sphere (rad*2, 0.9f) → spec dot (0.85f).
/// LIGHT (`.normal`): rim disc (rad*1.05, 0.32f) → sphere (rad*2, 0.82f) → spec (0.7f).
/// A slow lissajous micro-drift + radius wobble + the two beating waves are all
/// driven purely by `frame.t`; `reduced` pins the thickness phase to 1.7 and drops
/// drift/wobble → a poised still frozen-film frame. `batteryThrottled` drops the
/// bloom halo + specular catchlight (the expendable passes). No wall clock.
///
/// Faithful simplifications vs source: the sphere sprite omits the dark lower-lip
/// volume overlay (the kit's radial cache is center-symmetric); destruction/ripple
/// event paths (pop/deflate/impact ripple, `dissolve`/`melt`/`armed`) are not part
/// of the steady substrate frame, so `vis=1`, `armSwell=1`, no ripple.
public final class FilmBubbleSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // ── thin-film spectrum LUT (built once; the hot loop never touches HSL math) ──
    private static let spectrumN = 256
    private static let spectrum: [RGBA] = {
        var out = [RGBA]()
        out.reserveCapacity(spectrumN)
        for i in 0..<spectrumN {
            let u = Double(i) / Double(spectrumN)
            // thin-film hue loops with shifting saturation, heavy in cyan/magenta.
            let hue = frac(0.58 + 0.92 * u)            // start near cyan, sweep > 1 cycle
            let sat = clampD(0.55 + 0.35 * sin(u * TAU * 2 + 0.4), 0.2, 0.95)
            let lit = clampD(0.62 + 0.1 * sin(u * TAU + 1.1), 0.45, 0.78)
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
        if hp < 1 { r = c; g = x }
        else if hp < 2 { r = x; g = c }
        else if hp < 3 { g = c; b = x }
        else if hp < 4 { g = x; b = c }
        else if hp < 5 { r = x; b = c }
        else { r = c; b = x }
        let m = l - c / 2
        return (r + m, g + m, b + m)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled        // drop halo + spec catchlight when throttled
        let sizePx = frame.sizePx
        let t = frame.t
        let cx = frame.cx, cy = frame.cy, R = frame.R

        // Global film bloom-in: fades the film in as the mark forms (vis/armed fold
        // to 1 for the held substrate look). reduced → treat as fully formed.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45
        let armSwell = 1.0                        // no scroll-verdict arming in the steady frame

        // Two interfering thickness wave fields. Slightly different spatial freq +
        // temporal rate → they beat, rolling rainbow moiré bands across the cluster.
        let invR = 1 / max(1, R)
        let tt = reduced ? 1.7 : t                // frozen-but-pretty phase under reduced motion
        let aFx = 2.1 * invR
        let aFy = 1.3 * invR
        let bFx = 2.55 * invR                     // detuned → moiré
        let bFy = 1.05 * invR
        let aRate = 0.55
        let bRate = -0.42

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Cached sprites resolved ONCE per frame, drawn many. Sphere: clear core →
        // bright iridescent-able rim → clear (white so the colored disc beneath tints
        // it). Spec: crisp white catchlight.
        let sphereImg = ctx.resolve(sprites.radial(diameter: 64, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.04)),
            (0.42, RGBA(r: 1, g: 1, b: 1, a: 0.10)),
            (0.78, RGBA(r: 1, g: 1, b: 1, a: 0.55)),
            (0.93, RGBA(r: 1, g: 1, b: 1, a: 1.0)),   // bright iridescent rim
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0)),
        ]))
        let specImg: GraphicsContext.ResolvedImage? = lite ? nil : ctx.resolve(sprites.radial(diameter: 32, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.5, RGBA(r: 1, g: 1, b: 1, a: 0.5)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0)),
        ]))

        let specN = Double(Self.spectrumN)

        for i in 0..<count {
            let d = frame.dots[i]
            let px = d.x
            let py = d.y
            let seed = shash(Double(i) * 1.37 + 0.5)

            // surface-tension micro-drift on a slow lissajous (±~1px) + radius wobble.
            var dxo = 0.0, dyo = 0.0, wob = 1.0
            if !reduced {
                let ph = seed * TAU
                dxo = sin(t * 0.6 + ph) * 0.9
                dyo = sin(t * 0.47 + ph * 1.7 + 1.3) * 0.9
                wob = 0.9 + 0.12 * sin(t * 1.3 + ph * 2.3)
            }
            let x = px + dxo
            let y = py + dyo

            // virtual film thickness = sum of two detuned waves (the beating pair).
            let rx = px - cx
            let ry = py - cy
            let thick = sin(rx * aFx + ry * aFy * 0.6 + tt * aRate)
                + sin(rx * bFx * 0.7 + ry * bFy + tt * bRate + seed * 1.1)

            // thickness (-2..2) → spectrum index.
            let u = frac(thick * 0.25 + 0.5)
            let si = min(Self.spectrumN - 1, max(0, Int(u * specN)))

            // rim hue: 62% iridescent spectrum / 38% per-point brand color so the
            // mark stays on-brand and legible while the rainbow only recolors it.
            let rim = d.rgba.mix(with: Self.spectrum[si], amount: 0.62)

            let rad = sizePx * 2.35 * wob * armSwell * (0.7 + 0.3 * f)
            let r2 = max(0.5, rad)

            if dark {
                // (1) soft colored bloom halo (iridescent), additive — expendable.
                if !lite {
                    let rh = rad * 1.35
                    ctx.fill(Path(ellipseIn: CGRect(x: x - rh, y: y - rh, width: rh * 2, height: rh * 2)),
                             with: .color(rim.withOpacity(clampD(0.16 * f, 0, 1)).color))
                }
                // (2) colored core disc carrying the hue.
                let rc = rad * 0.92
                ctx.fill(Path(ellipseIn: CGRect(x: x - rc, y: y - rc, width: rc * 2, height: rc * 2)),
                         with: .color(rim.withOpacity(clampD(0.5 * f, 0, 1)).color))
                // (3) white rim sphere sprite on top → bright iridescent edge + glassy body.
                var sg = ctx
                sg.opacity = clampD(0.9 * f, 0, 1)
                sg.draw(sphereImg, in: CGRect(x: x - r2, y: y - r2, width: r2 * 2, height: r2 * 2))
            } else {
                // LIGHT canvas: source-over, lower alpha, no additive blowout.
                let rd = rad * 1.05
                ctx.fill(Path(ellipseIn: CGRect(x: x - rd, y: y - rd, width: rd * 2, height: rd * 2)),
                         with: .color(rim.withOpacity(clampD(0.32 * f, 0, 1)).color))
                var sg = ctx
                sg.opacity = clampD(0.82 * f, 0, 1)
                sg.draw(sphereImg, in: CGRect(x: x - r2, y: y - r2, width: r2 * 2, height: r2 * 2))
            }

            // (4) crisp specular catchlight, upper-left (same blend as base).
            if let specImg {
                let sr = max(0.4, rad * 0.42)
                let ox = x - rad * 0.34
                let oy = y - rad * 0.36
                var sp = ctx
                sp.opacity = clampD((dark ? 0.85 : 0.7) * f, 0, 1)
                sp.draw(specImg, in: CGRect(x: ox - sr, y: oy - sr, width: sr * 2, height: sr * 2))
            }
        }

        return true
    }
}

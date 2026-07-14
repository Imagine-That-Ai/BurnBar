import SwiftUI
import OpenBurnBarKernel
import CoreGraphics

/// Plankton Wake — premium port of imaginethat `flow/plankton-wake.ts` drawBody.
///
/// Each silhouette point is a bioluminescent ember on a curl-noise current. The
/// source reads "lighter" (additive) on dark; this port goes further toward the
/// gorgeous web look by stacking REAL depth:
///
///   1. GAUSSIAN BLOOM UNDERLAYER (dark) — a single `drawLayer` with `.blur` +
///      `.plusLighter` stamps every ember (cyan/aqua sprite) plus a per-point
///      tinted soft body into a blurred additive wash. Overlapping glows ADD, so
///      the silhouette fills with a continuous luminous water-glow that bleeds
///      between points — the field reads as a glowing wake, never as scattered
///      faint dots. (Dropped on `batteryThrottled` — the one heaviest pass.)
///   2. SATURATED BODY (dark) — per point: a 2-ghost motion comet + the wide
///      cyan→aquamarine ember halo sprite + a brand-tint body disc.
///   3. HOT CORE ON TOP (dark) — a tight near-white core (brand color pushed
///      asymmetrically toward white by 0.78/0.82/0.66) plus a white sparkle pop
///      when a point flares — the crisp legible silhouette point.
///
/// On LIGHT a low-opacity blurred halo underlayer gives the same watery depth,
/// then crisp source-over cores read with real contrast (`.plusLighter` blows out
/// on white, so light stays `.normal`).
///
/// Motion is the analytic curl-noise current (sum-of-sines stream-function
/// derivatives), advecting each ember in a hard-capped ≤2px orbit so the mark
/// never migrates, a per-ember breathe (~0.4Hz own phase), and a curl-shear-gated
/// sparkle — all on `frame.t` with a per-point seed. `reduced` freezes to a poised
/// still ember-field (bloom kept — it is a static glow). The fixed cyan/aqua halo
/// hue is theme-independent; the per-point color only tints body + core + wash.
public final class PlanktonWakeSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // ── Analytic curl of a sum-of-sines stream function ψ(x,y,t): divergence-free
    // velocity (∂ψ/∂y, −∂ψ/∂x). Cheap, deterministic, allocation-free. Verbatim.
    @inline(__always) private static func curlX(_ x: Double, _ y: Double, _ t: Double) -> Double {
        cos(x * 0.018 + t * 0.22) * cos(y * 0.021 - t * 0.17) * 0.021
        - sin(x * 0.011 - t * 0.13) * sin(y * 0.014 + t * 0.19) * 0.014
        + cos(y * 0.033 + t * 0.31) * 0.033 * 0.6
    }
    @inline(__always) private static func curlY(_ x: Double, _ y: Double, _ t: Double) -> Double {
        -(sin(x * 0.018 + t * 0.22) * sin(y * 0.021 - t * 0.17) * -0.018
          + cos(x * 0.011 - t * 0.13) * cos(y * 0.014 + t * 0.19) * 0.011
          + sin(x * 0.027 - t * 0.27) * 0.027 * 0.6)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t

        // assembly fade-in: embers kindle as the mark forms (settleProgress == source `formed`).
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.4 + 0.6

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // ── Precompute drift + brightness ONCE; bloom + crisp passes share it (no double trig).
        var px = [Double](repeating: 0, count: count)
        var py = [Double](repeating: 0, count: count)
        var kk = [Double](repeating: 0, count: count)
        var adx = [Double](repeating: 0, count: count)
        var ady = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let d = frame.dots[i]
            let tx = d.x, ty = d.y
            let seed = shash(Double(i) * 1.37 + 0.5)
            let phase = seed * TAU

            // ── curl current → tiny capped drift orbit (≤2px). Hot core stays on target.
            var dx = 0.0, dy = 0.0, speed = 0.0
            if !reduced {
                let vx = Self.curlX(tx, ty, t)
                let vy = Self.curlY(tx, ty, t)
                speed = (vx * vx + vy * vy).squareRoot()       // local |curl| pressure
                let wob = t * (0.55 + seed * 0.5) + phase
                dx = vx * 64 + cos(wob) * 0.9
                dy = vy * 64 + sin(wob) * 0.9
                let dmag = (dx * dx + dy * dy).squareRoot()
                if dmag > 2 { dx = dx / dmag * 2; dy = dy / dmag * 2 }
            }

            // ── resting breathe between dim ember and mid glow (~0.4Hz, own phase).
            let breatheArg: Double = reduced ? phase * 13.0 : t * 2.5 + phase
            let br: Double = 0.5 + 0.5 * sin(breatheArg)
            var k: Double = 0.46 + 0.34 * br                   // brightness floor keeps it legible

            // ── sparkle: where local |curl| shears past a threshold, flare to full core.
            if !reduced {
                let s = sin(t * (1.0 + seed * 1.3) + phase * 5.0 + speed * 220.0)
                if s > 0.9 { k += ((s - 0.9) / 0.1) * (0.55 + speed * 26) }
            }

            k = clampD(k, 0.18, 2.4) * form
            px[i] = tx + dx; py[i] = ty + dy; kk[i] = k; adx[i] = dx; ady[i] = dy
        }

        // The cached cyan→aquamarine ember halo sprite — resolve ONCE, stamp many.
        // Fixed bioluminescent hue (independent of theme color); only alpha/radius vary.
        let ember: GraphicsContext.ResolvedImage? = dark
            ? ctx.resolve(sprites.radial(diameter: 96, stops: [
                (0.00, RGBA(r: 236.0/255, g: 1.0, b: 1.0, a: 1.00)),
                (0.04, RGBA(r: 208.0/255, g: 252.0/255, b: 1.0, a: 0.95)),
                (0.16, RGBA(r: 90.0/255, g: 224.0/255, b: 238.0/255, a: 0.55)),
                (0.38, RGBA(r: 58.0/255, g: 196.0/255, b: 214.0/255, a: 0.22)),
                (0.66, RGBA(r: 64.0/255, g: 210.0/255, b: 190.0/255, a: 0.07)),
                (1.00, RGBA(r: 64.0/255, g: 210.0/255, b: 190.0/255, a: 0.00))
            ]))
            : nil

        if dark, let ember {
            // ── PASS 1 (heaviest, dropped on throttle): TRUE GAUSSIAN BLOOM UNDERLAYER.
            // One blurred additive layer; overlapping ember glows ADD into a continuous
            // luminous wash that fills the silhouette and glows between points.
            if !lite {
                ctx.drawLayer { l in
                    l.blendMode = .plusLighter
                    l.addFilter(.blur(radius: CGFloat(max(3.4, sizePx * 3.0))))
                    for i in 0..<count {
                        let k = kk[i]
                        let x = px[i], y = py[i]
                        let wide = sizePx * (3.6 + 2.8 * k)
                        var g = l; g.opacity = clampD(0.15 * k, 0, 0.62)
                        g.draw(ember, in: CGRect(x: x - wide, y: y - wide, width: wide * 2, height: wide * 2))
                        // a per-point tinted soft dot carries each point's hue into the wash.
                        let c = frame.dots[i].rgba
                        let bodyR = max(1.0, sizePx * 1.7)
                        l.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR, width: bodyR * 2, height: bodyR * 2)),
                               with: .color(c.withOpacity(clampD(0.23 * k, 0, 0.62)).color))
                    }
                }
            }

            // ── PASS 2: saturated body + hot core per point (crisp, on top of the bloom).
            for i in 0..<count {
                let k = kk[i]
                let x = px[i], y = py[i]
                let col = frame.dots[i].rgba

                // 2-ghost motion comet along the drift, falling alpha (skip on throttle/reduced).
                if !lite && !reduced {
                    let trailAng = atan2(ady[i], adx[i])
                    let trailLen = sizePx * (0.9 + 1.4 * k)
                    let tcos = cos(trailAng), tsin = sin(trailAng)
                    let tr = sizePx * (2.0 + 0.6 * k)
                    for s in 1...2 {
                        let a = 0.06 * k * (1 - Double(s) * 0.4)
                        if a <= 0 { continue }
                        let gx = x - tcos * trailLen * Double(s)
                        let gy = y - tsin * trailLen * Double(s)
                        var g = ctx; g.opacity = a
                        g.draw(ember, in: CGRect(x: gx - tr, y: gy - tr, width: tr * 2, height: tr * 2))
                    }
                }

                // the wide aquamarine→cyan ember halo (cached sprite), boosted for presence.
                let bloomR = sizePx * (3.0 + 2.1 * k)
                var gh = ctx; gh.opacity = clampD(0.24 * k, 0, 0.7)
                gh.draw(ember, in: CGRect(x: x - bloomR, y: y - bloomR, width: bloomR * 2, height: bloomR * 2))

                // brand-tint body just inside the halo (keeps theme hue present).
                let bodyR = max(0.9, sizePx * 1.4)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR, width: bodyR * 2, height: bodyR * 2)),
                         with: .color(col.withOpacity(clampD(0.46 * k, 0, 0.78)).color))

                // tiny hot teal/green-lit core — the legible silhouette point, on target.
                // Push toward white but keep the green/teal channels dominant so the core
                // glows bioluminescent rather than washing out to neutral white.
                let coreR = max(0.7, sizePx * 0.6)
                let hot = RGBA(r: col.r + (1 - col.r) * 0.74,
                               g: col.g + (1 - col.g) * 0.86,
                               b: col.b + (1 - col.b) * 0.72,
                               a: clampD(1.0 * k, 0, 1))
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                         with: .color(hot.color))

                // a white sparkle pop at peak brightness — the curl-flare wink, hot on top.
                if k > 1.05 {
                    let sr = max(0.5, sizePx * 0.34)
                    let pop = clampD((k - 1.05) * 0.8, 0, 0.7)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - sr, y: y - sr, width: sr * 2, height: sr * 2)),
                             with: .color(Color.white.opacity(pop)))
                }
            }
        } else {
            // ── LIGHT canvas: cool plankton ink dots, source-over, never blown out.
            // A low-opacity blurred halo underlayer gives the same watery depth.
            if !lite {
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: CGFloat(max(2.5, sizePx * 2.0))))
                    l.opacity = 0.5
                    for i in 0..<count {
                        let k = kk[i]
                        let x = px[i], y = py[i]
                        let col = frame.dots[i].rgba
                        let r = sizePx * (1.9 + 0.7 * k)
                        l.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                               with: .color(col.withOpacity(clampD(0.22 * k, 0, 0.4)).color))
                    }
                }
            }

            for i in 0..<count {
                let k = kk[i]
                let x = px[i], y = py[i]
                let col = frame.dots[i].rgba

                let haloR = sizePx * (1.7 + 0.4 * k)
                ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR, width: haloR * 2, height: haloR * 2)),
                         with: .color(col.withOpacity(clampD(0.13 * k, 0, 0.28)).color))

                let coreR = max(0.85, sizePx * 0.62)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                         with: .color(col.withOpacity(clampD(0.92 * form, 0, 1)).color))

                // a brighter half-whitened speck at peak brightness reads as a flare wink.
                if !reduced && k > 1.1 {
                    let speckR = max(0.6, sizePx * 0.4)
                    let lit = RGBA(r: col.r + (1 - col.r) * 0.5,
                                   g: col.g + (1 - col.g) * 0.55,
                                   b: col.b + (1 - col.b) * 0.4,
                                   a: clampD((k - 1.1) * 0.7, 0, 0.5))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - speckR, y: y - speckR, width: speckR * 2, height: speckR * 2)),
                             with: .color(lit.color))
                }
            }
        }

        return true
    }
}

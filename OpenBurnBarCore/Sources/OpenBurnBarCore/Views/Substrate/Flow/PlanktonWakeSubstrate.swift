import SwiftUI

/// Plankton Wake — faithful port of imaginethat `flow/plankton-wake.ts` drawBody (L136-301).
///
/// Each silhouette point is a bioluminescent ember. On a DARK canvas (additive
/// `.plusLighter`) every point stacks, in z-order: (1) a short 2-ghost motion
/// comet of the cached ember sprite trailing along the drift direction; (2) the
/// wide cyan→aquamarine ember halo (one cached 4-stop radial sprite — core,
/// cyan mid, fading aquamarine, transparent); (3) a brand-tint body disc in the
/// point's own color; (4) a tiny near-white hot core (the legible silhouette
/// point), the brand color pushed asymmetrically toward white by (0.78,0.82,0.66).
/// On a LIGHT canvas (`.normal`) it collapses to a soft colored halo + saturated
/// core, plus a half-white speck when a point flares.
///
/// Motion is an analytic curl-noise current (sum-of-sines stream-function
/// derivatives) advecting each ember in a hard-capped ≤2px orbit so the mark
/// never migrates, a per-ember breathe (~0.4Hz own phase), and a curl-shear-gated
/// sparkle that flares a point to full core then decays — all on `frame.t` with a
/// per-point seed. `reduced` freezes to a poised still ember-field (no drift, no
/// sparkle, no comet, static breathe). `batteryThrottled` drops the comet trails
/// and the wide halo sprite (keeps body + core). Exact alpha/radius constants ARE
/// the look. Interaction-driven wake/ring/bloom terms are omitted (held look only).
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

        // The cached cyan→aquamarine ember halo sprite — resolve ONCE, stamp many.
        // Fixed bioluminescent hue (independent of theme color); only alpha/radius vary.
        let ember: GraphicsContext.ResolvedImage? = (dark && !lite)
            ? ctx.resolve(sprites.radial(diameter: 96, stops: [
                (0.00, RGBA(r: 236.0/255, g: 1.0,       b: 1.0,       a: 1.00)),
                (0.04, RGBA(r: 208.0/255, g: 252.0/255, b: 1.0,       a: 0.95)),
                (0.16, RGBA(r: 90.0/255,  g: 224.0/255, b: 238.0/255, a: 0.55)),
                (0.38, RGBA(r: 58.0/255,  g: 196.0/255, b: 214.0/255, a: 0.22)),
                (0.66, RGBA(r: 64.0/255,  g: 210.0/255, b: 190.0/255, a: 0.07)),
                (1.00, RGBA(r: 64.0/255,  g: 210.0/255, b: 190.0/255, a: 0.00)),
            ]))
            : nil

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
            let x = tx + dx, y = ty + dy

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

            let col = d.rgba

            if dark {
                // ── 2-ghost motion comet along the drift, falling alpha (skip on throttle/reduced).
                if let ember, !reduced {
                    let trailAng = atan2(dy, dx)
                    let trailLen = sizePx * (0.9 + 1.4 * k)
                    let tcos = cos(trailAng), tsin = sin(trailAng)
                    let tr = sizePx * (2.0 + 0.6 * k)
                    for s in 1...2 {
                        let a = 0.05 * k * (1 - Double(s) * 0.4)
                        if a <= 0 { continue }
                        let gx = x - tcos * trailLen * Double(s)
                        let gy = y - tsin * trailLen * Double(s)
                        var g = ctx; g.opacity = a
                        g.draw(ember, in: CGRect(x: gx - tr, y: gy - tr, width: tr * 2, height: tr * 2))
                    }
                }

                // ── the wide aquamarine→cyan ember halo (cached sprite).
                if let ember {
                    let bloomR = sizePx * (2.6 + 1.7 * k)
                    var g = ctx; g.opacity = clampD(0.13 * k, 0, 0.5)
                    g.draw(ember, in: CGRect(x: x - bloomR, y: y - bloomR, width: bloomR * 2, height: bloomR * 2))
                }

                // ── brand-tint body just inside the halo (keeps theme hue present).
                let bodyR = max(0.8, sizePx * 1.25)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR, width: bodyR * 2, height: bodyR * 2)),
                         with: .color(col.withOpacity(clampD(0.34 * k, 0, 0.65)).color))

                // ── tiny hot near-white core — the legible silhouette point, on target.
                let coreR = max(0.7, sizePx * 0.52)
                let hot = RGBA(r: col.r + (1 - col.r) * 0.78,
                               g: col.g + (1 - col.g) * 0.82,
                               b: col.b + (1 - col.b) * 0.66,
                               a: clampD(0.92 * k, 0, 1))
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                         with: .color(hot.color))
            } else {
                // ── LIGHT canvas: cool plankton ink dots, source-over, never blown out.
                let haloR = sizePx * (1.7 + 0.4 * k)
                ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR, width: haloR * 2, height: haloR * 2)),
                         with: .color(col.withOpacity(clampD(0.12 * k, 0, 0.26)).color))
                let coreR = max(0.85, sizePx * 0.62)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)),
                         with: .color(col.withOpacity(clampD(0.9 * form, 0, 1)).color))
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

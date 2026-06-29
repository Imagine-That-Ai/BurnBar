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
    private static let FLOOR = 0.16   // dim legibility glow every node always emits
    private static let GAMMA = 1.9    // contrast on the fringe product (antinodes pop)
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
        let cx = frame.cx, cy = frame.cy, R = frame.R

        // Assembly fade so the fringes bloom in as the mark forms (vis/armPulse fold
        // to 1 for the held substrate look). reduced → treat as fully formed.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        // Grating geometry: spatial frequency scales with cloud size so the band
        // count reads the same on any logo. Two gratings at slightly different
        // orientation + frequency beat into the crawling moiré.
        let base = 5.6 / max(R, 1)
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

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Resolve the additive bloom sprite ONCE per frame (dark only), draw many.
        // Exact source stops: white@0 → .62@.18 → .22@.42 → .05@.72 → clear@1.
        let glow = dark ? ctx.resolve(sprites.radial(diameter: 64, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.18, RGBA(r: 1, g: 1, b: 1, a: 0.62)),
            (0.42, RGBA(r: 1, g: 1, b: 1, a: 0.22)),
            (0.72, RGBA(r: 1, g: 1, b: 1, a: 0.05)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0)),
        ])) : nil

        let bodyR = max(0.9, sizePx * 1.25)        // dark colored-body radius (constant)
        let coreR = max(0.85, sizePx * 0.7)        // light crisp-core radius (constant)

        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            // node-space coords keep the grating phase locked to the mark's frame.
            let px = x - cx
            let py = y - cy

            // two gratings (axis-aligned A, rotated B): their PRODUCT is the
            // interference. Each in [0,1].
            let g1 = 0.5 + 0.5 * sin(px * kx + py * ky * 0.18 + phA)
            let u2 = px * c2 - py * s2
            let g2 = 0.5 + 0.5 * sin(u2 * k2 + phB)

            // interference brightness: product, contrast-shaped, lifted off the floor.
            var inten = pow(g1 * g2, gamma)
            inten = floor + (1 - floor) * inten
            inten *= form
            if inten <= 0 { continue }

            let col = d.rgba

            if dark {
                let k = clampD(inten, 0, 1.9)
                // (1) primary emissive node — cached white bloom sized by k.
                let r0 = sizePx * (2.0 + 2.4 * min(k, 1.0))
                if let glow {
                    var g = ctx
                    g.opacity = clampD(0.5 * k, 0, 0.95)
                    g.draw(glow, in: CGRect(x: x - r0, y: y - r0, width: r0 * 2, height: r0 * 2))
                }
                // (2) colored body carries the brand hue through the bloom.
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR,
                                                width: bodyR * 2, height: bodyR * 2)),
                         with: .color(col.withOpacity(clampD(0.42 * k, 0, 0.85)).color))
                // (3) antinode bloom: brightest nodes get a wide faint disc.
                // Dropped under battery throttle (the expendable extra pass).
                if !lite, k > 0.85, let glow {
                    let rb = sizePx * (4.5 + 3.0 * (k - 0.85))
                    var g = ctx
                    g.opacity = clampD(0.12 * (k - 0.85) * 2.4, 0, 0.3)
                    g.draw(glow, in: CGRect(x: x - rb, y: y - rb, width: rb * 2, height: rb * 2))
                }
            } else {
                // LIGHT canvas: source-over accent discs; alpha IS the fringe so the
                // bands read as tonal modulation and never blow the canvas to white.
                let k = clampD(inten, 0, 1.4)
                // soft outer halo.
                let haloR = sizePx * (1.8 + 1.2 * min(k, 1.0))
                ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR,
                                                width: haloR * 2, height: haloR * 2)),
                         with: .color(col.withOpacity(clampD(0.14 * k, 0, 0.34)).color))
                // crisp core that keeps the silhouette dense.
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(col.withOpacity(clampD(0.52 + 0.4 * (k - floor), 0.3, 0.95)).color))
            }
        }

        return true
    }
}

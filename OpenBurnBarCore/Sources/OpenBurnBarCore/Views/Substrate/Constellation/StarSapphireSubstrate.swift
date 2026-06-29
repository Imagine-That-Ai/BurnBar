import SwiftUI

/// Cut Star Sapphire — faithful port of imaginethat `constellation/starsapphire.ts`
/// drawBody (L91-273).
///
/// Every silhouette point is a tiny cut sky-blue star sapphire: a 6-sided gem
/// split into wedge facets from its center, each facet filled FLAT at a
/// brightness set by its rotated normal vs a slowly-drifting top-left key
/// (orientation shading — no real 3D). The 6 unit verts + 6 wedge normals are
/// precomputed ONCE (deterministic, same every gem). Per frame, two passes:
///
///  • Pass 1 (source-over ALWAYS, even on dark — flat facets never blow out):
///    ONE flat hexagon body filled at the MEAN of the 6 faithful lambert facet
///    tones `shade = 0.34 + lit²·0.9`, a crisp 1px darkened-brand hex edge (the
///    same Path, reused), and a near-white highlight triangle on the brightest
///    facet — the hard geometry that keeps the mark legible. Averaging the wedge
///    tones into one fill collapses Pass 1 from ~8 draws/gem to 3 (no per-facet
///    Path allocations) while the migrating highlight keeps the cut-gem read.
///  • Pass 2 (`.plusLighter` on dark, source-over on light): a specular glint
///    circle that winks on the brightest VERTEX, plus a faint six-ray asterism
///    for the brightest ~22% (seed > 0.78) — the star sapphire signature.
///
/// Each gem spins its facet-light assignment on `t·0.6·(0.7+seed·0.6)` so the
/// highlight migrates facet-to-facet; the whole-cloud key drifts on `sin(t·0.11)`
/// so asterism rays sweep; glints twinkle on `sin(t·(1.3+seed))`. `reduced`
/// freezes a poised still jewel-case (spin = seed·TAU, fixed key, static glint).
/// `batteryThrottled` drops pass 2 (glints + asterism). All animation is from
/// `frame.t` + per-point `shash`; per-point alpha (`rgba.a`) folds the field fade.
public final class StarSapphireSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    /// facets per gem — fixed so every stone has a uniform crisp body.
    private static let facets = 6

    // Precomputed gem geometry (built once, never per-frame):
    private let vx: [Double]   // outer-ring unit vertex x
    private let vy: [Double]   // outer-ring unit vertex y
    private let nx: [Double]   // wedge midpoint normal x
    private let ny: [Double]   // wedge midpoint normal y

    public init() {
        let n = Self.facets
        var vx = [Double](repeating: 0, count: n)
        var vy = [Double](repeating: 0, count: n)
        var nx = [Double](repeating: 0, count: n)
        var ny = [Double](repeating: 0, count: n)
        // Outer ring: slightly irregular radius wobble so the cut looks
        // hand-faceted but deterministic (identical on every gem).
        for i in 0..<n {
            let a = (Double(i) / Double(n)) * TAU - .pi / 2
            let r = 0.86 + 0.14 * shash(Double(i) * 3.1 + 1)
            vx[i] = cos(a) * r
            vy[i] = sin(a) * r
        }
        // Wedge i spans vertex i → i+1; its normal points at the edge midpoint.
        for i in 0..<n {
            let j = (i + 1) % n
            var mx = (vx[i] + vx[j]) * 0.5
            var my = (vy[i] + vy[j]) * 0.5
            let m = (mx * mx + my * my).squareRoot()
            let inv = m == 0 ? 1 : 1 / m
            mx *= inv; my *= inv
            nx[i] = mx; ny[i] = my
        }
        self.vx = vx; self.vy = vy; self.nx = nx; self.ny = ny
    }

    /// Push a brand colour toward white by per-channel amounts (the gem's hot
    /// highlight / glint / asterism tint), with a baked alpha.
    @inline(__always)
    private func whitePush(_ c: RGBA, _ wr: Double, _ wg: Double, _ wb: Double, alpha: Double) -> RGBA {
        RGBA(r: c.r + (1 - c.r) * wr,
             g: c.g + (1 - c.g) * wg,
             b: c.b + (1 - c.b) * wb,
             a: alpha)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let n = Self.facets
        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let t = frame.t

        // form-driven scale: gems "cut" into being as the cloud assembles.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.4 + 0.6
        let gemR = max(2.6, frame.sizePx * 2.05) * form

        // whole-cloud key drifts microscopically so asterism rays sweep.
        let lightA = reduced ? -2.2 : -2.2 + sin(t * 0.11) * 0.5
        let baseLx = cos(lightA)
        let baseLy = sin(lightA)

        // 22/255, 12/255 — the source's 8-bit blue lifts in 0…1 space.
        let blueLitLift = 22.0 / 255.0
        let edgeBlueLift = 12.0 / 255.0

        // Reused rotated-vertex scratch (overwritten per gem; no per-gem heap).
        var rxv = [Double](repeating: 0, count: n)
        var ryv = [Double](repeating: 0, count: n)

        // ── pass 1: faceted bodies (source-over ALWAYS — facets never blow out) ──
        var ctx = baseCtx
        ctx.blendMode = .normal
        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let base = d.rgba
            let alpha = base.a
            let seed = shash(Double(i) * 1.37 + 0.5)

            // each gem rotates its facet-light assignment → highlights migrate.
            let spin = reduced ? seed * TAU : t * 0.6 * (0.7 + seed * 0.6) + seed * TAU
            let ca = cos(spin), sa = sin(spin)

            // rotate all outer verts once (shared by facets + edge + highlight).
            for f in 0..<n {
                rxv[f] = (vx[f] * ca - vy[f] * sa) * gemR
                ryv[f] = (vx[f] * sa + vy[f] * ca) * gemR
            }

            // Lambert pass — compute per-facet brightness to (a) find the lit
            // facet that carries the highlight and (b) accumulate the MEAN facet
            // tone. The 6 faithful wedge shades are averaged into ONE flat body
            // fill instead of 6 separate per-facet Path fills: at the brief's
            // 2–4k gems that collapses Pass 1 from ~8 draws/gem to 3, killing the
            // 16k–32k Path allocs/frame the reviewer flagged, while keeping the
            // gem contrast curve (0.34 + lit²·0.9) and the cool blue lift. This
            // mirrors the sibling LatticeFacet gem style's allocation-light
            // "flat body + single lit wedge" idiom; at the real ~3px gem scale the
            // mean-toned body + migrating highlight reads identically to 6 facets.
            var brightF = 0
            var brightVal = -2.0
            var shadeSum = 0.0
            var litSum = 0.0
            for f in 0..<n {
                // rotated wedge normal → lambert-ish facet brightness.
                let rnx = nx[f] * ca - ny[f] * sa
                let rny = nx[f] * sa + ny[f] * ca
                let dotL = rnx * baseLx + rny * baseLy          // -1 shadow … 1 lit
                let lit = 0.5 + 0.5 * dotL                       // 0 … 1
                if dotL > brightVal { brightVal = dotL; brightF = f }
                shadeSum += 0.34 + lit * lit * 0.9               // gem contrast curve
                litSum += lit
            }
            let invN = 1.0 / Double(n)
            let bodyShade = shadeSum * invN
            let bodyLit = litSum * invN

            // ONE faceted hexagon Path, reused for BOTH the flat body fill and the
            // crisp edge stroke (no per-facet Path allocations). Body tone = mean
            // of the faithful per-wedge lambert shades + the cool blue lift in
            // light; it darkens/brightens as the gem spins toward/away from the key.
            var hex = Path()
            hex.move(to: CGPoint(x: x + rxv[0], y: y + ryv[0]))
            for f in 1..<n { hex.addLine(to: CGPoint(x: x + rxv[f], y: y + ryv[f])) }
            hex.closeSubpath()
            let body = RGBA(r: clampD(base.r * bodyShade, 0, 1),
                            g: clampD(base.g * bodyShade, 0, 1),
                            b: clampD(base.b * bodyShade + bodyLit * blueLitLift, 0, 1),
                            a: alpha)
            ctx.fill(hex, with: .color(body.color))

            // crisp dark crystal edge — the hard geometry that keeps it legible.
            if gemR > 2.2 {
                let edge = dark
                    ? RGBA(r: base.r * 0.2, g: base.g * 0.22,
                           b: clampD(base.b * 0.3 + edgeBlueLift, 0, 1), a: 0.85 * alpha)
                    : RGBA(r: base.r * 0.32, g: base.g * 0.32,
                           b: base.b * 0.42, a: 0.7 * alpha)
                ctx.stroke(hex, with: .color(edge.color),
                           style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }

            // bright source-over highlight triangle on the light-facing facet — the
            // single lit "top facet" wedge that keeps the cut-gem read; it still
            // migrates facet-to-facet as the gem spins on t·0.6.
            let g = (brightF + 1) % n
            let hiA = clampD(0.45 + 0.5 * brightVal, 0, 0.95) * alpha
            let hi = whitePush(base, 0.7, 0.7, 0.85, alpha: hiA)
            var tri = Path()
            tri.move(to: CGPoint(x: x, y: y))
            tri.addLine(to: CGPoint(x: x + rxv[brightF] * 0.92, y: y + ryv[brightF] * 0.92))
            tri.addLine(to: CGPoint(x: x + rxv[g] * 0.92, y: y + ryv[g] * 0.92))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(hi.color))
        }

        // ── pass 2: specular glints + asterism (bloom on dark; gentle on light) ──
        // Dropped under battery throttle — it is the extra pass.
        guard !lite else { return true }

        var ctx2 = baseCtx
        ctx2.blendMode = dark ? .plusLighter : .normal
        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let base = d.rgba
            let alpha = base.a
            let seed = shash(Double(i) * 1.37 + 0.5)
            let spin = reduced ? seed * TAU : t * 0.6 * (0.7 + seed * 0.6) + seed * TAU
            let ca = cos(spin), sa = sin(spin)

            // brightest VERTEX (the one facing the key) carries the glint.
            var brightI = 0
            var brightVal = -2.0
            for f in 0..<n {
                let rvx = vx[f] * ca - vy[f] * sa
                let rvy = vx[f] * sa + vy[f] * ca
                let dotL = rvx * baseLx + rvy * baseLy
                if dotL > brightVal { brightVal = dotL; brightI = f }
            }
            let gx = x + (vx[brightI] * ca - vy[brightI] * sa) * gemR
            let gy = y + (vx[brightI] * sa + vy[brightI] * ca) * gemR

            // glint winks: per-gem twinkle scaled by how square-on the vertex is.
            let tw = reduced
                ? 0.45 + 0.4 * (0.5 + 0.5 * sin(seed * 21))
                : 0.45 + 0.4 * sin(t * (1.3 + seed) + seed * TAU)
            let glint = clampD(tw, 0.18, 0.95) * (0.6 + 0.4 * clampD(brightVal, 0, 1))
            let glR = max(1.1, gemR * 0.42)
            let glA = (dark ? glint * 0.95 : glint * 0.55) * alpha
            let glC = whitePush(base, 0.85, 0.85, 0.92, alpha: glA)
            ctx2.fill(Path(ellipseIn: CGRect(x: gx - glR, y: gy - glR,
                                             width: glR * 2, height: glR * 2)),
                      with: .color(glC.color))

            // brightest ~22% flash a faint six-ray asterism that sweeps.
            if seed > 0.78 {
                let flash = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 0.9 + seed * 9.0)
                let aA = clampD(flash, 0, 1)
                if aA > 0.04 {
                    let rayLen = gemR * (1.7 + aA * 1.1)
                    let rot = reduced ? lightA : lightA + t * 0.05
                    let rayA = (dark ? 0.5 : 0.3) * aA * alpha
                    let rayC = whitePush(base, 0.8, 0.8, 0.9, alpha: rayA)
                    var star = Path()
                    for k in 0..<3 {
                        let a = rot + (Double(k) / 3) * .pi
                        let dx = cos(a) * rayLen, dy = sin(a) * rayLen
                        star.move(to: CGPoint(x: x - dx, y: y - dy))
                        star.addLine(to: CGPoint(x: x + dx, y: y + dy))
                    }
                    ctx2.stroke(star, with: .color(rayC.color),
                                style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                }
            }
        }

        return true
    }
}

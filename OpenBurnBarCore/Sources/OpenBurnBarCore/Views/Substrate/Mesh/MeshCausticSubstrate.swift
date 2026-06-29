import SwiftUI

/// Caustic Pool — faithful port of imaginethat `mesh/mesh-caustic.ts` drawBody.
///
/// A thin-film iridescent membrane lit from behind, so light POOLS at the mesh
/// vertices like caustics on a pool floor. Each frame a cheap 2-octave value-noise
/// field, folded with `|sin(phase)|`, is advected (~0.08 Hz) into crawling bright
/// RIDGES; every silhouette point carries that intensity as a glow whose radius +
/// alpha pulse on a per-point offset. A 0.26 intensity FLOOR keeps the mark a solid
/// luminous body. Passes, in z-order:
///   0. (LIGHT only, source-over) deep-ink under-glow disc so the bright net reads
///      on a bright canvas without blowing out.
///   2. pooled-light glow — DARK: an iris-tinted core disc + a cached 64px white
///      radial bloom (additive); LIGHT: a soft colored disc.
///   3. refracted filaments — link points whose intensity ≥0.42 to their ≤2 nearest
///      neighbours (`frame.structure`) when both sit on a ridge and the gap is short;
///      batched into ONE whitened-iris stroke.
///   4. specular sparks — a cached 32px white-blue spark at the brightest ridge
///      vertices (k≥0.6), gated by a per-spark twinkle so they never flash as one.
/// Hue is a 6-stop closed IRIS jewel ramp sampled by centroid-bearing + field +
/// drift, blended into each point's brand colour. `reduced` freezes phase/drift/pulse
/// into a poised shimmering still net; `batteryThrottled` drops the white bloom +
/// sparks. Animated only from `frame.t` + per-point hashes — no wall clock.
public final class MeshCausticSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    // Hoisted per-point scratch (rebuilt each frame; reused when count is stable).
    private var inten: [Double] = []
    private var hueU: [Double] = []
    public init() {}

    /// 6-stop closed iridescent jewel ramp (sky→aqua→mint→gold→magenta→violet).
    private static let iris: [RGBA] = [
        RGBA(r: 70 / 255, g: 150 / 255, b: 235 / 255),
        RGBA(r: 80 / 255, g: 220 / 255, b: 210 / 255),
        RGBA(r: 150 / 255, g: 235 / 255, b: 150 / 255),
        RGBA(r: 235 / 255, g: 200 / 255, b: 120 / 255),
        RGBA(r: 235 / 255, g: 130 / 255, b: 200 / 255),
        RGBA(r: 140 / 255, g: 120 / 255, b: 240 / 255)
    ]

    /// Sample the closed iris ramp at `u` (wraps; matches source `iris()`).
    @inline(__always) private func iris(_ u: Double) -> RGBA {
        let ramp = Self.iris
        let n = ramp.count
        let fu = frac(u) * Double(n)
        let i = Int(floor(fu)) % n
        let fr = fu - floor(fu)
        return ramp[i].mix(with: ramp[(i + 1) % n], amount: fr)
    }

    /// Smooth value noise: hashed lattice + smoothstep interpolation (source `vnoise`).
    @inline(__always) private func vnoise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x), yi = floor(y)
        let xf = x - xi, yf = y - yi
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        let n00 = shash(xi * 127.1 + yi * 311.7)
        let n10 = shash((xi + 1) * 127.1 + yi * 311.7)
        let n01 = shash(xi * 127.1 + (yi + 1) * 311.7)
        let n11 = shash((xi + 1) * 127.1 + (yi + 1) * 311.7)
        let a = n00 + (n10 - n00) * u
        let b = n01 + (n11 - n01) * u
        return a + (b - a) * v
    }

    /// 2-octave fbm — crawling ridges, cheap per point (source `fbm2`).
    @inline(__always) private func fbm2(_ x: Double, _ y: Double) -> Double {
        vnoise(x, y) * 0.65 + vnoise(x * 2.03 + 5.2, y * 2.03 - 3.1) * 0.35
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let cx = frame.cx, cy = frame.cy, radius = frame.cloudRadius

        // Master fade: assembly ramp (alive/dissolve/armed default to held look).
        let f = clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        // Animation drivers — frozen into a poised pose under reduced motion.
        let phase = reduced ? 0.6 : t * (TAU * 0.08)
        let hueDrift = reduced ? 0.15 : frac(t / 14)
        let fs = 3.4 / max(radius, 1)

        if inten.count != count {
            inten = [Double](repeating: 0, count: count)
            hueU = [Double](repeating: 0, count: count)
        }

        // ── pass 1: build the caustic intensity field + per-point hue (no draw) ──
        var maxI = 1e-4
        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let fld = fbm2(x * fs + phase * 0.6, y * fs - phase * 0.4)
            var ridge = abs(sin((fld * 2.4 + phase) * Double.pi))
            ridge *= ridge
            let seed = shash(Double(i) * 1.37 + 0.5)
            let pulse = reduced
                ? 0.78 + 0.22 * (0.5 + 0.5 * sin(seed * 17))
                : 0.7 + 0.3 * (0.5 + 0.5 * sin(t * (1.0 + seed * 0.8) + seed * TAU))
            // 0.26 floor keeps the silhouette solid even deep in valleys.
            let v = clampD((0.26 + 0.74 * ridge) * pulse, 0, 1.6)
            inten[i] = v
            if v > maxI { maxI = v }
            let ang = atan2(y - cy, x - cx) / TAU // -0.5…0.5
            hueU[i] = ang * 0.5 + fld * 0.7 + hueDrift
        }
        let invMax = 1 / maxI

        var ctx = baseCtx

        // ── pass 0 (LIGHT only): deep-ink under-glow so the net reads on bright ──
        if !dark {
            ctx.blendMode = .normal
            for i in 0..<count {
                let d = frame.dots[i]
                let k = inten[i] * invMax
                let a = clampD((0.18 + 0.5 * k) * f, 0, 0.7)
                if a < 0.004 { continue }
                let rad = sizePx * (1.6 + 1.4 * k)
                let ink = RGBA(r: d.rgba.r * 0.55, g: d.rgba.g * 0.55, b: d.rgba.b * 0.6).withOpacity(a)
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                         with: .color(ink.color))
            }
        }

        // Bright passes: additive on dark, source-over on light.
        ctx.blendMode = dark ? .plusLighter : .normal

        // Resolve sprites ONCE per frame (drawn many times below).
        let glow = (dark && !lite) ? ctx.resolve(sprites.radial(diameter: 64, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.28, RGBA(r: 1, g: 1, b: 1, a: 0.42)),
            (0.6, RGBA(r: 1, g: 1, b: 1, a: 0.1)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ])) : nil

        // ── pass 2: pooled-light glow at every vertex ──────────────────────────
        let tint = dark ? 0.62 : 0.5
        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let k = inten[i] * invMax
            let hu = iris(hueU[i])
            let base = d.rgba
            let tr = lerp(base.r, hu.r, tint)
            let tg = lerp(base.g, hu.g, tint)
            let tb = lerp(base.b, hu.b, tint)
            let rad = sizePx * (1.5 + 2.6 * k) * (dark ? 1.15 : 0.95)
            let a = dark
                ? clampD((0.14 + 0.5 * k) * f, 0, 0.78)
                : clampD((0.4 + 0.45 * k) * f, 0, 0.92)

            if dark {
                // colored core disc (gives the glow its hue) …
                let coreA = clampD(a * 0.9, 0, 0.7)
                let cr = rad * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: x - cr, y: y - cr, width: cr * 2, height: cr * 2)),
                         with: .color(RGBA(r: tr, g: tg, b: tb).withOpacity(coreA).color))
                // … then the additive white bloom sprite (dropped when throttled).
                if let glow {
                    var g = ctx
                    g.opacity = clampD(a * 0.55, 0, 0.5)
                    g.draw(glow, in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
                }
            } else {
                // light stage: a soft colored disc reads as a luminous pool.
                ctx.fill(Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)),
                         with: .color(RGBA(r: tr, g: tg, b: tb).withOpacity(a).color))
            }
        }

        // ── pass 3: refracted filaments between bright near-neighbours ──────────
        // Source colours each segment by iris((hueU_i+hueU_nj)*0.5) and scales its
        // alpha by per-edge strength = clamp((ki+kj)*0.5-0.32,0,1)*1.5, so brighter
        // ridges grow brighter filaments and the net carries a spatial rainbow.
        // To preserve that while honouring the batched-Path rule, qualifying edges
        // are BUCKETED by mean hue into the 6 iris stops (one Path each) and the
        // bucket is stroked in its own whitened-iris colour at its mean edge
        // strength — still only ≤6 strokes/frame.
        let neighbors = frame.structure.structure(for: frame.dots, k: 6).neighbors
        if neighbors.count >= count {
            let gapSq = radius * radius * 0.16
            let nb = Self.iris.count // 6 hue buckets matching the iris stops
            var bucketPath = [Path](repeating: Path(), count: nb)
            var bucketStrSum = [Double](repeating: 0, count: nb)
            var bucketN = [Int](repeating: 0, count: nb)
            for i in 0..<count {
                let ki = inten[i] * invMax
                if ki < 0.42 { continue }
                let di = frame.dots[i]
                let list = neighbors[i]
                let lim = min(2, list.count)
                for j in 0..<lim {
                    let nj = list[j]
                    if nj <= i { continue } // each undirected edge once
                    let kj = inten[nj] * invMax
                    if kj < 0.42 { continue }
                    let dj = frame.dots[nj]
                    let dx = dj.x - di.x, dy = dj.y - di.y
                    if dx * dx + dy * dy > gapSq { continue } // don't bridge gaps
                    // per-edge strength: brighter ridges → brighter filaments.
                    let strength = clampD((ki + kj) * 0.5 - 0.32, 0, 1) * 1.5
                    // bucket by mean hue so the net keeps its spatial rainbow.
                    let hm = (hueU[i] + hueU[nj]) * 0.5
                    let b = min(nb - 1, Int(frac(hm) * Double(nb)))
                    bucketPath[b].move(to: CGPoint(x: di.x, y: di.y))
                    bucketPath[b].addLine(to: CGPoint(x: dj.x, y: dj.y))
                    bucketStrSum[b] += strength
                    bucketN[b] += 1
                }
            }
            let cap = dark ? 0.7 : 0.55
            let aBase = dark ? 0.3 : 0.22
            for b in 0..<nb {
                let n = bucketN[b]
                if n == 0 { continue }
                let meanStr = bucketStrSum[b] / Double(n)
                let a = clampD(aBase * meanStr, 0, cap) * f
                if a < 0.012 { continue }
                // representative whitened-iris hue at this bucket's ramp centre.
                let hu = iris((Double(b) + 0.5) / Double(nb))
                let fil = hu.mix(with: RGBA(r: 1, g: 1, b: 1), amount: 0.4)
                ctx.stroke(bucketPath[b], with: .color(fil.withOpacity(a).color),
                           style: StrokeStyle(lineWidth: dark ? 1 : 0.9, lineCap: .round))
            }
        }

        // ── pass 4: alpha-capped specular sparks at the brightest ridge vertices ─
        if !lite {
            let spark = ctx.resolve(sprites.radial(diameter: 32, stops: [
                (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
                (0.32, RGBA(r: 214 / 255, g: 236 / 255, b: 1, a: 0.6)),
                (1.0, RGBA(r: 190 / 255, g: 220 / 255, b: 1, a: 0.0))
            ]))
            for i in 0..<count {
                let k = inten[i] * invMax
                if k < 0.6 { continue }
                let seed = shash(Double(i) * 2.71 + 0.13)
                let tw = reduced ? 0.5 + 0.5 * sin(seed * 23) : sin(t * (1.4 + seed) + seed * TAU)
                if tw < 0.2 { continue }
                let sp = (k - 0.6) / 0.4
                let a = clampD((dark ? 0.34 : 0.26) * sp * tw * f, 0, dark ? 0.5 : 0.42)
                if a < 0.004 { continue }
                let rad = sizePx * (0.7 + 1.2 * sp)
                let d = frame.dots[i]
                var g = ctx
                g.opacity = a
                g.draw(spark, in: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2))
            }
        }

        return true
    }
}

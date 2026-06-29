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
        let accent = frame.stage.accent
        let ink = frame.stage.ink

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
        // Light POOLS on the folded ridges; valleys thin out. The ridge term is
        // sharpened (cubed) so the field reads as a NETWORK of bright filaments
        // rather than a uniform wash of blobs — the caustic signature.
        var maxI = 1e-4
        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let fld = fbm2(x * fs + phase * 0.6, y * fs - phase * 0.4)
            var ridge = abs(sin((fld * 2.4 + phase) * Double.pi))
            ridge = ridge * ridge * ridge // sharpen → crisp light filaments, deep valleys
            let seed = shash(Double(i) * 1.37 + 0.5)
            let pulse = reduced
                ? 0.78 + 0.22 * (0.5 + 0.5 * sin(seed * 17))
                : 0.7 + 0.3 * (0.5 + 0.5 * sin(t * (1.0 + seed * 0.8) + seed * TAU))
            // 0.22 floor keeps the silhouette a solid luminous body even in valleys
            // (the bloom layer carries presence there); the ridges supply structure.
            let v = clampD((0.22 + 0.92 * ridge) * pulse, 0, 1.7)
            inten[i] = v
            if v > maxI { maxI = v }
            let ang = atan2(y - cy, x - cx) / TAU // -0.5…0.5
            hueU[i] = ang * 0.5 + fld * 0.7 + hueDrift
        }
        let invMax = 1 / maxI

        // ── build the refracted filament net ONCE (reused by bloom + crisp) ─────
        // Link bright ridge points (k≥0.4) to their ≤2 nearest neighbours when both
        // sit on a ridge and the gap is short, so the net reinforces the outline.
        // Edges are bucketed by mean hue into the 6 iris stops → ≤6 batched strokes.
        let nb = Self.iris.count
        var bucketPath = [Path](repeating: Path(), count: nb)
        var bucketStrSum = [Double](repeating: 0, count: nb)
        var bucketN = [Int](repeating: 0, count: nb)
        let neighbors = frame.structure.structure(for: frame.dots, k: 6).neighbors
        if neighbors.count >= count {
            let gapSq = radius * radius * 0.16
            for i in 0..<count {
                let ki = inten[i] * invMax
                if ki < 0.4 { continue }
                let di = frame.dots[i]
                let list = neighbors[i]
                let lim = min(2, list.count)
                for j in 0..<lim {
                    let nj = list[j]
                    if nj <= i { continue } // each undirected edge once
                    let kj = inten[nj] * invMax
                    if kj < 0.4 { continue }
                    let dj = frame.dots[nj]
                    let dx = dj.x - di.x, dy = dj.y - di.y
                    if dx * dx + dy * dy > gapSq { continue } // don't bridge gaps
                    let strength = clampD((ki + kj) * 0.5 - 0.3, 0, 1) * 1.7
                    let hm = (hueU[i] + hueU[nj]) * 0.5
                    let b = min(nb - 1, Int(frac(hm) * Double(nb)))
                    bucketPath[b].move(to: CGPoint(x: di.x, y: di.y))
                    bucketPath[b].addLine(to: CGPoint(x: dj.x, y: dj.y))
                    bucketStrSum[b] += strength
                    bucketN[b] += 1
                }
            }
        }
        @inline(__always) func bucketHue(_ b: Int) -> RGBA { iris((Double(b) + 0.5) / Double(nb)) }

        var ctx = baseCtx

        if dark {
            // ════════════════ DARK — luminous additive caustic net ════════════════

            // ── layer A: TRUE GAUSSIAN BLOOM (soft glow UNDER) ──────────────────
            // Pooled vertex glows + thick filament strokes drawn into a single
            // blurred additive layer → an Apple-grade luminous halo of pooled light
            // and refracted filaments. The heaviest pass: dropped when throttled.
            if !lite {
                let bloomR = max(2.0, sizePx * 2.2)
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: bloomR))
                    layer.blendMode = .plusLighter
                    // pooled light at every vertex (iris-tinted, sized by intensity)
                    for i in 0..<count {
                        let d = frame.dots[i]
                        let k = inten[i] * invMax
                        let hu = iris(hueU[i])
                        let col = d.rgba.mix(with: hu, amount: 0.66).mix(with: accent, amount: 0.12)
                        let rad = sizePx * (0.9 + 2.8 * k)
                        let a = clampD((0.10 + 0.5 * k) * f, 0, 0.72)
                        if a < 0.012 { continue }
                        layer.fill(
                            Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                            with: .color(col.withOpacity(a).color))
                    }
                    // refracted filaments bloom into glowing light strands
                    for b in 0..<nb {
                        let n = bucketN[b]
                        if n == 0 { continue }
                        let meanStr = bucketStrSum[b] / Double(n)
                        let a = clampD(0.42 * meanStr, 0, 0.85) * f
                        if a < 0.012 { continue }
                        let fil = bucketHue(b).mix(with: RGBA(r: 1, g: 1, b: 1), amount: 0.45)
                        layer.stroke(bucketPath[b], with: .color(fil.withOpacity(a).color),
                                     style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    }
                }
            }

            // ── layer B: saturated CORE BODY (crisp, additive) ──────────────────
            // Tight iris-tinted cores pushed toward white on the brightest ridges
            // → a hot luminous body sitting inside the soft bloom.
            ctx.blendMode = .plusLighter
            for i in 0..<count {
                let d = frame.dots[i]
                let k = inten[i] * invMax
                let hu = iris(hueU[i])
                // hue from brand→iris in glows, pushed toward white at hot cores.
                let body = d.rgba.mix(with: hu, amount: 0.6).toWhite(0.18 + 0.5 * k)
                let rad = sizePx * (0.42 + 1.25 * k)
                let a = clampD((0.20 + 0.72 * k) * f, 0, 0.95)
                if a < 0.01 { continue }
                ctx.fill(
                    Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                    with: .color(body.withOpacity(a).color))
            }

            // ── layer C: crisp refracted FILAMENTS riding the geometry ──────────
            for b in 0..<nb {
                let n = bucketN[b]
                if n == 0 { continue }
                let meanStr = bucketStrSum[b] / Double(n)
                let a = clampD(0.34 * meanStr, 0, 0.7) * f
                if a < 0.012 { continue }
                let fil = bucketHue(b).mix(with: RGBA(r: 1, g: 1, b: 1), amount: 0.55)
                ctx.stroke(bucketPath[b], with: .color(fil.withOpacity(a).color),
                           style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round))
            }

            // ── layer D: hot specular SPARKS at the brightest pools ─────────────
            if !lite {
                let spark = ctx.resolve(sprites.radial(diameter: 32, stops: [
                    (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
                    (0.32, RGBA(r: 214 / 255, g: 236 / 255, b: 1, a: 0.65)),
                    (1.0, RGBA(r: 190 / 255, g: 220 / 255, b: 1, a: 0.0))
                ]))
                for i in 0..<count {
                    let k = inten[i] * invMax
                    if k < 0.6 { continue }
                    let seed = shash(Double(i) * 2.71 + 0.13)
                    let tw = reduced ? 0.5 + 0.5 * sin(seed * 23) : sin(t * (1.4 + seed) + seed * TAU)
                    if tw < 0.2 { continue }
                    let sp = (k - 0.6) / 0.4
                    let a = clampD(0.4 * sp * tw * f, 0, 0.6)
                    if a < 0.006 { continue }
                    let rad = sizePx * (0.8 + 1.4 * sp)
                    let d = frame.dots[i]
                    var g = ctx
                    g.opacity = a
                    g.draw(spark, in: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2))
                }
            }
        } else {
            // ════════════════ LIGHT — pooled light reads on a bright canvas ═══════
            ctx.blendMode = .normal

            // ── pass 0: deep-ink under-glow (depth/shadow beneath each pool) ────
            for i in 0..<count {
                let d = frame.dots[i]
                let k = inten[i] * invMax
                let a = clampD((0.16 + 0.5 * k) * f, 0, 0.66)
                if a < 0.006 { continue }
                let rad = sizePx * (1.5 + 1.6 * k)
                // saturated brand hue darkened toward ink → a luminous shadow pool.
                let pool = d.rgba.mix(with: ink, amount: 0.42).withOpacity(a)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                    with: .color(pool.color))
            }

            // ── pass 1: saturated colored POOLS (the iridescent body) ───────────
            for i in 0..<count {
                let d = frame.dots[i]
                let k = inten[i] * invMax
                let hu = iris(hueU[i])
                let col = d.rgba.mix(with: hu, amount: 0.5)
                let rad = sizePx * (0.9 + 1.5 * k)
                let a = clampD((0.4 + 0.5 * k) * f, 0, 0.95)
                if a < 0.01 { continue }
                ctx.fill(
                    Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                    with: .color(col.withOpacity(a).color))
                // a lit highlight core → the pool reads dimensional, not a flat disc.
                if k > 0.45 {
                    let hr = rad * 0.42
                    let ha = clampD((k - 0.45) * 1.1 * f, 0, 0.7)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: d.x - hr, y: d.y - hr, width: hr * 2, height: hr * 2)),
                        with: .color(col.toWhite(0.62).withOpacity(ha).color))
                }
            }

            // ── pass 2: crisp refracted FILAMENTS (saturated iris on bright bg) ─
            for b in 0..<nb {
                let n = bucketN[b]
                if n == 0 { continue }
                let meanStr = bucketStrSum[b] / Double(n)
                let a = clampD(0.34 * meanStr, 0, 0.6) * f
                if a < 0.012 { continue }
                // keep saturation (don't whiten) so the net reads on a light canvas.
                let fil = bucketHue(b).mix(with: ink, amount: 0.18)
                ctx.stroke(bucketPath[b], with: .color(fil.withOpacity(a).color),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }

            // ── pass 3: subtle specular highlights at the brightest pools ───────
            if !lite {
                for i in 0..<count {
                    let k = inten[i] * invMax
                    if k < 0.62 { continue }
                    let seed = shash(Double(i) * 2.71 + 0.13)
                    let tw = reduced ? 0.5 + 0.5 * sin(seed * 23) : sin(t * (1.4 + seed) + seed * TAU)
                    if tw < 0.2 { continue }
                    let sp = (k - 0.62) / 0.38
                    let a = clampD(0.5 * sp * tw * f, 0, 0.55)
                    if a < 0.01 { continue }
                    let rad = sizePx * (0.4 + 0.5 * sp)
                    let d = frame.dots[i]
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                        with: .color(RGBA(r: 1, g: 1, b: 1).withOpacity(a).color))
                }
            }
        }

        return true
    }
}

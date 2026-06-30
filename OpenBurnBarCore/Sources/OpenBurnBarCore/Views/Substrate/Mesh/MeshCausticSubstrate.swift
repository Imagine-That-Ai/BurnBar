import SwiftUI

/// Caustic Pool — a continuous web of light through water.
///
/// In the dense SHAPE regime (`isShapeMode`, or settled with most dots formed) this
/// renders the original per-vertex caustic pools + refracted filament net that pool
/// light on the logo silhouette. In the sparse FREE-SWARM regime (the Atelier
/// full-bleed backdrop, ~1k dots scattered over a wide near-black field) a single
/// per-particle mark would scatter into confetti — so instead we render a CONTINUOUS
/// caustic material across the *whole* canvas:
///
///   • A coarse density/colour field is splatted from the swarm and box-blurred, so it
///     feathers gently to nothing where the swarm thins (never a hard rectangle).
///   • An animated 2-layer fbm height field is folded with `|sin|³` and crossed with a
///     decorrelated second layer → a crawling NET of thin bright caustic filaments that
///     fills the canvas like light dappling a pool floor.
///   • The net is MODULATED by the density envelope so it intensifies where the swarm
///     clusters and fades feathered where empty; coloured by the closed iris ramp
///     indexed by position + height + drift, then tinted toward the local brand colour
///     accumulated at particle positions.
///   • One true Gaussian bloom layer (the whole field at once) carries the glow; a crisp
///     additive core pass adds the hot filament cores; gated specular sparks ride the
///     brightest cells at particle positions to tie the material back to the swarm.
///
/// `reduced` freezes phase/drift into a poised shimmering still net; `batteryThrottled`
/// drops the bloom + sparks. Animated only from `frame.t` + per-cell/point hashes.
public final class MeshCausticSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    // Hoisted per-point scratch for the SHAPE regime (rebuilt when count is stable).
    private var inten: [Double] = []
    private var hueU: [Double] = []
    // Hoisted per-cell scratch for the FREE-SWARM caustic field (resized on layout change).
    private var aW: [Double] = []      // splatted density weight
    private var aR: [Double] = []      // weighted brand R
    private var aG: [Double] = []      // weighted brand G
    private var aB: [Double] = []      // weighted brand B
    private var aHue: [Double] = []    // weighted colorIndex seed
    private var blurTmp: [Double] = [] // separable-blur scratch
    private var cellI: [Double] = []   // resolved caustic intensity per cell
    private var cellR: [Double] = []   // resolved colour per cell
    private var cellG: [Double] = []
    private var cellB: [Double] = []
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

    /// 2-octave fbm — crawling ridges, cheap per sample (source `fbm2`).
    @inline(__always) private func fbm2(_ x: Double, _ y: Double) -> Double {
        vnoise(x, y) * 0.65 + vnoise(x * 2.03 + 5.2, y * 2.03 - 3.1) * 0.35
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        // Detect the dense SHAPE regime: explicit shape mode, or settled with the
        // majority of dots carrying a shape target. The sparse free-swarm backdrop
        // falls through to the continuous caustic field.
        var formed = 0
        for i in 0..<count where frame.dots[i].inShape { formed += 1 }
        let inShapeFrac = Double(formed) / Double(count)
        let shapeMode = frame.isShapeMode || (frame.settleProgress >= 0.6 && inShapeFrac > 0.5)

        // Master fade: assembly ramp (alive/dissolve/armed default to held look).
        let f = clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        if shapeMode {
            paintShapePools(frame, into: baseCtx, f: f)
        } else {
            paintCausticField(frame, into: baseCtx, f: f)
        }
        return true
    }

    // ════════════════════════════════════════════════════════════════════════════
    // FREE-SWARM — continuous caustic field across the whole canvas
    // ════════════════════════════════════════════════════════════════════════════
    private func paintCausticField(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext, f: Double) {
        let count = frame.dots.count
        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let accent = frame.stage.accent
        let ink = frame.stage.ink

        let width = frame.size.width, height = frame.size.height
        guard width > 1, height > 1 else { return }
        let minDim = min(width, height)

        // Cell step in ABSOLUTE px, proportional to the canvas (NOT cloudRadius) so the
        // caustic reads identically at a 460×320 thumbnail and full screen. Bounded so
        // it never produces giant or hairline cells.
        let step = clampD(minDim * 0.05, 12, 60)
        let cols = max(3, Int((width / step).rounded(.up)) + 1)
        let rows = max(3, Int((height / step).rounded(.up)) + 1)
        let nCells = cols * rows

        // (Re)allocate per-cell scratch on layout change; reset accumulators each frame.
        if aW.count != nCells {
            aW = [Double](repeating: 0, count: nCells)
            aR = [Double](repeating: 0, count: nCells)
            aG = [Double](repeating: 0, count: nCells)
            aB = [Double](repeating: 0, count: nCells)
            aHue = [Double](repeating: 0, count: nCells)
            blurTmp = [Double](repeating: 0, count: nCells)
            cellI = [Double](repeating: 0, count: nCells)
            cellR = [Double](repeating: 0, count: nCells)
            cellG = [Double](repeating: 0, count: nCells)
            cellB = [Double](repeating: 0, count: nCells)
        } else {
            for i in 0..<nCells { aW[i] = 0; aR[i] = 0; aG[i] = 0; aB[i] = 0; aHue[i] = 0 }
        }

        // ── splat the swarm into the density/colour grid (bilinear, O(dots)) ───────
        let invStep = 1 / step
        for i in 0..<count {
            let d = frame.dots[i]
            let gx = d.x * invStep - 0.5
            let gy = d.y * invStep - 0.5
            let c0 = Int(floor(gx)), r0 = Int(floor(gy))
            let fx = gx - Double(c0), fy = gy - Double(r0)
            let w = clampD(d.opacity, 0.2, 1.0) * (0.7 + 0.35 * (d.baseSize - 0.8))
            let rgba = d.rgba
            // 4 bilinear corners
            var cy = r0
            var wy = 1 - fy
            for sy in 0..<2 {
                if cy >= 0 && cy < rows {
                    var cxi = c0
                    var wx = 1 - fx
                    for sx in 0..<2 {
                        if cxi >= 0 && cxi < cols {
                            let ww = w * wx * wy
                            let idx = cy * cols + cxi
                            aW[idx] += ww
                            aR[idx] += ww * rgba.r
                            aG[idx] += ww * rgba.g
                            aB[idx] += ww * rgba.b
                            aHue[idx] += ww * d.colorIndex
                        }
                        cxi += 1; wx = fx
                    }
                }
                cy += 1; wy = fy
            }
        }

        // ── feather the field: separable box-blur so it spreads to fill gaps and
        //    fades gently (never hard-edged) where the swarm thins ────────────────
        blurField(&aW, cols: cols, rows: rows)
        blurField(&aW, cols: cols, rows: rows) // density twice → softer envelope
        blurField(&aR, cols: cols, rows: rows)
        blurField(&aG, cols: cols, rows: rows)
        blurField(&aB, cols: cols, rows: rows)
        blurField(&aHue, cols: cols, rows: rows)

        var maxW = 1e-4
        for v in aW where v > maxW { maxW = v }
        let invMaxW = 1 / maxW

        // ── animation drivers (frozen into a poised still under reduced motion) ────
        let phase = reduced ? 0.55 : t * (TAU * 0.08)
        let hueDrift = reduced ? 0.12 : frac(t / 16)
        // Noise frequency in PIXEL space → caustic-cell spacing ~16% of the short edge,
        // so several filament cells span the field at any resolution.
        let nf = 1.0 / max(40.0, minDim * 0.16)
        let flowX = phase * 0.25
        let flowY = -phase * 0.18
        let invW = 1 / width, invH = 1 / height

        // ── resolve the caustic web + colour per cell (one fbm sample set / cell) ──
        for r in 0..<rows {
            let py = (Double(r) + 0.5) * step
            for c in 0..<cols {
                let idx = r * cols + c
                let px = (Double(c) + 0.5) * step
                let wsum = aW[idx]
                let dn = wsum * invMaxW

                // crawling caustic net: two decorrelated folded fbm layers, crossed.
                let x = px * nf, y = py * nf
                let h1 = fbm2(x + flowX, y + flowY)
                let h2 = fbm2(y * 0.92 - 11.0 - flowY, x * 0.92 + 7.0 + flowX)
                let s1 = abs(sin((h1 * 2.6 + phase) * .pi))
                let s2 = abs(sin((h2 * 2.6 - phase * 0.8) * .pi))
                let r1 = s1 * s1 * s1
                let r2 = s2 * s2 * s2
                let cross = r1 * r2
                let web = r1 * 0.7 + r2 * 0.55 + cross * cross * 1.1

                // envelope: feathered density gate with a faint baseline so the web
                // dapples the whole field even at sparse density, intensifying in clusters.
                let env = smoothstep(0.0, 0.55, dn + 0.16)
                cellI[idx] = clampD(web * env, 0, 1.5)

                // hue: iris ramp indexed by position + height + drift, tinted toward the
                // local accumulated brand colour at particle positions.
                let posU = (px * invW * 0.55 + py * invH * 0.45) * 0.5
                let lhue = wsum > 1e-4 ? aHue[idx] / wsum : 0
                var col = iris(posU + h1 * 0.55 + lhue * 0.5 + hueDrift)
                if wsum > 1e-4 {
                    let inv = 1 / wsum
                    let brand = RGBA(r: aR[idx] * inv, g: aG[idx] * inv, b: aB[idx] * inv)
                    col = col.mix(with: brand, amount: 0.3 * clampD(dn, 0, 1))
                }
                col = col.mix(with: accent, amount: 0.08)
                cellR[idx] = col.r; cellG[idx] = col.g; cellB[idx] = col.b
            }
        }

        var ctx = baseCtx

        if dark {
            // ── layer A: TRUE GAUSSIAN BLOOM — the whole field in one blurred pass ──
            if !lite {
                let bloomR = clampD(step * 0.72, 3, 26)
                let discR = step * 0.95
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: bloomR))
                    layer.blendMode = .plusLighter
                    for r in 0..<rows {
                        let py = (Double(r) + 0.5) * step
                        for c in 0..<cols {
                            let idx = r * cols + c
                            let k = cellI[idx]
                            if k < 0.045 { continue }
                            let a = clampD(k * 0.55 * f, 0, 0.82)
                            if a < 0.012 { continue }
                            let px = (Double(c) + 0.5) * step
                            let col = RGBA(r: cellR[idx], g: cellG[idx], b: cellB[idx], a: a)
                            layer.fill(
                                Path(ellipseIn: CGRect(x: px - discR, y: py - discR, width: discR * 2, height: discR * 2)),
                                with: .color(col.color))
                        }
                    }
                }
            }

            // ── layer B: crisp hot filament CORES (additive, pushed toward white) ──
            ctx.blendMode = .plusLighter
            for r in 0..<rows {
                let py = (Double(r) + 0.5) * step
                for c in 0..<cols {
                    let idx = r * cols + c
                    let k = cellI[idx]
                    if k < 0.2 { continue }
                    let kk = clampD((k - 0.2) / 1.3, 0, 1)
                    let a = clampD((0.18 + 0.7 * kk) * f, 0, 0.9)
                    if a < 0.012 { continue }
                    let rad = step * (0.28 + 0.55 * kk)
                    let px = (Double(c) + 0.5) * step
                    let col = RGBA(r: cellR[idx], g: cellG[idx], b: cellB[idx]).toWhite(0.22 + 0.5 * kk)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: px - rad, y: py - rad, width: rad * 2, height: rad * 2)),
                        with: .color(col.withOpacity(a).color))
                }
            }

            // ── layer C: specular SPARKS riding the swarm where the web is hot ─────
            if !lite {
                let spark = ctx.resolve(sprites.radial(diameter: 32, stops: [
                    (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
                    (0.32, RGBA(r: 214 / 255, g: 236 / 255, b: 1, a: 0.65)),
                    (1.0, RGBA(r: 190 / 255, g: 220 / 255, b: 1, a: 0.0))
                ]))
                for i in 0..<count {
                    let d = frame.dots[i]
                    let c = min(cols - 1, max(0, Int(d.x * invStep)))
                    let r = min(rows - 1, max(0, Int(d.y * invStep)))
                    let k = cellI[r * cols + c]
                    if k < 0.5 { continue }
                    let seed = shash(Double(i) * 2.71 + 0.13)
                    let tw = reduced ? 0.5 + 0.5 * sin(seed * 23) : sin(t * (1.3 + seed) + seed * TAU)
                    if tw < 0.25 { continue }
                    let sp = clampD((k - 0.5) / 0.6, 0, 1)
                    let a = clampD(0.42 * sp * tw * f, 0, 0.6)
                    if a < 0.008 { continue }
                    let rad = sizePx * (0.8 + 1.5 * sp)
                    var g = ctx
                    g.opacity = a
                    g.draw(spark, in: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2))
                }
            }
        } else {
            // ════════════ LIGHT — pooled caustic reads on a bright canvas ══════════
            ctx.blendMode = .normal
            let discR = step * 0.98
            for r in 0..<rows {
                let py = (Double(r) + 0.5) * step
                for c in 0..<cols {
                    let idx = r * cols + c
                    let k = cellI[idx]
                    if k < 0.045 { continue }
                    let a = clampD((0.18 + 0.55 * k) * f, 0, 0.72)
                    if a < 0.01 { continue }
                    let px = (Double(c) + 0.5) * step
                    // saturated caustic darkened toward ink → a luminous shadow pool.
                    let pool = RGBA(r: cellR[idx], g: cellG[idx], b: cellB[idx]).mix(with: ink, amount: 0.28)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: px - discR, y: py - discR, width: discR * 2, height: discR * 2)),
                        with: .color(pool.withOpacity(a).color))
                }
            }
            // crisp bright web highlights so the caustic net reads on light.
            for r in 0..<rows {
                let py = (Double(r) + 0.5) * step
                for c in 0..<cols {
                    let idx = r * cols + c
                    let k = cellI[idx]
                    if k < 0.42 { continue }
                    let kk = clampD((k - 0.42) / 1.0, 0, 1)
                    let a = clampD(0.5 * kk * f, 0, 0.6)
                    if a < 0.01 { continue }
                    let rad = step * (0.2 + 0.34 * kk)
                    let px = (Double(c) + 0.5) * step
                    let col = RGBA(r: cellR[idx], g: cellG[idx], b: cellB[idx]).toWhite(0.6)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: px - rad, y: py - rad, width: rad * 2, height: rad * 2)),
                        with: .color(col.withOpacity(a).color))
                }
            }
        }
    }

    /// Separable 1-2-1 box blur over the cell grid (in place, O(cells)).
    @inline(__always) private func blurField(_ a: inout [Double], cols: Int, rows: Int) {
        // horizontal
        for r in 0..<rows {
            let base = r * cols
            for c in 0..<cols {
                let i = base + c
                let l = c > 0 ? a[i - 1] : a[i]
                let rr = c < cols - 1 ? a[i + 1] : a[i]
                blurTmp[i] = (l + 2 * a[i] + rr) * 0.25
            }
        }
        // vertical
        for r in 0..<rows {
            let base = r * cols
            for c in 0..<cols {
                let i = base + c
                let u = r > 0 ? blurTmp[i - cols] : blurTmp[i]
                let dn = r < rows - 1 ? blurTmp[i + cols] : blurTmp[i]
                a[i] = (u + 2 * blurTmp[i] + dn) * 0.25
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════════
    // SHAPE — per-vertex pooled caustics + refracted filament net (original look)
    // ════════════════════════════════════════════════════════════════════════════
    private func paintShapePools(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext, f: Double) {
        let count = frame.dots.count
        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let cx = frame.cx, cy = frame.cy, radius = frame.cloudRadius
        let accent = frame.stage.accent
        let ink = frame.stage.ink

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
            ridge = ridge * ridge * ridge // sharpen → crisp light filaments, deep valleys
            let seed = shash(Double(i) * 1.37 + 0.5)
            let pulse = reduced
                ? 0.78 + 0.22 * (0.5 + 0.5 * sin(seed * 17))
                : 0.7 + 0.3 * (0.5 + 0.5 * sin(t * (1.0 + seed * 0.8) + seed * TAU))
            let v = clampD((0.22 + 0.92 * ridge) * pulse, 0, 1.7)
            inten[i] = v
            if v > maxI { maxI = v }
            let ang = atan2(y - cy, x - cx) / TAU // -0.5…0.5
            hueU[i] = ang * 0.5 + fld * 0.7 + hueDrift
        }
        let invMax = 1 / maxI

        // ── build the refracted filament net ONCE (reused by bloom + crisp) ─────
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
            if !lite {
                let bloomR = max(2.0, sizePx * 2.2)
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: bloomR))
                    layer.blendMode = .plusLighter
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

            ctx.blendMode = .plusLighter
            for i in 0..<count {
                let d = frame.dots[i]
                let k = inten[i] * invMax
                let hu = iris(hueU[i])
                let body = d.rgba.mix(with: hu, amount: 0.6).toWhite(0.18 + 0.5 * k)
                let rad = sizePx * (0.42 + 1.25 * k)
                let a = clampD((0.20 + 0.72 * k) * f, 0, 0.95)
                if a < 0.01 { continue }
                ctx.fill(
                    Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                    with: .color(body.withOpacity(a).color))
            }

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

            for i in 0..<count {
                let d = frame.dots[i]
                let k = inten[i] * invMax
                let a = clampD((0.16 + 0.5 * k) * f, 0, 0.66)
                if a < 0.006 { continue }
                let rad = sizePx * (1.5 + 1.6 * k)
                let pool = d.rgba.mix(with: ink, amount: 0.42).withOpacity(a)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: d.x - rad, y: d.y - rad, width: rad * 2, height: rad * 2)),
                    with: .color(pool.color))
            }

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
                if k > 0.45 {
                    let hr = rad * 0.42
                    let ha = clampD((k - 0.45) * 1.1 * f, 0, 0.7)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: d.x - hr, y: d.y - hr, width: hr * 2, height: hr * 2)),
                        with: .color(col.toWhite(0.62).withOpacity(ha).color))
                }
            }

            for b in 0..<nb {
                let n = bucketN[b]
                if n == 0 { continue }
                let meanStr = bucketStrSum[b] / Double(n)
                let a = clampD(0.34 * meanStr, 0, 0.6) * f
                if a < 0.012 { continue }
                let fil = bucketHue(b).mix(with: ink, amount: 0.18)
                ctx.stroke(bucketPath[b], with: .color(fil.withOpacity(a).color),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }

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
    }
}

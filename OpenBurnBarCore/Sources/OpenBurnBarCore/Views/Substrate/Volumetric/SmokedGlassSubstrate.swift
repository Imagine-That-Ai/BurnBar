import SwiftUI

/// Smoked Glass Slab — faithful port of imaginethat `volumetric/smoked-glass.ts`
/// `drawBody` (the only SOLID material in the family).
///
/// Each silhouette point is a small extruded glass CHIP: a rotated rounded quad
/// with a static per-point facet normal (outward bearing from the cloud centroid +
/// per-seed ±0.85rad jitter — the "facet tree" look) and a baked depth = screen
/// altitude. A single slow top-light rakes the slab — `lightAng = -1.05 + 0.5·sin(t·0.04)`
/// — so the per-chip `lit = clamp(n·light·0.5+0.5)` migrates and specular rims crawl.
/// Chips draw DEPTH-SORTED back→front (the load-bearing correctness detail) so the
/// cluster reads as one carved, semi-transparent solid. The render is layered for
/// real volumetric depth — soft glow UNDER, saturated body, hot catch ON TOP:
///   0. (DARK) a real GAUSSIAN bloom bed — every chip's color pushed toward
///      stage.accent + a jewel-ramp hue and kissed white, drawn additively into one
///      `.blur` layer so the whole field rests in a cohesive luminous wash (presence
///      floor 0.42 + a strong lit-side lift). The heaviest pass → dropped on throttle.
///   1. the depth-sorted colored smoked BASE slabs (.normal) — `lerp(color, cool-slate,
///      smoke)` shaded `·(0.58+0.34·depth)` (back of the slab darker), alpha rising with
///      depth so the nearer face reads as solid mass and the chips stay LEGIBLE.
///   2. light, GATED TO THE LIT SIDE so the shadow side stays deep (the key to depth,
///      not a whiteout): a directional corner SHEEN sprite at the lit corner, a
///      breathing interior TRAPPED-GLOW radial (`lit>0.44`), and a tight HOT CORE
///      sprite on the strongest catches (`lit>0.66`) — additive on dark / source-over
///      on light. On LIGHT a soft contact SHADOW under each chip gives stacked depth.
///   3. a face-culled near-white specular RIM stroke on facets whose `n·light ≥ 0.45`,
///      twinkling on `t·1.7+phase` (dropped under throttle).
/// Sub-pixel sway (`sin/cos(t·~0.5+phase)`) breathes the volume without blurring the
/// silhouette. `reduced` → a poised STILL slab (light frozen at -1.05, breath 0.6,
/// no sway, twinkle 0.7). Normals/depth/phase/rotation and the depth draw-order are
/// baked once per count; sprites (sheen / trapped-glow / hot-core) resolve once per
/// frame and draw many.
///
/// Premium vs. the source's 12 baked linear-gradient chip sprites: the cool→rim
/// facet ramp is reproduced as an OFFSET radial sheen sprite at the lit corner
/// (light catching one edge) over a depth-shaded colored body, plus a real Gaussian
/// bloom bed the source can't cheaply do on web — so the slab glows on dark, reads
/// crisply on light, and never collapses to flat dots or blows out to white mush.
public final class SmokedGlassSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // ── baked per-point facet field (rebuilt only when the point count changes) ──
    private var n = -1
    private var nxA: [Double] = []    // facet normal x
    private var nyA: [Double] = []    // facet normal y
    private var depthA: [Double] = [] // 0 far → 1 near (== screen altitude)
    private var phaseA: [Double] = [] // per-seed sway / twinkle phase
    private var rotC: [Double] = []   // cos(atan2(ny,nx)·0.5) — quad rotation
    private var rotS: [Double] = []   // sin(atan2(ny,nx)·0.5)
    private var orderA: [Int] = []    // draw order: back (low depth) → front (high)
    // ── per-frame scratch (reused across passes; no per-frame allocation) ──
    private var swX: [Double] = []
    private var swY: [Double] = []
    private var litA: [Double] = []

    /// Bake normals, depth, phase, per-chip rotation and the back→front draw order.
    /// Purely a function of i + screen position (matches source `ensureField`).
    private func buildField(_ frame: SwarmSubstrateFrame) {
        let count = frame.dots.count
        n = count
        nxA = [Double](repeating: 0, count: count)
        nyA = [Double](repeating: 0, count: count)
        depthA = [Double](repeating: 0, count: count)
        phaseA = [Double](repeating: 0, count: count)
        rotC = [Double](repeating: 0, count: count)
        rotS = [Double](repeating: 0, count: count)
        orderA = Array(0..<count)
        swX = [Double](repeating: 0, count: count)
        swY = [Double](repeating: 0, count: count)
        litA = [Double](repeating: 0, count: count)
        guard count > 0 else { return }

        let cx = frame.cx, cy = frame.cy
        var minY = frame.dots[0].y, maxY = frame.dots[0].y
        for d in frame.dots {
            if d.y < minY { minY = d.y }
            if d.y > maxY { maxY = d.y }
        }
        let span = (maxY - minY) == 0 ? 1 : (maxY - minY)

        for i in 0..<count {
            let d = frame.dots[i]
            let fi = Double(i)
            let seed = shash(fi * 1.37 + 0.5)
            // facet normal: outward bearing from the centroid (faces fan like a cut
            // crystal) + per-seed jitter so neighbours catch light at slight angles.
            let bearing = atan2(d.y - cy, d.x - cx)
            let jit = (shash(fi * 2.71 + 0.13) - 0.5) * 1.7
            let a = bearing + jit
            nxA[i] = cos(a)
            nyA[i] = sin(a)
            // depth = altitude: lower-on-screen chips are NEARER (drawn last).
            depthA[i] = (d.y - minY) / span
            phaseA[i] = seed * TAU
            let half = atan2(nyA[i], nxA[i]) * 0.5
            rotC[i] = cos(half)
            rotS[i] = sin(half)
        }
        // depth-order is stable (altitude is static), so sort once per count change.
        orderA.sort { depthA[$0] < depthA[$1] }
    }

    /// A rotated rounded-quad chip path centred at (cx,cy); `rc`,`rs` = cos/sin of
    /// the chip's (pre-baked) `ang·0.5` rotation. Matches the source roundRect quad.
    @inline(__always)
    private func chipPath(_ cx: Double, _ cy: Double, _ r: Double, _ rc: Double, _ rs: Double) -> Path {
        let xf = CGAffineTransform(a: rc, b: rs, c: -rs, d: rc, tx: cx, ty: cy)
        let rect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        return Path(roundedRect: rect, cornerRadius: r * 0.42).applying(xf)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }
        if n != count { buildField(frame) }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let t = frame.t
        let radius = frame.cloudRadius
        let sizePx = frame.sizePx
        // fade-in × (no in-place fracture in the substrate): formGate 0.5…1.
        let f = clampD(frame.settleProgress, 0, 1) * 0.5 + 0.5

        // single global top-light direction (frozen in a poised pose under reduced).
        let lightAng = reduced ? -1.05 : -1.05 + 0.5 * sin(t * 0.04)
        let lx = cos(lightAng), ly = sin(lightAng)
        // 1.8s breath modulates the trapped-glow alpha (the medium inhaling).
        let breath = reduced ? 0.6 : 0.5 + 0.5 * sin(t * (TAU / 1.8))
        // chip footprint scales with the cloud so it stays a packed solid. Slightly
        // larger than the source so the slab reads as solid mass, not gappy dots.
        let chipR = clampD(sizePx * 2.0 + radius * 0.013, 1.7, 8)

        // smoked, low-saturation cool slate the base is pulled toward.
        let smoke = dark ? 0.30 : 0.18
        let coolR = dark ? 122.0 / 255 : 70.0 / 255
        let coolG = dark ? 142.0 / 255 : 84.0 / 255
        let coolB = dark ? 178.0 / 255 : 116.0 / 255

        // jewel glow tint per chip — its own color mixed toward stage.accent and a
        // jewel-ramp sample (richer than a flat accent), used for the bloom bed.
        let accent = frame.stage.accent

        // ── per-frame preloop: sub-pixel sway + facet lighting (reused by all passes)
        for i in 0..<count {
            let d = frame.dots[i]
            var x = d.x, y = d.y
            if !reduced {
                // nearer chips (high depth) sway a touch more; never enough to blur.
                let swAmp = 0.5 + 0.7 * depthA[i]
                x += sin(t * 0.5 + phaseA[i]) * swAmp
                y += cos(t * 0.46 + phaseA[i] * 1.3) * swAmp * 0.7
            }
            swX[i] = x
            swY[i] = y
            let ndl = nxA[i] * lx + nyA[i] * ly        // -1…1
            litA[i] = clampD(ndl * 0.5 + 0.5, 0, 1)    // 0 away → 1 toward light
        }

        // ── cached sprites (resolved ONCE per frame, drawn many) ─────────────────
        // soft inner trapped-glow radial: light caught in the medium.
        let trapImg = baseCtx.resolve(sprites.radial(diameter: 44, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.95)),
            (0.42, RGBA(r: 1, g: 1, b: 1, a: 0.34)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))
        // a soft directional sheen — the bright catch where a facet meets the light.
        let sheenImg = baseCtx.resolve(sprites.radial(diameter: 52, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.45, RGBA(r: 1, g: 1, b: 1, a: 0.38)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))
        // a tight hot core for the most strongly-lit chips (the brightest catch).
        let coreImg = baseCtx.resolve(sprites.whiteGlow(diameter: 48))

        // ── layer 0 (DARK only): a real GAUSSIAN bloom bed under the slab. Each
        //    chip's color, pushed toward accent + a jewel-ramp hue and kissed white,
        //    is drawn additively into one blurred layer so the whole field rests in
        //    a cohesive luminous wash — brighter on the lit side, never empty on the
        //    shadow side. This is the heaviest extra pass → dropped under throttle. ─
        if dark && !lite {
            let bloomDisc = chipR * 2.7
            let blurR = max(4.0, chipR * 1.9)
            let bloom = baseCtx
            bloom.drawLayer { layer in
                layer.addFilter(.blur(radius: blurR))
                layer.blendMode = .plusLighter
                for i in 0..<count {
                    let d = frame.dots[i]
                    let lit = litA[i]
                    let dep = depthA[i]
                    // jewel-tinted glow: own color → accent → ramp hue, lifted white.
                    let hue = accent.mix(with: SubstrateRamp.sample(SubstrateRamp.iris, d.colorIndex), amount: 0.34)
                    let gcol = d.rgba.mix(with: hue, amount: 0.42).toWhite(0.10)
                    // presence everywhere (0.42 floor) + a strong lit-side lift.
                    let k = (0.42 + 0.58 * lit) * (0.7 + 0.3 * dep)
                    let a = clampD(0.16 * k * f, 0, 0.42)
                    layer.fill(
                        Path(ellipseIn: CGRect(x: d.x - bloomDisc, y: d.y - bloomDisc,
                                               width: bloomDisc * 2, height: bloomDisc * 2)),
                        with: .color(gcol.withOpacity(a).color))
                }
            }
        }

        // colored smoked base fill for chip `i` (the glass body mass). Deeper chips
        // sit darker (back of the slab); nearer chips brighter + more opaque so the
        // depth stack reads as one carved solid.
        @inline(__always)
        func baseColor(_ i: Int) -> RGBA {
            let base = frame.dots[i].rgba
            let dep = depthA[i]
            let shade = 0.58 + 0.34 * dep
            let r0 = lerp(base.r, coolR, smoke) * shade
            let g0 = lerp(base.g, coolG, smoke) * shade
            let b0 = lerp(base.b, coolB, smoke) * shade
            let a = clampD((dark ? 0.5 + 0.32 * dep : 0.6 + 0.24 * dep) * f, 0, dark ? 0.92 : 0.95)
            return RGBA(r: clampD(r0, 0, 1), g: clampD(g0, 0, 1), b: clampD(b0, 0, 1), a: a)
        }

        if dark {
            // ── DARK ──────────────────────────────────────────────────────────────
            // Body (.normal, back→front): the depth-sorted colored smoked slabs. The
            // additive light layers COMMUTE, so we draw all bodies first (correct
            // occlusion), then all highlights in one additive pass.
            var body = baseCtx
            body.blendMode = .normal
            for oi in 0..<count {
                let i = orderA[oi]
                body.fill(chipPath(swX[i], swY[i], chipR, rotC[i], rotS[i]),
                          with: .color(baseColor(i).color))
            }

            // Highlights (.plusLighter): gated to the lit side so the shadow side
            // stays deep + smoked (real depth, not whiteout). Per chip: a corner
            // sheen catch, a breathing interior glow, and a tight hot core on the
            // brightest facets.
            var glow = baseCtx
            glow.blendMode = .plusLighter
            for i in 0..<count {
                let lit = litA[i]
                if lit <= 0.30 { continue }
                let x = swX[i], y = swY[i]
                // (a) directional sheen at the lit corner.
                let sk = smoothstep(0.30, 1.0, lit)
                let sa = clampD(0.42 * sk * f, 0, 0.55)
                if sa > 0.01 {
                    let sr = chipR * 1.05
                    let ex = x + lx * chipR * 0.5
                    let ey = y + ly * chipR * 0.5
                    glow.opacity = sa
                    glow.draw(sheenImg, in: CGRect(x: ex - sr, y: ey - sr, width: sr * 2, height: sr * 2))
                }
                // (b) breathing interior trapped glow.
                if !lite && lit > 0.44 {
                    let tg = (lit - 0.44) / 0.56
                    let ta = clampD(0.26 * tg * (0.6 + 0.4 * breath) * f, 0, 0.42)
                    if ta > 0.01 {
                        let tr = chipR * (0.7 + 0.35 * tg)
                        glow.opacity = ta
                        glow.draw(trapImg, in: CGRect(x: x - tr, y: y - tr, width: tr * 2, height: tr * 2))
                    }
                }
                // (c) tight hot core on the strongest catches (the brightest point).
                if lit > 0.66 {
                    let tw = reduced ? 0.7 : 0.6 + 0.4 * sin(t * 1.7 + phaseA[i] * 1.7)
                    let ck = smoothstep(0.66, 1.0, lit) * tw
                    let ca = clampD(0.5 * ck * f, 0, 0.7)
                    if ca > 0.01 {
                        let cr = chipR * 0.62
                        glow.opacity = ca
                        glow.draw(coreImg, in: CGRect(x: x - cr, y: y - cr, width: cr * 2, height: cr * 2))
                    }
                }
            }
        } else {
            // ── LIGHT ─────────────────────────────────────────────────────────────
            // Source-over does NOT commute, so draw each chip's full stack back→front
            // in one pass: a soft contact shadow (depth), the colored smoked body,
            // the corner sheen, and the interior glow — a nearer chip correctly
            // occludes a farther one's highlight.
            var ctx = baseCtx
            ctx.blendMode = .normal
            for oi in 0..<count {
                let i = orderA[oi]
                let x = swX[i], y = swY[i]
                let lit = litA[i]
                let dep = depthA[i]
                // (a) contact shadow under the chip → stacked-slab depth on a bright
                //     page. Nearer chips cast a stronger shadow.
                let shA = clampD((0.10 + 0.10 * dep) * f, 0, 0.22)
                if shA > 0.01 {
                    let so = chipR * 0.3
                    ctx.opacity = 1
                    ctx.fill(chipPath(x + so, y + so * 1.2, chipR, rotC[i], rotS[i]),
                             with: .color(RGBA(r: 0.20, g: 0.25, b: 0.38, a: shA).color))
                }
                // (b) colored smoked body.
                ctx.opacity = 1
                ctx.fill(chipPath(x, y, chipR, rotC[i], rotS[i]),
                         with: .color(baseColor(i).color))
                // (c) corner sheen.
                if lit > 0.28 {
                    let sk = smoothstep(0.28, 1.0, lit)
                    let sa = clampD(0.36 * sk * f, 0, 0.5)
                    if sa > 0.01 {
                        let sr = chipR * 0.95
                        let ex = x + lx * chipR * 0.46
                        let ey = y + ly * chipR * 0.46
                        ctx.opacity = sa
                        ctx.draw(sheenImg, in: CGRect(x: ex - sr, y: ey - sr, width: sr * 2, height: sr * 2))
                    }
                }
                // (d) soft interior glow.
                if !lite && lit > 0.44 {
                    let tg = (lit - 0.44) / 0.56
                    let ta = clampD(0.15 * tg * (0.6 + 0.4 * breath) * f, 0, 0.3)
                    if ta > 0.01 {
                        let tr = chipR * 0.72
                        ctx.opacity = ta
                        ctx.draw(trapImg, in: CGRect(x: x - tr, y: y - tr, width: tr * 2, height: tr * 2))
                    }
                }
            }
        }

        // ── specular rim strokes on light-facing facets (face-culled) ──────────────
        // Orientation culling so the slab catches a coherent crawling specular sheet,
        // not every chip. Crisp near-white edges, additive on dark / source-over on
        // light. An extra pass: dropped when battery-throttled.
        if !lite {
            var specCtx = baseCtx
            specCtx.blendMode = dark ? .plusLighter : .normal
            specCtx.opacity = 1
            let specCap = dark ? 0.85 : 0.62
            let lineW = dark ? 1.25 : 1.0
            for oi in 0..<count {
                let i = orderA[oi]
                let ndl = nxA[i] * lx + nyA[i] * ly
                if ndl < 0.45 { continue }                 // facet faces away → no rim
                let spec = (ndl - 0.45) / 0.55             // 0…1 over the lit band
                // faint per-chip twinkle so glints scintillate as the light drifts.
                let tw = reduced ? 0.7 : 0.65 + 0.35 * sin(t * 1.7 + phaseA[i] * 1.7)
                let a = clampD((dark ? 0.55 : 0.42) * spec * tw * f, 0, specCap)
                if a < 0.02 { continue }
                let x = swX[i], y = swY[i]
                // rim runs along the lit edge (perpendicular to the light dir),
                // offset toward the light so the highlight sits on the lit corner.
                let px = -ly, py = lx
                let len = chipR * (0.85 + 0.5 * spec)
                let ex = x + lx * chipR * 0.55
                let ey = y + ly * chipR * 0.55
                let white = 0.55 + 0.45 * spec
                let col = frame.dots[i].rgba.toWhite(white).withOpacity(a)
                var p = Path()
                p.move(to: CGPoint(x: ex - px * len, y: ey - py * len))
                p.addLine(to: CGPoint(x: ex + px * len, y: ey + py * len))
                specCtx.stroke(p, with: .color(col.color),
                               style: StrokeStyle(lineWidth: lineW, lineCap: .round))
            }
        }

        return true
    }
}

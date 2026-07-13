import SwiftUI
import OpenBurnBarKernel

/// Silk Filament — "Raked Light Filaments", faithful port of imaginethat
/// `glyph/stage/styles/volumetric/silk-filament.ts` drawBody.
///
/// The whole mark is ONE continuous spider-silk strand threaded through every
/// silhouette point in nearest-neighbour order (`frame.structure.order`) — so the
/// logo reads as a single living thread of light, not a field of dots. Hence
/// `suppressesGlyphs = true`.
///
/// The thread is mostly dim; a soft travelling GLINT (a gaussian brightness window
/// in arc-length `s∈[0,1]`) rakes down its length, igniting a few segments at a
/// time like a crepuscular shaft catching silk. The strand is rendered as short
/// per-segment sub-lines so each segment's alpha/width is modulated independently
/// by the rake (light travels ALONG the thread, not a hard dash). Two wrapped
/// gaussian lobes — a bright primary + faint trailing secondary — supply the rake.
///
/// Colour is a 24-step OKLab altitude ramp (cyan foot → rose crown) woven with the
/// live brand accents, baked once per accent change:
///   • `rampCore` — the grade (soft bloom halo + dim strand)
///   • `rampHot`  — graded toward white where the rake is hot (dark-page core)
///   • `rampInk`  — darkened grade (the crisp strand on a light page)
/// Per-segment hue is chosen by altitude (top of the mark → crown).
///
/// Transverse SILK SWAY nudges every vertex along its local path NORMAL by a
/// low-amplitude arc-length-phased sine (clamped well below point spacing so it
/// never blurs the silhouette). Greedy-NN order occasionally leaps across negative
/// space; segments far longer than the local mean are BROKEN so gaps read as gaps.
///
/// Compositing: dark stage additive `.plusLighter`; light stage `.normal`. The
/// strand is built as three depth layers for an Apple-grade luminous look:
///   1. a TRUE GAUSSIAN bloom (`drawLayer` + `.blur` + additive) strokes the lit
///      strand wide & saturated so light fills the silhouette and glows — soft
///      everywhere, hot along the rake (dark only);
///   2. a crisp accent-graded body HALO (dark) / a faint tinted under-wash (light);
///   3. the thin near-white CORE on top (dark) / a saturated ink strand (light).
/// To keep the draw cheap the segments are bucketed by (altitude hue × quantized
/// rake band) into ONE geometry set per bucket, stroked a few times — the
/// travelling glint stays smooth while stroke calls stay ≤ a few hundred.
///
/// `reduced` → a poised STILL frame: the rake parks (one glint mid-strand) and the
/// sway is zeroed (the bloom remains, a held lit thread). `batteryThrottled` →
/// drop only the gaussian bloom layer; the body halo is boosted to keep it glowing.
/// `count == 1` → a single soft seed. The native substrate has no destruction
/// lifecycle, so the source's dissolve/melt/armed/alive death hooks and the
/// reaction glint heads (PASS C) are intentionally omitted (held/forming look).
public final class SilkFilamentSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    // altitude ramp anchors (cool foot → warm crown), brand accents woven at bake.
    private static let foot = RGBA(r: 96.0 / 255, g: 214.0 / 255, b: 255.0 / 255) // cyan
    private static let crown = RGBA(r: 255.0 / 255, g: 168.0 / 255, b: 196.0 / 255) // rose
    private static let rampSteps = 24
    /// Quantized rake bands for batching (segments grouped per band per hue).
    private static let rakeBands = 10
    private static let bandWidth = 0.14 // covers rake range ~0…1.4

    // ── baked colour LUTs (pure OKLab math; no canvas) ──
    private var rampCore: [RGBA] = []
    private var rampHot: [RGBA] = []
    private var rampInk: [RGBA] = []
    private var bakedKey: UInt64 = .max

    // ── per-frame vertex scaffolding (reused; resized on count change) ──
    private var px: [Double] = []
    private var py: [Double] = []
    private var sArc: [Double] = []
    private var hueIdx: [Int] = []
    private var brk: [Bool] = []

    // ── reusable bucket paths (hue × rake band), reset each frame ──
    // One geometry set per bucket; stroked several times (bloom → body → core).
    private var coreBuckets: [Path] = []

    public init() {}

    public var suppressesGlyphs: Bool { true }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let t = frame.t
        let stage = frame.stage
        let sizePx = frame.sizePx

        ensureRamp(stage.accent, stage.accent2)

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // count == 1 — a single soft seed so it's never blank / never throws.
        if count < 2 {
            drawSeed(frame, ctx)
            return true
        }

        // Nearest-neighbour walk order (cached by topology in the provider).
        let s = frame.structure.structure(for: frame.dots, k: 6)
        // Guard BOTH length and value range: a cached structure from a frame with
        // a different dot count could otherwise index `frame.dots` out of bounds.
        let order: [Int] = (s.order.count == count && s.order.allSatisfy { $0 >= 0 && $0 < count })
            ? s.order : Array(0..<count)

        if px.count != count {
            px = [Double](repeating: 0, count: count)
            py = [Double](repeating: 0, count: count)
            sArc = [Double](repeating: 0, count: count)
            hueIdx = [Int](repeating: 0, count: count)
            brk = [Bool](repeating: false, count: count)
        }

        // ── form gate + dim baseline (the silhouette is ALWAYS faintly readable) ──
        let formGate = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.5 + 0.5
        // Lifted from the source's faint 0.16 so the whole strand reads as a living
        // luminous thread (not a near-black maze); the rake still pops above it.
        let baseDim = dark ? 0.24 : 0.36 // armBright == 1 (no armed hook)
        let invR = frame.cloudRadius > 0 ? 1.0 / frame.cloudRadius : 0.0
        let cy = frame.cy

        // ── rake phase, derived purely from frame.t (≈0.07 laps/s shaft) ──
        let rakePhase = reduced ? 0.0 : frac(t * 0.07)
        let p1 = reduced ? 0.5 : rakePhase
        let p2 = reduced ? 0.18 : frac(rakePhase * 0.6 + 0.37)

        // transverse sway amplitude — clamped below point spacing so the strand
        // never blurs into illegibility. spacing ≈ R / sqrt(count).
        let spacing = max(2.0, frame.cloudRadius / max(1.0, Double(count).squareRoot()))
        let sway = reduced ? 0.0 : min(spacing * 0.3, frame.cloudRadius * 0.035)

        // ── PASS A: lay out vertices, arc-length, altitude hue (un-swayed first) ──
        var prevX = 0.0, prevY = 0.0
        var total = 0.0
        for step in 0..<count {
            let d = frame.dots[order[step]]
            let bx = d.x, by = d.y
            px[step] = bx
            py[step] = by
            if step == 0 {
                sArc[step] = 0
            } else {
                let dx = bx - prevX, dy = by - prevY
                total += (dx * dx + dy * dy).squareRoot()
                sArc[step] = total
            }
            // altitude hue: top of the mark (dy < 0) → crown; bottom → foot.
            let ay = clampD(0.5 - (by - cy) * invR * 0.5, 0, 1)
            hueIdx[step] = min(Self.rampSteps - 1, max(0, Int(ay * Double(Self.rampSteps - 1) + 0.5)))
            prevX = bx
            prevY = by
        }
        let arcTotal = total > 0 ? total : 1
        let invArc = 1.0 / arcTotal
        for step in 0..<count { sArc[step] *= invArc } // → 0…1

        // break long NN leaps so the strand never slashes a chord across empty space.
        let meanStep = total / Double(max(1, count - 1))
        let breakThresh = max(meanStep * 3.2, spacing * 4)
        brk[0] = true // no segment before step 0
        for step in 1..<count {
            let segLen = (sArc[step] - sArc[step - 1]) * arcTotal
            brk[step] = segLen > breakThresh
        }

        // apply transverse sway: nudge each vertex along the local path NORMAL by a
        // sine phased by arc-length (silk swaying in still air).
        if sway > 0 {
            for step in 0..<count {
                let sParam = sArc[step]
                let a = step > 0 ? step - 1 : step
                let c2 = step < count - 1 ? step + 1 : step
                var tx = px[c2] - px[a]
                var ty = py[c2] - py[a]
                let tl = (tx * tx + ty * ty).squareRoot()
                if tl > 0 { tx /= tl; ty /= tl }
                // normal = tangent rotated 90°.
                let nx = -ty, ny = tx
                let shimmer = sin(sParam * 9 + t * 1.1) * 0.7 + sin(sParam * 21 - t * 0.7) * 0.3
                let off = shimmer * sway
                px[step] += nx * off
                py[step] += ny * off
            }
        }

        // ── geometry constants ──
        let tiny = frame.cloudRadius < 56
        let wCore = clampD(sizePx * 0.6, 0.7, 1.6)        // crisp hot core
        let wBody = max(1.0, sizePx) * 1.9                // saturated mid strand
        let wHalo = max(1.0, sizePx) * 3.2                // wide soft body halo
        let wBloom = max(1.5, sizePx) * 4.0               // blurred glow footprint
        let bloomR = clampD(sizePx * 2.8, 6, 14)          // gaussian bloom radius
        let coreMax = dark ? 1.0 : 0.92
        // The true-gaussian bloom layer is the heaviest extra pass → it is the one
        // thing we drop under battery throttle (the body/core still glow & read).
        let drawBloom = dark && !tiny && !throttled
        let drawHalo = dark && !tiny

        // ── PASS B: bucket segments by (altitude hue × rake band) into ONE geometry
        // set; each bucket is stroked several times (bloom → body → core) so the
        // travelling glint stays smooth while strokes collapse to a couple hundred.
        let nBuckets = Self.rampSteps * Self.rakeBands
        if coreBuckets.count != nBuckets {
            coreBuckets = [Path](repeating: Path(), count: nBuckets)
        } else {
            for i in 0..<nBuckets { coreBuckets[i] = Path() }
        }

        for step in 1..<count {
            if brk[step] { continue }
            let sMid = (sArc[step - 1] + sArc[step]) * 0.5
            let rk = Self.rakeAt(sMid, p1: p1, p2: p2)
            let lit = clampD(baseDim + rk, 0, 1.35) * formGate
            if lit <= 0.02 { continue }
            let band = min(Self.rakeBands - 1, max(0, Int(rk / Self.bandWidth)))
            let bucket = hueIdx[step] * Self.rakeBands + band
            coreBuckets[bucket].move(to: CGPoint(x: px[step - 1], y: py[step - 1]))
            coreBuckets[bucket].addLine(to: CGPoint(x: px[step], y: py[step]))
        }

        // representative rake/lit for a bucket band (used by every stroke pass).
        @inline(__always) func bandLit(_ band: Int) -> (Double, Double) {
            let rkRep = (Double(band) + 0.5) * Self.bandWidth
            return (rkRep, clampD(baseDim + rkRep, 0, 1.35) * formGate)
        }

        // ── DEPTH PASS 1: true GAUSSIAN bloom (the premium glow). Every lit segment
        // is stroked wide & saturated into a blurred, additive layer so the strand
        // reads as volumetric light filling the silhouette — brightest along the
        // travelling rake, a soft cyan→rose wash everywhere else.
        if drawBloom {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: bloomR))
                layer.blendMode = .plusLighter
                for hi in 0..<Self.rampSteps {
                    let cBloom = rampCore[hi]
                    for band in 0..<Self.rakeBands {
                        let bucket = hi * Self.rakeBands + band
                        if coreBuckets[bucket].isEmpty { continue }
                        let (rkRep, litRep) = bandLit(band)
                        let ab = clampD(litRep * 0.5, 0, 0.8)
                        if ab <= 0.01 { continue }
                        layer.stroke(coreBuckets[bucket],
                                     with: .color(cBloom.withOpacity(ab).color),
                                     style: StrokeStyle(lineWidth: wBloom * (0.8 + 0.6 * rkRep),
                                                        lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }

        // ── DEPTH PASS 2: soft body halo. On dark a crisp wide accent-graded stroke
        // (boosted when throttled to compensate for the dropped bloom); on light a
        // low-alpha colour wash UNDER the ink for tinted depth.
        let throttleBoost = (throttled && dark) ? 1.5 : 1.0
        for hi in 0..<Self.rampSteps {
            let cHalo = rampCore[hi]
            for band in 0..<Self.rakeBands {
                let bucket = hi * Self.rakeBands + band
                if coreBuckets[bucket].isEmpty { continue }
                let (rkRep, litRep) = bandLit(band)
                if dark {
                    if !drawHalo { continue }
                    let ah = clampD(litRep * 0.34 * throttleBoost, 0, 0.6)
                    if ah <= 0.01 { continue }
                    ctx.stroke(coreBuckets[bucket],
                               with: .color(cHalo.withOpacity(ah).color),
                               style: StrokeStyle(lineWidth: wHalo * (0.7 + 0.5 * rkRep) * throttleBoost,
                                                  lineCap: .round, lineJoin: .round))
                } else {
                    // light page: a faint colour halo gives the strand depth without
                    // greying — kept well under the ink so contrast stays crisp.
                    let ah = clampD(litRep * 0.16, 0, 0.28)
                    if ah <= 0.01 { continue }
                    ctx.stroke(coreBuckets[bucket],
                               with: .color(cHalo.withOpacity(ah).color),
                               style: StrokeStyle(lineWidth: wBody * (0.8 + 0.4 * rkRep),
                                                  lineCap: .round, lineJoin: .round))
                }
            }
        }

        // ── DEPTH PASS 3: the crisp CORE on top. Near-white where the rake is hot
        // (dark), accent-graded where dim, a saturated dark strand on a light page.
        for hi in 0..<Self.rampSteps {
            for band in 0..<Self.rakeBands {
                let bucket = hi * Self.rakeBands + band
                if coreBuckets[bucket].isEmpty { continue }
                let (rkRep, litRep) = bandLit(band)
                let cCore = dark
                    ? (rkRep > 0.18 ? rampHot[hi] : rampCore[hi])
                    : rampInk[hi]
                let alpha = clampD(litRep * (dark ? 0.95 : 0.9), 0, coreMax)
                if alpha <= 0.01 { continue }
                let width = tiny ? max(0.7, wCore * 0.9) : wCore * (1 + 0.6 * rkRep)
                ctx.stroke(coreBuckets[bucket],
                           with: .color(cCore.withOpacity(alpha).color),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }

        return true
    }

    // MARK: - Rake

    /// The rake at arc-fraction `s`: two travelling gaussian lobes (a bright primary
    /// + a faint trailing secondary), wrapped on the unit circle so they glide
    /// continuously down the looping strand.
    @inline(__always)
    private static func rakeAt(_ s: Double, p1: Double, p2: Double) -> Double {
        let g1 = gauss(circDist(s, p1), 0.075) * 0.95
        let g2 = gauss(circDist(s, p2), 0.05) * 0.4
        return g1 + g2
    }

    /// gaussian falloff: exp(−(d/σ)²).
    @inline(__always)
    private static func gauss(_ d: Double, _ sigma: Double) -> Double {
        let x = d / sigma
        return exp(-x * x)
    }

    /// shortest distance between two points on the unit circle [0,1).
    @inline(__always)
    private static func circDist(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b)
        if d > 0.5 { d = 1 - d }
        return d
    }

    // MARK: - Seed (count == 1)

    /// count == 1 degenerate — a single soft seed (never blank, never throws).
    private func drawSeed(_ frame: SwarmSubstrateFrame, _ ctx: GraphicsContext) {
        let d = frame.dots[0]
        let dark = frame.dark
        let k = frame.reduced ? 0.9 : 0.7 + 0.3 * (0.5 + 0.5 * sin(frame.t * 1.2))
        let glow = rampCore.isEmpty ? frame.stage.accent : rampCore[Self.rampSteps >> 1]
        let gr = frame.sizePx * 3 * k
        let glowRect = CGRect(x: d.x - gr, y: d.y - gr, width: gr * 2, height: gr * 2)
        // dark: a true-gaussian bloom seed; light: a soft tinted halo.
        if dark {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: max(3, frame.sizePx * 2)))
                layer.blendMode = .plusLighter
                layer.fill(Path(ellipseIn: glowRect), with: .color(glow.withOpacity(0.55 * k).color))
            }
        } else {
            var g = ctx
            g.opacity = 0.22 * k
            g.fill(Path(ellipseIn: glowRect), with: .color(glow.color))
        }
        let cr = max(0.8, frame.sizePx * 0.7)
        let core: Color = dark ? .white.opacity(0.95) : frame.stage.ink.color
        var c = ctx
        c.opacity = dark ? 0.95 : 0.85
        c.fill(Path(ellipseIn: CGRect(x: d.x - cr, y: d.y - cr, width: cr * 2, height: cr * 2)),
               with: .color(core))
    }

    // MARK: - Baked OKLab altitude ramp (re-bake only on accent change)

    private func ensureRamp(_ accent: RGBA, _ accent2: RGBA) {
        var h = Hasher()
        h.combine(accent.bucketKey)
        h.combine(accent2.bucketKey)
        let key = UInt64(bitPattern: Int64(h.finalize()))
        if key == bakedKey && rampCore.count == Self.rampSteps { return }
        bakedKey = key

        // weave the brand accents into the cool→warm silk ramp (cyan foot → rose crown).
        let footC = Self.oklabMix(Self.foot, accent, 0.4)
        let crownC = Self.oklabMix(Self.crown, accent2, 0.4)
        let white = RGBA(r: 1, g: 1, b: 1)

        rampCore = []; rampHot = []; rampInk = []
        rampCore.reserveCapacity(Self.rampSteps)
        rampHot.reserveCapacity(Self.rampSteps)
        rampInk.reserveCapacity(Self.rampSteps)
        for i in 0..<Self.rampSteps {
            let tt = Double(i) / Double(Self.rampSteps - 1)
            let c = Self.oklabMix(footC, crownC, tt)
            rampCore.append(c)
            rampHot.append(Self.oklabMix(c, white, 0.72)) // near-white where the rake hits
            rampInk.append(RGBA(r: c.r * 0.45, g: c.g * 0.45, b: c.b * 0.5)) // light-page strand
        }
    }

    // ── OKLab straight-line mix (bake-time only; never in the hot loop) ──
    // Channels in 0…1 (sRGB); alpha kept at 1 (ramp colours fold opacity at draw).

    @inline(__always)
    private static func srgbToLin(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    @inline(__always)
    private static func linToSrgb(_ x: Double) -> Double {
        let v = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055
        return clampD(v, 0, 1)
    }
    private static func rgbToOklab(_ c: RGBA) -> (Double, Double, Double) {
        let r = srgbToLin(c.r), g = srgbToLin(c.g), b = srgbToLin(c.b)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = Foundation.cbrt(l), m_ = Foundation.cbrt(m), s_ = Foundation.cbrt(s)
        return (
            0.2104542553 * l_ + 0.793617785 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.428592205 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.808675766 * s_
        )
    }
    private static func oklabToRgb(_ lab: (Double, Double, Double)) -> RGBA {
        let l_ = lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2
        let m_ = lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2
        let s_ = lab.0 - 0.0894841775 * lab.1 - 1.291485548 * lab.2
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return RGBA(
            r: linToSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            g: linToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            b: linToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s)
        )
    }
    private static func oklabMix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        let la = rgbToOklab(a), lb = rgbToOklab(b)
        return oklabToRgb((
            la.0 + (lb.0 - la.0) * t,
            la.1 + (lb.1 - la.1) * t,
            la.2 + (lb.2 - la.2) * t
        ))
    }
}

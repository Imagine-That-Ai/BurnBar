import SwiftUI

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
/// Compositing: dark stage additive `.plusLighter`; light stage `.normal`. Per
/// non-tiny segment on dark: a wide soft bloom HALO then a thin CORE drawing the
/// exact outline; on light only the crisp ink core. To keep the draw cheap the
/// segments are bucketed by (altitude hue × quantized rake band) and each bucket
/// strokes ONE batched Path — the travelling glint stays smooth while stroke calls
/// stay ≤ a couple hundred instead of one-per-segment.
///
/// `reduced` → a poised STILL frame: the rake parks (one glint mid-strand) and the
/// sway is zeroed. `batteryThrottled` → drop the bloom halo, keep the crisp core.
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
    private var coreBuckets: [Path] = []
    private var haloBuckets: [Path] = []

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
        let baseDim = dark ? 0.16 : 0.34 // armBright == 1 (no armed hook)
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
        let drawHalo = dark && !tiny && !throttled
        let wHalo = max(1.0, sizePx) * 3.0
        let wCore = clampD(sizePx * 0.6, 0.7, 1.6)
        let coreMax = dark ? 1.0 : 0.92

        // ── PASS B: bucket segments by (altitude hue × rake band), stroke once each.
        // Each segment's rake is evaluated at its midpoint; bucketing keeps the
        // travelling glint smooth while collapsing ~count strokes to a couple hundred.
        let nBuckets = Self.rampSteps * Self.rakeBands
        if coreBuckets.count != nBuckets {
            coreBuckets = [Path](repeating: Path(), count: nBuckets)
            haloBuckets = [Path](repeating: Path(), count: nBuckets)
        } else {
            for i in 0..<nBuckets { coreBuckets[i] = Path(); haloBuckets[i] = Path() }
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
            if drawHalo {
                haloBuckets[bucket].move(to: CGPoint(x: px[step - 1], y: py[step - 1]))
                haloBuckets[bucket].addLine(to: CGPoint(x: px[step], y: py[step]))
            }
        }

        // Stroke the halo first (wide soft bloom), then the crisp core on top.
        if drawHalo {
            for hi in 0..<Self.rampSteps {
                let cHalo = rampCore[hi]
                for band in 0..<Self.rakeBands {
                    let bucket = hi * Self.rakeBands + band
                    if haloBuckets[bucket].isEmpty { continue }
                    let rkRep = (Double(band) + 0.5) * Self.bandWidth
                    let litRep = clampD(baseDim + rkRep, 0, 1.35) * formGate
                    let ah = clampD(litRep * 0.32, 0, 0.5)
                    if ah <= 0.01 { continue }
                    ctx.stroke(haloBuckets[bucket],
                               with: .color(cHalo.withOpacity(ah).color),
                               style: StrokeStyle(lineWidth: wHalo * (0.7 + 0.5 * rkRep),
                                                  lineCap: .round, lineJoin: .round))
                }
            }
        }

        for hi in 0..<Self.rampSteps {
            for band in 0..<Self.rakeBands {
                let bucket = hi * Self.rakeBands + band
                if coreBuckets[bucket].isEmpty { continue }
                let rkRep = (Double(band) + 0.5) * Self.bandWidth
                let litRep = clampD(baseDim + rkRep, 0, 1.35) * formGate
                // near-white where the rake is hot (dark); accent-graded where dim;
                // a baked dark ink strand on a light page.
                let cCore = dark
                    ? (rkRep > 0.18 ? rampHot[hi] : rampCore[hi])
                    : rampInk[hi]
                let alpha = clampD(litRep * (dark ? 0.9 : 0.85), 0, coreMax)
                if alpha <= 0.01 { continue }
                let width = tiny ? max(0.7, wCore * 0.85) : wCore * (1 + 0.5 * rkRep)
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
        var g = ctx
        g.opacity = 0.3 * k
        g.fill(Path(ellipseIn: CGRect(x: d.x - gr, y: d.y - gr, width: gr * 2, height: gr * 2)),
               with: .color(glow.color))
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

import SwiftUI

/// Crepuscular Shafts — faithful port of imaginethat `volumetric/sunshaft.ts`.
///
/// Each silhouette point is the FOOT of a soft volumetric god-ray: a tall white
/// luminance-mask shaft (bright thin filament down center x → soft skirt; bright
/// foot blooming up to a wide soft crown), pre-tinted across a 32-step OKLab
/// accent→accent2 altitude ramp (cyan foot → rose crown). The whole cloud reads
/// as raked by a SINGLE sun: every shaft leans along one slowly-swivelling global
/// light direction (`sin(t*0.05)*8°`), so the eye sees one beam fanning through
/// dust, not noise. Per-shaft length+brightness breathe off-phase
/// (`sin(t*0.3+seed)`); a shared 1.8s smootherstep "inhale" scales all widths
/// together. ~38% of points carry a hot near-white radial CORE spring-locked on
/// the exact target — that's the legible silhouette; the soft shafts fan past it.
///
/// Compositing: DARK page lays ONE soft centered ink radial source-over first
/// (gives additive `.plusLighter` a field to sum into), then shafts + cores
/// additive. LIGHT page skips the ink and drops shaft alpha hard so it reads as
/// caustic light, not smear. A hard 0.7px source-over crisp dot per core fires at
/// small radii (`R<64`). `reduced` freezes one poised raked still frame
/// (swivel=0, widthBreath=1, static per-seed breath). `batteryThrottled` drops
/// the ink halo. Death hooks (dissolve/melt/armed/alive) are the held-look
/// identity here, so they collapse to rest and are omitted.
public final class SunshaftSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    private static let hueSteps = 32

    // Pre-tinted shaft luminance masks (white mask × OKLab altitude ramp), and the
    // near-white core colours — rebuilt only on palette change (never per frame).
    private var shaftImgs: [Image] = []
    private var coreCols: [RGBA] = []
    private var rampKey: UInt64 = .max

    // Per-point static attributes, rebuilt only on count/geometry change.
    private var attrCount = -1
    private var attrCx = 0.0, attrCy = 0.0, attrR = 0.0
    private var hueIdx: [Int] = []
    private var seedA: [Double] = []
    private var lenJit: [Double] = []
    private var isCore: [Bool] = []

    public init() {}

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }
        ensureRamp(frame.stage)
        ensureAttrs(frame)

        let dark = frame.dark
        let reduced = frame.reduced
        let throttle = frame.batteryThrottled
        let t = frame.t
        let R = frame.R, cx = frame.cx, cy = frame.cy
        let sizePx = frame.sizePx

        // assembly gate: the medium ignites as the mark forms (env == source).
        let env = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.6 + 0.4

        // ── one global single-sun direction, swivelling ~8° on a slow sin ──
        let swivel = reduced ? 0 : sin(t * 0.05) * (8 * .pi / 180)
        let baseAng = -Double.pi / 2 + swivel        // shafts shoot up, raked slightly
        let lx = cos(baseAng), ly = sin(baseAng)
        let rot = atan2(lx, -ly)                      // sprite up-axis → light vector
        // shared medium "inhale": one 1.8s width breath for every shaft together.
        let widthBreath = reduced ? 1.0
            : 0.86 + 0.28 * smootherstep(0, 1, 0.5 + 0.5 * sin(t * (TAU / 1.8)))

        let shaftH = R * 1.2
        let shaftW = max(2.0, R * 0.18)
        let shaftAlpha = dark ? 0.22 : 0.085          // light reads as caustic light
        let coreAlpha = dark ? 0.62 : 0.5

        // ── dark page: soft centered ink field so 'lighter' has somewhere to sum.
        // Light page skips it; battery-throttle drops this extra full-field halo.
        if dark && !throttle {
            var ink = baseCtx
            ink.blendMode = .normal
            let ic = RGBA(r: 6.0 / 255, g: 9.0 / 255, b: 18.0 / 255, a: 1)
            let halo = ink.resolve(sprites.radial(diameter: 256, stops: [
                (0.0, ic.withOpacity(0.55)),
                (0.15, ic.withOpacity(0.55)),
                (0.7, ic.withOpacity(0.22)),
                (1.0, ic.withOpacity(0.0)),
            ]))
            let rr = max(R * 1.9, 1)
            ink.opacity = clampD(0.5 * env, 0, 0.6)
            ink.draw(halo, in: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2))
        }

        // additive on dark (light sums), source-over on light (no blow-out).
        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // resolve the 32 pre-tinted shaft + core sprites ONCE per frame, draw many.
        let shaftRes: [GraphicsContext.ResolvedImage] = shaftImgs.map { ctx.resolve($0) }
        let coreRes: [GraphicsContext.ResolvedImage] = coreCols.map { col in
            ctx.resolve(sprites.radial(diameter: 40, stops: [
                (0.0, col.withOpacity(1.0)),
                (0.32, col.withOpacity(0.55)),
                (0.7, col.withOpacity(0.12)),
                (1.0, col.withOpacity(0.0)),
            ]))
        }
        guard shaftRes.count == Self.hueSteps else { return true }

        // ── PASS 1: the SHAFTS — one tall god-ray per point, all leaning along the
        // single global light direction, anchored AT the point (decorate outward).
        for i in 0..<count {
            let x = frame.dots[i].x, y = frame.dots[i].y
            let sh = seedA[i]
            let breath = reduced ? 0.62 + 0.2 * sin(sh) : 0.5 + 0.5 * sin(t * 0.3 + sh)
            let core = isCore[i]
            // core-locked points get a shorter, calmer beam so the silhouette stays crisp.
            let lenK = lenJit[i] * (core ? 0.62 : 1) * (0.62 + 0.55 * breath) * env
            let h = shaftH * lenK
            let w = shaftW * widthBreath * (core ? 0.78 : 1)
            let a = clampD(shaftAlpha * (0.45 + 0.85 * breath) * env, 0, 0.5)
            if a <= 0.003 || h <= 0.5 { continue }
            // orient the foot-anchored sprite along the light vector, draw foot-at-(x,y).
            var g = ctx
            g.translateBy(x: x, y: y)
            g.rotate(by: .radians(rot))
            g.opacity = a
            g.draw(shaftRes[hueIdx[i]], in: CGRect(x: -w / 2, y: -h, width: w, height: h))
        }

        // ── PASS 2: the CORES — bright near-white feet spring-locked on the exact
        // mark targets, barely twinkling. THIS is the legible silhouette.
        let coreR = max(1.4, sizePx * 1.5)
        let coreD = coreR * 2.4
        for i in 0..<count where isCore[i] {
            let x = frame.dots[i].x, y = frame.dots[i].y
            let k = reduced ? 0.85 : 0.78 + 0.22 * (0.5 + 0.5 * sin(t * 1.4 + seedA[i]))
            let a = clampD(coreAlpha * k * env, 0, 1)
            if a <= 0.003 { continue }
            var g = ctx
            g.opacity = a
            g.draw(coreRes[hueIdx[i]], in: CGRect(x: x - coreD / 2, y: y - coreD / 2,
                                                  width: coreD, height: coreD))
        }

        // ── PASS 3: small-R crispening — a hard 0.7px source-over definition dot on
        // each locked core so the silhouette reads even when the bloom smears.
        if R < 64 {
            var crisp = baseCtx
            crisp.blendMode = .normal
            let ca = clampD(0.85 * env, 0, 1)
            for i in 0..<count where isCore[i] {
                let c = frame.dots[i].rgba
                let col = RGBA(r: c.r, g: c.g, b: c.b, a: ca).color
                let x = frame.dots[i].x, y = frame.dots[i].y
                crisp.fill(Path(ellipseIn: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)),
                           with: .color(col))
            }
        }

        return true
    }

    // MARK: - per-point attributes (cheap; only on count/geometry change)

    private func ensureAttrs(_ frame: SwarmSubstrateFrame) {
        let count = frame.dots.count
        if count == attrCount && frame.cx == attrCx && frame.cy == attrCy && frame.R == attrR { return }
        attrCount = count; attrCx = frame.cx; attrCy = frame.cy; attrR = frame.R
        hueIdx = [Int](repeating: 0, count: count)
        seedA = [Double](repeating: 0, count: count)
        lenJit = [Double](repeating: 0, count: count)
        isCore = [Bool](repeating: false, count: count)
        let invR = frame.R > 0 ? 1 / frame.R : 0
        let steps = Self.hueSteps
        for i in 0..<count {
            let di = Double(i)
            let ny = (frame.dots[i].y - frame.cy) * invR
            // altitude hue: bottom (ny>0) cyan foot; top (ny<0) rose crown.
            let tt = clampD(0.5 - ny * 0.5, 0, 1)
            hueIdx[i] = min(steps - 1, max(0, Int(tt * Double(steps - 1) + 0.5)))
            seedA[i] = shash(di * 1.37 + 0.5) * TAU
            lenJit[i] = 0.7 + 0.6 * shash(di * 2.71 + 9.1)
            isCore[i] = shash(di * 0.917 + 3.3) < 0.38      // ~38% locked legibility cores
        }
    }

    // MARK: - sprite ramp bake (only on palette change)

    private func ensureRamp(_ stage: SubstrateStage) {
        var hh = Hasher(); hh.combine(stage.accent.bucketKey); hh.combine(stage.accent2.bucketKey)
        let key = UInt64(bitPattern: Int64(hh.finalize()))
        if key == rampKey && shaftImgs.count == Self.hueSteps { return }
        rampKey = key
        let white = RGBA(r: 1, g: 1, b: 1, a: 1)
        shaftImgs = []
        coreCols = []
        shaftImgs.reserveCapacity(Self.hueSteps)
        coreCols.reserveCapacity(Self.hueSteps)
        for i in 0..<Self.hueSteps {
            let tt = Double(i) / Double(Self.hueSteps - 1)
            let col = oklabMix(stage.accent, stage.accent2, tt)     // cool foot → warm crown
            shaftImgs.append(Self.bakeShaft(col))
            coreCols.append(oklabMix(col, white, 0.6))              // hot near-white foot
        }
    }

    /// Bake the tall shaft luminance mask, pre-tinted to `col`: vertical envelope
    /// (bright foot blooming up to a soft crown) × horizontal filament (tight bright
    /// center x with a soft skirt). White × col, premultiplied, once per ramp step.
    private static func bakeShaft(_ col: RGBA) -> Image {
        let W = 48, H = 256
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                                 bytesPerRow: W * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = cg.data
        else { return Image(systemName: "circle.fill") }
        let ptr = buf.bindMemory(to: UInt8.self, capacity: W * H * 4)
        let r8 = col.r, g8 = col.g, b8 = col.b
        // vertical envelope keyed on `up` (0 at foot → 1 at crown). Buffer row 0 is
        // the crown (top), row H-1 the bright foot (bottom of the produced image).
        let vStops: [(Double, Double)] = [(0.0, 0.96), (0.4, 0.46), (0.78, 0.14), (1.0, 0.0)]
        let hStops: [(Double, Double)] = [(0.0, 0.0), (0.36, 0.14), (0.5, 1.0), (0.64, 0.14), (1.0, 0.0)]
        for row in 0..<H {
            let up = Double(H - 1 - row) / Double(H - 1)
            let vA = Self.pw(vStops, up)
            let base = row * W * 4
            for cIdx in 0..<W {
                let hx = Double(cIdx) / Double(W - 1)
                let a = vA * Self.pw(hStops, hx)
                let o = base + cIdx * 4
                ptr[o + 0] = UInt8(max(0, min(255, r8 * a * 255)))
                ptr[o + 1] = UInt8(max(0, min(255, g8 * a * 255)))
                ptr[o + 2] = UInt8(max(0, min(255, b8 * a * 255)))
                ptr[o + 3] = UInt8(max(0, min(255, a * 255)))
            }
        }
        if let img = cg.makeImage() { return Image(decorative: img, scale: 1) }
        return Image(systemName: "circle.fill")
    }

    /// Piecewise-linear lookup over sorted (location, value) stops in 0…1.
    @inline(__always) private static func pw(_ stops: [(Double, Double)], _ x: Double) -> Double {
        if x <= stops[0].0 { return stops[0].1 }
        for j in 1..<stops.count {
            let (lx, lv) = stops[j - 1], (rx, rv) = stops[j]
            if x <= rx {
                let f = rx - lx <= 0 ? 0 : (x - lx) / (rx - lx)
                return lv + (rv - lv) * f
            }
        }
        return stops[stops.count - 1].1
    }

    // MARK: - OKLab straight-line mix (bake-time only; never in the hot loop)

    @inline(__always) private func srgbToLin(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    @inline(__always) private func linToSrgb(_ x: Double) -> Double {
        let v = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055
        return clampD(v, 0, 1)
    }
    private func oklabMix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        let la = rgbToOklab(a), lb = rgbToOklab(b)
        return oklabToRgb((la.0 + (lb.0 - la.0) * t,
                           la.1 + (lb.1 - la.1) * t,
                           la.2 + (lb.2 - la.2) * t))
    }
    private func rgbToOklab(_ c: RGBA) -> (Double, Double, Double) {
        let r = srgbToLin(c.r), g = srgbToLin(c.g), b = srgbToLin(c.b)
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
                1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
                0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
    }
    private func oklabToRgb(_ lab: (Double, Double, Double)) -> RGBA {
        let l_ = lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2
        let m_ = lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2
        let s_ = lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return RGBA(r: linToSrgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                    g: linToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                    b: linToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                    a: 1)
    }

    /// Ken-Perlin smootherstep (the shared medium "inhale"; the kit ships smoothstep).
    @inline(__always) private func smootherstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clampD((x - a) / (b - a == 0 ? 1 : b - a), 0, 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

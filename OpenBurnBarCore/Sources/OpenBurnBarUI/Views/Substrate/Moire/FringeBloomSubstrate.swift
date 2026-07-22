import SwiftUI
import OpenBurnBarKernel

/// Fringe Bloom — a real two-grating interferogram rendered as a CONTINUOUS glowing field.
///
/// Two slowly-drifting sinusoidal gratings beat against each other. Grating A drifts
/// `+t*0.55`, grating B drifts `-t*0.44` (rotated ~10°); the ~0.8× speed mismatch is the
/// beat envelope, so luminous moiré bands crawl diagonally and beat in and out. Contrast
/// (γ) pops the antinodes; a FLOOR lift keeps the band field continuously lit — the moiré
/// only MODULATES an already-complete field, never punches holes.
///
/// TWO REGIMES, branched on shape state so both the dense logo and the sparse Atelier
/// backdrop read as a premium interferogram:
///
/// • SPARSE / FREE swarm (`isShapeMode == false`): the fringe SCALAR FIELD is evaluated
///   continuously over a bounded-px grid that tiles the WHOLE canvas, so the bands FILL
///   the field instead of collapsing into confetti at one-mark-per-particle. A coarse
///   particle DENSITY splat feathers the field — bands intensify where the swarm clusters
///   and fade gently (never hard-edged) into empty corners — and tints it with the local
///   brand hue. The whole interferogram rests in ONE real Gaussian bloom layer; crisp
///   crest discs sharpen the antinode bands; cached white blooms seeded at each particle
///   position modulate the field with bright sparkles. Grating frequency is locked to an
///   absolute-px wavelength (`min(W,H)/8`, clamped) — NEVER cloud-radius — so a wide sparse
///   field never grows giant bands, and 460×320 thumbnails read the same as full-screen.
///
/// • SHAPE mode (`isShapeMode`, or settled with most dots `inShape`): the original dense
///   per-node interferogram — every silhouette point a soft emissive node whose brightness
///   is the fringe product — tessellates the logo silhouette exactly as before.
///
/// DARK canvas is additive (`.plusLighter`); LIGHT canvas is `.normal` with alpha carrying
/// the fringe so a bright canvas never blows out. `reduced` freezes the phases into a poised
/// still interferogram; `batteryThrottled` drops the heaviest extra passes. Driven purely by
/// `frame.t` and field-space phase — no per-frame gradients, no wall clock.
public final class FringeBloomSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // ── tunables (mirror the source) ────────────────────────────────────────
    private static let FLOOR = 0.22   // legibility glow the field always emits (lifted so bands FILL)
    private static let GAMMA = 1.7    // contrast on the fringe product (eased so bands stay luminous, antinodes still pop)
    private static let DRIFT_A = 0.55 // primary grating temporal drift (rad/s)
    private static let DRIFT_B = 0.44 // second grating drift (~0.8×) → the beat envelope
    private static let BEAT = 0.085   // slow whole-mark breathing of the carrier freq

    // ── per-layout density grid (rebuilt only when canvas geometry changes) ──
    private var gCols = 0, gRows = 0
    private var gStep: Double = 0
    private var gW: [Double] = []   // splatted particle weight
    private var gR: [Double] = []   // weight·brandR (un-normalized)
    private var gG: [Double] = []
    private var gB: [Double] = []
    // reusable scratch for the continuous field cells (cleared, capacity kept)
    private var cells: [(x: Double, y: Double, inten: Double, col: RGBA)] = []

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let cx = frame.cx, cy = frame.cy, radius = frame.cloudRadius
        let width = frame.size.width, height = frame.size.height

        // Are we forming/holding the dense logo, or scattered as the free backdrop swarm?
        var inShapeN = 0
        for i in 0..<count where frame.dots[i].inShape { inShapeN += 1 }
        let inShapeFrac = Double(inShapeN) / Double(count)
        let shaped = frame.isShapeMode || (frame.settleProgress >= 0.6 && inShapeFrac > 0.5)

        // Assembly fade. Shape mode blooms in as the mark forms; the free field keeps a
        // brighter floor so the sparse interferogram always reads as light, not embers.
        let settle = clampD(frame.settleProgress, 0, 1)
        let form = reduced ? 1.0 : (shaped ? settle * 0.55 + 0.45 : 0.6 + 0.4 * settle)

        // Grating geometry. In shape mode the frequency tracks cloud size so band count
        // reads the same on any logo. In the free field it is BOUNDED IN ABSOLUTE PX
        // (never derived from cloudRadius, which would balloon bands on a wide sparse
        // canvas) — a fixed-ish wavelength keeps thumbnails and full-screen identical.
        let beat = reduced ? 0 : sin(t * Self.BEAT) * 0.5
        let kf: Double = shaped
            ? 5.6 / max(radius, 1)
            : (2 * Double.pi) / clampD(min(width, height) / 8, 84, 150)
        let kx = kf * (1 + 0.05 * beat)
        let ky = kf * (1 + 0.05 * beat) * 0.92
        let ang2 = 0.18 // ~10° rotation for the second grating → diagonal bands
        let c2 = cos(ang2)
        let s2 = sin(ang2)
        let k2 = kf * 1.06
        let phA = reduced ? 0.6 : t * Self.DRIFT_A
        let phB = reduced ? -0.9 : -t * Self.DRIFT_B

        let floor = Self.FLOOR
        let gamma = Self.GAMMA

        // Spectral interferogram palette: real two-grating fringes carry a thin-film
        // rainbow, so the moiré bands shimmer across the iris jewel ramp.
        let iris = SubstrateRamp.iris
        let accent = frame.stage.accent

        // The interference field, sampled in the mark's own frame. Returns the
        // floor-lifted, contrast-shaped, form-gated intensity plus the blended grating
        // value that indexes the spectral ramp. Allocates nothing (cheap sin math).
        @inline(__always)
        func fringe(_ px: Double, _ py: Double) -> (inten: Double, gmix: Double) {
            let g1 = 0.5 + 0.5 * sin(px * kx + py * ky * 0.18 + phA)
            let u2 = px * c2 - py * s2
            let g2 = 0.5 + 0.5 * sin(u2 * k2 + phB)
            var inten = pow(g1 * g2, gamma)
            inten = floor + (1 - floor) * inten
            inten *= form
            return (inten, g1 * 0.5 + g2 * 0.5)
        }

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Resolve the additive bloom sprite ONCE per frame (dark only), draw many.
        // Exact source stops: white@0 → .62@.18 → .22@.42 → .05@.72 → clear@1.
        let glow = dark ? ctx.resolve(sprites.radial(diameter: 64, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 1.0)),
            (0.18, RGBA(r: 1, g: 1, b: 1, a: 0.62)),
            (0.42, RGBA(r: 1, g: 1, b: 1, a: 0.22)),
            (0.72, RGBA(r: 1, g: 1, b: 1, a: 0.05)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ])) : nil

        if shaped {
            paintShape(frame, ctx: ctx, fringe: fringe, glow: glow,
                       dark: dark, lite: lite, sizePx: sizePx, cx: cx, cy: cy,
                       iris: iris, accent: accent, floor: floor, count: count)
        } else {
            paintField(frame, ctx: ctx, fringe: fringe, glow: glow,
                       dark: dark, lite: lite, reduced: reduced, sizePx: sizePx,
                       cx: cx, cy: cy, width: width, height: height, iris: iris, accent: accent, count: count)
        }

        return true
    }

    // ══════════════════════════════════════════════════════════════════════════
    // FREE / SPARSE REGIME — continuous interferogram that fills the whole canvas,
    // feathered + tinted by the particle density field.
    // ══════════════════════════════════════════════════════════════════════════
    private func paintField(
        _ frame: SwarmSubstrateFrame,
        ctx: GraphicsContext,
        fringe: (Double, Double) -> (inten: Double, gmix: Double),
        glow: GraphicsContext.ResolvedImage?,
        dark: Bool, lite: Bool, reduced: Bool, sizePx: Double,
        cx: Double, cy: Double, width: Double, height: Double,
        iris: [RGBA], accent: RGBA, count: Int
    ) {
        // Fine fringe grid step: BOUNDED IN PX (sizePx-nudged, clamped), then capped so
        // total cell work stays O(~targetCells) on any canvas — wide screens coarsen, they
        // never explode. ~4 samples per wavelength keeps the bands smooth under the bloom.
        let area = max(width * height, 1)
        let targetCells = lite ? 1500.0 : 2800.0
        let stepMin = clampD(sizePx * 7.0, 15, 24)
        let gs = max(stepMin, (area / targetCells).squareRoot())

        // ── coarse particle density splat (feathers + tints the field) ──────────
        let cd = max(gs * 2.4, 42)
        let cols = max(2, Int((width / cd).rounded(.up)) + 1)
        let rows = max(2, Int((height / cd).rounded(.up)) + 1)
        if cols != gCols || rows != gRows || cd != gStep {
            gCols = cols; gRows = rows; gStep = cd
            let n = cols * rows
            gW = Array(repeating: 0, count: n)
            gR = Array(repeating: 0, count: n)
            gG = Array(repeating: 0, count: n)
            gB = Array(repeating: 0, count: n)
        } else {
            for i in 0..<gW.count { gW[i] = 0; gR[i] = 0; gG[i] = 0; gB[i] = 0 }
        }
        let invCd = 1 / cd
        let twoSig2 = 2 * cd * cd          // Gaussian σ = cd → a soft, wide feather
        for i in 0..<count {
            let d = frame.dots[i]
            let ix = Int(floor(d.x * invCd - 0.5))
            let iy = Int(floor(d.y * invCd - 0.5))
            let cr = d.rgba
            var jj = iy - 2
            while jj <= iy + 2 {
                if jj >= 0 && jj < rows {
                    let cyp = (Double(jj) + 0.5) * cd
                    let ddy = d.y - cyp
                    let base = jj * cols
                    var ii = ix - 2
                    while ii <= ix + 2 {
                        if ii >= 0 && ii < cols {
                            let cxp = (Double(ii) + 0.5) * cd
                            let ddx = d.x - cxp
                            let w = exp(-(ddx * ddx + ddy * ddy) / twoSig2)
                            let idx = base + ii
                            gW[idx] += w
                            gR[idx] += w * cr.r
                            gG[idx] += w * cr.g
                            gB[idx] += w * cr.b
                        }
                        ii += 1
                    }
                }
                jj += 1
            }
        }
        var maxW = 1e-6
        for v in gW where v > maxW { maxW = v }
        let invMax = 1 / maxW

        // bilinear sample of the (weight, weight-averaged brand colour) field.
        @inline(__always)
        func sampleDens(_ x: Double, _ y: Double) -> (w: Double, r: Double, g: Double, b: Double) {
            let gx = x * invCd - 0.5, gy = y * invCd - 0.5
            let ix = Int(floor(gx)), iy = Int(floor(gy))
            let fx = gx - Double(ix), fy = gy - Double(iy)
            @inline(__always) func at(_ a: Int, _ b: Int) -> Int {
                let aa = min(max(a, 0), gCols - 1)
                let bb = min(max(b, 0), gRows - 1)
                return bb * gCols + aa
            }
            let i00 = at(ix, iy), i10 = at(ix + 1, iy), i01 = at(ix, iy + 1), i11 = at(ix + 1, iy + 1)
            @inline(__always) func bil(_ a: [Double]) -> Double {
                let top = a[i00] * (1 - fx) + a[i10] * fx
                let bot = a[i01] * (1 - fx) + a[i11] * fx
                return top * (1 - fy) + bot * fy
            }
            let w = bil(gW)
            let inv = w > 1e-6 ? 1 / w : 0
            return (w, bil(gR) * inv, bil(gG) * inv, bil(gB) * inv)
        }

        // ── evaluate the continuous fringe field over the canvas grid ───────────
        cells.removeAll(keepingCapacity: true)
        let fCols = max(1, Int((width / gs).rounded(.up)))
        let fRows = max(1, Int((height / gs).rounded(.up)))
        var fy = 0
        while fy < fRows {
            let y = (Double(fy) + 0.5) * gs
            let py = y - cy
            var fx = 0
            while fx < fCols {
                let x = (Double(fx) + 0.5) * gs
                let ds = sampleDens(x, y)
                let densN = ds.w * invMax
                // coverage feathers the field on at the swarm boundary (no rectangle);
                // cluster boost intensifies the bands where the swarm bunches up.
                let coverage = smoothstep(0.04, 0.20, densN)
                if coverage > 0.02 {
                    let (inten, gmix) = fringe(x - cx, py)
                    let cluster = smoothstep(0.18, 0.62, densN)
                    let fInten = inten * coverage * (0.5 + 0.9 * cluster)
                    if fInten >= 0.035 {
                        // spectral fringe tint, kissed by the local brand hue + accent.
                        let seed = frac(gmix + x * 0.00065 + y * 0.00095)
                        let spec = SubstrateRamp.sample(iris, seed)
                        let brand = RGBA(r: ds.r, g: ds.g, b: ds.b, a: 1)
                        let col = brand.mix(with: spec, amount: 0.55)
                            .mix(with: accent, amount: dark ? 0.22 : 0.05)
                            .toWhite(dark ? 0.12 : 0.0)
                        cells.append((x, y, fInten, col))
                    }
                }
                fx += 1
            }
            fy += 1
        }

        // ── (1) ONE real Gaussian bloom layer the whole interferogram rests in ──
        // Overlapping soft discs at ~cell pitch, blurred once → a continuous glowing
        // field, not dots. Additive on dark, normal (saturating haze) on light.
        let cellR = gs * 0.95
        let blurRad = gs * (dark ? 1.05 : 0.8)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: blurRad))
            layer.blendMode = dark ? .plusLighter : .normal
            for c in cells {
                let k = min(c.inten, 1.6)
                let r = cellR * (0.78 + 0.42 * min(k, 1.2))
                let a = dark ? clampD(0.5 * k, 0, 0.92) : clampD(0.3 * k, 0, 0.6)
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                           with: .color(c.col.withOpacity(a).color))
            }
        }

        // ── (2) crisp antinode crests — sharpen the bright fringe bands. The
        //     expendable extra pass → dropped under battery throttle.
        if !lite {
            let crestR = gs * 0.48
            for c in cells where c.inten > 0.6 {
                let k = min(c.inten, 1.6)
                let col = dark ? c.col.toWhite(0.34 + 0.5 * min(k - 0.6, 1.0)) : c.col.toWhite(0.0)
                let a = dark ? clampD(0.36 * (k - 0.55), 0, 0.72) : clampD(0.32 * (k - 0.55), 0, 0.55)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - crestR, y: c.y - crestR,
                                                width: crestR * 2, height: crestR * 2)),
                         with: .color(col.withOpacity(a).color))
            }
        }

        // ── (3) particle seeds — modulate the field's core brightness/colour at the
        //     actual particle positions: cached white blooms + tiny tinted bodies that
        //     light up where the swarm sits on a bright fringe band. Sizing is sizePx-
        //     bounded (never cloudRadius). On light, just crisp tinted cores.
        for i in 0..<count {
            let d = frame.dots[i]
            let (pin, pg) = fringe(d.x - cx, d.y - cy)
            let cov = smoothstep(0.04, 0.20, sampleDens(d.x, d.y).w * invMax)
            let k = clampD(pin * cov, 0, 1.6)
            if k < 0.06 { continue }
            let spec = SubstrateRamp.sample(iris, frac(pg + d.colorIndex * 0.2))
            if dark {
                if let glow {
                    let r0 = sizePx * (1.5 + 1.4 * min(k, 1.0))
                    var g = ctx
                    g.opacity = clampD(0.52 * k, 0, 0.85)
                    g.draw(glow, in: CGRect(x: d.x - r0, y: d.y - r0, width: r0 * 2, height: r0 * 2))
                }
                let body = d.rgba.mix(with: spec, amount: 0.42).toWhite(0.2 + 0.45 * min(k, 1.0))
                let br = max(0.7, sizePx * 0.66)
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - br, y: d.y - br, width: br * 2, height: br * 2)),
                         with: .color(body.withOpacity(clampD(0.5 * k, 0, 0.9)).color))
            } else {
                let col = d.rgba.mix(with: spec, amount: 0.3)
                let r = max(0.8, sizePx * 0.7)
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)),
                         with: .color(col.withOpacity(clampD(0.42 * k, 0, 0.62)).color))
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SHAPE REGIME — the original dense per-node interferogram, untouched: every
    // silhouette point a soft emissive node whose brightness is the fringe product.
    // ══════════════════════════════════════════════════════════════════════════
    private func paintShape(
        _ frame: SwarmSubstrateFrame,
        ctx: GraphicsContext,
        fringe: (Double, Double) -> (inten: Double, gmix: Double),
        glow: GraphicsContext.ResolvedImage?,
        dark: Bool, lite: Bool, sizePx: Double,
        cx: Double, cy: Double, iris: [RGBA], accent: RGBA, floor: Double, count: Int
    ) {
        // ── (0) TRUE GAUSSIAN BLOOM — the premium depth layer ────────────────────
        if !lite {
            let bloomR = sizePx * (dark ? 2.9 : 2.1)
            let blurRad = sizePx * (dark ? 3.4 : 2.3)
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: blurRad))
                layer.blendMode = dark ? .plusLighter : .normal
                for i in 0..<count {
                    let d = frame.dots[i]
                    let (inten, gmix) = fringe(d.x - cx, d.y - cy)
                    let k = clampD(inten, 0, 1.9)
                    if k < 0.05 { continue }
                    let spec = SubstrateRamp.sample(iris, frac(gmix + d.colorIndex * 0.2))
                    let glowCol = d.rgba.mix(with: spec, amount: 0.62)
                        .mix(with: accent, amount: dark ? 0.22 : 0.05)
                        .toWhite(dark ? 0.16 : 0.0)
                    let r = bloomR * (0.6 + 0.9 * min(k, 1.4))
                    let a = dark ? clampD(0.42 * k, 0, 0.88) : clampD(0.24 * k, 0, 0.5)
                    layer.fill(Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r,
                                                      width: r * 2, height: r * 2)),
                               with: .color(glowCol.withOpacity(a).color))
                }
            }
        }

        for i in 0..<count {
            let d = frame.dots[i]
            let x = d.x, y = d.y
            let px = x - cx
            let py = y - cy

            let (inten, gmix) = fringe(px, py)
            if inten <= 0 { continue }

            let spec = SubstrateRamp.sample(iris, frac(gmix + d.colorIndex * 0.2))

            if dark {
                let k = clampD(inten, 0, 1.9)
                let r0 = sizePx * (2.4 + 2.8 * min(k, 1.0))
                if let glow {
                    var g = ctx
                    g.opacity = clampD(0.44 + 0.72 * k, 0, 1.0)
                    g.draw(glow, in: CGRect(x: x - r0, y: y - r0, width: r0 * 2, height: r0 * 2))
                }
                let bodyCol = d.rgba.mix(with: spec, amount: 0.46)
                let bodyR = max(1.0, sizePx * 1.5)
                ctx.fill(Path(ellipseIn: CGRect(x: x - bodyR, y: y - bodyR,
                                                width: bodyR * 2, height: bodyR * 2)),
                         with: .color(bodyCol.withOpacity(clampD(0.64 * k, 0, 0.95)).color))
                let coreR = max(0.72, sizePx * 0.62)
                let coreCol = bodyCol.toWhite(0.36 + 0.55 * min(k, 1.0))
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(coreCol.withOpacity(clampD(0.42 + 0.6 * (k - 0.4), 0.28, 1.0)).color))
                if !lite, k > 0.7, let glow {
                    let rb = sizePx * (4.8 + 3.6 * (k - 0.7))
                    var g = ctx
                    g.opacity = clampD(0.2 * (k - 0.7) * 2.6, 0, 0.46)
                    g.draw(glow, in: CGRect(x: x - rb, y: y - rb, width: rb * 2, height: rb * 2))
                }
            } else {
                let k = clampD(inten, 0, 1.4)
                let haloCol = d.rgba.mix(with: spec, amount: 0.36)
                let haloR = sizePx * (2.0 + 1.4 * min(k, 1.0))
                ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR,
                                                width: haloR * 2, height: haloR * 2)),
                         with: .color(haloCol.withOpacity(clampD(0.26 * k, 0, 0.5)).color))
                let coreCol = d.rgba.mix(with: spec, amount: 0.26)
                let coreR = max(0.92, sizePx * 0.82)
                ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                                width: coreR * 2, height: coreR * 2)),
                         with: .color(coreCol.withOpacity(clampD(0.6 + 0.42 * (k - floor), 0.4, 0.97)).color))
            }
        }
    }
}

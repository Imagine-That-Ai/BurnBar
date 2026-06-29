import SwiftUI

// Grid resolution for the scalar height field. Coarse on purpose — marching
// squares at this size is a few-thousand-cell scan, trivial at 60fps.
private let meshGRID = 52
private let meshCELLS = meshGRID * meshGRID
// World-space margin (in cells) so the splat blur fits inside the grid.
private let meshPAD = 3
private let meshINNER_LEVELS = 7
private let meshBOUNDARY_LEVEL = 0.18 // the silhouette threshold (index contour)
// Cloud-bbox → grid span (× cloudRadius). Wider than the original 2.35 so the real
// footprint sits comfortably inside the PAD margin and the field can fall to zero
// BEFORE the grid edge — otherwise the field is clipped by the rectangle and the
// march draws straight contour runs along the grid border (the offending square).
private let meshSPAN = 2.9
// Coverage gate (footprint mask): cells whose local point density is below SKIP draw
// no contour at all (kills everything outside the cloud → no rectangular border);
// cells below FULL draw a faded/thinner "feather" segment so the silhouette fades
// softly into the empty edge instead of terminating on a hard line.
private let meshCOV_SKIP = 0.07
private let meshCOV_FULL = 0.40

/// Iso Contour — faithful port of imaginethat `glyph/stage/styles/mesh/mesh-isoline.ts` drawBody.
///
/// The mark drawn as a topographic contour map. The cloud points are splatted
/// (Gaussian) into a 52×52 density grid ONCE per layout — a smooth scalar that
/// peaks at the dense core and falls to zero outside the silhouette. Each frame
/// we composite a cheap organic fbm time-wobble onto that field, then march 8
/// iso-levels: 7 inner contours whose level window all drift together at ~0.06 Hz
/// (a living topo crawling in/out of the core, a fresh ring born as one wraps out),
/// plus one geometrically LOCKED "index" boundary contour drawn brightest/thickest
/// to anchor the read (its hue shimmers along the iris ramp). Each level is one
/// batched `Path` stroked once. DARK → additive `.plusLighter` glowing filaments
/// (the index gets 2 wide low-alpha underglow restrokes then a near-white core);
/// LIGHT → thin opaque source-over ink kept dark enough to never blow out. The
/// iris jewel ramp is derived from the brand colors. `reduced` parks the drift at
/// 0.5 with wobble/shimmer off (a poised still topo); `batteryThrottled` drops the
/// underglow restrokes. Pure stroke material → no fills, no sprites, no per-point
/// primitives. Owns the whole silhouette, so it suppresses the engine glyph pass.
public final class MeshIsolineSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    // ── cached static density field (the mark as a height map) ─────────────────
    private var field = [Double](repeating: 0, count: meshCELLS)  // base 0…1
    private var warp = [Double](repeating: 0, count: meshCELLS)    // static fbm phase
    private var scratch = [Double](repeating: 0, count: meshCELLS) // per-frame composite
    // Footprint MASK (0…1): how much real point density sits at each cell, ramped
    // gently across the cloud and forced to 0 at the grid margin. Gates the march so
    // contours exist ONLY inside the actual point cloud and dissolve at its edge —
    // this is what dismantles the bounding-rectangle read.
    private var coverage = [Double](repeating: 0, count: meshCELLS)
    private var sig = Double.nan
    private var builtDark = false
    // grid → screen mapping (built with the field).
    private var gx0 = 0.0, gy0 = 0.0, gw = 1.0, gh = 1.0
    // iris color ramp (parsed from brand colors at build time).
    private var rampLo = RGBA(r: 0.47, g: 0.71, b: 1.0)
    private var rampMid = RGBA(r: 0.59, g: 0.92, b: 1.0)
    private var rampHi = RGBA(r: 0.88, g: 0.98, b: 1.0)

    public init() {}

    public var suppressesGlyphs: Bool { true }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        let radius = frame.cloudRadius
        guard count > 0, radius > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let lite = frame.batteryThrottled
        let t = frame.t
        let cx = frame.cx, cy = frame.cy
        let accent = frame.stage.accent     // family accent — tints the hot core
        let accent2 = frame.stage.accent2   // family iris — tints the glow
        let white = RGBA(r: 1, g: 1, b: 1)

        // Rebuild the static field only when the layout (or polarity) changes —
        // mirrors the source layout signature.
        let s0 = frame.dots[0]
        let newSig = Double(count) * 131.0
            + (s0.x).rounded() * 0.13
            + (s0.y).rounded() * 0.071
            + radius.rounded() * 1.7
            + cx.rounded() * 0.011
            + cy.rounded() * 0.017
        if newSig != sig || dark != builtDark {
            sig = newSig
            rebuild(frame)
        }
        if sig.isNaN { return true } // degenerate/empty field — nothing to draw

        // Composite the live field: base + organic time wobble (no rebake).
        composite(t: t, reduced: reduced)

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // Grid → screen origin (meltY defaults to 0 for the held look).
        let x0 = gx0 - Double(meshPAD) * gw
        let y0 = gy0 - Double(meshPAD) * gh

        // Line weight scales with the mark size; bounded so filaments stay delicate.
        let baseW = clampD(radius * 0.006, 0.6, 1.5)

        // ── march every contour ONCE, cache (path + look) for the layered passes ──
        // (one marching-squares scan per level; reused across bloom + body + core).
        let loBand = meshBOUNDARY_LEVEL + 0.08
        let hiBand = 0.92
        let band = hiBand - loBand
        let drift = reduced ? 0.5 : 0.5 + 0.5 * sin(t * (TAU * 0.06))
        let spacing = band / Double(meshINNER_LEVELS)
        // Presence: the blind port sat at 0.42 (near-invisible). Drive the filaments
        // hard so the field clearly fills + glows; bloom carries the depth.
        let aGlow = dark ? 0.78 : 0.82

        // Tints (the fix asks for iris/brand ink, NOT pure white). The hot core is a
        // near-white pushed back toward the family accent so it reads luminous-jewel
        // instead of blown-out; the surrounding glow is biased into the iris ramp.
        let coreTint = white.mix(with: accent, amount: 0.20)
        let featherA = 0.45 // how strongly the edge band fades vs. the crisp interior

        struct Iso { let full: Path; let feather: Path; let body: RGBA; let glow: RGBA; let lw: Double }
        var isos: [Iso] = []
        isos.reserveCapacity(meshINNER_LEVELS)
        for n in 0..<meshINNER_LEVELS {
            var level = loBand + (Double(n) + drift) * spacing
            if level >= hiBand { level -= band } // wrap → a fresh ring born at the core
            let u = clampD((level - loBand) / band, 0, 1)
            // jewel ramp: deep iris in the flats → luminous ice toward the core.
            // Tint subtly into the canonical iris ramp, push the core toward the
            // accent-tinted near-white, and bias the glow into the family iris/accent.
            let irisStop = SubstrateRamp.sample(SubstrateRamp.iris, 0.06 + u * 0.42)
            let ramp = rampAt(u).mix(with: irisStop, amount: 0.24)
            let body = ramp.mix(with: coreTint, amount: u * u * 0.42)
            let glow = ramp.mix(with: accent2, amount: (1 - u) * 0.34)
            let lw = baseW * lerp(1.55, 0.85, u)
            // a born/dying ring fades at the band edges so the wrap is seamless.
            let edgeFade = min(1, (1 - abs(u - 0.5) * 2) * 3 + 0.18)
            let a = clampD(aGlow * edgeFade, 0, 1)
            if a <= 0.001 { continue }
            let (full, feather) = march(level: level, x0: x0, y0: y0)
            isos.append(Iso(full: full, feather: feather,
                            body: body.withOpacity(a),
                            glow: glow.withOpacity(a),
                            lw: lw))
        }

        // ── index (boundary) contour: the silhouette edge. No longer a bold locked
        // square — it rides the SAME footprint feather, so where it would trace the
        // bounding rectangle it has already been masked away, and where it follows the
        // real cloud edge it fades softly. Hue shimmers along the iris ramp.
        let shimmer = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 0.7)
        let idxCol = rampAt(lerp(0.4, 1.0, shimmer))
            .mix(with: SubstrateRamp.sample(SubstrateRamp.iris, 0.1), amount: 0.22)
        let (idxFull, idxFeather) = march(level: meshBOUNDARY_LEVEL, x0: x0, y0: y0)

        if dark {
            // ── PASS 1 · TRUE GAUSSIAN BLOOM (the depth layer) ───────────────────
            // Re-stroke the cached paths fat + bright into a blurred additive layer.
            // This is the heaviest extra pass → the only thing dropped on battery.
            if !lite {
                let bloomR = clampD(radius * 0.035, 7, 18)
                let bloom = ctx
                bloom.drawLayer { layer in
                    layer.addFilter(.blur(radius: bloomR))
                    layer.blendMode = .plusLighter
                    for iso in isos {
                        layer.stroke(iso.full, with: .color(iso.glow.color),
                                     style: StrokeStyle(lineWidth: iso.lw * 2.6,
                                                        lineCap: .round, lineJoin: .round))
                        layer.stroke(iso.feather,
                                     with: .color(iso.glow.withOpacity(iso.glow.a * featherA).color),
                                     style: StrokeStyle(lineWidth: iso.lw * 2.0,
                                                        lineCap: .round, lineJoin: .round))
                    }
                    // the silhouette edge blooms as a soft iris halo (feathered, so it
                    // glows the cloud's outline without re-drawing a hard rectangle).
                    let idxGlow = idxCol.mix(with: accent2, amount: 0.30)
                    layer.stroke(idxFull, with: .color(idxGlow.withOpacity(0.8).color),
                                 style: StrokeStyle(lineWidth: baseW * 4.4,
                                                    lineCap: .round, lineJoin: .round))
                    layer.stroke(idxFeather, with: .color(idxGlow.withOpacity(0.42).color),
                                 style: StrokeStyle(lineWidth: baseW * 3.2,
                                                    lineCap: .round, lineJoin: .round))
                }
            }

            // ── PASS 2 · SATURATED BODY (the contour filaments themselves) ───────
            for iso in isos {
                ctx.stroke(iso.full, with: .color(iso.body.color),
                           style: StrokeStyle(lineWidth: iso.lw, lineCap: .round, lineJoin: .round))
                ctx.stroke(iso.feather,
                           with: .color(iso.body.withOpacity(iso.body.a * featherA).color),
                           style: StrokeStyle(lineWidth: iso.lw * 0.82, lineCap: .round, lineJoin: .round))
            }

            // ── PASS 3 · INDEX boundary: soft underglow → iris-tinted body → core ──
            // Kept even on battery, but feathered so it dissolves at the empty edge
            // rather than nailing down a square. The core is an accent-tinted ice, no
            // longer pure white.
            ctx.stroke(idxFull, with: .color(idxCol.withOpacity(0.24).color),
                       style: StrokeStyle(lineWidth: baseW * 4.0, lineCap: .round, lineJoin: .round))
            ctx.stroke(idxFull, with: .color(idxCol.withOpacity(0.42).color),
                       style: StrokeStyle(lineWidth: baseW * 2.4, lineCap: .round, lineJoin: .round))
            let core = idxCol.mix(with: coreTint, amount: 0.6)
            ctx.stroke(idxFull, with: .color(core.color),
                       style: StrokeStyle(lineWidth: baseW * 1.6, lineCap: .round, lineJoin: .round))
            ctx.stroke(idxFeather, with: .color(core.withOpacity(0.5).color),
                       style: StrokeStyle(lineWidth: baseW * 1.2, lineCap: .round, lineJoin: .round))
        } else {
            // ── LIGHT: crisp opaque iris ink, never blows out; feathered at the edge ─
            for iso in isos {
                ctx.stroke(iso.full, with: .color(iso.body.color),
                           style: StrokeStyle(lineWidth: iso.lw * 1.15, lineCap: .round, lineJoin: .round))
                ctx.stroke(iso.feather,
                           with: .color(iso.body.withOpacity(iso.body.a * featherA).color),
                           style: StrokeStyle(lineWidth: iso.lw * 0.95, lineCap: .round, lineJoin: .round))
            }
            // a soft iris ink halo under the boundary line; both feathered so the
            // silhouette fades to nothing at the cloud edge (no rectangular frame).
            ctx.stroke(idxFull, with: .color(idxCol.withOpacity(0.30).color),
                       style: StrokeStyle(lineWidth: baseW * 3.0, lineCap: .round, lineJoin: .round))
            ctx.stroke(idxFull, with: .color(idxCol.withOpacity(0.92).color),
                       style: StrokeStyle(lineWidth: baseW * 2.0, lineCap: .round, lineJoin: .round))
            ctx.stroke(idxFeather, with: .color(idxCol.withOpacity(0.45).color),
                       style: StrokeStyle(lineWidth: baseW * 1.5, lineCap: .round, lineJoin: .round))
        }

        return true
    }

    // ── build the static density field from the actual cloud points ────────────

    private func rebuild(_ frame: SwarmSubstrateFrame) {
        let dots = frame.dots
        let count = dots.count
        let radius = frame.cloudRadius
        for i in 0..<meshCELLS { field[i] = 0; coverage[i] = 0 }
        guard count > 0, radius > 0 else { sig = .nan; return }

        // Map the cloud bbox (padded) onto the grid using centroid + radius.
        let span = radius * meshSPAN
        let half = span / 2
        gx0 = frame.cx - half
        gy0 = frame.cy - half
        let usable = Double(meshGRID - 2 * meshPAD)
        gw = span / usable
        gh = span / usable
        let inv = usable / span

        // Splat each point as a small Gaussian → a smooth soft signed-distance-
        // into-the-mark scalar (high interior, low edge, zero outside).
        let sigmaCells = 1.7
        let sig2 = 2 * sigmaCells * sigmaCells
        let rad = Int((sigmaCells * 2.4).rounded(.up))
        for p in 0..<count {
            let gxf = (dots[p].x - gx0) * inv + Double(meshPAD)
            let gyf = (dots[p].y - gy0) * inv + Double(meshPAD)
            let cgx = Int(gxf.rounded()), cgy = Int(gyf.rounded())
            let x0 = max(0, cgx - rad), x1 = min(meshGRID - 1, cgx + rad)
            let y0 = max(0, cgy - rad), y1 = min(meshGRID - 1, cgy + rad)
            if x0 > x1 || y0 > y1 { continue }
            for gy in y0...y1 {
                let dy = Double(gy) - gyf
                let rowBase = gy * meshGRID
                for gx in x0...x1 {
                    let dx = Double(gx) - gxf
                    field[rowBase + gx] += exp(-(dx * dx + dy * dy) / sig2)
                }
            }
        }

        // Normalize by the peak; gentle gamma so mid-levels spread → even contours.
        var peak = 0.0
        for i in 0..<meshCELLS where field[i] > peak { peak = field[i] }
        if peak <= 1e-6 { sig = .nan; return }
        let invPeak = 1 / peak

        // ── footprint MASK (read raw density BEFORE the gamma overwrite) ────────────
        // A gentle ramp across the cloud: 0 in the empty surround, rising smoothly to
        // 1 in the dense core, so the outermost contours land in a partial band and
        // fade rather than terminating on a hard silhouette line. Multiplied by a
        // margin window that forces the outer PAD ring to 0 → no contour can ever run
        // along the grid border, so the bounding rectangle simply cannot be drawn.
        for gy in 0..<meshGRID {
            let myEdge = min(gy, meshGRID - 1 - gy)
            for gx in 0..<meshGRID {
                let i = gy * meshGRID + gx
                let rn = field[i] * invPeak
                var cov = smoothstep(0.03, 0.5, rn)
                let m = Double(min(myEdge, min(gx, meshGRID - 1 - gx)))
                cov *= smoothstep(0.0, Double(meshPAD), m)
                coverage[i] = cov
            }
        }

        for i in 0..<meshCELLS {
            field[i] = pow(clampD(field[i] * invPeak, 0, 1), 0.78)
        }

        // Per-cell static fbm phase (the organic warp), deterministic.
        for gy in 0..<meshGRID {
            for gx in 0..<meshGRID {
                warp[gy * meshGRID + gx] =
                    vnoise(Double(gx) * 0.21, Double(gy) * 0.21)
                    + 0.5 * vnoise(Double(gx) * 0.47 + 9, Double(gy) * 0.47 - 4)
            }
        }

        buildRamp(dots: dots, dark: frame.dark)
        builtDark = frame.dark
    }

    /// iris ramp from the baked brand colors: average three sampled cloud hues,
    /// then build a cool jewel ramp (constants ported from 0…255 → 0…1 space).
    private func buildRamp(dots: [SwarmSubstrateDot], dark: Bool) {
        let count = dots.count
        let a = dots[0].rgba
        let b = dots[count / 2].rgba
        let c = dots[count - 1].rgba
        let bR = (a.r + b.r + c.r) / 3
        let bG = (a.g + b.g + c.g) / 3
        let bB = (a.b + b.b + c.b) / 3
        if dark {
            // deep jewel at low levels → luminous ice at the core.
            rampLo = RGBA(r: bR * 0.55, g: bG * 0.62, b: min(1, bB * 0.7 + 40.0 / 255.0))
            rampMid = RGBA(r: bR * 0.78 + 24.0 / 255.0, g: bG * 0.92 + 30.0 / 255.0,
                           b: min(1, bB * 0.95 + 60.0 / 255.0))
            rampHi = RGBA(r: min(1, bR * 0.7 + 150.0 / 255.0),
                          g: min(1, bG * 0.85 + 150.0 / 255.0), b: 1.0)
        } else {
            // thin saturated ink on light — dark enough to never blow out.
            rampLo = RGBA(r: bR * 0.34, g: bG * 0.32, b: bB * 0.4 + 12.0 / 255.0)
            rampMid = RGBA(r: bR * 0.42, g: bG * 0.44, b: bB * 0.5 + 18.0 / 255.0)
            rampHi = RGBA(r: bR * 0.5, g: bG * 0.56, b: bB * 0.62 + 24.0 / 255.0)
        }
    }

    /// iris ramp sampled by level u ∈ [0,1] (low → high field value).
    private func rampAt(_ u: Double) -> RGBA {
        if u < 0.5 { return rampLo.mix(with: rampMid, amount: u * 2) }
        return rampMid.mix(with: rampHi, amount: (u - 0.5) * 2)
    }

    // ── composite the live field: base + organic time wobble (cell-cheap) ───────
    private func composite(t: Double, reduced: Bool) {
        let wobAmp = reduced ? 0.0 : 0.045
        let wt = t * 0.9
        if wobAmp <= 0 {
            for i in 0..<meshCELLS { scratch[i] = field[i] }
            return
        }
        for i in 0..<meshCELLS {
            let v = field[i]
            scratch[i] = v + wobAmp * sin(wt + warp[i] * TAU) * v
        }
    }

    // ── marching squares: accumulate one threshold's segments into TWO paths ─────
    // Each cell is gated by the local footprint coverage: cells below `meshCOV_SKIP`
    // emit nothing (outside the cloud → the bounding rectangle is never drawn); cells
    // below `meshCOV_FULL` emit into `feather` (drawn faded + thinner → a soft fade to
    // the empty edge); the dense interior emits into `full` (crisp filaments).
    private func march(level: Double, x0: Double, y0: Double) -> (full: Path, feather: Path) {
        var full = Path()
        var feather = Path()
        let fld = scratch
        let cov = coverage
        let gw = self.gw, gh = self.gh
        @inline(__always) func ix(_ a: Double, _ b: Double) -> Double {
            let d = b - a
            return (level - a) / (d == 0 ? 1e-6 : d)
        }
        for gy in 0..<(meshGRID - 1) {
            let rowA = gy * meshGRID
            let rowB = rowA + meshGRID
            let cyT = y0 + Double(gy) * gh
            let cyB = cyT + gh
            for gx in 0..<(meshGRID - 1) {
                let tl = fld[rowA + gx]
                let tr = fld[rowA + gx + 1]
                let br = fld[rowB + gx + 1]
                let bl = fld[rowB + gx]
                var code = 0
                if tl > level { code |= 8 }
                if tr > level { code |= 4 }
                if br > level { code |= 2 }
                if bl > level { code |= 1 }
                if code == 0 || code == 15 { continue }
                // footprint gate — average the 4 corner masks for this cell.
                let c = (cov[rowA + gx] + cov[rowA + gx + 1]
                         + cov[rowB + gx + 1] + cov[rowB + gx]) * 0.25
                if c < meshCOV_SKIP { continue }
                let toFull = c >= meshCOV_FULL
                let cxL = x0 + Double(gx) * gw
                let cxR = cxL + gw
                // edge crossings: top(tl→tr) right(tr→br) bottom(bl→br) left(tl→bl).
                let tX = cxL + gw * ix(tl, tr)
                let rY = cyT + gh * ix(tr, br)
                let bX = cxL + gw * ix(bl, br)
                let lY = cyT + gh * ix(tl, bl)
                @inline(__always) func place(_ p: inout Path) {
                    switch code {
                    case 1, 14: seg(&p, cxL, lY, bX, cyB)
                    case 2, 13: seg(&p, bX, cyB, cxR, rY)
                    case 3, 12: seg(&p, cxL, lY, cxR, rY)
                    case 4, 11: seg(&p, tX, cyT, cxR, rY)
                    case 5:
                        seg(&p, cxL, lY, tX, cyT)
                        seg(&p, bX, cyB, cxR, rY)
                    case 6, 9: seg(&p, tX, cyT, bX, cyB)
                    case 7, 8: seg(&p, cxL, lY, tX, cyT)
                    case 10:
                        seg(&p, tX, cyT, cxR, rY)
                        seg(&p, cxL, lY, bX, cyB)
                    default: break
                    }
                }
                if toFull { place(&full) } else { place(&feather) }
            }
        }
        return (full, feather)
    }

    @inline(__always) private func seg(_ p: inout Path, _ x1: Double, _ y1: Double,
                                       _ x2: Double, _ y2: Double) {
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
    }

    // ── tiny deterministic value noise for the static per-cell warp phases ──────
    private func vhash(_ ix: Int, _ iy: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: ix &* 374_761_393 &+ iy &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h % 100_000) / 100_000
    }

    private func vnoise(_ x: Double, _ y: Double) -> Double {
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x - Double(ix), fy = y - Double(iy)
        let ux = fx * fx * (3 - 2 * fx)
        let uy = fy * fy * (3 - 2 * fy)
        let a = vhash(ix, iy)
        let b = vhash(ix + 1, iy)
        let c = vhash(ix, iy + 1)
        let d = vhash(ix + 1, iy + 1)
        return lerp(lerp(a, b, ux), lerp(c, d, ux), uy)
    }
}

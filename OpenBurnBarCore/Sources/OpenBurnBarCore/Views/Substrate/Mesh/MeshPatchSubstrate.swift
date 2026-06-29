import SwiftUI
import CoreGraphics

/// Gradient Patch — ported from imaginethat `glyph/stage/styles/mesh/mesh-patch.ts`.
///
/// A CONTINUOUS iridescent-mesh tessellation: an edge-to-edge sheet of glossy
/// stained-glass panes that covers the WHOLE canvas, brightens where the swarm
/// clusters and dissolves softly where it thins — never isolated confetti.
///
/// CONTINUOUS-SHEET PASS — kills the "huge floating gradient pieces" artifact:
///   • The grid is built over the FULL canvas (0…width × 0…height), not the cloud
///     bbox, and EVERY cell is painted as a rounded gradient pane edge-to-edge
///     (overlap ≥ 1, so no seam gaps). Pane existence is NOT decided per-particle;
///     the whole sheet is always there.
///   • A per-cell DENSITY field is splatted from the particles (normalized Gaussian
///     kernel). Density MODULATES each pane — empty cells (density ≈ 0) fade out
///     softly, mid cells feather, dense cells read saturated/opaque — so the sheet
///     feathers to nothing at the cloud silhouette with NO rectangular boundary.
///   • Each cell's hue is a Gaussian-weighted (inverse-distance) blend of the
///     particles around it, so the entire sheet is a brand-coloured stained glass.
///   • A slow 2-octave height field lifts/tilts the panes (draped breathing cloth),
///     each pane catches a small specular hotspot, an iridescent thin-film seam
///     shimmers along the grid, and ONE pooled Gaussian bloom layer glows under the
///     lit panes (dropped under battery throttle).
///   • Dense shape-mode is preserved automatically: when the cloud forms the logo,
///     the density field concentrates on the silhouette and the SAME tessellation
///     tightens onto it.
/// The grid geometry is cached per layout; the hot loop re-splats the live cloud
/// (O(dots·kernel)) and paints the cells in O(cells) with no per-frame sort.
public final class MeshPatchSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // MARK: Tunables

    /// Max grid resolution along either canvas axis (cells). The grid is ADAPTIVE —
    /// chosen so each pane stays a small, fixed SCREEN size rather than scaling with
    /// the cloud/screen (a sparse full-screen swarm must never yield huge tiles).
    private static let MAXGRID = 80
    /// Total-cell budget. Keeps the per-frame paint bounded on very wide canvases;
    /// when exceeded the cell size is grown until the count fits.
    private static let MAXCELLS = 2800
    /// Pane overlap so adjacent cells leave no seam gaps (continuous sheet).
    private static let overlap = 1.12
    /// Rounded-corner fraction of a pane half-extent — soft glossy lozenges.
    private static let cornerFrac = 0.22
    /// Gaussian splat radius (cells) and width — controls how the cloud bleeds into
    /// the density/colour field (and therefore how softly the sheet feathers).
    private static let splatR = 2
    private static let splatSigma = 0.92
    /// The dark-corner sink color (near-black with a cool iris cast) for depth.
    private static let nearBlack = RGBA(r: 18.0 / 255, g: 22.0 / 255, b: 34.0 / 255)
    /// Iridescent thin-film ramp the seam hue creeps through (looped): cyan,
    /// periwinkle, magenta, warm gold, mint.
    private static let irisRamp: [RGBA] = [
        RGBA(r: 120.0 / 255, g: 196.0 / 255, b: 255.0 / 255),
        RGBA(r: 150.0 / 255, g: 150.0 / 255, b: 255.0 / 255),
        RGBA(r: 232.0 / 255, g: 150.0 / 255, b: 232.0 / 255),
        RGBA(r: 255.0 / 255, g: 168.0 / 255, b: 150.0 / 255),
        RGBA(r: 150.0 / 255, g: 236.0 / 255, b: 210.0 / 255)
    ]

    // MARK: Per-layout cache (rebuilt when count / canvas size / settle changes)

    private var builtCount = -1          // point count this geometry was built for
    private var built = false            // membership finalized (post-assembly)?
    private var lastW = -1               // canvas width this grid was sized for
    private var lastH = -1               // canvas height
    private var cols = 0                 // grid columns over the full canvas
    private var rows = 0                 // grid rows
    private var cells = 0                // cols * rows
    private var cellW: Double = 0        // cell width  (screen px)
    private var cellH: Double = 0        // cell height (screen px)
    private var ext: Double = 0          // pane half-extent (screen px, bounded)

    // MARK: Per-frame scratch (reused; sized cols*rows)

    private var wsum: [Double] = []      // splatted weight (raw density)
    private var crsum: [Double] = []     // weighted colour accumulators
    private var cgsum: [Double] = []
    private var cbsum: [Double] = []
    private var colR: [Double] = []      // normalized per-cell blended hue
    private var colG: [Double] = []
    private var colB: [Double] = []
    private var dens: [Double] = []      // 0…1 presence (feathers field to cloud)
    private var hcache: [Double] = []    // height field per cell (this frame)

    // MARK: Deterministic field helpers

    /// Cheap 2-octave value-noise height field (deterministic, no allocation), ~[-1,1].
    @inline(__always)
    private func heightField(_ gx: Double, _ gy: Double, _ t: Double) -> Double {
        let a = sin(gx * 0.9 + t * 0.6) * cos(gy * 0.8 - t * 0.5)
              + 0.5 * sin(gx * 1.9 - gy * 1.3 + t * 0.9)
        return a / 1.5
    }

    /// Sample the looping iris ramp at phase `p` ∈ [0,∞).
    @inline(__always)
    private func irisAt(_ p: Double) -> RGBA {
        let n = Self.irisRamp.count
        let nn = Double(n)
        let fp = (p.truncatingRemainder(dividingBy: nn) + nn).truncatingRemainder(dividingBy: nn)
        let i0 = Int(fp)
        let i1 = (i0 + 1) % n
        return Self.irisRamp[i0].mix(with: Self.irisRamp[i1], amount: fp - Double(i0))
    }

    // MARK: Layout (per (count, canvas size, settle))

    /// Size an ADAPTIVE grid over the FULL canvas so every cell is a small, fixed
    /// screen-px pane (independent of how far the cloud spreads). Allocate the
    /// reusable density/colour field. Nothing positional is baked here — the field
    /// is splatted live each frame so the sheet tracks the moving cloud.
    private func layout(_ frame: SwarmSubstrateFrame) {
        let w = max(frame.size.width, 1)
        let h = max(frame.size.height, 1)
        builtCount = frame.dots.count
        built = frame.settleProgress >= 0.6 || frame.reduced
        lastW = Int(w.rounded())
        lastH = Int(h.rounded())

        // Target pane ≈ a small ceramic lozenge in SCREEN px. On a sparse full-screen
        // swarm this means MORE, still-small cells — never the giant slabs a cloud-
        // radius-scaled tile would produce.
        let targetCellPx = max(18.0, frame.sizePx * 8.5)
        var c = max(8, min(Self.MAXGRID, Int((w / targetCellPx).rounded())))
        var r = max(8, min(Self.MAXGRID, Int((h / targetCellPx).rounded())))
        // Honour the total-cell budget (grow cells, never explode the paint loop).
        if c * r > Self.MAXCELLS {
            let s = (Double(c * r) / Double(Self.MAXCELLS)).squareRoot()
            c = max(8, Int(Double(c) / s))
            r = max(8, Int(Double(r) / s))
        }
        cols = c
        rows = r
        cells = c * r
        cellW = w / Double(c)
        cellH = h / Double(r)
        // Bound the pane half-extent in absolute px (never cloud-radius scaled).
        ext = max(cellW, cellH) * 0.5 * Self.overlap

        wsum = [Double](repeating: 0, count: cells)
        crsum = [Double](repeating: 0, count: cells)
        cgsum = [Double](repeating: 0, count: cells)
        cbsum = [Double](repeating: 0, count: cells)
        colR = [Double](repeating: 0, count: cells)
        colG = [Double](repeating: 0, count: cells)
        colB = [Double](repeating: 0, count: cells)
        dens = [Double](repeating: 0, count: cells)
        hcache = [Double](repeating: 0, count: cells)
    }

    /// Splat the live cloud into the full-canvas grid with a normalized Gaussian
    /// kernel → a smooth per-cell density (presence) and an inverse-distance blend
    /// of the nearby particle hues (the stained-glass colour). This is the live work
    /// that makes the sheet brighten where the swarm clusters and feather to nothing
    /// where it thins, with no rectangular edge.
    private func splat(_ frame: SwarmSubstrateFrame) {
        let dots = frame.dots
        for i in 0..<cells { wsum[i] = 0; crsum[i] = 0; cgsum[i] = 0; cbsum[i] = 0 }

        let invCW = Double(cols) / max(frame.size.width, 1)
        let invCH = Double(rows) / max(frame.size.height, 1)
        let twoSig2 = 2 * Self.splatSigma * Self.splatSigma
        let R = Self.splatR

        for d in dots {
            // Fractional cell coordinate of the particle.
            let fx = d.x * invCW
            let fy = d.y * invCH
            let cc = Int(fx)
            let rr = Int(fy)
            let cr = d.rgba.r, cg = d.rgba.g, cb = d.rgba.b
            // Weight by particle opacity so faint dots contribute proportionally.
            let wgt0 = max(0.15, d.opacity)
            var dy = -R
            while dy <= R {
                let ry = rr + dy
                if ry >= 0 && ry < rows {
                    let ddy = (Double(ry) + 0.5) - fy
                    let base = ry * cols
                    var dx = -R
                    while dx <= R {
                        let cx = cc + dx
                        if cx >= 0 && cx < cols {
                            let ddx = (Double(cx) + 0.5) - fx
                            let dist2 = ddx * ddx + ddy * ddy
                            let wg = wgt0 * exp(-dist2 / twoSig2)
                            let idx = base + cx
                            wsum[idx] += wg
                            crsum[idx] += wg * cr
                            cgsum[idx] += wg * cg
                            cbsum[idx] += wg * cb
                        }
                        dx += 1
                    }
                }
                dy += 1
            }
        }

        // Field-relative normalizer: the typical occupied cell reads as "present",
        // truly empty cells (no dot within the splat radius) fade out, dense clusters
        // saturate. Adapts identically to a sparse uniform field and a tight logo.
        var sumW = 0.0
        var occ = 0
        for i in 0..<cells where wsum[i] > 1e-4 { sumW += wsum[i]; occ += 1 }
        let meanW = occ > 0 ? sumW / Double(occ) : 1.0
        let norm = 1.0 / max(meanW * 1.45, 1e-6)
        for i in 0..<cells {
            let w = wsum[i]
            if w > 1e-4 {
                let inv = 1.0 / w
                colR[i] = crsum[i] * inv
                colG[i] = cgsum[i] * inv
                colB[i] = cbsum[i] * inv
                dens[i] = smoothstep(0.05, 1.0, w * norm)
            } else {
                dens[i] = 0
            }
        }
    }

    // MARK: Paint

    public func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        if count <= 0 { return false }

        // (Re)layout when count, canvas size, or the forge-assembly settle changes.
        let wi = Int(max(frame.size.width, 1).rounded())
        let hi = Int(max(frame.size.height, 1).rounded())
        if count != builtCount || wi != lastW || hi != lastH
            || (!built && (frame.settleProgress >= 0.6 || frame.reduced)) {
            layout(frame)
        }
        if cells <= 0 { return false }
        splat(frame)

        let dark = frame.stage.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let accent = frame.stage.accent
        // Assembly fade ramp (held look: dissolve fade = 1).
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45
        let ht = reduced ? 0 : frame.t          // freeze the ripple under reduced motion
        let seamPhase = reduced ? 0 : frame.t * 0.18
        let baseExt = ext > 0 ? ext : frame.sizePx * 4

        // Height field per cell (logical grid coords drive the undulation phase).
        for i in 0..<cells {
            let gx = Double(i % cols)
            let gy = Double(i / cols)
            hcache[i] = heightField(gx * 0.5, gy * 0.5, ht * 0.4)
        }

        var ctx = ctx

        // Cached glossy specular sprite — resolved ONCE this frame, drawn many.
        let spot = ctx.resolve(sprites.radial(diameter: 48, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.95)),
            (0.30, RGBA(r: 1, g: 1, b: 1, a: 0.46)),
            (0.7, RGBA(r: 1, g: 1, b: 1, a: 0.08)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))

        // ── Pass A (dark only): ONE pooled Gaussian bloom under the lit panes ──
        // A single blurred additive layer pools a soft colored under-glow beneath the
        // present, high cells so the sheet visibly glows and fills its silhouette.
        // The heaviest extra pass → dropped under battery throttle.
        if dark && !throttled {
            let bloomR = max(3.0, baseExt * 1.2)
            var bctx = ctx
            bctx.blendMode = .plusLighter
            bctx.drawLayer { layer in
                layer.addFilter(.blur(radius: bloomR))
                layer.blendMode = .plusLighter
                for i in 0..<cells {
                    let dn = dens[i]
                    if dn < 0.12 { continue }
                    let hf = hcache[i]
                    let br = clampD(0.42 + 0.58 * hf, 0, 1) * dn
                    if br < 0.12 { continue }
                    let col = (i % cols)
                    let row = i / cols
                    let x = (Double(col) + 0.5) * cellW
                    let y = (Double(row) + 0.5) * cellH - hf * baseExt * 0.5
                    let glow = RGBA(r: colR[i], g: colG[i], b: colB[i])
                        .toWhite(0.26).mix(with: accent, amount: 0.18)
                    let rr = baseExt * (1.35 + 0.5 * br)
                    layer.opacity = clampD(0.55 * br * f, 0, 0.8)
                    layer.fill(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(glow.color))
                }
            }
        }

        // ── Pass B: the continuous ROUNDED gradient panes (edge-to-edge sheet) ──
        // Iterate row-major top→bottom so lower (front) panes overpaint higher ones —
        // a cheap, stable painter order for top-lit draped cloth (no per-frame sort).
        for i in 0..<cells {
            let dn = dens[i]
            if dn < 0.025 { continue }              // empty → feathered away, skip
            let hf = hcache[i]
            let col = i % cols
            let row = i / cols
            let cxp = (Double(col) + 0.5) * cellW
            let cyp = (Double(row) + 0.5) * cellH - hf * baseExt * 0.45   // draped lift

            // Pane tilt from the height-field gradient → the gradient axis + hotspot
            // slide as the sheet breathes (flat under reduced motion).
            let gx = Double(col) * 0.5, gy = Double(row) * 0.5
            let tilt: Double = reduced ? 0 : 0.20 * (
                heightField(gx + 0.6, gy, ht * 0.4) - heightField(gx - 0.6, gy, ht * 0.4)
            )
            let cosT = cos(tilt), sinT = sin(tilt)

            // Rounded, tilted glossy lozenge edge-to-edge (overlap ≥ 1 → no seam gaps).
            let rect = CGRect(x: cxp - baseExt, y: cyp - baseExt, width: baseExt * 2, height: baseExt * 2)
            let xf = CGAffineTransform(translationX: cxp, y: cyp)
                .rotated(by: tilt)
                .translatedBy(x: -cxp, y: -cyp)
            let quad = Path(roundedRect: rect, cornerRadius: baseExt * Self.cornerFrac).applying(xf)

            // Gradient axis runs top→bottom (rotated by tilt): HOT toward white on the
            // lit (high) top, sunk toward iris-tinted near-black at the bottom.
            @inline(__always) func rp(_ lx: Double, _ ly: Double) -> CGPoint {
                CGPoint(x: cxp + (lx * cosT - ly * sinT), y: cyp + (lx * sinT + ly * cosT))
            }
            let pTop = rp(-baseExt * 0.7, -baseExt)
            let pBot = rp(baseExt * 0.7, baseExt)

            let base = RGBA(r: colR[i], g: colG[i], b: colB[i])
            let litK = clampD(0.5 + 0.42 * hf, 0, 1)
            // A touch of travelling thin-film iridescence across the whole sheet.
            let iris = irisAt(seamPhase + Double(col) * 0.18 + Double(row) * 0.12)
            let topC = base.toWhite(0.12 + 0.40 * litK).mix(with: iris, amount: 0.10)
            let botC = base.mix(with: Self.nearBlack, amount: 0.20 * (1 - litK) + 0.06)
            let midC = topC.mix(with: botC, amount: 0.5)
            let grad = Gradient(stops: [
                .init(color: topC.color, location: 0.0),
                .init(color: midC.color, location: 0.5),
                .init(color: botC.color, location: 1.0)
            ])

            ctx.opacity = clampD(f * dn, 0, 1)
            ctx.fill(quad, with: .linearGradient(grad, startPoint: pTop, endPoint: pBot))

            // Hot glossy specular core toward the upper-left lit corner. Additive on
            // dark (it blooms), source-over on light (never blows out the canvas).
            let specK = clampD(litK * dn, 0, 1)
            if specK > 0.12 {
                let ox = -baseExt * 0.40, oy = -baseExt * 0.40
                let hxp = cxp + (ox * cosT - oy * sinT)
                let hyp = cyp + (ox * sinT + oy * cosT)
                let hr = baseExt * (0.78 + 0.28 * specK)
                ctx.blendMode = dark ? .plusLighter : .normal
                ctx.opacity = clampD((dark ? 0.46 : 0.32) * specK * f, 0, dark ? 0.75 : 0.46)
                ctx.draw(spot, in: CGRect(x: hxp - hr, y: hyp - hr, width: hr * 2, height: hr * 2))
                ctx.blendMode = .normal
            }

            // Hairline iridescent thin-film seam — gated by density so it reads as an
            // INTERIOR grid shimmer that fades at the cloud edge, never an outline.
            let seamA = clampD((0.18 + 0.34 * litK) * f * dn, 0, 0.72)
            if seamA > 0.02 {
                ctx.opacity = seamA
                ctx.stroke(quad, with: .color(iris.color),
                           style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }

        ctx.opacity = 1
        return true
    }
}

import SwiftUI
import CoreGraphics

/// Gradient Patch — ported from imaginethat `glyph/stage/styles/mesh/mesh-patch.ts`.
///
/// The literal anatomy of a gradient mesh. The point cloud is quantized to a
/// coarse 16×16 quad grid; each occupied cell becomes one glossy ceramic-glass
/// PANE filled with a per-cell linear gradient blended from its four sampled
/// corner brand hues (an Illustrator-mesh / Coons-patch made solid). Each pane
/// catches a single small specular hotspot in its upper-left, and a slow 2-octave
/// height field advected by `t` lifts and tilts the panes so the sheet undulates
/// like draped, breathing gradient cloth.
///
/// PREMIUM PASS — kills the square-edge artifact and raises presence/depth:
///   • NO bounding rectangle: panes are soft, ROUNDED gradient lozenges and each
///     cell is DENSITY-GATED (sparse boundary cells fade to faint soft patches and
///     shrink), so the field clips to the actual point cloud and feathers at its
///     silhouette instead of tracing a hard rounded-rectangle frame. The iris seam
///     is gated + rounded so it reads as an interior grid shimmer, never an outline.
///   • Real GAUSSIAN bloom: on dark, a single blurred `.plusLighter` layer pools a
///     soft colored under-glow beneath the lit panes (one blur for the whole field),
///     so the sheet visibly GLOWS and fills its silhouette — never faint.
///   • Layered depth: soft bloom UNDER → saturated rounded gradient body → hot white
///     specular core ON TOP. Cores push toward white; glows push toward stage accent.
/// Per-layout work (binning, corner-hue sampling, density) is cached; the hot loop
/// recomputes live centroids, the height field, the painter sort, and ≤256 panes.
public final class MeshPatchSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // MARK: Tunables

    /// Max grid resolution along the cloud's longer axis (cells). The grid is
    /// ADAPTIVE — chosen so each pane stays a small, fixed screen size rather than
    /// scaling with the cloud/screen (a sparse full-screen swarm must never yield
    /// huge tiles). This cap bounds memory/cell count on very large fields.
    private static let MAXGRID = 80
    /// Pane overlap so adjacent (interior) cells leave no seam gaps.
    private static let overlap = 1.18
    /// Rounded-corner fraction of a pane half-extent — soft glossy lozenges, not
    /// hard squares (so the boundary never reads as a rectangle).
    private static let cornerFrac = 0.24
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

    // MARK: Per-layout cache (built once per (count, settled-layout))

    private var builtCount = -1          // point count this geometry was built for
    private var built = false            // membership finalized (post-assembly)?
    private var cells = 0                // occupied cell count
    private var storedExt: Double = 0    // per-cell half-extent in screen px
    private var cellOf: [Int] = []       // point → cell index (−1 unassigned)
    private var cgx: [Double] = []       // per-cell logical grid X (height-field phase)
    private var cgy: [Double] = []       // per-cell logical grid Y
    private var cnt: [Int] = []          // members per cell
    private var dens: [Double] = []      // 0…1 density weight (clips field to cloud)
    private var cornerHue: [RGBA] = []   // per-cell sampled corner hues, [c*4 + {TL,TR,BR,BL}]

    // MARK: Per-frame scratch (reused; sized with the cells)

    private var csx: [Double] = []       // live screen centroid X
    private var csy: [Double] = []       // live screen centroid Y
    private var sumx: [Double] = []
    private var sumy: [Double] = []
    private var hcache: [Double] = []    // height field per cell (this frame)
    private var order: [Int] = []        // painter sort (back→front by height)

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
        let f = (p.truncatingRemainder(dividingBy: nn) + nn).truncatingRemainder(dividingBy: nn)
        let i0 = Int(f)
        let i1 = (i0 + 1) % n
        return Self.irisRamp[i0].mix(with: Self.irisRamp[i1], amount: f - Double(i0))
    }

    // MARK: Binning (per layout)

    /// Quantize the cloud to a coarse quad grid, dedupe occupied cells, sample each
    /// cell's four corner brand hues, and compute a per-cell DENSITY weight (so the
    /// painted field clips to the dense cloud and feathers at its silhouette rather
    /// than presenting a hard grid boundary). Everything positional is live.
    private func bin(_ frame: SwarmSubstrateFrame) {
        let dots = frame.dots
        let count = dots.count
        let cx = frame.cx, cy = frame.cy
        builtCount = count
        built = frame.settleProgress >= 0.6 || frame.reduced

        let span = max(frame.cloudRadius, 1) * 2.1
        // Target pane ≈ a small ceramic lozenge in SCREEN px (independent of how
        // far the cloud spreads). Adapt the grid so cells land at this size; on a
        // sparse full-screen swarm that means MORE, still-small cells — never the
        // ~50px slabs a fixed 16×16 grid produced over a wide field.
        let targetCellPx = max(13.0, frame.sizePx * 8.5)
        let grid = max(8, min(Self.MAXGRID, Int((span / targetCellPx).rounded())))
        let inv = Double(grid) / span
        let half = Double(grid) * 0.5

        // First pass: discover occupied cells via a dense grid×grid lookup.
        var keyToCell = [Int](repeating: -1, count: grid * grid)
        var cellOf = [Int](repeating: -1, count: count)
        var cellCount = 0
        for i in 0..<count {
            let gx = min(grid - 1, max(0, Int((dots[i].x - cx) * inv + half)))
            let gy = min(grid - 1, max(0, Int((dots[i].y - cy) * inv + half)))
            let key = gy * grid + gx
            var c = keyToCell[key]
            if c < 0 { c = cellCount; cellCount += 1; keyToCell[key] = c }
            cellOf[i] = c
        }

        cells = cellCount
        self.cellOf = cellOf
        cgx = [Double](repeating: 0, count: cellCount)
        cgy = [Double](repeating: 0, count: cellCount)
        cnt = [Int](repeating: 0, count: cellCount)
        dens = [Double](repeating: 1, count: cellCount)
        cornerHue = [RGBA](repeating: Self.nearBlack, count: cellCount * 4)
        csx = [Double](repeating: 0, count: cellCount)
        csy = [Double](repeating: 0, count: cellCount)
        sumx = [Double](repeating: 0, count: cellCount)
        sumy = [Double](repeating: 0, count: cellCount)
        hcache = [Double](repeating: 0, count: cellCount)
        order = Array(0..<cellCount)
        // Hard-cap the pane half-extent so even at the grid clamp (huge fields)
        // panes never balloon — discrete small lozenges with gaps when sparse,
        // tessellated when the shape is dense.
        storedExt = min(span / Double(grid) / 2, targetCellPx * 0.62)

        // Recover each cell's logical grid coord (for the height-field phase).
        for key in 0..<keyToCell.count {
            let c = keyToCell[key]
            if c < 0 { continue }
            cgx[c] = Double(key % grid)
            cgy[c] = Double(key / grid)
        }

        // Per-cell screen centroid + member tally.
        for i in 0..<count {
            let c = cellOf[i]
            csx[c] += dots[i].x
            csy[c] += dots[i].y
            cnt[c] += 1
        }
        for c in 0..<cellCount {
            let k = Double(max(1, cnt[c]))
            csx[c] /= k
            csy[c] /= k
        }

        // Density weight: a fully-occupied interior cell holds ~mean members; sparse
        // boundary cells (1–2 points sitting in mostly-empty grid) fade toward a
        // faint soft patch. This is what clips the painted sheet to the real cloud
        // and removes the square boundary artifact — no hull math required.
        let meanCnt = max(1.0, Double(count) / Double(max(1, cellCount)))
        for c in 0..<cellCount {
            let ratio = Double(cnt[c]) / meanCnt
            dens[c] = 0.25 + 0.75 * smoothstep(0.35, 1.05, ratio)
        }

        // Sample four corner hues per cell from the member lying most toward each
        // corner (TL,TR,BR,BL) so the bilinear face reads as a true brand blend.
        let cdx: [Double] = [-1, 1, 1, -1]
        let cdy: [Double] = [-1, -1, 1, 1]
        var bestIdx = [Int](repeating: -1, count: cellCount * 4)
        var bestDot = [Double](repeating: -1e9, count: cellCount * 4)
        for i in 0..<count {
            let c = cellOf[i]
            let px = dots[i].x - csx[c]
            let py = dots[i].y - csy[c]
            for k in 0..<4 {
                let d = px * cdx[k] + py * cdy[k]
                let bk = c * 4 + k
                if d > bestDot[bk] { bestDot[bk] = d; bestIdx[bk] = i }
            }
        }
        for c in 0..<cellCount {
            for k in 0..<4 {
                let idx = bestIdx[c * 4 + k]
                cornerHue[c * 4 + k] = dots[idx >= 0 ? idx : 0].rgba.withOpacity(1)
            }
        }
    }

    /// Live per-frame refresh of each cell's screen centroid so the panes follow
    /// the moving cloud (membership is fixed from `bin`).
    private func refresh(_ frame: SwarmSubstrateFrame) {
        let dots = frame.dots
        for c in 0..<cells { sumx[c] = 0; sumy[c] = 0 }
        for i in 0..<dots.count {
            let c = cellOf[i]
            if c < 0 { continue }
            sumx[c] += dots[i].x
            sumy[c] += dots[i].y
        }
        for c in 0..<cells {
            let k = cnt[c]
            if k > 0 { csx[c] = sumx[c] / Double(k); csy[c] = sumy[c] / Double(k) }
        }
    }

    // MARK: Paint

    public func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        if count <= 0 { return false }

        // (Re)bin when count changes or the forge assembly has just settled.
        if count != builtCount || (!built && (frame.settleProgress >= 0.6 || frame.reduced)) {
            bin(frame)
        }
        if cells <= 0 { return false }
        refresh(frame)

        let dark = frame.stage.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let accent = frame.stage.accent
        // Assembly fade ramp (held look: dissolve fade = 1).
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.6 + 0.4
        let ht = reduced ? 0 : frame.t          // freeze the ripple under reduced motion
        let baseExt = storedExt > 0 ? storedExt : frame.sizePx * 4
        let seamPhase = reduced ? 0 : frame.t * 0.18

        // Height field per cell → painter sort (back/high → front/low).
        for c in 0..<cells {
            hcache[c] = heightField(cgx[c] * 0.5, cgy[c] * 0.5, ht * 0.4)
        }
        for c in 0..<cells { order[c] = c }
        // Insertion sort (small, near-stable array) by height descending.
        if cells > 1 {
            for i in 1..<cells {
                let a = order[i]
                let ah = hcache[a]
                var j = i - 1
                while j >= 0 && hcache[order[j]] < ah { order[j + 1] = order[j]; j -= 1 }
                order[j + 1] = a
            }
        }

        var ctx = ctx

        // Cached glossy specular sprite — resolved ONCE this frame, drawn many.
        let spot = ctx.resolve(sprites.radial(diameter: 48, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.95)),
            (0.30, RGBA(r: 1, g: 1, b: 1, a: 0.46)),
            (0.7, RGBA(r: 1, g: 1, b: 1, a: 0.08)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))

        // ── Pass A (dark only): REAL Gaussian bloom under the lit panes ──
        // One blurred additive layer pools a soft colored under-glow beneath the
        // brighter (high) cells, so the sheet visibly glows and fills its
        // silhouette. The heaviest extra pass → dropped under battery throttle.
        if dark && !throttled {
            let bloomR = max(3.0, baseExt * 1.4)
            var bctx = ctx
            bctx.blendMode = .plusLighter
            bctx.drawLayer { layer in
                layer.addFilter(.blur(radius: bloomR))
                layer.blendMode = .plusLighter
                for s in 0..<cells {
                    let c = order[s]
                    let hf = hcache[c]
                    let d = dens[c]
                    let br = clampD(0.4 + 0.6 * hf, 0, 1) * d
                    if br < 0.12 { continue }
                    let x = csx[c]
                    let y = csy[c] - hf * baseExt * 0.5
                    // Glow tint: the lit corner hue lifted toward white and pushed
                    // toward the stage accent (rich, luminous — never grey mush).
                    let glow = cornerHue[c * 4 + 0].toWhite(0.30).mix(with: accent, amount: 0.18)
                    let rr = baseExt * (1.5 + 0.55 * br)
                    layer.opacity = clampD(0.62 * br * f, 0, 0.85)
                    layer.fill(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(glow.color))
                }
            }
        }

        // ── Pass B: the solid ROUNDED gradient panes (source-over on both stages) ──
        for s in 0..<cells {
            let c = order[s]
            let hf = hcache[c]
            let d = dens[c]
            let x = csx[c]
            let y = csy[c] - hf * baseExt * 0.6     // lift along screen-y (draped cloth)
            // Sparse boundary cells shrink slightly → soft patches, not full tiles.
            let ext = baseExt * Self.overlap * (0.82 + 0.18 * d)

            // Pane tilt: a few degrees from the height-field gradient → the gradient
            // axis + hotspot slide as the sheet breathes (flat under reduced motion).
            let tilt: Double = reduced ? 0 : 0.22 * (
                heightField(cgx[c] * 0.5 + 0.6, cgy[c] * 0.5, ht * 0.4)
                - heightField(cgx[c] * 0.5 - 0.6, cgy[c] * 0.5, ht * 0.4)
            )
            let cosT = cos(tilt), sinT = sin(tilt)

            // Rounded, tilted glossy lozenge (NOT a hard square → no rectangle edge).
            let rect = CGRect(x: x - ext, y: y - ext, width: ext * 2, height: ext * 2)
            let xf = CGAffineTransform(translationX: x, y: y)
                .rotated(by: tilt)
                .translatedBy(x: -x, y: -y)
            let quad = Path(roundedRect: rect, cornerRadius: ext * Self.cornerFrac).applying(xf)

            // Gradient axis along the TL↔BR diagonal (rotated by tilt).
            @inline(__always) func rp(_ lx: Double, _ ly: Double) -> CGPoint {
                CGPoint(x: x + (lx * cosT - ly * sinT), y: y + (lx * sinT + ly * cosT))
            }
            let pTL = rp(-ext, -ext)
            let pBR = rp(ext, ext)

            // Bilinear corner blend: HOT toward white on the lit (high) corner,
            // sunk toward iris-tinted near-black on the low corner (real depth).
            let litK = clampD(0.5 + 0.42 * hf, 0, 1)
            let startC = cornerHue[c * 4 + 0].toWhite(0.16 + 0.42 * litK)
            let endC = cornerHue[c * 4 + 2].mix(with: Self.nearBlack, amount: 0.20 * (1 - litK) + 0.06)
            let midC = startC.mix(with: endC, amount: 0.5)
            let grad = Gradient(stops: [
                .init(color: startC.color, location: 0.0),
                .init(color: midC.color, location: 0.5),
                .init(color: endC.color, location: 1.0)
            ])

            ctx.opacity = clampD(f * d, 0, 1)
            ctx.fill(quad, with: .linearGradient(grad, startPoint: pTL, endPoint: pBR))

            // Hot glossy specular core toward the upper-left lit corner. Additive on
            // dark (it blooms), source-over on light (never blows out the canvas).
            let specK = clampD(litK * d, 0, 1)
            if specK > 0.12 {
                let ox = -ext * 0.42, oy = -ext * 0.42
                let hxp = x + (ox * cosT - oy * sinT)
                let hyp = y + (ox * sinT + oy * cosT)
                let hr = ext * (0.82 + 0.3 * specK)
                ctx.blendMode = dark ? .plusLighter : .normal
                ctx.opacity = clampD((dark ? 0.5 : 0.36) * specK * f, 0, dark ? 0.8 : 0.5)
                ctx.draw(spot, in: CGRect(x: hxp - hr, y: hyp - hr, width: hr * 2, height: hr * 2))
                ctx.blendMode = .normal
            }

            // Hairline iridescent thin-film seam — gated by density + rounded so it
            // reads as an INTERIOR grid shimmer that fades at the cloud edge, never
            // an outline. (This is the line that used to trace the broken rectangle.)
            let seamA = clampD((0.22 + 0.4 * litK) * f * d, 0, 0.82)
            if seamA > 0.02 {
                let iris = irisAt(seamPhase + cgx[c] * 0.18 + cgy[c] * 0.12)
                ctx.opacity = seamA
                ctx.stroke(quad, with: .color(iris.color),
                           style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
        }

        ctx.opacity = 1
        return true
    }
}

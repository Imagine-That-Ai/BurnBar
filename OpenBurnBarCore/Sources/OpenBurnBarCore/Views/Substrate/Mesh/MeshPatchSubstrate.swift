import SwiftUI

/// Gradient Patch — ported from imaginethat `glyph/stage/styles/mesh/mesh-patch.ts`.
///
/// The literal anatomy of a gradient mesh. The point cloud is quantized to a
/// coarse 16×16 quad grid; each occupied cell becomes one glossy ceramic-glass
/// PANE filled with a per-cell linear gradient blended from its four sampled
/// corner brand hues (an Illustrator-mesh / Coons-patch made solid). Each pane
/// catches a single small specular hotspot in its upper-left, and its edges are
/// seamed with a hairline iridescent thin-film rim. A slow 2-octave height field
/// advected by `t` lifts and tilts the panes so the sheet undulates like draped,
/// breathing gradient cloth.
///
/// Faithful to `drawBody`: SOLID panes are source-over on BOTH stages (crisp
/// silhouette, never blows out a bright canvas); the dark stage adds a faint
/// additive white bloom pre-pass under the lit panes for backlit glass; the
/// specular hotspot is additive on dark / source-over on light. Per-layout work
/// (binning, corner-hue sampling, cell phase) is cached; the hot loop only
/// recomputes live centroids, the height field, the painter sort, and ≤256
/// panes — trivially 60fps. The destruction/reaction state (dissolve/melt/armed/
/// flip/swell/bulge) is the held-look default (fade=1, no displacement).
public final class MeshPatchSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    // MARK: Tunables

    /// Grid resolution along the cloud's longer axis (cells).
    private static let GRID = 16
    /// Pane overlap so adjacent cells leave no seam gaps.
    private static let overlap = 1.18
    /// The dark-corner sink color (near-black with a cool cast).
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
    private var corner: [RGBA] = []      // per-cell sampled corner hues, [c*4 + {TL,TR,BR,BL}]

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

    /// Quantize the cloud to a coarse quad grid, dedupe occupied cells, and sample
    /// each cell's four corner brand hues once. Everything positional (centroid,
    /// height, sort) is recomputed live each frame.
    private func bin(_ frame: SwarmSubstrateFrame) {
        let dots = frame.dots
        let count = dots.count
        let cx = frame.cx, cy = frame.cy
        let grid = Self.GRID
        builtCount = count
        built = frame.settleProgress >= 0.6 || frame.reduced

        let span = max(frame.cloudRadius, 1) * 2.1
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
        corner = [RGBA](repeating: Self.nearBlack, count: cellCount * 4)
        csx = [Double](repeating: 0, count: cellCount)
        csy = [Double](repeating: 0, count: cellCount)
        sumx = [Double](repeating: 0, count: cellCount)
        sumy = [Double](repeating: 0, count: cellCount)
        hcache = [Double](repeating: 0, count: cellCount)
        order = Array(0..<cellCount)
        storedExt = span / Double(grid) / 2

        // Recover each cell's logical grid coord (for the height-field phase).
        for key in 0..<keyToCell.count {
            let c = keyToCell[key]
            if c < 0 { continue }
            cgx[c] = Double(key % grid)
            cgy[c] = Double(key / grid)
        }

        // Per-cell screen centroid (needed to bias the corner-hue samples).
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

        // Sample four corner hues per cell from the member lying most toward each
        // corner (TL,TR,BR,BL) so the bilinear face reads as a true brand blend.
        let cdx: [Double] = [-1, 1, 1, -1]
        let cdy: [Double] = [-1, -1, 1, 1]
        var bestIdx = [Int](repeating: -1, count: cellCount * 4)
        var bestDot = [Double](repeating: -1e9, count: cellCount * 4)
        for i in 0..<count {
            let c = cellOf[i]
            // vector from centroid → point (point lies toward a corner when this
            // aligns with that corner's direction).
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
                // Degenerate single-member cell repeats its one color (still glossy).
                corner[c * 4 + k] = dots[idx >= 0 ? idx : 0].rgba.withOpacity(1)
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
        // Assembly fade ramp (held look: dissolve fade = 1).
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.6 + 0.4
        let ht = reduced ? 0 : frame.t          // freeze the ripple under reduced motion
        let baseExt = storedExt > 0 ? storedExt : frame.sizePx * 4
        let ext = baseExt * Self.overlap
        let seamPhase = reduced ? 0 : frame.t * 0.18

        // Height field per cell → painter sort (back/high → front/low).
        for c in 0..<cells {
            hcache[c] = heightField(cgx[c] * 0.5, cgy[c] * 0.5, ht * 0.4)
        }
        for c in 0..<cells { order[c] = c }
        // Insertion sort (small, near-stable array) by height descending.
        for i in 1..<max(1, cells) {
            let a = order[i]
            let ah = hcache[a]
            var j = i - 1
            while j >= 0 && hcache[order[j]] < ah { order[j + 1] = order[j]; j -= 1 }
            order[j + 1] = a
        }

        var ctx = ctx

        // Resolve the cached sprites ONCE this frame, then draw many.
        let spot = ctx.resolve(sprites.radial(diameter: 48, stops: [
            (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.95)),
            (0.32, RGBA(r: 1, g: 1, b: 1, a: 0.42)),
            (0.7, RGBA(r: 1, g: 1, b: 1, a: 0.08)),
            (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
        ]))

        // ── Pass A (dark only, full power): faint additive bloom under lit panes ──
        if dark && !throttled {
            let bloom = ctx.resolve(sprites.radial(diameter: 56, stops: [
                (0.0, RGBA(r: 1, g: 1, b: 1, a: 0.7)),
                (0.5, RGBA(r: 1, g: 1, b: 1, a: 0.16)),
                (1.0, RGBA(r: 1, g: 1, b: 1, a: 0.0))
            ]))
            ctx.blendMode = .plusLighter
            let r = baseExt * Self.overlap * 1.5
            for s in 0..<cells {
                let c = order[s]
                let hf = hcache[c]
                let br = clampD(0.5 + 0.5 * hf, 0, 1)
                if br < 0.3 { continue }
                let x = csx[c]
                let y = csy[c] - hf * baseExt * 0.5
                ctx.opacity = clampD(0.1 * br * f, 0, 0.3)
                ctx.draw(bloom, in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            ctx.blendMode = .normal
            ctx.opacity = 1
        }

        // ── Pass B: the solid gradient panes (source-over on both stages) ──
        for s in 0..<cells {
            let c = order[s]
            let hf = hcache[c]
            let x = csx[c]
            let y = csy[c] - hf * baseExt * 0.6     // lift along screen-y (draped cloth)

            // Pane tilt: a few degrees from the height-field gradient → the gradient
            // axis + hotspot slide as the sheet breathes (flat under reduced motion).
            let tilt: Double = reduced ? 0 : 0.22 * (
                heightField(cgx[c] * 0.5 + 0.6, cgy[c] * 0.5, ht * 0.4)
                - heightField(cgx[c] * 0.5 - 0.6, cgy[c] * 0.5, ht * 0.4)
            )
            let cosT = cos(tilt), sinT = sin(tilt)

            // Four corners TL,TR,BR,BL rotated by tilt.
            @inline(__always) func corner(_ lx: Double, _ ly: Double) -> CGPoint {
                CGPoint(x: x + (lx * cosT - ly * sinT), y: y + (lx * sinT + ly * cosT))
            }
            let pTL = corner(-ext, -ext)
            let pTR = corner(ext, -ext)
            let pBR = corner(ext, ext)
            let pBL = corner(-ext, ext)

            var quad = Path()
            quad.move(to: pTL)
            quad.addLine(to: pTR)
            quad.addLine(to: pBR)
            quad.addLine(to: pBL)
            quad.closeSubpath()

            // Gradient TL↔BR: brighten toward the lit (high) corner, sink the low one.
            let litK = clampD(0.5 + 0.42 * hf, 0, 1)
            let startC = self.corner[c * 4 + 0].toWhite(0.1 + 0.32 * litK)
            let endC = self.corner[c * 4 + 2].mix(with: Self.nearBlack, amount: 0.16 * (1 - litK))
            let midC = startC.mix(with: endC, amount: 0.5)
            let grad = Gradient(stops: [
                .init(color: startC.color, location: 0.0),
                .init(color: midC.color, location: 0.5),
                .init(color: endC.color, location: 1.0)
            ])

            ctx.opacity = clampD(f, 0, 1)
            ctx.fill(quad, with: .linearGradient(grad, startPoint: pTL, endPoint: pBR))

            // Glossy specular hotspot toward the upper-left lit corner (alpha-capped
            // so it decorates without erasing the mark). Dropped under battery throttle.
            if !throttled {
                let specK = clampD(litK, 0, 1)
                if specK > 0.12 {
                    let ox = -ext * 0.42, oy = -ext * 0.42
                    let hxp = x + (ox * cosT - oy * sinT)
                    let hyp = y + (ox * sinT + oy * cosT)
                    let hr = ext * (0.8 + 0.3 * specK)
                    ctx.blendMode = dark ? .plusLighter : .normal
                    ctx.opacity = clampD((dark ? 0.4 : 0.34) * specK * f, 0, dark ? 0.7 : 0.5)
                    ctx.draw(spot, in: CGRect(x: hxp - hr, y: hyp - hr, width: hr * 2, height: hr * 2))
                    ctx.blendMode = .normal
                }
            }

            // Hairline iridescent thin-film seam: hue creeps by seam position so a
            // thin-film band drifts across the grid.
            let iris = irisAt(seamPhase + cgx[c] * 0.18 + cgy[c] * 0.12)
            let seamA = clampD((0.34 + 0.4 * litK) * f, 0, 0.95)
            ctx.opacity = seamA
            ctx.stroke(quad, with: .color(iris.color),
                       style: StrokeStyle(lineWidth: 1, lineJoin: .round))
        }

        ctx.opacity = 1
        return true
    }
}

import SwiftUI
import Foundation

/// Lattice Facet — reworked from imaginethat `glyph/stage/styles/moire/lattice-facet.ts`.
///
/// A breathing crystal lattice. Instead of one isolated gem per particle (which
/// scattered into confetti on the sparse Atelier free-swarm), this paints a
/// **GLOBAL faceted tiling** — a continuous triangular crystal lattice locked to a
/// FIXED SCREEN-PX frequency that fills the whole canvas — and then MODULATES each
/// facet by the local particle field:
///   • a coarse density grid (bilinear-sampled, feathered) lifts facet brightness
///     and OPACITY where the swarm clusters and lets it fall gently toward a dim
///     continuous crust where the field is empty (never a hard rectangle);
///   • the grid also carries the swarm's average brand colour, so facets near the
///     swarm take the brand hue while empty facets keep the cool iris jewel tone;
///   • a KEY LIGHT rotates one way (`lightA = t·0.18`) while an offset lattice
///     phase drifts the OTHER way (`latPhase = -t·0.42`); where two slightly
///     detuned px-frequency carriers beat together AND a facet faces the light, a
///     diagonal ribbon of lit facets marches across the lattice — the faceted moiré.
///
/// SHAPE MODE — when `isShapeMode` (or the cloud has settled with most dots in the
/// silhouette) the density gate steepens (`pow(dens, …)`): empty facets vanish and
/// the lit lattice tightens onto the mark, recovering the dense forming look while
/// glyph particles still draw on top.
///
/// Passes: (0) one real Gaussian bloom layer for the whole field — the glow that
/// kills the "flat tiles" read; (1) opaque-feathered faceted gem bodies (the
/// continuous crystal) with an inner lit top-facet on bright cells; (2) specular
/// hot glints riding the moiré ribbon near the swarm. Lattice geometry is cached
/// per layout; the hot loop is O(facets) with no per-frame allocation.
public final class LatticeFacetSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    public init() {}

    // ── cached lattice geometry (rebuilt only when the layout/frequency changes) ──
    private struct Facet {
        var ax: Double; var ay: Double
        var bx: Double; var by: Double
        var cx: Double; var cy: Double
        var fx: Double; var fy: Double          // centroid
        var cosN: Double; var sinN: Double      // facet pseudo-normal (the cut axis)
        var seed: Double
    }
    private var facets: [Facet] = []
    private var builtW = -1.0, builtH = -1.0, builtCell = -1.0

    // per-facet draw scratch (sized with the lattice; never allocates in the loop)
    private var sBright: [Double] = []
    private var sR: [Double] = []
    private var sG: [Double] = []
    private var sB: [Double] = []
    private var sA: [Double] = []
    private var sQ: [Double] = []
    private var sSpec: [Double] = []

    // ── coarse particle-density grid (rebuilt/zeroed per frame) ──────────────────
    private var gCols = 0, gRows = 0
    private var gCell = 1.0
    private var gw: [Double] = []
    private var gr: [Double] = []
    private var gg: [Double] = []
    private var gb: [Double] = []

    /// Rebuild the triangular lattice for this canvas size + facet frequency.
    private func ensureLattice(width: Double, height: Double, cell: Double) {
        if abs(builtW - width) < 0.5, abs(builtH - height) < 0.5, abs(builtCell - cell) < 0.5,
           !facets.isEmpty { return }
        builtW = width; builtH = height; builtCell = cell
        facets.removeAll(keepingCapacity: true)

        let colW = cell
        let rowH = cell * 0.8660254          // equilateral row height
        let nRows = Int(ceil(height / rowH)) + 2
        let nCols = Int(ceil(width / colW)) + 2

        @inline(__always) func add(_ ax: Double, _ ay: Double,
                                    _ bx: Double, _ by: Double,
                                    _ cx: Double, _ cy: Double,
                                    up: Bool, _ ri: Int, _ ci: Int) {
            let fx = (ax + bx + cx) / 3.0
            let fy = (ay + by + cy) / 3.0
            let seed = shash2(Double(ci) * 1.7 + (up ? 0.31 : 0.74), Double(ri) * 1.3 + 0.17)
            // up-facets catch the light from one cut axis, down-facets from the
            // opposite → the lit ribbon alternates across neighbours (the sparkle).
            let baseAng = up ? -Double.pi / 2 : Double.pi / 2
            let na = baseAng + (seed - 0.5) * 0.85
            facets.append(Facet(ax: ax, ay: ay, bx: bx, by: by, cx: cx, cy: cy,
                                fx: fx, fy: fy, cosN: cos(na), sinN: sin(na), seed: seed))
        }

        var ri = -1
        while ri < nRows {
            let yT = Double(ri) * rowH
            let yB = yT + rowH
            let stagger = (ri & 1 == 0) ? 0.0 : colW * 0.5
            var ci = -1
            while ci < nCols {
                let x = stagger + Double(ci) * colW
                // up triangle: base on bottom line, apex on top line
                add(x, yB, x + colW, yB, x + colW * 0.5, yT, up: true, ri, ci)
                // down triangle: base on top line, apex on bottom line (fills the gap)
                add(x + colW * 0.5, yT, x + colW * 1.5, yT, x + colW, yB, up: false, ri, ci)
                ci += 1
            }
            ri += 1
        }

        let n = facets.count
        sBright = [Double](repeating: 0, count: n)
        sR = [Double](repeating: 0, count: n)
        sG = [Double](repeating: 0, count: n)
        sB = [Double](repeating: 0, count: n)
        sA = [Double](repeating: 0, count: n)
        sQ = [Double](repeating: 0, count: n)
        sSpec = [Double](repeating: 0, count: n)
    }

    /// Ensure the density grid arrays are sized to `cols×rows`.
    private func ensureGrid(_ cols: Int, _ rows: Int) {
        let want = cols * rows
        if gCols == cols, gRows == rows, gw.count == want { return }
        gCols = cols; gRows = rows
        gw = [Double](repeating: 0, count: want)
        gr = [Double](repeating: 0, count: want)
        gg = [Double](repeating: 0, count: want)
        gb = [Double](repeating: 0, count: want)
    }

    /// Bilinear sample of the density grid → (weight, average brand colour).
    @inline(__always)
    private func sampleGrid(_ x: Double, _ y: Double, fallback: RGBA) -> (Double, RGBA) {
        let fx = x / gCell - 0.5
        let fy = y / gCell - 0.5
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        @inline(__always) func idx(_ ix: Int, _ iy: Int) -> Int {
            let cx = min(max(ix, 0), gCols - 1)
            let cy = min(max(iy, 0), gRows - 1)
            return cy * gCols + cx
        }
        let i00 = idx(x0, y0), i10 = idx(x0 + 1, y0)
        let i01 = idx(x0, y0 + 1), i11 = idx(x0 + 1, y0 + 1)
        @inline(__always) func bil(_ a: [Double]) -> Double {
            let top = a[i00] * (1 - tx) + a[i10] * tx
            let bot = a[i01] * (1 - tx) + a[i11] * tx
            return top * (1 - ty) + bot * ty
        }
        let w = bil(gw)
        if w > 1e-4 {
            return (w, RGBA(r: bil(gr) / w, g: bil(gg) / w, b: bil(gb) / w))
        }
        return (w, fallback)
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        let W = Double(frame.size.width), H = Double(frame.size.height)
        guard count > 0, W > 1, H > 1 else { return false }

        let dark = frame.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let sizePx = frame.sizePx
        let accent = frame.stage.accent
        let ink = frame.stage.ink
        let t = frame.t

        // FIXED screen-px facet frequency — bounded in absolute px, NEVER derived
        // from cloudRadius (which scales with the screen → giant tiles on a wide
        // sparse field). Clamped so thumbnails and full-screen both read.
        let cell = clampD(30 + sizePx * 4.0, 30, 52)
        ensureLattice(width: W, height: H, cell: cell)
        guard !facets.isEmpty else { return true }

        // assembly reveal — the lattice kindles as the cloud forms.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1)
        let reveal = 0.32 + 0.68 * form

        // shape tightening: in shape mode the density gate steepens so the lit
        // lattice tightens onto the silhouette and empty facets fall away.
        var inN = 0
        for d in frame.dots where d.inShape { inN += 1 }
        let inFrac = Double(inN) / Double(count)
        let shapeTight = clampD(max(frame.isShapeMode ? 0.7 : 0.0,
                                    inFrac * smoothstep(0.4, 0.85, form)), 0, 1)

        // ── build the coarse density + brand-colour field from the swarm ─────────
        let gridCellSize = clampD(cell * 2.2, 52, 130)
        let cols = max(2, Int(ceil(W / gridCellSize)) + 1)
        let rows = max(2, Int(ceil(H / gridCellSize)) + 1)
        ensureGrid(cols, rows)
        gCell = gridCellSize
        for i in 0..<gw.count { gw[i] = 0; gr[i] = 0; gg[i] = 0; gb[i] = 0 }
        for d in frame.dots {
            let gx = min(max(Int(d.x / gridCellSize), 0), cols - 1)
            let gy = min(max(Int(d.y / gridCellSize), 0), rows - 1)
            let k = gy * cols + gx
            let w = clampD(d.opacity, 0, 1) * 0.6 + 0.4
            gw[k] += w
            let c = d.rgba
            gr[k] += c.r * w; gg[k] += c.g * w; gb[k] += c.b * w
        }

        // resting clock: KEY LIGHT rotates one way; offset-lattice phase drifts the
        // OTHER way → the lit-facet ribbon marches across the field (the moiré).
        let lightA = reduced ? -0.6 : t * 0.18
        let latPhase = reduced ? 1.0 : -t * 0.42
        let lx = cos(lightA), ly = sin(lightA)
        // whole-field brightness "inhale" (geometry stays fixed so the lattice is
        // cached; only the glow breathes ±5%).
        let breath = reduced ? 1.0 : 1.0 + 0.05 * sin(t * 0.7)
        let hueDrift = reduced ? 0.0 : t * 0.05

        // moiré carriers at a FIXED px wavelength; the slight detune makes the
        // bright band a moiré, not a plain sweep. Diagonalised across x/y.
        let waveA = TAU / (cell * 6.5)
        let waveB = TAU / (cell * 5.6)

        // continuous lattice baseline so the crust never fully disappears (feathered)
        // in free-swarm — but gated OUT of shape mode by `shapeTight` so a formed
        // logo/wallpaper tightens to its silhouette instead of flooding every
        // full-canvas facet with a faint lattice. `shapeTight` ≈ 0 in free-swarm.
        let floorDim = (dark ? 0.085 : 0.11) * (1.0 - shapeTight)
        let densExp = lerp(1.0, 2.4, shapeTight)

        // ── PASS A: compute every facet's state once (shared by all draw passes) ──
        let n = facets.count
        for fi in 0..<n {
            let f = facets[fi]
            let (gW, brand) = sampleGrid(f.fx, f.fy, fallback: accent)
            let dens = 1.0 - exp(-gW * 0.30)          // 0 (empty) … ~1 (clustered)
            let densG = pow(dens, densExp)             // shape-gated

            let facing = f.cosN * lx + f.sinN * ly      // −1…1
            let latA = (f.fx * 0.86 + f.fy * 0.32) * waveA
            let latB = (f.fx * 0.24 + f.fy * 0.94) * waveB
            let band = 0.5 + 0.5 * sin(latA + latPhase) * sin(latB - latPhase)
            let lit = clampD(0.5 + 0.5 * facing, 0, 1) * (0.45 + 0.55 * band)

            // continuous glow envelope: dim floor everywhere, intensifying on the swarm.
            let glow = (floorDim + (1 - floorDim) * densG) * breath
            let bright = clampD((0.30 + 0.70 * lit) * glow * reveal, 0, 1.2)
            // quantise into a few stable levels — a low-poly faceted crust.
            let q = min(3.0, floor(clampD(bright, 0, 1) * 4.0)) / 3.0

            // iris jewel tone (empty regions) → brand colour (near the swarm).
            let jewel = SubstrateRamp.sample(SubstrateRamp.iris,
                                             band * 0.6 + f.seed * 0.5 + hueDrift)
            let facetCol = jewel.mix(with: brand, amount: clampD(densG * 0.8, 0, 0.8))

            // body tone: lit facets lift toward white; dim facets settle toward ink
            // for the cut depth. Alpha carries the feathered fade to empty space.
            let body: RGBA
            if dark {
                body = facetCol.toWhite(0.05 + 0.45 * q)
            } else {
                body = facetCol.mix(with: ink, amount: 0.18 * (1 - q)).toWhite(0.04 + 0.20 * q)
            }
            let aBody = dark
                ? clampD(0.05 + 0.92 * bright, 0, 0.95)
                : clampD(0.04 + 0.62 * bright, 0, 0.82)

            let spec = facing > 0.25 ? clampD((facing - 0.25) / 0.75, 0, 1) * band * densG : 0

            sBright[fi] = bright
            sR[fi] = body.r; sG[fi] = body.g; sB[fi] = body.b
            sA[fi] = aBody; sQ[fi] = q; sSpec[fi] = spec
        }

        var ctx = baseCtx

        // ── PASS 0: REAL Gaussian under-bloom for the whole field ────────────────
        // One blurred transparency layer — the discs fuse into a continuous luminous
        // crust that intensifies on the swarm and feathers to nothing in empty space.
        // Heaviest pass → dropped first under battery throttle.
        if !throttled {
            let bloomR = max(3.0, cell * 0.55)
            let rg = cell * 0.95
            ctx.blendMode = dark ? .plusLighter : .normal
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: bloomR))
                layer.blendMode = dark ? .plusLighter : .normal
                for fi in 0..<n {
                    let bright = sBright[fi]
                    if bright <= 0.08 { continue }
                    let f = facets[fi]
                    let glowCol = RGBA(r: sR[fi], g: sG[fi], b: sB[fi]).toWhite(0.12 + 0.4 * sQ[fi])
                    let a = dark
                        ? clampD(0.10 + 0.70 * bright, 0, 0.85)
                        : clampD(0.05 + 0.18 * bright, 0, 0.32)
                    let disc = Path(ellipseIn: CGRect(x: f.fx - rg, y: f.fy - rg,
                                                      width: rg * 2, height: rg * 2))
                    layer.fill(disc, with: .color(glowCol.withOpacity(a).color))
                }
            }
        }

        // ── PASS 1: faceted gem bodies — the continuous cut crystal ──────────────
        // source-over on both stages; alpha-feathered so the lattice is solid on the
        // swarm and fades gently where empty. Neighbouring up/down facets differ in
        // tone (different normal + moiré) so the tiling reads as cut crystal. Bright
        // facets get an inner lit top-facet for the gem sparkle.
        ctx.blendMode = .normal
        for fi in 0..<n {
            let a = sA[fi]
            if a <= 0.02 { continue }
            let f = facets[fi]
            var path = Path()
            path.move(to: CGPoint(x: f.ax, y: f.ay))
            path.addLine(to: CGPoint(x: f.bx, y: f.by))
            path.addLine(to: CGPoint(x: f.cx, y: f.cy))
            path.closeSubpath()
            ctx.fill(path, with: .color(RGBA(r: sR[fi], g: sG[fi], b: sB[fi]).withOpacity(a).color))

            // inner lit top-facet (gem table) on bright cells — a smaller triangle
            // pulled toward the centroid, whitened, for the cut-crystal sparkle.
            if !throttled && sBright[fi] > 0.52 {
                let q = sQ[fi]
                let top = RGBA(r: sR[fi], g: sG[fi], b: sB[fi]).toWhite(0.30 + 0.45 * q)
                let s = 0.46
                var inner = Path()
                inner.move(to: CGPoint(x: f.fx + (f.ax - f.fx) * s, y: f.fy + (f.ay - f.fy) * s))
                inner.addLine(to: CGPoint(x: f.fx + (f.bx - f.fx) * s, y: f.fy + (f.by - f.fy) * s))
                inner.addLine(to: CGPoint(x: f.fx + (f.cx - f.fx) * s, y: f.fy + (f.cy - f.fy) * s))
                inner.closeSubpath()
                ctx.fill(inner, with: .color(top.withOpacity(clampD(a * 0.85, 0, 0.9)).color))
            }
        }

        // ── PASS 2: specular hot glints riding the moiré ribbon (near the swarm) ──
        // Dark: a cached white-glow sprite (soft hot core, additive) under a crisp
        // white triangle. Light: just the crisp soft triangle. Throttle drops the
        // sprite bloom and the whole pass stays light (few facets qualify).
        if !throttled {
            ctx.blendMode = dark ? .plusLighter : .normal
            let glowSprite = dark ? ctx.resolve(sprites.whiteGlow(diameter: 48)) : nil
            let specColor: Color = dark ? .white
                : Color(red: 252.0 / 255, green: 253.0 / 255, blue: 1.0)
            let sr = cell * 0.30
            for fi in 0..<n {
                let spec = sSpec[fi]
                if spec <= 0.06 { continue }
                let f = facets[fi]
                // glint sits just off the centroid toward the lit cut axis.
                let ex = f.fx + f.cosN * cell * 0.18
                let ey = f.fy + f.sinN * cell * 0.18

                if let glow = glowSprite {
                    let gr = cell * (0.32 + 0.5 * spec)
                    var sctx = ctx
                    sctx.opacity = clampD(0.28 + 0.5 * spec, 0, 0.9)
                    sctx.draw(glow, in: CGRect(x: ex - gr, y: ey - gr, width: gr * 2, height: gr * 2))
                }

                let perpX = -f.sinN, perpY = f.cosN
                var tri = Path()
                tri.move(to: CGPoint(x: ex + f.cosN * sr * 0.6, y: ey + f.sinN * sr * 0.6))
                tri.addLine(to: CGPoint(x: ex + perpX * sr * 0.42 - f.cosN * sr * 0.28,
                                        y: ey + perpY * sr * 0.42 - f.sinN * sr * 0.28))
                tri.addLine(to: CGPoint(x: ex - perpX * sr * 0.42 - f.cosN * sr * 0.28,
                                        y: ey - perpY * sr * 0.42 - f.sinN * sr * 0.28))
                tri.closeSubpath()
                let alpha = clampD((dark ? 0.66 : 0.42) * spec, 0, 0.9)
                ctx.fill(tri, with: .color(specColor.opacity(alpha)))
            }
        }

        return true
    }
}

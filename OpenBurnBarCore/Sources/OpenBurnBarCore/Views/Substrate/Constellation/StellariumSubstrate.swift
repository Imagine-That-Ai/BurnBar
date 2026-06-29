import SwiftUI

/// Drawn Constellation — faithful port of imaginethat `constellation/stellarium.ts`
/// (drawBody L181-363; graph build ensureGraph L84-170).
///
/// An antique star-chart: a sparse, capped nearest-neighbour GRAPH of luminous
/// edges plus open-ring star NODES sitting exactly on the silhouette points. The
/// lines ARE the mark, so this idiom owns the whole silhouette (`suppressesGlyphs`).
///
/// Topology (built once per layout, cached in point-index space so geometry
/// tracks the dots for free): each node links its 1–2 nearest neighbours within a
/// density-adaptive radius gate (`medianNN² * 6 + 1`), deduped low→high, capped at
/// `MAX_EDGES`; falls back to the NN-walk `order` chain when too sparse.
///
/// Per frame, three batched stroke passes + per-node marks:
///   • PASS 1 — one wide soft-glow Path over every edge (`stage.accent`, low α).
///   • PASS 2 — one crisp thin Path over non-guide edges (`e%5≠0`, accent
///     whitened on dark / darkened on light) + one dashed crawling Path over the
///     guide edges (`e%5==0`, `dashPhase = -t*9`).
///   • SURVEY BEAM — a bright sweep tracing `(t*0.11*ec)%ec`; edges within the
///     beam brighten (own α + width). Dropped when reduced or battery-throttled.
///   • NODES — per-point open RING (`colors[i]`) + breathing CENTRE dot
///     (`tw = 0.5+0.5·sin(t·1.5 + nodePhase[i])`, whitened on dark).
///
/// Dark → additive `.plusLighter` filament glow; light → `.normal` crisp ink.
/// `reduced` → still sky-atlas (no crawl/beam, fixed twinkle phase). The native
/// substrate has no destruction lifecycle, so the source `dissolve` branch and
/// fragment/destroy hooks are intentionally omitted (`fade = 1`).
public final class StellariumSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    /// Max edges we ever draw — keeps the chart sparse and the loop bounded.
    private static let maxEdges = 900
    /// Every Nth edge gets the crawling engraved dash (the guide ticks).
    private static let guideEvery = 5

    // Cached constellation graph in point-index space. Edges live in point-index
    // space, so screen geometry tracks the moving dots for free during a morph —
    // the graph only needs rebuilding when the point COUNT changes (matching the
    // source's count-keyed token, ensureGraph L84-89), never per drift frame.
    private var edgeA: [Int] = []
    private var edgeB: [Int] = []
    private var edgeCount = 0
    private var builtCount = -1

    public init() {}

    public var suppressesGlyphs: Bool { true }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }

        let dots = frame.dots
        let dark = frame.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t

        ensureGraph(frame)
        let ec = edgeCount

        // Assembly fade: lines draw in as the cloud forms; full on a settled stage.
        let f = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        // Ink line colors. EDGES use the single theme accent (NOT per-point) —
        // raw accent for the soft pass, whitened on dark / darkened on light for
        // the crisp pass. Channels built explicitly (the exact mix is the look).
        let acc = frame.stage.accent
        let crispCol: RGBA = dark
            ? RGBA(r: acc.r + (1 - acc.r) * 0.72,
                   g: acc.g + (1 - acc.g) * 0.72,
                   b: acc.b + (1 - acc.b) * 0.78)
            : RGBA(r: acc.r * 0.45, g: acc.g * 0.45, b: acc.b * 0.5)
        // Apex of the survey beam — near-white on dark, deepened accent on light.
        let beamCol: RGBA = dark ? RGBA(r: 0.96, g: 0.975, b: 1.0) : crispCol

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // ── Build the edge geometry ONCE — reused by the bloom layer and the
        //    crisp base passes (point-index space already tracks the moving dots).
        var allEdges = Path()   // every edge — the soft body + bloom base
        var solid = Path()      // non-guide crisp filament
        var guide = Path()      // guide ticks (dashed, crawling)
        if ec > 0 {
            for e in 0..<ec {
                let a = edgeA[e], b = edgeB[e]
                let pa = CGPoint(x: dots[a].x, y: dots[a].y)
                let pb = CGPoint(x: dots[b].x, y: dots[b].y)
                allEdges.move(to: pa); allEdges.addLine(to: pb)
                if e % Self.guideEvery == 0 {
                    guide.move(to: pa); guide.addLine(to: pb)
                } else {
                    solid.move(to: pa); solid.addLine(to: pb)
                }
            }
        }

        // ── SURVEY BEAM geometry: the few edges the sweep is currently lighting.
        //    Collected once so it can be both bloomed (soft halo) and drawn crisp
        //    (hot core). The heaviest extra pass → dropped when battery-throttled.
        var beamPath = Path()
        var beamLit: [(Int, Double)] = []
        let beamActive = !reduced && !throttled && ec > 0
        if beamActive {
            let ecD = Double(ec)
            let beamPos = ecD * frac(t * 0.11)
            // Tighter sweep than the source (was 5% of edges) so a dense cluster
            // never lights all at once into a blown-out white slab.
            let beamWidth = max(2.0, ecD * 0.028)
            for e in 0..<ec {
                var dd = Double(e) - beamPos
                if dd < -ecD / 2 { dd += ecD } else if dd > ecD / 2 { dd -= ecD }
                let k = 1 - abs(dd) / beamWidth
                if k <= 0 { continue }
                let a = edgeA[e], b = edgeB[e]
                beamPath.move(to: CGPoint(x: dots[a].x, y: dots[a].y))
                beamPath.addLine(to: CGPoint(x: dots[b].x, y: dots[b].y))
                beamLit.append((e, k))
            }
        }

        // ════════════════════════════════════════════════════════════════════
        // BLOOM (dark only): a real Gaussian glow layer under the crisp chart —
        // additive, blurred. The filaments and star cores spill light into the
        // page so the sky-atlas GLOWS instead of reading as faint thread. On
        // light we skip it (additive blur blows out a pale page) and lean on
        // raised crisp alphas + a soft per-node halo for presence.
        // ════════════════════════════════════════════════════════════════════
        if dark && ec > 0 {
            let bloomR = max(2.5, sizePx * 1.7)
            let wideW = max(1.6, sizePx * 1.25)
            let glowW = max(1.0, sizePx * 0.72)
            let glowTint = acc.toWhite(0.32)
            let nodeGlowR = max(1.4, sizePx * 1.55)
            ctx.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.addFilter(.blur(radius: bloomR))
                // Wide accent wash over the whole graph — the atmospheric base.
                layer.stroke(allEdges,
                             with: .color(acc.withOpacity(0.42 * f).color),
                             style: StrokeStyle(lineWidth: wideW, lineCap: .round))
                // Brighter filament glow on the working (non-guide) edges.
                layer.stroke(solid,
                             with: .color(crispCol.withOpacity(0.5 * f).color),
                             style: StrokeStyle(lineWidth: glowW, lineCap: .round))
                // Survey beam halo.
                if beamActive {
                    layer.stroke(beamPath,
                                 with: .color(beamCol.withOpacity(0.75 * f).color),
                                 style: StrokeStyle(lineWidth: glowW * 1.4, lineCap: .round))
                }
                // Star cores spill light — one batched bright dot per node.
                var coresGlow = Path()
                for i in 0..<count {
                    let x = dots[i].x, y = dots[i].y
                    coresGlow.addEllipse(in: CGRect(x: x - nodeGlowR, y: y - nodeGlowR,
                                                    width: nodeGlowR * 2, height: nodeGlowR * 2))
                }
                layer.fill(coresGlow, with: .color(glowTint.withOpacity(0.5 * f).color))
            }
        }

        // ── PASS 1: wide soft body over every edge (crisp ctx) — keeps the chart
        //    present even outside the bloom and carries the light page on its own.
        if ec > 0 {
            ctx.stroke(allEdges,
                       with: .color(acc.withOpacity((dark ? 0.14 : 0.1) * f).color),
                       style: StrokeStyle(lineWidth: max(1.4, sizePx * 1.05), lineCap: .round))
        }

        // ── PASS 2: crisp thin filament + engraved guide-dash crawl ────────────
        if ec > 0 {
            let crispW = max(0.8, sizePx * 0.45)

            ctx.stroke(solid,
                       with: .color(crispCol.withOpacity((dark ? 0.62 : 0.72) * f).color),
                       style: StrokeStyle(lineWidth: crispW, lineCap: .round))

            // Guide edges: dashed, slowly crawling — the engraved-chart ticks.
            ctx.stroke(guide,
                       with: .color(crispCol.withOpacity((dark ? 0.52 : 0.58) * f).color),
                       style: StrokeStyle(lineWidth: crispW, lineCap: .round,
                                          dash: [2.4, 4.2],
                                          dashPhase: reduced ? 0 : -t * 9))

            // ── SURVEY BEAM crisp core: bright traced line over the bloom halo,
            //    width + alpha falling off across the sweep. Tamed alpha so the
            //    additive cores never stack into a white slab.
            if beamActive {
                for (e, k) in beamLit {
                    let a = edgeA[e], b = edgeB[e]
                    var seg = Path()
                    seg.move(to: CGPoint(x: dots[a].x, y: dots[a].y))
                    seg.addLine(to: CGPoint(x: dots[b].x, y: dots[b].y))
                    let alpha = clampD(smoothstep(0, 1, k) * (dark ? 0.7 : 0.65) * f, 0, 1)
                    ctx.stroke(seg,
                               with: .color(beamCol.withOpacity(alpha).color),
                               style: StrokeStyle(lineWidth: max(0.9, sizePx * (0.55 + 0.6 * k)),
                                                  lineCap: .round))
                }
            }
        }

        // ── NODES: layered depth — soft per-colour halo, luminous open ring,
        //    hot near-white breathing core sitting exactly on the silhouette.
        let ringR = max(1.4, sizePx * 0.95)
        let ringW = max(0.7, sizePx * 0.34)
        let ringStyle = StrokeStyle(lineWidth: ringW, lineCap: .round)
        for i in 0..<count {
            let d = dots[i]
            let x = d.x, y = d.y
            let ph = shash(Double(i) * 1.61 + 0.31) * TAU
            let tw = reduced ? 0.6 + 0.4 * sin(ph) : 0.5 + 0.5 * sin(t * 1.5 + ph)
            let col = d.rgba

            // Soft per-colour halo (depth) — additive on dark, a faint wash on
            // light. Pushes node colour into the glow so the field reads in hue.
            let haloR = max(1.2, sizePx * (1.05 + 0.45 * tw))
            ctx.fill(Path(ellipseIn: CGRect(x: x - haloR, y: y - haloR,
                                            width: haloR * 2, height: haloR * 2)),
                     with: .color(col.withOpacity((dark ? 0.2 : 0.13) * f).color))

            // Open star ring — lifted toward white on dark so it glows, not greys.
            let ringCol = dark ? col.toWhite(0.28) : col
            ctx.stroke(Path(ellipseIn: CGRect(x: x - ringR, y: y - ringR,
                                              width: ringR * 2, height: ringR * 2)),
                       with: .color(ringCol.withOpacity((dark ? 0.62 : 0.6) * f).color),
                       style: ringStyle)

            // Hot breathing centre dot — near-white on dark so it always reads.
            let coreCol = dark ? col.toWhite(0.62) : col
            let coreR = max(0.8, sizePx * (0.38 + 0.14 * tw))
            let coreA = clampD((dark ? 0.8 + 0.2 * tw : 0.82 + 0.18 * tw) * f, 0, 1)
            ctx.fill(Path(ellipseIn: CGRect(x: x - coreR, y: y - coreR,
                                            width: coreR * 2, height: coreR * 2)),
                     with: .color(coreCol.withOpacity(coreA).color))
        }

        return true
    }

    // MARK: - Graph build (once per topology)

    /// Build the sparse, deduped constellation graph from the cloud's k-NN
    /// structure. Each node contributes up to 2 nearest neighbours within a
    /// density-adaptive radius gate; edges are kept once (low→high) and capped.
    /// Allocation happens here, never per frame.
    private func ensureGraph(_ frame: SwarmSubstrateFrame) {
        let dots = frame.dots
        let count = dots.count
        // Gate on count only — edges in index space already track the moving dots,
        // so a morph/drift never needs the expensive kNN + graph rebuild.
        if builtCount == count { return }
        builtCount = count

        edgeA.removeAll(keepingCapacity: true)
        edgeB.removeAll(keepingCapacity: true)
        edgeCount = 0
        guard count >= 2 else { return }

        let s = frame.structure.structure(for: dots, k: 6)
        let neigh = s.neighbors

        if neigh.count >= count {
            // Sample typical nearest-neighbour distance² for the gate.
            var samples: [Double] = []
            let step = max(1, count / 64)
            var i = 0
            while i < count {
                let row = neigh[i]
                if let j = row.first, j >= 0, j < count {
                    let dx = dots[i].x - dots[j].x, dy = dots[i].y - dots[j].y
                    samples.append(dx * dx + dy * dy)
                }
                i += step
            }
            samples.sort()
            let med = samples.isEmpty ? frame.cloudRadius * frame.cloudRadius * 0.01 : samples[samples.count >> 1]
            // Gate generously (a chart spans a couple node-gaps) but finite, so
            // sparse outliers don't sprout long crossing struts.
            let gate = med * 6.0 + 1

            var seen = Set<Int>()
            let cap = Self.maxEdges
            for i in 0..<count where edgeCount < cap {
                let row = neigh[i]
                var linked = 0
                for j in row where linked < 2 {
                    if j < 0 || j >= count || j == i { continue }
                    let dx = dots[i].x - dots[j].x, dy = dots[i].y - dots[j].y
                    if dx * dx + dy * dy > gate { continue }
                    let a = i < j ? i : j
                    let b = i < j ? j : i
                    let key = a * count + b
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    edgeA.append(a); edgeB.append(b); edgeCount += 1
                    linked += 1
                }
            }
        }

        // Fallback/supplement: chain the NN-walk order so the chart always has a
        // continuous spine when the gate left it too sparse to read.
        if edgeCount < 1 {
            let order = s.order
            if order.count >= 2 {
                var i = 1
                while i < order.count && edgeCount < Self.maxEdges {
                    let a = order[i - 1], b = order[i]
                    if a != b {
                        edgeA.append(min(a, b)); edgeB.append(max(a, b)); edgeCount += 1
                    }
                    i += 1
                }
            } else {
                var i = 1
                while i < count && edgeCount < Self.maxEdges {
                    edgeA.append(i - 1); edgeB.append(i); edgeCount += 1
                    i += 1
                }
            }
        }
    }
}

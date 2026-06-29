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

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // ── PASS 1: wide soft glow — one batched Path over every edge ──────────
        if ec > 0 {
            var p = Path()
            for e in 0..<ec {
                let a = edgeA[e], b = edgeB[e]
                p.move(to: CGPoint(x: dots[a].x, y: dots[a].y))
                p.addLine(to: CGPoint(x: dots[b].x, y: dots[b].y))
            }
            ctx.stroke(p,
                       with: .color(acc.withOpacity((dark ? 0.1 : 0.07) * f).color),
                       style: StrokeStyle(lineWidth: max(1.4, sizePx * 1.05), lineCap: .round))
        }

        // ── PASS 2: crisp thin filament + engraved guide-dash crawl ────────────
        if ec > 0 {
            let crispW = max(0.75, sizePx * 0.42)

            // Non-guide crisp lines (solid), one batched Path.
            var solid = Path()
            for e in 0..<ec where e % Self.guideEvery != 0 {
                let a = edgeA[e], b = edgeB[e]
                solid.move(to: CGPoint(x: dots[a].x, y: dots[a].y))
                solid.addLine(to: CGPoint(x: dots[b].x, y: dots[b].y))
            }
            ctx.stroke(solid,
                       with: .color(crispCol.withOpacity((dark ? 0.5 : 0.62) * f).color),
                       style: StrokeStyle(lineWidth: crispW, lineCap: .round))

            // Guide edges: dashed, slowly crawling — the engraved-chart ticks.
            var guide = Path()
            for e in stride(from: 0, to: ec, by: Self.guideEvery) {
                let a = edgeA[e], b = edgeB[e]
                guide.move(to: CGPoint(x: dots[a].x, y: dots[a].y))
                guide.addLine(to: CGPoint(x: dots[b].x, y: dots[b].y))
            }
            ctx.stroke(guide,
                       with: .color(crispCol.withOpacity((dark ? 0.42 : 0.5) * f).color),
                       style: StrokeStyle(lineWidth: crispW, lineCap: .round,
                                          dash: [2.4, 4.2],
                                          dashPhase: reduced ? 0 : -t * 9))

            // ── SURVEY BEAM: brighten the edges the sweep is passing over ──────
            if !reduced && !throttled && ec > 0 {
                let ecD = Double(ec)
                let beamPos = ecD * frac(t * 0.11)
                let beamWidth = max(2.0, ecD * 0.05)
                let beamCol: RGBA = dark ? RGBA(r: 244.0 / 255, g: 248.0 / 255, b: 1.0) : crispCol
                for e in 0..<ec {
                    var dd = Double(e) - beamPos
                    if dd < -ecD / 2 { dd += ecD } else if dd > ecD / 2 { dd -= ecD }
                    let k = 1 - abs(dd) / beamWidth
                    if k <= 0 { continue }
                    let a = edgeA[e], b = edgeB[e]
                    var seg = Path()
                    seg.move(to: CGPoint(x: dots[a].x, y: dots[a].y))
                    seg.addLine(to: CGPoint(x: dots[b].x, y: dots[b].y))
                    let alpha = clampD(smoothstep(0, 1, k) * (dark ? 0.85 : 0.7) * f, 0, 1)
                    ctx.stroke(seg,
                               with: .color(beamCol.withOpacity(alpha).color),
                               style: StrokeStyle(lineWidth: max(0.9, sizePx * (0.5 + 0.5 * k)),
                                                  lineCap: .round))
                }
            }
        }

        // ── NODES: open ring + breathing centre dot, exactly on the points ─────
        let ringR = max(1.3, sizePx * 0.92)
        let ringW = max(0.7, sizePx * 0.34)
        let ringStyle = StrokeStyle(lineWidth: ringW, lineCap: .round)
        for i in 0..<count {
            let d = dots[i]
            let x = d.x, y = d.y
            let ph = shash(Double(i) * 1.61 + 0.31) * TAU
            let tw = reduced ? 0.6 + 0.4 * sin(ph) : 0.5 + 0.5 * sin(t * 1.5 + ph)
            let col = d.rgba

            // Open star ring (the chart node).
            ctx.stroke(Path(ellipseIn: CGRect(x: x - ringR, y: y - ringR,
                                              width: ringR * 2, height: ringR * 2)),
                       with: .color(col.withOpacity((dark ? 0.5 : 0.55) * f).color),
                       style: ringStyle)

            // Hot breathing centre dot — near-white on dark so it always reads.
            let coreCol = dark ? col.toWhite(0.56) : col
            let coreR = max(0.7, sizePx * (0.34 + 0.12 * tw))
            let coreA = clampD((dark ? 0.7 + 0.3 * tw : 0.78 + 0.22 * tw) * f, 0, 1)
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

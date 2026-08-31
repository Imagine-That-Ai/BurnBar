#if canImport(AppKit)
import AppKit
#endif
import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - Bloom, chart, and orb glass
//
// Three parts, one idea: Home should look like the plasma selectors — lit, refractive,
// colour-reflecting — rather than a stack of frosted slabs.
//
//   * `HomeSpendSeries` / `HomeSpendChart` — the live spend curve as something you can
//     actually read and scrub, not a faint wash behind type.
//   * `HomeBloomBackdrop` — the atmosphere the hero screens sit on.
//
// The glass recipe itself now lives in `BurnBarGlassMaterial` — the orb's lighting
// became the shared material rather than a second one maintained here.
//
// The glass note is the important one. `.ultraThinMaterial` with a tint is *fog*: it
// blurs what is behind it and adds haze, and on a light ground it becomes a pale
// rectangle with no edge at all. `PlasmaPersonaOrb` does not do that — it reads as
// glass because of three things, and all three are copied here:
//
//   1. A **directional rim**: white at the top-leading corner, black at the
//      bottom-trailing one. That one gradient is what says "lit sphere" rather than
//      "flat sticker", and because it carries a light end *and* a dark end it defines
//      the boundary in both colour schemes — the white shows on dark grounds, the black
//      shows on light ones. It fixes "hard to see boundaries in light mode" and "too
//      fogged" with the same stroke.
//   2. A **coloured shadow** in the surface's own tint, so a plate throws its accent
//      onto whatever is behind it. This is the part that reads as colour reflection.
//   3. A **`.plusLighter` sheen**, which brightens without hazing.
//
// Real `glassEffect` still does the refraction on macOS 26 (through the existing
// `liquidGlassSurface` adapter); these add the lighting the material does not. Grouping
// matters too — glass cannot sample other glass, so panes that should refract together
// belong in one `LiquidGlassGroup` (`GlassEffectContainer`).

// MARK: - Series

/// One bucket of spend.
struct HomeSpendSample: Equatable, Sendable, Identifiable {
    let date: Date
    let cost: Double
    var id: Date { date }
}

/// Which question the colour is answering.
///
/// All three are the same rows over the same window — only the grouping key changes.
/// "Total" is the shape of the day. "Harness" is *where* the day went: Claude Code
/// against Codex against Cursor. "Model" is finer, and cuts across harnesses, so Opus
/// run through three different CLIs adds up into one band.
enum HomeSpendBreakdown: String, CaseIterable, Identifiable, Sendable {
    case total
    case harness
    case model

    var id: String { rawValue }

    var label: String {
        switch self {
        case .total: return "TOTAL"
        case .harness: return "HARNESS"
        case .model: return "MODEL"
        }
    }

    var help: String {
        switch self {
        case .total: return "One curve — the shape of the day"
        case .harness: return "Stacked by harness: Claude Code, Codex, Cursor…"
        case .model: return "Stacked by model, across every harness that ran it"
        }
    }
}

/// One coloured layer of the stack.
///
/// `values` is bucket-aligned with `HomeSpendCube.dates`. That alignment is the whole
/// point: a band can be summed, stacked, or dropped without touching a usage row, which
/// is what makes toggling a series in the legend instant instead of a re-query.
struct HomeSpendBand: Equatable, Sendable, Identifiable {
    /// Stable across renders — the provider's raw value, or the lowercased model name.
    let id: String
    let label: String
    let color: Color
    let values: [Double]
    let total: Double
}

/// Every breakdown of one window, derived once.
///
/// Held as a cube rather than recomputed per mode so switching HARNESS→MODEL is a
/// re-render, not a re-scan of `dataStore.usages`.
struct HomeSpendCube: Equatable, Sendable {
    let dates: [Date]
    let byHarness: [HomeSpendBand]
    let byModel: [HomeSpendBand]

    static let empty = HomeSpendCube(dates: [], byHarness: [], byModel: [])

    /// The bands a given breakdown renders.
    ///
    /// `.total` is a real band rather than a special case, so the chart has exactly one
    /// drawing path: everything is a stack, and "total" is a stack of one.
    func bands(for breakdown: HomeSpendBreakdown) -> [HomeSpendBand] {
        switch breakdown {
        case .harness: return byHarness
        case .model:   return byModel
        case .total:
            guard dates.isEmpty == false else { return [] }
            let values = totalsPerBucket
            // A day with no spend has no bands, exactly as the broken-out cuts do —
            // otherwise "total" would be the one mode that renders a flat zero line and
            // calls it a series.
            guard values.contains(where: { $0 > 0 }) else { return [] }
            return [
                HomeSpendBand(
                    id: "all",
                    label: "All spend",
                    color: DesignSystem.Colors.blaze,
                    values: values,
                    total: values.reduce(0, +)
                )
            ]
        }
    }

    /// Cost per bucket with nothing broken out.
    ///
    /// Summed from the harness bands rather than kept as a fourth array — they are a
    /// complete partition of the window, so a separate total could only ever drift.
    var totalsPerBucket: [Double] {
        guard dates.isEmpty == false else { return [] }
        var running = [Double](repeating: 0, count: dates.count)
        for band in byHarness {
            for index in running.indices where band.values.indices.contains(index) {
                running[index] += band.values[index]
            }
        }
        return running
    }

    /// The flat curve, for callers that only want a shape.
    var samples: [HomeSpendSample] {
        zip(dates, totalsPerBucket).map { HomeSpendSample(date: $0, cost: $1) }
    }
}

/// Turns raw usage rows into readable curves.
///
/// Pure and `static` so bucketing, ranking and scaling can be pinned by tests without
/// mounting a view — the contract `LivingSpaceBudget` and `DashboardHomeRailMetrics`
/// already keep.
enum HomeSpendSeries {

    static let defaultBuckets = 72
    static let defaultWindow: TimeInterval = 24 * 60 * 60

    /// Bands beyond this fold into "Other".
    ///
    /// Six colours is a legend; twenty is confetti. The tail is never dropped — it is
    /// summed, so the stack's top edge is still the true total.
    static let bandLimit = 5

    /// Cost per bucket across the trailing window.
    static func samples(
        _ usages: [TokenUsage],
        buckets: Int = defaultBuckets,
        now: Date = Date(),
        window: TimeInterval = defaultWindow
    ) -> [HomeSpendSample] {
        cube(usages, buckets: buckets, now: now, window: window).samples
    }

    /// The same window cut three ways.
    static func cube(
        _ usages: [TokenUsage],
        buckets: Int = defaultBuckets,
        now: Date = Date(),
        window: TimeInterval = defaultWindow,
        limit: Int = bandLimit
    ) -> HomeSpendCube {
        guard buckets > 1 else { return .empty }
        let start = now.addingTimeInterval(-window)
        let step = window / Double(buckets)
        let dates = (0..<buckets).map { start.addingTimeInterval(step * Double($0)) }
        let zeros = [Double](repeating: 0, count: buckets)

        var harness: [AgentProvider: [Double]] = [:]
        var model: [String: [Double]] = [:]
        var modelLabels: [String: String] = [:]

        for usage in usages where usage.endTime >= start && usage.endTime <= now {
            let progress = usage.endTime.timeIntervalSince(start) / window
            let index = min(buckets - 1, max(0, Int(progress * Double(buckets))))

            harness[usage.provider, default: zeros][index] += usage.cost

            let raw = usage.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = raw.isEmpty ? "unknown" : raw.lowercased()
            modelLabels[key] = raw.isEmpty ? "Unknown model" : raw
            model[key, default: zeros][index] += usage.cost
        }

        return HomeSpendCube(
            dates: dates,
            byHarness: rank(harness, limit: limit, buckets: buckets) { provider in
                (provider.rawValue, provider.displayName, DesignSystem.Colors.primary(for: provider))
            },
            byModel: rank(model, limit: limit, buckets: buckets) { key in
                let label = modelLabels[key] ?? key
                return (key, label, DesignSystem.Colors.colorForModel(label))
            }
        )
    }

    /// The value the curve's top edge represents.
    ///
    /// **Not** the maximum. One 40× spike against an otherwise quiet day flattens every
    /// other bucket onto the baseline — which is exactly why the first version of this
    /// chart was "barely visible": the shape was there, squashed into two pixels.
    /// Scaling to a high percentile and letting the rare spike clip keeps the *day*
    /// legible, which is what a curve is for. The spike stays obvious because it hits
    /// the ceiling and the peak readout names it.
    static func ceiling(_ samples: [HomeSpendSample], percentile: Double = 0.92) -> Double {
        ceiling(of: samples.map(\.cost), percentile: percentile)
    }

    /// The same rule applied to an already-stacked column of buckets.
    static func ceiling(of values: [Double], percentile: Double = 0.92) -> Double {
        let positive = values.filter { $0 > 0 }.sorted()
        guard positive.isEmpty == false else { return 0 }
        let index = Int((Double(positive.count - 1) * max(0, min(1, percentile))).rounded())
        // Never let the ceiling collapse onto the floor on a nearly flat day.
        return max(positive[index], (positive.last ?? 0) * 0.12)
    }

    // MARK: Ranking

    /// Biggest spenders first, the tail folded into one honest "Other".
    ///
    /// Ties break on the identity string so the stack's order — and therefore its
    /// colours — do not shuffle between renders of identical data.
    private struct Candidate {
        let id: String
        let label: String
        let color: Color
        let values: [Double]
        let total: Double
    }

    private static func rank<Key: Hashable>(
        _ grouped: [Key: [Double]],
        limit: Int,
        buckets: Int,
        identify: (Key) -> (id: String, label: String, color: Color)
    ) -> [HomeSpendBand] {
        let scored: [Candidate] = grouped
            .map { key, values in
                let identity = identify(key)
                return Candidate(
                    id: identity.id,
                    label: identity.label,
                    color: identity.color,
                    values: values,
                    total: values.reduce(0, +)
                )
            }
            .filter { $0.total > 0 }
            .sorted { $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total }

        var bands: [HomeSpendBand] = []
        var usedColors: [Color: Int] = [:]

        for entry in scored.prefix(max(1, limit)) {
            let occurrence = usedColors[entry.color] ?? 0
            usedColors[entry.color] = occurrence + 1
            bands.append(
                HomeSpendBand(
                    id: entry.id,
                    label: entry.label,
                    color: separate(entry.color, occurrence: occurrence),
                    values: entry.values,
                    total: entry.total
                )
            )
        }

        let tail = scored.dropFirst(max(1, limit))
        if tail.isEmpty == false {
            var folded = [Double](repeating: 0, count: buckets)
            for entry in tail {
                for index in folded.indices where entry.values.indices.contains(index) {
                    folded[index] += entry.values[index]
                }
            }
            bands.append(
                HomeSpendBand(
                    id: "other",
                    label: "Other (\(tail.count))",
                    color: DesignSystem.Colors.textMuted,
                    values: folded,
                    total: folded.reduce(0, +)
                )
            )
        }

        return bands
    }

    /// Pull a repeated brand colour apart.
    ///
    /// Every Claude model resolves to the same ochre, so a stack of Opus over Sonnet
    /// would be two bands with an invisible seam. Repeats step deterministically in hue
    /// and brightness: far enough apart to separate, close enough that the family still
    /// reads as a family.
    private static func separate(_ base: Color, occurrence: Int) -> Color {
        guard occurrence > 0 else { return base }
        #if canImport(AppKit)
        guard let rgb = NSColor(base).usingColorSpace(.sRGB) else { return base }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shift = CGFloat(occurrence)
        return Color(
            hue: Double((hue + 0.05 * shift).truncatingRemainder(dividingBy: 1)),
            saturation: Double(max(0.28, min(1, saturation - 0.09 * shift))),
            brightness: Double(max(0.34, min(1, brightness + 0.13 * shift))),
            opacity: Double(alpha)
        )
        #else
        return base.opacity(max(0.4, 1 - 0.18 * Double(occurrence)))
        #endif
    }
}

// MARK: - Spend chart

/// The live spend curve: readable, labelled, scrubbable — and broken out by what
/// actually spent the money.
///
/// A single anonymous curve answers "how much" and stops there. The question anyone
/// looking at this screen actually has is "on **what**" — which harness, which model —
/// and that is a property of colour, not of a tooltip. So the area under the curve is a
/// stack: one coloured band per harness or model, ranked by spend, tail folded into
/// `Other`, every band togglable from the legend. The top edge of the stack is still
/// the exact total, so turning the breakdown off changes the palette and nothing else.
struct HomeSpendChart: View {
    let cube: HomeSpendCube
    let ink: BackdropInk
    var accent: Color = DesignSystem.Colors.blaze

    /// The chosen cut persists: it is a reading preference, not view state, and having
    /// it reset every time Home re-mounts made the control feel broken.
    @AppStorage("home.spend.breakdown") private var breakdownRaw = HomeSpendBreakdown.harness.rawValue
    /// Hidden series, namespaced by breakdown — hiding Codex under HARNESS must not
    /// also hide a model that happens to share its name.
    @AppStorage("home.spend.hidden") private var hiddenRaw = ""

    @State private var hoverIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room reserved along the bottom for the time axis, and along the top for controls.
    private static let axisInset: CGFloat = 22
    private static let headerInset: CGFloat = 34
    /// Gap between the ceiling and the control strip, so a peak's stroke, glow, and
    /// marker have generous breathing room without hitting or clipping the header.
    private static let crestHeadroom: CGFloat = 14
    /// Catmull-Rom tension. Balanced to render soft, continuous curves with natural
    /// rounded summits without overshooting into negative spend.
    private static let tension: CGFloat = 0.90
    /// Fraction of the legend strip given over to the "there is more" falloff.
    private static let legendFade: CGFloat = 0.05
    private static let hiddenSeparator = "\n"
    private static let hiddenNamespace = "\t"

    // MARK: State derivation

    private var breakdown: HomeSpendBreakdown {
        HomeSpendBreakdown(rawValue: breakdownRaw) ?? .harness
    }

    private var hidden: Set<String> {
        Set(hiddenRaw.components(separatedBy: Self.hiddenSeparator).filter { $0.isEmpty == false })
    }

    private func hiddenKey(_ band: HomeSpendBand) -> String {
        breakdown.rawValue + Self.hiddenNamespace + band.id
    }

    private func isHidden(_ band: HomeSpendBand) -> Bool { hidden.contains(hiddenKey(band)) }

    private func toggle(_ band: HomeSpendBand) {
        var next = hidden
        let key = hiddenKey(band)
        if next.remove(key) == nil { next.insert(key) }
        hiddenRaw = next.sorted().joined(separator: Self.hiddenSeparator)
    }

    private var bands: [HomeSpendBand] { cube.bands(for: breakdown) }
    private var visible: [HomeSpendBand] { bands.filter { isHidden($0) == false } }

    /// The stacked column heights the ceiling is scaled against.
    private var stackedTotals: [Double] {
        guard cube.dates.isEmpty == false else { return [] }
        var running = [Double](repeating: 0, count: cube.dates.count)
        for band in visible {
            for index in running.indices where band.values.indices.contains(index) {
                running[index] += band.values[index]
            }
        }
        return running
    }

    private var ceiling: Double { HomeSpendSeries.ceiling(of: stackedTotals) }
    private var total: Double { stackedTotals.reduce(0, +) }

    private var peak: HomeSpendSample? {
        zip(cube.dates, stackedTotals)
            .map { HomeSpendSample(date: $0, cost: $1) }
            .max { $0.cost < $1.cost }
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas(opaque: false) { context, size in
                    drawGrid(&context, size: size)
                    drawStack(&context, size: size)
                    drawHover(&context, size: size)
                }
                .animation(MotionTokens.tick(reduceMotion: reduceMotion), value: visible)

                if total <= 0 { emptyPlot }

                axis
                header
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverIndex = point.y > Self.headerInset
                        ? index(at: point.x, width: geo.size.width)
                        : nil
                case .ended:
                    hoverIndex = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spend over the last 24 hours, broken down by \(breakdown.label.lowercased())")
    }

    // MARK: Geometry

    private func plotHeight(_ size: CGSize) -> CGFloat {
        max(1, size.height - Self.headerInset - Self.axisInset)
    }

    private func baseline(_ size: CGSize) -> CGFloat { Self.headerInset + plotHeight(size) }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        guard cube.dates.count > 1, width > 0 else { return nil }
        let ratio = max(0, min(1, x / width))
        return min(cube.dates.count - 1, Int(ratio * CGFloat(cube.dates.count - 1)))
    }

    /// Cumulative top edges, bottom-most band first.
    ///
    /// Each entry is the running sum *through* that band, so edge `n` is where band `n`
    /// ends and band `n+1` begins. Painting them back-to-front down to the baseline is
    /// what keeps the seams gap-free — an explicitly closed ribbon between two smoothed
    /// curves leaves hairlines wherever the smoothing disagrees.
    private func edges(in size: CGSize) -> [[CGPoint]] {
        let count = cube.dates.count
        guard count > 1, size.width > 0, ceiling > 0 else { return [] }
        let usable = plotHeight(size)
        let step = size.width / CGFloat(count - 1)

        var running = [Double](repeating: 0, count: count)
        var result: [[CGPoint]] = []
        for band in visible {
            for index in running.indices where band.values.indices.contains(index) {
                running[index] += band.values[index]
            }
            let span = max(1, usable - Self.crestHeadroom)
            result.append(
                running.enumerated().map { index, value in
                    CGPoint(
                        x: CGFloat(index) * step,
                        y: Self.headerInset + Self.crestHeadroom
                            + span * (1 - CGFloat(min(1, value / ceiling)))
                    )
                }
            )
        }
        return result
    }

    /// A smoothed curve that passes **through** its points.
    ///
    /// The previous quad-through-midpoints version treated the samples as control
    /// points, so the drawn curve never actually touched them: single-bucket spikes got
    /// flattened, and the peak marker floated off the line it was supposed to be
    /// marking. Catmull-Rom converted to cubic Béziers interpolates instead, which is
    /// what lets the markers, the hover dots and the band seams all agree.
    private func smoothed(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for index in 0..<(points.count - 1) {
            let before = points[max(0, index - 1)]
            let start = points[index]
            let end = points[index + 1]
            let after = points[min(points.count - 1, index + 2)]
            path.addCurve(
                to: end,
                control1: CGPoint(
                    x: start.x + (end.x - before.x) / 6 * Self.tension,
                    y: start.y + (end.y - before.y) / 6 * Self.tension
                ),
                control2: CGPoint(
                    x: end.x - (after.x - start.x) / 6 * Self.tension,
                    y: end.y - (after.y - start.y) / 6 * Self.tension
                )
            )
        }
        return path
    }

    /// A cumulative edge closed down to the baseline — the region *under* that edge.
    private func filled(_ edge: [CGPoint], size: CGSize) -> Path {
        var path = smoothed(edge)
        path.addLine(to: CGPoint(x: size.width, y: baseline(size)))
        path.addLine(to: CGPoint(x: 0, y: baseline(size)))
        path.closeSubpath()
        return path
    }

    // MARK: Drawing

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        let usable = plotHeight(size)
        for fraction in [0.0, 0.5, 1.0] {
            let y = Self.headerInset + usable * CGFloat(fraction)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                line,
                with: .color(ink.hairline.opacity(fraction == 1 ? 0.55 : 0.22)),
                style: StrokeStyle(lineWidth: 0.75, dash: fraction == 1 ? [] : [3, 5])
            )
        }
    }

    private func drawStack(_ context: inout GraphicsContext, size: CGSize) {
        let edges = edges(in: size)
        guard edges.isEmpty == false else { return }
        let floor = baseline(size)

        // The plot is its own room: an overshooting curve may not climb into the
        // control strip or spill under the time axis.
        var plot = context
        plot.clip(
            to: Path(
                CGRect(x: 0, y: Self.headerInset, width: size.width, height: floor - Self.headerInset)
            )
        )

        // Each band is the ribbon between its own cumulative edge and the one below it,
        // cut by clipping rather than by painting one translucent area over another.
        // Overdraw was the first version, and it turned five distinct harnesses into one
        // muddy purple wash — stacked translucency composites, it does not layer.
        let whole = Path(CGRect(origin: .zero, size: size))
        for offset in edges.indices {
            var band = plot
            band.clip(to: filled(edges[offset], size: size))
            if offset > 0 {
                band.clip(to: filled(edges[offset - 1], size: size), options: .inverse)
            }
            let color = visible[offset].color
            band.fill(
                whole,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.82), color.opacity(0.34)]),
                    startPoint: CGPoint(x: 0, y: Self.headerInset),
                    endPoint: CGPoint(x: 0, y: floor)
                )
            )
        }

        // Every seam gets its own line, so two neighbouring colours stay told apart even
        // where the fills are close in value.
        for offset in edges.indices.dropLast() {
            plot.stroke(
                smoothed(edges[offset]),
                with: .color(visible[offset].color.opacity(0.9)),
                lineWidth: 1.1
            )
        }

        drawCrest(&plot, edge: edges[edges.count - 1], size: size)
    }

    /// The top of the stack — the total. It carries the glow because it is the line the
    /// eye is meant to follow, and because it has to survive sitting on a bright bloom.
    private func drawCrest(_ context: inout GraphicsContext, edge: [CGPoint], size: CGSize) {
        let line = smoothed(edge)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: crestColors),
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0)
        )
        // With a breakdown on, the bands are the subject and the crest is the summary —
        // the full two-pass bloom that a lone curve needs to survive the backdrop turns
        // a stack into haze. One curve keeps it; a stack gets the tight pass only.
        if visible.count < 2 {
            var wide = context
            wide.addFilter(.blur(radius: 14))
            wide.stroke(line, with: shading, lineWidth: 5)
        }
        var tight = context
        tight.addFilter(.blur(radius: visible.count < 2 ? 5 : 3))
        tight.stroke(line, with: shading, lineWidth: 3)
        context.stroke(line, with: shading, lineWidth: 2.2)

        if let last = edge.last {
            markDot(&context, at: last, color: DesignSystem.Colors.ember, radius: 4)
        }
        if let peak, peak.cost > 0,
           let peakIndex = cube.dates.firstIndex(of: peak.date), edge.indices.contains(peakIndex) {
            markDot(&context, at: edge[peakIndex], color: DesignSystem.Colors.amber, radius: 3)
        }
    }

    /// The crest is tinted by what is under it: with a breakdown on, it runs through the
    /// visible bands' own colours rather than a fixed brand gradient.
    private var crestColors: [Color] {
        let palette = visible.map(\.color)
        guard palette.count > 1 else {
            return [DesignSystem.Colors.whimsy, palette.first ?? accent, DesignSystem.Colors.ember]
        }
        return palette
    }

    private func markDot(_ context: inout GraphicsContext, at point: CGPoint, color: Color, radius: CGFloat) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        var glow = context
        glow.addFilter(.blur(radius: 6))
        glow.fill(Circle().path(in: rect), with: .color(color))
        context.fill(Circle().path(in: rect), with: .color(color))
    }

    private func drawHover(_ context: inout GraphicsContext, size: CGSize) {
        guard let hoverIndex, cube.dates.indices.contains(hoverIndex) else { return }
        let edges = edges(in: size)
        guard edges.isEmpty == false, edges[0].indices.contains(hoverIndex) else { return }

        let x = edges[0][hoverIndex].x
        var rule = Path()
        rule.move(to: CGPoint(x: x, y: Self.headerInset))
        rule.addLine(to: CGPoint(x: x, y: baseline(size)))
        context.stroke(
            rule,
            with: .color(ink.secondary.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 3])
        )

        // One dot per band boundary: the scrub reads the split, not just the total.
        for offset in edges.indices where visible[offset].values[hoverIndex] > 0 {
            markDot(&context, at: edges[offset][hoverIndex], color: visible[offset].color, radius: 2.6)
        }
        markDot(&context, at: edges[edges.count - 1][hoverIndex], color: .white, radius: 3.5)
    }

    // MARK: Overlays

    private var emptyPlot: some View {
        VStack(spacing: 4) {
            Text(bands.isEmpty ? "No spend in the last 24 hours" : "Every series is hidden")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.secondary)
            if bands.isEmpty == false {
                Text("Pick one from the legend above")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(ink.subtle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, Self.headerInset)
        .padding(.bottom, Self.axisInset)
        .allowsHitTesting(false)
    }

    private var axis: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(Array(axisLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(ink.subtle)
                        .frame(maxWidth: .infinity, alignment: alignment(for: index))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func alignment(for index: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == axisLabels.count - 1 { return .trailing }
        return .center
    }

    private var axisLabels: [String] {
        guard let first = cube.dates.first, let last = cube.dates.last else { return [] }
        let span = last.timeIntervalSince(first)
        return (0...4).map { step in
            HomeShellCopy.time(first.addingTimeInterval(span * Double(step) / 4))
        }
    }

    /// Controls, legend, readout — one row, in that order.
    ///
    /// The controls come first because they are the thing that was missing: the chart
    /// had no way to ask a different question of the same data.
    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            HomeSpendBreakdownPicker(selection: $breakdownRaw, ink: ink, accent: accent)

            if bands.isEmpty == false {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(bands) { band in
                            legendChip(band)
                        }
                    }
                    .padding(.trailing, 2)
                }
                // The scroll view is greedy, so on a wide window the chips end well
                // before the trailing edge and this gradient falls on empty space. It
                // only becomes visible when there is genuinely more legend than room —
                // which is exactly when "there is more" needs saying.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 1 - Self.legendFade),
                            .init(color: .black.opacity(0), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            readout
        }
        .frame(height: Self.headerInset - 6, alignment: .center)
        .animation(MotionTokens.settle(reduceMotion: reduceMotion), value: breakdownRaw)
    }

    /// A legend entry that is also the control. Clicking it drops that harness or model
    /// out of the stack — the "selection" half of the ask, and the only place it can
    /// live without inventing a second menu for something you are already looking at.
    private func legendChip(_ band: HomeSpendBand) -> some View {
        let off = isHidden(band)
        let share = total > 0 ? band.total / max(total, .leastNonzeroMagnitude) : 0
        return Button {
            withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) { toggle(band) }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(band.color.opacity(off ? 0.22 : 1))
                    .frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(band.color.opacity(off ? 0.55 : 0), lineWidth: 1))
                Text(Self.chipLabel(band.label))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(off ? ink.subtle : ink.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .burnBarGlassControl(.standard, tint: off ? nil : band.color, height: 20)
            .opacity(off ? 0.5 : 1)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(band.label) — \(band.total.formatAsCost())\(share > 0 ? String(format: " · %.0f%%", share * 100) : "") · click to \(off ? "show" : "hide")")
        .accessibilityLabel(band.label)
        .accessibilityValue(band.total.formatAsCost())
        .accessibilityHint(off ? "Hidden. Activate to show in the chart." : "Shown. Activate to hide from the chart.")
        .accessibilityAddTraits(off ? [] : .isSelected)
    }

    /// Real model names run long — `claude-3-5-sonnet-20241022` on its own is wider
    /// than the picker. Middle-truncated so both ends survive: the family at the front
    /// and the version at the back are what tell two builds apart. The full name stays
    /// in the tooltip and in the accessibility label.
    ///
    /// Truncated here rather than by `lineLimit`, because inside a horizontal
    /// `ScrollView` a `Text` is offered unbounded width and never truncates at all.
    private static func chipLabel(_ label: String) -> String {
        guard label.count > 20 else { return label }
        return label.prefix(10) + "…" + label.suffix(8)
    }

    /// Peak and total — or the hovered bucket, broken down, while scrubbing.
    @ViewBuilder
    private var readout: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if let hoverIndex, cube.dates.indices.contains(hoverIndex) {
                readoutPair(
                    HomeShellCopy.time(cube.dates[hoverIndex]),
                    stackedTotals[hoverIndex].formatAsCost(),
                    tint: ink.primary
                )
                ForEach(hoverContributions(at: hoverIndex)) { band in
                    HStack(spacing: 4) {
                        Circle().fill(band.color).frame(width: 5, height: 5)
                        Text(band.values[hoverIndex].formatAsCost())
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(ink.secondary)
                    }
                }
            } else {
                if let peak, peak.cost > 0 {
                    readoutPair(
                        "PEAK \(HomeShellCopy.time(peak.date))",
                        peak.cost.formatAsCost(),
                        tint: DesignSystem.Colors.amber
                    )
                }
                readoutPair("24H", total.formatAsCost(), tint: DesignSystem.Colors.ember)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 5)
        .burnBarGlass(.standard, role: .instrument, tint: accent, cornerRadius: DesignSystem.Radius.sm)
        .animation(MotionTokens.tick(reduceMotion: reduceMotion), value: hoverIndex)
        .fixedSize()
    }

    /// The biggest contributors in the hovered bucket. Three, because a readout that
    /// lists eight series is a table that happens to follow the cursor.
    private func hoverContributions(at index: Int) -> [HomeSpendBand] {
        guard breakdown != .total else { return [] }
        let contributing = visible
            .filter { $0.values.indices.contains(index) && $0.values[index] > 0 }
            .sorted { $0.values[index] > $1.values[index] }
        return Array(contributing.prefix(3))
    }

    private func readoutPair(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(ink.subtle)
            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Breakdown picker

/// Three segments: the question selector for the spend curve.
///
/// Bound to the raw string rather than the enum so the chart can keep it in
/// `@AppStorage` without a second source of truth.
struct HomeSpendBreakdownPicker: View {
    @Binding var selection: String
    let ink: BackdropInk
    var accent: Color = DesignSystem.Colors.blaze

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var slider

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HomeSpendBreakdown.allCases) { mode in
                let isOn = selection == mode.rawValue
                Button {
                    withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) {
                        selection = mode.rawValue
                    }
                } label: {
                    Text(mode.label)
                        .font(DesignSystem.Typography.monoTiny)
                        .tracking(0.5)
                        .foregroundStyle(isOn ? ink.primary : ink.subtle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            if isOn {
                                Capsule(style: .continuous)
                                    .fill(accent.opacity(0.18))
                                    .matchedGeometryEffect(id: "home.spend.breakdown", in: slider)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.help)
                .accessibilityLabel(mode.label.capitalized)
                .accessibilityHint(mode.help)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .burnBarGlassControl(.standard, tint: accent, height: 24)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Break spend down by")
    }
}
// MARK: - Bloom backdrop

/// Atmosphere for the hero shells: two offset radial washes, no plate.
///
/// A single centred glow reads as a vignette, which is decoration. Offset lobes read as
/// light arriving from somewhere, which is a room.
struct HomeBloomBackdrop: View {
    var accent: Color = DesignSystem.Colors.blaze
    var intensity: Double = 1

    var body: some View {
        Canvas(opaque: false) { context, size in
            let lobes: [(CGPoint, CGFloat, Color, Double)] = [
                (CGPoint(x: size.width * 0.16, y: size.height * 0.92), size.height * 1.25, accent, 0.34),
                (CGPoint(x: size.width * 0.84, y: size.height * 0.12), size.height * 1.00,
                 DesignSystem.Colors.whimsy, 0.24)
            ]
            for (center, radius, color, opacity) in lobes {
                let rect = CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )
                context.fill(
                    Circle().path(in: rect),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(opacity * intensity), color.opacity(0)]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Chip cloud

/// Prompt chips that wrap and then stop.
///
/// The bug this replaces: five capsules in a `VStack` inside a slot that had been
/// granted stretch, floating above ~600pt of bare plate. A cloud is exactly as tall as
/// its rows, so it cannot do that.
struct HomeChipCloud: View {
    let prompts: [String]
    let ink: BackdropInk
    let onPick: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FlowLayout(horizontalSpacing: DesignSystem.Spacing.xs, verticalSpacing: DesignSystem.Spacing.xs) {
            ForEach(Array(prompts.enumerated()), id: \.element) { index, prompt in
                Button { onPick(prompt) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                        Text(prompt)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(ink.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 6)
                    .burnBarGlassControl(.ask, tint: DesignSystem.Colors.whimsy)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(MotionTokens.flow(reduceMotion: reduceMotion))
                .animation(MotionTokens.arrive(index: index, reduceMotion: reduceMotion), value: prompts)
            }
        }
    }
}

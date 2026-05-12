import Foundation

// MARK: - Standard Gallery
//
// A locally-derived, zero-Hermes set of evocative charts that are *always*
// available in Chart Studio. The chat composer is for "ask anything", but
// the canvas leads with real, beautifully-rendered insights so the user
// gets value before they ever type.
//
// Pure-value, `Sendable`, unit-testable.

public struct StandardGalleryItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case chart
        case insight
        case ascii
    }

    public let id: String                  // stable slug (used for replay + tests)
    public let kind: Kind
    public let category: String            // "Spend" | "Velocity" | "Cache" | "Models" | "Time" | "Mix"
    public let headline: String            // short title shown above the rendered card
    public let blurb: String               // 1-line subtitle under the headline
    public let rendering: ChartStudioRendering

    public init(
        id: String,
        kind: Kind,
        category: String,
        headline: String,
        blurb: String,
        rendering: ChartStudioRendering
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.headline = headline
        self.blurb = blurb
        self.rendering = rendering
    }
}

// MARK: - Quick Facts

public struct QuickFact: Hashable, Sendable, Identifiable {
    public enum Tone: String, Sendable {
        case neutral, positive, warning
    }

    public let id: String
    public let label: String         // small all-caps eyebrow ("TODAY", "TOP MODEL")
    public let value: String         // the headline number/string ("$18.74", "claude-sonnet-4.5")
    public let detail: String        // one-line context ("vs $14.20 yesterday")
    public let tone: Tone
    public let sparkline: [Double]   // optional micro-sparkline; empty = none

    public init(
        id: String,
        label: String,
        value: String,
        detail: String,
        tone: Tone = .neutral,
        sparkline: [Double] = []
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
        self.tone = tone
        self.sparkline = sparkline
    }
}

// MARK: - Generator

public enum StandardGallery {

    /// Compute the 3 quick-fact tiles shown above the gallery. These read
    /// as one-liners — never numerically empty.
    public static func quickFacts(from digest: TrendDataDigest) -> [QuickFact] {
        var facts: [QuickFact] = []

        let isCurrency = digest.displayMode == "currency"

        // Today vs yesterday
        if let today = digest.totals.first(where: { $0.window == "today" }),
           let sevenDay = digest.totals.first(where: { $0.window == "7d" }) {
            let avgPriorDay = max(0, (sevenDay.costUsd - today.costUsd)) / 6.0
            let delta = avgPriorDay > 0 ? (today.costUsd - avgPriorDay) / avgPriorDay : 0
            let tone: QuickFact.Tone =
                delta > 0.25 ? .warning :
                delta < -0.10 ? .positive : .neutral
            let value = isCurrency ? formatCurrency(today.costUsd) : formatTokens(today.tokens)
            let detail: String
            if avgPriorDay > 0 {
                let pct = Int(delta * 100)
                let arrow = pct >= 0 ? "↑" : "↓"
                detail = "\(arrow) \(abs(pct))% vs 7-day avg"
            } else {
                detail = "first day on record"
            }
            facts.append(QuickFact(
                id: "fact.today",
                label: "TODAY",
                value: value,
                detail: detail,
                tone: tone,
                sparkline: digest.daily.suffix(7).map(\.total)
            ))
        }

        // Top provider share
        if let top = digest.providers.first {
            let pct = Int(top.sharePct.rounded())
            let tone: QuickFact.Tone = pct >= 80 ? .warning : .neutral
            facts.append(QuickFact(
                id: "fact.topProvider",
                label: "TOP PROVIDER",
                value: top.provider,
                detail: "\(pct)% of tokens · \(formatCurrency(top.costUsd))",
                tone: tone
            ))
        }

        // Cache savings
        let hit = Int((digest.cache.cacheHitRate * 100).rounded())
        if digest.cache.totalCacheReadTokens > 0 {
            let tone: QuickFact.Tone = hit >= 50 ? .positive : (hit < 15 ? .warning : .neutral)
            let savings = digest.cache.estSavingsUsd
            let detail = savings >= 0.01
                ? "saved ≈ \(formatCurrency(savings))"
                : "\(formatTokens(digest.cache.totalCacheReadTokens)) cache reads"
            facts.append(QuickFact(
                id: "fact.cache",
                label: "CACHE HITS",
                value: "\(hit)%",
                detail: detail,
                tone: tone
            ))
        } else if let firstModel = digest.models.first {
            facts.append(QuickFact(
                id: "fact.topModel",
                label: "TOP MODEL",
                value: firstModel.model,
                detail: "\(formatTokens(firstModel.tokens)) tokens"
            ))
        }

        return facts
    }

    /// Build the 6 standard gallery items (charts + insights + ascii flair).
    /// Each generator returns `nil` when there's not enough data to make
    /// the chart honest; the caller skips empty slots.
    public static func items(from digest: TrendDataDigest) -> [StandardGalleryItem] {
        let candidates: [StandardGalleryItem?] = [
            burnTrajectory(from: digest),
            stackedDailyByProvider(from: digest),
            providerShareDonut(from: digest),
            modelPerformance(from: digest),
            hourOfDayHeat(from: digest),
            cacheHealthInsight(from: digest)
        ]
        return candidates.compactMap { $0 }
    }

    // MARK: - 1. Burn Trajectory (line + 7-day rolling)

    private static func burnTrajectory(from digest: TrendDataDigest) -> StandardGalleryItem? {
        guard digest.daily.count >= 4 else { return nil }
        let dailyPoints = digest.daily.map { day in
            ChartSpec.DataPoint(x: .string(day.date), y: day.total, group: "daily", label: nil)
        }
        // 7-day rolling average overlay
        let totals = digest.daily.map(\.total)
        let rollingPoints: [ChartSpec.DataPoint] = digest.daily.enumerated().map { idx, day in
            let lo = max(0, idx - 6)
            let window = Array(totals[lo...idx])
            let avg = window.reduce(0, +) / Double(window.count)
            return ChartSpec.DataPoint(x: .string(day.date), y: avg, group: "rolling", label: nil)
        }
        // Aurora palette — warm coral lead + mercury rolling baseline.
        let series: [ChartSpec.Series] = [
            ChartSpec.Series(name: "Daily", color: "#E07868", points: dailyPoints),       // ember
            ChartSpec.Series(name: "7-day avg", color: "#C8BFB5", points: rollingPoints)   // mercury
        ]
        let spec = ChartSpec(
            kind: .area,
            title: "Burn trajectory",
            subtitle: "Daily \(digest.displayMode == "currency" ? "spend" : "tokens") with 7-day rolling average",
            xAxis: ChartSpec.AxisDescriptor(title: "Date", kind: "time"),
            yAxis: ChartSpec.AxisDescriptor(title: digest.displayMode == "currency" ? "USD" : "Tokens", kind: "linear"),
            series: series,
            annotations: nil,
            valueFormat: digest.displayMode == "currency" ? "currency" : "tokens"
        )
        return StandardGalleryItem(
            id: "gallery.burnTrajectory",
            kind: .chart,
            category: "Spend",
            headline: "Where your burn is heading",
            blurb: "Last \(digest.daily.count) days · with rolling baseline",
            rendering: .swiftChart(spec)
        )
    }

    // MARK: - 2. Stacked Daily by Provider

    private static func stackedDailyByProvider(from digest: TrendDataDigest) -> StandardGalleryItem? {
        guard digest.daily.count >= 5 else { return nil }
        let providersPresent = digest.providers.prefix(4).map(\.providerKey)
        guard !providersPresent.isEmpty else { return nil }

        // Aurora palette: ember → whimsy → amber → mercury (warm-first).
        let palette = ["#E07868", "#A294F0", "#E5A848", "#C8BFB5"]
        let series: [ChartSpec.Series] = providersPresent.enumerated().map { idx, providerKey in
            let displayName = digest.providers.first { $0.providerKey == providerKey }?.provider ?? providerKey
            let points = digest.daily.map { day -> ChartSpec.DataPoint in
                let v = day.perProvider[providerKey] ?? 0
                return ChartSpec.DataPoint(x: .string(day.date), y: v, group: displayName, label: nil)
            }
            return ChartSpec.Series(name: displayName, color: palette[idx % palette.count], points: points)
        }
        let spec = ChartSpec(
            kind: .stackedArea,
            title: "Daily mix",
            subtitle: "Stacked spend by provider · \(digest.daily.count) days",
            xAxis: ChartSpec.AxisDescriptor(title: "Date", kind: "time"),
            yAxis: ChartSpec.AxisDescriptor(title: "USD", kind: "linear"),
            series: series,
            annotations: nil,
            valueFormat: "currency"
        )
        return StandardGalleryItem(
            id: "gallery.stackedDaily",
            kind: .chart,
            category: "Mix",
            headline: "Provider mix, day by day",
            blurb: "Top \(series.count) providers · stacked",
            rendering: .swiftChart(spec)
        )
    }

    // MARK: - 3. Provider Share Donut

    private static func providerShareDonut(from digest: TrendDataDigest) -> StandardGalleryItem? {
        guard digest.providers.count >= 2 else { return nil }
        // Aurora palette for the donut wedges.
        let palette = ["#E07868", "#A294F0", "#E5A848", "#C8BFB5", "#F0A07A"]
        let points = digest.providers.prefix(5).enumerated().map { idx, p in
            ChartSpec.DataPoint(
                x: .string(p.provider),
                y: Double(p.tokens),
                group: p.provider,
                label: "\(Int(p.sharePct.rounded()))%"
            )
        }
        _ = palette
        let series = ChartSpec.Series(
            name: "Tokens",
            color: palette[0],
            points: points
        )
        let spec = ChartSpec(
            kind: .donut,
            title: "Token share",
            subtitle: "Across all providers",
            xAxis: nil,
            yAxis: nil,
            series: [series],
            annotations: nil,
            valueFormat: "tokens"
        )
        return StandardGalleryItem(
            id: "gallery.providerDonut",
            kind: .chart,
            category: "Mix",
            headline: "How your tokens split",
            blurb: "Top 5 providers · share of total tokens",
            rendering: .swiftChart(spec)
        )
    }

    // MARK: - 4. Model Performance Scatter

    private static func modelPerformance(from digest: TrendDataDigest) -> StandardGalleryItem? {
        // Need cost + tokens + multiple models
        let candidates = digest.models.filter { $0.tokens > 0 && $0.costUsd >= 0 }
        guard candidates.count >= 2 else { return nil }
        let palette = ["#E07868", "#9080D8", "#2CCAC0", "#E0A030", "#C8BFB5", "#8E86D0", "#F0C040", "#3DD68C"]
        let series = candidates.enumerated().map { idx, m -> ChartSpec.Series in
            let costPerMTok = m.tokens > 0 ? (m.costUsd / Double(m.tokens) * 1_000_000) : 0
            return ChartSpec.Series(
                name: m.model,
                color: palette[idx % palette.count],
                points: [
                    ChartSpec.DataPoint(
                        x: .double(Double(m.tokens)),
                        y: costPerMTok,
                        group: m.model,
                        label: m.model
                    )
                ]
            )
        }
        let spec = ChartSpec(
            kind: .scatter,
            title: "Model performance",
            subtitle: "Cost per million tokens × volume",
            xAxis: ChartSpec.AxisDescriptor(title: "Tokens used", kind: "linear"),
            yAxis: ChartSpec.AxisDescriptor(title: "$ / 1M tokens", kind: "linear"),
            series: series,
            annotations: nil,
            valueFormat: "currency"
        )
        return StandardGalleryItem(
            id: "gallery.modelScatter",
            kind: .chart,
            category: "Models",
            headline: "Which model is actually pulling its weight",
            blurb: "Cost-per-million vs total volume · top \(candidates.count)",
            rendering: .swiftChart(spec)
        )
    }

    // MARK: - 5. Hour-of-day heat strip

    private static func hourOfDayHeat(from digest: TrendDataDigest) -> StandardGalleryItem? {
        let total = digest.hourly.reduce(0) { $0 + $1.costUsd }
        guard total > 0 else { return nil }
        // Find peak hour
        let peak = digest.hourly.max(by: { $0.costUsd < $1.costUsd })
        let peakLabel = peak.map { String(format: "%02d:00", $0.hour) } ?? "—"

        // Render as ASCII heat strip — feels like a TUI; complements the
        // numeric charts above without duplicating them.
        let cells: [String] = digest.hourly.map { bucket in
            let normalized = peak.map { Double(bucket.costUsd / max(0.0001, $0.costUsd)) } ?? 0
            switch normalized {
            case 0..<0.05:  return " "
            case 0.05..<0.20: return "░"
            case 0.20..<0.45: return "▒"
            case 0.45..<0.75: return "▓"
            default:        return "█"
            }
        }
        let strip = cells.joined()
        let header = (0..<24).map { ($0 % 6 == 0) ? String(format: "%02d", $0) : " " }.joined(separator: "·")
        let line = "│" + strip + "│"

        let asciiSpec = AsciiSpec(
            title: "Hour-of-day heat",
            subtitle: "When you actually burn — last 14 days",
            variant: .heatmap,
            blocks: [
                AsciiSpec.Block(label: nil, lines: [header], accent: "#C8BFB5"),
                AsciiSpec.Block(label: "00 → 23", lines: [line], accent: "#2CCAC0")
            ],
            footnote: "peak at \(peakLabel) · scale: ░ low → █ high"
        )
        return StandardGalleryItem(
            id: "gallery.hourHeat",
            kind: .ascii,
            category: "Time",
            headline: "Your burn rhythm",
            blurb: "Peak hour: \(peakLabel)",
            rendering: .ascii(asciiSpec)
        )
    }

    // MARK: - 6. Cache health insight

    private static func cacheHealthInsight(from digest: TrendDataDigest) -> StandardGalleryItem? {
        let basis = digest.cache.totalInputTokens + digest.cache.totalCacheReadTokens
        guard basis > 0 else { return nil }
        let pct = Int((digest.cache.cacheHitRate * 100).rounded())
        let tone: String
        let body: String
        switch pct {
        case 50...:
            tone = "positive"
            body = "Cache reads carried \(pct)% of your prompts — that's the kind of efficiency that compounds. Estimated savings ≈ \(formatCurrency(digest.cache.estSavingsUsd))."
        case 20..<50:
            tone = "neutral"
            body = "Cache hit rate is \(pct)%. There's still room — long sessions on the same context are where caches really pay off."
        default:
            tone = "warning"
            body = "Only \(pct)% cache hits. If you're rerunning prompts on similar context, reusing cached prefixes can drop cost by ~75%."
        }

        let spark = digest.recentSessions.prefix(20).map { $0.cacheHitRate }
        let insightSpec = InsightSpec(
            title: "Cache health · \(pct)%",
            body: body,
            sparkline: spark.isEmpty ? nil : spark,
            tone: tone
        )
        return StandardGalleryItem(
            id: "gallery.cacheHealth",
            kind: .insight,
            category: "Cache",
            headline: "Are caches earning their keep?",
            blurb: "\(formatTokens(digest.cache.totalCacheReadTokens)) tokens served from cache",
            rendering: .insight(insightSpec)
        )
    }

    // MARK: - Formatters

    private static func formatCurrency(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.0f", value) }
        if value >= 10   { return String(format: "$%.1f", value) }
        return String(format: "$%.2f", value)
    }

    private static func formatTokens(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000     { return String(format: "%.1fK", v / 1_000) }
        return "\(value)"
    }
}

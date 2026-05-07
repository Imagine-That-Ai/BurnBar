import Foundation
import OpenBurnBarCore

// MARK: - Trend Insight Engine
//
// Pure logic that turns a `TrendDataDigest` into a list of short, scannable
// insights for the Trend Atlas auto-rotator. Every rule is independently
// unit-testable (no view/Hermes dependency).
//
// Rules are ranked by `priority` so the most surprising / actionable
// insight appears first. The card shows them on a 6-second rotation.

public struct TrendInsight: Hashable, Sendable, Identifiable {
    public enum Tone: String, Codable, Hashable, Sendable {
        case positive
        case neutral
        case warning
    }

    public let id: String
    public let title: String
    public let detail: String
    public let symbolName: String
    public let tone: Tone
    public let priority: Int

    public init(
        id: String,
        title: String,
        detail: String,
        symbolName: String,
        tone: Tone,
        priority: Int
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.tone = tone
        self.priority = priority
    }
}

public enum TrendInsightEngine {

    /// Build the ordered insight list. Always returns at least one element
    /// — the fallback ensures the rotator never goes dark.
    public static func insights(from digest: TrendDataDigest) -> [TrendInsight] {
        var out: [TrendInsight] = []

        out.append(contentsOf: providerDominance(digest))
        out.append(contentsOf: modelChampion(digest))
        out.append(contentsOf: cacheTrend(digest))
        out.append(contentsOf: peakHour(digest))
        out.append(contentsOf: weekendBurn(digest))
        out.append(contentsOf: reasoningSpike(digest))
        out.append(contentsOf: costPerOutputToken(digest))
        out.append(contentsOf: writingSpeedChampion(digest))

        out.sort { $0.priority > $1.priority }

        if out.isEmpty {
            out.append(
                TrendInsight(
                    id: "fallback.empty",
                    title: "Waiting for signal",
                    detail: "Run a session on your Mac to populate Trend Atlas.",
                    symbolName: "wifi.exclamationmark",
                    tone: .neutral,
                    priority: 0
                )
            )
        }
        return out
    }

    // MARK: - Rules

    private static func providerDominance(_ d: TrendDataDigest) -> [TrendInsight] {
        guard let top = d.providers.first, top.sharePct >= 50 else { return [] }
        let pct = Int(top.sharePct.rounded())
        let runner = d.providers.dropFirst().first
        let detail: String
        if let runner {
            detail = "\(top.provider) drove \(pct)% of tokens — \(runner.provider) trailed at \(Int(runner.sharePct))%."
        } else {
            detail = "\(top.provider) drove \(pct)% of tokens this window."
        }
        return [
            TrendInsight(
                id: "providerDominance",
                title: "\(top.provider) is dominant",
                detail: detail,
                symbolName: "crown.fill",
                tone: pct >= 80 ? .warning : .neutral,
                priority: pct >= 80 ? 95 : 80
            )
        ]
    }

    private static func modelChampion(_ d: TrendDataDigest) -> [TrendInsight] {
        guard let top = d.models.first, top.tokens > 0 else { return [] }
        let pct = Int(top.sharePct.rounded())
        return [
            TrendInsight(
                id: "modelChampion",
                title: "\(top.model) is your workhorse",
                detail: "\(pct)% of all tokens flowed through \(top.model) (\(top.provider)).",
                symbolName: "bolt.fill",
                tone: .positive,
                priority: 70
            )
        ]
    }

    private static func cacheTrend(_ d: TrendDataDigest) -> [TrendInsight] {
        let basis = d.cache.totalInputTokens + d.cache.totalCacheReadTokens + d.cache.totalCacheCreationTokens
        guard basis > 0 else { return [] }
        let pct = Int((d.cache.cacheHitRate * 100).rounded())
        if d.cache.cacheHitRate >= 0.5 {
            return [
                TrendInsight(
                    id: "cacheHigh",
                    title: "\(pct)% cache hits",
                    detail: "Strong reuse — \(d.cache.totalCacheReadTokens.formatAsTokenVolume()) tokens read from cache.",
                    symbolName: "internaldrive.fill",
                    tone: .positive,
                    priority: 85
                )
            ]
        } else if d.cache.cacheHitRate < 0.15 {
            return [
                TrendInsight(
                    id: "cacheLow",
                    title: "Low cache reuse",
                    detail: "Only \(pct)% of prompt tokens are cached — most prompts are paying full price.",
                    symbolName: "exclamationmark.triangle.fill",
                    tone: .warning,
                    priority: 90
                )
            ]
        }
        return []
    }

    private static func peakHour(_ d: TrendDataDigest) -> [TrendInsight] {
        guard let peak = d.hourly.max(by: { $0.costUsd < $1.costUsd }), peak.costUsd > 0 else { return [] }
        let label = labelForHour(peak.hour)
        return [
            TrendInsight(
                id: "peakHour",
                title: "Peak burn at \(label)",
                detail: "Most expensive hour over the last 14 days — \(peak.costUsd.formatAsCost()).",
                symbolName: "clock.fill",
                tone: .neutral,
                priority: 60
            )
        ]
    }

    private static func weekendBurn(_ d: TrendDataDigest) -> [TrendInsight] {
        // Compare last 7 days vs trailing 30 to detect weekend skew via daily series.
        let recentDays = d.daily.suffix(14)
        guard recentDays.count >= 7 else { return [] }
        let weekendDates = recentDays.filter { isWeekend(dateString: $0.date) }
        let weekdayDates = recentDays.filter { !isWeekend(dateString: $0.date) }
        guard !weekendDates.isEmpty, !weekdayDates.isEmpty else { return [] }
        let weekendAvg = weekendDates.reduce(0.0) { $0 + $1.total } / Double(weekendDates.count)
        let weekdayAvg = weekdayDates.reduce(0.0) { $0 + $1.total } / Double(weekdayDates.count)
        guard weekdayAvg > 0 else { return [] }
        let ratio = weekendAvg / weekdayAvg
        if ratio >= 1.25 {
            let pct = Int(((ratio - 1) * 100).rounded())
            return [
                TrendInsight(
                    id: "weekendBurn",
                    title: "Weekends run hot",
                    detail: "Saturday/Sunday burn is \(pct)% above weekday average.",
                    symbolName: "sparkles",
                    tone: .neutral,
                    priority: 55
                )
            ]
        }
        if ratio <= 0.5 {
            let pct = Int(((1 - ratio) * 100).rounded())
            return [
                TrendInsight(
                    id: "weekendCool",
                    title: "Quiet weekends",
                    detail: "Saturday/Sunday burn is \(pct)% below weekday average.",
                    symbolName: "moon.stars.fill",
                    tone: .positive,
                    priority: 50
                )
            ]
        }
        return []
    }

    private static func reasoningSpike(_ d: TrendDataDigest) -> [TrendInsight] {
        let totalReasoning = d.recentSessions.reduce(0) { $0 + $1.reasoningTokens }
        let totalOutput = d.recentSessions.reduce(0) { $0 + $1.outputTokens }
        guard totalOutput > 0, totalReasoning > 0 else { return [] }
        let ratio = Double(totalReasoning) / Double(totalOutput + totalReasoning)
        if ratio >= 0.4 {
            let pct = Int((ratio * 100).rounded())
            return [
                TrendInsight(
                    id: "reasoningSpike",
                    title: "Heavy reasoning load",
                    detail: "\(pct)% of generated tokens were reasoning — these don't appear in chat output.",
                    symbolName: "brain.head.profile",
                    tone: .warning,
                    priority: 75
                )
            ]
        }
        return []
    }

    private static func costPerOutputToken(_ d: TrendDataDigest) -> [TrendInsight] {
        guard let topModel = d.models.first, topModel.tokens > 0 else { return [] }
        let cheapest = d.models.filter { $0.tokens > 1000 && $0.costUsd > 0 }
            .min { (a, b) -> Bool in
                let aRate = a.costUsd / Double(a.tokens)
                let bRate = b.costUsd / Double(b.tokens)
                return aRate < bRate
            }
        guard let cheapest, cheapest.model != topModel.model else { return [] }
        let topRate = topModel.costUsd / Double(max(1, topModel.tokens))
        let cheapestRate = cheapest.costUsd / Double(max(1, cheapest.tokens))
        guard cheapestRate > 0 else { return [] }
        let ratio = topRate / cheapestRate
        if ratio >= 2 {
            let multiple = String(format: "%.1f", ratio)
            return [
                TrendInsight(
                    id: "costPerOutputToken",
                    title: "\(topModel.model) is \(multiple)× pricier",
                    detail: "vs \(cheapest.model). Consider routing simpler tasks to \(cheapest.model).",
                    symbolName: "scalemass.fill",
                    tone: .warning,
                    priority: 65
                )
            ]
        }
        return []
    }

    private static func writingSpeedChampion(_ d: TrendDataDigest) -> [TrendInsight] {
        // "Writing speed" = output tokens per second across sessions, grouped by model.
        let groups = Dictionary(grouping: d.recentSessions) { $0.model }
        let modelStats: [(String, Double)] = groups.compactMap { model, sessions in
            let total = sessions.reduce(0.0) { $0 + $1.outputTokensPerSecond }
            guard !sessions.isEmpty, total > 0 else { return nil }
            return (model, total / Double(sessions.count))
        }
        guard let champion = modelStats.max(by: { $0.1 < $1.1 }), champion.1 > 5 else {
            return []
        }
        let tps = String(format: "%.0f", champion.1)
        return [
            TrendInsight(
                id: "writingSpeed",
                title: "\(champion.0) writes at \(tps) tok/s",
                detail: "Fastest model in your fleet over the last 25 sessions.",
                symbolName: "hare.fill",
                tone: .positive,
                priority: 45
            )
        ]
    }

    // MARK: - Date helpers

    private static func isWeekend(dateString: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateString) else { return false }
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: date)
        return weekday == 1 || weekday == 7   // Sunday=1, Saturday=7
    }

    private static func labelForHour(_ h: Int) -> String {
        let hour = ((h % 24) + 24) % 24
        if hour == 0 { return "12 am" }
        if hour < 12 { return "\(hour) am" }
        if hour == 12 { return "12 pm" }
        return "\(hour - 12) pm"
    }
}

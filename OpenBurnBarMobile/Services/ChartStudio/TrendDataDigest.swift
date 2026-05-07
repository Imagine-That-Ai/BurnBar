import Foundation
import OpenBurnBarCore

// MARK: - Trend Data Digest
//
// Compact, JSON-serializable snapshot of everything Hermes needs to draw
// charts about the user's burn. Capped at ~6KB so it always fits in a
// single Hermes turn even on small open-source models.
//
// This type is `Sendable` and pure-value so it can be built off the main
// thread and unit-tested without view dependencies.

public struct TrendDataDigest: Codable, Hashable, Sendable {

    // MARK: - Top-level totals

    public struct WindowTotals: Codable, Hashable, Sendable {
        public let window: String          // "today" | "7d" | "30d"
        public let costUsd: Double
        public let tokens: Int
        public let requests: Int
    }

    // MARK: - Per-provider summary

    public struct ProviderSlice: Codable, Hashable, Sendable {
        public let provider: String        // display name e.g. "Claude Code"
        public let providerKey: String     // persistedToken
        public let costUsd: Double
        public let tokens: Int
        public let requests: Int
        public let sharePct: Double        // 0...100
    }

    // MARK: - Per-model summary

    public struct ModelSlice: Codable, Hashable, Sendable {
        public let model: String
        public let provider: String
        public let costUsd: Double
        public let tokens: Int
        public let requests: Int
        public let sharePct: Double
    }

    // MARK: - Per-project summary

    public struct ProjectSlice: Codable, Hashable, Sendable {
        public let project: String
        public let costUsd: Double
        public let tokens: Int
        public let sessions: Int
    }

    // MARK: - Per-device summary

    public struct DeviceSlice: Codable, Hashable, Sendable {
        public let device: String
        public let tokens: Int
        public let requests: Int
    }

    // MARK: - Daily series

    public struct DailySeries: Codable, Hashable, Sendable {
        public let date: String            // ISO `yyyy-MM-dd`
        public let total: Double
        public let perProvider: [String: Double]   // providerKey → value
    }

    // MARK: - Hour-of-day histogram

    public struct HourBucket: Codable, Hashable, Sendable {
        public let hour: Int               // 0...23
        public let costUsd: Double
        public let tokens: Int
    }

    // MARK: - Recent session

    public struct SessionSlice: Codable, Hashable, Sendable {
        public let id: String
        public let startedAt: String       // ISO 8601
        public let durationSec: Int
        public let provider: String
        public let providerKey: String
        public let model: String
        public let project: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheCreationTokens: Int
        public let reasoningTokens: Int
        public let costUsd: Double
        public let cacheHitRate: Double    // 0...1
        public let outputTokensPerSecond: Double
    }

    // MARK: - Cache aggregates

    public struct CacheAggregate: Codable, Hashable, Sendable {
        public let totalCacheReadTokens: Int
        public let totalCacheCreationTokens: Int
        public let totalInputTokens: Int
        public let cacheHitRate: Double                // 0...1 across window
        public let estSavingsUsd: Double               // rough: cacheRead × (input price - cache read price), see prompt
    }

    // MARK: - Display mode hint

    public let displayMode: String                     // "currency" | "tokens"
    public let generatedAt: String                     // ISO 8601
    public let windowDescription: String               // human label e.g. "last 30 days"

    public let totals: [WindowTotals]
    public let providers: [ProviderSlice]
    public let models: [ModelSlice]
    public let projects: [ProjectSlice]
    public let devices: [DeviceSlice]
    public let daily: [DailySeries]
    public let hourly: [HourBucket]
    public let recentSessions: [SessionSlice]
    public let cache: CacheAggregate

    // MARK: - Builder

    /// Build a digest from `DashboardStore` + `ActivityStore` data. Caps each
    /// list to a sensible size so the JSON stays under ~6KB.
    public static func build(
        windowTotals: [RollupWindowKey: RollupTotals],
        providerSummaries: [RollupProviderSummary],
        modelSummaries: [RollupModelSummary],
        deviceSummaries: [RollupDeviceSummary],
        dailyPoints: [RollupDailyPoint],
        recentUsages: [TokenUsage],
        displayMode: UsageDisplayMode,
        windowDescription: String = "last 30 days",
        now: Date = Date()
    ) -> TrendDataDigest {

        // Totals (today / 7d / 30d only — keep it tight)
        let totals: [WindowTotals] = [
            (RollupWindowKey.today, "today"),
            (RollupWindowKey.sevenDays, "7d"),
            (RollupWindowKey.thirtyDays, "30d")
        ].compactMap { key, label in
            guard let t = windowTotals[key] else { return nil }
            return WindowTotals(
                window: label,
                costUsd: t.costUsd,
                tokens: t.tokens,
                requests: t.requests
            )
        }

        // Providers (top 6, with share %)
        let providerTotal = providerSummaries.reduce(0.0) { $0 + Double($1.totalTokens) }
        let providerSlices = providerSummaries.prefix(6).map { p -> ProviderSlice in
            let share = providerTotal > 0
                ? (Double(p.totalTokens) / providerTotal) * 100
                : 0
            let displayProvider = AgentProvider.fromPersistedToken(p.provider)
                ?? AgentProvider.fromProviderID(p.providerID)
            return ProviderSlice(
                provider: displayProvider?.displayName ?? p.provider,
                providerKey: p.provider,
                costUsd: p.totalCost ?? 0,
                tokens: p.totalTokens,
                requests: p.totalRequests,
                sharePct: share
            )
        }

        // Models (top 8, with share %)
        let modelTotal = modelSummaries.reduce(0) { $0 + $1.tokens }
        let modelSlices = modelSummaries.prefix(8).map { m -> ModelSlice in
            let share = modelTotal > 0
                ? (Double(m.tokens) / Double(modelTotal)) * 100
                : 0
            return ModelSlice(
                model: m.model,
                provider: m.provider,
                costUsd: m.cost ?? 0,
                tokens: m.tokens,
                requests: m.requests,
                sharePct: share
            )
        }

        // Devices (top 4)
        let deviceSlices = deviceSummaries.prefix(4).map {
            DeviceSlice(
                device: $0.deviceId,
                tokens: $0.tokens,
                requests: $0.requests
            )
        }

        // Daily series — bucket recent usage by day to derive perProvider stack
        let calendar = Calendar(identifier: .gregorian)
        let daily = buildDailySeries(
            dailyPoints: dailyPoints,
            recentUsages: recentUsages,
            calendar: calendar
        )

        // Hour-of-day histogram from recentUsages (last 14 days)
        let hourly = buildHourly(
            recentUsages: recentUsages,
            calendar: calendar,
            now: now
        )

        // Project slices — group recentUsages by projectName, top 6
        let projectGroups = Dictionary(grouping: recentUsages) { $0.projectName }
        let projectSlices = projectGroups
            .map { project, items -> ProjectSlice in
                let cost = items.reduce(0.0) { $0 + $1.cost }
                let tokens = items.reduce(0) { $0 + $1.totalTokens }
                let sessions = Set(items.map(\.sessionId)).count
                return ProjectSlice(
                    project: project.isEmpty ? "Unknown" : project,
                    costUsd: cost,
                    tokens: tokens,
                    sessions: sessions
                )
            }
            .sorted { $0.costUsd > $1.costUsd }
            .prefix(6)
            .map { $0 }

        // Recent sessions (top 25 by start time)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let recentSessions = recentUsages.prefix(25).map { u -> SessionSlice in
            let duration = Int(max(0, u.endTime.timeIntervalSince(u.startTime)))
            let promptBasis = max(0, u.inputTokens) + max(0, u.cacheCreationTokens) + max(0, u.cacheReadTokens)
            let cacheHit: Double = promptBasis > 0
                ? Double(max(0, u.cacheReadTokens)) / Double(promptBasis)
                : 0
            let velocity: Double = duration > 0
                ? Double(u.outputTokens) / Double(duration)
                : 0
            return SessionSlice(
                id: u.sessionId,
                startedAt: iso.string(from: u.startTime),
                durationSec: duration,
                provider: u.provider.displayName,
                providerKey: u.provider.persistedToken,
                model: u.model,
                project: u.projectName.isEmpty ? "Unknown" : u.projectName,
                inputTokens: u.inputTokens,
                outputTokens: u.outputTokens,
                cacheReadTokens: u.cacheReadTokens,
                cacheCreationTokens: u.cacheCreationTokens,
                reasoningTokens: u.reasoningTokens,
                costUsd: u.cost,
                cacheHitRate: cacheHit,
                outputTokensPerSecond: velocity
            )
        }

        // Cache aggregate
        let totalInput = recentUsages.reduce(0) { $0 + max(0, $1.inputTokens) }
        let totalCacheRead = recentUsages.reduce(0) { $0 + max(0, $1.cacheReadTokens) }
        let totalCacheCreation = recentUsages.reduce(0) { $0 + max(0, $1.cacheCreationTokens) }
        let basis = totalInput + totalCacheRead + totalCacheCreation
        let cacheHitRate: Double = basis > 0 ? Double(totalCacheRead) / Double(basis) : 0
        // Rough savings estimate: assume non-cached input is 4× the cost of cache read
        // (Anthropic's published 1× vs 0.25× → 75% cheaper). This is a heuristic
        // shown to Hermes; it is *not* user-facing currency without disclaimer.
        let estSavings = Double(totalCacheRead) * 0.000003
        let cache = CacheAggregate(
            totalCacheReadTokens: totalCacheRead,
            totalCacheCreationTokens: totalCacheCreation,
            totalInputTokens: totalInput,
            cacheHitRate: cacheHitRate,
            estSavingsUsd: estSavings
        )

        return TrendDataDigest(
            displayMode: displayMode.rawValue,
            generatedAt: iso.string(from: now),
            windowDescription: windowDescription,
            totals: totals,
            providers: Array(providerSlices),
            models: Array(modelSlices),
            projects: projectSlices,
            devices: Array(deviceSlices),
            daily: daily,
            hourly: hourly,
            recentSessions: Array(recentSessions),
            cache: cache
        )
    }

    /// Encodes the digest as compact JSON. Used both by the prompt engine
    /// and by debug overlays. Returns empty string on encoder failure.
    public func compactJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Approximate byte size of the JSON payload — used by tests to keep us
    /// under the 6KB ceiling.
    public var approximateByteSize: Int {
        compactJSON().utf8.count
    }

    // MARK: - Daily series helpers

    private static func buildDailySeries(
        dailyPoints: [RollupDailyPoint],
        recentUsages: [TokenUsage],
        calendar: Calendar
    ) -> [DailySeries] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"

        // Bucket recent usage by day → providerKey → value (cost)
        var perDay: [String: [String: Double]] = [:]
        for usage in recentUsages {
            let day = formatter.string(from: usage.startTime)
            perDay[day, default: [:]][usage.provider.persistedToken, default: 0] += usage.cost
        }

        // Cap to last 30 daily points to control payload size
        return dailyPoints.suffix(30).map { point in
            let day = formatter.string(from: point.date)
            return DailySeries(
                date: day,
                total: point.value,
                perProvider: perDay[day] ?? [:]
            )
        }
    }

    private static func buildHourly(
        recentUsages: [TokenUsage],
        calendar: Calendar,
        now: Date
    ) -> [HourBucket] {
        let cutoff = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        var buckets: [Int: (Double, Int)] = [:]
        for usage in recentUsages where usage.startTime >= cutoff {
            let hour = calendar.component(.hour, from: usage.startTime)
            let existing = buckets[hour] ?? (0, 0)
            buckets[hour] = (existing.0 + usage.cost, existing.1 + usage.totalTokens)
        }
        return (0..<24).map { h in
            let (cost, tokens) = buckets[h] ?? (0, 0)
            return HourBucket(hour: h, costUsd: cost, tokens: tokens)
        }
    }
}

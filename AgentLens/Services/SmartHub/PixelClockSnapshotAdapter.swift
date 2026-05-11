import Foundation
import OpenBurnBarCore

enum PixelClockSnapshotAdapter {
    @MainActor
    static func quotaItems(
        quotaService: ProviderQuotaService?,
        period: SmartHubTimePeriod,
        statuses: [String: PixelClockAgentStatus] = [:]
    ) -> [PixelClockQuotaItem] {
        AgentProvider.quotaSignalProviders.compactMap { provider in
            let status = statuses[provider.persistedToken] ?? .ready
            guard let snapshot = quotaService?.snapshot(for: provider),
                  let bucket = bestBucket(in: snapshot, for: period) else {
                guard status != .ready else { return nil }
                return PixelClockQuotaItem(
                    providerID: provider.persistedToken,
                    providerName: provider == .factory ? "Factory / Droid" : provider.displayName,
                    percentUsed: 0,
                    usageText: status == .ready ? "ready" : status.displayText.lowercased(),
                    windowLabel: fallbackWindowLabel(for: period),
                    agentStatus: status
                )
            }
            let percent = Int((bucket.progressFraction * 100).rounded())
            return PixelClockQuotaItem(
                providerID: provider.persistedToken,
                providerName: provider == .factory ? "Factory / Droid" : provider.displayName,
                percentUsed: percent,
                usageText: bucket.usageText,
                windowLabel: windowLabel(for: bucket),
                agentStatus: status
            )
        }
    }

    @MainActor
    static func quotaCycleItems(
        quotaService: ProviderQuotaService?,
        statuses: [String: PixelClockAgentStatus] = [:]
    ) -> [PixelClockQuotaItem] {
        AgentProvider.quotaSignalProviders.flatMap { provider -> [PixelClockQuotaItem] in
            let status = statuses[provider.persistedToken] ?? .ready
            guard let snapshot = quotaService?.snapshot(for: provider) else {
                return status == .ready
                    ? []
                    : [
                        fallbackItem(
                            provider: provider,
                            period: .rolling5h,
                            status: status
                        )
                    ]
            }

            let periods: [SmartHubTimePeriod] = [.rolling5h, .rolling7d]
            let items = periods.compactMap { period -> PixelClockQuotaItem? in
                guard let bucket = bestBucket(in: snapshot, for: period) else { return nil }
                return item(provider: provider, bucket: bucket, status: status)
            }

            if items.isEmpty, status != .ready {
                return [fallbackItem(provider: provider, period: .rolling5h, status: status)]
            }
            return items
        }
    }

    static func bestBucket(
        in snapshot: ProviderQuotaSnapshot,
        for period: SmartHubTimePeriod
    ) -> ProviderQuotaBucket? {
        let buckets = snapshot.displayableQuotaBuckets
        if buckets.isEmpty { return nil }

        let target = period.spanHours
        var bestBucket: ProviderQuotaBucket?
        var bestScore = Double.infinity

        for bucket in buckets {
            guard let hours = approximateBucketHours(bucket) else { continue }
            let score = abs(log(max(hours, 0.5)) - log(max(target, 0.5)))
            if score < bestScore {
                bestScore = score
                bestBucket = bucket
            }
        }
        if let bestBucket { return bestBucket }

        let preferredPriorities = ["primary", "month", "monthly", "weekly", "daily"]
        for hint in preferredPriorities {
            if let match = buckets.first(where: { $0.key.lowercased().contains(hint) || $0.label.lowercased().contains(hint) }) {
                return match
            }
        }
        return buckets.first
    }

    static func approximateBucketHours(_ bucket: ProviderQuotaBucket) -> Double? {
        let key = bucket.key.lowercased()
        let label = bucket.label.lowercased()

        if key.contains("five_hour") || label.contains("5-hour") || label.contains("5 hour") || key.contains("five-hour") {
            return 5
        }
        if key.contains("seven_day") || label.contains("7-day") || label.contains("7 day") || key.contains("seven-day") {
            return 24 * 7
        }
        if label.contains("daily") || key.contains("daily") || label.contains("24h") || label.contains("24 hour") {
            return 24
        }
        if label.contains("monthly") || key.contains("month") {
            return 24 * 30
        }
        if label.contains("weekly") || key.contains("weekly") {
            return 24 * 7
        }

        switch bucket.windowKind {
        case .rollingHours:
            return 5
        case .rollingDays:
            return 24 * 7
        case .daily:
            return 24
        case .weekly:
            return 24 * 7
        case .monthly:
            return 24 * 30
        case .lifetime, .custom:
            return nil
        }
    }

    static func windowLabel(for bucket: ProviderQuotaBucket) -> String {
        guard let hours = approximateBucketHours(bucket) else { return "" }
        if hours <= 24 { return "\(Int(hours))h" }
        let days = Int((hours / 24).rounded())
        return "\(days)d"
    }

    static func fallbackWindowLabel(for period: SmartHubTimePeriod) -> String {
        switch period {
        case .rolling5h: return "5h"
        case .rolling24h: return "24h"
        case .rolling7d: return "7d"
        case .rolling30d: return "30d"
        }
    }

    private static func item(
        provider: AgentProvider,
        bucket: ProviderQuotaBucket,
        status: PixelClockAgentStatus
    ) -> PixelClockQuotaItem {
        let percent = Int((bucket.progressFraction * 100).rounded())
        return PixelClockQuotaItem(
            providerID: provider.persistedToken,
            providerName: provider == .factory ? "Factory / Droid" : provider.displayName,
            percentUsed: percent,
            usageText: bucket.usageText,
            windowLabel: windowLabel(for: bucket),
            agentStatus: status
        )
    }

    private static func fallbackItem(
        provider: AgentProvider,
        period: SmartHubTimePeriod,
        status: PixelClockAgentStatus
    ) -> PixelClockQuotaItem {
        PixelClockQuotaItem(
            providerID: provider.persistedToken,
            providerName: provider == .factory ? "Factory / Droid" : provider.displayName,
            percentUsed: 0,
            usageText: status.displayText.lowercased(),
            windowLabel: fallbackWindowLabel(for: period),
            agentStatus: status
        )
    }
}

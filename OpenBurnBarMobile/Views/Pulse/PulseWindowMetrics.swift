import Foundation
import OpenBurnBarCore

struct PulseWindowMetrics: Equatable {
    let total: RollupTotals
    let trailingTotal: RollupTotals?
}

enum PulseWindowMetricBuilder {
    /// Authority for window math is `MobilePulseWindowPolicy` (iOS oracle). The
    /// windows are pure millisecond arithmetic, so no calendar is involved —
    /// `liveQueryStart` is the only place a time zone matters.
    static func metrics(
        scope: PulseTimelineScope,
        rollupTotals: [RollupWindowKey: RollupTotals],
        liveUsages: [TokenUsage],
        now: Date = Date()
    ) -> PulseWindowMetrics {
        let result = MobilePulseWindowPolicy.metrics(
            scope: scope.policyScope,
            rollups: Dictionary(uniqueKeysWithValues: rollupTotals.map { key, value in
                (key.rawValue, MobilePulseRollupTotals(
                    requests: value.requests,
                    tokens: value.tokens,
                    costUsd: value.costUsd
                ))
            }),
            usages: liveUsages.map { usage in
                MobilePulseUsageEvent(
                    startMs: usage.startTime.pulseEpochMs,
                    endMs: usage.endTime.pulseEpochMs,
                    tokens: MobilePulseWindowPolicy.pulseTokens(
                        totalTokens: usage.totalTokens,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        cacheCreationTokens: usage.cacheCreationTokens,
                        cacheReadTokens: usage.cacheReadTokens,
                        reasoningTokens: usage.reasoningTokens
                    ),
                    // The three-spelling coalesce is for Android's raw document
                    // parse; iOS has already decoded them into `costUSD`, so this
                    // call only applies the shared clamp.
                    costUsd: MobilePulseWindowPolicy.pulseCost(
                        costUsd: usage.costUSD,
                        costUSD: usage.costUSD,
                        cost: usage.costUSD
                    )
                )
            },
            nowMs: now.pulseEpochMs
        )
        return PulseWindowMetrics(
            total: RollupTotals(
                requests: result.total.requests,
                tokens: Int(clamping: result.total.tokens),
                costUsd: result.total.costUsd
            ),
            trailingTotal: result.trailing.map {
                RollupTotals(requests: $0.requests, tokens: Int(clamping: $0.tokens), costUsd: $0.costUsd)
            }
        )
    }

    static func liveQueryStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let ms = MobilePulseWindowPolicy.liveQueryStartMs(
            nowMs: now.pulseEpochMs,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        return Date(timeIntervalSince1970: Double(ms) / 1_000)
    }
}

private extension PulseTimelineScope {
    var policyScope: MobilePulseTimelineScope {
        switch self {
        case .minute: return .minute
        case .hour: return .hour
        case .day: return .day
        case .week: return .week
        case .month: return .month
        }
    }
}

private extension Date {
    var pulseEpochMs: Int64 { Int64((timeIntervalSince1970 * 1_000).rounded()) }
}

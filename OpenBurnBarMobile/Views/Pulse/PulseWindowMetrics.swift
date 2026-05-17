import Foundation
import OpenBurnBarCore

struct PulseWindowMetrics: Equatable {
    let total: RollupTotals
    let trailingTotal: RollupTotals?
}

enum PulseWindowMetricBuilder {
    static func metrics(
        scope: PulseTimelineScope,
        rollupTotals: [RollupWindowKey: RollupTotals],
        liveUsages: [TokenUsage],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PulseWindowMetrics {
        switch scope {
        case .minute:
            return liveMetrics(
                from: liveUsages,
                since: now.addingTimeInterval(-60),
                through: now,
                trailingTotal: rollupTotals[.sevenDays]
            )
        case .hour:
            return liveMetrics(
                from: liveUsages,
                since: now.addingTimeInterval(-3_600),
                through: now,
                trailingTotal: rollupTotals[.sevenDays]
            )
        case .day:
            return liveMetrics(
                from: liveUsages,
                since: calendar.startOfDay(for: now),
                through: now,
                trailingTotal: rollupTotals[.sevenDays]
            )
        case .week:
            return PulseWindowMetrics(
                total: rollupTotals[.sevenDays] ?? .zero,
                trailingTotal: rollupTotals[.thirtyDays]
            )
        case .month:
            return PulseWindowMetrics(
                total: rollupTotals[.thirtyDays] ?? .zero,
                trailingTotal: rollupTotals[.ninetyDays]
            )
        }
    }

    static func todayStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    private static func liveMetrics(
        from usages: [TokenUsage],
        since start: Date,
        through end: Date,
        trailingTotal: RollupTotals?
    ) -> PulseWindowMetrics {
        let rows = usages.filter { usage in
            let attributedAt = eventDate(for: usage)
            return attributedAt >= start && attributedAt <= end
        }
        return PulseWindowMetrics(
            total: RollupTotals(
                requests: rows.count,
                tokens: rows.reduce(0) { $0 + max(0, $1.totalTokens) },
                costUsd: rows.reduce(0) { $0 + max(0, $1.costUSD) }
            ),
            trailingTotal: trailingTotal
        )
    }

    private static func eventDate(for usage: TokenUsage) -> Date {
        max(usage.startTime, usage.endTime)
    }
}

private extension RollupTotals {
    static let zero = RollupTotals(requests: 0, tokens: 0, costUsd: 0)
}

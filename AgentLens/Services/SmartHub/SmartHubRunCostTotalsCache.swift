import Foundation
import OpenBurnBarKernel
import OpenBurnBarUI

@MainActor
final class SmartHubRunCostTotalsCache {
    // Match the provider refresh cadence. Usage-table writes still invalidate
    // immediately, while an unchanged seven-day window avoids a second
    // SQLCipher aggregate halfway through every refresh interval.
    static let bucketDurationSeconds: TimeInterval = 60

    private var activeWriteMarker: Int?
    private var activeTimeBucket: Int64?
    private var totalsByPeriod: [String: [AgentProvider: ProviderRunCostTotals]] = [:]

    func values(
        for periods: [SmartHubTimePeriod],
        writeMarker: Int,
        now: Date,
        load: ([SmartHubTimePeriod]) async -> [String: [AgentProvider: ProviderRunCostTotals]]
    ) async -> [String: [AgentProvider: ProviderRunCostTotals]] {
        let timeBucket = Int64(
            floor(now.timeIntervalSince1970 / Self.bucketDurationSeconds)
        )
        if activeWriteMarker != writeMarker || activeTimeBucket != timeBucket {
            totalsByPeriod.removeAll(keepingCapacity: true)
            activeWriteMarker = writeMarker
            activeTimeBucket = timeBucket
        }

        var uniquePeriods: [SmartHubTimePeriod] = []
        for period in periods where !uniquePeriods.contains(period) {
            uniquePeriods.append(period)
        }

        let missingPeriods = uniquePeriods.filter { totalsByPeriod[$0.rawValue] == nil }
        if !missingPeriods.isEmpty {
            let loadedTotals = await load(missingPeriods)
            for period in missingPeriods {
                totalsByPeriod[period.rawValue] = loadedTotals[period.rawValue] ?? [:]
            }
        }
        return totalsByPeriod
    }
}

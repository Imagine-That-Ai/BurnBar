import Foundation
import OpenBurnBarCore

#if canImport(AppKit)
import AppKit
#endif

extension ProviderQuotaService {
    func evaluateReset(previous: ProviderQuotaSnapshot?, current: ProviderQuotaSnapshot) {
        let detection = QuotaResetDetector.detect(
            previous: previous,
            current: current,
            now: Date(),
            consumedBoundaries: Set(celebrationStore.ledger.consumedBoundaries),
            appWasActive: isQuotaCelebrationAppActive,
            lastCaptionByProvider: celebrationStore.ledger.lastCaptionByProvider,
            surpriseCountLastDay: celebrationStore.ledger.surpriseCount(
                for: current.quotaProvider?.persistedToken ?? current.provider.lowercased(),
                within: QuotaResetDetector.doubleTapWindow,
                now: Date()
            )
        )
        celebrationStore.ingest(detection)
    }

    func evaluateClockCrossResets(now: Date = Date()) {
        var combined = QuotaResetDetection()
        let consumed = Set(celebrationStore.ledger.consumedBoundaries)
        for snapshot in Array(snapshotsByProvider.values) + Array(snapshotsByAccountID.values) {
            combined.merge(
                QuotaResetDetector.detectClockCross(
                    snapshot: snapshot,
                    now: now,
                    consumedBoundaries: consumed.union(combined.consumedBoundaries),
                    appWasActive: isQuotaCelebrationAppActive,
                    lastCaptionByProvider: celebrationStore.ledger.lastCaptionByProvider
                )
            )
        }
        combined.events = QuotaResetDetector.deduplicate(combined.events)
        celebrationStore.ingest(combined)
    }

    func earliestPerformableResetDate(now: Date = Date()) -> Date? {
        let dates = (Array(snapshotsByProvider.values) + Array(snapshotsByAccountID.values))
            .flatMap(\.buckets)
            .filter { !$0.isQuotaResetExtraLane && QuotaResetDetector.isPerformableWindow($0.resetWindowClass) }
            .compactMap(\.resetsAt)
            .filter { $0 > now }
        return dates.min()
    }

    private var isQuotaCelebrationAppActive: Bool {
        #if canImport(AppKit)
        return NSApp.isActive
        #else
        return true
        #endif
    }
}

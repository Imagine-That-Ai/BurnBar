import XCTest
@testable import OpenBurnBarCore

final class QuotaResetDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_011_200) // 2026-08-12 00:00 UTC

    // MARK: - Gates

    func test_firstSnapshot_emitsNothing() {
        let current = snapshot(used: 2, resetsAt: now.addingTimeInterval(7.days))
        let detection = QuotaResetDetector.detect(previous: nil, current: current, now: now)
        XCTAssertTrue(detection.isEmpty)
    }

    func test_estimatedSnapshot_emitsNothing() {
        let previous = snapshot(used: 80, resetsAt: now.addingTimeInterval(2.days), confidence: .medium)
        let current = snapshot(used: 2, resetsAt: now.addingTimeInterval(7.days), confidence: .medium)
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertTrue(detection.isEmpty)
    }

    func test_staleSnapshot_emitsNothing() {
        let previous = snapshot(used: 80, resetsAt: now.addingTimeInterval(2.days))
        let current = snapshot(used: 2, resetsAt: now.addingTimeInterval(7.days), confidence: .stale)
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertTrue(detection.isEmpty)
    }

    func test_jitterBelowThreshold_emitsNothing() {
        let previous = snapshot(used: 40, resetsAt: now.addingTimeInterval(3.days))
        let current = snapshot(used: 22, resetsAt: now.addingTimeInterval(3.days))
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertTrue(detection.isEmpty)
    }

    func test_limitDoubledUsedFlat_emitsNothing() {
        let previous = snapshot(
            key: "cursor-plan",
            label: "Included usage",
            window: "monthly",
            used: 50,
            limit: 100,
            usedPercent: 50,
            resetsAt: now.addingTimeInterval(10.days),
            unit: .currency
        )
        let current = snapshot(
            key: "cursor-plan",
            label: "Included usage",
            window: "monthly",
            used: 50,
            limit: 200,
            usedPercent: 25,
            resetsAt: now.addingTimeInterval(10.days),
            unit: .currency
        )
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertTrue(detection.isEmpty)
    }

    // MARK: - Window policy

    func test_fiveHourOnly_isWhisperNotPerform() {
        let previous = sessionSnapshot(used: 90, resetsAt: now.addingTimeInterval(-60))
        let current = sessionSnapshot(used: 4, resetsAt: now.addingTimeInterval(5.hours))
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertEqual(detection.events.count, 1)
        XCTAssertEqual(detection.events.first?.presentation, .whisper)
        XCTAssertEqual(detection.events.first?.windowClass, .session)
        XCTAssertTrue(QuotaResetDetector.performances(from: detection.events).isEmpty)
    }

    func test_codeReviewLane_isIgnored() {
        let previous = snapshot(
            key: "codex-code-review-5h",
            label: "Code Review 5-hour window",
            window: "rollingHours",
            used: 90,
            resetsAt: now.addingTimeInterval(2.days)
        )
        let current = snapshot(
            key: "codex-code-review-5h",
            label: "Code Review 5-hour window",
            window: "rollingHours",
            used: 2,
            resetsAt: now.addingTimeInterval(7.days)
        )
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertTrue(detection.isEmpty)
    }

    // MARK: - Scheduled vs surprise

    func test_clockCrossThenHTTP_doesNotDoubleEmit() {
        let raw = snapshot(used: 82, resetsAt: now.addingTimeInterval(-120))
        let clock = QuotaResetDetector.detectClockCross(snapshot: raw, now: now)
        XCTAssertEqual(clock.events.first?.kind, .scheduled)
        XCTAssertEqual(clock.events.first?.presentation, .perform)

        let refreshed = snapshot(used: 3, resetsAt: now.addingTimeInterval(7.days))
        let http = QuotaResetDetector.detect(
            previous: raw,
            current: refreshed,
            now: now,
            consumedBoundaries: clock.consumedBoundaries
        )
        XCTAssertTrue(http.isEmpty)
    }

    func test_lateObservation_isScheduledNotSurprise() {
        let previousReset = now.addingTimeInterval(-2.days)
        let previous = snapshot(used: 70, resetsAt: previousReset)
        let current = snapshot(used: 4, resetsAt: now.addingTimeInterval(5.days))
        let detection = QuotaResetDetector.detect(
            previous: previous,
            current: current,
            now: now,
            appWasActive: false
        )
        XCTAssertEqual(detection.events.map(\.kind), [.scheduled])
        XCTAssertEqual(detection.events.first?.freshness, .whileAway)
    }

    func test_midWindowDrop_isSurprise() {
        let previous = snapshot(used: 70, resetsAt: now.addingTimeInterval(3.days))
        let current = snapshot(used: 3, resetsAt: now.addingTimeInterval(7.days))
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertEqual(detection.events.map(\.kind), [.surprise])
        XCTAssertEqual(detection.events.first?.presentation, .perform)
        XCTAssertEqual(detection.events.first?.windowClass, .weekly)
    }

    func test_imminentScheduledReset_isScheduled() {
        let previous = snapshot(used: 88, resetsAt: now.addingTimeInterval(20 * 60))
        let current = snapshot(used: 2, resetsAt: now.addingTimeInterval(7.days))
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertEqual(detection.events.map(\.kind), [.scheduled])
    }

    func test_staleClockCross_isLedgerOnly() {
        let raw = snapshot(used: 91, resetsAt: now.addingTimeInterval(-3.days))
        let detection = QuotaResetDetector.detectClockCross(snapshot: raw, now: now)
        XCTAssertEqual(detection.events.first?.presentation, .ledgerOnly)
        XCTAssertTrue(QuotaResetDetector.performances(from: detection.events).isEmpty)
    }

    // MARK: - Banked

    func test_bankedRedeem_beatsSurprise() {
        let card = QuotaResetCredit(id: "card-1", expiresAt: now.addingTimeInterval(20.days))
        let previous = snapshot(
            used: 92,
            resetsAt: now.addingTimeInterval(4.days),
            credits: [card]
        )
        let current = snapshot(
            used: 1,
            resetsAt: now.addingTimeInterval(7.days),
            credits: []
        )
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertEqual(Set(detection.events.map(\.kind)), [.bankedRedeem])
    }

    func test_bankedGrant_withoutUsedDrop() {
        let card = QuotaResetCredit(id: "card-2", expiresAt: now.addingTimeInterval(30.days))
        let previous = snapshot(used: 44, resetsAt: now.addingTimeInterval(4.days), credits: [])
        let current = snapshot(used: 45, resetsAt: now.addingTimeInterval(4.days), credits: [card])
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertEqual(detection.events.map(\.kind), [.bankedGrant])
        XCTAssertEqual(detection.events.first?.presentation, .perform)
    }

    // MARK: - Multi-window / multi-account

    func test_sessionAndWeeklyTogether_keepsWeekly() {
        let previous = dualSnapshot(
            sessionUsed: 80,
            weeklyUsed: 75,
            sessionReset: now.addingTimeInterval(2.hours),
            weeklyReset: now.addingTimeInterval(-30)
        )
        let current = dualSnapshot(
            sessionUsed: 1,
            weeklyUsed: 2,
            sessionReset: now.addingTimeInterval(5.hours),
            weeklyReset: now.addingTimeInterval(7.days)
        )
        let detection = QuotaResetDetector.detect(previous: previous, current: current, now: now)
        XCTAssertEqual(detection.events.count, 1)
        XCTAssertEqual(detection.events.first?.windowClass, .weekly)
        XCTAssertEqual(detection.events.first?.kind, .scheduled)
    }

    func test_providerRollupAndAccount_dedupesToAccount() {
        let previousReset = now.addingTimeInterval(-60)
        let previousRollup = snapshot(used: 80, resetsAt: previousReset, accountID: nil)
        let currentRollup = snapshot(used: 2, resetsAt: now.addingTimeInterval(7.days), accountID: nil)
        let previousAccount = snapshot(used: 80, resetsAt: previousReset, accountID: "acct-1")
        let currentAccount = snapshot(used: 2, resetsAt: now.addingTimeInterval(7.days), accountID: "acct-1")

        var combined = QuotaResetDetection()
        combined.merge(QuotaResetDetector.detect(previous: previousRollup, current: currentRollup, now: now))
        combined.merge(QuotaResetDetector.detect(previous: previousAccount, current: currentAccount, now: now))
        let deduped = QuotaResetDetector.deduplicate(combined.events)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.accountID, "acct-1")
    }

    func test_fourScheduledPerformances_coalesce() {
        let events = ["codex", "claude-code", "cursor", "xai"].enumerated().map { index, token in
            makeScheduledEvent(providerToken: token, offset: TimeInterval(index))
        }
        let performances = QuotaResetDetector.performances(from: events)
        XCTAssertEqual(performances.count, 1)
        if case .coalesced(let grouped) = performances.first {
            XCTAssertEqual(grouped.count, 4)
        } else {
            XCTFail("expected coalesced scheduled performance")
        }
    }

    func test_surpriseDoesNotCoalesceWithScheduled() {
        let surprise = makeEvent(kind: .surprise, providerToken: "codex")
        let scheduled = makeScheduledEvent(providerToken: "claude-code", offset: 0)
        let performances = QuotaResetDetector.performances(from: [surprise, scheduled])
        XCTAssertEqual(performances.count, 2)
        XCTAssertEqual(performances.first?.lead?.kind, .surprise)
    }

    // MARK: - Copy

    func test_codexSurpriseMayMentionTibo_othersNeverDo() {
        let second = QuotaResetCopy.caption(
            kind: .surprise,
            providerToken: "codex",
            providerDisplayName: "Codex",
            windowClass: .weekly,
            accountLabel: nil,
            surpriseCountLastDay: 1,
            lastHeadline: nil,
            seed: "double"
        )
        XCTAssertTrue(second.mentionsTibo)
        XCTAssertTrue(second.headline.contains("twice"))

        for token in ["claude-code", "cursor", "xai"] {
            for seed in ["a", "b", "c", "d", "e", "f"] {
                let caption = QuotaResetCopy.caption(
                    kind: .surprise,
                    providerToken: token,
                    providerDisplayName: token,
                    windowClass: .weekly,
                    accountLabel: nil,
                    surpriseCountLastDay: 1,
                    lastHeadline: nil,
                    seed: seed
                )
                XCTAssertFalse(caption.mentionsTibo, token)
                XCTAssertFalse(caption.headline.lowercased().contains("tibo"), token)
                XCTAssertFalse(caption.eyebrow.lowercased().contains("tibo"), token)
            }
        }
    }

    func test_copyAvoidsRepeatingLastHeadline() {
        let first = QuotaResetCopy.caption(
            kind: .scheduled,
            providerToken: "claude-code",
            providerDisplayName: "Claude Code",
            windowClass: .weekly,
            accountLabel: nil,
            surpriseCountLastDay: 0,
            lastHeadline: nil,
            seed: "seed-1"
        )
        let second = QuotaResetCopy.caption(
            kind: .scheduled,
            providerToken: "claude-code",
            providerDisplayName: "Claude Code",
            windowClass: .weekly,
            accountLabel: nil,
            surpriseCountLastDay: 0,
            lastHeadline: first.headline,
            seed: "seed-1"
        )
        XCTAssertNotEqual(first.headline, second.headline)
    }

    // MARK: - Fixtures

    private func snapshot(
        key: String = "codex-7d",
        label: String = "7-day window",
        window: String = "rollingDays",
        used: Double,
        limit: Double = 100,
        usedPercent: Double? = nil,
        resetsAt: Date,
        confidence: ProviderQuotaConfidence = .high,
        accountID: String? = nil,
        credits: [QuotaResetCredit] = [],
        unit: ProviderQuotaUnit = .percent
    ) -> ProviderQuotaSnapshot {
        let percent = usedPercent ?? used
        let bucket = ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: ProviderQuotaWindowKind(rawValue: window) ?? .custom,
            usedValue: used,
            limitValue: limit,
            remainingValue: max(0, limit - used),
            usedPercent: percent,
            resetsAt: resetsAt,
            unit: unit,
            isEstimated: false
        )
        return ProviderQuotaSnapshot(
            id: "codex_\(accountID ?? "default")",
            provider: AgentProvider.codex.rawValue,
            providerID: AgentProvider.codex.providerID,
            accountID: accountID,
            sourceKind: .officialAPI,
            sourceId: accountID ?? "default",
            fetchedAt: now,
            source: "officialAPI",
            confidence: confidence,
            buckets: [bucket],
            updatedAt: now,
            resetCredits: credits
        )
    }

    private func sessionSnapshot(used: Double, resetsAt: Date) -> ProviderQuotaSnapshot {
        snapshot(
            key: "codex-5h",
            label: "5-hour window",
            window: "rollingHours",
            used: used,
            resetsAt: resetsAt
        )
    }

    private func dualSnapshot(
        sessionUsed: Double,
        weeklyUsed: Double,
        sessionReset: Date,
        weeklyReset: Date
    ) -> ProviderQuotaSnapshot {
        let session = ProviderQuotaBucket(
            key: "codex-5h",
            label: "5-hour window",
            windowKind: .rollingHours,
            usedValue: sessionUsed,
            limitValue: 100,
            remainingValue: 100 - sessionUsed,
            usedPercent: sessionUsed,
            resetsAt: sessionReset,
            unit: .percent,
            isEstimated: false
        )
        let weekly = ProviderQuotaBucket(
            key: "codex-7d",
            label: "7-day window",
            windowKind: .rollingDays,
            usedValue: weeklyUsed,
            limitValue: 100,
            remainingValue: 100 - weeklyUsed,
            usedPercent: weeklyUsed,
            resetsAt: weeklyReset,
            unit: .percent,
            isEstimated: false
        )
        return ProviderQuotaSnapshot(
            id: "codex_default",
            provider: AgentProvider.codex.rawValue,
            providerID: AgentProvider.codex.providerID,
            sourceKind: .officialAPI,
            sourceId: "default",
            fetchedAt: now,
            source: "officialAPI",
            confidence: .high,
            buckets: [session, weekly],
            updatedAt: now
        )
    }

    private func makeScheduledEvent(providerToken: String, offset: TimeInterval) -> QuotaResetEvent {
        makeEvent(kind: .scheduled, providerToken: providerToken, observedAt: now.addingTimeInterval(offset))
    }

    private func makeEvent(
        kind: QuotaResetKind,
        providerToken: String,
        observedAt: Date? = nil
    ) -> QuotaResetEvent {
        QuotaResetEvent(
            providerID: ProviderID(rawValue: providerToken),
            providerToken: providerToken,
            accountID: "default",
            accountLabel: nil,
            bucketKey: "weekly",
            bucketLabel: "7-day window",
            resetBoundary: "\(kind.rawValue)|\(providerToken)|\(observedAt?.timeIntervalSince1970 ?? now.timeIntervalSince1970)",
            kind: kind,
            windowClass: .weekly,
            presentation: .perform,
            freshness: .live,
            previousUsedPercent: 80,
            currentUsedPercent: 2,
            previousLimit: 100,
            currentLimit: 100,
            previousResetsAt: now.addingTimeInterval(-60),
            currentResetsAt: now.addingTimeInterval(7.days),
            credits: [],
            observedAt: observedAt ?? now,
            choreography: .clockStrike,
            captionEyebrow: "RESET",
            captionHeadline: "\(providerToken) reset",
            mentionsTibo: false
        )
    }
}

private extension Int {
    var hours: TimeInterval { TimeInterval(self) * 3_600 }
    var days: TimeInterval { TimeInterval(self) * 86_400 }
}

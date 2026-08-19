import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel

final class TightestQuotaWindowTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func makeBucket(
        key: String = "weekly",
        label: String = "weekly",
        windowKind: ProviderQuotaWindowKind = .weekly,
        usedValue: Double? = nil,
        limitValue: Double? = nil,
        remainingValue: Double? = 50,
        usedPercent: Double? = 50,
        resetsAt: Date? = nil,
        unit: ProviderQuotaUnit = .percent,
        isEstimated: Bool = false
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind,
            usedValue: usedValue,
            limitValue: limitValue,
            remainingValue: remainingValue,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            unit: unit,
            isEstimated: isEstimated
        )
    }

    private func makeSnapshot(
        id: String = "snap-1",
        provider: String = "Claude Code",
        providerID: ProviderID? = ProviderID(rawValue: "claude"),
        accountLabel: String? = nil,
        confidence: ProviderQuotaConfidence = .high,
        buckets: [ProviderQuotaBucket],
        fetchedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            id: id,
            provider: provider,
            providerID: providerID,
            accountID: nil,
            accountLabel: accountLabel,
            accountStorageScope: nil,
            sourceKind: .provider,
            sourceId: "source-1",
            fetchedAt: fetchedAt ?? fixedNow,
            source: "test",
            confidence: confidence,
            managementURL: nil,
            statusMessage: nil,
            buckets: buckets,
            schemaVersion: 2,
            mergedAccountCount: nil,
            updatedAt: updatedAt ?? fixedNow
        )
    }

    // MARK: - Empty / Nil Cases

    func test_emptySnapshotsArray_returnsNil() {
        let winner = TightestQuotaWindow.tightest(across: [], asOf: fixedNow)
        XCTAssertNil(winner)
    }

    func test_noBucketsWithRealPercentage_returnsNil() {
        // A bucket with unit = .tokens and no limitValue has remainingPercent == nil
        let tokenBucket = makeBucket(
            key: "token-pool",
            label: "token pool",
            windowKind: .custom,
            usedValue: 1000,
            limitValue: nil,
            remainingValue: 5000,
            usedPercent: nil,
            unit: .tokens
        )
        let snapshot = makeSnapshot(provider: "Codex", buckets: [tokenBucket])
        let winner = TightestQuotaWindow.tightest(across: [snapshot], asOf: fixedNow)
        XCTAssertNil(winner)
    }

    func test_emptyBucketsArray_returnsNil() {
        let snapshot = makeSnapshot(provider: "Codex", buckets: [])
        let winner = TightestQuotaWindow.tightest(across: [snapshot], asOf: fixedNow)
        XCTAssertNil(winner)
    }

    func test_filteredOutBucketsOnly_returnsNil() {
        // Filtered out keywords: "cache", "hit rate", "local model", "task", etc.
        let cacheBucket = makeBucket(
            key: "cache-hit",
            label: "cache hit rate",
            remainingValue: 80,
            usedPercent: 20
        )
        let snapshot = makeSnapshot(provider: "Codex", buckets: [cacheBucket])
        let winner = TightestQuotaWindow.tightest(across: [snapshot], asOf: fixedNow)
        XCTAssertNil(winner)
    }

    // MARK: - Selection Logic & Winner Properties

    func test_picksLowestRemainingPercentAcrossProviders() {
        let futureReset = fixedNow.addingTimeInterval(3600)
        let snapClaude = makeSnapshot(
            provider: "Claude Code",
            providerID: ProviderID(rawValue: "claude"),
            accountLabel: "Work",
            buckets: [
                makeBucket(label: "5-hour window", remainingValue: 45, usedPercent: 55, resetsAt: futureReset)
            ]
        )
        let snapCodex = makeSnapshot(
            provider: "Codex",
            providerID: ProviderID(rawValue: "codex"),
            accountLabel: "Personal",
            buckets: [
                makeBucket(label: "weekly", remainingValue: 12, usedPercent: 88, resetsAt: futureReset)
            ]
        )
        let snapCursor = makeSnapshot(
            provider: "Cursor",
            providerID: ProviderID(rawValue: "cursor"),
            buckets: [
                makeBucket(label: "fast requests", remainingValue: 60, usedPercent: 40, resetsAt: futureReset)
            ]
        )

        let winner = TightestQuotaWindow.tightest(across: [snapClaude, snapCodex, snapCursor], asOf: fixedNow)

        XCTAssertNotNil(winner)
        XCTAssertEqual(winner?.providerDisplayName, "Codex")
        XCTAssertEqual(winner?.providerID, ProviderID(rawValue: "codex"))
        XCTAssertEqual(winner?.accountLabel, "Personal")
        XCTAssertEqual(winner?.windowLabel, "weekly")
        XCTAssertEqual(winner?.remainingPercent ?? 0, 12, accuracy: 0.0001)
        XCTAssertEqual(winner?.resetsAt, futureReset)
        XCTAssertEqual(winner?.comparedProviderCount, 3)
    }

    // MARK: - Tie-Breaking Logic

    func test_tieOnPercent_breaksToSoonerResetsAt() {
        let resetSoon = fixedNow.addingTimeInterval(1800)
        let resetLater = fixedNow.addingTimeInterval(7200)

        let snapA = makeSnapshot(
            provider: "Provider A",
            buckets: [
                makeBucket(label: "window A", remainingValue: 25, usedPercent: 75, resetsAt: resetLater)
            ]
        )
        let snapB = makeSnapshot(
            provider: "Provider B",
            buckets: [
                makeBucket(label: "window B", remainingValue: 25, usedPercent: 75, resetsAt: resetSoon)
            ]
        )

        let winner = TightestQuotaWindow.tightest(across: [snapA, snapB], asOf: fixedNow)
        XCTAssertEqual(winner?.providerDisplayName, "Provider B")
        XCTAssertEqual(winner?.resetsAt, resetSoon)
    }

    func test_tieOnPercent_knownResetBeatsNilReset() {
        let resetDate = fixedNow.addingTimeInterval(3600)

        let snapNoReset = makeSnapshot(
            provider: "Provider No Reset",
            buckets: [
                makeBucket(label: "pool", remainingValue: 30, usedPercent: 70, resetsAt: nil)
            ]
        )
        let snapWithReset = makeSnapshot(
            provider: "Provider With Reset",
            buckets: [
                makeBucket(label: "window", remainingValue: 30, usedPercent: 70, resetsAt: resetDate)
            ]
        )

        // Case 1: Incumbent has no reset, candidate has reset
        let winner1 = TightestQuotaWindow.tightest(across: [snapNoReset, snapWithReset], asOf: fixedNow)
        XCTAssertEqual(winner1?.providerDisplayName, "Provider With Reset")

        // Case 2: Incumbent has reset, candidate has no reset
        let winner2 = TightestQuotaWindow.tightest(across: [snapWithReset, snapNoReset], asOf: fixedNow)
        XCTAssertEqual(winner2?.providerDisplayName, "Provider With Reset")
    }

    func test_tieOnPercent_identicalResets_incumbentWins() {
        let resetDate = fixedNow.addingTimeInterval(3600)

        let snap1 = makeSnapshot(
            provider: "Provider First",
            buckets: [
                makeBucket(label: "window 1", remainingValue: 30, usedPercent: 70, resetsAt: resetDate)
            ]
        )
        let snap2 = makeSnapshot(
            provider: "Provider Second",
            buckets: [
                makeBucket(label: "window 2", remainingValue: 30, usedPercent: 70, resetsAt: resetDate)
            ]
        )

        let winner = TightestQuotaWindow.tightest(across: [snap1, snap2], asOf: fixedNow)
        XCTAssertEqual(winner?.providerDisplayName, "Provider First")
    }

    func test_tieOnPercent_bothNilResets_incumbentWins() {
        let snap1 = makeSnapshot(
            provider: "Provider First",
            buckets: [
                makeBucket(label: "pool 1", remainingValue: 30, usedPercent: 70, resetsAt: nil)
            ]
        )
        let snap2 = makeSnapshot(
            provider: "Provider Second",
            buckets: [
                makeBucket(label: "pool 2", remainingValue: 30, usedPercent: 70, resetsAt: nil)
            ]
        )

        let winner = TightestQuotaWindow.tightest(across: [snap1, snap2], asOf: fixedNow)
        XCTAssertEqual(winner?.providerDisplayName, "Provider First")
    }

    // MARK: - comparedProviderCount

    func test_comparedProviderCount_countsDistinctProvidersNotBuckets() {
        let futureReset = fixedNow.addingTimeInterval(3600)
        // Provider 1 has two displayable buckets
        let snapClaude = makeSnapshot(
            provider: "Claude Code",
            buckets: [
                makeBucket(key: "5h", label: "5-hour window", remainingValue: 50, usedPercent: 50, resetsAt: futureReset),
                makeBucket(key: "weekly", label: "weekly window", remainingValue: 30, usedPercent: 70, resetsAt: futureReset)
            ]
        )
        // Provider 2 has one displayable bucket
        let snapCodex = makeSnapshot(
            provider: "Codex",
            buckets: [
                makeBucket(key: "monthly", label: "monthly pool", remainingValue: 20, usedPercent: 80, resetsAt: futureReset)
            ]
        )
        // Provider 3 has no displayable buckets with percentage
        let snapEmpty = makeSnapshot(
            provider: "Other",
            buckets: []
        )

        let winner = TightestQuotaWindow.tightest(across: [snapClaude, snapCodex, snapEmpty], asOf: fixedNow)
        XCTAssertEqual(winner?.providerDisplayName, "Codex")
        XCTAssertEqual(winner?.comparedProviderCount, 2, "Must count only the 2 providers that carried real signal")
    }

    // MARK: - isEstimated Derivation

    func test_isEstimated_trueWhenBucketIsEstimated() {
        let futureReset = fixedNow.addingTimeInterval(3600)
        let snap = makeSnapshot(
            confidence: .high,
            buckets: [
                makeBucket(remainingValue: 20, usedPercent: 80, resetsAt: futureReset, isEstimated: true)
            ]
        )
        let winner = TightestQuotaWindow.tightest(across: [snap], asOf: fixedNow)
        XCTAssertEqual(winner?.isEstimated, true)
    }

    func test_isEstimated_trueWhenConfidenceIsLow() {
        let futureReset = fixedNow.addingTimeInterval(3600)
        let snap = makeSnapshot(
            confidence: .low,
            buckets: [
                makeBucket(remainingValue: 20, usedPercent: 80, resetsAt: futureReset, isEstimated: false)
            ]
        )
        let winner = TightestQuotaWindow.tightest(across: [snap], asOf: fixedNow)
        XCTAssertEqual(winner?.isEstimated, true)
    }

    func test_isEstimated_trueWhenConfidenceIsStale() {
        let futureReset = fixedNow.addingTimeInterval(3600)
        let snap = makeSnapshot(
            confidence: .stale,
            buckets: [
                makeBucket(remainingValue: 20, usedPercent: 80, resetsAt: futureReset, isEstimated: false)
            ]
        )
        let winner = TightestQuotaWindow.tightest(across: [snap], asOf: fixedNow)
        XCTAssertEqual(winner?.isEstimated, true)
    }

    func test_isEstimated_falseWhenConfidenceIsHighAndBucketNotEstimated() {
        let futureReset = fixedNow.addingTimeInterval(3600)
        let snap = makeSnapshot(
            confidence: .high,
            buckets: [
                makeBucket(remainingValue: 20, usedPercent: 80, resetsAt: futureReset, isEstimated: false)
            ]
        )
        let winner = TightestQuotaWindow.tightest(across: [snap], asOf: fixedNow)
        XCTAssertEqual(winner?.isEstimated, false)
    }

    func test_isEstimated_falseWhenConfidenceIsMediumAndBucketNotEstimated() {
        let futureReset = fixedNow.addingTimeInterval(3600)
        let snap = makeSnapshot(
            confidence: .medium,
            buckets: [
                makeBucket(remainingValue: 20, usedPercent: 80, resetsAt: futureReset, isEstimated: false)
            ]
        )
        let winner = TightestQuotaWindow.tightest(across: [snap], asOf: fixedNow)
        XCTAssertEqual(winner?.isEstimated, false)
    }

    // MARK: - Pressure Bands

    func test_pressureBands() {
        func window(percent: Double) -> TightestQuotaWindow {
            TightestQuotaWindow(
                providerDisplayName: "Test",
                windowLabel: "test",
                remainingPercent: percent,
                resetsAt: nil,
                isEstimated: false,
                comparedProviderCount: 1
            )
        }

        // Critical: < 15
        XCTAssertEqual(window(percent: 0.0).pressure, .critical)
        XCTAssertEqual(window(percent: 14.9).pressure, .critical)
        XCTAssertEqual(window(percent: 14.99).pressure, .critical)

        // Tightening: 15 ..< 40
        XCTAssertEqual(window(percent: 15.0).pressure, .tightening)
        XCTAssertEqual(window(percent: 25.0).pressure, .tightening)
        XCTAssertEqual(window(percent: 39.9).pressure, .tightening)
        XCTAssertEqual(window(percent: 39.99).pressure, .tightening)

        // Comfortable: >= 40
        XCTAssertEqual(window(percent: 40.0).pressure, .comfortable)
        XCTAssertEqual(window(percent: 40.01).pressure, .comfortable)
        XCTAssertEqual(window(percent: 85.0).pressure, .comfortable)
        XCTAssertEqual(window(percent: 100.0).pressure, .comfortable)
    }

    // MARK: - displayPercent

    func test_displayPercentFloorsRatherThanRounds() {
        func window(percent: Double) -> TightestQuotaWindow {
            TightestQuotaWindow(
                providerDisplayName: "Test",
                windowLabel: "test",
                remainingPercent: percent,
                resetsAt: nil,
                isEstimated: false,
                comparedProviderCount: 1
            )
        }

        XCTAssertEqual(window(percent: 38.6).displayPercent, 38)
        XCTAssertEqual(window(percent: 39.99).displayPercent, 39)
        XCTAssertEqual(window(percent: 0.9).displayPercent, 0)
        XCTAssertEqual(window(percent: 0.0).displayPercent, 0)
        XCTAssertEqual(window(percent: 100.0).displayPercent, 100)
    }

    // MARK: - Direct Initializer & Equatable

    func test_directInitAndEquatable() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let w1 = TightestQuotaWindow(
            providerDisplayName: "Claude Code",
            providerID: ProviderID(rawValue: "claude"),
            accountLabel: "Work",
            windowLabel: "weekly",
            remainingPercent: 35.5,
            resetsAt: date,
            isEstimated: true,
            comparedProviderCount: 2
        )
        let w2 = TightestQuotaWindow(
            providerDisplayName: "Claude Code",
            providerID: ProviderID(rawValue: "claude"),
            accountLabel: "Work",
            windowLabel: "weekly",
            remainingPercent: 35.5,
            resetsAt: date,
            isEstimated: true,
            comparedProviderCount: 2
        )
        let w3 = TightestQuotaWindow(
            providerDisplayName: "Codex",
            providerID: ProviderID(rawValue: "codex"),
            accountLabel: "Personal",
            windowLabel: "weekly",
            remainingPercent: 35.5,
            resetsAt: date,
            isEstimated: true,
            comparedProviderCount: 2
        )

        XCTAssertEqual(w1, w2)
        XCTAssertNotEqual(w1, w3)
        XCTAssertEqual(w1.providerDisplayName, "Claude Code")
        XCTAssertEqual(w1.providerID, ProviderID(rawValue: "claude"))
        XCTAssertEqual(w1.accountLabel, "Work")
        XCTAssertEqual(w1.windowLabel, "weekly")
        XCTAssertEqual(w1.remainingPercent, 35.5)
        XCTAssertEqual(w1.resetsAt, date)
        XCTAssertTrue(w1.isEstimated)
        XCTAssertEqual(w1.comparedProviderCount, 2)
    }
}

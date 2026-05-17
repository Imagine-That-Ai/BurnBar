import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class QuotaWorkspaceViewModelTests: XCTestCase {

    // MARK: makeEntry

    func test_makeEntry_extractsRemainingPercentFromPrimaryBucket() {
        let bucket = ProviderQuotaBucket(
            key: "claude-week",
            label: "Weekly",
            windowKind: .weekly,
            usedValue: 30,
            limitValue: 100,
            remainingValue: 70,
            usedPercent: 30,
            resetsAt: Date().addingTimeInterval(60 * 60),
            unit: .percent,
            isEstimated: false
        )
        let snapshot = ProviderQuotaSnapshot(
            provider: .claudeCode,
            accountID: "team-a",
            accountLabel: "Team A",
            fetchedAt: Date(),
            source: .localCLI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "30% used",
            buckets: [bucket]
        )

        let entry = QuotaWorkspaceViewModel.makeEntry(
            provider: .claudeCode,
            snapshot: snapshot,
            isRefreshing: false
        )

        XCTAssertEqual(entry.remainingPercentRounded, 70)
        XCTAssertEqual(entry.accountLabel, "Team A")
        XCTAssertEqual(entry.providerID, .claudeCode)
    }

    func test_makeEntry_pressureUsesMaxOfDisplayableBuckets() {
        let hourly = ProviderQuotaBucket(
            key: "h",
            label: "5h",
            windowKind: .rollingHours,
            usedValue: 8,
            limitValue: 10,
            remainingValue: 2,
            usedPercent: 80,
            resetsAt: Date().addingTimeInterval(60),
            unit: .percent,
            isEstimated: false
        )
        let weekly = ProviderQuotaBucket(
            key: "w",
            label: "7d",
            windowKind: .weekly,
            usedValue: 20,
            limitValue: 100,
            remainingValue: 80,
            usedPercent: 20,
            resetsAt: Date().addingTimeInterval(60 * 60 * 24),
            unit: .percent,
            isEstimated: false
        )
        let snapshot = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: Date(),
            source: .localCLI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "ok",
            buckets: [weekly, hourly]
        )

        let entry = QuotaWorkspaceViewModel.makeEntry(
            provider: .codex,
            snapshot: snapshot,
            isRefreshing: false
        )

        XCTAssertEqual(entry.pressure, 0.8, accuracy: 0.01)
        XCTAssertEqual(entry.remainingPercentRounded, 20)
    }

    // MARK: sort

    func test_sort_urgencyPutsHighestPressureFirst() {
        let now = Date()
        let lowPressure = makeEntry(provider: .claudeCode, pressure: 0.10, fetchedAt: now)
        let midPressure = makeEntry(provider: .codex, pressure: 0.55, fetchedAt: now)
        let highPressure = makeEntry(provider: .factory, pressure: 0.92, fetchedAt: now)

        let sorted = QuotaWorkspaceViewModel.sort(
            [lowPressure, midPressure, highPressure],
            by: .urgency,
            spendByID: [:]
        )

        XCTAssertEqual(sorted.map(\.provider), [.factory, .codex, .claudeCode])
    }

    func test_sort_alphabeticalIgnoresPressure() {
        let now = Date()
        let factory = makeEntry(provider: .factory, pressure: 0.90, fetchedAt: now)
        let claude = makeEntry(provider: .claudeCode, pressure: 0.10, fetchedAt: now)

        let sorted = QuotaWorkspaceViewModel.sort(
            [factory, claude],
            by: .alphabetical,
            spendByID: [:]
        )

        XCTAssertEqual(sorted.first?.provider, .claudeCode)
    }

    func test_sort_recentlyRefreshedUsesFetchedAt() {
        let older = makeEntry(
            provider: .codex,
            pressure: 0.10,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 100_000)
        )
        let newer = makeEntry(
            provider: .factory,
            pressure: 0.10,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 200_000)
        )

        let sorted = QuotaWorkspaceViewModel.sort(
            [older, newer],
            by: .recentlyRefreshed,
            spendByID: [:]
        )

        XCTAssertEqual(sorted.first?.provider, .factory)
    }

    func test_sort_spendUsesProvidedDictionary() {
        let now = Date()
        let codex = makeEntry(provider: .codex, pressure: 0.50, fetchedAt: now)
        let factory = makeEntry(provider: .factory, pressure: 0.50, fetchedAt: now)

        let sorted = QuotaWorkspaceViewModel.sort(
            [codex, factory],
            by: .spend,
            spendByID: [
                AgentProvider.codex.providerID: 12.50,
                AgentProvider.factory.providerID: 90.00
            ]
        )

        XCTAssertEqual(sorted.first?.provider, .factory)
    }

    // MARK: - Test helpers

    private func makeEntry(
        provider: AgentProvider,
        pressure: Double,
        fetchedAt: Date
    ) -> SubscriptionEntry {
        let usedPercent = pressure * 100
        let bucket = ProviderQuotaBucket(
            key: "main",
            label: "Weekly",
            windowKind: .weekly,
            usedValue: usedPercent,
            limitValue: 100,
            remainingValue: 100 - usedPercent,
            usedPercent: usedPercent,
            resetsAt: nil,
            unit: .percent,
            isEstimated: false
        )
        let snap = ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: fetchedAt,
            source: .localCLI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "ok",
            buckets: [bucket]
        )
        return QuotaWorkspaceViewModel.makeEntry(
            provider: provider,
            snapshot: snap,
            isRefreshing: false
        )
    }
}

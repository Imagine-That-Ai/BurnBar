import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias ProviderQuotaBucket = OpenBurnBar.ProviderQuotaBucket
private typealias ProviderQuotaSnapshot = OpenBurnBar.ProviderQuotaSnapshot

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

    func test_makeEntry_xaiSuperGrokRollingWindowProducesStableEntry() {
        let bucket = ProviderQuotaBucket(
            key: "xai-supergrok-2h-rolling",
            label: "SuperGrok prompts (rolling 2h)",
            windowKind: .rollingHours,
            usedValue: 25,
            limitValue: 100,
            remainingValue: 75,
            usedPercent: 25,
            resetsAt: Date().addingTimeInterval(60 * 60),
            unit: .requests,
            isEstimated: true
        )
        let snapshot = ProviderQuotaSnapshot(
            provider: .xAI,
            providerID: .xAI,
            fetchedAt: Date(),
            source: .localSession,
            confidence: .estimated,
            managementURL: "https://grok.com/plans",
            statusMessage: "SuperGrok rolling window",
            buckets: [bucket]
        )

        let entry = QuotaWorkspaceViewModel.makeEntry(
            provider: .xAI,
            snapshot: snapshot,
            isRefreshing: false
        )

        XCTAssertEqual(entry.provider, .xAI)
        XCTAssertEqual(entry.providerID, .xAI)
        XCTAssertEqual(entry.remainingPercentRounded, 75)
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

    func test_makeEntry_keepsProviderVisibleWithoutDisplayableBuckets() {
        let snapshot = ProviderQuotaSnapshot(
            provider: .claudeCode,
            accountID: "claude-work",
            accountLabel: "Claude Work",
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: "Bridge installed but no rate-limit payload captured yet.",
            buckets: []
        )

        let entry = QuotaWorkspaceViewModel.makeEntry(
            provider: .claudeCode,
            snapshot: snapshot,
            isRefreshing: false
        )

        XCTAssertEqual(entry.accountLabel, "Claude Work")
        XCTAssertTrue(entry.allDisplayableBuckets.isEmpty)
        XCTAssertEqual(entry.primaryBucket.label, "Bridge installed but no rate-limit payload captured yet.")
        XCTAssertNil(entry.primaryDisplayableBucket)
        XCTAssertEqual(entry.remainingPercentText, "—")
    }

    func test_rebuild_prefersAccountSnapshotOverProviderRollupWhenAccountHasNoSignal() throws {
        let appSupportRoot = try makeTemporaryDirectory()
        let home = try makeTemporaryDirectory()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot)
        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: .default)
        let staleRollup = ProviderQuotaSnapshot(
            provider: .claudeCode,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 100),
            source: .localCLI,
            confidence: .estimated,
            managementURL: nil,
            statusMessage: "Stale last known Claude Code quota from the local status line JSON bridge.",
            buckets: [
                ProviderQuotaBucket(
                    key: "claude-five_hour",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 8,
                    limitValue: 100,
                    remainingValue: 92,
                    usedPercent: 8,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: true
                )
            ]
        )
        let emptyAccount = ProviderQuotaSnapshot(
            provider: .claudeCode,
            accountID: "claude-work",
            accountLabel: "Claude Work",
            fetchedAt: Date(timeIntervalSinceReferenceDate: 200),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: "Bridge installed but no rate-limit payload captured yet.",
            buckets: []
        )
        store.persistSnapshots(
            [.claudeCode: staleRollup],
            accountSnapshots: [ProviderQuotaSnapshotStore.accountSnapshotKey(emptyAccount): emptyAccount]
        )

        let service = ProviderQuotaService(
            keyStore: makeKeyStore(),
            providerRuntimeKeyStore: makeRuntimeKeyStore(),
            appPaths: appPaths,
            environment: [:],
            homeDirectoryURL: home,
            refreshProviders: [.claudeCode]
        )
        let viewModel = QuotaWorkspaceViewModel()

        viewModel.rebuild(
            quotaService: service,
            dataStore: try makeDataStore(),
            providerSpendByID: [:]
        )

        XCTAssertEqual(viewModel.entries.count, 1)
        XCTAssertEqual(viewModel.entries.first?.snapshot.accountID, "claude-work")
        XCTAssertNil(viewModel.entries.first?.hourlyBucket)
        XCTAssertEqual(viewModel.entries.first?.allDisplayableBuckets.count, 0)
        XCTAssertEqual(viewModel.entries.first?.remainingPercentText, "—")
    }

    func test_rebuild_showsDefaultCLILoginAlongsideIsolatedProfiles() throws {
        let appSupportRoot = try makeTemporaryDirectory()
        let home = try makeTemporaryDirectory()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot)
        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: .default)
        let current = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 300),
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Current Codex quota.",
            buckets: [
                ProviderQuotaBucket(
                    key: "codex-current-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 3,
                    limitValue: 100,
                    remainingValue: 97,
                    usedPercent: 3,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                )
            ]
        )
        let isolated = ProviderQuotaSnapshot(
            provider: .codex,
            accountID: "profile-reserve",
            accountLabel: "Reserve Codex",
            accountStorageScope: .localOnly,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 400),
            source: .officialAPI,
            sourceId: "switcher-cli:codex:profile-reserve",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Reserve Codex quota.",
            buckets: [
                ProviderQuotaBucket(
                    key: "codex-reserve-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 25,
                    limitValue: 100,
                    remainingValue: 75,
                    usedPercent: 25,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                )
            ]
        )
        store.persistSnapshots(
            [.codex: current],
            accountSnapshots: [ProviderQuotaSnapshotStore.accountSnapshotKey(isolated): isolated]
        )

        let service = ProviderQuotaService(
            keyStore: makeKeyStore(),
            providerRuntimeKeyStore: makeRuntimeKeyStore(),
            appPaths: appPaths,
            environment: [:],
            homeDirectoryURL: home,
            refreshProviders: [.codex]
        )
        let viewModel = QuotaWorkspaceViewModel()

        viewModel.rebuild(
            quotaService: service,
            dataStore: try makeDataStore(),
            providerSpendByID: [:]
        )

        let codexEntries = viewModel.entries.filter { $0.provider == .codex }
        XCTAssertEqual(codexEntries.count, 2)
        XCTAssertEqual(Set(codexEntries.compactMap { $0.snapshot.accountID }), ["current-codex", "profile-reserve"])
    }

    func test_rebuild_keepsPendingAccountVisibleAlongsideDisplayableAccounts() throws {
        let appSupportRoot = try makeTemporaryDirectory()
        let home = try makeTemporaryDirectory()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot)
        let store = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: .default)
        let active = ProviderQuotaSnapshot(
            provider: .codex,
            accountID: "profile-active",
            accountLabel: "Active Codex",
            accountStorageScope: .localOnly,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 400),
            source: .officialAPI,
            sourceId: "switcher-cli:codex:profile-active",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Active Codex quota.",
            buckets: [
                ProviderQuotaBucket(
                    key: "codex-active-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 12,
                    limitValue: 100,
                    remainingValue: 88,
                    usedPercent: 12,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                )
            ]
        )
        let pending = ProviderQuotaSnapshot(
            provider: .codex,
            accountID: "profile-pending",
            accountLabel: "Pending Codex",
            accountStorageScope: .localOnly,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 410),
            source: .unavailable,
            sourceId: "switcher-cli:codex:profile-pending",
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: "Quota probe pending.",
            buckets: []
        )
        store.persistSnapshots(
            [:],
            accountSnapshots: [
                ProviderQuotaSnapshotStore.accountSnapshotKey(active): active,
                ProviderQuotaSnapshotStore.accountSnapshotKey(pending): pending
            ]
        )

        let service = ProviderQuotaService(
            keyStore: makeKeyStore(),
            providerRuntimeKeyStore: makeRuntimeKeyStore(),
            appPaths: appPaths,
            environment: [:],
            homeDirectoryURL: home,
            refreshProviders: [.codex]
        )
        let viewModel = QuotaWorkspaceViewModel()

        viewModel.rebuild(
            quotaService: service,
            dataStore: try makeDataStore(),
            providerSpendByID: [:]
        )

        let codexEntries = viewModel.entries.filter { $0.provider == .codex }
        XCTAssertEqual(codexEntries.count, 2)
        let pendingEntry = try XCTUnwrap(codexEntries.first { $0.snapshot.accountID == "profile-pending" })
        XCTAssertEqual(pendingEntry.allDisplayableBuckets.count, 0)
        XCTAssertEqual(pendingEntry.remainingPercentText, "—")
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaWorkspaceViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeKeyStore() -> ProviderAPIKeyStore {
        ProviderAPIKeyStore(
            keychain: KeychainStore(service: "quota-workspace-tests.\(UUID().uuidString)", legacyServices: [], backend: TestKeychainBackend())
        )
    }

    private func makeRuntimeKeyStore() -> KeychainStore {
        KeychainStore(service: "quota-workspace-runtime-tests.\(UUID().uuidString)", legacyServices: [], backend: TestKeychainBackend())
    }
}

private final class TestKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

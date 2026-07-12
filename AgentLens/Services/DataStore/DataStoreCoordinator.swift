import Foundation
import GRDB
import Observation
import OpenBurnBarCore

// MARK: - DataStoreCoordinator
//
// DataStoreActor (actor) is in DataStore.swift to avoid a circular dependency.
// This class is the @MainActor @Observable facade that forwards all async calls
// to the actor. It also owns the usage view model.
//
// Previously this class was named DataStore. It was extracted to its own file
// to eliminate the monolithic DataStore.swift. All code that imports DataStore
// should continue to work via the typealias in DataStore.swift.
// TODO(1.0): Remove the DataStore typealias and update all import sites.

@Observable
@MainActor
final class DataStoreCoordinator {
    static let legacyChatThreadID = OpenBurnBarDatabase.legacyChatThreadID
    private static let quickHydrationLimit = 5_000

    private struct DatabaseOpenResult {
        let pool: DatabasePool
        let migrationBackupConfigurationBuilder: OpenBurnBarDatabase.MigrationBackupConfigurationBuilder?
    }

    nonisolated let actor: DataStoreActor

    nonisolated var switcherStore: SwitcherProfileStore { actor.switcherStore }

    /// Presentation-layer view model for dashboard aggregate metrics.
    /// Rebuilt automatically whenever usages change.
    let usageViewModel = DashboardUsageViewModel()

    private(set) var usages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?
    /// Monotonically increasing counter bumped once per CONTENT-CHANGING
    /// write to `usages`. Views that derive aggregations from the usage
    /// array should `.onChange(of: dataStore.usagesVersion)` instead of
    /// observing the `[TokenUsage]` array directly — observing the array
    /// re-evaluates the view body whenever any element comparison wiggles,
    /// while observing the `Int` re-evaluates exactly once per refresh.
    /// Wraparound is intentional (`&+= 1`); SwiftUI only cares about
    /// inequality between successive values.
    ///
    /// A replacement whose rows are byte-identical to the applied set skips
    /// the bump entirely (no sort, no aggregate rebuild) until the next
    /// time-window boundary — see `UsageReplaceGate` and
    /// `docs/architecture/macos-performance.md` §2/§14.
    private(set) var usagesVersion: Int = 0
    private var refreshGeneration = 0
    #if DEBUG
    var debugRefreshGenerationForTesting: Int { refreshGeneration }
    #endif
    private var lastAppliedFingerprint: UsageContentFingerprint?
    private var nextWindowBoundary: Date = .distantPast
    /// Injectable clock so boundary-crossing behavior is unit-testable.
    @ObservationIgnored var nowProvider: () -> Date = Date.init

    // MARK: - Forwarding Computed Properties (deprecated — use usageViewModel)

    /// Use `usageViewModel.moodBand` instead.
    var moodBand: MoodBand { usageViewModel.moodBand }

    /// Use `usageViewModel.moodLabel` instead.
    var moodLabel: String { usageViewModel.moodLabel }

    /// Use `usageViewModel.totalCostToday` instead.
    var totalCostToday: Double { usageViewModel.totalCostToday }

    /// Use `usageViewModel.totalCostThisWeek` instead.
    var totalCostThisWeek: Double { usageViewModel.totalCostThisWeek }

    /// Use `usageViewModel.totalCostThisMonth` instead.
    var totalCostThisMonth: Double { usageViewModel.totalCostThisMonth }

    /// Use `usageViewModel.totalCostAllTime` instead.
    var totalCostAllTime: Double { usageViewModel.totalCostAllTime }

    /// Use `usageViewModel.totalTokensToday` instead.
    var totalTokensToday: Int { usageViewModel.totalTokensToday }

    /// Use `usageViewModel.totalTokensThisWeek` instead.
    var totalTokensThisWeek: Int { usageViewModel.totalTokensThisWeek }

    /// Use `usageViewModel.totalTokensThisMonth` instead.
    var totalTokensThisMonth: Int { usageViewModel.totalTokensThisMonth }

    /// Use `usageViewModel.totalTokensAllTime` instead.
    var totalTokensAllTime: Int { usageViewModel.totalTokensAllTime }

    /// Use `usageViewModel.last7DayCosts` instead.
    var last7DayCosts: [Double] { usageViewModel.last7DayCosts }

    /// Use `usageViewModel.last7DayTokenTotals` instead.
    var last7DayTokenTotals: [Int] { usageViewModel.last7DayTokenTotals }

    /// Use `usageViewModel.rollingDailyAverage` instead.
    var rollingDailyAverage: Double { usageViewModel.rollingDailyAverage }

    /// Use `usageViewModel.providerSummaries` instead.
    var providerSummaries: [ProviderSummary] { usageViewModel.providerSummaries }

    /// Use `usageViewModel.hasEstimatedProviders` instead.
    var hasEstimatedProviders: Bool { usageViewModel.hasEstimatedProviders }

    /// Use `usageViewModel.modelSummaries` instead.
    var modelSummaries: [ModelSummary] { usageViewModel.modelSummaries }

    func providerSummaries(in dateRange: ClosedRange<Date>?) -> [ProviderSummary] {
        usageViewModel.providerSummaries(in: dateRange)
    }

    func providerSummaries(for timeRange: TimeRange) -> [ProviderSummary] {
        usageViewModel.providerSummaries(for: timeRange)
    }

    func modelSummaries(in dateRange: ClosedRange<Date>?) -> [ModelSummary] {
        usageViewModel.modelSummaries(in: dateRange)
    }

    func modelSummaries(for timeRange: TimeRange) -> [ModelSummary] {
        usageViewModel.modelSummaries(for: timeRange)
    }

    func cacheEfficiency(in dateRange: ClosedRange<Date>?) -> CacheEfficiency {
        usageViewModel.cacheEfficiency(in: dateRange)
    }

    func cacheEfficiency(for timeRange: TimeRange) -> CacheEfficiency {
        usageViewModel.cacheEfficiency(for: timeRange)
    }

    func usageWindowSummary(in dateRange: ClosedRange<Date>?) -> DashboardUsageWindowSummary {
        usageViewModel.windowSummary(in: dateRange)
    }

    func usageWindowSummary(for timeRange: TimeRange) -> DashboardUsageWindowSummary {
        usageViewModel.windowSummary(for: timeRange)
    }

    var totalUsageSessionCount: Int {
        usageViewModel.windowSummary(for: .allTime).sessionCount
    }

    func usages(in dateRange: ClosedRange<Date>?) -> [TokenUsage] {
        usageViewModel.usages(in: dateRange)
    }

    func usages(forModel normalizedName: String) -> [TokenUsage] {
        usageViewModel.usages(forModel: normalizedName)
    }

    func usages(forModel normalizedName: String, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usageViewModel.usages(forModel: normalizedName, in: dateRange)
    }

    var dailySummaries: [DailyUsageSummary] {
        usageViewModel.dailySummaries
    }

    func usages(for provider: AgentProvider) -> [TokenUsage] {
        usageViewModel.usages(for: provider)
    }

    func usages(for provider: AgentProvider, in dateRange: ClosedRange<Date>) -> [TokenUsage] {
        usageViewModel.usages(for: provider, in: dateRange)
    }

    func topProviderToday() -> (provider: AgentProvider, cost: Double)? {
        usageViewModel.topProviderToday()
    }

    // MARK: - Initialization

    /// Creates the database pool. Reads `databaseEncryptionEnabled` directly from
    /// UserDefaults so this can be called before SettingsManager is initialized.
    /// Enables WAL mode for better read concurrency and write performance.
    ///
    /// Encryption-at-rest is default-ON for new installs (B-DATA-1): when the key
    /// has no persisted value we treat it as enabled. Existing installs keep their
    /// stored value.
    ///
    /// **Fail-closed invariant.** When encryption is enabled, this method never
    /// opens the store plaintext. If the build is missing SQLCipher or Keychain
    /// persistence fails, startup fails with a typed error. If the current
    /// database is a legacy plaintext SQLite file, the verified SQLCipher export
    /// migration runs before the encrypted pool opens; migration failure aborts
    /// startup instead of silently violating the data-at-rest contract.
    private static func makeDatabaseOpenResult(path: String) throws -> DatabaseOpenResult {
        let defaults = UserDefaults.standard
        // Default-on for new installs: only treat as disabled when explicitly stored false.
        let encryptionEnabled = (defaults.object(forKey: "databaseEncryptionEnabled") as? Bool) ?? true

        guard encryptionEnabled else {
            var config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
            installStartupPragmas(on: &config)
            installDebugQueryTracer(on: &config)
            return DatabaseOpenResult(
                pool: try openDatabasePool(path: path, configuration: config),
                migrationBackupConfigurationBuilder: nil
            )
        }

        guard DatabaseEncryptionService.isCipherAvailable() else {
            AppLogger.dataStore.error(
                "encryption_unavailable_codec_absent",
                metadata: [
                    "reason": "SQLCipher codec not linked (PRAGMA cipher_version empty); refusing plaintext fallback",
                    "path": path
                ]
            )
            throw DatabaseEncryptionError.cipherUnavailable
        }

        let encryptionKey = try DatabaseEncryptionService.getOrCreatePersistedKey()
        let fileExists = FileManager.default.fileExists(atPath: path)
        if fileExists, DatabaseEncryptionService.isEncryptedDatabaseFile(at: path) == false {
            let migrated: Bool
            do {
                migrated = try DatabaseEncryptionService.migratePlaintextDatabaseIfNeeded(
                    at: path,
                    encryptionKey: encryptionKey
                )
            } catch {
                guard DatabaseEncryptionService.isMissingSQLiteSidecarRemoval(error),
                      DatabaseEncryptionService.isEncryptedDatabaseFile(at: path)
                else {
                    throw error
                }
                DatabaseEncryptionService.removeSQLiteSidecarsIfPresent(at: path)
                migrated = true
            }
            AppLogger.dataStore.notice(
                "encryption_migrated_existing_plaintext_db",
                metadata: ["path": path, "migrated": "\(migrated)"]
            )
        }
        var config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: encryptionKey)
        installStartupPragmas(on: &config)
        installDebugQueryTracer(on: &config)
        return DatabaseOpenResult(
            pool: try openDatabasePool(path: path, configuration: config),
            migrationBackupConfigurationBuilder: {
                try DatabaseEncryptionService.makeConfiguration(encryptionKey: encryptionKey)
            }
        )
    }

    private static func makeDatabasePool(path: String) throws -> DatabasePool {
        try makeDatabaseOpenResult(path: path).pool
    }

    private static func openDatabasePool(path: String, configuration: Configuration) throws -> DatabasePool {
        var lastSidecarError: Error?
        for attempt in 1...3 {
            do {
                return try openAndValidateDatabasePool(path: path, configuration: configuration)
            } catch {
                guard DatabaseEncryptionService.isMissingSQLiteSidecarRemoval(error) else { throw error }
                lastSidecarError = error
                AppLogger.dataStore.notice(
                    "database_pool_open_retry_after_missing_sidecar",
                    metadata: ["path": path, "attempt": "\(attempt)", "error": "\(error)"]
                )
                DatabaseEncryptionService.removeSQLiteSidecarsIfPresent(at: path)
            }
        }

        if let lastSidecarError {
            AppLogger.dataStore.notice(
                "database_pool_open_failed_after_sidecar_retries",
                metadata: ["path": path, "error": "\(lastSidecarError)"]
            )
            throw lastSidecarError
        }
        return try openAndValidateDatabasePool(path: path, configuration: configuration)
    }

    private static func openAndValidateDatabasePool(path: String, configuration: Configuration) throws -> DatabasePool {
        let pool = try DatabasePool(path: path, configuration: configuration)
        do {
            _ = try pool.read { @Sendable db in
                try Int.fetchOne(db, sql: "PRAGMA user_version")
            }
            return pool
        } catch {
            do {
                try pool.close()
            } catch {
                AppLogger.dataStore.debug(
                    "database_pool_validation_close_failed",
                    metadata: ["path": path, "error": "\(error)"]
                )
            }
            throw error
        }
    }

    /// Legacy UserDefaults key retained so older settings/recovery UI can clear
    /// stale disclosed-plaintext state. New encryption-enabled startup rejects
    /// plaintext fallback when SQLCipher is unavailable.
    static let plaintextFallbackAcknowledgedDefaultsKey = "databaseEncryptionPlaintextFallbackAcknowledged"

    #if DEBUG
    static func makeDatabasePoolForTesting(path: String) throws -> DatabasePool {
        try makeDatabasePool(path: path)
    }

    static func makeInMemoryForTesting(
        runMigrations: Bool = true,
        refreshOnInit: Bool = false
    ) throws -> DataStoreCoordinator {
        let queue = try DatabaseQueue()
        return try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: runMigrations,
            refreshOnInit: refreshOnInit
        )
    }
    #endif

    /// Open-time WAL mode configuration (idempotent).
    /// WAL is automatically enabled by GRDB's DatabasePool, but we explicitly
    /// tune the checkpoint threshold and synchronous mode for our workload.
    /// This hook runs after SQLCipher keying and before DEBUG tracing so
    /// startup PRAGMAs do not require post-open synchronous queue writes.
    private static func installStartupPragmas(on config: inout Configuration) {
        config.prepareDatabase { @Sendable db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
    }

    /// DEBUG-only N+1 detection (`OpenBurnBarQueryTracer`). Must run AFTER
    /// `makeConfiguration`: GRDB chains `prepareDatabase` closures in install
    /// order, so the SQLCipher passphrase setup executes before the trace hook
    /// registers and the cipher key never reaches the trace log.
    private static func installDebugQueryTracer(on config: inout Configuration) {
        #if DEBUG
        OpenBurnBarQueryTracer.shared.configure(in: &config)
        #endif
    }

    convenience init() throws {
        let appDir = try OpenBurnBarCore.OpenBurnBarMigration.prepareSupportDirectory()
        let dbPath = appDir.appendingPathComponent(OpenBurnBarCore.OpenBurnBarIdentity.databaseFileName).path
        // DatabasePool enables concurrent reads (WAL mode) for read-heavy workloads
        // like dashboard aggregation and search queries. Writes remain serialized.
        let openResult = try Self.makeDatabaseOpenResult(path: dbPath)
        try OpenBurnBarDatabase.configureWALMode(openResult.pool)
        try self.init(
            databaseQueue: openResult.pool,
            migrationBackupConfigurationBuilder: openResult.migrationBackupConfigurationBuilder
        )
    }

    init(
        databaseQueue: any DatabaseWriter,
        runMigrations: Bool = true,
        refreshOnInit: Bool = true,
        migrationBackupConfigurationBuilder: OpenBurnBarDatabase.MigrationBackupConfigurationBuilder? = nil
    ) throws {
        let actor = try DataStoreActor(
            databaseQueue: databaseQueue,
            runMigrations: runMigrations,
            migrationBackupConfigurationBuilder: migrationBackupConfigurationBuilder
        )
        self.actor = actor

        // Callers that disable migrations often provide fixture schemas, or no
        // schema at all. Auto-refresh would race those fixtures and query
        // production tables that intentionally do not exist there.
        if refreshOnInit, runMigrations {
            Task { await refresh() }
        }
    }

    // MARK: - Cache Refresh

    func replaceUsages(_ newUsages: [TokenUsage]) {
        guard applyGateAdmits(newUsages) else { return }
        let sortedUsages = newUsages.sorted { $0.startTime > $1.startTime }
        usages = sortedUsages
        usageViewModel.replaceUsages(sortedUsages)
        lastRefresh = nowProvider()
        usagesVersion &+= 1
    }

    func replaceUsageSnapshot(_ snapshot: DashboardUsageSnapshot) {
        guard applyGateAdmits(snapshot.loadedUsages) else { return }
        let sortedUsages = snapshot.loadedUsages.sorted { $0.startTime > $1.startTime }
        usages = sortedUsages
        usageViewModel.replaceUsageSnapshot(snapshot)
        lastRefresh = nowProvider()
        usagesVersion &+= 1
    }

    /// No-change short-circuit shared by BOTH replace paths (the periodic
    /// cadence tick lands in `replaceUsages` via the billing reconcile's
    /// `fetchAllUsage`, while init/deleteAll land in
    /// `replaceUsageSnapshot`). A content-identical replacement before the
    /// next time-window boundary only refreshes `lastRefresh`; everything
    /// downstream (sorts, aggregate caches, `usagesVersion` consumers) is
    /// mathematically unchanged, so pixels cannot differ. Crossing a
    /// boundary (midnight / rolling-window decay) forces the apply because
    /// the bump is load-bearing for "Today" resets and 7d/30d decay.
    private func applyGateAdmits(_ rows: [TokenUsage]) -> Bool {
        let now = nowProvider()
        let fingerprint = UsageContentFingerprint(rows: rows)
        if fingerprint == lastAppliedFingerprint, now < nextWindowBoundary {
            lastRefresh = now
            return false
        }
        lastAppliedFingerprint = fingerprint
        nextWindowBoundary = UsageReplaceGate.nextWindowBoundary(rows: rows, after: now)
        return true
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }

        do {
            let snapshot = try await actor.fetchDashboardUsageSnapshot(loadedUsageLimit: Self.quickHydrationLimit)
            guard generation == refreshGeneration else { return }
            replaceUsageSnapshot(snapshot)
        } catch {
            AppLogger.dataStore.silentFailure("refresh_failed", error: error)
        }
    }

    func deleteAll() async throws {
        try await actor.deleteAllUsageRows()
        await refresh()
    }
}

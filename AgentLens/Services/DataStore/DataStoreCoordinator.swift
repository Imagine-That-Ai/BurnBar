import Foundation
import GRDB
import SwiftUI
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
    nonisolated static let legacyChatThreadID = "openburnbar-chat-legacy"
    private static let quickHydrationLimit = 5_000

    nonisolated let actor: DataStoreActor

    nonisolated var dbQueue: any DatabaseWriter { actor.dbQueue }
    nonisolated var database: OpenBurnBarDatabase { actor.database }
    nonisolated var usageStore: UsageStore { actor.usageStore }
    nonisolated var conversationStore: ConversationStore { actor.conversationStore }
    nonisolated var searchIndexStore: SearchIndexStore { actor.searchIndexStore }
    nonisolated var artifactStore: ArtifactStore { actor.artifactStore }
    nonisolated var projectionStore: ProjectionStore { actor.projectionStore }
    nonisolated var controlPlaneStore: ControlPlaneStore { actor.controlPlaneStore }
    nonisolated var deviceStore: DeviceStore { actor.deviceStore }
    nonisolated var checkpointStore: ParserCheckpointStore { actor.checkpointStore }
    nonisolated var remoteSyncWatermarkStore: RemoteSyncWatermarkStore { actor.remoteSyncWatermarkStore }
    nonisolated var switcherStore: SwitcherProfileStore { actor.switcherStore }
    nonisolated var backfillCursorStore: BackfillCursorStore { actor.backfillCursorStore }
    nonisolated var providerAccountStore: ProviderAccountStore { actor.providerAccountStore }
    nonisolated var textExpansionSnippetStore: TextExpansionSnippetStore { actor.textExpansionSnippetStore }

    /// Presentation-layer view model for dashboard aggregate metrics.
    /// Rebuilt automatically whenever usages change.
    let usageViewModel = DashboardUsageViewModel()

    private(set) var usages: [TokenUsage] = []
    private(set) var isLoading = false
    private(set) var lastRefresh: Date?
    /// Monotonically increasing counter bumped once per mutating write to
    /// `usages`. Views that derive aggregations from the usage array should
    /// `.onChange(of: dataStore.usagesVersion)` instead of observing the
    /// `[TokenUsage]` array directly — observing the array re-evaluates the
    /// view body whenever any element comparison wiggles, while observing the
    /// `Int` re-evaluates exactly once per refresh. Wraparound is intentional
    /// (`&+= 1`); SwiftUI only cares about inequality between successive
    /// values.
    ///
    /// See `docs/architecture/macos-performance.md` for the migration guide.
    private(set) var usagesVersion: Int = 0
    private var refreshGeneration = 0

    // MARK: - Forwarding Computed Properties (deprecated — use usageViewModel)

    /// Use `usageViewModel.moodBand` instead.
    var moodBand: MoodBand { usageViewModel.moodBand }

    /// Use `usageViewModel.moodLabel` instead.
    var moodLabel: String { usageViewModel.moodLabel }

    /// Use `usageViewModel.moodColor` instead.
    var moodColor: Color { usageViewModel.moodColor }

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

    /// Persisted escape-hatch key (mirrors `IndexSettings.plaintextDatabaseAcknowledged`).
    /// Read directly from `UserDefaults.standard` because this open path runs
    /// before `SettingsManager` exists.
    private static let plaintextAcknowledgedDefaultsKey = "plaintextDatabaseAcknowledged"

    /// Creates the database pool. Reads `databaseEncryptionEnabled` directly from
    /// UserDefaults so this can be called before SettingsManager is initialized.
    /// Enables WAL mode for better read concurrency and write performance.
    ///
    /// Encryption-at-rest is default-ON for new installs (B-DATA-1): when the key
    /// has no persisted value we treat it as enabled. Existing installs keep their
    /// stored value.
    ///
    /// **No-brick safety.** Every existing install holds a PLAINTEXT database
    /// (encryption was dead code until B-DATA-1), and the daemon shares this same
    /// file with no key. Two failure modes are handled without ever bricking data:
    ///
    ///   1. **SQLCipher genuinely unavailable in this build.** `makeConfiguration`
    ///      hard-fails via its `PRAGMA cipher_version` self-check
    ///      (`DatabaseEncryptionError.cipherUnavailable`). We then fall back to a
    ///      plaintext pool and record the acknowledged-plaintext escape hatch so the
    ///      app keeps running (with a standing banner) instead of crashing.
    ///   2. **Existing plaintext file + encryption now on.** Applying a cipher key
    ///      to a plaintext file fails to open it (`SQLITE error 26`). A safe in-place
    ///      `sqlcipher_export` migration cannot be implemented or PROVEN against the
    ///      current SPM build (the resolved `GRDB-SQLCipher` product links system
    ///      SQLite with no `SQLITE_HAS_CODEC`, so `usePassphrase`/`sqlcipher_export`
    ///      are unavailable). Per the no-brick rule we therefore do NOT force-encrypt
    ///      existing plaintext DBs: we open them plaintext under the same escape
    ///      hatch and leave the migration as a TODO for the SQLCipher-linked build.
    ///
    /// TODO(B-DATA-1): once the build links a real SQLCipher (PRAGMA cipher_version
    /// non-empty), implement the pre-migration-backup + `sqlcipher_export` encrypt
    /// step here and drop the plaintext fallback for the "existing plaintext file"
    /// case. Reuse `OpenBurnBarDatabase`'s backup machinery before exporting.
    private static func makeDatabasePool(path: String) throws -> DatabasePool {
        let defaults = UserDefaults.standard
        // Default-on for new installs: only treat as disabled when explicitly stored false.
        let encryptionEnabled = (defaults.object(forKey: "databaseEncryptionEnabled") as? Bool) ?? true

        guard encryptionEnabled else {
            var config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
            installDebugQueryTracer(on: &config)
            return try DatabasePool(path: path, configuration: config)
        }

        // Existing plaintext DB + encryption now on: cannot safely encrypt-migrate
        // in this build, so fall back to plaintext under the acknowledged escape
        // hatch rather than fail to open the user's data.
        let fileExists = FileManager.default.fileExists(atPath: path)
        if fileExists, DatabaseEncryptionService.isEncryptedDatabaseFile(at: path) == false {
            AppLogger.dataStore.error(
                "encryption_skipped_existing_plaintext_db",
                metadata: [
                    "reason": "Existing plaintext database; safe encrypt-migration unavailable in this build",
                    "path": path
                ]
            )
            return try openPlaintextWithEscapeHatch(path: path, defaults: defaults)
        }

        let encryptionKey = DatabaseEncryptionService.getOrCreateKey()
        do {
            var config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: encryptionKey)
            installDebugQueryTracer(on: &config)
            return try DatabasePool(path: path, configuration: config)
        } catch is DatabaseEncryptionError {
            // SQLCipher not active in this build. Hard-failing the whole app is the
            // one unacceptable outcome, so proceed in plaintext under the explicit
            // acknowledged escape hatch + standing banner.
            AppLogger.dataStore.error(
                "encryption_unavailable_falling_back_plaintext",
                metadata: ["reason": "SQLCipher inactive (PRAGMA cipher_version empty)", "path": path]
            )
            return try openPlaintextWithEscapeHatch(path: path, defaults: defaults)
        }
    }

    /// Opens the database in plaintext and persists the acknowledged-plaintext
    /// escape hatch so the UI can surface a standing "data is not encrypted" banner.
    private static func openPlaintextWithEscapeHatch(
        path: String,
        defaults: UserDefaults
    ) throws -> DatabasePool {
        defaults.set(true, forKey: plaintextAcknowledgedDefaultsKey)
        var config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
        installDebugQueryTracer(on: &config)
        return try DatabasePool(path: path, configuration: config)
    }

    /// DEBUG-only N+1 detection (`OpenBurnBarQueryTracer`). Must run AFTER
    /// `makeConfiguration`: GRDB chains `prepareDatabase` closures in install
    /// order, so the SQLCipher `PRAGMA key` executes before the trace hook
    /// registers and the cipher key never reaches the trace log.
    private static func installDebugQueryTracer(on config: inout Configuration) {
        #if DEBUG
        OpenBurnBarQueryTracer.shared.configure(in: &config)
        #endif
    }

    /// Post-open WAL mode configuration (idempotent).
    /// WAL is automatically enabled by GRDB's DatabasePool, but we explicitly
    /// tune the checkpoint threshold for our workload.
    private static func configureWALMode(_ dbQueue: any DatabaseWriter) throws {
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
        }
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
    }

    convenience init() throws {
        let appDir = try OpenBurnBarMigration.prepareSupportDirectory()
        let dbPath = appDir.appendingPathComponent(OpenBurnBarIdentity.databaseFileName).path
        // DatabasePool enables concurrent reads (WAL mode) for read-heavy workloads
        // like dashboard aggregation and search queries. Writes remain serialized.
        let pool = try Self.makeDatabasePool(path: dbPath)
        try Self.configureWALMode(pool)
        try self.init(databaseQueue: pool)
    }

    init(
        databaseQueue: any DatabaseWriter,
        runMigrations: Bool = true,
        refreshOnInit: Bool = true
    ) throws {
        let actor = try DataStoreActor(databaseQueue: databaseQueue, runMigrations: runMigrations)
        self.actor = actor

        if refreshOnInit {
            Task { await refresh() }
        }
    }

    // MARK: - Cache Refresh

    func replaceUsages(_ newUsages: [TokenUsage]) {
        let sortedUsages = newUsages.sorted { $0.startTime > $1.startTime }
        usages = sortedUsages
        usageViewModel.replaceUsages(sortedUsages)
        lastRefresh = Date()
        usagesVersion &+= 1
    }

    func replaceUsageSnapshot(_ snapshot: DashboardUsageSnapshot) {
        let sortedUsages = snapshot.loadedUsages.sorted { $0.startTime > $1.startTime }
        usages = sortedUsages
        usageViewModel.replaceUsageSnapshot(snapshot)
        lastRefresh = Date()
        usagesVersion &+= 1
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
        try await actor.deleteAll()
        await refresh()
    }
}

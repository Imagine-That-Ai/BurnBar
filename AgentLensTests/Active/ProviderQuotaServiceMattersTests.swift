import Foundation
import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Pins the behaviour of three formerly-swallowed `try?` error sites in
/// `ProviderQuotaService` that were conservatively judged to MATTER:
///
/// 1. `init` → `OpenBurnBarMigration.prepareSupportDirectory` (L277): the
///    support-directory prep must remain best-effort (the service still
///    constructs even if it fails) but the fault is now logged instead of
///    silently swallowed.
/// 2. `refreshRoutingState` → `providerAccountStore.fetchAll` (L482): a local
///    store read fault must NOT crash routing; it degrades gracefully (routing
///    still draws on snapshots / daemon configs / preferred IDs) and logs.
/// 3. `connectedQuotaProviderIDs` → `providerAccountStore.fetchAll` (L823): the
///    fail path must (a) report "no connected accounts" on a read fault and
///    (b) NOT poison the 15s cache with that fault-derived empty set, so a
///    transient DB hiccup self-heals on the very next call instead of hiding
///    every connected account for a quarter minute.
///
/// The read fault is injected realistically: a real in-memory `DataStore` is
/// constructed (so migrations create `provider_accounts`), then the table is
/// dropped so `fetchAll`'s `SELECT * FROM provider_accounts` throws a genuine
/// GRDB "no such table" error — exactly the shape of a corrupted/locked store.
@MainActor
final class ProviderQuotaServiceMattersTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProviderQuotaServiceMatters-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            if let tempRoot {
                try? FileManager.default.removeItem(at: tempRoot)
            }
            tempRoot = nil
        }
        try await super.tearDown()
    }

    // MARK: - L277: prepareSupportDirectory is best-effort but observable

    /// Even when the application-support root cannot be created (a plain file
    /// occupies the directory path), the service must still construct so the
    /// rest of the app keeps working. We only changed swallowing into logging
    /// — the resilience contract is unchanged.
    func test_init_survivesUnpreparableSupportDirectory() throws {
        // Plant a regular file where the support root directory should live so
        // `prepareSupportDirectory` cannot create the directory tree.
        let blockedRoot = tempRoot.appendingPathComponent("blocked-support-root", isDirectory: true)
        FileManager.default.createFile(atPath: blockedRoot.path, contents: Data("x".utf8))

        var service: ProviderQuotaService?
        XCTAssertNoThrow(
            service = makeService(appSupportRoot: blockedRoot)
        )
        XCTAssertNotNil(service, "Service must construct even when support-dir prep fails")
        // And it must be usable afterwards (no half-initialised state).
        XCTAssertNil(service?.snapshot(for: .minimax))
    }

    // MARK: - L482: refreshRoutingState degrades gracefully on a read fault

    func test_refreshRoutingState_doesNotCrashWhenAccountFetchThrows() async throws {
        let service = makeService(appSupportRoot: tempRoot)
        let dataStore = try makeDataStore()
        try await breakProviderAccountsTable(dataStore)

        let states = await service.refreshRoutingState(dataStore: dataStore)
        // With no locally-known accounts available (the read faulted) and no
        // daemon configs / snapshots seeded in this hermetic instance, routing
        // produces no candidate-backed states — but it must reach that result
        // gracefully rather than trapping on the swallowed throw.
        XCTAssertTrue(states.isEmpty)
    }

    // MARK: - L823: connected-account read fault is not cached

    func test_hasConnectedQuotaAccount_falseOnReadFaultWithoutPoisoningCache() async throws {
        let service = makeService(appSupportRoot: tempRoot)

        // First, a broken store: the connected-account read faults.
        let brokenStore = try makeDataStore()
        try await breakProviderAccountsTable(brokenStore)
        let brokenStoreHasMiniMax = await service.hasConnectedQuotaAccount(for: .minimax, dataStore: brokenStore)
        XCTAssertFalse(brokenStoreHasMiniMax, "A read fault must report no connected accounts, not crash")

        // Then, a healthy store with a genuinely-connected MiniMax account.
        // If the fault-derived empty set had been cached (the old behaviour),
        // this call would still return false for up to 15 seconds. The fix
        // skips caching on failure, so the very next call re-probes and sees
        // the connected account.
        let healthyStore = try makeDataStore()
        try await seedConnectedAccount(in: healthyStore, provider: .minimax)
        let healthyStoreHasMiniMax = await service.hasConnectedQuotaAccount(for: .minimax, dataStore: healthyStore)
        XCTAssertTrue(healthyStoreHasMiniMax, "A transient read fault must not pin an empty set in the 15s cache")
    }

    func test_hasConnectedQuotaAccount_trueForConnectedAccount() async throws {
        let service = makeService(appSupportRoot: tempRoot)
        let dataStore = try makeDataStore()
        try await seedConnectedAccount(in: dataStore, provider: .minimax)

        let hasMiniMax = await service.hasConnectedQuotaAccount(for: .minimax, dataStore: dataStore)
        XCTAssertTrue(hasMiniMax)
        // Sanity: an unconnected provider stays false.
        let hasDeepSeek = await service.hasConnectedQuotaAccount(for: .deepSeek, dataStore: dataStore)
        XCTAssertFalse(hasDeepSeek)
    }

    // MARK: - Helpers

    private func makeService(appSupportRoot: URL) -> ProviderQuotaService {
        ProviderQuotaService(
            keyStore: ProviderAPIKeyStore(
                keychain: KeychainStore(
                    service: "tests.matters.\(UUID().uuidString)",
                    legacyServices: [],
                    backend: InMemoryKeychainBackend()
                )
            ),
            providerRuntimeKeyStore: KeychainStore(
                service: "tests.matters.runtime.\(UUID().uuidString)",
                legacyServices: [],
                backend: InMemoryKeychainBackend()
            ),
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot),
            fileManager: .default,
            session: .shared,
            environment: [:],
            homeDirectoryURL: tempRoot.appendingPathComponent("home", isDirectory: true),
            miniMaxModeProvider: { .payAsYouGo },
            factoryPlanProvider: { .unknown },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            refreshProviders: ProviderQuotaService.supportedProviders
        )
    }

    private func makeDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    /// Drops `provider_accounts` so `fetchAll`'s SELECT throws a real GRDB
    /// "no such table" error — the cleanest available stand-in for a
    /// corrupted/locked local store.
    private func breakProviderAccountsTable(_ dataStore: DataStore) async throws {
        try await dataStore.actor.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS provider_accounts")
        }
    }

    private func seedConnectedAccount(in dataStore: DataStore, provider: AgentProvider) async throws {
        let now = Date()
        try await dataStore.upsertProviderAccount(
            ProviderAccountDoc(
                id: "\(provider.providerID.rawValue)-test",
                providerID: provider.providerID,
                label: "Test account",
                status: .connected,
                credentialKind: .bearer,
                storageScope: .deviceKeychain,
                redactedLabel: "Stored in Mac Keychain",
                isDefault: true,
                sortKey: 0,
                schemaVersion: 2,
                createdAt: now,
                updatedAt: now
            )
        )
    }
}

// MARK: - In-memory keychain backend

/// Hermetic `KeychainStoreBackend`: never touches the real keychain. Absence is
/// the empty store; all operations succeed against an in-process dictionary.
private final class InMemoryKeychainBackend: KeychainStoreBackend {
    private let storage = Locked<[String: [String: Data]]>([:])

    func set(_ value: Data, service: String, account: String) throws {
        storage.withLock { $0[service, default: [:]][account] = value }
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage.withLock { $0[service]?[account] }
    }

    func delete(service: String, account: String) throws {
        storage.withLock { $0[service]?[account] = nil }
    }
}

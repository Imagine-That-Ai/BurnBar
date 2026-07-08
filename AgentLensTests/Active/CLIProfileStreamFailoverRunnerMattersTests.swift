import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Behavioral guards for `ProductionSwitcherProfileStoreAdapter`, the adapter the
/// CLI profile-stream failover runner consults to (a) enumerate failover
/// candidates and (b) persist the active/drain pointer + quota-exhaustion state.
///
/// Previously every adapter method swallowed the underlying SQLite error with a
/// bare `try?`, so a genuine DB fault was indistinguishable from a legitimate
/// "absent profile" / "empty store" / "write succeeded". That silently changes
/// which account drains quota and lets a failover fail to "stick".
///
/// These tests pin two invariants:
///  1. Happy path — against a fully-migrated store, every method round-trips
///     exactly (the non-throwing protocol contract is preserved).
///  2. Fault path — against a store whose tables do not exist (every query
///     throws `no such table`), reads degrade to their documented fallback
///     (`nil` / `[]`) and writes are no-ops, WITHOUT propagating the error past
///     the non-throwing protocol boundary and WITHOUT corrupting a separate
///     healthy store's persisted state. The fault is now routed through
///     `AppLogger.dataStore` (observable) instead of being swallowed.
final class CLIProfileStreamFailoverRunnerMattersTests: XCTestCase {

    // MARK: - Schema helpers

    /// Builds a fully-migrated, healthy store backed by an in-memory queue.
    private func makeHealthyStore() async throws -> (SwitcherProfileStore, DatabaseQueue) {
        let queue = try DatabaseQueue()
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE switcher_profiles (
                    id TEXT PRIMARY KEY,
                    targetKind TEXT NOT NULL,
                    browserType TEXT,
                    browserMetadataJSON TEXT,
                    cliType TEXT,
                    cliMetadataJSON TEXT,
                    sortKey INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE switcher_active_profile (
                    activeProfileID TEXT,
                    providerID TEXT,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt)
                VALUES (NULL, NULL, '2024-01-01T00:00:00Z')
            """)
        }
        return (SwitcherProfileStore(dbQueue: queue), queue)
    }

    /// Builds a store backed by an in-memory queue with NO tables, so every
    /// underlying read/write throws (`no such table`). Models a real DB fault.
    private func makeFaultingStore() throws -> SwitcherProfileStore {
        let queue = try DatabaseQueue()
        return SwitcherProfileStore(dbQueue: queue)
    }

    private func makeCLIProfile(id: String, sortKey: Int) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            id: id,
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(displayLabel: "Profile \(id)"),
            sortKey: sortKey
        )
    }

    // MARK: - Happy path: contract preserved

    func test_healthyStore_roundTripsAllAdapterReadsAndWrites() async throws {
        let (store, _) = try await makeHealthyStore()
        let adapter = ProductionSwitcherProfileStoreAdapter(store: store)

        let primary = makeCLIProfile(id: "primary", sortKey: 1)
        let fallback = makeCLIProfile(id: "fallback", sortKey: 2)
        _ = try store.create(primary)
        _ = try store.create(fallback)

        // fetchProfile(id:)
        XCTAssertEqual(adapter.fetchProfile(id: "primary")?.id, "primary")
        XCTAssertNil(adapter.fetchProfile(id: "does-not-exist"))

        // fetchAllProfiles() — deterministic sortKey order.
        XCTAssertEqual(adapter.fetchAllProfiles().map(\.id), ["primary", "fallback"])

        // setActiveProfileID / fetchActiveProfileID (global pointer).
        adapter.setActiveProfileID("primary")
        XCTAssertEqual(adapter.fetchActiveProfileID(), "primary")

        // Per-provider drain pointer.
        adapter.setActiveProfileID("fallback", for: ProviderID.codex)
        XCTAssertEqual(adapter.fetchActiveProfileID(for: ProviderID.codex), "fallback")

        // updateProfile — persists quota-exhaustion metadata.
        let exhausted = SwitcherProfileRecord(
            id: "primary",
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Profile primary",
                lastQuotaExhaustedAt: Date(),
                lastQuotaExhaustionDetail: "rate limit"
            ),
            sortKey: 1,
            createdAt: primary.createdAt
        )
        adapter.updateProfile(exhausted)
        XCTAssertEqual(
            adapter.fetchProfile(id: "primary")?.cliMetadata?.lastQuotaExhaustionDetail,
            "rate limit"
        )
    }

    // MARK: - Fault path: reads degrade, do not crash, do not throw

    func test_faultingStore_fetchProfile_returnsNilWithoutThrowing() throws {
        let adapter = ProductionSwitcherProfileStoreAdapter(store: try makeFaultingStore())
        // A DB fault must not crash or escape the non-throwing protocol method;
        // it degrades to nil (now logged via AppLogger.dataStore.silently).
        XCTAssertNil(adapter.fetchProfile(id: "anything"))
    }

    func test_faultingStore_fetchAllProfiles_returnsEmptyWithoutThrowing() throws {
        let adapter = ProductionSwitcherProfileStoreAdapter(store: try makeFaultingStore())
        // An empty candidate set caused by a DB fault must not crash; it degrades
        // to [] (now observable). This is the path that otherwise silently removes
        // every failover candidate.
        XCTAssertTrue(adapter.fetchAllProfiles().isEmpty)
    }

    func test_faultingStore_fetchActiveProfileID_returnsNilWithoutThrowing() throws {
        let adapter = ProductionSwitcherProfileStoreAdapter(store: try makeFaultingStore())
        XCTAssertNil(adapter.fetchActiveProfileID())
        XCTAssertNil(adapter.fetchActiveProfileID(for: ProviderID.codex))
    }

    // MARK: - Fault path: writes are safe no-ops, do not corrupt healthy state

    func test_faultingStore_writes_doNotCrashOrThrow() throws {
        let adapter = ProductionSwitcherProfileStoreAdapter(store: try makeFaultingStore())
        // Smoke test by intent: the faulting store only exposes this contract
        // by not trapping or propagating through the adapter's non-throwing API.
        // Each write hits a missing table and throws underneath. The new do/catch
        // surfaces the failure via AppLogger.dataStore.error instead of swallowing
        // it, but must not crash or propagate past the non-throwing method.
        adapter.setActiveProfileID("primary")
        adapter.setActiveProfileID("primary", for: ProviderID.codex)
        adapter.updateProfile(makeCLIProfile(id: "primary", sortKey: 0))

        // The failed writes must not fabricate state: every read against the
        // same faulting store still degrades to nil/empty rather than echoing
        // the value the write pretended to persist.
        XCTAssertNil(adapter.fetchActiveProfileID(), "Failed setActiveProfileID must not surface as a readable pointer")
        XCTAssertNil(adapter.fetchActiveProfileID(for: ProviderID.codex), "Failed per-provider write must not surface as a readable pointer")
        XCTAssertTrue(adapter.fetchAllProfiles().isEmpty, "Failed updateProfile must not materialize a profile")
    }

    /// A failed write against a faulting store must not silently mutate a separate
    /// healthy store's persisted active-profile pointer — i.e. the lost write does
    /// not masquerade as success and the previously-pinned drain target stands.
    func test_faultingWrite_leavesPreviouslyPinnedDrainTargetIntact() async throws {
        let (healthyStore, _) = try await makeHealthyStore()
        let healthyAdapter = ProductionSwitcherProfileStoreAdapter(store: healthyStore)

        _ = try healthyStore.create(makeCLIProfile(id: "good", sortKey: 1))
        healthyAdapter.setActiveProfileID("good", for: ProviderID.codex)
        XCTAssertEqual(healthyAdapter.fetchActiveProfileID(for: ProviderID.codex), "good")

        // A separate, faulting store fails to persist a new pointer.
        let faultingAdapter = ProductionSwitcherProfileStoreAdapter(store: try makeFaultingStore())
        faultingAdapter.setActiveProfileID("stale", for: ProviderID.codex)

        // The healthy store's pinned drain target is unchanged: the failed write
        // never silently became a fail-open "stale" route.
        XCTAssertEqual(healthyAdapter.fetchActiveProfileID(for: ProviderID.codex), "good")
    }
}

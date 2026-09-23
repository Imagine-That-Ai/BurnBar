import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Wave 2.1c-v: the daemon owns `switcher_active_profile` (ADR-005) and the
/// app commits its active-pointer writes through the writer seam. These tests
/// pin the app→daemon mapping (recording writer), the local-double
/// equivalence for daemon-less suites, and the fail-closed contract.
final class SwitcherActiveProfileCutoverTests: XCTestCase {
    private var dbQueue: DatabaseQueue!

    override func setUp() async throws {
        try await super.setUp()
        dbQueue = try DatabaseQueue()
        try await dbQueue.write { db in
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
                INSERT INTO switcher_active_profile (activeProfileID, updatedAt) VALUES (NULL, '2024-01-01T00:00:00Z')
            """)
        }
    }

    override func tearDown() {
        dbQueue = nil
        super.tearDown()
    }

    private func makeCLIProfile(cliType: SwitcherCLIProfileType = .claude, sortKey: Int = 1) -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(),
            sortKey: sortKey
        )
    }

    private func makeBrowserProfile() -> SwitcherProfileRecord {
        SwitcherProfileRecord(
            targetKind: .browser,
            browserType: .chrome,
            browserMetadata: SwitcherBrowserProfileMetadata(
                profileIdentifier: "cutover",
                accountEmail: nil
            ),
            sortKey: 1
        )
    }

    private func fetchPointerRows() throws -> [(activeProfileID: String?, providerID: String?)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT activeProfileID, providerID FROM switcher_active_profile ORDER BY rowid ASC"
            ).map { ($0["activeProfileID"], $0["providerID"]) }
        }
    }

    // MARK: - Mapping (recording writer)

    func testGlobalSetSendsGlobalPlusMirrorInOneApply() throws {
        let recording = RecordingSwitcherActiveProfileWriter()
        let store = SwitcherProfileStore(dbQueue: dbQueue, activeProfileWriter: recording)
        let profile = try store.create(makeCLIProfile())

        try store.setActiveProfile(profile.id)

        XCTAssertEqual(recording.applies.count, 1)
        let request = try XCTUnwrap(recording.applies.first)
        XCTAssertNil(request.clearProfileID)
        XCTAssertEqual(request.sets.count, 2)
        XCTAssertEqual(request.sets[0].profileID, profile.id)
        XCTAssertNil(request.sets[0].providerID)
        XCTAssertEqual(request.sets[1].profileID, profile.id)
        XCTAssertEqual(
            request.sets[1].providerID,
            SwitcherCLIProfileType.claude.providerID.rawValue
        )
    }

    func testBrowserSetSendsGlobalOnly() throws {
        let recording = RecordingSwitcherActiveProfileWriter()
        let store = SwitcherProfileStore(dbQueue: dbQueue, activeProfileWriter: recording)
        let profile = try store.create(makeBrowserProfile())

        try store.setActiveProfile(profile.id)

        XCTAssertEqual(recording.applies.count, 1)
        let request = try XCTUnwrap(recording.applies.first)
        XCTAssertEqual(request.sets.count, 1)
        XCTAssertEqual(request.sets[0].profileID, profile.id)
        XCTAssertNil(request.sets[0].providerID)
    }

    func testProviderSetSendsSingleProviderSet() throws {
        let recording = RecordingSwitcherActiveProfileWriter()
        let store = SwitcherProfileStore(dbQueue: dbQueue, activeProfileWriter: recording)
        let profile = try store.create(makeCLIProfile())

        try store.setActiveProfile(profile.id, for: ProviderID(rawValue: "codex"))

        XCTAssertEqual(recording.applies.count, 1)
        let request = try XCTUnwrap(recording.applies.first)
        XCTAssertNil(request.clearProfileID)
        XCTAssertEqual(request.sets.count, 1)
        XCTAssertEqual(request.sets[0].profileID, profile.id)
        XCTAssertEqual(request.sets[0].providerID, "codex")
    }

    func testDeleteProfileSendsClearBeforeLocalDelete() throws {
        let recording = RecordingSwitcherActiveProfileWriter()
        let local = SwitcherProfileStore(
            dbQueue: dbQueue,
            activeProfileWriter: LocalSwitcherActiveProfileWriter(dbQueue: dbQueue)
        )
        let profile = try local.create(makeCLIProfile())
        try local.setActiveProfile(profile.id)

        let store = SwitcherProfileStore(dbQueue: dbQueue, activeProfileWriter: recording)
        try store.deleteProfile(id: profile.id)

        // The clear commits through the writer BEFORE the local profile
        // delete, and the fallback follows (no profiles remain, so a global
        // nil-set) — one RPC per call, in order. The recording writer stands
        // in for the daemon here, so the pointer rows themselves are
        // untouched — the assertion is the mapping.
        XCTAssertEqual(recording.applies.count, 2)
        let clear = try XCTUnwrap(recording.applies.first)
        XCTAssertEqual(clear.clearProfileID, profile.id)
        XCTAssertTrue(clear.sets.isEmpty)
        let fallback = try XCTUnwrap(recording.applies.last)
        XCTAssertNil(fallback.clearProfileID)
        XCTAssertEqual(fallback.sets.count, 1)
        XCTAssertNil(fallback.sets[0].profileID)
        XCTAssertNil(fallback.sets[0].providerID)
        XCTAssertNil(try store.fetchProfile(id: profile.id))
    }

    func testFallbackSelectsLowestSortKey() throws {
        let recording = RecordingSwitcherActiveProfileWriter()
        let store = SwitcherProfileStore(dbQueue: dbQueue, activeProfileWriter: recording)
        _ = try store.create(makeCLIProfile(cliType: .codex, sortKey: 2))
        let first = try store.create(makeCLIProfile(cliType: .claude, sortKey: 1))

        try store.selectFallbackActiveProfile()

        XCTAssertEqual(recording.applies.count, 1)
        let request = try XCTUnwrap(recording.applies.first)
        XCTAssertNil(request.clearProfileID)
        XCTAssertEqual(request.sets.count, 1)
        XCTAssertEqual(request.sets[0].profileID, first.id)
        XCTAssertNil(request.sets[0].providerID)
    }

    // MARK: - Local-double equivalence

    func testLocalDoubleSetAndFetchRoundTrip() throws {
        let store = SwitcherProfileStore(
            dbQueue: dbQueue,
            activeProfileWriter: LocalSwitcherActiveProfileWriter(dbQueue: dbQueue)
        )
        let profile = try store.create(makeCLIProfile())

        try store.setActiveProfile(profile.id)
        try store.setActiveProfile(profile.id, for: ProviderID(rawValue: "codex"))

        XCTAssertEqual(try store.fetchActiveProfileState().activeProfileID, profile.id)
        XCTAssertEqual(
            try store.fetchActiveProfileID(for: ProviderID(rawValue: "codex")),
            profile.id
        )
        XCTAssertEqual(
            try store.fetchActiveProfileID(for: SwitcherCLIProfileType.claude.providerID),
            profile.id
        )
    }

    func testLocalDoubleDeleteClearsAndFallsBack() throws {
        let store = SwitcherProfileStore(
            dbQueue: dbQueue,
            activeProfileWriter: LocalSwitcherActiveProfileWriter(dbQueue: dbQueue)
        )
        let keeper = try store.create(makeCLIProfile(cliType: .claude, sortKey: 1))
        let doomed = try store.create(makeCLIProfile(cliType: .codex, sortKey: 2))
        try store.setActiveProfile(doomed.id)

        try store.deleteProfile(id: doomed.id)

        XCTAssertEqual(try store.fetchActiveProfileState().activeProfileID, keeper.id)
        XCTAssertNil(try store.fetchProfile(id: doomed.id))
    }

    // MARK: - Fail closed

    func testThrowingWriterFailsClosedWithoutWriting() throws {
        let store = SwitcherProfileStore(
            dbQueue: dbQueue,
            activeProfileWriter: ThrowingSwitcherActiveProfileWriter()
        )
        let profile = try store.create(makeCLIProfile())

        XCTAssertThrowsError(try store.setActiveProfile(profile.id))

        // Nothing landed: the seed row is untouched and no pointer was set.
        let rows = try fetchPointerRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].activeProfileID)
    }

    func testThrowingWriterAbortsDeleteBeforeLocalDelete() throws {
        let local = SwitcherProfileStore(
            dbQueue: dbQueue,
            activeProfileWriter: LocalSwitcherActiveProfileWriter(dbQueue: dbQueue)
        )
        let profile = try local.create(makeCLIProfile())
        try local.setActiveProfile(profile.id)

        let store = SwitcherProfileStore(
            dbQueue: dbQueue,
            activeProfileWriter: ThrowingSwitcherActiveProfileWriter()
        )
        XCTAssertThrowsError(try store.deleteProfile(id: profile.id))

        // Fail-closed ordering: the clear threw, so the profile row is still
        // present — no dangling pointer, no silent half-delete.
        XCTAssertNotNil(try store.fetchProfile(id: profile.id))
    }
}

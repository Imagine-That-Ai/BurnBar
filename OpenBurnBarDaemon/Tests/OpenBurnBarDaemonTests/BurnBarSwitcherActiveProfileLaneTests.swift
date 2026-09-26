import XCTest
import GRDB
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon

/// Wave 2.1c-v: the daemon-owned write path for the app lane of
/// `switcher_active_profile`. The app finalizes every write locally; this
/// lane validates shape, then applies sets verbatim in one transaction.
final class BurnBarSwitcherActiveProfileLaneTests: XCTestCase {
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            // Full v46 shape (the lane's documented precondition): the
            // migrator owns `providerID` and the daemon bootstrap self-heals
            // it, so the column is guaranteed at lane time.
            try db.execute(sql: """
                CREATE TABLE switcher_active_profile (
                    activeProfileID TEXT,
                    providerID TEXT,
                    updatedAt TEXT NOT NULL
                )
            """)
        }
    }

    override func tearDown() {
        dbQueue = nil
        super.tearDown()
    }

    private func makeStore() -> BurnBarSwitcherSQLiteProfileStore {
        BurnBarSwitcherSQLiteProfileStore(dbQueue: dbQueue)
    }

    private func seed(activeProfileID: String?, providerID: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, ?, ?)",
                arguments: [activeProfileID, providerID, Date()]
            )
        }
    }

    private func fetchAll() throws -> [(activeProfileID: String?, providerID: String?)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT activeProfileID, providerID FROM switcher_active_profile ORDER BY rowid ASC"
            ).map { ($0["activeProfileID"], $0["providerID"]) }
        }
    }

    private func globalRow(
        in rows: [(activeProfileID: String?, providerID: String?)]
    ) -> (activeProfileID: String?, providerID: String?)? {
        rows.first { $0.providerID == nil }
    }

    private func providerRow(
        _ providerID: String,
        in rows: [(activeProfileID: String?, providerID: String?)]
    ) -> (activeProfileID: String?, providerID: String?)? {
        rows.first { $0.providerID == providerID }
    }

    // MARK: - Sets

    func testGlobalSetRewritesOnlyTheGlobalPointer() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-old", providerID: nil)
        try seed(activeProfileID: "profile-provider", providerID: "claude-code")

        let response = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "profile-new")])
        )

        XCTAssertEqual(response.setsApplied, 1)
        XCTAssertEqual(response.rowsCleared, 0)
        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 2)
        // DELETE+INSERT moves the rewritten row to the end, so look the
        // scopes up instead of assuming positions.
        XCTAssertEqual(globalRow(in: rows)?.activeProfileID, "profile-new")
        // The per-provider drain target survives the global rewrite.
        XCTAssertEqual(providerRow("claude-code", in: rows)?.activeProfileID, "profile-provider")
    }

    func testProviderSetRewritesOnlyThatProvider() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-global", providerID: nil)
        try seed(activeProfileID: "profile-old", providerID: "claude-code")
        try seed(activeProfileID: "profile-codex", providerID: "codex")

        let response = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(
                sets: [.init(profileID: "profile-new", providerID: "claude-code")]
            )
        )

        XCTAssertEqual(response.setsApplied, 1)
        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(globalRow(in: rows)?.activeProfileID, "profile-global")
        XCTAssertEqual(providerRow("claude-code", in: rows)?.activeProfileID, "profile-new")
        XCTAssertEqual(providerRow("codex", in: rows)?.activeProfileID, "profile-codex")
    }

    func testMultiSetBatchAppliesGlobalPlusMirror() throws {
        let store = makeStore()

        let response = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(sets: [
                BurnBarSwitcherActiveProfileSet(profileID: "profile-1"),
                BurnBarSwitcherActiveProfileSet(profileID: "profile-1", providerID: "claude-code")
            ])
        )

        XCTAssertEqual(response.setsApplied, 2)
        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].activeProfileID, "profile-1")
        XCTAssertNil(rows[0].providerID)
        XCTAssertEqual(rows[1].activeProfileID, "profile-1")
        XCTAssertEqual(rows[1].providerID, "claude-code")
    }

    func testSetHealsLegacyDuplicateRows() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-stale", providerID: nil)
        try seed(activeProfileID: "profile-staler", providerID: nil)

        _ = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "profile-new")])
        )

        // The DELETE-the-scope rewrite heals duplicates: the app's
        // pre-cutover fetch-time dedup is subsumed by the lane.
        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].activeProfileID, "profile-new")
    }

    func testNilProfileIDClearsThePointer() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-old", providerID: "claude-code")

        _ = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: nil, providerID: "claude-code")])
        )

        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].activeProfileID)
        XCTAssertEqual(rows[0].providerID, "claude-code")
    }

    func testProviderIDNormalizesBeforeStoring() throws {
        let store = makeStore()

        _ = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "profile-1", providerID: "Claude_Code")])
        )

        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].providerID, "claude-code")
    }

    // MARK: - Clear

    func testClearByProfileClearsGlobalAndProviderRows() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-doomed", providerID: nil)
        try seed(activeProfileID: "profile-doomed", providerID: "claude-code")
        try seed(activeProfileID: "profile-keeper", providerID: "codex")

        let response = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(clearProfileID: "profile-doomed")
        )

        XCTAssertEqual(response.setsApplied, 0)
        XCTAssertEqual(response.rowsCleared, 2)
        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0].activeProfileID)
        XCTAssertNil(rows[1].activeProfileID)
        XCTAssertEqual(rows[2].activeProfileID, "profile-keeper")
    }

    func testClearMatchesNothingWithoutError() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-keeper", providerID: nil)

        let response = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(clearProfileID: "profile-ghost")
        )

        XCTAssertEqual(response.rowsCleared, 0)
        XCTAssertEqual(try fetchAll().count, 1)
    }

    func testCombinedApplyClearsBeforeItSets() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-old", providerID: "codex")

        // If the set ran first, the clear would NULL the row just written.
        // Clear-first leaves the set standing.
        _ = try store.switcherActiveProfileApply(
            BurnBarSwitcherActiveProfileApplyRequest(
                sets: [.init(profileID: "profile-old")],
                clearProfileID: "profile-old"
            )
        )

        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].activeProfileID)
        XCTAssertEqual(rows[1].activeProfileID, "profile-old")
        XCTAssertNil(rows[1].providerID)
    }

    // MARK: - Validation

    func testValidationRejectsMalformedAppliesBeforeAnyWrite() throws {
        let store = makeStore()
        try seed(activeProfileID: "profile-keeper", providerID: nil)

        // Fully empty.
        assertInvalidRequest(store, BurnBarSwitcherActiveProfileApplyRequest())
        // Over the two-set cap (global + mirror is the only multi-set caller).
        assertInvalidRequest(
            store,
            BurnBarSwitcherActiveProfileApplyRequest(sets: [
                .init(profileID: "a"), .init(profileID: "b"), .init(profileID: "c")
            ])
        )
        // Clearing is spelled nil, never "".
        assertInvalidRequest(
            store,
            BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "")])
        )
        // Empty provider spellings (including whitespace-only, which
        // normalizes to empty) are caller bugs.
        assertInvalidRequest(
            store,
            BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "a", providerID: "")])
        )
        assertInvalidRequest(
            store,
            BurnBarSwitcherActiveProfileApplyRequest(sets: [.init(profileID: "a", providerID: "   ")])
        )
        assertInvalidRequest(
            store,
            BurnBarSwitcherActiveProfileApplyRequest(clearProfileID: "")
        )

        // Nothing landed: validation runs before the transaction opens.
        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].activeProfileID, "profile-keeper")
    }

    private func assertInvalidRequest(
        _ store: BurnBarSwitcherSQLiteProfileStore,
        _ request: BurnBarSwitcherActiveProfileApplyRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try store.switcherActiveProfileApply(request)
            XCTFail("malformed apply must throw", file: file, line: line)
        } catch BurnBarSwitcherSQLiteProfileStore.ActiveProfileLaneError.invalidRequest {
        } catch {
            XCTFail("expected invalidRequest, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Legacy delegation

    func testLegacySettersRouteThroughTheLane() throws {
        let store = makeStore()

        store.setActiveProfileID("profile-global")
        store.setActiveProfileID("profile-provider", for: ProviderID(rawValue: "claude-code"))

        let rows = try fetchAll()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(store.fetchActiveProfileID(), "profile-global")
        XCTAssertEqual(
            store.fetchActiveProfileID(for: ProviderID(rawValue: "claude-code")),
            "profile-provider"
        )
    }
}

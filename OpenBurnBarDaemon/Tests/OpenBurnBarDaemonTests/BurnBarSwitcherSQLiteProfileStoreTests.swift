import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBarDaemon

/// Regression coverage for the shared-DB hazard between the BurnBar app and the
/// daemon. The app's per-provider drain targets and the daemon's global active
/// profile both live in `switcher_active_profile` — these tests prove the
/// daemon stays a good citizen instead of wiping the app's rows.
final class BurnBarSwitcherSQLiteProfileStoreTests: XCTestCase {
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
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
            // Pre-v46 schema deliberately omits providerID so the store's
            // ensureDrainTargetColumn() can add it idempotently in the test.
            try db.execute(sql: """
                CREATE TABLE switcher_active_profile (
                    activeProfileID TEXT,
                    updatedAt TEXT NOT NULL
                )
            """)
        }
    }

    override func tearDown() {
        dbQueue = nil
        super.tearDown()
    }

    func test_init_addsProviderIDColumnIdempotently() throws {
        _ = BurnBarSwitcherSQLiteProfileStore(dbQueue: dbQueue)

        let columns = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(switcher_active_profile)")
                .compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(columns.contains("providerID"), "Daemon store must self-heal the schema for the shared DB")

        // Second init must not throw or duplicate the column.
        _ = BurnBarSwitcherSQLiteProfileStore(dbQueue: dbQueue)
        let columnsAfter = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(switcher_active_profile)")
                .compactMap { $0["name"] as? String }
        }
        XCTAssertEqual(columnsAfter.filter { $0 == "providerID" }.count, 1)
    }

    func test_setActiveProfileID_doesNotWipeAppSetPerProviderRows() throws {
        let store = BurnBarSwitcherSQLiteProfileStore(dbQueue: dbQueue)

        // App writes per-provider drain target for Claude.
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, ?, ?)",
                arguments: ["claude-personal-id", AgentProvider.claudeCode.providerID.rawValue, Date()]
            )
        }

        // Daemon flips its own global active profile.
        store.setActiveProfileID("daemon-chosen-global-id")

        let perProvider = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT activeProfileID FROM switcher_active_profile
                    WHERE providerID = ? AND activeProfileID IS NOT NULL
                """,
                arguments: [AgentProvider.claudeCode.providerID.rawValue]
            )
        }
        XCTAssertEqual(
            perProvider,
            "claude-personal-id",
            "Daemon global writes must leave the app's per-provider drain targets intact"
        )

        let globalActive = store.fetchActiveProfileID()
        XCTAssertEqual(globalActive, "daemon-chosen-global-id")
    }

    func test_fetchActiveProfileID_returnsGlobalNotPerProvider() throws {
        let store = BurnBarSwitcherSQLiteProfileStore(dbQueue: dbQueue)

        // Stamp a more recent per-provider row and an older global row. The
        // pre-fix daemon ordered purely by updatedAt and would have returned
        // the per-provider id; the fix scopes to providerID IS NULL.
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, NULL, ?)",
                arguments: ["global-id", Date().addingTimeInterval(-100)]
            )
            try db.execute(
                sql: "INSERT INTO switcher_active_profile (activeProfileID, providerID, updatedAt) VALUES (?, ?, ?)",
                arguments: ["claude-id", AgentProvider.claudeCode.providerID.rawValue, Date()]
            )
        }

        XCTAssertEqual(
            store.fetchActiveProfileID(),
            "global-id",
            "Daemon's global getter must ignore per-provider rows"
        )
    }

    func test_perProviderRoundTrip_onDaemonStore() {
        let store = BurnBarSwitcherSQLiteProfileStore(dbQueue: dbQueue)

        store.setActiveProfileID("claude-A", for: AgentProvider.claudeCode.providerID)
        store.setActiveProfileID("codex-B", for: AgentProvider.codex.providerID)

        XCTAssertEqual(store.fetchActiveProfileID(for: AgentProvider.claudeCode.providerID), "claude-A")
        XCTAssertEqual(store.fetchActiveProfileID(for: AgentProvider.codex.providerID), "codex-B")

        // Sibling isolation — swapping Claude must not touch Codex.
        store.setActiveProfileID("claude-Z", for: AgentProvider.claudeCode.providerID)
        XCTAssertEqual(store.fetchActiveProfileID(for: AgentProvider.claudeCode.providerID), "claude-Z")
        XCTAssertEqual(store.fetchActiveProfileID(for: AgentProvider.codex.providerID), "codex-B")
    }
}

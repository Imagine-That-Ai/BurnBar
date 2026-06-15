import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the durable fusion-spend partition: the v49 `parentRequestID` column,
/// its propagation through inserts, and `FusionImpactLedger` partitioning rows
/// over a window into fusion-versus-normal totals via the shared aggregator.
@MainActor
final class FusionImpactLedgerTests: XCTestCase {

    // MARK: - Migration

    func test_migration_v49_addsParentRequestIDColumnAndIndex() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let columns = try queue.read { db -> [String] in
            try Row.fetchAll(db, sql: "PRAGMA table_info(token_usage)")
                .compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(columns.contains("parentRequestID"),
                      "v49 must add the nullable parentRequestID column")

        let indexes = try queue.read { db -> [String] in
            try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'token_usage'"
            ).compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(indexes.contains("token_usage_parent_request_idx"),
                      "v49 must add the partial fusion-row index")
    }

    func test_insert_persistsParentRequestID() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = UsageStore(dbQueue: queue)

        let parent = "\(FusionUsageRow.fusionParentPrefix)\(UUID().uuidString)"
        try store.insert(TokenUsage(
            provider: .hermes, sessionId: "fusion-1", projectName: "Hermes",
            model: "claude-4-sonnet", inputTokens: 100, outputTokens: 50,
            costUSD: 0.02, startTime: Date(), endTime: Date(),
            usageSource: .daemon, parentRequestID: parent
        ))

        let stored = try queue.read { db -> String? in
            try Row.fetchOne(db, sql: "SELECT parentRequestID FROM token_usage LIMIT 1")?["parentRequestID"] as? String
        }
        XCTAssertEqual(stored, parent)
    }

    // MARK: - Partition

    func test_ledger_partitionsFusionVersusNormalOverWindow() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = UsageStore(dbQueue: queue)

        let now = Date()
        let parentA = "\(FusionUsageRow.fusionParentPrefix)A"
        let parentB = "\(FusionUsageRow.fusionParentPrefix)B"

        // Fusion run A: two sub-calls on two models.
        try store.insert(TokenUsage(
            provider: .hermes, sessionId: "a-panel", projectName: "Hermes",
            model: "claude-4-sonnet", inputTokens: 100, outputTokens: 100,
            costUSD: 0.10, startTime: now, endTime: now,
            usageSource: .daemon, parentRequestID: parentA
        ))
        try store.insert(TokenUsage(
            provider: .hermes, sessionId: "a-judge", projectName: "Hermes",
            model: "gpt-5", inputTokens: 50, outputTokens: 50,
            costUSD: 0.05, startTime: now, endTime: now,
            usageSource: .daemon, parentRequestID: parentA
        ))
        // Fusion run B: one sub-call.
        try store.insert(TokenUsage(
            provider: .hermes, sessionId: "b-final", projectName: "Hermes",
            model: "claude-4-sonnet", inputTokens: 200, outputTokens: 100,
            costUSD: 0.20, startTime: now, endTime: now,
            usageSource: .daemon, parentRequestID: parentB
        ))
        // Normal request (no parent).
        try store.insert(TokenUsage(
            provider: .claudeCode, sessionId: "normal-1", projectName: "Proj",
            model: "claude-4-sonnet", inputTokens: 300, outputTokens: 100,
            costUSD: 0.40, startTime: now, endTime: now
        ))

        let ledger = FusionImpactLedger(dbQueue: queue)
        let totals = try await ledger.totals(
            from: now.addingTimeInterval(-60),
            to: now.addingTimeInterval(60)
        )

        XCTAssertEqual(totals.fusionCost, 0.35, accuracy: 1e-6)
        XCTAssertEqual(totals.normalCost, 0.40, accuracy: 1e-6)
        XCTAssertEqual(totals.fusionRuns, 2, "Two distinct elderwand parents")
        XCTAssertEqual(totals.fusionCostByModel["claude-4-sonnet"] ?? 0, 0.30, accuracy: 1e-6)
        XCTAssertEqual(totals.fusionCostByModel["gpt-5"] ?? 0, 0.05, accuracy: 1e-6)
    }

    func test_ledger_excludesRowsOutsideWindow() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = UsageStore(dbQueue: queue)

        let now = Date()
        let old = now.addingTimeInterval(-90 * 24 * 60 * 60)
        try store.insert(TokenUsage(
            provider: .hermes, sessionId: "old-fusion", projectName: "Hermes",
            model: "gpt-5", inputTokens: 10, outputTokens: 10,
            costUSD: 9.99, startTime: old, endTime: old,
            usageSource: .daemon,
            parentRequestID: "\(FusionUsageRow.fusionParentPrefix)OLD"
        ))

        let ledger = FusionImpactLedger(dbQueue: queue)
        let totals = try await ledger.totals(
            from: now.addingTimeInterval(-60 * 60),
            to: now
        )
        XCTAssertEqual(totals.fusionCost, 0, "Row before the window must be excluded")
        XCTAssertEqual(totals.fusionRuns, 0)
    }

    // MARK: - Idempotency-key fallback parsing

    func test_fusionParentRequestID_parsesElderwandPrefixFromKey() {
        let parsed = OpenBurnBarDaemonUsageSyncService.fusionParentRequestID(
            fromIdempotencyKey: "elderwand-1234|panel|claude-4-sonnet|0"
        )
        XCTAssertEqual(parsed, "elderwand-1234")
    }

    func test_fusionParentRequestID_returnsNilForNonFusionKey() {
        XCTAssertNil(
            OpenBurnBarDaemonUsageSyncService.fusionParentRequestID(
                fromIdempotencyKey: "normal-session|model|0"
            )
        )
        XCTAssertNil(
            OpenBurnBarDaemonUsageSyncService.fusionParentRequestID(
                fromIdempotencyKey: "elderwand"
            ),
            "Bare 'elderwand' (no -prefix) is not a fusion parent"
        )
    }
}

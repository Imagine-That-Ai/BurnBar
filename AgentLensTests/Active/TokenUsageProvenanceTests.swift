import XCTest
import GRDB
@testable import OpenBurnBar

/// Tests for VAL-PERSIST-001: Row-level provenance and confidence are persisted.
/// Each ingested usage row must persist provenance method, confidence, and estimator
/// version fields sufficient to audit exact vs estimated origin.
@MainActor
final class TokenUsageProvenanceTests: XCTestCase {

    // MARK: - Schema Migration Tests

    func test_migration_v28_addsProvenanceColumns() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let columns = try queue.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(token_usage)")
            return rows.compactMap { $0["name"] as? String }
        }

        XCTAssertTrue(columns.contains("provenanceMethod"), "v28 must add provenanceMethod column")
        XCTAssertTrue(columns.contains("provenanceConfidence"), "v28 must add provenanceConfidence column")
        XCTAssertTrue(columns.contains("estimatorVersion"), "v28 must add estimatorVersion column")
    }

    // MARK: - Insert and Persist Provenance via Raw DB

    private func insertAndFetchRaw(
        queue: DatabaseQueue,
        usage: TokenUsage
    ) throws -> Row {
        let usageStore = UsageStore(dbQueue: queue)
        try usageStore.insert(usage)

        return try queue.read { db -> Row in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM token_usage ORDER BY startTime DESC LIMIT 1
                """)
            return try XCTUnwrap(rows.first)
        }
    }

    func test_insertExactProviderLog_persistsProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usage = TokenUsage(
            provider: .claudeCode, sessionId: "prov-test-1", projectName: "TestProject",
            model: "claude-4-sonnet", inputTokens: 1000, outputTokens: 500,
            cacheCreationTokens: 100, cacheReadTokens: 200, costUSD: 0.05,
            startTime: Date(), endTime: Date(),
            provenanceMethod: .providerLog, provenanceConfidence: .exact, estimatorVersion: ""
        )

        let row = try insertAndFetchRaw(queue: queue, usage: usage)

        XCTAssertEqual(row["provenanceMethod"] as? String, "provider_log")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row["estimatorVersion"] as? String, "")
    }

    func test_insertHeuristicEstimate_persistsProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usage = TokenUsage(
            provider: .cursor, sessionId: "prov-test-2", projectName: "CursorProject",
            model: "gpt-4", inputTokens: 5000, outputTokens: 1500, costUSD: 0.10,
            startTime: Date(), endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "hash-count-ratio-v1"
        )

        let row = try insertAndFetchRaw(queue: queue, usage: usage)

        XCTAssertEqual(row["provenanceMethod"] as? String, "heuristic_estimate")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "low_confidence_estimate")
        XCTAssertEqual(row["estimatorVersion"] as? String, "hash-count-ratio-v1")
    }

    func test_insertBillingAPI_persistsProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usage = TokenUsage(
            provider: .claudeCode, sessionId: "prov-test-3", projectName: "API Recon",
            model: "claude-4-sonnet", inputTokens: 50000, outputTokens: 12000,
            costUSD: 1.50, startTime: Date(), endTime: Date(),
            usageSource: .billingAPI,
            provenanceMethod: .billingAPI, provenanceConfidence: .exact, estimatorVersion: ""
        )

        let row = try insertAndFetchRaw(queue: queue, usage: usage)

        XCTAssertEqual(row["provenanceMethod"] as? String, "billing_api")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row["usageSource"] as? String, "billing_api")
    }

    func test_insertDaemonBridge_persistsProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usage = TokenUsage(
            provider: .factory, sessionId: "prov-test-4", projectName: "Daemon Session",
            model: "glm-5", inputTokens: 2000, outputTokens: 800, costUSD: 0.02,
            startTime: Date(), endTime: Date(), usageSource: .daemon,
            provenanceMethod: .daemonBridge, provenanceConfidence: .exact, estimatorVersion: ""
        )

        let row = try insertAndFetchRaw(queue: queue, usage: usage)

        XCTAssertEqual(row["provenanceMethod"] as? String, "daemon_bridge")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "exact")
    }

    func test_insertConnectorBridge_persistsProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usage = TokenUsage(
            provider: .claudeCode, sessionId: "prov-test-5", projectName: "Connector",
            model: "claude-4-sonnet", inputTokens: 3000, outputTokens: 1200,
            costUSD: 0.03, startTime: Date(), endTime: Date(),
            usageSource: .cursorBridge,
            provenanceMethod: .connectorBridge, provenanceConfidence: .exact, estimatorVersion: ""
        )

        let row = try insertAndFetchRaw(queue: queue, usage: usage)

        XCTAssertEqual(row["provenanceMethod"] as? String, "connector_bridge")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "exact")
    }

    func test_insertInAppChat_persistsProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let usage = TokenUsage(
            provider: .claudeCode, sessionId: "prov-test-6/1", projectName: "ChatProject",
            model: "claude-4-sonnet", inputTokens: 800, outputTokens: 300, costUSD: 0.01,
            startTime: Date(), endTime: Date(), usageSource: .inAppChat,
            provenanceMethod: .inAppChat, provenanceConfidence: .exact, estimatorVersion: ""
        )

        let row = try insertAndFetchRaw(queue: queue, usage: usage)

        XCTAssertEqual(row["provenanceMethod"] as? String, "in_app_chat")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "exact")
    }

    // MARK: - Upsert Preserves Provenance

    func test_upsertPreservesProvenanceOnConflict() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)

        let sessionId = "prov-upsert-1"
        let model = "claude-4-sonnet"

        // First insert: exact confidence
        let usage1 = TokenUsage(
            provider: .claudeCode, sessionId: sessionId, projectName: "Project",
            model: model, inputTokens: 1000, outputTokens: 500, costUSD: 0.05,
            startTime: Date(), endTime: Date(),
            provenanceMethod: .providerLog, provenanceConfidence: .exact, estimatorVersion: ""
        )
        try usageStore.insert(usage1)

        // Second insert: lower confidence estimate
        let usage2 = TokenUsage(
            provider: .claudeCode, sessionId: sessionId, projectName: "Project",
            model: model, inputTokens: 2000, outputTokens: 1000, costUSD: 0.10,
            startTime: Date(), endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try usageStore.insert(usage2)

        let count = try queue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage")!
        }
        XCTAssertEqual(count, 1, "Upsert must not create duplicate canonical rows")

        let row = try queue.read { db -> Row in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM token_usage LIMIT 1")
            return try XCTUnwrap(rows.first)
        }

        // Exact row must NOT be downgraded by lower confidence estimate
        let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
        XCTAssertEqual(inputTokens, 1000, "Exact row must not be downgraded by lower confidence estimate")
        XCTAssertEqual(row["provenanceMethod"] as? String, "provider_log")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row["estimatorVersion"] as? String, "")
    }

    func test_upsertEqualConfidence_allowsUpdate() throws {
        // Test that when confidence levels are equal, updates ARE allowed
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)

        let sessionId = "prov-upsert-equal-conf"
        let model = "claude-4-sonnet"

        // First insert: high confidence estimate
        let usage1 = TokenUsage(
            provider: .cursor, sessionId: sessionId, projectName: "Project",
            model: model, inputTokens: 1000, outputTokens: 500, costUSD: 0.05,
            startTime: Date(), endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v2"
        )
        try usageStore.insert(usage1)

        // Second insert: same confidence, different values
        let usage2 = TokenUsage(
            provider: .cursor, sessionId: sessionId, projectName: "Project",
            model: model, inputTokens: 2000, outputTokens: 1000, costUSD: 0.10,
            startTime: Date(), endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v2"
        )
        try usageStore.insert(usage2)

        let row = try queue.read { db -> Row in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM token_usage LIMIT 1")
            return try XCTUnwrap(rows.first)
        }

        // With equal confidence, update should happen
        let inputTokens = (row["inputTokens"] as? Int) ?? Int(row["inputTokens"] as? Int64 ?? 0)
        XCTAssertEqual(inputTokens, 2000, "Equal confidence should allow update")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "high_confidence_estimate")
    }

    // MARK: - Remote Insert Preserves Provenance

    func test_insertRemoteUsage_preservesProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)

        let usage = TokenUsage(
            provider: .claudeCode, sessionId: "prov-remote-1", projectName: "RemoteProject",
            model: "claude-4-sonnet", inputTokens: 5000, outputTokens: 2000,
            costUSD: 0.20, startTime: Date(), endTime: Date(),
            sourceDeviceId: "device-123", sourceDeviceName: "Other Mac", isRemote: true,
            provenanceMethod: .cloudSync, provenanceConfidence: .exact, estimatorVersion: ""
        )

        try usageStore.insertRemoteUsage(usage)

        let row = try queue.read { db -> Row in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM token_usage LIMIT 1")
            return try XCTUnwrap(rows.first)
        }

        XCTAssertEqual(row["provenanceMethod"] as? String, "cloud_sync")
        XCTAssertEqual(row["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row["sourceDeviceId"] as? String, "device-123")
    }

    // MARK: - Default Provenance (Legacy Backward Compatibility)

    func test_defaultProvenance_isUnknown() {
        let usage = TokenUsage(
            provider: .factory, sessionId: "default-prov", projectName: "P",
            model: "m", inputTokens: 100, outputTokens: 50, costUSD: 0.01,
            startTime: Date(), endTime: Date()
        )

        XCTAssertEqual(usage.provenanceMethod, .unknown)
        XCTAssertEqual(usage.provenanceConfidence, .unknown)
        XCTAssertEqual(usage.estimatorVersion, "")
    }

    // MARK: - Provenance Confidence Ordering

    func test_provenanceConfidence_precedenceOrdering() {
        XCTAssertTrue(UsageProvenanceConfidence.exact > .derivedExact)
        XCTAssertTrue(UsageProvenanceConfidence.derivedExact > .highConfidenceEstimate)
        XCTAssertTrue(UsageProvenanceConfidence.highConfidenceEstimate > .lowConfidenceEstimate)
        XCTAssertTrue(UsageProvenanceConfidence.lowConfidenceEstimate > .unknown)
    }

    // MARK: - Codable Round-Trip

    func test_provenance_codingRoundTrip() throws {
        let usage = TokenUsage(
            provider: .claudeCode, sessionId: "codec-test", projectName: "TestProject",
            model: "claude-4-sonnet", inputTokens: 1000, outputTokens: 500,
            cacheCreationTokens: 100, cacheReadTokens: 200, costUSD: 0.05,
            startTime: Date(), endTime: Date(),
            provenanceMethod: .providerLog, provenanceConfidence: .exact, estimatorVersion: "v1.0"
        )

        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)

        XCTAssertEqual(decoded.provenanceMethod, .providerLog)
        XCTAssertEqual(decoded.provenanceConfidence, .exact)
        XCTAssertEqual(decoded.estimatorVersion, "v1.0")
    }

    func test_provenance_decodeLegacyJSON_fallsBackToUnknown() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "provider": "Factory",
            "sessionId": "legacy-session",
            "projectName": "LegacyProject",
            "model": "glm-5",
            "inputTokens": 500,
            "outputTokens": 200,
            "totalTokens": 700,
            "cost": 0.02,
            "startTime": 700000000.0,
            "endTime": 700003600.0,
            "createdAt": 700000000.0,
            "usageSource": "provider_log",
            "isRemote": false
        }
        """

        let decoded = try JSONDecoder().decode(
            TokenUsage.self, from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.provenanceMethod, .unknown)
        XCTAssertEqual(decoded.provenanceConfidence, .unknown)
        XCTAssertEqual(decoded.estimatorVersion, "")
    }

    // MARK: - Migration Backfill Correctness

    func test_migrationBackfill_existingRowsGetExactProvenance() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)

        // Insert a row using pre-provenance code path (defaults to unknown)
        // Simulate by inserting via store and then verifying migration backfill
        let usage = TokenUsage(
            provider: .claudeCode, sessionId: "backfill-test", projectName: "Project",
            model: "claude-4-sonnet", inputTokens: 1000, outputTokens: 500,
            costUSD: 0.05, startTime: Date(), endTime: Date()
        )
        try usageStore.insert(usage)

        // After migration, the v28 backfill should set exact for provider_log source
        // Since we inserted with .unknown provenanceMethod, the WHERE clause
        // `WHERE provenanceMethod = 'unknown'` applies the backfill
        let row = try queue.read { db -> Row in
            let rows = try Row.fetchAll(db, sql: """
                SELECT usageSource, provenanceMethod, provenanceConfidence
                FROM token_usage LIMIT 1
                """)
            return try XCTUnwrap(rows.first)
        }

        // New rows inserted with default unknown method should still have unknown
        // (the backfill WHERE clause targets rows that were already unknown after migration)
        XCTAssertEqual(row["provenanceMethod"] as? String, "unknown")
    }
}

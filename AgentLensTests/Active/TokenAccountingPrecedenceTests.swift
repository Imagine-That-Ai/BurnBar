import XCTest
import GRDB
@testable import OpenBurnBar

/// Tests for canonical precedence and local upsert guards.
///
/// Verifies:
/// - VAL-PERSIST-002: Exact rows cannot be downgraded by lower-confidence writes
/// - VAL-PERSIST-003: Late exact arrivals promote existing estimated rows deterministically
/// - VAL-TOKEN-007: Idempotent local usage upsert by dedupe key (no duplicates)
@MainActor
final class TokenAccountingPrecedenceTests: XCTestCase {

    private func makeUsageStore(_ queue: DatabaseQueue) -> UsageStore {
        UsageStore(dbQueue: queue)
    }

    private func fetchCanonicalRow(queue: DatabaseQueue, sessionId: String) throws -> Row? {
        try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM token_usage 
                WHERE sessionId = ? 
                ORDER BY startTime DESC LIMIT 1
                """, arguments: [sessionId])
        }
    }

    private func countCanonicalRows(queue: DatabaseQueue, sessionId: String) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM token_usage 
                WHERE sessionId = ?
                """, arguments: [sessionId]) ?? 0
        }
    }

    // MARK: - VAL-PERSIST-002: Exact rows cannot be downgraded

    func test_exactRow_isNotDowngradedByLowerConfidenceEstimate() throws {
        // Given: an exact row already exists
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "exact-downgrade-test-1"
        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "ExactProject",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreationTokens: 100,
            cacheReadTokens: 200,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(exactUsage)

        // When: a lower-confidence estimate tries to overwrite
        let estimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "EstimateProject",
            model: "claude-4-sonnet",
            inputTokens: 2000, // different values
            outputTokens: 1000,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 0.10,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try store.insert(estimateUsage)

        // Then: exact row is preserved (not downgraded)
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)

        XCTAssertEqual(inputTokens, 1000, "Exact row must not be downgraded by estimate")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row?["provenanceMethod"] as? String, "provider_log")
        XCTAssertEqual(row?["projectName"] as? String, "ExactProject")
    }

    func test_exactRow_isNotDowngraded_evenWithDifferentValues() throws {
        // Given: an exact row exists
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "exact-downgrade-test-2"
        let exactUsage = TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: "FactoryProject",
            model: "glm-5",
            inputTokens: 5000,
            outputTokens: 2000,
            costUSD: 0.15,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(exactUsage)

        // When: a derived-exact tries to overwrite with different values
        let derivedUsage = TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: "DifferentProject",
            model: "glm-5",
            inputTokens: 8000,
            outputTokens: 3000,
            costUSD: 0.25,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .billingAPI,
            provenanceConfidence: .derivedExact,
            estimatorVersion: ""
        )
        try store.insert(derivedUsage)

        // Then: derivedExact should still win (higher than estimate but lower than exact... wait)
        // derivedExact has precedence 3, exact has precedence 4
        // So exact > derivedExact, meaning derived should NOT replace exact
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)

        XCTAssertEqual(inputTokens, 5000, "Exact row must not be downgraded")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "exact")
    }

    func test_highConfidenceEstimate_isNotDowngradedByLowConfidence() throws {
        // Given: a high-confidence estimate row
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "hce-downgrade-test"
        let hceUsage = TokenUsage(
            provider: .cursor,
            sessionId: sessionId,
            projectName: "CursorProject",
            model: "gpt-4",
            inputTokens: 3000,
            outputTokens: 1000,
            costUSD: 0.08,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v2"
        )
        try store.insert(hceUsage)

        // When: a low-confidence estimate tries to overwrite
        let lceUsage = TokenUsage(
            provider: .cursor,
            sessionId: sessionId,
            projectName: "CursorProject2",
            model: "gpt-4",
            inputTokens: 5000,
            outputTokens: 2000,
            costUSD: 0.15,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "coarse-v1"
        )
        try store.insert(lceUsage)

        // Then: high-confidence estimate is preserved
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)

        XCTAssertEqual(inputTokens, 3000, "High-confidence estimate must not be downgraded")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "high_confidence_estimate")
    }

    // MARK: - VAL-PERSIST-003: Late exact arrivals upgrade prior estimates

    func test_lateExactPromotesEstimatedCanonicalRow() throws {
        // Given: an estimated row exists
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "exact-upgrade-test-1"
        let estimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try store.insert(estimateUsage)

        // When: exact data arrives later
        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.09,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(exactUsage)

        // Then: canonical row is upgraded to exact
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)

        XCTAssertEqual(inputTokens, 2000, "Late exact must upgrade estimated row")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row?["provenanceMethod"] as? String, "provider_log")
    }

    func test_lateExactPromotesDerivedExactRow() throws {
        // Given: a derived-exact row exists
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "exact-upgrade-test-2"
        let derivedUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1500,
            outputTokens: 600,
            costUSD: 0.07,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .billingAPI,
            provenanceConfidence: .derivedExact,
            estimatorVersion: ""
        )
        try store.insert(derivedUsage)

        // When: true exact data arrives later
        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "ProjectUpdated",
            model: "claude-4-sonnet",
            inputTokens: 2500,
            outputTokens: 1000,
            costUSD: 0.12,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(exactUsage)

        // Then: canonical row is upgraded to exact (and projectName updated)
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)

        XCTAssertEqual(inputTokens, 2500, "Late exact must upgrade derived-exact row")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row?["projectName"] as? String, "ProjectUpdated")
    }

    func test_lateHighConfidencePromotesLowConfidenceEstimate() throws {
        // Given: a low-confidence estimate exists
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "hce-upgrade-test"
        let lowUsage = TokenUsage(
            provider: .cursor,
            sessionId: sessionId,
            projectName: "CursorProject",
            model: "gpt-4",
            inputTokens: 1000,
            outputTokens: 400,
            costUSD: 0.03,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "coarse-v1"
        )
        try store.insert(lowUsage)

        // When: high-confidence estimate arrives
        let highUsage = TokenUsage(
            provider: .cursor,
            sessionId: sessionId,
            projectName: "CursorProject",
            model: "gpt-4",
            inputTokens: 1500,
            outputTokens: 600,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v2"
        )
        try store.insert(highUsage)

        // Then: row is promoted to high-confidence
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)

        XCTAssertEqual(inputTokens, 1500, "Late high-confidence must promote low-confidence row")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "high_confidence_estimate")
    }

    // MARK: - VAL-TOKEN-007: Idempotent local upsert (no duplicates)

    func test_localReingest_sameLogicalKey_remainsDuplicateFree() throws {
        // Given: a usage row exists
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "dedupe-test-1"
        let originalUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(originalUsage)

        // When: same logical key is re-ingested
        let reingestUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000, // same values
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(reingestUsage)

        // Then: no duplicates created
        let count = try countCanonicalRows(queue: queue, sessionId: sessionId)
        XCTAssertEqual(count, 1, "Re-ingest must not create duplicate rows")

        // And the row is still there
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        XCTAssertNotNil(row, "Canonical row must still exist")
    }

    func test_localReingest_differentConfidence_equalPrecedence_updatesInPlace() throws {
        // Given: a usage row with unknown confidence
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "dedupe-test-2"
        let originalUsage = TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: "Project",
            model: "glm-5",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.06,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .unknown,
            provenanceConfidence: .unknown,
            estimatorVersion: ""
        )
        try store.insert(originalUsage)

        // When: same key is re-ingested with same confidence but updated values
        let reingestUsage = TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: "Project",
            model: "glm-5",
            inputTokens: 2500, // different values
            outputTokens: 1000,
            costUSD: 0.08,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact, // higher confidence - should upgrade
            estimatorVersion: ""
        )
        try store.insert(reingestUsage)

        // Then: still one row, but updated to exact
        let count = try countCanonicalRows(queue: queue, sessionId: sessionId)
        XCTAssertEqual(count, 1, "Re-ingest must not create duplicate rows")

        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)
        XCTAssertEqual(inputTokens, 2500, "Row should be updated")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "exact")
    }

    // MARK: - Precedence Ordering Invariants

    func test_precedence_exactIsHighest() {
        XCTAssertTrue(UsageProvenanceConfidence.exact > .derivedExact)
        XCTAssertTrue(UsageProvenanceConfidence.exact > .highConfidenceEstimate)
        XCTAssertTrue(UsageProvenanceConfidence.exact > .lowConfidenceEstimate)
        XCTAssertTrue(UsageProvenanceConfidence.exact > .unknown)
    }

    func test_precedence_derivedExactIsSecondHighest() {
        XCTAssertTrue(UsageProvenanceConfidence.derivedExact > .highConfidenceEstimate)
        XCTAssertTrue(UsageProvenanceConfidence.derivedExact > .lowConfidenceEstimate)
        XCTAssertTrue(UsageProvenanceConfidence.derivedExact > .unknown)
    }

    func test_precedence_highConfidenceEstimateIsThird() {
        XCTAssertTrue(UsageProvenanceConfidence.highConfidenceEstimate > .lowConfidenceEstimate)
        XCTAssertTrue(UsageProvenanceConfidence.highConfidenceEstimate > .unknown)
    }

    func test_precedence_lowConfidenceEstimateIsFourth() {
        XCTAssertTrue(UsageProvenanceConfidence.lowConfidenceEstimate > .unknown)
    }

    // MARK: - Source Device ID Handling

    func test_upsert_withDifferentSourceDeviceId_createsSeparateRows() throws {
        // Given: a usage row from device A
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "device-test-1"
        let deviceAUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            sourceDeviceId: "device-A",
            sourceDeviceName: "MacBook Pro A",
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(deviceAUsage)

        // When: same session from device B
        let deviceBUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1500,
            outputTokens: 700,
            costUSD: 0.08,
            startTime: Date(),
            endTime: Date(),
            sourceDeviceId: "device-B",
            sourceDeviceName: "MacBook Pro B",
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(deviceBUsage)

        // Then: both rows exist (different source device = different canonical key)
        let count = try countCanonicalRows(queue: queue, sessionId: sessionId)
        XCTAssertEqual(count, 2, "Different source devices should create separate rows")
    }

    func test_upsert_withNullSourceDeviceId_conflictsWithEmptySourceDeviceId() throws {
        // The conflict target is COALESCE(sourceDeviceId, '')
        // So null and empty string should be treated as the same
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "null-device-test"

        // First insert with nil sourceDeviceId
        let nilDeviceUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            sourceDeviceId: nil,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(nilDeviceUsage)

        // Second insert with empty string sourceDeviceId
        let emptyDeviceUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1500,
            outputTokens: 700,
            costUSD: 0.08,
            startTime: Date(),
            endTime: Date(),
            sourceDeviceId: "", // empty string
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try store.insert(emptyDeviceUsage)

        // Then: only one row exists (nil and empty are same conflict key)
        let count = try countCanonicalRows(queue: queue, sessionId: sessionId)
        XCTAssertEqual(count, 1, "nil and empty sourceDeviceId should conflict")
    }

    // MARK: - Equal Confidence Updates

    func test_equalConfidence_differentValues_updatesCorrectly() throws {
        // Given: a row with high-confidence estimate
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let store = makeUsageStore(queue)

        let sessionId = "equal-conf-test"
        let originalUsage = TokenUsage(
            provider: .cursor,
            sessionId: sessionId,
            projectName: "Project",
            model: "gpt-4",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v2"
        )
        try store.insert(originalUsage)

        // When: another high-confidence estimate with different values
        let updatedUsage = TokenUsage(
            provider: .cursor,
            sessionId: sessionId,
            projectName: "Project",
            model: "gpt-4",
            inputTokens: 2000, // different
            outputTokens: 1000, // different
            costUSD: 0.10, // different
            startTime: Date(),
            endTime: Date(),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate, // same confidence
            estimatorVersion: "cjk-aware-v2"
        )
        try store.insert(updatedUsage)

        // Then: row is updated
        let row = try fetchCanonicalRow(queue: queue, sessionId: sessionId)
        let inputTokens = (row?["inputTokens"] as? Int) ?? Int(row?["inputTokens"] as? Int64 ?? 0)

        XCTAssertEqual(inputTokens, 2000, "Equal confidence with different values should update")
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "high_confidence_estimate")
    }
}

import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Validates that FirestoreRepository correctly normalizes Cloud Function / desktop-sync
/// Firestore document shapes into the Codable types the mobile app expects.
///
/// These tests use the real `decodeUsageRollup`, `decodeWithDocID`, and `normalizeRollupData`
/// methods from FirestoreRepository (via @testable import) so there is no duplicated
/// normalization logic that could drift from production.
final class FirestoreNormalizationTests: XCTestCase {

    // The repository instance is only used to access the nonisolated decode helpers.
    // No Firestore network calls are made in these tests.
    private let repo = FirestoreRepository()

    // MARK: - Raw Firestore document shapes (exactly as written by Cloud Functions / desktop sync)

    static let cloudFunctionRollupDoc: [String: Any] = [
        "today": 5000,
        "7d": 35000,
        "30d": 150000,
        "90d": 450000,
        "all_time": 1000000,
        "totals": [
            "requests": 42,
            "tokens": 5000,
            "costUsd": 0.25
        ],
        "providerSummaries": [
            [
                "provider": "minimax",
                "totalRequests": 20,
                "totalTokens": 2500,
                "totalCost": 0.12
            ],
            [
                "provider": "claude-code",
                "totalRequests": 22,
                "totalTokens": 2500
            ]
        ],
        "modelSummaries": [
            [
                "model": "abab6.5",
                "provider": "minimax",
                "requests": 20,
                "tokens": 2500,
                "cost": 0.12
            ]
        ],
        "deviceSummaries": [
            [
                "deviceId": "mac-1",
                "requests": 42,
                "tokens": 5000
            ]
        ],
        "dailyPoints": [
            "2026-05-01": 2500,
            "2026-05-02": 2500
        ],
        "computedAt": "2026-05-02T12:00:00Z",
        "schemaVersion": 1
    ]

    /// Shape produced by the desktop `UsageSyncService.encodeUsage`.
    /// The desktop writes `"id"` as a UUID string; normalization must NOT overwrite it.
    static let desktopUsageEvent: [String: Any] = [
        "id": "550e8400-e29b-41d4-a716-446655440000",
        "deviceId": "mac-1",
        "provider": "claude-code",
        "sessionId": "sess-abc",
        "projectName": "BurnBar",
        "model": "claude-sonnet-4-20250514",
        "inputTokens": 100,
        "outputTokens": 50,
        "cacheCreationTokens": 0,
        "cacheReadTokens": 0,
        "reasoningTokens": 0,
        "usageSource": "provider_log",
        "totalTokens": 150,
        "cost": 0.01,
        "startTime": 799372800.0,
        "endTime": 799372860.0,
        "updatedAt": NSNull()
    ]

    static let cloudFunctionQuotaDoc: [String: Any] = [
        "provider": "minimax",
        "sourceKind": "provider",
        "sourceId": "default",
        "fetchedAt": "2026-05-02T12:00:00Z",
        "source": "MiniMax Dashboard",
        "confidence": "high",
        "managementURL": "https://platform.minimax.io",
        "buckets": [
            [
                "name": "Tokens",
                "used": 75000.0,
                "limit": 100000.0,
                "remaining": 25000.0,
                "window": "monthly"
            ]
        ],
        "schemaVersion": 1,
        "updatedAt": "2026-05-02T12:00:00Z"
    ]

    static let cloudFunctionConnectionDoc: [String: Any] = [
        "provider": "minimax",
        "status": "connected",
        "lastValidatedAt": "2026-05-02T12:00:00Z",
        "lastRefreshAt": "2026-05-02T12:00:00Z",
        "credentialKind": "token",
        "redactedLabel": "minimax_***abcd",
        "schemaVersion": 1
    ]

    // MARK: - CRITICAL: decodeWithDocID must NOT overwrite existing `id`

    func test_decodeWithDocID_preservesExistingID() throws {
        let usage = repo.decodeWithDocID(
            TokenUsage.self,
            from: Self.desktopUsageEvent,
            docID: "mac-1_different-uuid"
        )
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"),
                       "decodeWithDocID must NOT overwrite existing UUID id with doc ID")
        XCTAssertEqual(usage?.provider, .claudeCode)
        XCTAssertEqual(usage?.totalTokens, 150)
    }

    func test_decodeWithDocID_injectsIDWhenMissing() throws {
        var data = Self.cloudFunctionQuotaDoc
        // Cloud Function does not write an `id` field
        XCTAssertNil(data["id"])
        let snap = repo.decodeWithDocID(
            ProviderQuotaSnapshot.self,
            from: data,
            docID: "minimax_default"
        )
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.id, "minimax_default")
    }

    // MARK: - Rollup decoding (proves normalization is required)

    func testRawRollupDocFailsWithoutNormalization() throws {
        let jsonData = try JSONSerialization.data(withJSONObject: Self.cloudFunctionRollupDoc)
        XCTAssertThrowsError(try JSONDecoder().decode(UsageRollupDoc.self, from: jsonData),
                             "Raw Cloud Function rollup should fail to decode without normalization")
    }

    func testRollupProviderSummaryRequiresID() throws {
        let summaryJSON: [String: Any] = ["provider": "minimax", "totalRequests": 20, "totalTokens": 2500]
        let jsonData = try JSONSerialization.data(withJSONObject: summaryJSON)
        XCTAssertThrowsError(try JSONDecoder().decode(RollupProviderSummary.self, from: jsonData))
    }

    // MARK: - Normalized decoding using real FirestoreRepository methods

    func testNormalizedRollupDecodesSuccessfully() throws {
        let rollup = repo.decodeUsageRollup(from: Self.cloudFunctionRollupDoc, docID: "today")
        XCTAssertNotNil(rollup)
        XCTAssertEqual(rollup?.windowKey, .today)
        XCTAssertEqual(rollup?.totals.requests, 42)
        XCTAssertEqual(rollup?.totals.tokens, 5000)
        XCTAssertEqual(rollup?.totals.costUsd, 0.25)
        XCTAssertEqual(rollup?.providerSummaries.count, 2)
        XCTAssertEqual(rollup?.modelSummaries.count, 1)
        XCTAssertEqual(rollup?.deviceSummaries.count, 1)
        XCTAssertEqual(rollup?.dailyPoints.count, 2)
    }

    func testNormalizedRollupProviderSummariesHaveIDs() throws {
        let rollup = repo.decodeUsageRollup(from: Self.cloudFunctionRollupDoc, docID: "today")
        XCTAssertNotNil(rollup)
        for summary in rollup!.providerSummaries {
            XCTAssertFalse(summary.id.isEmpty)
        }
    }

    func testNormalizedRollupDailyPointsDatesAreCorrect() throws {
        let rollup = repo.decodeUsageRollup(from: Self.cloudFunctionRollupDoc, docID: "today")
        XCTAssertNotNil(rollup)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let expectedMay1 = formatter.date(from: "2026-05-01")!

        for point in rollup!.dailyPoints {
            if point.id == "2026-05-01" {
                XCTAssertEqual(point.date.timeIntervalSinceReferenceDate,
                               expectedMay1.timeIntervalSinceReferenceDate,
                               accuracy: 1.0,
                               "dailyPoints date should decode to 2026, not a future year")
            }
        }
    }

    func testNormalizedQuotaSnapshotDecodes() throws {
        let snap = repo.decodeWithDocID(
            ProviderQuotaSnapshot.self,
            from: Self.cloudFunctionQuotaDoc,
            docID: "minimax_default"
        )
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.id, "minimax_default")
        XCTAssertEqual(snap?.provider, "minimax")
        XCTAssertEqual(snap?.confidence, .high)
        XCTAssertEqual(snap?.buckets.count, 1)
    }

    func testNormalizedProviderConnectionDecodes() throws {
        let conn = repo.decodeWithDocID(
            ProviderConnectionDoc.self,
            from: Self.cloudFunctionConnectionDoc,
            docID: "minimax"
        )
        XCTAssertNotNil(conn)
        XCTAssertEqual(conn?.id, "minimax")
        XCTAssertEqual(conn?.status, .connected)
        XCTAssertEqual(conn?.credentialKind, .token)
    }

    // MARK: - All window keys

    func testAllWindowKeysParseCorrectly() {
        let keys: [(String, RollupWindowKey)] = [
            ("today", .today), ("7d", .sevenDays), ("30d", .thirtyDays),
            ("90d", .ninetyDays), ("all_time", .allTime)
        ]
        for (raw, expected) in keys {
            let rollup = repo.decodeUsageRollup(from: Self.cloudFunctionRollupDoc, docID: raw)
            XCTAssertNotNil(rollup, "Failed for window: \(raw)")
            XCTAssertEqual(rollup?.windowKey, expected, "Window \(raw) → \(expected)")
        }
    }

    // MARK: - Empty rollup

    func testEmptyRollupNormalization() throws {
        let empty: [String: Any] = [
            "totals": ["requests": 0, "tokens": 0, "costUsd": 0],
            "providerSummaries": [], "modelSummaries": [], "deviceSummaries": [],
            "dailyPoints": [:], "computedAt": "2026-05-02T12:00:00Z", "schemaVersion": 1
        ]
        let rollup = repo.decodeUsageRollup(from: empty, docID: "today")
        XCTAssertNotNil(rollup)
        XCTAssertEqual(rollup?.totals.tokens, 0)
        XCTAssertTrue(rollup?.dailyPoints.isEmpty ?? false)
    }

    // MARK: - deviceId → sourceDeviceId normalization

    func testUsageEventNormalizesDeviceIdToSourceDeviceId() throws {
        let usage = repo.decodeWithDocID(
            TokenUsage.self,
            from: Self.desktopUsageEvent,
            docID: "mac-1_test-uuid"
        )
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.sourceDeviceId, "mac-1",
                       "desktop writes 'deviceId', mobile expects 'sourceDeviceId'")
    }

    // MARK: - sanitizeForJSON

    func test_sanitizeForJSON_convertsTimestampToDouble() {
        let now = Date()
        let ts = Timestamp(date: now)
        let result = repo.sanitizeForJSON(ts)
        XCTAssertTrue(result is Double)
        let doubleVal = result as! Double
        XCTAssertEqual(doubleVal, now.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    func test_sanitizeForJSON_convertsISO8601StringToDouble() {
        let isoStr = "2026-05-02T12:00:00Z"
        let result = repo.sanitizeForJSON(isoStr)
        XCTAssertTrue(result is Double, "ISO 8601 string should be converted to Double for Date decoding")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedDate = formatter.date(from: isoStr)!
        XCTAssertEqual(result as! Double, expectedDate.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    func test_sanitizeForJSON_convertsISO8601WithFractionalSeconds() {
        let isoStr = "2026-05-02T12:00:00.123Z"
        let result = repo.sanitizeForJSON(isoStr)
        XCTAssertTrue(result is Double, "ISO 8601 with fractional seconds should convert")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedDate = formatter.date(from: isoStr)!
        XCTAssertEqual(result as! Double, expectedDate.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    func test_sanitizeForJSON_passesThroughRegularString() {
        let regular = "minimax"
        let result = repo.sanitizeForJSON(regular)
        XCTAssertTrue(result is String)
        XCTAssertEqual(result as! String, "minimax")
    }

    func test_sanitizeForJSON_passesThroughURLString() {
        let url = "https://platform.minimax.io"
        let result = repo.sanitizeForJSON(url)
        XCTAssertTrue(result is String, "URLs should not be mistaken for ISO dates")
        XCTAssertEqual(result as! String, url)
    }

    func test_sanitizeForJSON_passesThroughNSNull() {
        let result = repo.sanitizeForJSON(NSNull())
        XCTAssertTrue(result is NSNull)
    }

    func test_sanitizeForJSON_recursivelyConvertsDict() {
        let now = Date()
        let ts = Timestamp(date: now)
        let dict: [String: Any] = [
            "name": "test",
            "timestamp": ts,
            "isoDate": "2026-05-02T12:00:00Z",
            "nested": ["inner": ts]
        ]
        let result = repo.sanitizeForJSON(dict) as! [String: Any]
        XCTAssertEqual(result["name"] as! String, "test")
        XCTAssertTrue(result["timestamp"] is Double)
        XCTAssertTrue(result["isoDate"] is Double)
        let nested = result["nested"] as! [String: Any]
        XCTAssertTrue(nested["inner"] is Double)
    }

    func test_sanitizeForJSON_recursivelyConvertsArray() {
        let now = Date()
        let ts = Timestamp(date: now)
        let arr: [Any] = [ts, "hello", NSNull(), "2026-05-02T12:00:00Z"]
        let result = repo.sanitizeForJSON(arr) as! [Any]
        XCTAssertTrue(result[0] is Double)
        XCTAssertEqual(result[1] as! String, "hello")
        XCTAssertTrue(result[2] is NSNull)
        XCTAssertTrue(result[3] is Double)
    }

    // MARK: - ISO date strings in documents decode correctly

    func test_rollupComputedAtDecodesFromISOString() throws {
        let rollup = repo.decodeUsageRollup(from: Self.cloudFunctionRollupDoc, docID: "today")
        XCTAssertNotNil(rollup)
        // Verify computedAt decoded from the ISO string "2026-05-02T12:00:00Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.date(from: "2026-05-02T12:00:00Z")!
        XCTAssertEqual((rollup?.computedAt.timeIntervalSinceReferenceDate ?? 0),
                       expected.timeIntervalSinceReferenceDate,
                       accuracy: 0.001,
                       "computedAt should decode from ISO 8601 string")
    }

    func test_quotaSnapshotDateFieldsDecodeFromISOStrings() throws {
        let snap = repo.decodeWithDocID(
            ProviderQuotaSnapshot.self,
            from: Self.cloudFunctionQuotaDoc,
            docID: "minimax_default"
        )
        XCTAssertNotNil(snap)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedFetched = formatter.date(from: "2026-05-02T12:00:00Z")!
        let expectedUpdated = formatter.date(from: "2026-05-02T12:00:00Z")!
        XCTAssertEqual((snap?.fetchedAt.timeIntervalSinceReferenceDate ?? 0),
                       expectedFetched.timeIntervalSinceReferenceDate,
                       accuracy: 0.001,
                       "fetchedAt should decode from ISO 8601 string")
        XCTAssertEqual((snap?.updatedAt.timeIntervalSinceReferenceDate ?? 0),
                       expectedUpdated.timeIntervalSinceReferenceDate,
                       accuracy: 0.001,
                       "updatedAt should decode from ISO 8601 string")
    }

    func test_connectionDocDateFieldsDecodeFromISOStrings() throws {
        let conn = repo.decodeWithDocID(
            ProviderConnectionDoc.self,
            from: Self.cloudFunctionConnectionDoc,
            docID: "minimax"
        )
        XCTAssertNotNil(conn)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.date(from: "2026-05-02T12:00:00Z")!
        XCTAssertEqual((conn?.lastValidatedAt?.timeIntervalSinceReferenceDate ?? 0),
                       expected.timeIntervalSinceReferenceDate,
                       accuracy: 0.001,
                       "lastValidatedAt should decode from ISO 8601 string")
        XCTAssertEqual((conn?.lastRefreshAt?.timeIntervalSinceReferenceDate ?? 0),
                       expected.timeIntervalSinceReferenceDate,
                       accuracy: 0.001,
                       "lastRefreshAt should decode from ISO 8601 string")
    }
}


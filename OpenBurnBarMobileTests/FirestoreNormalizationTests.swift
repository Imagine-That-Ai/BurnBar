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
@MainActor
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

    static let desktopSyncedQuotaDoc: [String: Any] = [
        "provider": "Cursor",
        "providerID": "cursor",
        "sourceKind": "officialAPI",
        "sourceId": "default",
        "sourceID": "default",
        "fetchedAt": "2026-05-04T05:59:44Z",
        "source": "officialAPI",
        "confidence": "exact",
        "buckets": [
            [
                "name": "cursor-plan",
                "used": 25,
                "limit": 100,
                "remaining": 75,
                "window": "monthly",
                "meta": [
                    "label": "Plan",
                    "unit": "requests",
                    "isEstimated": false,
                    "priority": 1,
                    "resetsAt": "2026-05-04T06:04:57.701Z"
                ]
            ]
        ],
        "schemaVersion": 2,
        "updatedAt": "2026-05-04T06:04:57.701Z"
    ]

    static let desktopStylePercentQuotaDoc: [String: Any] = [
        "provider": "Claude Code",
        "providerID": "claude-code",
        "sourceKind": "localCLI",
        "sourceId": "default",
        "sourceID": "default",
        "fetchedAt": "2026-05-12T00:16:44Z",
        "source": "localCLI",
        "confidence": "exact",
        "statusMessage": "Quota captured from Claude Code's local status line JSON bridge.",
        "buckets": [
            [
                "key": "claude-five_hour",
                "label": "5-hour window",
                "windowKind": "rollingHours",
                "usedValue": 18.0,
                "remainingValue": 82.0,
                "usedPercent": 18.0,
                "unit": "percent",
                "isEstimated": false
            ],
            [
                "key": "claude-seven_day",
                "label": "7-day window",
                "windowKind": "rollingDays",
                "usedValue": 52.0,
                "remainingValue": 48.0,
                "usedPercent": 52.0,
                "unit": "percent",
                "isEstimated": false
            ]
        ],
        "schemaVersion": 2,
        "updatedAt": "2026-05-12T00:17:00Z"
    ]

    static let zeroLimitPercentQuotaDoc: [String: Any] = [
        "provider": "Codex",
        "providerID": "codex",
        "sourceKind": "localSession",
        "sourceId": "default",
        "fetchedAt": "2026-05-12T00:16:55Z",
        "source": "Codex",
        "confidence": "high",
        "buckets": [
            [
                "name": "codex-primary",
                "used": 37.0,
                "limit": 0.0,
                "remaining": 63.0,
                "window": "rollingHours",
                "meta": [
                    "label": "5-hour window",
                    "unit": "percent",
                    "usedPercent": "37.00"
                ]
            ]
        ],
        "schemaVersion": 2,
        "updatedAt": "2026-05-12T00:17:00Z"
    ]

    static let miniMaxUnlimitedQuotaDoc: [String: Any] = [
        "provider": "minimax",
        "providerID": "minimax",
        "sourceKind": "provider",
        "sourceId": "minimax_default",
        "fetchedAt": "2026-05-12T01:40:10Z",
        "source": "provider",
        "confidence": "high",
        "accountID": "minimax_default",
        "buckets": [
            [
                "name": "MiniMax-M*",
                "used": 0,
                "limit": -1,
                "remaining": -1,
                "window": "account"
            ]
        ],
        "schemaVersion": 2,
        "updatedAt": "2026-05-12T01:40:10Z"
    ]

    static let liveBackfilledQuotaDocs: [(id: String, data: [String: Any])] = [
        (
            id: "claude-code_unattributed_mac-local-cache",
            data: canonicalQuotaDoc(provider: "claude-code", providerID: "claude-code", sourceKind: "localCLI", source: "localCLI", bucketName: "claude-five_hour", label: "5-hour window", unit: "percent", used: 21, limit: 100, remaining: 79)
        ),
        (
            id: "codex_unattributed_mac-local-cache",
            data: canonicalQuotaDoc(provider: "codex", providerID: "codex", sourceKind: "localSession", source: "localSession", bucketName: "codex-primary", label: "5-hour window", unit: "percent", used: 39, limit: 100, remaining: 61)
        ),
        (
            id: "cursor_unattributed_mac-local-cache",
            data: canonicalQuotaDoc(provider: "cursor", providerID: "cursor", sourceKind: "officialAPI", source: "officialAPI", bucketName: "cursor-plan", label: "Included usage", unit: "currency", used: 400, limit: 400, remaining: 0, window: "monthly")
        ),
        (
            id: "factory_unattributed_mac-local-cache",
            data: canonicalQuotaDoc(provider: "factory", providerID: "factory", sourceKind: "localSession", source: "localSession", bucketName: "factory-7d", label: "7-day rolling", unit: "tokens", used: 253_998_585, limit: 200_000_000, remaining: 0, window: "rollingDays")
        ),
        (
            id: "minimax_unattributed_mac-local-cache",
            data: canonicalQuotaDoc(provider: "minimax", providerID: "minimax", sourceKind: "officialAPI", source: "officialAPI", bucketName: "minimax-5-hour-window-minimax-m", label: "5-hour window", unit: "requests", used: 0, limit: 4_500, remaining: 4_500, window: "rollingHours")
        ),
        (
            id: "ollama_unattributed_mac-local-cache",
            data: canonicalQuotaDoc(provider: "ollama", providerID: "ollama", sourceKind: "officialAPI", source: "officialAPI", bucketName: "ollama-cloud-session", label: "Cloud 5-hour window", unit: "percent", used: 1.2, limit: 100, remaining: 98.8, window: "rollingHours")
        ),
        (
            id: "openai_openai-team_api",
            data: canonicalQuotaDoc(provider: "OpenAI", providerID: "openai", sourceKind: "officialAPI", source: "usage-api", bucketName: "Monthly budget", label: "Monthly budget", unit: "currency", used: 218, limit: 500, remaining: 282, window: "monthly")
        ),
        (
            id: "zai_unattributed_mac-local-cache",
            data: canonicalQuotaDoc(provider: "zai", providerID: "zai", sourceKind: "officialAPI", source: "officialAPI", bucketName: "zai-token-usage-5-hour-limits", label: "Token usage (5-hour)", unit: "percent", used: 17, limit: 100, remaining: 83, window: "custom")
        )
    ]

    private static func canonicalQuotaDoc(
        provider: String,
        providerID: String,
        sourceKind: String,
        source: String,
        bucketName: String,
        label: String,
        unit: String,
        used: Double,
        limit: Double,
        remaining: Double,
        window: String = "rollingHours"
    ) -> [String: Any] {
        [
            "provider": provider,
            "providerID": providerID,
            "sourceKind": sourceKind,
            "sourceId": "mac-local-cache",
            "sourceID": "mac-local-cache",
            "fetchedAt": "2026-05-12T00:40:10Z",
            "source": source,
            "confidence": "exact",
            "buckets": [
                [
                    "name": bucketName,
                    "used": used,
                    "limit": limit,
                    "remaining": remaining,
                    "window": window,
                    "meta": [
                        "label": label,
                        "unit": unit,
                        "isEstimated": "false"
                    ]
                ]
            ],
            "schemaVersion": 2,
            "updatedAt": "2026-05-12T00:40:10Z"
        ]
    }

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
        let data = Self.cloudFunctionQuotaDoc
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

    func testRollupProviderSummaryDecodesLegacyProviderIDFallback() throws {
        let summaryJSON: [String: Any] = ["provider": "minimax", "totalRequests": 20, "totalTokens": 2500]
        let jsonData = try JSONSerialization.data(withJSONObject: summaryJSON)
        let summary = try JSONDecoder().decode(RollupProviderSummary.self, from: jsonData)
        XCTAssertEqual(summary.id, "minimax")
        XCTAssertEqual(summary.providerID, ProviderID(rawValue: "minimax"))
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
        let snap = repo.decodeQuotaSnapshot(
            from: Self.cloudFunctionQuotaDoc,
            docID: "minimax_default"
        )
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.id, "minimax_default")
        XCTAssertEqual(snap?.provider, "minimax")
        XCTAssertEqual(snap?.confidence, .high)
        XCTAssertEqual(snap?.buckets.count, 1)
    }

    func testDesktopSyncedQuotaSnapshotDecodesThroughProductionNormalizer() throws {
        let snap = repo.decodeQuotaSnapshot(
            from: Self.desktopSyncedQuotaDoc,
            docID: "cursor_unattributed_default"
        )

        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.id, "cursor_unattributed_default")
        XCTAssertEqual(snap?.provider, "Cursor")
        XCTAssertEqual(snap?.providerID, ProviderID(rawValue: "cursor"))
        XCTAssertEqual(snap?.sourceKind, .officialAPI)
        XCTAssertEqual(snap?.confidence, .high)
        XCTAssertEqual(snap?.buckets.first?.meta?["isEstimated"], "false")
        XCTAssertEqual(snap?.buckets.first?.meta?["priority"], "1")
        XCTAssertEqual(snap?.buckets.first?.meta?["resetsAt"], "2026-05-04T06:04:57.701Z")
        // Resolved Date must round-trip through the bucket-level field on
        // the shared model — that's the contract the iOS / Android details
        // views rely on to render the reset row.
        XCTAssertNotNil(snap?.buckets.first?.resetsAt,
                        "legacy meta-only docs must still surface resetsAt on the bucket")
    }

    /// Bug B regression. Firestore-native docs carry `resetsAt` as a
    /// top-level Timestamp on the bucket; `sanitizeForJSON` flattens that
    /// to a `timeIntervalSinceReferenceDate` Double. The normalizer used
    /// to throw the field away — every iOS reset rendered nil — so this
    /// pins that the top-level path is carried through to the decoded
    /// model.
    func testTopLevelResetsAtTimestampSurvivesNormalizer() throws {
        let resetDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let doc: [String: Any] = [
            "provider": "claude-code",
            "providerID": "claude-code",
            "sourceKind": "officialAPI",
            "sourceId": "default",
            "fetchedAt": "2026-05-12T12:00:00Z",
            "source": "officialAPI",
            "confidence": "high",
            "buckets": [
                [
                    "name": "5-hour window",
                    "used": 50.0,
                    "limit": 100.0,
                    "remaining": 50.0,
                    "window": "rollingHours",
                    "resetsAt": resetDate.timeIntervalSinceReferenceDate
                ]
            ],
            "schemaVersion": 1,
            "updatedAt": "2026-05-12T12:00:00Z"
        ]

        let snap = repo.decodeQuotaSnapshot(from: doc, docID: "claude-code_default")

        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.buckets.first?.name, "5-hour window")
        XCTAssertEqual(
            snap?.buckets.first?.resetsAt?.timeIntervalSinceReferenceDate ?? 0,
            resetDate.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
    }

    /// Bug A regression. The Mac writer emits ISO 8601 with no fractional
    /// seconds; the first decoder version only accepted the fractional
    /// form. Verifies that meta-string fallback parses both shapes.
    func testLegacyMetaResetsAtWithoutFractionalSecondsParses() throws {
        let doc: [String: Any] = [
            "provider": "claude-code",
            "sourceKind": "officialAPI",
            "sourceId": "default",
            "fetchedAt": "2026-05-12T12:00:00Z",
            "source": "officialAPI",
            "confidence": "high",
            "buckets": [
                [
                    "name": "Weekly",
                    "used": 12.0, "limit": 50.0, "remaining": 38.0,
                    "window": "weekly",
                    "meta": [
                        "label": "Weekly", "unit": "requests",
                        "resetsAt": "2026-05-15T09:00:00Z"
                    ]
                ]
            ],
            "schemaVersion": 1,
            "updatedAt": "2026-05-12T12:00:00Z"
        ]

        let snap = repo.decodeQuotaSnapshot(from: doc, docID: "claude-code_legacy")
        XCTAssertNotNil(snap?.buckets.first?.resetsAt,
                        "non-fractional ISO 8601 in meta must still parse")
    }

    func testDesktopStyleQuotaBucketsNormalizeForMobileDisplay() throws {
        let snap = repo.decodeQuotaSnapshot(
            from: Self.desktopStylePercentQuotaDoc,
            docID: "claude-code_unattributed_default"
        )

        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.providerID, .claudeCode)
        XCTAssertEqual(snap?.buckets.count, 2)
        XCTAssertEqual(snap?.buckets.first?.name, "claude-five_hour")
        XCTAssertEqual(snap?.buckets.first?.limit, 100)
        XCTAssertEqual(snap?.buckets.first?.remaining, 82)
        XCTAssertEqual(snap?.buckets.first?.window, "rollingHours")
        XCTAssertEqual(snap?.buckets.first?.meta?["label"], "5-hour window")
        XCTAssertEqual(snap?.buckets.first?.meta?["unit"], "percent")
        XCTAssertNotNil(snap?.filteringToDisplayableQuotaSignal())
    }

    func testZeroLimitPercentQuotaBucketsNormalizeToPercentDenominator() throws {
        let snap = repo.decodeQuotaSnapshot(
            from: Self.zeroLimitPercentQuotaDoc,
            docID: "codex_unattributed_default"
        )

        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.providerID, .codex)
        XCTAssertEqual(snap?.buckets.first?.limit, 100)
        XCTAssertEqual(snap?.buckets.first?.used, 37)
        XCTAssertEqual(snap?.buckets.first?.remaining, 63)
        XCTAssertNotNil(snap?.filteringToDisplayableQuotaSignal())
    }

    func testUnlimitedProviderQuotaBucketsRemainDisplayableOnMobile() throws {
        let snap = repo.decodeQuotaSnapshot(
            from: Self.miniMaxUnlimitedQuotaDoc,
            docID: "minimax_minimax_default"
        )

        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.providerID, ProviderID(rawValue: "minimax"))
        XCTAssertEqual(snap?.buckets.first?.limit, 100)
        XCTAssertEqual(snap?.buckets.first?.used, 0)
        XCTAssertEqual(snap?.buckets.first?.remaining, 100)
        XCTAssertEqual(snap?.buckets.first?.meta?["unit"], "unlimited")
        XCTAssertEqual(snap?.buckets.first?.meta?["limitKind"], "unlimited")
        XCTAssertNotNil(snap?.filteringToDisplayableQuotaSignal())
    }

    func testLiveBackfilledQuotaDocsDecodeIntoMultipleVisibleProviders() throws {
        let visibleProviders = Self.liveBackfilledQuotaDocs.compactMap { fixture -> ProviderID? in
            repo.decodeQuotaSnapshot(from: fixture.data, docID: fixture.id)?
                .filteringToDisplayableQuotaSignal()?
                .providerID
        }

        XCTAssertEqual(
            Set(visibleProviders),
            Set([
                ProviderID.claudeCode,
                ProviderID.codex,
                ProviderID(rawValue: "cursor"),
                ProviderID(rawValue: "factory"),
                ProviderID(rawValue: "minimax"),
                ProviderID(rawValue: "ollama"),
                ProviderID.openAI,
                ProviderID(rawValue: "zai")
            ])
        )
    }

    func testOpenAIBudgetQuotaIsDisplayableOnMobile() throws {
        let fixture = Self.liveBackfilledQuotaDocs.first { $0.id == "openai_openai-team_api" }
        XCTAssertNotNil(fixture)

        let snap = repo.decodeQuotaSnapshot(from: fixture!.data, docID: fixture!.id)
        let displayable = snap?.filteringToDisplayableQuotaSignal()

        XCTAssertNotNil(displayable)
        XCTAssertEqual(displayable?.providerID, .openAI)
        XCTAssertEqual(displayable?.buckets.first?.used, 218)
        XCTAssertEqual(displayable?.buckets.first?.limit, 500)
        XCTAssertEqual(displayable?.buckets.first?.remaining, 282)
    }

    func testQuotaStoreAccountCountIncludesConnectedAccountsWithoutSnapshots() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let accounts = [
            ProviderAccountDoc(
                id: "openai-team",
                providerID: .openAI,
                label: "OpenAI Team",
                status: .connected,
                credentialKind: .token,
                storageScope: .serverPrivate,
                redactedLabel: "sk-...team",
                createdAt: now,
                updatedAt: now
            )
        ]

        XCTAssertEqual(
            QuotaStore.accountCount(for: "openai", snapshots: [], accounts: accounts),
            1
        )
    }

    func testQuotaStoreGroupsAccountLinkedSnapshotsUnderConnectedAccountProvider() throws {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let account = ProviderAccountDoc(
            id: "openai-work",
            providerID: .openAI,
            label: "OpenAI Work",
            status: .connected,
            credentialKind: .token,
            storageScope: .deviceKeychain,
            redactedLabel: "sk-...work",
            createdAt: now,
            updatedAt: now
        )
        let snapshot = ProviderQuotaSnapshot(
            id: "codex_openai-work_provider:openai-work",
            provider: "codex",
            providerID: .codex,
            accountID: "openai-work",
            accountLabel: "OpenAI Work",
            accountStorageScope: .deviceKeychain,
            sourceKind: .localSession,
            sourceId: "provider:openai-work",
            fetchedAt: now,
            source: "localSession",
            confidence: .high,
            buckets: [
                ProviderQuotaBucket(
                    name: "codex-primary",
                    used: 20,
                    limit: 100,
                    remaining: 80,
                    window: "rollingHours",
                    meta: ["unit": "percent"]
                )
            ],
            updatedAt: now
        )

        let grouped = QuotaStore.snapshotsByDisplayProvider(
            snapshots: [snapshot],
            accounts: [account]
        )

        XCTAssertEqual(QuotaStore.providerDisplayKey(for: snapshot, accounts: [account]), "openai")
        XCTAssertEqual(grouped["openai"]?.first?.id, snapshot.id)
        XCTAssertNil(grouped["codex"])
    }

    func testQuotaStoreIgnoresCacheOnlyProviderRegression() {
        XCTAssertFalse(QuotaStore.shouldApplySnapshotUpdate(
            currentVisibleProviders: ["claude-code", "codex", "cursor", "factory", "minimax", "ollama", "zai"],
            incomingVisibleProviders: ["cursor"],
            isFromCache: true
        ))
    }

    func testQuotaStoreAcceptsServerProviderRegression() {
        XCTAssertTrue(QuotaStore.shouldApplySnapshotUpdate(
            currentVisibleProviders: ["claude-code", "codex", "cursor", "factory", "minimax", "ollama", "zai"],
            incomingVisibleProviders: ["cursor"],
            isFromCache: false
        ))
    }

    func testQuotaStoreAcceptsExpandingCacheUpdate() {
        XCTAssertTrue(QuotaStore.shouldApplySnapshotUpdate(
            currentVisibleProviders: ["cursor"],
            incomingVisibleProviders: ["claude-code", "codex", "cursor", "factory", "minimax", "ollama", "zai"],
            isFromCache: true
        ))
    }

    func testRedactedUserIDOnlyExposesSuffix() {
        XCTAssertEqual(FirestoreRepository.redactedUserID("6YTomKTKdQdpvIJgmz6VTIrrQ4w1"), "…rQ4w1")
        XCTAssertNil(FirestoreRepository.redactedUserID(nil))
        XCTAssertNil(FirestoreRepository.redactedUserID(""))
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

    func testProviderAccountsSortClientSideWithoutCompositeIndex() {
        let now = Date()
        let accounts = [
            providerAccount(id: "z", providerID: .openAI, label: "Zeta", sortKey: 2, now: now),
            providerAccount(id: "a", providerID: .claudeCode, label: "Alpha", sortKey: 2, now: now),
            providerAccount(id: "b", providerID: .claudeCode, label: "Beta", sortKey: 1, now: now)
        ]

        XCTAssertEqual(repo.sortProviderAccounts(accounts).map(\.id), ["b", "a", "z"])
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

    func test_sanitizeForJSON_convertsDateToDouble() {
        let now = Date()
        let result = repo.sanitizeForJSON(now)
        XCTAssertTrue(result is Double)
        XCTAssertEqual(result as! Double, now.timeIntervalSinceReferenceDate, accuracy: 0.001)
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
        let snap = repo.decodeQuotaSnapshot(
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

    private func providerAccount(id: String, providerID: ProviderID, label: String, sortKey: Double, now: Date) -> ProviderAccountDoc {
        ProviderAccountDoc(
            id: id,
            providerID: providerID,
            label: label,
            status: .connected,
            credentialKind: .token,
            storageScope: .cloudRefreshable,
            redactedLabel: "redacted",
            sortKey: sortKey,
            createdAt: now,
            updatedAt: now
        )
    }
}

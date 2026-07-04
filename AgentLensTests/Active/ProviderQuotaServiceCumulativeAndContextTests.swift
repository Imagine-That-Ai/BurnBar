import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias ProviderQuotaBucket = OpenBurnBar.ProviderQuotaBucket
private typealias ProviderQuotaSnapshot = OpenBurnBar.ProviderQuotaSnapshot
private typealias ProviderQuotaWindowKind = OpenBurnBar.ProviderQuotaWindowKind

@MainActor
extension ProviderQuotaServiceTests {
    // MARK: - Cumulative across accounts
    //
    // Pure-logic tests against
    // `ProviderQuotaService.cumulativeSnapshot(provider:from:now:)`. The
    // service-level convenience method is a thin wrapper over this and
    // exercises the same code path.

    func test_cumulativeSnapshot_returnsNilForSingleAccount() {
        let snapshots = [
            makeSnapshot(
                accountID: "a1",
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours, used: 30, limit: 100)]
            )
        ]
        let result = ProviderQuotaService.cumulativeSnapshot(
            provider: .claudeCode,
            from: snapshots,
            now: now
        )
        XCTAssertNil(result)
    }

    func test_cumulativeSnapshot_sumsTwoAccountsByKeyAndWindowKind() throws {
        let snapshots = [
            makeSnapshot(
                accountID: "a1",
                fetchedAt: now.addingTimeInterval(-60),
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours, used: 30, limit: 100,
                               resetsAt: now.addingTimeInterval(3 * 60 * 60)),
                    makeBucket(key: "7d", windowKind: .weekly, used: 200, limit: 1000,
                               resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60))
                ]
            ),
            makeSnapshot(
                accountID: "a2",
                fetchedAt: now.addingTimeInterval(-30),
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours, used: 70, limit: 100,
                               resetsAt: now.addingTimeInterval(60 * 60)),
                    makeBucket(key: "7d", windowKind: .weekly, used: 500, limit: 1000,
                               resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60))
                ]
            )
        ]

        let result = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )

        XCTAssertEqual(result.accountLabel, "All accounts (2)")
        XCTAssertNil(result.accountID)
        XCTAssertEqual(result.buckets.count, 2)

        let hourly = try XCTUnwrap(result.hourlyBucket(relativeTo: now))
        XCTAssertEqual(hourly.usedValue, 100)
        XCTAssertEqual(hourly.limitValue, 200)
        XCTAssertEqual(try XCTUnwrap(hourly.usedPercent), 50, accuracy: 0.001)
        // Earliest resetsAt wins.
        XCTAssertEqual(hourly.resetsAt, now.addingTimeInterval(60 * 60))

        let weekly = try XCTUnwrap(result.weeklyBucket(relativeTo: now))
        XCTAssertEqual(weekly.usedValue, 700)
        XCTAssertEqual(weekly.limitValue, 2000)
        XCTAssertEqual(try XCTUnwrap(weekly.usedPercent), 35, accuracy: 0.001)
    }

    func test_cumulativeSnapshot_recomputesUsedPercentFromSums() throws {
        // 10% of 1000 + 90% of 100 should NOT average to 50%. The
        // weighted total is (100 + 90) / (1000 + 100) ≈ 17.27%.
        let snapshots = [
            makeSnapshot(
                accountID: "a1",
                fetchedAt: now,
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours,
                               used: 100, limit: 1000,
                               resetsAt: now.addingTimeInterval(60 * 60))
                ]
            ),
            makeSnapshot(
                accountID: "a2",
                fetchedAt: now,
                buckets: [
                    makeBucket(key: "5h", windowKind: .rollingHours,
                               used: 90, limit: 100,
                               resetsAt: now.addingTimeInterval(60 * 60))
                ]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        let hourly = try XCTUnwrap(merged.hourlyBucket(relativeTo: now))
        let hourlyUsedPercent = try XCTUnwrap(hourly.usedPercent)
        XCTAssertEqual(hourlyUsedPercent, 190.0 / 1100.0 * 100, accuracy: 0.01)
        XCTAssertNotEqual(hourlyUsedPercent, 50, accuracy: 1)
    }

    func test_cumulativeSnapshot_marksEstimatedIfAnyInputEstimated() throws {
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100, isEstimated: false,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100, isEstimated: true,
                                      resetsAt: now.addingTimeInterval(3600))]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertTrue(try XCTUnwrap(merged.hourlyBucket(relativeTo: now)).isEstimated)
    }

    func test_cumulativeSnapshot_excludesLocalOnlyScope() {
        // localOnly snapshots are device-only scrape caches that
        // shouldn't be aggregated across accounts. With only one non-
        // localOnly account, the result should be nil (single account).
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                scope: .cloudRefreshable,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                scope: .localOnly,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 99, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            )
        ]
        let merged = ProviderQuotaService.cumulativeSnapshot(
            provider: .codex,
            from: snapshots,
            now: now
        )
        XCTAssertNil(merged)
    }

    func test_cumulativeSnapshot_mixedWindowKinds() throws {
        // a1 has only 5h, a2 has only 7d. Cumulative emits both buckets,
        // each summed across its own account (which is just that account).
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 40, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                buckets: [makeBucket(key: "7d", windowKind: .weekly,
                                      used: 50, limit: 100,
                                      resetsAt: now.addingTimeInterval(86400))]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertEqual(merged.buckets.count, 2)
        XCTAssertNotNil(merged.hourlyBucket(relativeTo: now))
        XCTAssertNotNil(merged.weeklyBucket(relativeTo: now))
    }

    func test_cumulativeSnapshot_picksEarliestResetsAt() throws {
        let later = now.addingTimeInterval(4 * 60 * 60)
        let earlier = now.addingTimeInterval(60 * 60)
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100, resetsAt: later)]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: now,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 70, limit: 100, resetsAt: earlier)]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertEqual(try XCTUnwrap(merged.hourlyBucket(relativeTo: now)).resetsAt, earlier)
    }

    func test_cumulativeSnapshot_staleFallbackWhenAllAccountsStale() throws {
        // Both snapshots fetched > 12h ago — `isStale` will return true
        // for each. The result should be the freshest single snapshot
        // wrapped with a "Stale data merged" status and unavailable
        // confidence.
        let veryOld = now.addingTimeInterval(-13 * 60 * 60)
        let slightlyLessOld = now.addingTimeInterval(-12 * 60 * 60 - 60)
        let snapshots = [
            makeSnapshot(
                accountID: "a1", fetchedAt: veryOld,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 30, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            ),
            makeSnapshot(
                accountID: "a2", fetchedAt: slightlyLessOld,
                buckets: [makeBucket(key: "5h", windowKind: .rollingHours,
                                      used: 70, limit: 100,
                                      resetsAt: now.addingTimeInterval(3600))]
            )
        ]
        let merged = try XCTUnwrap(
            ProviderQuotaService.cumulativeSnapshot(
                provider: .claudeCode,
                from: snapshots,
                now: now
            )
        )
        XCTAssertEqual(merged.confidence, .unavailable)
        XCTAssertTrue(merged.statusMessage.contains("Stale"))
    }

    // MARK: Cumulative-test fixtures

    /// Reference clock used by the cumulative tests above. Fixed so
    /// `isStale` boundaries are deterministic.
    private var now: Date {
        Date(timeIntervalSince1970: 1_750_000_000)
    }

    private func makeBucket(
        key: String,
        windowKind: ProviderQuotaWindowKind,
        used: Double,
        limit: Double,
        isEstimated: Bool = false,
        resetsAt: Date? = nil
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: key,
            windowKind: windowKind,
            usedValue: used,
            limitValue: limit,
            remainingValue: max(limit - used, 0),
            usedPercent: limit > 0 ? min(max(used / limit * 100, 0), 100) : nil,
            resetsAt: resetsAt,
            unit: .tokens,
            isEstimated: isEstimated
        )
    }

    private func makeSnapshot(
        provider: AgentProvider = .claudeCode,
        accountID: String,
        fetchedAt: Date? = nil,
        scope: ProviderAccountStorageScope = .cloudRefreshable,
        buckets: [ProviderQuotaBucket]
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            providerID: provider.providerID,
            accountID: accountID,
            accountLabel: "Account \(accountID)",
            accountStorageScope: scope,
            fetchedAt: fetchedAt ?? now,
            source: .officialAPI,
            sourceId: accountID,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "ok",
            buckets: buckets
        )
    }

    // MARK: - Claude context-window quota-boundary tests

    /// Writes a Claude statusline snapshot that contains `context_window`
    /// data but NO `rate_limits` key, plus the Claude settings needed for
    /// the bridge to report `.ready`.
    func writeContextWindowOnlyFixture(
        home: URL,
        appPaths: OpenBurnBar.OpenBurnBarAppPaths,
        fiveHourUsedPercent: Int? = nil,
        usedPercentage: Int = 26,
        windowSize: Int = 1_000_000,
        inputTokens: Int = 264_134,
        outputTokens: Int = 491,
        sessionName: String = "Fix loginwindow keystroke delivery",
        modelName: String = "Opus 4.8 (1M context)",
        costUSD: Double = 79.66,
        stale: Bool = false
    ) throws {
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rateLimits: String
        if let fiveHourUsedPercent {
            rateLimits = """
              "rate_limits": {
                "five_hour": { "used_percentage": \(fiveHourUsedPercent), "resets_at": "2026-03-24T15:00:00Z" }
              },
            """
        } else {
            rateLimits = ""
        }
        let payload = """
        {
        \(rateLimits)
          "session_name": "\(sessionName)",
          "model": { "id": "claude-opus-4-8", "display_name": "\(modelName)" },
          "cost": { "total_cost_usd": \(costUSD) },
          "context_window": {
            "total_input_tokens": \(inputTokens),
            "total_output_tokens": \(outputTokens),
            "context_window_size": \(windowSize),
            "used_percentage": \(usedPercentage),
            "remaining_percentage": \(100 - usedPercentage)
          }
        }
        """
        try Data(payload.utf8).write(to: snapshotURL)

        if stale {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-60 * 60)],
                ofItemAtPath: snapshotURL.path
            )
        }

        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let settings = """
        {
          "statusLine": {
            "type": "command",
            "command": "\(appPaths.claudeStatuslineBridgeScriptURL.path)"
          }
        }
        """
        try Data(settings.utf8).write(to: settingsURL)
    }

    func test_claudeRefresh_contextWindowOnlySnapshotDoesNotRenderAsQuota() async throws {
        let home = try makeSplitTemporaryDirectory()
        let appSupport = try makeSplitTemporaryDirectory()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        try writeContextWindowOnlyFixture(home: home, appPaths: appPaths)

        let service = makeSplitService(home: home, appSupportRoot: appSupport)
        await service.refresh(provider: .claudeCode, dataStore: try makeSplitDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.provider, .claudeCode)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertFalse(snapshot.statusMessage.contains("Context window"))
    }

    func test_claudeRefresh_staleContextWindowOnlySnapshotDoesNotRenderAsQuota() async throws {
        let home = try makeSplitTemporaryDirectory()
        let appSupport = try makeSplitTemporaryDirectory()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        try writeContextWindowOnlyFixture(home: home, appPaths: appPaths, stale: true)

        let service = makeSplitService(home: home, appSupportRoot: appSupport)
        await service.refresh(provider: .claudeCode, dataStore: try makeSplitDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertFalse(snapshot.statusMessage.contains("context window"))
    }

    func test_claudeRefresh_statuslineRateLimitsWinEvenWhenContextWindowIsPresent() async throws {
        let home = try makeSplitTemporaryDirectory()
        let appSupport = try makeSplitTemporaryDirectory()
        let appPaths = OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        // Write a fixture that has BOTH rate_limits and context_window
        try writeContextWindowOnlyFixture(
            home: home,
            appPaths: appPaths,
            fiveHourUsedPercent: 42
        )

        let service = makeSplitService(home: home, appSupportRoot: appSupport)
        await service.refresh(provider: .claudeCode, dataStore: try makeSplitDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.key != "context-window" }),
                       "When rate_limits is present, primary path should produce standard quota buckets")
        XCTAssertFalse(snapshot.buckets.contains(where: { $0.key == "context-window" }),
                        "Context-window telemetry must not render as quota")
    }

    private func makeSplitTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeSplitDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeSplitService(
        home: URL,
        appSupportRoot: URL
    ) -> ProviderQuotaService {
        ProviderQuotaService(
            keyStore: ProviderAPIKeyStore(
                keychain: KeychainStore(
                    service: "tests.split.\(UUID().uuidString)",
                    legacyServices: [],
                    backend: ProviderQuotaSplitKeychainBackend()
                )
            ),
            providerRuntimeKeyStore: KeychainStore(
                service: "tests.split.runtime.\(UUID().uuidString)",
                legacyServices: [],
                backend: ProviderQuotaSplitKeychainBackend()
            ),
            appPaths: OpenBurnBar.OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot),
            fileManager: .default,
            session: .shared,
            environment: [:],
            homeDirectoryURL: home,
            miniMaxModeProvider: { .payAsYouGo },
            factoryPlanProvider: { .unknown },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            refreshProviders: ProviderQuotaService.supportedProviders
        )
    }
}

private final class ProviderQuotaSplitKeychainBackend: KeychainStoreBackend {
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

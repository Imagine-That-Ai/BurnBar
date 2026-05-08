import Foundation
import GRDB
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class ProviderQuotaServiceTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        StubURLProtocol.requestHandler = nil
        OpenBurnBarDaemonManager.shared.providerConfigurations = []
    }

    func test_supportedProviders_onlyIncludesRealQuotaSignalProviders() {
        XCTAssertTrue(ProviderQuotaService.supportedProviders.contains(.warp))
        XCTAssertTrue(ProviderQuotaService.supportedProviders.contains(.ollama))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.hermes))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.aider))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.openAI))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.forgeDev))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.kiloCode))
    }

    func test_visiblePopoverProviders_onlyIncludesConnectedProviders() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            refreshProviders: [.minimax, .cursor, .warp]
        )

        try dataStore.providerAccountStore.upsert(providerAccount(provider: .cursor, status: .connected))
        try dataStore.providerAccountStore.upsert(providerAccount(provider: .minimax, status: .disabled))
        try dataStore.providerAccountStore.upsert(providerAccount(provider: .warp, status: .disconnected))

        XCTAssertEqual(service.visiblePopoverProviders(dataStore: dataStore), [.cursor])
        XCTAssertTrue(service.hasConnectedQuotaAccount(for: .cursor, dataStore: dataStore))
        XCTAssertFalse(service.hasConnectedQuotaAccount(for: .minimax, dataStore: dataStore))
        XCTAssertFalse(service.hasConnectedQuotaAccount(for: .warp, dataStore: dataStore))
    }

    func test_visiblePopoverProviders_includesLocalQuotaSignalsWithoutAccount() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()
        let eventDate = recentUTCDate(daysAgo: 1, hour: 10)
        let rolloutDirectory = codexRolloutDirectory(home: home, date: eventDate)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)

        let rolloutURL = codexRolloutFileURL(directory: rolloutDirectory, date: eventDate)
        let payload = """
        {"timestamp":"\(iso8601String(eventDate))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":22.0,"window_minutes":300,"resets_at":1774359600},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1774801258}}}}
        """
        try Data(payload.utf8).write(to: rolloutURL)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            refreshProviders: [.codex, .warp]
        )

        await service.refresh(provider: .codex, dataStore: dataStore)

        XCTAssertEqual(service.visiblePopoverProviders(dataStore: dataStore), [.codex])
    }

    func test_snapshotsForCloudSync_excludesUsageOnlyAndActivitySnapshots() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default).persistSnapshots([
            .codex: ProviderQuotaSnapshot(
                provider: .codex,
                fetchedAt: Date(),
                source: .localSession,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Codex quota.",
                buckets: [
                    ProviderQuotaBucket(
                        key: "codex-5h",
                        label: "5-hour window",
                        windowKind: .rollingHours,
                        usedValue: 40,
                        limitValue: 100,
                        remainingValue: 60,
                        usedPercent: 40,
                        resetsAt: nil,
                        unit: .percent,
                        isEstimated: false
                    )
                ]
            ),
            .hermes: ProviderQuotaSnapshot(
                provider: .hermes,
                fetchedAt: Date(),
                source: .localSession,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Hermes usage.",
                buckets: [
                    ProviderQuotaBucket(
                        key: "hermes-total",
                        label: "Total tokens",
                        windowKind: .lifetime,
                        usedValue: 1_000,
                        limitValue: nil,
                        remainingValue: nil,
                        usedPercent: nil,
                        resetsAt: nil,
                        unit: .tokens,
                        isEstimated: false
                    )
                ]
            ),
            .factory: ProviderQuotaSnapshot(
                provider: .factory,
                fetchedAt: Date(),
                source: .localSession,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Factory session usage.",
                buckets: [
                    ProviderQuotaBucket(
                        key: "factory-cache",
                        label: "Cache hit rate (30d)",
                        windowKind: .monthly,
                        usedValue: 90,
                        limitValue: 100,
                        remainingValue: nil,
                        usedPercent: 90,
                        resetsAt: nil,
                        unit: .percent,
                        isEstimated: false
                    )
                ]
            )
        ])
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            refreshProviders: [.codex, .hermes, .factory]
        )

        XCTAssertEqual(service.snapshotsForCloudSync.map(\.provider), [.codex])
    }

    func test_warpRefresh_readsLocalCreditTelemetry() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let warpDirectory = home
            .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
        try FileManager.default.createDirectory(at: warpDirectory, withIntermediateDirectories: true)
        let payload = """
        Body {
          "data": {
            "viewer": {
              "warpCredits": {
                "creditsUsed": 25,
                "creditsLimit": 100,
                "creditsRemaining": 75,
                "resetsAt": "2026-06-01T00:00:00Z"
              }
            }
          }
        }
        """
        try Data(payload.utf8).write(to: warpDirectory.appendingPathComponent("warp_network.log"))

        let service = makeService(home: home, appSupportRoot: appSupport)

        await service.refresh(provider: .warp, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .warp))

        XCTAssertEqual(snapshot.source, .localSession)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertEqual(snapshot.buckets.first?.label, "Monthly credits")
        XCTAssertEqual(snapshot.buckets.first?.usedValue, 25)
        XCTAssertEqual(snapshot.buckets.first?.limitValue, 100)
        XCTAssertEqual(snapshot.buckets.first?.remainingValue, 75)
    }

    func test_warpRefresh_withoutCreditTelemetry_returnsUnavailableSnapshot() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let warpDirectory = home
            .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
        try FileManager.default.createDirectory(at: warpDirectory, withIntermediateDirectories: true)
        try Data("Body {\"batch\":[]}".utf8).write(to: warpDirectory.appendingPathComponent("warp_network.log"))

        let service = makeService(home: home, appSupportRoot: appSupport)

        await service.refresh(provider: .warp, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .warp))

        XCTAssertEqual(snapshot.provider, .warp)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertTrue(snapshot.statusMessage.contains("Warp credit quota was not found"))
    }

    func test_refreshIfNeeded_respectsMaxAgeAfterUnavailableSnapshot() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()
        let warpDirectory = home
            .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
        try FileManager.default.createDirectory(at: warpDirectory, withIntermediateDirectories: true)
        try Data("Body {\"batch\":[]}".utf8).write(to: warpDirectory.appendingPathComponent("warp_network.log"))
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            refreshProviders: [.warp]
        )

        await service.refreshIfNeeded(dataStore: dataStore, maxAge: 300)
        let firstFetchedAt = try XCTUnwrap(service.snapshot(for: .warp)?.fetchedAt)
        try await Task.sleep(nanoseconds: 25_000_000)
        await service.refreshIfNeeded(dataStore: dataStore, maxAge: 300)
        let secondFetchedAt = try XCTUnwrap(service.snapshot(for: .warp)?.fetchedAt)

        XCTAssertEqual(firstFetchedAt, secondFetchedAt)
    }

    func test_codexRefresh_readsLatestLocalQuotaSnapshot() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let eventDate = recentUTCDate(daysAgo: 1, hour: 10)
        let rolloutDirectory = codexRolloutDirectory(home: home, date: eventDate)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)

        let rolloutURL = codexRolloutFileURL(directory: rolloutDirectory, date: eventDate)
        let payload = """
        {"timestamp":"\(iso8601String(eventDate))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":22.0,"window_minutes":300,"resets_at":1774359600},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1774801258}}}}
        """
        try Data(payload.utf8).write(to: rolloutURL)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport
        )

        await service.refresh(provider: .codex, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .codex))

        XCTAssertEqual(snapshot.source, .localSession)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.label == "5-hour window" })?.remainingPercent?.rounded(), 78)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.label == "7-day window" })?.remainingPercent?.rounded(), 80)
    }

    func test_codexRefresh_readsQuotaSnapshotFromLargeRolloutTail() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let eventDate = recentUTCDate(daysAgo: 1, hour: 11)
        let fillerDate = eventDate.addingTimeInterval(-61)
        let rolloutDirectory = codexRolloutDirectory(home: home, date: eventDate)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)

        let rolloutURL = codexRolloutFileURL(directory: rolloutDirectory, date: eventDate)
        let fillerLine = #"{"timestamp":"\#(iso8601String(fillerDate))","type":"event_msg","payload":{"type":"assistant_message","text":"filler"}}"#
        let quotaLine = """
        {"timestamp":"\(iso8601String(eventDate))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":35.0,"window_minutes":300,"resets_at":1774359600},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1774801258}}}}
        """
        let payload = Array(repeating: fillerLine, count: 7000).joined(separator: "\n") + "\n" + quotaLine
        try Data(payload.utf8).write(to: rolloutURL)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport
        )

        await service.refresh(provider: .codex, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .codex))

        XCTAssertEqual(snapshot.source, .localSession)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.label == "5-hour window" })?.remainingPercent?.rounded(), 65)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.label == "7-day window" })?.remainingPercent?.rounded(), 58)
    }

    func test_codexRefresh_reusesPersistedScanCacheForUnchangedFiles() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let eventDate = recentUTCDate(daysAgo: 1, hour: 12)
        let rolloutDirectory = codexRolloutDirectory(home: home, date: eventDate)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)

        let rolloutURL = codexRolloutFileURL(directory: rolloutDirectory, date: eventDate)
        let payload = """
        {"timestamp":"\(iso8601String(eventDate))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":41.0,"window_minutes":300,"resets_at":1774359600},"secondary":{"used_percent":33.0,"window_minutes":10080,"resets_at":1774801258}}}}
        """
        try Data(payload.utf8).write(to: rolloutURL)

        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let first = makeService(home: home, appSupportRoot: appSupport)
        await first.refresh(provider: .codex, dataStore: try makeDataStore())
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.codexRolloutScanCacheURL.path))

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: rolloutURL.path)

        let second = makeService(home: home, appSupportRoot: appSupport)
        await second.refresh(provider: .codex, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(second.snapshot(for: .codex))

        XCTAssertEqual(snapshot.source, .localSession)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.label == "5-hour window" })?.remainingPercent?.rounded(), 59)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rolloutURL.path)
    }

    func test_codexRefresh_normalizesWeeklyOnlyWindowIntoSecondaryBucket() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let eventDate = recentUTCDate(daysAgo: 1, hour: 13)
        let rolloutDirectory = codexRolloutDirectory(home: home, date: eventDate)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)

        let rolloutURL = codexRolloutFileURL(directory: rolloutDirectory, date: eventDate)
        let payload = """
        {"timestamp":"\(iso8601String(eventDate))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"free","primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1774801258}}}}
        """
        try Data(payload.utf8).write(to: rolloutURL)

        let service = makeService(home: home, appSupportRoot: appSupport)

        await service.refresh(provider: .codex, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .codex))

        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(snapshot.buckets.first?.label, "7-day window")
        XCTAssertEqual(snapshot.buckets.first?.windowKind, .rollingDays)
        XCTAssertEqual(snapshot.buckets.first?.remainingPercent?.rounded(), 88)
    }

    func test_codexRefresh_normalizesReversedSessionAndWeeklyWindows() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let eventDate = recentUTCDate(daysAgo: 1, hour: 14)
        let rolloutDirectory = codexRolloutDirectory(home: home, date: eventDate)
        try FileManager.default.createDirectory(at: rolloutDirectory, withIntermediateDirectories: true)

        let rolloutURL = codexRolloutFileURL(directory: rolloutDirectory, date: eventDate)
        let payload = """
        {"timestamp":"\(iso8601String(eventDate))","type":"event_msg","payload":{"type":"token_count","rate_limits":{"plan_type":"pro","primary":{"used_percent":43.0,"window_minutes":10080,"resets_at":1774801258},"secondary":{"used_percent":17.0,"window_minutes":300,"resets_at":1774359600}}}}
        """
        try Data(payload.utf8).write(to: rolloutURL)

        let service = makeService(home: home, appSupportRoot: appSupport)

        await service.refresh(provider: .codex, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .codex))

        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first?.label, "5-hour window")
        XCTAssertEqual(snapshot.buckets.first?.windowKind, .rollingHours)
        XCTAssertEqual(snapshot.buckets.first?.remainingPercent?.rounded(), 83)
        XCTAssertEqual(snapshot.buckets.last?.label, "7-day window")
        XCTAssertEqual(snapshot.buckets.last?.windowKind, .rollingDays)
        XCTAssertEqual(snapshot.buckets.last?.remainingPercent?.rounded(), 57)
    }

    func test_claudeBridge_installAndRemove_roundTripsStatusLineCommand() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let originalSettings = """
        {
          "statusLine": {
            "type": "command",
            "command": "echo original-status"
          }
        }
        """
        try Data(originalSettings.utf8).write(to: settingsURL)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport
        )

        try service.installClaudeQuotaBridge()

        let installedSettings = try readJSON(from: settingsURL)
        let installedStatusLine = try XCTUnwrap(installedSettings["statusLine"] as? [String: Any])
        let installedCommand = try XCTUnwrap(installedStatusLine["command"] as? String)
        XCTAssertEqual(installedCommand, OpenBurnBarAppPaths(applicationSupportRoot: appSupport).claudeStatuslineBridgeScriptURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: OpenBurnBarAppPaths(applicationSupportRoot: appSupport).claudeStatuslineBridgeScriptURL.path))
        XCTAssertEqual(service.claudeBridgeStatus.state, .awaitingFirstPayload)

        try service.removeClaudeQuotaBridge()

        let restoredSettings = try readJSON(from: settingsURL)
        let restoredStatusLine = try XCTUnwrap(restoredSettings["statusLine"] as? [String: Any])
        XCTAssertEqual(restoredStatusLine["command"] as? String, "echo original-status")
    }

    func test_claudeRefresh_isUnavailableWhenAPIBillingOverrideDetected() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: ["ANTHROPIC_API_KEY": "sk-ant-test"]
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("API billing"))
    }

    func test_claudeRefresh_usesLocalBridgeSnapshotEvenWhenAPIBillingOverrideDetected() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let snapshotURL = OpenBurnBarAppPaths(applicationSupportRoot: appSupport).claudeStatuslineSnapshotURL
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = """
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 10, "resets_at": "2026-03-24T15:00:00Z" },
            "seven_day_opus": { "used_percentage": 40, "resets_at": "2026-03-31T15:00:00Z" }
          }
        }
        """
        try Data(payload.utf8).write(to: snapshotURL)

        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let wrapperPath = OpenBurnBarAppPaths(applicationSupportRoot: appSupport).claudeStatuslineBridgeScriptURL.path
        let settings = """
        {
          "statusLine": {
            "type": "command",
            "command": "\(wrapperPath)"
          }
        }
        """
        try Data(settings.utf8).write(to: settingsURL)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: ["ANTHROPIC_API_KEY": "sk-ant-test"]
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.source, .localCLI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertTrue(snapshot.statusMessage.contains("local status line"))
        XCTAssertTrue(snapshot.statusMessage.contains("API billing"))
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "5-hour window" && $0.remainingPercent?.rounded() == 90 }))
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "7-day Opus window" && $0.remainingPercent?.rounded() == 60 }))
    }

    func test_factoryRefresh_prefersExactFactoryAPIUsingExplicitEnvironmentCredentials() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer factory-bearer")
            XCTAssertTrue((request.value(forHTTPHeaderField: "Cookie") ?? "").contains("session=factory-session"))

            if url.path.hasSuffix("/api/app/auth/me") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "organization": {
                        "name": "Acme",
                        "subscription": {
                          "factoryTier": "team",
                          "orbSubscription": {
                            "plan": { "name": "Team" }
                          }
                        }
                      }
                    }
                    """
                )
            }

            if url.path.hasSuffix("/api/organization/subscription/usage") {
                XCTAssertEqual(request.httpMethod, "GET")
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "usage": {
                        "endDate": 1774359600000,
                        "standard": {
                          "userTokens": 100,
                          "totalAllowance": 1000,
                          "usedRatio": 0.10
                        },
                        "premium": {
                          "userTokens": 10,
                          "totalAllowance": 100,
                          "usedRatio": 0.10
                        }
                      }
                    }
                    """
                )
            }

            XCTFail("Unexpected Factory URL \(url.absoluteString)")
            return try self.httpResponse(url: url, statusCode: 404, body: #"{"error":"not found"}"#)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            environment: [
                "FACTORY_BEARER_TOKEN": "factory-bearer",
                "FACTORY_COOKIE_HEADER": "session=factory-session"
            ],
            factoryPlanProvider: { .pro }
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertTrue(snapshot.statusMessage.contains("environment override"))
        XCTAssertTrue(snapshot.buckets.contains(where: {
            $0.label == "Standard tokens"
                && $0.limitValue?.rounded() == 1_000
                && $0.remainingValue?.rounded() == 900
                && $0.usedPercent?.rounded() == 10
        }))
        XCTAssertTrue(snapshot.buckets.contains(where: {
            $0.label == "Premium tokens"
                && $0.limitValue?.rounded() == 100
                && $0.remainingValue?.rounded() == 90
                && $0.usedPercent?.rounded() == 10
        }))
    }

    func test_refreshAll_persistsSnapshotsAndReloadsFromDisk() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)

        let first = makeService(
            home: home,
            appSupportRoot: appSupport,
            factoryPlanProvider: { .pro }
        )

        let store = try makeDataStore()
        await first.refreshAll(dataStore: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.providerQuotaSnapshotsURL.path))

        let second = makeService(
            home: home,
            appSupportRoot: appSupport,
            factoryPlanProvider: { .pro }
        )

        XCTAssertNotNil(second.snapshot(for: .factory))
    }

    func test_persistedSnapshots_preserveMultipleAccountsForSameProvider() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let store = ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default)
        let work = ProviderQuotaSnapshot(
            provider: .minimax,
            accountID: "minimax_work",
            accountLabel: "Work",
            accountStorageScope: .deviceKeychain,
            fetchedAt: Date(timeIntervalSince1970: 100),
            source: .officialAPI,
            sourceId: "slot-work",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Work quota",
            buckets: []
        )
        let personal = ProviderQuotaSnapshot(
            provider: .minimax,
            accountID: "minimax_personal",
            accountLabel: "Personal",
            accountStorageScope: .deviceKeychain,
            fetchedAt: Date(timeIntervalSince1970: 200),
            source: .officialAPI,
            sourceId: "slot-personal",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Personal quota",
            buckets: []
        )

        store.persistSnapshots([.minimax: personal], accountSnapshots: [
            ProviderQuotaSnapshotStore.accountSnapshotKey(work): work,
            ProviderQuotaSnapshotStore.accountSnapshotKey(personal): personal,
        ])

        let service = makeService(home: home, appSupportRoot: appSupport)

        XCTAssertEqual(service.snapshots(for: .minimax).map(\.accountID), ["minimax_personal", "minimax_work"])
        XCTAssertEqual(service.snapshot(accountID: "minimax_work")?.accountLabel, "Work")
        XCTAssertEqual(service.snapshot(for: .minimax)?.accountID, "minimax_personal")
    }

    func test_miniMaxRefresh_usesTokenPlanEndpoint() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "minimax", value: "mm-token")
        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mm-token")

            let body = """
            {
              "data": [
                {
                  "name": "5 hour quota",
                  "used_percent": 25,
                  "window": "5 hour"
                },
                {
                  "name": "weekly quota",
                  "used_percent": 40,
                  "window": "weekly"
                }
              ]
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session,
            miniMaxModeProvider: { .tokenPlan }
        )

        await service.refresh(provider: .minimax, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .minimax))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first?.remainingPercent?.rounded(), 75)
    }

    func test_refreshAll_fetchesDaemonCredentialSlotsAsAccountSnapshots() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let runtimeSecrets = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        )
        try runtimeSecrets.set("sk-cp-work", for: "provider.minimax.slot.work.apiKey")
        try runtimeSecrets.set("sk-cp-personal", for: "provider.minimax.slot.personal.apiKey")

        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "minimax",
                provider: .minimax,
                displayName: "MiniMax",
                isEnabled: true,
                baseURL: "https://api.minimax.io",
                preferredModelIDs: [],
                preferredCredentialSlotID: "work",
                credentialSlots: [
                    OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                        slotID: "work",
                        label: "Work",
                        isEnabled: true,
                        status: .ready,
                        cooldownUntil: nil,
                        lastSelectedAt: nil,
                        lastQuotaRemainingPercent: nil,
                        lastQuotaResetsAt: nil,
                        lastStatusMessage: nil
                    ),
                    OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                        slotID: "personal",
                        label: "Personal",
                        isEnabled: true,
                        status: .ready,
                        cooldownUntil: nil,
                        lastSelectedAt: nil,
                        lastQuotaRemainingPercent: nil,
                        lastQuotaResetsAt: nil,
                        lastStatusMessage: nil
                    ),
                ]
            )
        ]

        let observedAuthorizations = Locked<[String]>([])
        let session = makeStubSession { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            observedAuthorizations.withLock { $0.append(authorization) }
            let usedPercent: Int
            switch authorization {
            case "Bearer sk-cp-work":
                usedPercent = 10
            case "Bearer sk-cp-personal":
                usedPercent = 70
            default:
                usedPercent = 99
            }
            let body = """
            {
              "data": [
                {
                  "name": "5 hour quota",
                  "used_percent": \(usedPercent),
                  "window": "5 hour"
                }
              ]
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            providerRuntimeKeyStore: runtimeSecrets,
            session: session,
            miniMaxModeProvider: { .tokenPlan },
            refreshProviders: [.minimax]
        )

        let dataStore = try makeDataStore()
        await service.refreshAll(dataStore: dataStore)

        let snapshots = service.snapshots(for: .minimax)
        let work = try XCTUnwrap(snapshots.first { $0.accountLabel == "Work" })
        let personal = try XCTUnwrap(snapshots.first { $0.accountLabel == "Personal" })
        let persistedAccounts = try dataStore.providerAccountStore.fetchAll(providerID: ProviderID(rawValue: "minimax"))

        XCTAssertEqual(work.accountID, "minimax-work")
        XCTAssertEqual(work.accountStorageScope, .deviceKeychain)
        XCTAssertEqual(work.sourceId, "daemon-slot:minimax:work")
        XCTAssertEqual(try XCTUnwrap(work.primaryBucket?.remainingPercent).rounded(), 90)
        XCTAssertEqual(personal.accountID, "minimax-personal")
        XCTAssertEqual(personal.sourceId, "daemon-slot:minimax:personal")
        XCTAssertEqual(try XCTUnwrap(personal.primaryBucket?.remainingPercent).rounded(), 30)
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer sk-cp-work"))
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer sk-cp-personal"))
        XCTAssertEqual(persistedAccounts.map(\.id), ["minimax-work", "minimax-personal"])
        XCTAssertEqual(persistedAccounts.first?.label, "Work")
        XCTAssertEqual(persistedAccounts.first?.storageScope, .deviceKeychain)
        XCTAssertEqual(persistedAccounts.first?.isDefault, true)
    }

    func test_refreshAll_persistsOpenAIDaemonCredentialSlotsWithoutQuotaSnapshots() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let runtimeSecrets = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        )
        try runtimeSecrets.set("sk-openai-work", for: "provider.openai.slot.work.apiKey")

        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "openai",
                provider: .openAI,
                displayName: "OpenAI",
                isEnabled: true,
                baseURL: "https://api.openai.com/v1",
                preferredModelIDs: [],
                preferredCredentialSlotID: "work",
                credentialSlots: [
                    OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                        slotID: "work",
                        label: "Work",
                        isEnabled: true,
                        status: .ready,
                        cooldownUntil: nil,
                        lastSelectedAt: nil,
                        lastQuotaRemainingPercent: nil,
                        lastQuotaResetsAt: nil,
                        lastStatusMessage: nil
                    ),
                ]
            )
        ]

        let session = makeStubSession { request in
            XCTFail("OpenAI is usage-only and should not be refreshed as quota: \(request)")
            return try self.httpResponse(url: request.url!, statusCode: 500, body: "{}")
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            providerRuntimeKeyStore: runtimeSecrets,
            session: session,
            refreshProviders: [.openAI]
        )

        let dataStore = try makeDataStore()
        await service.refreshAll(dataStore: dataStore)

        let persistedAccounts = try dataStore.providerAccountStore.fetchAll(providerID: .openAI)

        XCTAssertTrue(service.snapshots(for: AgentProvider.openAI).isEmpty)
        XCTAssertEqual(persistedAccounts.map(\.id), ["openai-work"])
        XCTAssertEqual(persistedAccounts.first?.label, "Work")
        XCTAssertEqual(persistedAccounts.first?.storageScope, .deviceKeychain)
    }

    func test_refreshAll_marksRemovedDaemonCredentialSlotAccountsDeleted() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let runtimeSecrets = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        )
        try runtimeSecrets.set("sk-cp-work", for: "provider.minimax.slot.work.apiKey")

        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "minimax",
                provider: .minimax,
                displayName: "MiniMax",
                isEnabled: true,
                baseURL: "https://api.minimax.io",
                preferredModelIDs: [],
                preferredCredentialSlotID: "work",
                credentialSlots: [
                    OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                        slotID: "work",
                        label: "Work",
                        isEnabled: true,
                        status: .ready,
                        cooldownUntil: nil,
                        lastSelectedAt: nil,
                        lastQuotaRemainingPercent: nil,
                        lastQuotaResetsAt: nil,
                        lastStatusMessage: nil
                    ),
                ]
            )
        ]

        let dataStore = try makeDataStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try dataStore.providerAccountStore.upsert(
            ProviderAccountDoc(
                id: "minimax-personal",
                providerID: ProviderID(rawValue: "minimax"),
                label: "Personal",
                status: .connected,
                credentialKind: .bearer,
                storageScope: .deviceKeychain,
                redactedLabel: "Stored in Mac Keychain",
                isDefault: true,
                sortKey: 0,
                schemaVersion: 1,
                createdAt: now,
                updatedAt: now
            )
        )

        let session = makeStubSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-cp-work")
            let body = """
            {
              "data": [
                {
                  "name": "5 hour quota",
                  "used_percent": 10,
                  "window": "5 hour"
                }
              ]
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            providerRuntimeKeyStore: runtimeSecrets,
            session: session,
            miniMaxModeProvider: { .tokenPlan },
            refreshProviders: [.minimax]
        )

        await service.refreshAll(dataStore: dataStore)

        let accounts = try dataStore.providerAccountStore.fetchAll(providerID: ProviderID(rawValue: "minimax"))
        let work = try XCTUnwrap(accounts.first { $0.id == "minimax-work" })
        let removed = try XCTUnwrap(accounts.first { $0.id == "minimax-personal" })

        XCTAssertEqual(work.status, .connected)
        XCTAssertEqual(work.isDefault, true)
        XCTAssertEqual(removed.status, .deleted)
        XCTAssertEqual(removed.lastErrorCode, "credential_slot_removed")
        XCTAssertEqual(removed.isDefault, false)
    }

    func test_refreshIfNeeded_populatesRoutingStateFromFreshPersistedSnapshotsWithoutNetworkRefresh() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let now = Date()
        ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default).persistSnapshots([
            .openAI: ProviderQuotaSnapshot(
                provider: .openAI,
                fetchedAt: now,
                source: .officialAPI,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Fresh OpenAI quota.",
                buckets: [
                    ProviderQuotaBucket(
                        key: "monthly",
                        label: "Monthly",
                        windowKind: .monthly,
                        usedValue: 10,
                        limitValue: 100,
                        remainingValue: 90,
                        usedPercent: 10,
                        resetsAt: nil,
                        unit: .requests,
                        isEstimated: false
                    )
                ]
            )
        ])

        let dataStore = try makeDataStore()
        try dataStore.providerAccountStore.upsert(
            routingAccount(id: "openai-work", label: "Work", storageScope: .deviceKeychain)
        )
        let session = makeStubSession { request in
            XCTFail("Fresh persisted quota should not require a network refresh: \(request)")
            return try self.httpResponse(url: request.url!, statusCode: 500, body: "{}")
        }
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            refreshProviders: [.openAI]
        )

        await service.refreshIfNeeded(dataStore: dataStore)

        let state = try XCTUnwrap(service.routingState(for: .openAI))
        XCTAssertEqual(state.activeAccount?.accountID, "openai-work")
        XCTAssertEqual(state.activeAccount?.quotaState, .unknown)
    }

    func test_refreshRoutingState_persistsSanitizedRoutingEventTrail() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let dataStore = try makeDataStore()

        try dataStore.providerAccountStore.upsert(
            routingAccount(
                id: "openai-work",
                label: "Work",
                status: .error,
                storageScope: .deviceKeychain,
                // Plaintext-shaped secret payload that the persistence
                // layer must scrub before writing routing events to disk.
                redactedLabel: "secretVersionName=" + "REDACTED_PLACEHOLDER",
                lastErrorCode: "Authorization: " + "Bearer REDACTED_PLACEHOLDER"
            )
        )
        try dataStore.providerAccountStore.upsert(
            routingAccount(id: "openai-personal", label: "Personal", storageScope: .deviceKeychain, sortKey: 1)
        )

        let service = makeService(home: home, appSupportRoot: appSupport, refreshProviders: [.openAI])
        let states = service.refreshRoutingState(
            dataStore: dataStore,
            request: ProviderRoutingRequest(preferredProviderIDs: [.openAI])
        )

        XCTAssertEqual(states[.openAI]?.activeAccount?.accountID, "openai-personal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.providerRoutingEventsURL.path))

        let persisted = try String(contentsOf: paths.providerRoutingEventsURL)
        XCTAssertTrue(persisted.contains("Personal"))
        // Persistence layer must scrub plaintext-shaped secret payload
        // before writing routing events to disk. Both the substring tag
        // and the placeholder value would pass through unsanitized if the
        // scrubber is bypassed.
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("secretVersionName"))
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("REDACTED_PLACEHOLDER"))
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("Bearer "))
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("credentialHandle"))

        let reloaded = makeService(home: home, appSupportRoot: appSupport, refreshProviders: [.openAI])
        XCTAssertEqual(reloaded.routingEvents.count, 1)
        XCTAssertEqual(reloaded.routingEvents.first?.selectedAccountID, "openai-personal")
    }

    func test_miniMaxRefresh_rejectsStandardAPIKeysBeforeNetworkCall() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "minimax", value: "sk-api-test")
        let session = makeStubSession { request in
            XCTFail("MiniMax standard API keys should not trigger network calls: \(request)")
            return try self.httpResponse(url: request.url!, statusCode: 500, body: "{}")
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session,
            miniMaxModeProvider: { .tokenPlan }
        )

        await service.refresh(provider: .minimax, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .minimax))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("sk-cp"))
    }

    func test_miniMaxRefresh_parsesStringHeavyTokenPlanPayload() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "minimax", value: "mm-token")
        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")

            let body = """
            {
              "data": {
                "quota_list": [
                  {
                    "quota_name": "M2.7 requests",
                    "quota_cycle": "5 hour",
                    "quota_usage": "225 / 1,500 requests",
                    "quota_remain": "1,275 requests",
                    "next_reset_time": "2026-03-24T10:15:00Z"
                  },
                  {
                    "resource_name": "image-01",
                    "window": "daily",
                    "used_num": "12 images",
                    "quota_limit": "50 images"
                  }
                ]
              }
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session,
            miniMaxModeProvider: { .tokenPlan }
        )

        await service.refresh(provider: .minimax, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .minimax))

        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "M2.7 Requests" && $0.remainingValue?.rounded() == 1_275 }))
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "Image 01" && $0.limitValue?.rounded() == 50 }))
    }

    func test_miniMaxRefresh_parsesModelRemainsPayload() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "minimax", value: "mm-token")
        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")

            let body = """
            {
              "base_resp": {
                "status_code": 0,
                "status_msg": "success"
              },
              "model_remains": [
                {
                  "model_name": "MiniMax-M2.7-HighSpeed",
                  "start_time": 1774320000000,
                  "end_time": 1774338000000,
                  "remains_time": 7200000,
                  "current_interval_total_count": 1500,
                  "current_interval_usage_count": 1437
                }
              ]
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session,
            miniMaxModeProvider: { .tokenPlan }
        )

        await service.refresh(provider: .minimax, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .minimax))
        let bucket = try XCTUnwrap(snapshot.primaryBucket)

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(bucket.label, "Minimax M2.7 Highspeed")
        XCTAssertEqual(bucket.limitValue?.rounded(), 1_500)
        XCTAssertEqual(bucket.remainingValue?.rounded(), 1_437)
        XCTAssertEqual(bucket.usedValue?.rounded(), 63)
        XCTAssertEqual(bucket.windowKind, .rollingHours)
    }

    func test_miniMaxRefresh_distinguishesFiveHourAndSevenDayBucketsFromDuration() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "minimax", value: "mm-token")
        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://www.minimax.io/v1/api/openplatform/coding_plan/remains")

            let body = """
            {
              "model_remains": [
                {
                  "model_name": "MiniMax-M2.7-HighSpeed",
                  "start_time": 1774320000000,
                  "end_time": 1774338000000,
                  "current_interval_total_count": 1500,
                  "current_interval_usage_count": 1437
                },
                {
                  "model_name": "MiniMax-M2.7-HighSpeed",
                  "start_time": 1774320000000,
                  "end_time": 1774924800000,
                  "current_interval_total_count": 10000,
                  "current_interval_usage_count": 6400
                }
              ]
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session,
            miniMaxModeProvider: { .tokenPlan }
        )

        await service.refresh(provider: .minimax, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .minimax))

        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertEqual(snapshot.buckets.first(where: { $0.windowKind == .rollingHours })?.label, "5-hour window")
        XCTAssertEqual(snapshot.buckets.first(where: { $0.windowKind == .rollingDays })?.label, "7-day window")
    }

    func test_zaiRefresh_usesOfficialMonitorEndpoints() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "zai", value: "zai-key")
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            let path = url.path
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer zai-key")

            if path.hasSuffix("/api/monitor/usage/model-usage") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: #"{"data":[{"model":"glm-5","usage":2}]}"#
                )
            }

            if path.hasSuffix("/api/monitor/usage/tool-usage") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: #"{"data":[{"name":"mcp","usage":12}]}"#
                )
            }

            if path.hasSuffix("/api/monitor/usage/quota/limit") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "data": [
                        {
                          "type": "TOKENS_LIMIT",
                          "percentage": 32,
                          "resets_at": "2026-03-24T12:00:00Z"
                        },
                        {
                          "type": "TIME_LIMIT",
                          "currentUsage": 12,
                          "usage": 100,
                          "percentage": 12
                        }
                      ]
                    }
                    """
                )
            }

            XCTFail("Unexpected URL \(url.absoluteString)")
            return try self.httpResponse(url: url, statusCode: 404, body: #"{"error":"not found"}"#)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session
        )

        await service.refresh(provider: .zai, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .zai))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertGreaterThanOrEqual(snapshot.buckets.count, 2)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label.lowercased().contains("token") }))
    }

    func test_zaiRefresh_succeedsWhenQuotaEndpointWorksButTelemetryEndpointsFail() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "zai", value: "zai-key")
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            let path = url.path
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer zai-key")

            if path.hasSuffix("/api/monitor/usage/quota/limit") {
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "data": [
                        {
                          "type": "TOKENS_LIMIT",
                          "percentage": 20,
                          "resets_at": "2026-03-24T12:00:00Z"
                        }
                      ]
                    }
                    """
                )
            }

            return try self.httpResponse(url: url, statusCode: 500, body: #"{"error":"no telemetry"}"#)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session
        )

        await service.refresh(provider: .zai, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .zai))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(snapshot.buckets.first?.remainingPercent?.rounded(), 80)
    }

    func test_zaiRefresh_surfacesInlineAuthErrors() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "zai", value: "bad-key")
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            return try self.httpResponse(
                url: url,
                statusCode: 200,
                body: #"{"code":401,"msg":"invalid token"}"#
            )
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session
        )

        await service.refresh(provider: .zai, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .zai))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("rejected the configured key"))
    }

    func test_cursorRefresh_usesBillingCycleQuotaWhenCookieConfigured() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "cursor_cookie", value: "session=test")
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=test")

            switch url.path {
            case "/api/usage-summary":
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "billing_cycle_end": "2026-04-24T12:00:00Z",
                      "individual_usage": {
                        "plan": {
                          "used": 12000,
                          "limit": 50000,
                          "total_percent_used": 30
                        },
                        "on_demand": {
                          "used": 500,
                          "limit": 2500
                        }
                      }
                    }
                    """
                )
            case "/api/auth/me":
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: #"{"id":"user_123"}"#
                )
            case "/api/usage":
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "user_123")
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "gpt4": {
                        "num_requests_total": 120,
                        "max_request_usage": 500
                      }
                    }
                    """
                )
            default:
                XCTFail("Unexpected URL \(url.absoluteString)")
                return try self.httpResponse(url: url, statusCode: 404, body: #"{"error":"not found"}"#)
            }
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session
        )

        await service.refresh(provider: .cursor, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .cursor))
        let primary = try XCTUnwrap(snapshot.primaryBucket)

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(primary.label, "Included usage")
        XCTAssertEqual(primary.remainingValue?.rounded(), 380)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "On-demand" && $0.limitValue == 25 }))
    }

    func test_cursorRefresh_fallsBackWhenConfiguredCookieIsRejected() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "cursor_cookie", value: "bad-cookie")
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            return try self.httpResponse(
                url: url,
                statusCode: 401,
                body: #"{"error":"unauthorized"}"#
            )
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session
        )

        await service.refresh(provider: .cursor, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .cursor))

        XCTAssertEqual(snapshot.source, .unavailable)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("rejected the configured cookie"))
    }

    func test_snapshotPrimaryBucket_prefersMostConstrainedWindow() {
        let snapshot = ProviderQuotaSnapshot(
            provider: .minimax,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Quota fetched.",
            buckets: [
                ProviderQuotaBucket(
                    key: "loose",
                    label: "Weekly",
                    windowKind: .weekly,
                    usedValue: 10,
                    limitValue: 100,
                    remainingValue: 90,
                    usedPercent: 10,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                ),
                ProviderQuotaBucket(
                    key: "tight",
                    label: "5-hour",
                    windowKind: .rollingHours,
                    usedValue: 75,
                    limitValue: 100,
                    remainingValue: 25,
                    usedPercent: 75,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                ),
            ]
        )

        XCTAssertEqual(snapshot.primaryBucket?.label, "5-hour")
        XCTAssertEqual(snapshot.summaryText, "5-hour: 25% left")
    }

    private func makeService(
        home: URL,
        appSupportRoot: URL,
        keyStore: ProviderAPIKeyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(service: "tests.\(UUID().uuidString)", legacyServices: [], backend: TestKeychainBackend())
        ),
        providerRuntimeKeyStore: KeychainStore = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        ),
        session: URLSession = .shared,
        environment: [String: String] = [:],
        miniMaxModeProvider: @escaping () -> MiniMaxQuotaMode = { .payAsYouGo },
        factoryPlanProvider: @escaping () -> FactoryQuotaPlanTier = { .unknown },
        refreshProviders: [AgentProvider] = ProviderQuotaService.supportedProviders
    ) -> ProviderQuotaService {
        ProviderQuotaService(
            keyStore: keyStore,
            providerRuntimeKeyStore: providerRuntimeKeyStore,
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot),
            fileManager: .default,
            session: session,
            environment: environment,
            homeDirectoryURL: home,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: factoryPlanProvider,
            refreshProviders: refreshProviders
        )
    }

    private func makeDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeKeyStore(provider: String, value: String) throws -> ProviderAPIKeyStore {
        let backend = TestKeychainBackend()
        let store = ProviderAPIKeyStore(
            keychain: KeychainStore(service: "tests.\(UUID().uuidString)", legacyServices: [], backend: backend)
        )
        try store.setAPIKey(value, for: provider)
        return store
    }

    private func routingAccount(
        id: String,
        label: String,
        status: ProviderAccountStatus = .connected,
        storageScope: ProviderAccountStorageScope = .deviceKeychain,
        redactedLabel: String = "Stored in test keychain",
        lastErrorCode: String? = nil,
        sortKey: Double = 0
    ) -> ProviderAccountDoc {
        let now = Date(timeIntervalSinceReferenceDate: 800_200_000 + sortKey)
        return ProviderAccountDoc(
            id: id,
            providerID: .openAI,
            label: label,
            status: status,
            credentialKind: .bearer,
            storageScope: storageScope,
            redactedLabel: redactedLabel,
            isDefault: sortKey == 0,
            sortKey: sortKey,
            lastValidatedAt: now,
            lastRefreshAt: now,
            lastErrorCode: lastErrorCode,
            schemaVersion: 1,
            createdAt: now,
            updatedAt: now
        )
    }

    private func providerAccount(
        provider: AgentProvider,
        status: ProviderAccountStatus,
        label: String? = nil
    ) -> ProviderAccountDoc {
        let now = Date(timeIntervalSinceReferenceDate: 800_300_000 + Double(provider.rawValue.count))
        return ProviderAccountDoc(
            id: "\(provider.providerID.rawValue)-test",
            providerID: provider.providerID,
            label: label ?? provider.displayName,
            status: status,
            credentialKind: .bearer,
            storageScope: .deviceKeychain,
            redactedLabel: "Stored in test keychain",
            isDefault: true,
            sortKey: 0,
            lastValidatedAt: status == .connected ? now : nil,
            lastRefreshAt: status == .connected ? now : nil,
            schemaVersion: 1,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeStubSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        StubURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func httpResponse(url: URL, statusCode: Int, body: String) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, Data(body.utf8))
    }

    private func readJSON(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func recentUTCDate(daysAgo: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = calendar.startOfDay(for: Date())
        let shiftedDay = calendar.date(byAdding: .day, value: -daysAgo, to: base) ?? base
        return calendar.date(bySettingHour: hour, minute: 0, second: 1, of: shiftedDay) ?? shiftedDay
    }

    private func codexRolloutDirectory(home: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        let path = formatter.string(from: date)
        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions/\(path)", isDirectory: true)
    }

    private func codexRolloutFileURL(directory: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return directory.appendingPathComponent("rollout-\(formatter.string(from: date)).jsonl")
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private final class TestKeychainBackend: KeychainStoreBackend {
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

private final class StubURLProtocol: URLProtocol {
    /// Test-only global seam intentionally mutable across test setup/teardown.
    private static let _requestHandler = Locked<(@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)

    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { _requestHandler.read() }
        set { _requestHandler.write(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension ProviderQuotaServiceTests {
    // MARK: - Cursor

    func test_cursorRefresh_parsesUsageSummary_fromAPI() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        // Golden fixture: real cursor.sh/api/usage-summary response captured 2026-05-03
        let goldenResponse = """
        {
          "membershipType": "ultra",
          "individualUsage": {
            "plan": {
              "breakdown": {"bonus": 0, "included": 36063, "total": 36063},
              "enabled": true,
              "limit": 40000,
              "apiPercentUsed": 59.85,
              "used": 36063,
              "remaining": 3937,
              "autoPercentUsed": 6.138,
              "totalPercentUsed": 24.042
            },
            "onDemand": {"limit": 100, "enabled": true, "remaining": 100, "used": 0}
          },
          "limitType": "user",
          "billingCycleEnd": "2026-05-27T23:10:32.000Z",
          "isUnlimited": false,
          "billingCycleStart": "2026-04-27T23:10:32.000Z"
        }
        """

        let session = makeStubSession { request in
            if request.url?.absoluteString.contains("/api/usage-summary") ?? false {
                return try self.httpResponse(url: request.url!, statusCode: 200, body: goldenResponse)
            }
            if request.url?.absoluteString.contains("/api/auth/me") ?? false {
                return try self.httpResponse(url: request.url!, statusCode: 200, body: "{}")
            }
            throw URLError(.badURL)
        }

        // Simulate a valid JWT via env var (cursorAuth/accessToken from state.vscdb)
        let env = ["CURSOR_COOKIE_HEADER": "WorkosCursorSessionToken=test::eyJ.test.test"]

        let service = makeService(
            home: home, appSupportRoot: appSupport,
            session: session, environment: env)

        await service.refresh(provider: .cursor, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .cursor))

        // Confidence
        XCTAssertEqual(snapshot.confidence, .exact, "Cursor must be .exact — we hit the real API")
        XCTAssertEqual(snapshot.source, .officialAPI)

        // Plan bucket — real numbers from the golden fixture
        let planBucket = try XCTUnwrap(snapshot.buckets.first(where: { $0.key == "cursor-plan" }))
        XCTAssertEqual(planBucket.label, "Included usage")
        XCTAssertEqual(planBucket.isEstimated, false)
        let planPct = try XCTUnwrap(planBucket.usedPercent)
        XCTAssertEqual(planPct, 24.04, accuracy: 0.01, "Plan usage % must match golden fixture")

        // Used/limit in dollars (cents/100)
        let usedVal = try XCTUnwrap(planBucket.usedValue); XCTAssertEqual(usedVal, 360.63, accuracy: 0.01)
        let limitVal = try XCTUnwrap(planBucket.limitValue); XCTAssertEqual(limitVal, 400.00, accuracy: 0.01)
        XCTAssertEqual(planBucket.windowKind, .monthly)

        // Auto + Composer bucket
        let autoBucket = try XCTUnwrap(snapshot.buckets.first(where: { $0.key == "cursor-auto" }))
        XCTAssertEqual(autoBucket.label, "Auto + Composer")
        XCTAssertEqual(autoBucket.isEstimated, false)
        let autoPct = try XCTUnwrap(autoBucket.usedPercent)
        XCTAssertEqual(autoPct, 6.14, accuracy: 0.01)

        // API bucket
        let apiBucket = try XCTUnwrap(snapshot.buckets.first(where: { $0.key == "cursor-api" }))
        XCTAssertEqual(apiBucket.label, "API usage")
        XCTAssertEqual(apiBucket.isEstimated, false)
        let apiPct = try XCTUnwrap(apiBucket.usedPercent)
        XCTAssertEqual(apiPct, 59.85, accuracy: 0.01)

        // Status message
        XCTAssertTrue(snapshot.statusMessage.contains("Ultra"), "Expected Ultra tier, got: \(snapshot.statusMessage)")
        XCTAssertTrue(snapshot.statusMessage.contains("Capped"), "Expected Capped plan")

        // Plan bucket carries dollars; the unit must be `.currency` so the
        // gauge labels render as "$X.XX / $Y.YY" instead of decimals.
        XCTAssertEqual(planBucket.unit, .currency)

        // On-demand bucket exists when limit > 0, even if used=0 — this is correct.
        if let odBucket = snapshot.buckets.first(where: { $0.key == "cursor-ondemand" }) {
            XCTAssertEqual(odBucket.usedValue, 0.0)
            XCTAssertEqual(odBucket.limitValue, 1.0)  // 100 cents = $1.00
            XCTAssertEqual(odBucket.unit, .currency)
        }
    }


    func test_cursorRefresh_noAuth_returnsUnavailable() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: ["OPENBURNBAR_DISABLE_CURSOR_AUTO_AUTH": "1"]
        )

        await service.refresh(provider: .cursor, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .cursor))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertTrue(snapshot.statusMessage.contains("Sign in"), "Expected sign-in prompt, got: \(snapshot.statusMessage)")
    }

    // MARK: - Ollama Cloud

    func test_ollamaCloud_parsesFiveHourAndWeeklySettingsHTML() {
        let html = """
        <span>Cloud Usage</span><span>Pro</span>
        <div id="header-email">alberto@example.com</div>
        <section>
          <h3>5-hour usage</h3>
          <div style="width: 37.5%"></div>
          <time data-time="2026-05-05T20:00:00Z"></time>
        </section>
        <section>
          <h3>Weekly usage</h3>
          <div>62% used</div>
          <time data-time="2026-05-10T20:00:00Z"></time>
        </section>
        """

        let usage = OllamaCloudScraper.parseCloudUsage(html: html)

        XCTAssertEqual(usage.planName, "Pro")
        XCTAssertEqual(usage.accountEmail, "alberto@example.com")
        XCTAssertEqual(usage.sessionUsedPercent, 37.5)
        XCTAssertEqual(usage.weeklyUsedPercent, 62)
        XCTAssertNotNil(usage.sessionResetsAt)
        XCTAssertNotNil(usage.weeklyResetsAt)
    }

    func test_ollamaCloud_envHTMLProducesOnlyRealQuotaBuckets() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let html = """
        <span>Cloud Usage</span><span>Pro</span>
        <h3>Session usage</h3><div>12% used</div>
        <h3>Weekly usage</h3><div style="width: 34%"></div>
        """

        let session = makeStubSession { request in
            guard let urlString = request.url?.absoluteString else {
                throw URLError(.badURL)
            }
            if urlString.contains("api/tags") {
                let body = """
                {"models": [{"name": "llama3:cloud"}, {"name": "codellama"}]}
                """
                return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
            }
            if urlString.contains("api/ps") {
                return try self.httpResponse(url: request.url!, statusCode: 200, body: "{}")
            }
            throw URLError(.badURL)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            environment: [
                "OLLAMA_HOST": "http://localhost:11434",
                "OPENBURNBAR_OLLAMA_CLOUD_HTML": html
            ]
        )

        await service.refresh(provider: .ollama, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .ollama))

        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.buckets.map(\.key), ["ollama-cloud-session", "ollama-cloud-weekly"])
        XCTAssertEqual(snapshot.hourlyBucket?.windowKind, .rollingHours)
        XCTAssertEqual(snapshot.weeklyBucket?.windowKind, .weekly)
        XCTAssertFalse(snapshot.buckets.contains { $0.key.contains("local") || $0.key == "ollama-cloud" })
    }

    func test_refreshAll_persistsKimiSlotsByMappingMoonshotCatalogToKimiAdapter() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let runtimeSecrets = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        )
        let kimiJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1aWQiOiJrZW1pIn0.signature"
        try runtimeSecrets.set(kimiJWT, for: "provider.moonshot.slot.session.apiKey")

        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "moonshot",
                provider: .kimi,
                displayName: "Kimi (Moonshot)",
                isEnabled: true,
                baseURL: "https://api.moonshot.cn/v1",
                preferredModelIDs: [],
                preferredCredentialSlotID: "session",
                credentialSlots: [
                    OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                        slotID: "session",
                        label: "Browser Session",
                        isEnabled: true,
                        status: .ready,
                        cooldownUntil: nil,
                        lastSelectedAt: nil,
                        lastQuotaRemainingPercent: nil,
                        lastQuotaResetsAt: nil,
                        lastStatusMessage: nil
                    ),
                ]
            )
        ]

        let observedAuthorizations = Locked<[String]>([])
        let session = makeStubSession { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            observedAuthorizations.withLock { $0.append(authorization) }
            let body = """
            {
              "usages": [
                {
                  "scope": "FEATURE_CODING",
                  "detail": {
                    "used_tokens": 250000,
                    "total_tokens": 1000000,
                    "used_requests": 30,
                    "total_requests": 200,
                    "reset_time": "2026-05-15T00:00:00Z"
                  },
                  "limits": []
                }
              ]
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            providerRuntimeKeyStore: runtimeSecrets,
            session: session,
            refreshProviders: [.kimi]
        )

        let dataStore = try makeDataStore()
        await service.refreshAll(dataStore: dataStore)

        XCTAssertTrue(observedAuthorizations.read().contains("Bearer \(kimiJWT)"),
                      "Kimi adapter should authorize using daemon-slot Moonshot key. Saw: \(observedAuthorizations.read())")

        let snapshots = service.snapshots(for: .kimi)
        XCTAssertFalse(snapshots.isEmpty, "Expected Kimi snapshot from Moonshot daemon slot bleed-over")

        let persistedAccounts = try dataStore.providerAccountStore.fetchAll(providerID: ProviderID(rawValue: "moonshot"))
        XCTAssertEqual(persistedAccounts.map(\.id), ["moonshot-session"])
        XCTAssertEqual(persistedAccounts.first?.label, "Browser Session")
        XCTAssertEqual(persistedAccounts.first?.storageScope, .deviceKeychain)
    }

    func test_ollamaLocalAndCloudModelsWithoutScrapedQuotaDoNotCreateBuckets() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let session = makeStubSession { request in
            guard let urlString = request.url?.absoluteString else {
                throw URLError(.badURL)
            }
            if urlString.contains("api/tags") {
                let body = """
                {"models": [{"name": "llama3"}, {"name": "mistral:cloud"}]}
                """
                return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
            }
            if urlString.contains("api/ps") {
                return try self.httpResponse(url: request.url!, statusCode: 200, body: "{}")
            }
            throw URLError(.badURL)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            environment: ["OLLAMA_HOST": "http://localhost:11434"]
        )

        await service.refresh(provider: .ollama, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .ollama))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertFalse(snapshot.hasDisplayableQuotaSignal)
    }
}

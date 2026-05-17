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
        XCTAssertTrue(ProviderQuotaService.supportedProviders.contains(.deepSeek))
        // OpenAI is exposed as a quota-signal provider so the daemon can
        // persist credential slots and surface them in the routing cockpit
        // even though the admin-usage path is usage-only (no per-window
        // quota refresh). See `AgentProvider.quotaSignalProviders`.
        XCTAssertTrue(ProviderQuotaService.supportedProviders.contains(.openAI))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.hermes))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.aider))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.forgeDev))
        XCTAssertFalse(ProviderQuotaService.supportedProviders.contains(.kiloCode))
    }

    func test_quotaBucketResetDisplay_advancesPastRollingResetTimes() {
        let threeDaysAgo = Date().addingTimeInterval(-3 * 24 * 3600)
        let bucket = ProviderQuotaBucket(
            key: "codex-5h",
            label: "5h window",
            windowKind: .rollingHours,
            usedValue: 50,
            limitValue: 100,
            remainingValue: 50,
            usedPercent: 50,
            resetsAt: threeDaysAgo,
            unit: .percent,
            isEstimated: false
        )

        let display = bucket.resetsAtDisplay
        XCTAssertNotNil(display)
        XCTAssertFalse(display?.relative.contains("ago") ?? true)
    }

    func test_quotaBucketResetDisplay_keepsFutureResetTimes() {
        let inTwoHours = Date().addingTimeInterval(2 * 3600)
        let bucket = ProviderQuotaBucket(
            key: "codex-5h",
            label: "5h window",
            windowKind: .rollingHours,
            usedValue: 50,
            limitValue: 100,
            remainingValue: 50,
            usedPercent: 50,
            resetsAt: inTwoHours,
            unit: .percent,
            isEstimated: false
        )

        let display = bucket.resetsAtDisplay
        XCTAssertNotNil(display)
        XCTAssertFalse(display?.relative.contains("ago") ?? true)
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

    func test_refreshProviderPublishesDisplayableSnapshotsForCloudSync() async throws {
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
            refreshProviders: [.codex]
        )
        var publishedProviders: [AgentProvider] = []
        var publishedBucketCounts: [Int] = []
        service.onSnapshotsPersistedForCloudSync = { snapshots in
            publishedProviders = snapshots.map(\.provider)
            publishedBucketCounts = snapshots.map { $0.displayableQuotaBuckets.count }
        }

        await service.refresh(provider: .codex, dataStore: dataStore)

        XCTAssertEqual(publishedProviders, [.codex])
        XCTAssertEqual(publishedBucketCounts, [2])
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

    func test_automaticRefreshRunsWhenQuotaKeyChanges() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(service: "tests.\(UUID().uuidString)", legacyServices: [], backend: TestKeychainBackend())
        )
        let dataStore = try makeDataStore()
        let warpDirectory = home
            .appendingPathComponent("Library/Application Support/dev.warp.Warp-Stable", isDirectory: true)
        try FileManager.default.createDirectory(at: warpDirectory, withIntermediateDirectories: true)
        try Data("Body {\"batch\":[]}".utf8).write(to: warpDirectory.appendingPathComponent("warp_network.log"))
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            refreshProviders: [.warp]
        )
        service.startAutomaticRefresh(
            dataStore: dataStore,
            initialDelay: .seconds(60),
            interval: .seconds(60)
        )
        defer { service.stopAutomaticRefresh() }

        try keyStore.setAPIKey("not-used-by-warp", for: "warp")

        let deadline = Date().addingTimeInterval(2)
        while service.snapshot(for: .warp) == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertNotNil(service.snapshot(for: .warp))
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

    func test_claudeBridge_reinstallDropsSelfReferentialOriginalCommand() throws {
        let home = try makeTemporaryDirectory()
        let appSupportRoot = try makeTemporaryDirectory()
            .appendingPathComponent("Application Support", isDirectory: true)
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupportRoot)
        let wrapperPath = appPaths.claudeStatuslineBridgeScriptURL.path
        let quotedWrapperPath = "'\(wrapperPath.replacingOccurrences(of: "'", with: "'\\''"))'"

        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: [
            "statusLine": [
                "type": "command",
                "command": quotedWrapperPath
            ]
        ], options: [.prettyPrinted]).write(to: settingsURL)

        try FileManager.default.createDirectory(
            at: appPaths.claudeStatuslineBridgeMetadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: [
            "originalStatusLine": [
                "type": "command",
                "command": quotedWrapperPath
            ],
            "originalCommandSpec": [
                "executable": wrapperPath,
                "arguments": []
            ],
            "wrapperPath": wrapperPath
        ], options: [.prettyPrinted]).write(to: appPaths.claudeStatuslineBridgeMetadataURL)

        let service = makeService(home: home, appSupportRoot: appSupportRoot)

        try service.installClaudeQuotaBridge()

        let metadata = try readJSON(from: appPaths.claudeStatuslineBridgeMetadataURL)
        XCTAssertTrue(metadata["originalStatusLine"] is NSNull)
        XCTAssertTrue(metadata["originalCommandSpec"] is NSNull)

        let script = try String(contentsOf: appPaths.claudeStatuslineBridgeScriptURL)
        XCTAssertTrue(script.contains("os.path.realpath(executable) == os.path.realpath(wrapper_path)"))

        try service.removeClaudeQuotaBridge()
        let restoredSettings = try readJSON(from: settingsURL)
        XCTAssertNil(restoredSettings["statusLine"], "Removing a bridge with corrupted self-referential metadata must not restore the wrapper as the user's status line.")
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

    func test_claudeRefresh_keepsStaleBridgeSnapshotVisibleWhenAPIBillingOverrideDetected() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = """
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 10, "resets_at": "2026-03-24T15:00:00Z" },
            "seven_day": { "used_percentage": 40, "resets_at": "2026-03-31T15:00:00Z" }
          }
        }
        """
        try Data(payload.utf8).write(to: snapshotURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 60)],
            ofItemAtPath: snapshotURL.path
        )

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

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: ["ANTHROPIC_API_KEY": "sk-ant-test"]
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.source, .localCLI)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertTrue(snapshot.statusMessage.contains("API billing"))
        XCTAssertTrue(snapshot.statusMessage.contains("Stale last known Claude Code quota"))
        XCTAssertTrue(snapshot.isStale())
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "5-hour window" && $0.remainingPercent?.rounded() == 90 && $0.isEstimated }))
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "7-day window" && $0.remainingPercent?.rounded() == 60 && $0.isEstimated }))
    }

    func test_claudeRefresh_staleBridgeSnapshotFallsThroughToOAuthUsage() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let snapshotURL = appPaths.claudeStatuslineSnapshotURL
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stalePayload = """
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 10, "resets_at": "2026-03-24T15:00:00Z" },
            "seven_day": { "used_percentage": 40, "resets_at": "2026-03-31T15:00:00Z" }
          }
        }
        """
        try Data(stalePayload.utf8).write(to: snapshotURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 60)],
            ofItemAtPath: snapshotURL.path
        )

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

        let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 60 * 60))
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            return try self.httpResponse(
                url: url,
                statusCode: 200,
                body: """
                {
                  "rate_limits": {
                    "five_hour": { "used_percentage": 80, "resets_at": "\(reset)" },
                    "seven_day": { "used_percentage": 30, "resets_at": "\(reset)" }
                  }
                }
                """
            )
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-live",
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: "pro",
                rateLimitTier: "",
                organizationUuid: nil
            ))
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label.contains("5-hour") && $0.remainingPercent?.rounded() == 20 }))
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label.contains("7-day") && $0.remainingPercent?.rounded() == 70 }))
    }

    func test_claudeRefresh_oauthCacheHit_usesPersistedRateLimitsWithoutNetwork() async throws {
        // OAuth credentials present (env override) AND a fresh cache file
        // exists with reset windows in the future. Adapter must read the
        // cache and never call the live endpoint — verified by the stub
        // session XCTFailing on any request.
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let credentials = ClaudeOAuthCredentials(
            accessToken: "sk-ant-oat-fake",
            refreshToken: nil,
            expiresAt: nil,
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            organizationUuid: nil
        )
        let cacheURL = ClaudeOAuthUsageFetcher.scopedCacheURL(
            baseURL: OpenBurnBarAppPaths(applicationSupportRoot: appSupport).claudeOAuthUsageCacheURL,
            credentials: credentials
        )
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let envelope: [String: Any] = [
            "fetchedAt": formatter.string(from: now.addingTimeInterval(-60)),
            "fiveHourResetsAt": formatter.string(from: now.addingTimeInterval(3 * 60 * 60)),
            "sevenDayResetsAt": formatter.string(from: now.addingTimeInterval(5 * 24 * 60 * 60)),
            "payload": [
                "five_hour": ["used_percentage": 25, "resets_at": formatter.string(from: now.addingTimeInterval(3 * 60 * 60))],
                "seven_day": ["used_percentage": 5, "resets_at": formatter.string(from: now.addingTimeInterval(5 * 24 * 60 * 60))]
            ]
        ]
        let cacheData = try JSONSerialization.data(withJSONObject: envelope)
        try cacheData.write(to: cacheURL)

        let session = makeStubSession { request in
            XCTFail("Cache hit must not network. Got: \(request.url?.absoluteString ?? "?")")
            throw URLError(.cannotConnectToHost)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: credentials)
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertTrue(snapshot.statusMessage.contains("Max"))
        XCTAssertTrue(snapshot.statusMessage.contains("(cached)"))
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label.contains("5-hour") && $0.remainingPercent?.rounded() == 75 }))
    }

    func test_claudeRefresh_oauthLiveCall_writesCacheAndReportsExactRateLimits() async throws {
        // No cache, no statusline bridge — env credentials drive the live
        // OAuth call. The stub session returns a canned `rate_limits`
        // payload; the adapter must surface it as exact and persist it.
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let fiveHourReset = formatter.string(from: now.addingTimeInterval(4 * 60 * 60))
        let sevenDayReset = formatter.string(from: now.addingTimeInterval(6 * 24 * 60 * 60))

        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat-live")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            return try self.httpResponse(
                url: url,
                statusCode: 200,
                body: """
                {
                  "rate_limits": {
                    "five_hour": { "used_percentage": 80, "resets_at": "\(fiveHourReset)" },
                    "seven_day": { "used_percentage": 30, "resets_at": "\(sevenDayReset)" }
                  }
                }
                """
            )
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-live",
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: "pro",
                rateLimitTier: "",
                organizationUuid: nil
            ))
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertTrue(snapshot.statusMessage.contains("Pro"))
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label.contains("5-hour") && $0.remainingPercent?.rounded() == 20 }))

        // Cache file persisted for next refresh.
        let cacheURL = ClaudeOAuthUsageFetcher.scopedCacheURL(
            baseURL: OpenBurnBarAppPaths(applicationSupportRoot: appSupport).claudeOAuthUsageCacheURL,
            credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-live",
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: "pro",
                rateLimitTier: "",
                organizationUuid: nil
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func test_claudeRefresh_jsonlPlanCap_inferredMax20xCapPercent() async throws {
        // No bridge, no OAuth network response, but local JSONL has token
        // counts AND env credentials report Max-20x → adapter must
        // annotate JSONL buckets with the published 880K / 7.7M caps and
        // produce a usedPercent.
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let projectsDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let jsonlURL = projectsDir.appendingPathComponent("session.jsonl")
        let now = Date()
        let recentISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60 * 30))
        // 200K input + 20K output = 220K total — half of Max-20x five-hour cap.
        let line = """
        {"timestamp":"\(recentISO)","type":"assistant","message":{"usage":{"input_tokens":200000,"output_tokens":20000}}}
        """
        try Data(line.utf8).write(to: jsonlURL)

        // Stub session fails any network so OAuth path falls through.
        let session = makeStubSession { _ in throw URLError(.notConnectedToInternet) }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-fake",
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: "max",
                rateLimitTier: "default_claude_max_20x",
                organizationUuid: nil
            ))
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.source, .localSession)
        // Max-20x five-hour cap = 3.52M tokens. 220K / 3.52M ≈ 6.25%.
        let fiveHour = try XCTUnwrap(snapshot.buckets.first(where: { $0.key == "claude-five-hour-jsonl" }))
        XCTAssertEqual(fiveHour.limitValue, 3_520_000)
        XCTAssertEqual(fiveHour.usedPercent?.rounded(), 6)
        XCTAssertTrue(snapshot.statusMessage.contains("Max"))
    }

    func test_claudeRefresh_createsAccountSnapshotForSwitcherProfileConfigPath() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()
        let profileRoot = try makeTemporaryDirectory()
        let projectsDir = profileRoot
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("burnbar", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let jsonlURL = projectsDir.appendingPathComponent("session.jsonl")
        let recentISO = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 30))
        let line = """
        {"timestamp":"\(recentISO)","type":"assistant","message":{"usage":{"input_tokens":300000,"output_tokens":52000}}}
        """
        try Data(line.utf8).write(to: jsonlURL)

        let profile = try dataStore.switcherStore.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Claude Work",
                configDirectory: profileRoot.path,
                accountDescription: "Claude Work",
                providerID: .anthropic,
                linkedHarnessIDs: ["claude"]
            ),
            sortKey: 0
        ))

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: makeStubSession { _ in throw URLError(.notConnectedToInternet) },
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-expired",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(-3600),
                subscriptionType: "max",
                rateLimitTier: "default_claude_max_20x",
                organizationUuid: nil
            )),
            refreshProviders: [.claudeCode]
        )

        await service.refresh(provider: .claudeCode, dataStore: dataStore)
        let snapshot = try XCTUnwrap(service.snapshot(accountID: profile.id))

        XCTAssertEqual(snapshot.provider, .claudeCode)
        XCTAssertEqual(snapshot.providerID, .claudeCode)
        XCTAssertEqual(snapshot.accountID, profile.id)
        XCTAssertEqual(snapshot.accountLabel, "Claude Work")
        XCTAssertEqual(snapshot.source, .localSession)

        let fiveHour = try XCTUnwrap(snapshot.buckets.first(where: { $0.key == "claude-five-hour-jsonl" }))
        XCTAssertEqual(fiveHour.limitValue, 3_520_000)
        XCTAssertEqual(fiveHour.remainingPercent?.rounded(), 90)
    }

    func test_claudeRefresh_createsDistinctAccountSnapshotsForMultipleSwitcherProfiles() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()
        let formatter = ISO8601DateFormatter()
        let recentISO = formatter.string(from: Date().addingTimeInterval(-60 * 30))

        func createProfile(label: String, tokens: Int) throws -> SwitcherProfileRecord {
            let profileRoot = try makeTemporaryDirectory()
            let projectsDir = profileRoot
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(label.replacingOccurrences(of: " ", with: "-"), isDirectory: true)
            try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

            let jsonlURL = projectsDir.appendingPathComponent("session.jsonl")
            let line = """
            {"timestamp":"\(recentISO)","type":"assistant","message":{"usage":{"input_tokens":\(tokens),"output_tokens":0}}}
            """
            try Data(line.utf8).write(to: jsonlURL)

            return try dataStore.switcherStore.create(SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .claude,
                cliMetadata: SwitcherCLIProfileMetadata(
                    displayLabel: label,
                    configDirectory: profileRoot.path,
                    accountDescription: label,
                    providerID: .anthropic,
                    linkedHarnessIDs: ["claude"]
                ),
                sortKey: 0
            ))
        }

        let work = try createProfile(label: "Claude Work", tokens: 352_000)
        let personal = try createProfile(label: "Claude Personal", tokens: 1_760_000)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: makeStubSession { _ in throw URLError(.notConnectedToInternet) },
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-expired",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(-3600),
                subscriptionType: "max",
                rateLimitTier: "default_claude_max_20x",
                organizationUuid: nil
            )),
            refreshProviders: [.claudeCode]
        )

        await service.refresh(provider: .claudeCode, dataStore: dataStore)

        let workSnapshot = try XCTUnwrap(service.snapshot(accountID: work.id))
        let personalSnapshot = try XCTUnwrap(service.snapshot(accountID: personal.id))
        let workFiveHour = try XCTUnwrap(workSnapshot.buckets.first(where: { $0.key == "claude-five-hour-jsonl" }))
        let personalFiveHour = try XCTUnwrap(personalSnapshot.buckets.first(where: { $0.key == "claude-five-hour-jsonl" }))

        XCTAssertEqual(workSnapshot.accountLabel, "Claude Work")
        XCTAssertEqual(workSnapshot.sourceId, "switcher-cli:claude:\(work.id)")
        XCTAssertEqual(personalSnapshot.accountLabel, "Claude Personal")
        XCTAssertEqual(personalSnapshot.sourceId, "switcher-cli:claude:\(personal.id)")
        XCTAssertEqual(workFiveHour.remainingPercent?.rounded(), 90)
        XCTAssertEqual(personalFiveHour.remainingPercent?.rounded(), 50)
    }

    func test_claudeRefresh_switcherProfilesUseProfileOAuthUsageCredentials() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()
        let futureReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(4 * 60 * 60))
        let expiresAt = Int(Date().addingTimeInterval(60 * 60).timeIntervalSince1970 * 1000)

        func createProfile(label: String, token: String) throws -> SwitcherProfileRecord {
            let configRoot = try makeTemporaryDirectory()
            let credentialsURL = configRoot.appendingPathComponent(".credentials.json", isDirectory: false)
            let credentials = """
            {
              "claudeAiOauth": {
                "accessToken": "\(token)",
                "expiresAt": \(expiresAt),
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x"
              },
              "organizationUuid": "\(label)-org"
            }
            """
            try Data(credentials.utf8).write(to: credentialsURL)

            return try dataStore.switcherStore.create(SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .claude,
                cliMetadata: SwitcherCLIProfileMetadata(
                    displayLabel: label,
                    configDirectory: configRoot.path,
                    accountDescription: label,
                    providerID: .anthropic,
                    linkedHarnessIDs: ["claude"]
                ),
                sortKey: 0
            ))
        }

        let work = try createProfile(label: "Claude Work", token: "claude-work-token")
        let reserve = try createProfile(label: "Claude Reserve", token: "claude-reserve-token")
        let observedAuthorizations = Locked<[String]>([])
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            observedAuthorizations.withLock { $0.append(authorization) }
            let usedPercent: Int
            switch authorization {
            case "Bearer claude-work-token":
                usedPercent = 11
            case "Bearer claude-reserve-token":
                usedPercent = 64
            default:
                usedPercent = 99
            }
            return try self.httpResponse(
                url: url,
                statusCode: 200,
                body: """
                {
                  "five_hour": { "utilization": \(usedPercent), "resets_at": "\(futureReset)" },
                  "seven_day": { "utilization": 20, "resets_at": "\(futureReset)" }
                }
                """
            )
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            refreshProviders: [.claudeCode]
        )

        await service.refresh(provider: .claudeCode, dataStore: dataStore)

        let workSnapshot = try XCTUnwrap(service.snapshot(accountID: work.id))
        let reserveSnapshot = try XCTUnwrap(service.snapshot(accountID: reserve.id))
        let workFiveHour = try XCTUnwrap(workSnapshot.buckets.first(where: { $0.key == "claude-five_hour" }))
        let reserveFiveHour = try XCTUnwrap(reserveSnapshot.buckets.first(where: { $0.key == "claude-five_hour" }))

        XCTAssertEqual(workSnapshot.source, .officialAPI)
        XCTAssertEqual(workSnapshot.confidence, .exact)
        XCTAssertEqual(reserveSnapshot.source, .officialAPI)
        XCTAssertEqual(reserveSnapshot.confidence, .exact)
        XCTAssertEqual(workFiveHour.remainingPercent?.rounded(), 89)
        XCTAssertEqual(reserveFiveHour.remainingPercent?.rounded(), 36)
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer claude-work-token"))
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer claude-reserve-token"))
    }

    func test_claudeRefresh_switcherProfileDoesNotReuseGlobalStaleStatuslineSnapshot() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let dataStore = try makeDataStore()

        let snapshotURL = appPaths.claudeStatuslineSnapshotURL
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stalePayload = """
        {
          "rate_limits": {
            "five_hour": { "used_percentage": 8, "resets_at": "2026-05-14T16:40:00Z" },
            "seven_day": { "used_percentage": 21, "resets_at": "2026-05-20T06:00:00Z" }
          }
        }
        """
        try Data(stalePayload.utf8).write(to: snapshotURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 60)],
            ofItemAtPath: snapshotURL.path
        )

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

        let profileRoot = try makeTemporaryDirectory()
        let profile = try dataStore.switcherStore.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .claude,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Claude Work",
                configDirectory: profileRoot.path,
                accountDescription: "Claude Work",
                providerID: .anthropic,
                linkedHarnessIDs: ["claude"]
            ),
            sortKey: 0
        ))

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: makeStubSession { _ in throw URLError(.notConnectedToInternet) },
            refreshProviders: [.claudeCode]
        )

        await service.refresh(provider: .claudeCode, dataStore: dataStore)

        let accountSnapshot = try XCTUnwrap(service.snapshot(accountID: profile.id))
        XCTAssertEqual(accountSnapshot.source, .unavailable)
        XCTAssertEqual(accountSnapshot.confidence, .unavailable)
        XCTAssertTrue(accountSnapshot.buckets.isEmpty)
        XCTAssertTrue(accountSnapshot.statusMessage.contains("will not reuse another Claude account"))
    }

    func test_codexRefresh_usesEachSwitcherProfileConfigForSeparateOAuthQuota() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let dataStore = try makeDataStore()

        func createProfile(label: String, token: String) throws -> SwitcherProfileRecord {
            let configRoot = try makeTemporaryDirectory()
            let authURL = configRoot.appendingPathComponent("auth.json")
            let auth = """
            {
              "auth_mode": "chatgpt",
              "tokens": {
                "access_token": "\(token)"
              }
            }
            """
            try Data(auth.utf8).write(to: authURL)

            return try dataStore.switcherStore.create(SwitcherProfileRecord(
                targetKind: .cli,
                cliType: .codex,
                cliMetadata: SwitcherCLIProfileMetadata(
                    displayLabel: label,
                    configDirectory: configRoot.path,
                    accountDescription: label,
                    providerID: .openAI,
                    linkedHarnessIDs: ["codex"]
                ),
                sortKey: 0
            ))
        }

        let work = try createProfile(label: "Codex Work", token: "codex-work-token")
        let personal = try createProfile(label: "Codex Personal", token: "codex-personal-token")
        let observedAuthorizations = Locked<[String]>([])
        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            observedAuthorizations.withLock { $0.append(authorization) }

            let usedPercent: Int
            switch authorization {
            case "Bearer codex-work-token":
                usedPercent = 12
            case "Bearer codex-personal-token":
                usedPercent = 82
            default:
                usedPercent = 99
            }

            let body = """
            {
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": {
                  "used_percent": \(usedPercent),
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600
                },
                "secondary_window": {
                  "used_percent": 20,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 86400
                }
              }
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            refreshProviders: [.codex]
        )

        await service.refresh(provider: .codex, dataStore: dataStore)

        let workSnapshot = try XCTUnwrap(service.snapshot(accountID: work.id))
        let personalSnapshot = try XCTUnwrap(service.snapshot(accountID: personal.id))
        let workFiveHour = try XCTUnwrap(workSnapshot.buckets.first(where: { $0.key == "codex-5h" }))
        let personalFiveHour = try XCTUnwrap(personalSnapshot.buckets.first(where: { $0.key == "codex-5h" }))

        XCTAssertEqual(workSnapshot.accountLabel, "Codex Work")
        XCTAssertEqual(workSnapshot.sourceId, "switcher-cli:codex:\(work.id)")
        XCTAssertEqual(personalSnapshot.accountLabel, "Codex Personal")
        XCTAssertEqual(personalSnapshot.sourceId, "switcher-cli:codex:\(personal.id)")
        XCTAssertEqual(workFiveHour.remainingPercent?.rounded(), 88)
        XCTAssertEqual(personalFiveHour.remainingPercent?.rounded(), 18)
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer codex-work-token"))
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer codex-personal-token"))
    }

    func test_codexRefresh_prunesStaleManagedAccountSnapshotsForRemovedProfiles() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let store = ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default)
        let dataStore = try makeDataStore()

        let providerRollup = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: Date(timeIntervalSince1970: 100),
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Default Codex login",
            buckets: []
        )
        let staleSwitcher = ProviderQuotaSnapshot(
            provider: .codex,
            accountID: "stale-profile",
            accountLabel: "Old Codex profile",
            accountStorageScope: .localOnly,
            fetchedAt: Date(timeIntervalSince1970: 200),
            source: .localSession,
            sourceId: "switcher:stale-profile",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Stale switcher quota",
            buckets: []
        )
        let staleLegacyProvider = ProviderQuotaSnapshot(
            provider: .codex,
            accountID: "openai-work",
            accountLabel: "Old provider account",
            accountStorageScope: .localOnly,
            fetchedAt: Date(timeIntervalSince1970: 300),
            source: .localSession,
            sourceId: "provider:openai-work",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Stale legacy provider quota",
            buckets: []
        )
        store.persistSnapshots([.codex: providerRollup], accountSnapshots: [
            ProviderQuotaSnapshotStore.accountSnapshotKey(staleSwitcher): staleSwitcher,
            ProviderQuotaSnapshotStore.accountSnapshotKey(staleLegacyProvider): staleLegacyProvider,
        ])

        let configRoot = try makeTemporaryDirectory()
        let authURL = configRoot.appendingPathComponent("auth.json")
        let auth = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "access_token": "codex-current-token"
          }
        }
        """
        try Data(auth.utf8).write(to: authURL)
        let current = try dataStore.switcherStore.create(SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Codex Current",
                configDirectory: configRoot.path,
                accountDescription: "Codex Current",
                providerID: .openAI,
                linkedHarnessIDs: ["codex"]
            ),
            sortKey: 0
        ))

        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer codex-current-token")
            let body = """
            {
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 40,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 3600
                },
                "secondary_window": {
                  "used_percent": 10,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 86400
                }
              }
            }
            """
            return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
        }
        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            refreshProviders: [.codex]
        )

        await service.refresh(provider: .codex, dataStore: dataStore)

        let accountIDs = service.snapshots(for: AgentProvider.codex).compactMap(\.accountID)
        XCTAssertEqual(accountIDs, [current.id])
        XCTAssertNil(service.snapshot(accountID: "stale-profile"))
        XCTAssertNil(service.snapshot(accountID: "openai-work"))

        let currentSnapshot = try XCTUnwrap(service.snapshot(accountID: current.id))
        XCTAssertEqual(currentSnapshot.accountLabel, "Codex Current")
        XCTAssertEqual(currentSnapshot.primaryDisplayableBucket?.remainingPercent?.rounded(), 60)
        XCTAssertNil(service.snapshot(for: .codex)?.accountID)
    }

    func test_claudeRefresh_planOnlyBadge_renderedWhenNoUsageDataAvailable() async throws {
        // No bridge, no JSONL, OAuth network down — but Keychain (env
        // override) reports a Pro plan. Adapter must render a plan-badge
        // snapshot rather than "unavailable" so the user sees their plan
        // tier in the popover.
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let session = makeStubSession { _ in throw URLError(.notConnectedToInternet) }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-fake",
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: "pro",
                rateLimitTier: "",
                organizationUuid: nil
            ))
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertTrue(snapshot.buckets.contains(where: { $0.label == "Plan: Pro" }))
        XCTAssertTrue(snapshot.statusMessage.contains("Pro"))
    }

    func test_claudeCredentialsReader_decodesOAuthPayloadShape() throws {
        // Fixture matches Anthropic's OAuth payload shape
        // (claudeAiOauth wrapper, ms-precision expiresAt,
        // organizationUuid sibling) without touching user stores.
        let fixture = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat-real",
            "refreshToken": "sk-ant-ort-real",
            "expiresAt": 1778310120051,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          },
          "organizationUuid": "abc-123"
        }
        """
        let data = Data(fixture.utf8)
        let creds = try XCTUnwrap(ClaudeCredentialsReader.decode(data))
        XCTAssertEqual(creds.accessToken, "sk-ant-oat-real")
        XCTAssertEqual(creds.refreshToken, "sk-ant-ort-real")
        XCTAssertEqual(creds.subscriptionType, "max")
        XCTAssertEqual(creds.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(creds.organizationUuid, "abc-123")
        XCTAssertEqual(creds.planDisplayName, "Max")
        let routePayload = creds.routeCredentialStoragePayload()
        let routePayloadCreds = try XCTUnwrap(ClaudeCredentialsReader.decode(Data(routePayload.utf8)))
        XCTAssertEqual(routePayloadCreds.accessToken, "sk-ant-oat-real")
        XCTAssertEqual(routePayloadCreds.refreshToken, "sk-ant-ort-real")
        XCTAssertEqual(routePayloadCreds.subscriptionType, "max")
        XCTAssertEqual(routePayloadCreds.rateLimitTier, "default_claude_max_20x")
        XCTAssertEqual(routePayloadCreds.organizationUuid, "abc-123")
        // 1778310120051 ms ≈ 2026-04-26 — well in the future from
        // today's session date but exercise the parser regardless.
        XCTAssertNotNil(creds.expiresAt)
    }

    func test_claudeQuotaSourceDoesNotReadClaudeCredentialStores() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceFiles = [
            "AgentLens/Services/ProviderQuota/ClaudeCredentialsReader.swift",
            "AgentLens/Services/ProviderQuota/ClaudeQuotaAdapter.swift",
            "AgentLens/Services/ProviderQuota/ProviderQuotaService.swift",
            "AgentLens/Services/ProviderQuota/QuotaRefreshActor.swift"
        ]
        let forbidden = [
            "Claude Code-credentials",
            "SecItemCopyMatching",
            "SecKeychain",
            "kSecAttrService",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CREDENTIALS_SKIP_KEYCHAIN",
            "Data(contentsOf: credentialsFileURL"
        ]

        for relativePath in sourceFiles {
            let url = repoRoot.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: url, encoding: .utf8)
            for needle in forbidden {
                XCTAssertFalse(
                    contents.contains(needle),
                    "\(relativePath) must not contain \(needle); Claude quota must not read third-party credential stores."
                )
            }
        }
    }

    func test_claudeCredentials_canCallUsageEndpoint_acceptsExpiredAccessWithRefreshToken() {
        // Expired access token + refresh token → allowed (the fetcher
        // will refresh transparently). Expired access + no refresh →
        // not allowed (would 401 immediately).
        let now = Date()
        let withRefresh = ClaudeOAuthCredentials(
            accessToken: "sk-ant-oat-expired",
            refreshToken: "sk-ant-ort-fresh",
            expiresAt: now.addingTimeInterval(-3600),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            organizationUuid: nil
        )
        XCTAssertTrue(withRefresh.isExpired(now: now))
        XCTAssertTrue(withRefresh.canCallUsageEndpoint(now: now))

        let withoutRefresh = ClaudeOAuthCredentials(
            accessToken: "sk-ant-oat-expired",
            refreshToken: nil,
            expiresAt: now.addingTimeInterval(-3600),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            organizationUuid: nil
        )
        XCTAssertTrue(withoutRefresh.isExpired(now: now))
        XCTAssertFalse(withoutRefresh.canCallUsageEndpoint(now: now))
    }

    func test_claudeRateLimits_parsesAnthropicResponseShapeAndExposesTypedWindows() {
        // Real-shape `/api/oauth/usage` body — verify the strongly
        // typed model captures used %, remaining %, and resets_at as
        // a parsed Date. Falls back from `rate_limits` wrapper or bare
        // payload — both shapes are accepted for future-proofing.
        let now = Date()
        let resetISO = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 60 * 60))
        let body = """
        {
          "rate_limits": {
            "five_hour": {
              "used_percentage": 42,
              "resets_at": "\(resetISO)"
            },
            "seven_day": {
              "used_percentage": 60,
              "resets_at": "\(resetISO)"
            }
          }
        }
        """
        let parsed = ClaudeRateLimits(from: Data(body.utf8))
        XCTAssertEqual(parsed.windows.count, 2)
        let five = try? XCTUnwrap(parsed.window(named: "five_hour"))
        XCTAssertEqual(five?.usedPercentage, 42)
        XCTAssertEqual(five?.remainingPercentage, 58) // derived from used
        XCTAssertNotNil(five?.resetsAt)

        // Bare payload (no rate_limits wrapper) also accepted.
        let bareBody = """
        {"five_hour": {"used_percentage": 10}}
        """
        let bare = ClaudeRateLimits(from: Data(bareBody.utf8))
        XCTAssertEqual(bare.windows.count, 1)
        XCTAssertEqual(bare.window(named: "five_hour")?.usedPercentage, 10)
    }

    func test_claudeRateLimits_parsesCurrentTopLevelUtilizationShape() throws {
        let body = """
        {
          "five_hour": {
            "utilization": 100.0,
            "resets_at": "2026-05-17T18:40:00.399875+00:00"
          },
          "seven_day": {
            "utilization": 18.0,
            "resets_at": "2026-05-24T12:00:00.399900+00:00"
          },
          "seven_day_oauth_apps": null
        }
        """

        let parsed = ClaudeRateLimits(from: Data(body.utf8))
        let fiveHour = try XCTUnwrap(parsed.window(named: "five_hour"))
        let sevenDay = try XCTUnwrap(parsed.window(named: "seven_day"))

        XCTAssertEqual(fiveHour.usedPercentage, 100)
        XCTAssertEqual(fiveHour.remainingPercentage, 0)
        XCTAssertNotNil(fiveHour.resetsAt)
        XCTAssertEqual(sevenDay.usedPercentage, 18)
        XCTAssertEqual(sevenDay.remainingPercentage, 82)
        XCTAssertNotNil(sevenDay.resetsAt)
    }

    func test_claudeRefresh_oauthExpiredAccessToken_refreshesBeforeUsageCallWithoutPersistingThirdPartyCredentials() async throws {
        // Expired access token + refresh token → fetcher must hit the
        // token endpoint first, then the usage endpoint with the new
        // token. The refreshed credential stays in memory only; the
        // app must not mutate Claude Code's credential files.
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let futureReset = formatter.string(from: now.addingTimeInterval(4 * 60 * 60))

        // `@Sendable` stub session closures cannot mutate captured
        // vars, so the proof that the refresh+usage chain ran lives in
        // the usage request assertion and the returned snapshot.
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            if url.absoluteString == "https://platform.claude.com/v1/oauth/token" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                // URLProtocol strips httpBody on some flow paths; the
                // body lives in `httpBodyStream` then. Read whichever
                // is populated so the assertion is robust.
                let rawBody: Data = request.httpBody ?? {
                    guard let stream = request.httpBodyStream else { return Data() }
                    stream.open()
                    defer { stream.close() }
                    var collected = Data()
                    let bufferSize = 4096
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                    defer { buffer.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buffer, maxLength: bufferSize)
                        if read <= 0 { break }
                        collected.append(buffer, count: read)
                    }
                    return collected
                }()
                let body = String(data: rawBody, encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("grant_type=refresh_token"), "body=\(body)")
                XCTAssertTrue(body.contains("refresh_token=sk-ant-ort-good"), "body=\(body)")
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "sk-ant-oat-NEW",
                      "refresh_token": "sk-ant-ort-NEW",
                      "expires_in": 28800
                    }
                    """
                )
            }
            if url.absoluteString == "https://api.anthropic.com/api/oauth/usage" {
                // Critical: the usage call MUST carry the refreshed
                // token. If we still see the expired one, refresh
                // didn't run and the assertion fails inline.
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer sk-ant-oat-NEW",
                    "Usage endpoint must use the refreshed access token."
                )
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "rate_limits": {
                        "five_hour": { "used_percentage": 12, "resets_at": "\(futureReset)" }
                      }
                    }
                    """
                )
            }
            XCTFail("Unexpected URL: \(url.absoluteString)")
            throw URLError(.cannotConnectToHost)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            session: session,
            claudeCredentialsReader: StaticClaudeCredentialsReader(credentials: ClaudeOAuthCredentials(
                accessToken: "sk-ant-oat-old",
                refreshToken: "sk-ant-ort-good",
                expiresAt: now.addingTimeInterval(-3600),
                subscriptionType: "pro",
                rateLimitTier: "default_claude_pro_5x",
                organizationUuid: nil
            ))
        )

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .claudeCode))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertTrue(snapshot.buckets.contains { $0.usedPercent?.rounded() == 12 })

        let credentialsURL = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: credentialsURL.path),
            "OpenBurnBar must not create or rewrite Claude Code credential files."
        )
    }

    func test_claudeRefresh_autoInstall_marksAttemptedAndSkipsOnSecondRefresh() async throws {
        // Bridge isn't installed but ~/.claude/projects exists → the
        // adapter should auto-install. On the SECOND refresh, even if
        // the first install left the bridge in a non-ready state, we
        // must not try to install again (the marker file prevents
        // retry loops on read-only home dirs).
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeDir.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )

        // Stub session never expected to be hit — no credentials.
        let session = makeStubSession { _ in throw URLError(.notConnectedToInternet) }
        let service = makeService(home: home, appSupportRoot: appSupport, session: session)

        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let markerURL = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
            .claudeStatuslineSnapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent("claude-bridge-auto-install-attempted.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path),
            "First refresh must record an auto-install attempt marker.")

        // Capture marker mtime, then refresh again. mtime must not
        // change because the second pass should skip auto-install.
        let firstAttrs = try FileManager.default.attributesOfItem(atPath: markerURL.path)
        let firstMTime = (firstAttrs[.modificationDate] as? Date) ?? .distantPast

        // Sleep briefly so any retry would produce a measurably later
        // mtime — keeps the test deterministic at sub-second resolution.
        try await Task.sleep(nanoseconds: 200_000_000)
        await service.refresh(provider: .claudeCode, dataStore: try makeDataStore())
        let secondAttrs = try FileManager.default.attributesOfItem(atPath: markerURL.path)
        let secondMTime = (secondAttrs[.modificationDate] as? Date) ?? .distantPast
        XCTAssertEqual(firstMTime, secondMTime,
            "Second refresh must not rewrite the auto-install marker (loop prevention).")
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

    /// Regression: without a Factory session cookie or env override the
    /// adapter falls through to `~/.factory/sessions/**/*.settings.json`. Those
    /// session files carry real tokenUsage counts but no plan limits, which
    /// used to drop every bucket through the displayable-quota filter
    /// (`isDisplayableQuotaSignal` requires a non-nil `limitValue` for `.tokens`).
    /// The adapter must now anchor each window to the configured plan tier so
    /// the popover renders 5h / 7d / monthly buckets with `.exact` confidence.
    func test_factoryRefresh_localSessions_renderDisplayableBucketsAgainstPlanCap() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let sessionsDir = home
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // 1M tokens within the last 5 hours
        let recent = isoFormatter.string(from: Date().addingTimeInterval(-60 * 60))
        let recentSession = """
        {
          "model": "claude-3-5-sonnet",
          "providerLock": "factory",
          "providerLockTimestamp": "\(recent)",
          "tokenUsage": {
            "inputTokens": 900000,
            "outputTokens": 100000,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "thinkingTokens": 0
          }
        }
        """
        try recentSession.write(
            to: sessionsDir.appendingPathComponent("recent.settings.json"),
            atomically: true,
            encoding: .utf8
        )

        // 2M tokens earlier this week (~3 days ago)
        let lastWeek = isoFormatter.string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60))
        let weekSession = """
        {
          "model": "claude-3-5-sonnet",
          "providerLock": "factory",
          "providerLockTimestamp": "\(lastWeek)",
          "tokenUsage": {
            "inputTokens": 1500000,
            "outputTokens": 500000,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "thinkingTokens": 0
          }
        }
        """
        try weekSession.write(
            to: sessionsDir.appendingPathComponent("week.settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            // No FACTORY_* env, no cookie → adapter must fall through to the
            // local-session reader.
            environment: [:],
            factoryPlanProvider: { .pro }
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        XCTAssertEqual(snapshot.source, .localSession)
        XCTAssertEqual(snapshot.confidence, .exact, "Pro plan tier ⇒ exact, not estimated")
        XCTAssertTrue(snapshot.hasDisplayableQuotaSignal,
                      "Local-session buckets must survive the displayable filter")

        // 5-hour bucket: 1M / 20M = 5%
        let fiveHour = try XCTUnwrap(snapshot.hourlyBucket)
        XCTAssertEqual(fiveHour.usedValue?.rounded(), 1_000_000)
        XCTAssertEqual(fiveHour.limitValue, 20_000_000)
        XCTAssertEqual(fiveHour.usedPercent?.rounded(), 5)
        XCTAssertEqual(fiveHour.isEstimated, false)

        // 7-day bucket: (1M + 2M) / 20M = 15%
        let weekly = try XCTUnwrap(snapshot.weeklyBucket)
        XCTAssertEqual(weekly.usedValue?.rounded(), 3_000_000)
        XCTAssertEqual(weekly.limitValue, 20_000_000)
        XCTAssertEqual(weekly.usedPercent?.rounded(), 15)

        // Monthly bucket carries the same data window but the displayable
        // 30-day label.
        let monthly = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-30d" })
        XCTAssertEqual(monthly.usedValue?.rounded(), 3_000_000)
        XCTAssertEqual(monthly.limitValue, 20_000_000)
        XCTAssertTrue(monthly.label.contains("Pro"))
    }

    /// When the user has not picked a plan tier the adapter must still render
    /// buckets (using the inferred Pro cap) so the popover doesn't sit on
    /// "Readable quota not available yet" out of the box. The snapshot is
    /// marked `.estimated` and each bucket carries `isEstimated: true` so the
    /// UI can signal the inferred-vs-confirmed distinction.
    func test_factoryRefresh_localSessions_withUnknownPlanTier_marksEstimatedButStillDisplays() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let sessionsDir = home
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = isoFormatter.string(from: Date().addingTimeInterval(-3 * 60 * 60))

        let payload = """
        {
          "model": "claude-3-5-sonnet",
          "providerLock": "factory",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 500000,
            "outputTokens": 100000,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "thinkingTokens": 0
          }
        }
        """
        try payload.write(
            to: sessionsDir.appendingPathComponent("session.settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: [:],
            factoryPlanProvider: { .unknown }
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        XCTAssertEqual(snapshot.confidence, .estimated,
                       "Unknown plan tier ⇒ snapshot is flagged estimated")
        XCTAssertTrue(snapshot.hasDisplayableQuotaSignal)
        XCTAssertTrue(snapshot.statusMessage.contains("Set your plan tier"),
                      "Status should nudge users to confirm their plan tier — got: \(snapshot.statusMessage)")

        let monthly = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-30d" })
        XCTAssertEqual(monthly.isEstimated, true)
        XCTAssertEqual(monthly.limitValue, 20_000_000, "Inferred Pro cap")
        XCTAssertTrue(monthly.label.contains("inferred"))
    }

    /// Confirms the new Plus tier (May 2026 pricing) reports a 100M monthly
    /// cap (~5x Pro) across all three rolling windows and is treated as a
    /// confirmed plan tier — no `inferred` marker, `.exact` confidence, no
    /// "Set your plan tier" status nudge.
    func test_factoryRefresh_localSessions_plusPlanTier_uses100MmonthlyCap() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let sessionsDir = home
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // 10M tokens recently → 10% of Plus monthly cap (100M)
        let stamp = isoFormatter.string(from: Date().addingTimeInterval(-2 * 60 * 60))
        let payload = """
        {
          "model": "claude-3-5-sonnet",
          "providerLock": "factory",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 8000000,
            "outputTokens": 2000000,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "thinkingTokens": 0
          }
        }
        """
        try payload.write(
            to: sessionsDir.appendingPathComponent("plus.settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: [:],
            factoryPlanProvider: { .plus }
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        XCTAssertEqual(snapshot.confidence, .exact,
                       "Plus is a confirmed tier, not estimated")
        XCTAssertFalse(snapshot.statusMessage.contains("Set your plan tier"),
                       "Confirmed Plus tier should not prompt the user to pick a tier")

        // 5h / 7d / 30d all anchored to the 100M Plus cap.
        for key in ["factory-5h", "factory-7d", "factory-30d"] {
            let bucket = try XCTUnwrap(snapshot.buckets.first { $0.key == key }, "Missing bucket: \(key)")
            XCTAssertEqual(bucket.limitValue, 100_000_000, "\(key) should anchor to Plus 100M cap")
            XCTAssertEqual(bucket.usedValue?.rounded(), 10_000_000)
            XCTAssertEqual(bucket.usedPercent?.rounded(), 10)
            XCTAssertEqual(bucket.isEstimated, false, "\(key) is not estimated for confirmed Plus tier")
        }

        let monthly = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-30d" })
        XCTAssertTrue(monthly.label.contains("Plus"),
                      "Monthly bucket label should advertise Plus tier — got: \(monthly.label)")
    }

    /// Pricing copy guard — every confirmed tier surfaces the Droid Core /
    /// Extra Usage fallback in the status message so users can find the
    /// escape hatch without leaving OpenBurnBar.
    func test_factoryRefresh_localSessions_statusMessageMentionsDroidCoreAndExtraUsageFallback() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let sessionsDir = home
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = isoFormatter.string(from: Date().addingTimeInterval(-30 * 60))

        let payload = """
        {
          "model": "claude-3-5-sonnet",
          "providerLock": "factory",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 100000,
            "outputTokens": 50000,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "thinkingTokens": 0
          }
        }
        """
        try payload.write(
            to: sessionsDir.appendingPathComponent("session.settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: [:],
            factoryPlanProvider: { .max }
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        XCTAssertTrue(
            snapshot.statusMessage.contains("Droid Core"),
            "Status message must mention Droid Core fallback — got: \(snapshot.statusMessage)"
        )
        XCTAssertTrue(
            snapshot.statusMessage.contains("Extra Usage"),
            "Status message must mention Extra Usage fallback — got: \(snapshot.statusMessage)"
        )
    }

    // MARK: - Factory Collection Upgrades (May 2026)

    /// CRITICAL collection bug: sessions where `providerLock != "factory"`
    /// are user-configured custom proxies (VibeProxy, OpenCode-Go,
    /// localhost Ollama, BYOK). They route through `config.json
    /// .custom_models[]` and are NOT billed by Factory. The adapter must
    /// exclude them from every Standard Usage bucket and instead surface
    /// the count in the diagnostic `factory-custom-proxy-30d` bucket.
    /// Before this filter, a power-user with 1488 custom-proxy sessions
    /// and 26 factory-billed sessions saw the 1488 sessions overwhelm
    /// the Pro 20M cap and the popover showed 100% within a week.
    func test_factoryRefresh_localSessions_excludesCustomProxySessionsFromStandardUsageBuckets() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let sessionsDir = home
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = iso.string(from: Date().addingTimeInterval(-60 * 60))

        // 1M tokens — VibeProxy passthrough (user-configured proxy, NOT billed)
        let vibeProxy = """
        {
          "model": "custom:VibeProxy:-GPT-5.5-(High)-18",
          "providerLock": "generic-chat-completion-api",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 900000,
            "outputTokens": 100000,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "thinkingTokens": 0
          }
        }
        """
        try vibeProxy.write(to: sessionsDir.appendingPathComponent("vibe.settings.json"), atomically: true, encoding: .utf8)

        // 1M tokens — anthropic via custom_models (user-configured, NOT billed)
        let anthropicProxy = """
        {
          "model": "custom:Claude-Opus-4.7-Max-[VibeProxy]-15",
          "providerLock": "anthropic",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 900000,
            "outputTokens": 100000,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "thinkingTokens": 0
          }
        }
        """
        try anthropicProxy.write(to: sessionsDir.appendingPathComponent("anth.settings.json"), atomically: true, encoding: .utf8)

        // 500K tokens — REAL Factory session (claude on Factory's lane)
        let factory = """
        {
          "model": "claude-opus-4-7",
          "providerLock": "factory",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 400000,
            "outputTokens": 100000,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "thinkingTokens": 0
          }
        }
        """
        try factory.write(to: sessionsDir.appendingPathComponent("factory.settings.json"), atomically: true, encoding: .utf8)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: [:],
            factoryPlanProvider: { .pro }
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        // The 30-day Factory bucket MUST contain only the 500K from the
        // factory-billed session — NOT the 2M from custom proxies.
        let monthly = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-30d" })
        XCTAssertEqual(monthly.usedValue?.rounded(), 500_000,
                       "Custom proxy sessions must not count against Factory Standard Usage")

        // 5h bucket: same — only 500K.
        let fiveHour = try XCTUnwrap(snapshot.hourlyBucket)
        XCTAssertEqual(fiveHour.usedValue?.rounded(), 500_000)

        // Diagnostic custom-proxy bucket reports the 2M total of excluded usage.
        let proxyBucket = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-custom-proxy-30d" })
        XCTAssertEqual(proxyBucket.usedValue?.rounded(), 2_000_000)
        XCTAssertFalse(proxyBucket.isDisplayableQuotaSignal,
                       "Custom-proxy bucket is diagnostic; must not be on the headline gauge")

        XCTAssertTrue(snapshot.statusMessage.contains("Excluded 2 custom-proxy session(s)"),
                      "Status message must disclose the proxy session count — got: \(snapshot.statusMessage)")
    }

    /// Droid Core open-weight models (kimi, glm, deepseek, minimax,
    /// qwen) running on Factory's lane get a separate informational
    /// bucket so users can see the split between Premium frontier burn
    /// (which can exhaust Standard Usage) and Core burn (which falls
    /// back to a free pool when Standard is depleted).
    func test_factoryRefresh_localSessions_classifiesDroidCoreModelsAsSeparateBucket() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let sessionsDir = home
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = iso.string(from: Date().addingTimeInterval(-30 * 60))

        // 600K tokens — Premium frontier model (Claude) on Factory's lane.
        let premium = """
        {
          "model": "claude-opus-4-7",
          "providerLock": "factory",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 500000,
            "outputTokens": 100000,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "thinkingTokens": 0
          }
        }
        """
        try premium.write(to: sessionsDir.appendingPathComponent("premium.settings.json"), atomically: true, encoding: .utf8)

        // 400K tokens — Droid Core open-weight model on Factory's lane.
        let core = """
        {
          "model": "kimi-k2.6",
          "providerLock": "factory",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 350000,
            "outputTokens": 50000,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "thinkingTokens": 0
          }
        }
        """
        try core.write(to: sessionsDir.appendingPathComponent("core.settings.json"), atomically: true, encoding: .utf8)

        // 300K tokens — glm-5 (also Droid Core).
        let glm = """
        {
          "model": "glm-5",
          "providerLock": "factory",
          "providerLockTimestamp": "\(stamp)",
          "tokenUsage": {
            "inputTokens": 250000,
            "outputTokens": 50000,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "thinkingTokens": 0
          }
        }
        """
        try glm.write(to: sessionsDir.appendingPathComponent("glm.settings.json"), atomically: true, encoding: .utf8)

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            environment: [:],
            factoryPlanProvider: { .pro }
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        // Combined 30d burn = 1.3M (Premium 600K + Core 700K).
        let monthly = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-30d" })
        XCTAssertEqual(monthly.usedValue?.rounded(), 1_300_000)

        // Standard lane shows just the 600K Premium burn.
        let standard = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-standard-30d" })
        XCTAssertEqual(standard.usedValue?.rounded(), 600_000)
        XCTAssertTrue(standard.label.contains("Standard"))

        // Droid Core lane shows 700K (kimi 400K + glm 300K).
        let core30 = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-droid-core-30d" })
        XCTAssertEqual(core30.usedValue?.rounded(), 700_000)
        XCTAssertNil(core30.limitValue,
                     "Droid Core lane has no published cap — it's a separate free pool")
    }

    /// Plan auto-detection from `/api/app/auth/me` — `factoryTier=plus`
    /// or `plan.name = "Plus"` must map to `FactoryQuotaPlanTier.plus`
    /// regardless of casing. This lets the popover show the right cap
    /// without users picking a tier in Settings.
    func test_factoryAdapter_inferPlanTier_recognizesAllTiersFromAuthResponse() {
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: "pro", planName: nil), .pro)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: nil, planName: "Pro Plan"), .pro)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: "plus", planName: nil), .plus)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: nil, planName: "Plus"), .plus)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: "max", planName: nil), .max)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: nil, planName: "Max — Enterprise Trial"), .max)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: "ultra", planName: nil), .max,
                       "'ultra' aliases Max — Factory's feature flag uses this name")
        // Order: "max" must win even when "pro" is also present.
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: "max", planName: "Pro upgraded to Max"), .max)
        // Enterprise / Teams / unknown → .unknown (no cap pretense).
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: "team", planName: "Team"), .unknown)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: "enterprise", planName: "Enterprise"), .unknown)
        XCTAssertEqual(FactoryQuotaAdapter.inferPlanTier(tier: nil, planName: nil), .unknown)
    }

    /// Classifier coverage — every lane the adapter cares about.
    func test_factorySessionClassifier_assignsLanesByProviderLockAndModelFamily() {
        let cases: [(json: [String: Any], expected: FactorySessionLane, label: String)] = [
            (["providerLock": "factory", "model": "kimi-k2.6"], .droidCore, "kimi → Core"),
            (["providerLock": "factory", "model": "glm-5.1"], .droidCore, "glm → Core"),
            (["providerLock": "factory", "model": "deepseek-v4-pro"], .droidCore, "deepseek → Core"),
            (["providerLock": "factory", "model": "minimax-m2.7"], .droidCore, "minimax → Core"),
            (["providerLock": "factory", "model": "qwen3.6-plus"], .droidCore, "qwen → Core"),
            (["providerLock": "factory", "model": "claude-opus-4-7"], .standard, "claude → Standard"),
            (["providerLock": "factory", "model": "gpt-5.5"], .standard, "gpt → Standard"),
            (["providerLock": "factory", "model": "gemini-2.5"], .standard, "gemini → Standard"),
            (["providerLock": "factory", "model": "o4-something"], .standard, "o-series → Standard"),
            (["providerLock": "factory", "model": "mystery-new-llm"], .factoryUnknown, "unknown model still on Factory lane"),
            (["providerLock": "openai", "model": "gpt-5.5(high)"], .customProxy, "openai providerLock → custom proxy"),
            (["providerLock": "anthropic", "model": "claude-opus-4-6"], .customProxy, "anthropic providerLock → custom proxy"),
            (["providerLock": "generic-chat-completion-api", "model": "kimi-k2.6:cloud"], .customProxy, "generic-chat-completion → custom proxy"),
            (["providerLock": "google", "model": "gemini-2.5"], .customProxy, "google providerLock → custom proxy"),
            (["providerLock": "", "model": "anything"], .customProxy, "empty providerLock → custom proxy"),
            (["model": "claude-opus-4-7"], .customProxy, "missing providerLock → custom proxy")
        ]
        for testCase in cases {
            XCTAssertEqual(
                FactorySessionClassifier.lane(for: testCase.json),
                testCase.expected,
                "Failed: \(testCase.label)"
            )
        }
    }

    /// Classifier strips the `custom:` prefix and `:cloud-N` suffix that
    /// the CLI adds when routing a Factory-native model through a user
    /// proxy. Without this normalization, "custom:Kimi-K2.6-Highspeed-3"
    /// would not match the kimi prefix.
    func test_factorySessionClassifier_normalizesCustomPrefixAndCloudSuffix() {
        let cases: [String: FactorySessionLane] = [
            "custom:kimi-k2.6-highspeed-3": .droidCore,
            "custom:glm-5.1:cloud-0":       .droidCore,
            "custom:Kimi-K2.6":             .droidCore,    // mixed case
            "kimi-k2.6:cloud-7":            .droidCore,
            "Kimi K2.6":                    .droidCore,    // display-name with spaces
            "custom:claude-opus-4-7":       .standard,
            "custom:gpt-5.5(xhigh)":        .standard
        ]
        for (model, expected) in cases {
            XCTAssertEqual(
                FactorySessionClassifier.lane(for: ["providerLock": "factory", "model": model]),
                expected,
                "Model '\(model)' should classify as \(expected)"
            )
        }
    }

    /// `/api/organization/subscription/usage` now exposes Droid Core
    /// lane stats and an Extra Usage prepaid wallet. The adapter must
    /// surface both as distinct buckets so the popover can render
    /// "Standard / Premium / Core / $X Extra".
    func test_factoryRefresh_exactAPI_surfacesDroidCoreLaneAndExtraUsageWallet() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/api/app/auth/me") {
                return try self.httpResponse(
                    url: url, statusCode: 200,
                    body: #"""
                    {
                      "organization": {
                        "name": "Acme",
                        "subscription": {
                          "factoryTier": "plus",
                          "orbSubscription": {
                            "status": "active",
                            "plan": { "name": "Plus" }
                          }
                        }
                      }
                    }
                    """#
                )
            }
            if url.path.hasSuffix("/api/organization/subscription/usage") {
                return try self.httpResponse(
                    url: url, statusCode: 200,
                    body: #"""
                    {
                      "usage": {
                        "endDate": 1774359600000,
                        "standard": {
                          "userTokens": 60000000,
                          "totalAllowance": 100000000,
                          "usedRatio": 0.60
                        },
                        "premium": {
                          "userTokens": 12000000,
                          "totalAllowance": 20000000,
                          "usedRatio": 0.60
                        },
                        "droidCore": {
                          "userTokens": 5000000,
                          "totalAllowance": 50000000,
                          "usedRatio": 0.10
                        },
                        "extraUsage": {
                          "balanceUSD": 12.34,
                          "enabled": true
                        }
                      }
                    }
                    """#
                )
            }
            XCTFail("Unexpected URL \(url.absoluteString)")
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
            factoryPlanProvider: { .unknown }  // API auto-detect should override
        )

        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)

        let standard = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-standard" })
        XCTAssertEqual(standard.usedPercent?.rounded(), 60)

        let core = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-droid-core" },
                                 "Droid Core lane bucket must be present when API exposes it")
        XCTAssertEqual(core.label, "Droid Core (open-weight)")
        XCTAssertEqual(core.usedValue?.rounded(), 5_000_000)
        XCTAssertEqual(core.limitValue?.rounded(), 50_000_000)
        XCTAssertEqual(core.usedPercent?.rounded(), 10)

        let extra = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-extra-usage" },
                                  "Extra Usage wallet bucket must be present when API exposes a positive balance")
        XCTAssertEqual(extra.unit, .currency)
        XCTAssertEqual(try XCTUnwrap(extra.remainingValue), 12.34, accuracy: 0.001)
        XCTAssertFalse(extra.label.contains("disabled"),
                       "Enabled wallet should not carry the disabled suffix")
    }

    /// `enabled: false` on Extra Usage means the toggle is off — even
    /// with a positive balance, sessions won't draw from it. Surface
    /// the disabled state in the label so users know they can flip it.
    func test_factoryRefresh_exactAPI_extraUsageDisabledStateIsLabeled() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/api/app/auth/me") {
                return try self.httpResponse(
                    url: url, statusCode: 200,
                    body: #"{"organization":{"subscription":{"factoryTier":"pro"}}}"#
                )
            }
            if url.path.hasSuffix("/api/organization/subscription/usage") {
                return try self.httpResponse(
                    url: url, statusCode: 200,
                    body: #"""
                    {
                      "usage": {
                        "standard": { "userTokens": 1000, "totalAllowance": 20000000, "usedRatio": 0.0001 },
                        "premium": { "userTokens": 0, "totalAllowance": 4000000, "usedRatio": 0 },
                        "extraUsage": { "balanceUSD": 25.0, "enabled": false }
                      }
                    }
                    """#
                )
            }
            return try self.httpResponse(url: url, statusCode: 404, body: "{}")
        }

        let service = makeService(
            home: home, appSupportRoot: appSupport, session: session,
            environment: [
                "FACTORY_BEARER_TOKEN": "factory-bearer",
                "FACTORY_COOKIE_HEADER": "session=factory-session"
            ],
            factoryPlanProvider: { .pro }
        )
        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        let extra = try XCTUnwrap(snapshot.buckets.first { $0.key == "factory-extra-usage" })
        XCTAssertEqual(try XCTUnwrap(extra.remainingValue), 25.0, accuracy: 0.001)
        XCTAssertTrue(extra.label.contains("disabled"),
                      "Disabled wallet must carry '(disabled)' so users know to flip the toggle")
    }

    /// Subscription status badges — when Orb reports `trialing`,
    /// `past_due`, or `canceled`, the popover status line surfaces it
    /// so users see the billing state without clicking through to
    /// app.factory.ai/settings/billing.
    func test_factoryRefresh_exactAPI_surfacesSubscriptionStatusBadge() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/api/app/auth/me") {
                return try self.httpResponse(
                    url: url, statusCode: 200,
                    body: #"""
                    {
                      "organization": {
                        "subscription": {
                          "factoryTier": "max",
                          "orbSubscription": {
                            "status": "trialing",
                            "plan": { "name": "Max" }
                          }
                        }
                      }
                    }
                    """#
                )
            }
            if url.path.hasSuffix("/api/organization/subscription/usage") {
                return try self.httpResponse(
                    url: url, statusCode: 200,
                    body: #"""
                    {
                      "usage": {
                        "standard": { "userTokens": 100, "totalAllowance": 200000000, "usedRatio": 0.0 },
                        "premium": { "userTokens": 0, "totalAllowance": 40000000, "usedRatio": 0 }
                      }
                    }
                    """#
                )
            }
            return try self.httpResponse(url: url, statusCode: 404, body: "{}")
        }

        let service = makeService(
            home: home, appSupportRoot: appSupport, session: session,
            environment: [
                "FACTORY_BEARER_TOKEN": "factory-bearer",
                "FACTORY_COOKIE_HEADER": "session=factory-session"
            ],
            factoryPlanProvider: { .pro }
        )
        await service.refresh(provider: .factory, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .factory))

        XCTAssertTrue(snapshot.statusMessage.contains("trial"),
                      "Subscription status badge must surface 'trial' — got: \(snapshot.statusMessage)")
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
        let providerRollup = ProviderQuotaSnapshot(
            provider: .minimax,
            fetchedAt: Date(timeIntervalSince1970: 50),
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Provider rollup",
            buckets: []
        )
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

        store.persistSnapshots([.minimax: providerRollup], accountSnapshots: [
            ProviderQuotaSnapshotStore.accountSnapshotKey(work): work,
            ProviderQuotaSnapshotStore.accountSnapshotKey(personal): personal,
        ])

        let service = makeService(home: home, appSupportRoot: appSupport)

        let accountSnapshots = service.snapshots(for: .minimax)
        XCTAssertEqual(accountSnapshots.map(\.accountID), ["minimax_personal", "minimax_work"])
        XCTAssertEqual(service.snapshot(accountID: "minimax_work")?.accountLabel, "Work")
        XCTAssertNil(service.snapshot(for: .minimax)?.accountID)
        XCTAssertEqual(service.snapshot(for: .minimax)?.statusMessage, "Provider rollup")
    }

    func test_persistedAccountSnapshotDoesNotBecomeProviderFallbackAfterReload() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let store = ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default)
        let providerRollup = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: Date(timeIntervalSince1970: 100),
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Default Codex login",
            buckets: [
                ProviderQuotaBucket(
                    key: "default-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 5,
                    limitValue: 100,
                    remainingValue: 95,
                    usedPercent: 5,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                ),
            ]
        )
        let otherAccount = ProviderQuotaSnapshot(
            provider: .codex,
            accountID: "codex_other",
            accountLabel: "Other account",
            accountStorageScope: .localOnly,
            fetchedAt: Date(timeIntervalSince1970: 200),
            source: .officialAPI,
            sourceId: "switcher-cli:codex:codex_other",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Other account quota",
            buckets: [
                ProviderQuotaBucket(
                    key: "other-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 80,
                    limitValue: 100,
                    remainingValue: 20,
                    usedPercent: 80,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                ),
            ]
        )

        store.persistSnapshots([.codex: providerRollup], accountSnapshots: [
            ProviderQuotaSnapshotStore.accountSnapshotKey(otherAccount): otherAccount,
        ])

        let service = makeService(home: home, appSupportRoot: appSupport)
        let fallback = try XCTUnwrap(service.snapshot(for: .codex))
        let account = try XCTUnwrap(service.snapshot(accountID: "codex_other"))

        XCTAssertNil(fallback.accountID)
        XCTAssertEqual(fallback.primaryDisplayableBucket?.remainingPercent?.rounded(), 95)
        XCTAssertEqual(account.primaryDisplayableBucket?.remainingPercent?.rounded(), 20)
    }

    func test_routingStateUsesExactAccountQuotaSnapshots() throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let store = ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default)
        let fetchedAt = Date()
        let work = ProviderQuotaSnapshot(
            provider: .openAI,
            accountID: "openai_work",
            accountLabel: "Work",
            accountStorageScope: .deviceKeychain,
            fetchedAt: fetchedAt,
            source: .officialAPI,
            sourceId: "slot-work",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Work quota under pressure",
            buckets: [
                ProviderQuotaBucket(
                    key: "work-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 90,
                    limitValue: 100,
                    remainingValue: 10,
                    usedPercent: 90,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                ),
            ]
        )
        let personal = ProviderQuotaSnapshot(
            provider: .openAI,
            accountID: "openai_personal",
            accountLabel: "Personal",
            accountStorageScope: .deviceKeychain,
            fetchedAt: fetchedAt.addingTimeInterval(1),
            source: .officialAPI,
            sourceId: "slot-personal",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Personal quota healthy",
            buckets: [
                ProviderQuotaBucket(
                    key: "personal-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 15,
                    limitValue: 100,
                    remainingValue: 85,
                    usedPercent: 15,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                ),
            ]
        )

        store.persistSnapshots([.openAI: work], accountSnapshots: [
            ProviderQuotaSnapshotStore.accountSnapshotKey(work): work,
            ProviderQuotaSnapshotStore.accountSnapshotKey(personal): personal,
        ])

        let service = makeService(home: home, appSupportRoot: appSupport)
        let dataStore = try makeDataStore()
        try dataStore.providerAccountStore.upsert(routingAccount(id: "openai_work", label: "Work", sortKey: 0))
        try dataStore.providerAccountStore.upsert(routingAccount(id: "openai_personal", label: "Personal", sortKey: 1))

        let states = service.refreshRoutingState(dataStore: dataStore)
        let state = try XCTUnwrap(states[.openAI])

        XCTAssertEqual(state.activeAccount?.accountID, "openai_personal")
        XCTAssertEqual(state.activeAccount?.quotaState, .healthy)
        XCTAssertEqual(state.nextFallback?.accountID, "openai_work")
        XCTAssertEqual(state.nextFallback?.quotaState, .pressure)
    }

    func test_cliQuotaWindowDisplaysUseSuppliedProfileSnapshot() throws {
        let profile = SwitcherProfileRecord(
            targetKind: .cli,
            cliType: .codex,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Codex Work",
                configDirectory: "/tmp/codex-work",
                accountDescription: "work@example.com",
                providerID: .openAI,
                linkedHarnessIDs: ["codex"]
            ),
            sortKey: 0
        )
        let accountSnapshot = ProviderQuotaSnapshot(
            provider: .codex,
            accountID: profile.id,
            accountLabel: "Codex Work",
            accountStorageScope: .localOnly,
            fetchedAt: Date(timeIntervalSince1970: 100),
            source: .officialAPI,
            sourceId: "switcher-cli:codex:\(profile.id)",
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Work quota",
            buckets: [
                ProviderQuotaBucket(
                    key: "work-5h",
                    label: "5-hour window",
                    windowKind: .rollingHours,
                    usedValue: 12,
                    limitValue: 100,
                    remainingValue: 88,
                    usedPercent: 12,
                    resetsAt: nil,
                    unit: .percent,
                    isEstimated: false
                ),
            ]
        )
        let providerSnapshot = ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: Date(timeIntervalSince1970: 200),
            source: .officialAPI,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Provider fallback quota",
            buckets: [
                ProviderQuotaBucket(
                    key: "fallback-5h",
                    label: "5-hour window",
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

        let accountWindows = try XCTUnwrap(cliQuotaWindowDisplays(for: profile, snapshot: accountSnapshot))
        let providerFallbackWindows = try XCTUnwrap(cliQuotaWindowDisplays(for: profile) { _ in providerSnapshot })

        XCTAssertEqual(accountWindows.map(\.remaining), ["88%"])
        XCTAssertEqual(providerFallbackWindows.map(\.remaining), ["25%"])
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

    func test_deepSeekRefresh_usesOfficialBalanceEndpoint() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let keyStore = try makeKeyStore(provider: "deepseek", value: "deepseek-key")
        let session = makeStubSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer deepseek-key")

            let body = """
            {
              "is_available": true,
              "balance_infos": [
                {
                  "currency": "CNY",
                  "total_balance": "123.45",
                  "granted_balance": "20.00",
                  "topped_up_balance": "103.45"
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
            session: session
        )

        await service.refresh(provider: .deepSeek, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .deepSeek))
        let bucket = try XCTUnwrap(snapshot.primaryDisplayableBucket)

        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(bucket.label, "CNY credit balance")
        XCTAssertEqual(bucket.remainingValue ?? -1, 123.45, accuracy: 0.01)
        XCTAssertTrue(bucket.isDisplayableQuotaSignal)
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

    func test_refreshAll_fetchesDeepSeekDaemonCredentialSlotsAsAccountSnapshots() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let runtimeSecrets = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        )
        try runtimeSecrets.set("deepseek-work", for: "provider.deepseek.slot.work.apiKey")
        try runtimeSecrets.set("deepseek-personal", for: "provider.deepseek.slot.personal.apiKey")

        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "deepseek",
                provider: .deepSeek,
                displayName: "DeepSeek",
                isEnabled: true,
                baseURL: "https://api.deepseek.com/v1",
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
            XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            observedAuthorizations.withLock { $0.append(authorization) }
            let balance = authorization == "Bearer deepseek-personal" ? "7.25" : "42.50"
            let body = """
            {
              "is_available": true,
              "balance_infos": [
                {"currency": "USD", "total_balance": "\(balance)"}
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
            refreshProviders: [.deepSeek]
        )

        let dataStore = try makeDataStore()
        await service.refreshAll(dataStore: dataStore)

        let snapshots = service.snapshots(for: .deepSeek)
        let work = try XCTUnwrap(snapshots.first { $0.accountLabel == "Work" })
        let personal = try XCTUnwrap(snapshots.first { $0.accountLabel == "Personal" })
        let persistedAccounts = try dataStore.providerAccountStore.fetchAll(providerID: ProviderID(rawValue: "deepseek"))

        XCTAssertEqual(work.accountID, "deepseek-work")
        XCTAssertEqual(work.sourceId, "daemon-slot:deepseek:work")
        XCTAssertEqual(work.primaryDisplayableBucket?.remainingValue ?? -1, 42.50, accuracy: 0.01)
        XCTAssertEqual(personal.accountID, "deepseek-personal")
        XCTAssertEqual(personal.sourceId, "daemon-slot:deepseek:personal")
        XCTAssertEqual(personal.primaryDisplayableBucket?.remainingValue ?? -1, 7.25, accuracy: 0.01)
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer deepseek-work"))
        XCTAssertTrue(observedAuthorizations.read().contains("Bearer deepseek-personal"))
        XCTAssertEqual(persistedAccounts.map(\.id), ["deepseek-work", "deepseek-personal"])
    }

    func test_refreshAll_fetchesAnthropicOAuthSlotsAsClaudeAccountQuotaSnapshots() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let runtimeSecrets = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        )
        let routePayload = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat-gmail",
            "refreshToken": "sk-ant-ort-gmail",
            "expiresAt": 4102444800000,
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """
        try runtimeSecrets.set(routePayload, for: "provider.anthropic.slot.gmail.apiKey")

        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "anthropic",
                provider: AgentProvider.claudeCode,
                displayName: "Anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: [],
                preferredCredentialSlotID: "gmail",
                credentialSlots: [
                    OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                        slotID: "gmail",
                        label: "gmail",
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

        let formatter = ISO8601DateFormatter()
        let reset = formatter.string(from: Date().addingTimeInterval(2 * 60 * 60))
        let observedAuthorizations = Locked<[String]>([])
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            if url.absoluteString == "https://api.anthropic.com/api/oauth/usage" {
                observedAuthorizations.withLock {
                    $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
                }
                return try self.httpResponse(
                    url: url,
                    statusCode: 200,
                    body: """
                    {
                      "rate_limits": {
                        "five_hour": { "used_percentage": 8, "resets_at": "\(reset)" },
                        "seven_day": { "used_percentage": 21, "resets_at": "\(reset)" }
                      }
                    }
                    """
                )
            }
            XCTFail("Unexpected URL: \(url.absoluteString)")
            throw URLError(.cannotConnectToHost)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            providerRuntimeKeyStore: runtimeSecrets,
            session: session,
            refreshProviders: [AgentProvider.claudeCode]
        )
        let dataStore = try makeDataStore()

        await service.refreshAll(dataStore: dataStore)

        let snapshots = service.snapshots(for: AgentProvider.claudeCode)
        let gmail = try XCTUnwrap(snapshots.first { $0.accountLabel == "gmail" })
        let persistedAccounts = try dataStore.providerAccountStore.fetchAll(providerID: ProviderID(rawValue: "anthropic"))

        XCTAssertEqual(gmail.accountID, "anthropic-gmail")
        XCTAssertEqual(gmail.sourceId, "daemon-slot:anthropic:gmail")
        XCTAssertEqual(gmail.buckets.map { $0.key }.sorted(), ["claude-five_hour", "claude-seven_day"])
        let fiveHour = try XCTUnwrap(gmail.buckets.first { $0.key == "claude-five_hour" })
        let sevenDay = try XCTUnwrap(gmail.buckets.first { $0.key == "claude-seven_day" })
        XCTAssertEqual(fiveHour.label, "5-hour window")
        XCTAssertEqual(sevenDay.label, "7-day window")
        XCTAssertEqual(try XCTUnwrap(fiveHour.remainingPercent).rounded(), 92)
        XCTAssertEqual(try XCTUnwrap(sevenDay.remainingPercent).rounded(), 79)
        XCTAssertEqual(observedAuthorizations.read(), ["Bearer sk-ant-oat-gmail"])
        XCTAssertEqual(persistedAccounts.map { $0.id }, ["anthropic-gmail"])
        XCTAssertEqual(persistedAccounts.first?.label, "gmail")
    }

    func test_refreshAll_claudeOAuthAccountCachesAreCredentialScoped() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let runtimeSecrets = KeychainStore(
            service: "tests.runtime.\(UUID().uuidString)",
            legacyServices: [],
            backend: TestKeychainBackend()
        )
        let workPayload = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat-work",
            "expiresAt": 4102444800000,
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """
        let reservePayload = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat-reserve",
            "expiresAt": 4102444800000,
            "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_20x"
          }
        }
        """
        try runtimeSecrets.set(workPayload, for: "provider.anthropic.slot.work.apiKey")
        try runtimeSecrets.set(reservePayload, for: "provider.anthropic.slot.reserve.apiKey")

        OpenBurnBarDaemonManager.shared.providerConfigurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "anthropic",
                provider: AgentProvider.claudeCode,
                displayName: "Anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
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
                        slotID: "reserve",
                        label: "Reserve",
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

        // Regression guard: the old implementation used this one global
        // cache file for every Claude account. A fresh global cache must not
        // prevent account-specific OAuth calls or contaminate account B with
        // account A's quota.
        let formatter = ISO8601DateFormatter()
        let globalEnvelope: [String: Any] = [
            "fetchedAt": formatter.string(from: Date()),
            "fiveHourResetsAt": formatter.string(from: Date().addingTimeInterval(4 * 60 * 60)),
            "sevenDayResetsAt": formatter.string(from: Date().addingTimeInterval(5 * 24 * 60 * 60)),
            "payload": [
                "five_hour": ["used_percentage": 8, "resets_at": formatter.string(from: Date().addingTimeInterval(4 * 60 * 60))],
                "seven_day": ["used_percentage": 21, "resets_at": formatter.string(from: Date().addingTimeInterval(5 * 24 * 60 * 60))]
            ]
        ]
        try FileManager.default.createDirectory(
            at: appPaths.claudeOAuthUsageCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: globalEnvelope)
            .write(to: appPaths.claudeOAuthUsageCacheURL)

        let observedAuthorizations = Locked<[String]>([])
        let session = makeStubSession { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            observedAuthorizations.withLock { $0.append(authorization) }
            let used: Int
            switch authorization {
            case "Bearer sk-ant-oat-work":
                used = 10
            case "Bearer sk-ant-oat-reserve":
                used = 60
            default:
                XCTFail("Unexpected authorization: \(authorization)")
                used = 100
            }
            let reset = formatter.string(from: Date().addingTimeInterval(3 * 60 * 60))
            return try self.httpResponse(
                url: url,
                statusCode: 200,
                body: """
                {
                  "rate_limits": {
                    "five_hour": { "used_percentage": \(used), "resets_at": "\(reset)" },
                    "seven_day": { "used_percentage": \(used / 2), "resets_at": "\(reset)" }
                  }
                }
                """
            )
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            providerRuntimeKeyStore: runtimeSecrets,
            session: session,
            refreshProviders: [AgentProvider.claudeCode]
        )

        await service.refreshAll(dataStore: try makeDataStore())

        let snapshots = service.snapshots(for: AgentProvider.claudeCode)
        let work = try XCTUnwrap(snapshots.first { $0.accountLabel == "Work" })
        let reserve = try XCTUnwrap(snapshots.first { $0.accountLabel == "Reserve" })
        let workFiveHour = try XCTUnwrap(work.buckets.first { $0.key == "claude-five_hour" })
        let reserveFiveHour = try XCTUnwrap(reserve.buckets.first { $0.key == "claude-five_hour" })

        XCTAssertEqual(work.source, .officialAPI)
        XCTAssertEqual(reserve.source, .officialAPI)
        XCTAssertEqual(workFiveHour.remainingPercent?.rounded(), 90)
        XCTAssertEqual(reserveFiveHour.remainingPercent?.rounded(), 40)
        XCTAssertEqual(
            Set(observedAuthorizations.read()),
            Set(["Bearer sk-ant-oat-work", "Bearer sk-ant-oat-reserve"])
        )
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

        // OpenAI is usage-only: refreshAll may surface placeholder snapshot
        // entries for the daemon credential slot, but none of them should
        // carry real quota window data (the stub session would have
        // XCTFail'd above if quota HTTP had been attempted).
        for snapshot in service.snapshots(for: AgentProvider.openAI) {
            XCTAssertTrue(
                snapshot.buckets.isEmpty,
                "OpenAI snapshots should not carry quota buckets — got \(snapshot.buckets)"
            )
        }
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

    func test_providerRoutingEventPersistencePreservesHistoryBeyondDisplayLimit() throws {
        let appSupport = try makeTemporaryDirectory()
        let paths = OpenBurnBarAppPaths(applicationSupportRoot: appSupport)
        let store = ProviderQuotaSnapshotStore(appPaths: paths, fileManager: .default)
        let events = (0..<150).map { index in
            ProviderRoutingDecisionEvent(
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                modelID: nil,
                selected: nil,
                nextFallback: nil,
                reason: "route-\(index)",
                skipped: []
            )
        }

        store.persistRoutingEvents(events)

        switch store.loadPersistedRoutingEvents() {
        case .loaded(let reloaded):
            XCTAssertEqual(reloaded.count, 150)
            XCTAssertEqual(reloaded.first?.reason, "route-0")
            XCTAssertEqual(reloaded.last?.reason, "route-149")
        default:
            XCTFail("Expected persisted routing events to reload")
        }

        switch store.loadPersistedRoutingEvents(limit: 100) {
        case .loaded(let displayWindow):
            XCTAssertEqual(displayWindow.count, 100)
            XCTAssertEqual(displayWindow.first?.reason, "route-50")
            XCTAssertEqual(displayWindow.last?.reason, "route-149")
        default:
            XCTFail("Expected limited routing event readback to reload")
        }
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
        claudeCredentialsReader: any ClaudeCredentialsReading = NoClaudeCredentialsReader(),
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
            claudeCredentialsReader: claudeCredentialsReader,
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

    /// Regression: clicking "Connect Ollama" stores a cookie header in
    /// Keychain under `ollama_cookie_header`; the adapter must forward that
    /// cookie to `ollama.com/settings` so quota actually gets read. Before the
    /// fix the cookie was always nil and the cloud scrape silently no-op'd.
    func test_ollamaCloud_storedCookieIsReplayedToOllamaSettings() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()
        let cookieHeader = "ollama_session=test-session-value; signed-in=1"

        let keyStore = ProviderAPIKeyStore(
            keychain: KeychainStore(
                service: "tests.\(UUID().uuidString)",
                legacyServices: [],
                backend: TestKeychainBackend()
            )
        )
        try keyStore.setAPIKey(cookieHeader, for: "ollama_cookie_header")

        let observedCookieHeaders = Locked<[String]>([])
        let observedSettingsURLs = Locked<[String]>([])
        let session = makeStubSession { request in
            guard let urlString = request.url?.absoluteString else {
                throw URLError(.badURL)
            }
            if urlString.contains("api/tags") {
                let body = """
                {"models": [{"name": "llama3:cloud"}]}
                """
                return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
            }
            if urlString.contains("api/ps") {
                return try self.httpResponse(url: request.url!, statusCode: 200, body: "{}")
            }
            if urlString.contains("ollama.com/settings") {
                observedSettingsURLs.withLock { $0.append(urlString) }
                if let cookie = request.value(forHTTPHeaderField: "Cookie") {
                    observedCookieHeaders.withLock { $0.append(cookie) }
                }
                let html = """
                <span>Cloud Usage</span><span>Cloud Pro</span>
                <h3>5-hour usage</h3><div>17.5% used</div>
                <h3>Weekly usage</h3><div>42% used</div>
                """
                return try self.httpResponse(url: request.url!, statusCode: 200, body: html)
            }
            throw URLError(.badURL)
        }

        let service = makeService(
            home: home,
            appSupportRoot: appSupport,
            keyStore: keyStore,
            session: session,
            environment: ["OLLAMA_HOST": "http://localhost:11434"]
        )

        await service.refresh(provider: .ollama, dataStore: try makeDataStore())
        let snapshot = try XCTUnwrap(service.snapshot(for: .ollama))

        XCTAssertEqual(observedSettingsURLs.read(), ["https://ollama.com/settings"],
                      "Adapter must hit ollama.com/settings exactly once when a cookie is stored")
        XCTAssertEqual(observedCookieHeaders.read(), [cookieHeader],
                      "Adapter must replay the stored Ollama cookie jar")

        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertEqual(snapshot.source, .officialAPI)
        XCTAssertEqual(snapshot.buckets.map(\.key), ["ollama-cloud-session", "ollama-cloud-weekly"])
        XCTAssertEqual(snapshot.hourlyBucket?.usedPercent, 17.5)
        XCTAssertEqual(snapshot.weeklyBucket?.usedPercent, 42)
    }

    /// Without a stored Ollama login session the adapter must NOT touch
    /// ollama.com (no anonymous probes, no broken auth attempts) and the
    /// status message must point the user at the connect flow instead of
    /// the legacy "Readable quota not available yet" generic copy.
    func test_ollamaCloud_withoutStoredCookieSkipsRemoteFetchAndPromptsConnect() async throws {
        let home = try makeTemporaryDirectory()
        let appSupport = try makeTemporaryDirectory()

        let observedSettingsHits = Locked<Int>(0)
        let session = makeStubSession { request in
            guard let urlString = request.url?.absoluteString else {
                throw URLError(.badURL)
            }
            if urlString.contains("api/tags") {
                let body = """
                {"models": [{"name": "llama3"}]}
                """
                return try self.httpResponse(url: request.url!, statusCode: 200, body: body)
            }
            if urlString.contains("api/ps") {
                return try self.httpResponse(url: request.url!, statusCode: 200, body: "{}")
            }
            if urlString.contains("ollama.com/settings") {
                observedSettingsHits.withLock { $0 += 1 }
                return try self.httpResponse(url: request.url!, statusCode: 401, body: "")
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

        XCTAssertEqual(observedSettingsHits.read(), 0,
                      "Adapter must not hit ollama.com without a stored session cookie")
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertTrue(
            snapshot.statusMessage.contains("Connect Ollama"),
            "Status should prompt the user to connect — got: \(snapshot.statusMessage)"
        )
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
                provider: AgentProvider.kimi,
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
            refreshProviders: [AgentProvider.kimi]
        )

        let dataStore = try makeDataStore()
        await service.refreshAll(dataStore: dataStore)

        XCTAssertTrue(observedAuthorizations.read().contains("Bearer \(kimiJWT)"),
                      "Kimi adapter should authorize using daemon-slot Moonshot key. Saw: \(observedAuthorizations.read())")

        let snapshots = service.snapshots(for: AgentProvider.kimi)
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

import XCTest
@testable import OpenBurnBar

/// Coverage for the durability sentry that keeps Codex / Forge / OpenCode /
/// Droid wired through the local BurnBar gateway when external tools (plugin
/// installs, dotfile syncs) strip the OpenBurnBar-owned block.
///
/// Claude Code is intentionally excluded because its global
/// `ANTHROPIC_BASE_URL` override disables claude.ai connectors and has no
/// fallback when the local daemon is off.
///
/// Every test runs against an isolated temp "home" and an isolated
/// `UserDefaults` suite so we never touch the developer's real config files
/// or app preferences.
final class RoutedClientWiringSentryTests: XCTestCase {

    private var tempHome: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: SettingsManager!
    private var sentry: RoutedClientWiringSentry!

    override func setUp() async throws {
        try await super.setUp()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-sentry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        suiteName = "openburnbar.sentry.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)

        await MainActor.run {
            self.settings = SettingsManager(defaults: self.defaults, flushDelayNanoseconds: 0)
            self.settings.gateway.gatewayHost = "127.0.0.1"
            self.settings.gateway.gatewayPort = 8317
            self.settings.gateway.gatewayAuthToken = ""
            self.settings.gateway.gatewayEnabled = true
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            self.sentry?.stop()
            self.sentry = nil
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
        defaults = nil
        settings = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Initial repair on start

    @MainActor
    func test_start_repairsEnrolledCodexTargetWhenBlockMissing() async throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "model = \"native\"\n".write(to: url, atomically: true, encoding: .utf8)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertTrue(wiring.isWired(target: .codex))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# openburnbar:routing — start"))
        XCTAssertTrue(text.contains("model = \"native\""))
        XCTAssertNotNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "codex"))
    }

    @MainActor
    func test_start_doesNotRepairWhenTargetNotEnrolled() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: url)

        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
    }

    @MainActor
    func test_start_doesNotAdoptExistingClaudeGlobalProxyWiring() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staleRoot: [String: Any] = [
            "theme": "dark",
            "env": [
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
                "ANTHROPIC_AUTH_TOKEN": "old-token",
                "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
                "ANTHROPIC_CUSTOM_HEADERS": "X-OpenBurnBar-Client: claude-code",
                "OPENBURNBAR_MODEL_CATALOG_IDS": "claude-opus-4-8,claude-opus-4-8-high",
                "OPENBURNBAR_MODEL_CATALOG_FINGERPRINT": "stale-fingerprint",
                "OPENBURNBAR_WIRED": "1"
            ]
        ]
        let staleData = try JSONSerialization.data(withJSONObject: staleRoot)
        try staleData.write(to: url)
        XCTAssertFalse(
            settings.routedClientWiring.enrolledTargets.contains(RoutingClientWiringTarget.claudeCode.rawValue),
            "This reproduces an older install where Claude Code was wired before the durability sentry recorded enrollment."
        )

        let beforeData = try Data(contentsOf: url)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        XCTAssertFalse(settings.routedClientWiring.enrolledTargets.contains(RoutingClientWiringTarget.claudeCode.rawValue))
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))

        let afterData = try Data(contentsOf: url)
        XCTAssertEqual(afterData, beforeData, "Claude Code global proxy wiring must not be adopted or refreshed")
    }

    @MainActor
    func test_start_doesNotAdoptLocalClaudeProxyWithoutOpenBurnBarMarker() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let proxyRoot: [String: Any] = [
            "theme": "dark",
            "env": [
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
                "ANTHROPIC_AUTH_TOKEN": "not-openburnbar"
            ]
        ]
        let proxyData = try JSONSerialization.data(withJSONObject: proxyRoot)
        try proxyData.write(to: url)

        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        XCTAssertFalse(settings.routedClientWiring.enrolledTargets.contains(RoutingClientWiringTarget.claudeCode.rawValue))
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))

        let root = try loadJSONObject(at: url)
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "not-openburnbar")
        XCTAssertNil(env["OPENBURNBAR_WIRED"])
        XCTAssertNil(env["OPENBURNBAR_MODEL_CATALOG_IDS"])
        XCTAssertEqual(root["theme"] as? String, "dark")
    }

    @MainActor
    func test_start_doesNotAdoptExistingDroidOpenBurnBarWiringWithoutPersistedIntent() async throws {
        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        let staleModels = [
            RoutingClientAdvertisedModel(
                id: "gpt-5.4",
                displayName: "GPT-5.4",
                providerID: "openai",
                providerName: "OpenAI",
                routeEligible: true
            )
        ]
        let refreshedModels = [
            RoutingClientAdvertisedModel(
                id: "gpt-5.5",
                displayName: "GPT-5.5",
                providerID: "openai",
                providerName: "OpenAI",
                routeEligible: true
            )
        ]
        _ = try makeWiring().wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: staleModels
        )
        XCTAssertFalse(
            settings.routedClientWiring.enrolledTargets.contains(RoutingClientWiringTarget.droid.rawValue),
            "This reproduces a config file that looks OpenBurnBar-owned but lacks persisted user intent."
        )

        sentry = makeSentry(advertisedModels: refreshedModels)
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        XCTAssertFalse(settings.routedClientWiring.enrolledTargets.contains(RoutingClientWiringTarget.droid.rawValue))
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "droid"))

        let root = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        let customModels = try XCTUnwrap(root["customModels"] as? [[String: Any]])
        XCTAssertEqual(customModels.map { $0["model"] as? String }, ["gpt-5.4"])
        let refreshedText = try String(
            contentsOf: tempHome.appendingPathComponent(".factory/settings.local.json"),
            encoding: .utf8
        )
        XCTAssertFalse(
            refreshedText.contains("gpt-5.5"),
            "Startup must not refresh config-carried tokens/catalog rows without persisted enrollment."
        )
    }

    @MainActor
    func test_start_doesNotAdoptForgeableClaudeMarker() async throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let markerRoot: [String: Any] = [
            "env": [
                "OPENBURNBAR_WIRED": "1",
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
                "ANTHROPIC_AUTH_TOKEN": "attacker-visible-placeholder"
            ]
        ]
        let markerData = try JSONSerialization.data(withJSONObject: markerRoot)
        try markerData.write(to: url)

        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        XCTAssertFalse(settings.routedClientWiring.enrolledTargets.contains(RoutingClientWiringTarget.claudeCode.rawValue))
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))
        XCTAssertEqual(try Data(contentsOf: url), markerData)
    }

    @MainActor
    func test_start_doesNotAdoptLocalDroidProxyWithoutOpenBurnBarMarker() async throws {
        let url = tempHome.appendingPathComponent(".factory/settings.local.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let proxyRoot: [String: Any] = [
            "customModels": [
                [
                    "id": "custom:manual-loopback",
                    "model": "gpt-4o",
                    "baseUrl": "http://127.0.0.1:8317/v1",
                    "apiKey": "user-owned-token",
                    "displayName": "Manual loopback proxy",
                    "provider": "openai"
                ]
            ]
        ]
        let proxyData = try JSONSerialization.data(withJSONObject: proxyRoot)
        try proxyData.write(to: url)

        XCTAssertTrue(
            makeWiring().isWired(target: .droid),
            "The UI detector can still show a broad local Droid gateway as wired."
        )

        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        XCTAssertFalse(settings.routedClientWiring.enrolledTargets.contains(RoutingClientWiringTarget.droid.rawValue))
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "droid"))

        let root = try loadJSONObject(at: url)
        let customModels = try XCTUnwrap(root["customModels"] as? [[String: Any]])
        let model = try XCTUnwrap(customModels.first)
        XCTAssertEqual(model["id"] as? String, "custom:manual-loopback")
        XCTAssertEqual(model["apiKey"] as? String, "user-owned-token")
        XCTAssertEqual(model["displayName"] as? String, "Manual loopback proxy")
    }

    @MainActor
    func test_start_doesNotRepairWhenAutoRepairDisabled() async throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model = \"native\"\n".utf8).write(to: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        settings.routedClientWiring.autoRepairEnabled = false
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .codex))
    }

    @MainActor
    func test_start_doesNotRepairWhenGatewayDisabled() async throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model = \"native\"\n".utf8).write(to: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        settings.gateway.gatewayEnabled = false
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .codex))
    }

    @MainActor
    func test_start_isNoOpWhenAlreadyWired() async throws {
        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .codex,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: ""),
            advertisedModels: Self.defaultAdvertisedModels
        )
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        let preRepairData = try Data(contentsOf: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let postRepairData = try Data(contentsOf: url)
        XCTAssertEqual(preRepairData, postRepairData, "wired file must not be touched")
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "codex"))
    }

    // MARK: - Repair after external rewrite

    @MainActor
    func test_externalStripTriggersRepairViaSweep() async throws {
        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .codex,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: ""),
            advertisedModels: Self.defaultAdvertisedModels
        )
        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try "model = \"native\"\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(makeWiring().isWired(target: .codex))

        await sentry.sweepNow().value

        XCTAssertTrue(makeWiring().isWired(target: .codex))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("model = \"native\""))
        XCTAssertTrue(text.contains("# openburnbar:routing — start"))
    }

    @MainActor
    func test_externalStripDoesNotRepairClaudeCodeViaSweep() async throws {
        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .claudeCode,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: ""),
            advertisedModels: Self.defaultAdvertisedModels
        )
        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.claudeCode.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let url = tempHome.appendingPathComponent(".claude/settings.json")
        let stripped: [String: Any] = ["theme": "dracula", "permissions": ["allow": ["Read"]]]
        let strippedData = try JSONSerialization.data(withJSONObject: stripped)
        try strippedData.write(to: url, options: [.atomic])
        XCTAssertFalse(makeWiring().isWired(target: .claudeCode))

        await sentry.sweepNow().value

        XCTAssertFalse(makeWiring().isWired(target: .claudeCode))
        let root = try loadJSONObject(at: url)
        XCTAssertEqual(root["theme"] as? String, "dracula")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual((permissions["allow"] as? [String])?.first, "Read")
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "claudeCode"))
    }

    // MARK: - Enrollment changes

    @MainActor
    func test_unenrollViaSettingsRemovesAuditState() async throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model = \"native\"\n".utf8).write(to: url)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value
        XCTAssertNotNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "codex"))

        settings.routedClientWiring.unenroll(targetRawValue: "codex")
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "codex"))
        XCTAssertFalse(settings.routedClientWiring.enrolledTargets.contains("codex"))
    }

    @MainActor
    func test_enrollmentNotificationRefreshesWatchers() async throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model = \"native\"\n".utf8).write(to: url)

        sentry = makeSentry()
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value
        XCTAssertFalse(makeWiring().isWired(target: .codex), "no enrollment yet")

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        await Task.yield()
        await sentry.sweepNow().value

        XCTAssertTrue(makeWiring().isWired(target: .codex))
    }

    // MARK: - Persistence

    @MainActor
    func test_enrollmentSurvivesAcrossInstances() async {
        settings.routedClientWiring.enroll(targetRawValue: "claudeCode")
        settings.routedClientWiring.enroll(targetRawValue: "codex")

        let secondInstance = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        XCTAssertTrue(secondInstance.routedClientWiring.enrolledTargets.contains("claudeCode"))
        XCTAssertTrue(secondInstance.routedClientWiring.enrolledTargets.contains("codex"))
        XCTAssertTrue(secondInstance.routedClientWiring.autoRepairEnabled)
    }

    @MainActor
    func test_autoRepairTogglePersists() async {
        settings.routedClientWiring.autoRepairEnabled = false
        let secondInstance = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        XCTAssertFalse(secondInstance.routedClientWiring.autoRepairEnabled)
    }

    @MainActor
    func test_sweepRefreshesStaleDroidModelCache() async throws {
        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        let staleModels = [
            RoutingClientAdvertisedModel(
                id: "gpt-5.4",
                displayName: "GPT-5.4",
                providerID: "openai",
                providerName: "OpenAI",
                routeEligible: true
            )
        ]
        let refreshedModels = [
            RoutingClientAdvertisedModel(
                id: "gpt-5.5",
                displayName: "GPT-5.5",
                providerID: "openai",
                providerName: "OpenAI",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "claude-opus-4-8",
                displayName: "Claude Opus 4.8",
                providerID: "anthropic",
                providerName: "Anthropic",
                formatFamily: "anthropic",
                servedEndpoints: ["/v1/messages", "/v1/chat/completions"],
                routeEligible: true
            )
        ]
        _ = try makeWiring().wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: staleModels
        )

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.droid.rawValue)
        sentry = makeSentry(advertisedModels: refreshedModels)
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let status = makeWiring().modelSyncStatus(
            target: .droid,
            gateway: gateway,
            advertisedModels: refreshedModels
        )
        XCTAssertEqual(status, .current(modelIDs: ["gpt-5.5", "claude-opus-4-8"]))
        let root = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        let customModels = try XCTUnwrap(root["customModels"] as? [[String: Any]])
        XCTAssertEqual(customModels.map { $0["model"] as? String }, ["gpt-5.5", "claude-opus-4-8"])
        XCTAssertNotNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "droid"))
    }

    @MainActor
    func test_sweepDoesNotRewriteCatalogAwareTargetWhenLiveCatalogUnavailable() async throws {
        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        let staleModels = [
            RoutingClientAdvertisedModel(
                id: "glm-5.1",
                displayName: "GLM 5.1",
                providerID: "zai",
                providerName: "Z.ai",
                servedEndpoints: ["/v1/responses"],
                routeEligible: true
            )
        ]
        _ = try makeWiring().wire(
            target: .codex,
            gateway: gateway,
            advertisedModels: staleModels
        )
        let catalogURL = tempHome
            .appendingPathComponent(".codex")
            .appendingPathComponent("openburnbar-model-catalog.json")
        let beforeData = try Data(contentsOf: catalogURL)

        settings.routedClientWiring.enroll(targetRawValue: RoutingClientWiringTarget.codex.rawValue)
        sentry = makeSentry(advertisedModels: [])
        sentry.start(settingsManager: settings)
        await sentry.sweepNow().value

        let afterData = try Data(contentsOf: catalogURL)
        XCTAssertEqual(afterData, beforeData)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: afterData) as? [String: Any])
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        XCTAssertTrue(
            models.contains { $0["slug"] as? String == "openburnbar/glm-5.1" },
            "Sentry must not wipe OpenBurnBar-owned model sidecars when the live catalog fetch fails."
        )
        XCTAssertNil(settings.routedClientWiring.lastRepairDate(targetRawValue: "codex"))
    }

    // MARK: - Helpers

    @MainActor
    private func makeSentry(
        advertisedModels: [RoutingClientAdvertisedModel]? = nil
    ) -> RoutedClientWiringSentry {
        let home = tempHome!
        return RoutedClientWiringSentry(
            configuration: RoutedClientWiringSentry.Configuration(
                debounceNanoseconds: 1_000_000,
                periodicSweepSeconds: 0,
                reopenBackoffNanoseconds: 1_000_000,
                monitoredEvents: [.write, .extend, .rename, .delete, .attrib, .link],
                fileSystemWatchersEnabled: false,
                lifecycleSweepsEnabled: false
            ),
            wiringFactory: {
                RoutingClientWiring(
                    fileManager: .default,
                    home: home,
                    now: { Date(timeIntervalSince1970: 1_700_000_000) }
                )
            },
            advertisedModelsProvider: { _, _ in
                if let advertisedModels {
                    return advertisedModels
                }
                return Self.defaultAdvertisedModels
            }
        )
    }

    private static let defaultAdvertisedModels: [RoutingClientAdvertisedModel] = [
        RoutingClientAdvertisedModel(
            id: "claude-opus-4-8",
            displayName: "Claude Opus 4.8",
            providerID: "anthropic",
            providerName: "Anthropic",
            formatFamily: "anthropic",
            servedEndpoints: ["/v1/messages", "/v1/responses", "/v1/chat/completions"],
            routeEligible: true
        )
    ]

    private func makeWiring() -> RoutingClientWiring {
        RoutingClientWiring(
            fileManager: .default,
            home: tempHome,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

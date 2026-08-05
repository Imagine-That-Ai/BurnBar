import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore

/// Pins the smart-Connect state machine for the new Connections settings
/// page. The view model collapses every legacy concept (enable gateway,
/// wire, probe, loopback auth, etc.) into one button press; these tests
/// guarantee that flow stays one-click for the user.
@MainActor
final class ConnectionsViewModelTests: XCTestCase {

    private var tempHome: URL!
    private var settings: SettingsManager!
    private var viewModel: ConnectionsViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("connections-vm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        // Isolated UserDefaults so we don't trample real Settings.
        let suiteName = "ConnectionsViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsManager(defaults: defaults)

        // Start with the gateway off so the "auto-enable" branch exercises.
        settings.gatewayEnabled = false
        settings.gatewayHost = ""
        settings.gatewayPort = 0
        settings.gatewayAuthToken = ""

        let homeURL = tempHome!
        viewModel = ConnectionsViewModel(wiringFactory: {
            RoutingClientWiring(home: homeURL)
        })
    }

    override func tearDownWithError() throws {
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
        tempHome = nil
        settings = nil
        viewModel = nil
        try super.tearDownWithError()
    }

    // MARK: - Account wizard launch targets

    func test_addAccountLaunchTargetStartsOnProviderSelection() {
        let target = ProviderWizardTarget.addAccount

        XCTAssertNil(target.providerID)
        XCTAssertTrue(target.startsAtProviderSelection)
        XCTAssertEqual(target.id, "add-account")
    }

    func test_existingProviderLaunchTargetKeepsProviderDashboard() {
        let target = ProviderWizardTarget(providerID: "anthropic")

        XCTAssertEqual(target.providerID, "anthropic")
        XCTAssertFalse(target.startsAtProviderSelection)
        XCTAssertEqual(target.id, "anthropic")
    }

    // MARK: - Auto-enable gateway on first Connect

    func test_connect_flipsGatewayOnAndUsesLoopbackDefaults() async {
        XCTAssertFalse(settings.gatewayEnabled)

        await viewModel.connect(target: .claudeCode, settings: settings)

        XCTAssertTrue(settings.gatewayEnabled, "Connect must enable the local gateway automatically")
        XCTAssertEqual(settings.gatewayHost, "127.0.0.1", "Connect must fill in loopback host defaults")
        XCTAssertEqual(settings.gatewayPort, 8317, "Connect must fill in the default gateway port")
    }

    func test_connectRestartsGatewayAfterEnablingIt() async {
        var restartCount = 0

        await viewModel.connect(
            target: .claudeCode,
            settings: settings,
            restartGateway: {
                restartCount += 1
            }
        )

        XCTAssertEqual(restartCount, 1, "Connect must restart the daemon after enabling the gateway so the local port actually comes up.")
    }

    // MARK: - Wiring actually writes the config

    func test_connect_writesClientConfigFile() async throws {
        await viewModel.connect(target: .claudeCode, settings: settings)
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Connect must write the Claude Code config file under the test home")
        XCTAssertTrue(
            RoutingClientWiring(home: tempHome).isWired(target: .claudeCode),
            "Once Connect completes, isWired must round-trip to true"
        )
    }

    // MARK: - State machine

    func test_connect_landsInConnectedOrDegradedNeverInflightForever() async {
        await viewModel.connect(target: .codex, settings: settings)
        switch viewModel.state(for: .codex) {
        case .connected, .degraded:
            break // either is acceptable — the probe runs against a real
                  // local port that does not exist in tests
        case let other:
            XCTFail("Expected .connected or .degraded after Connect, got \(other)")
        }
    }

    func test_syncModels_ignoresDuplicateTapWhileAlreadyBusy() async {
        var restartCount = 0
        viewModel.appStates[.droid] = .syncingModels

        await viewModel.syncModels(
            target: .droid,
            settings: settings,
            restartGateway: {
                restartCount += 1
            }
        )

        XCTAssertEqual(restartCount, 0, "A second Sync models tap while syncing must not restart or rewrite concurrently.")
        XCTAssertEqual(viewModel.state(for: .droid), .syncingModels)
    }

    func test_refreshProxyModelCatalog_usesLiveGatewayFetcher() async {
        settings.gatewayHost = "127.0.0.1"
        settings.gatewayPort = 8317
        settings.gatewayAuthToken = "catalog-token"

        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { gateway in
                XCTAssertEqual(gateway.baseURL, "http://127.0.0.1:8317")
                XCTAssertEqual(gateway.authToken, "catalog-token")
                return [
                    ProxyAdvertisedModel(
                        modelID: "MiniMax-M2.7",
                        displayName: "MiniMax M2.7",
                        providerID: "minimax",
                        providerName: "MiniMax",
                        accountID: "acct_minimax",
                        accountLabel: "MiniMax primary",
                        sourceID: "minimax#acct_minimax",
                        sourceKind: "provider_account",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat", "routing"],
                        lastError: nil
                    ),
                    ProxyAdvertisedModel(
                        modelID: "deepseek-v4-flash",
                        displayName: "DeepSeek V4 Flash",
                        providerID: "deepseek",
                        providerName: "DeepSeek",
                        accountID: "acct_deepseek",
                        accountLabel: "DeepSeek reserve",
                        sourceID: "deepseek#acct_deepseek",
                        sourceKind: "provider_account",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat", "routing"],
                        lastError: nil
                    )
                ]
            }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)

        XCTAssertEqual(viewModel.proxyModels.map(\.modelID), ["deepseek-v4-flash", "MiniMax-M2.7"])
        XCTAssertEqual(viewModel.proxyModels.map(\.providerID), ["deepseek", "minimax"])
        if case .loaded = viewModel.proxyModelCatalogState {
            // expected
        } else {
            XCTFail("Expected loaded catalog state, got \(viewModel.proxyModelCatalogState)")
        }
    }

    func test_refreshProxyModelCatalog_surfacesGatewayFailure() async {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in throw ProxyCatalogTestError.offline }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)

        XCTAssertTrue(viewModel.proxyModels.isEmpty)
        if case .error(let message, _) = viewModel.proxyModelCatalogState {
            XCTAssertEqual(message, "Gateway offline")
        } else {
            XCTFail("Expected error catalog state, got \(viewModel.proxyModelCatalogState)")
        }
    }

    func test_startProxyGatewayShowsStartingStateBeforeRestartCompletes() async {
        var observedState: ProxyModelCatalogState?
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                XCTFail("Daemon start failure should stop before catalog fetch.")
                return []
            }
        )

        await viewModel.startProxyGateway(settings: settings) {
            observedState = self.viewModel.proxyModelCatalogState
            return "launchctl failed: helper missing"
        }

        XCTAssertEqual(observedState, .startingGateway)
    }

    func test_startProxyGatewaySurfacesDaemonFailureInsteadOfGenericCatalogFailure() async {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                XCTFail("Daemon start failure should stop before catalog fetch.")
                return []
            }
        )

        await viewModel.startProxyGateway(settings: settings) {
            "OpenBurnBarDaemon resources are missing."
        }

        XCTAssertTrue(settings.gatewayEnabled)
        XCTAssertEqual(settings.gatewayHost, "127.0.0.1")
        XCTAssertEqual(settings.gatewayPort, 8317)
        if case .error(let message, _) = viewModel.proxyModelCatalogState {
            XCTAssertEqual(message, "OpenBurnBarDaemon resources are missing.")
        } else {
            XCTFail("Expected daemon start error, got \(viewModel.proxyModelCatalogState)")
        }
    }

    func test_startProxyGatewayRefreshesCatalogAfterSuccessfulRestart() async {
        var fetchCount = 0
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { gateway in
                fetchCount += 1
                XCTAssertEqual(gateway.baseURL, "http://127.0.0.1:8317")
                return []
            }
        )

        await viewModel.startProxyGateway(settings: settings) {
            nil
        }

        XCTAssertEqual(fetchCount, 1)
        if case .loaded = viewModel.proxyModelCatalogState {
            // expected
        } else {
            XCTFail("Expected loaded catalog state, got \(viewModel.proxyModelCatalogState)")
        }
    }

    func test_refreshProxyRouteLogLoadsEntriesFromDaemonSocket() async throws {
        let socketURL = URL(fileURLWithPath: "/tmp/openburnbar-test.sock")
        let sample = makeRouteLogEntry(
            clientModelSlug: "claude-3-opus",
            upstreamModelSlug: "claude-3-opus",
            providerID: "anthropic",
            providerName: "Anthropic",
            providerLogoKey: "AnthropicLogo",
            finalStatus: .exact
        )
        var capturedSocketURL: URL?
        var capturedLimit: Int?
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyRouteLogFetcher: { socketURL, limit in
                capturedSocketURL = socketURL
                capturedLimit = limit
                return [sample]
            }
        )

        await viewModel.refreshProxyRouteLog(socketURL: socketURL, limit: 25)

        XCTAssertEqual(capturedSocketURL, socketURL)
        XCTAssertEqual(capturedLimit, 25)
        XCTAssertEqual(viewModel.proxyRouteLogEntries, [sample])
        if case .loaded = viewModel.proxyRouteLogState {
            // expected
        } else {
            XCTFail("Expected loaded route-log state, got \(viewModel.proxyRouteLogState)")
        }
    }

    func test_clearProxyRouteLogClearsEntriesThroughDaemonSocket() async {
        let socketURL = URL(fileURLWithPath: "/tmp/openburnbar-test.sock")
        var capturedSocketURL: URL?
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyRouteLogClearer: { socketURL in
                capturedSocketURL = socketURL
                return true
            }
        )
        viewModel.proxyRouteLogEntries = [
            makeRouteLogEntry(
                clientModelSlug: "claude-3-opus",
                upstreamModelSlug: "deepseek-chat",
                providerID: "deepseek",
                providerName: "DeepSeek",
                providerLogoKey: "DeepSeekProviderLogo",
                finalStatus: .crossVendorFallback
            )
        ]

        await viewModel.clearProxyRouteLog(socketURL: socketURL)

        XCTAssertEqual(capturedSocketURL, socketURL)
        XCTAssertTrue(viewModel.proxyRouteLogEntries.isEmpty)
        if case .loaded = viewModel.proxyRouteLogState {
            // expected
        } else {
            XCTFail("Expected loaded route-log state after clear, got \(viewModel.proxyRouteLogState)")
        }
    }

    func test_refreshProxyRouteLogSurfacesDaemonFailure() async {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyRouteLogFetcher: { _, _ in throw ProxyRouteLogTestError.offline }
        )

        await viewModel.refreshProxyRouteLog(socketURL: URL(fileURLWithPath: "/tmp/openburnbar-test.sock"))

        XCTAssertTrue(viewModel.proxyRouteLogEntries.isEmpty)
        if case .error(let message, _) = viewModel.proxyRouteLogState {
            XCTAssertEqual(message, "Route log offline")
        } else {
            XCTFail("Expected error route-log state, got \(viewModel.proxyRouteLogState)")
        }
    }

    func test_refreshProxyModelCatalog_collapsesSameProviderModelAcrossAccounts() async throws {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                [
                    ProxyAdvertisedModel(
                        modelID: "shared-model",
                        displayName: "Shared Model (Primary)",
                        providerID: "openai-compatible",
                        providerName: "OpenAI Compatible",
                        accountID: "default",
                        accountLabel: "Primary",
                        sourceID: "provider-a#default",
                        sourceKind: "upstream_models_endpoint",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat"],
                        lastError: nil
                    ),
                    ProxyAdvertisedModel(
                        modelID: "shared-model",
                        displayName: "Shared Model (Reserve)",
                        providerID: "openai-compatible",
                        providerName: "OpenAI Compatible",
                        accountID: "backup",
                        accountLabel: "Reserve",
                        sourceID: "provider-b#default",
                        sourceKind: "upstream_models_endpoint",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat"],
                        lastError: nil
                    )
                ]
            }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)

        XCTAssertEqual(viewModel.proxyModels.count, 1)
        let model = try XCTUnwrap(viewModel.proxyModels.first)
        XCTAssertEqual(model.modelID, "shared-model")
        XCTAssertEqual(model.displayName, "Shared Model")
        XCTAssertEqual(model.accountID, "auto")
        XCTAssertEqual(model.accountLabel, "Auto failover (2 accounts)")
        XCTAssertEqual(model.sourceID, "openai-compatible#auto")
        XCTAssertEqual(model.sourceKind, "upstream_models_endpoint")
        XCTAssertTrue(model.routeEligible)
    }

    // A collapsed multi-account row may be served by any backing account, so
    // it must advertise the minimum context window and only the modalities
    // every account supports — mirroring the daemon's
    // `mergedModelCapabilities` instead of promising one account's superset.
    func test_refreshProxyModelCatalog_collapseUsesConservativeCapabilityMetadata() async throws {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                [
                    ProxyAdvertisedModel(
                        modelID: "shared-model",
                        displayName: "Shared Model",
                        providerID: "openai-compatible",
                        providerName: "OpenAI Compatible",
                        accountID: "default",
                        accountLabel: "Primary",
                        sourceID: "provider-a#default",
                        sourceKind: "upstream_models_endpoint",
                        contextWindowTokens: 1_000_000,
                        inputModalities: ["text", "image"],
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat"],
                        lastError: nil
                    ),
                    ProxyAdvertisedModel(
                        modelID: "shared-model",
                        displayName: "Shared Model",
                        providerID: "openai-compatible",
                        providerName: "OpenAI Compatible",
                        accountID: "backup",
                        accountLabel: "Reserve",
                        sourceID: "provider-b#default",
                        sourceKind: "upstream_models_endpoint",
                        contextWindowTokens: 128_000,
                        inputModalities: ["text"],
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat"],
                        lastError: nil
                    )
                ]
            }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)

        XCTAssertEqual(viewModel.proxyModels.count, 1)
        let model = try XCTUnwrap(viewModel.proxyModels.first)
        XCTAssertEqual(model.accountLabel, "Auto failover (2 accounts)")
        XCTAssertEqual(model.contextWindowTokens, 128_000)
        XCTAssertEqual(model.inputModalities, ["text"])
    }

    func test_refreshProxyModelCatalog_keepsSameModelDistinctAcrossProviders() async {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                [
                    ProxyAdvertisedModel(
                        modelID: "shared-model",
                        displayName: "Shared Model",
                        providerID: "provider-a",
                        providerName: "Provider A",
                        accountID: "default",
                        accountLabel: "Primary",
                        sourceID: "provider-a#default",
                        sourceKind: "upstream_models_endpoint",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat"],
                        lastError: nil
                    ),
                    ProxyAdvertisedModel(
                        modelID: "shared-model",
                        displayName: "Shared Model",
                        providerID: "provider-b",
                        providerName: "Provider B",
                        accountID: "default",
                        accountLabel: "Primary",
                        sourceID: "provider-b#default",
                        sourceKind: "upstream_models_endpoint",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat"],
                        lastError: nil
                    )
                ]
            }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)

        XCTAssertEqual(viewModel.proxyModels.count, 2)
        XCTAssertEqual(viewModel.proxyModels.map(\.providerID), ["provider-a", "provider-b"])
    }

    func test_refreshProxyModelCatalog_preservesEndpointMetadataForClaudeCompatibleRows() async throws {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                [
                    self.makeProxyAdvertisedModel(
                        modelID: "glm-5.2",
                        displayName: "GLM 5.2",
                        providerID: "zai",
                        providerName: "Z.ai",
                        formatFamily: "openai_compat",
                        servedEndpoints: ["/v1/messages", "/v1/responses"]
                    )
                ]
            }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)

        let model = try XCTUnwrap(viewModel.proxyModels.first)
        XCTAssertEqual(model.modelID, "glm-5.2")
        XCTAssertEqual(model.formatFamily, "openai_compat")
        XCTAssertTrue(model.servedEndpoints.contains("/v1/messages"))
        XCTAssertTrue(model.servedEndpoints.contains("/v1/responses"))
    }

    func test_disconnect_unwiresButLeavesGatewayEnabled() async {
        await viewModel.connect(target: .claudeCode, settings: settings)
        XCTAssertTrue(settings.gatewayEnabled)

        await viewModel.disconnect(target: .claudeCode)

        XCTAssertEqual(viewModel.state(for: .claudeCode), .notConnected,
                       "Disconnect must roll back the row to .notConnected")
        XCTAssertTrue(settings.gatewayEnabled,
                      "Disconnect must NOT turn off the gateway — other apps may still be wired")
        XCTAssertFalse(
            RoutingClientWiring(home: tempHome).isWired(target: .claudeCode),
            "Disconnect must remove the on-disk wiring"
        )
    }

    func test_refreshWiringState_reflectsOnDiskTruth() async throws {
        // Pre-wire from outside the view model, then refresh and assert the
        // view sees it. This is the round-trip a user gets when they reopen
        // Settings after a previous Connect.
        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        _ = try RoutingClientWiring(home: tempHome).wire(target: .claudeCode, gateway: gateway)

        viewModel.refreshWiringState()

        XCTAssertEqual(viewModel.state(for: .claudeCode), .connected)
        XCTAssertEqual(viewModel.state(for: .codex), .notConnected)
    }

    func test_refreshWiringState_marksDroidStaleWhenCachedModelsNoLongerMatchLiveCatalog() async throws {
        settings.gatewayEnabled = true
        settings.gatewayHost = "127.0.0.1"
        settings.gatewayPort = 8317
        settings.gatewayAuthToken = ""

        let settingsURL = tempHome.appendingPathComponent(".factory/settings.local.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "customModels": [
            {"model": "MiniMax-M2.5", "id": "custom:OpenBurnBar-MiniMax-M2.5-0", "displayName": "OpenBurnBar MiniMax M2.5", "provider": "generic-chat-completion-api", "baseUrl": "http://127.0.0.1:8317/v1"}
          ]
        }
        """.utf8).write(to: settingsURL)

        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                [
                    ProxyAdvertisedModel(
                        modelID: "MiniMax-M2.7",
                        displayName: "MiniMax M2.7",
                        providerID: "minimax",
                        providerName: "MiniMax",
                        accountID: "acct_minimax",
                        accountLabel: "MiniMax primary",
                        sourceID: "minimax#acct_minimax",
                        sourceKind: "provider_account",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["openai_compat", "routing"],
                        lastError: nil
                    )
                ]
            }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)
        await viewModel.refreshWiringState(settings: settings)

        if case .degraded(let message) = viewModel.state(for: .droid) {
            XCTAssertTrue(message.contains("Droid's BurnBar model list is stale"))
            XCTAssertTrue(message.contains("Sync models"))
        } else {
            XCTFail("Expected Droid row to show stale/degraded, got \(viewModel.state(for: .droid))")
        }
    }

    func test_refreshWiringState_marksCodexStaleWhenCachedCatalogNoLongerMatchesLiveCatalog() async throws {
        settings.gatewayEnabled = true
        settings.gatewayHost = "127.0.0.1"
        settings.gatewayPort = 8317
        settings.gatewayAuthToken = ""

        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        let wiring = RoutingClientWiring(home: tempHome)
        let installedModel = RoutingClientAdvertisedModel(
            id: "glm-5.1",
            displayName: "GLM 5.1",
            providerID: "zai",
            providerName: "Z.ai",
            servedEndpoints: ["/v1/responses"],
            routeEligible: true
        )
        _ = try wiring.wire(target: .codex, gateway: gateway, advertisedModels: [installedModel])

        viewModel = ConnectionsViewModel(wiringFactory: { RoutingClientWiring(home: self.tempHome) })
        viewModel.proxyModels = [
            makeProxyAdvertisedModel(
                modelID: "glm-5.2",
                displayName: "GLM 5.2",
                providerID: "zai",
                providerName: "Z.ai",
                servedEndpoints: ["/v1/responses"]
            )
        ]

        await viewModel.refreshWiringState(settings: settings)

        if case .degraded(let message) = viewModel.state(for: .codex) {
            XCTAssertTrue(message.contains("Codex's BurnBar model catalog is stale"))
            XCTAssertTrue(message.contains("Sync models"))
        } else {
            XCTFail("Expected Codex row to show stale/degraded, got \(viewModel.state(for: .codex))")
        }
    }

    func test_refreshWiringState_marksClaudeStaleWhenCachedCatalogNoLongerMatchesLiveCatalog() async throws {
        settings.gatewayEnabled = true
        settings.gatewayHost = "127.0.0.1"
        settings.gatewayPort = 8317
        settings.gatewayAuthToken = ""

        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        let wiring = RoutingClientWiring(home: tempHome)
        let installedModel = RoutingClientAdvertisedModel(
            id: "glm-5.1",
            displayName: "GLM 5.1",
            providerID: "zai",
            providerName: "Z.ai",
            formatFamily: "openai_compat",
            servedEndpoints: ["/v1/messages"],
            routeEligible: true
        )
        _ = try wiring.wire(target: .claudeCode, gateway: gateway, advertisedModels: [installedModel])

        viewModel = ConnectionsViewModel(wiringFactory: { RoutingClientWiring(home: self.tempHome) })
        viewModel.proxyModels = [
            makeProxyAdvertisedModel(
                modelID: "glm-5.2",
                displayName: "GLM 5.2",
                providerID: "zai",
                providerName: "Z.ai",
                formatFamily: "openai_compat",
                servedEndpoints: ["/v1/messages", "/v1/responses"]
            )
        ]

        await viewModel.refreshWiringState(settings: settings)

        if case .degraded(let message) = viewModel.state(for: .claudeCode) {
            XCTAssertTrue(message.contains("Claude Code's BurnBar discovery catalog is stale"))
            XCTAssertTrue(message.contains("Sync models"))
            XCTAssertTrue(message.contains("restart Claude Code"))
        } else {
            XCTFail("Expected Claude Code row to show stale/degraded, got \(viewModel.state(for: .claudeCode))")
        }
    }

    // MARK: - Route-ready truth

    func test_routeReadiness_requiresRouteReadyGatewayCredentialForClaude() {
        XCTAssertFalse(
            ConnectionsRouteReadiness.hasRouteReadyProvider(for: .claudeCode, configurations: []),
            "A local Claude Code login alone is not a BurnBar proxy route."
        )

        XCTAssertTrue(
            ConnectionsRouteReadiness.hasRouteReadyProvider(
                for: .claudeCode,
                configurations: [
                    makeProviderConfiguration(
                        providerID: "anthropic",
                        formatDisplayName: "Anthropic",
                        slotStatus: .ready
                    )
                ]
            )
        )

        XCTAssertFalse(
            ConnectionsRouteReadiness.hasRouteReadyProvider(
                for: .claudeCode,
                configurations: [
                    makeProviderConfiguration(
                        providerID: "anthropic",
                        formatDisplayName: "Anthropic",
                        slotStatus: .missingSecret
                    )
                ]
            ),
            "Claude must not show route-ready when the Anthropic slot has no usable credential."
        )

        XCTAssertTrue(
            ConnectionsRouteReadiness.hasRouteReadyProvider(
                for: .claudeCode,
                configurations: [
                    makeProviderConfiguration(
                        providerID: "minimax",
                        formatDisplayName: "MiniMax",
                        slotStatus: .ready
                    )
                ]
            ),
            "Claude Code can use OpenAI-compatible OpenBurnBar providers through the /v1/messages bridge."
        )
    }

    func test_routeReadiness_mapsGatewayCLIsToBridgeCapableProviders() {
        let minimax = makeProviderConfiguration(
            providerID: "minimax",
            formatDisplayName: "MiniMax",
            slotStatus: .ready
        )

        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .codex, configurations: [minimax]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .opencode, configurations: [minimax]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .forge, configurations: [minimax]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .droid, configurations: [minimax]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .claudeCode, configurations: [minimax]))

        let anthropic = makeProviderConfiguration(
            providerID: "anthropic",
            formatDisplayName: "Anthropic",
            slotStatus: .ready
        )
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .codex, configurations: [anthropic]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .droid, configurations: [anthropic]))
    }

    func test_providerRouteReadyCredentialSlotsIgnoreEnabledProviderWithNoUsableCredential() {
        let switchedOnNoCredential = makeProviderConfiguration(
            providerID: "anthropic",
            formatDisplayName: "Anthropic",
            slotStatus: .ready,
            includeSlot: false
        )
        XCTAssertTrue(switchedOnNoCredential.isEnabled)
        XCTAssertTrue(switchedOnNoCredential.hasRoutingCapability)
        XCTAssertTrue(switchedOnNoCredential.routeReadyCredentialSlots.isEmpty)

        let disabledSlot = makeProviderConfiguration(
            providerID: "anthropic",
            formatDisplayName: "Anthropic",
            slotStatus: .ready,
            slotIsEnabled: false
        )
        XCTAssertTrue(disabledSlot.routeReadyCredentialSlots.isEmpty)

        let readySlot = makeProviderConfiguration(
            providerID: "anthropic",
            formatDisplayName: "Anthropic",
            slotStatus: .ready
        )
        XCTAssertEqual(readySlot.routeReadyCredentialSlots.map(\.slotID), ["default"])
    }

    func test_daemonCredentialSlotProjectionIncludesCatalogOnlyRouteAccounts() {
        let updatedAt = Date(timeIntervalSince1970: 1_773_700_000)
        let now = Date(timeIntervalSince1970: 1_773_700_500)
        let configuration = OpenBurnBarDaemonProviderConfiguration(
            providerID: "deepseek",
            provider: nil,
            displayName: "DeepSeek",
            isEnabled: true,
            baseURL: "https://api.deepseek.com/v1",
            preferredModelIDs: ["deepseek-chat"],
            preferredCredentialSlotID: "default",
            credentialSlots: [
                OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                    slotID: "default",
                    label: "Default plan",
                    isEnabled: true,
                    status: .ready,
                    cooldownUntil: nil,
                    lastSelectedAt: updatedAt,
                    lastQuotaRemainingPercent: nil,
                    lastQuotaResetsAt: nil,
                    lastStatusMessage: nil,
                    updatedAt: updatedAt
                ),
                OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                    slotID: "gmail",
                    label: "gmail",
                    isEnabled: true,
                    status: .missingSecret,
                    cooldownUntil: nil,
                    lastSelectedAt: nil,
                    lastQuotaRemainingPercent: nil,
                    lastQuotaResetsAt: nil,
                    lastStatusMessage: "Missing API key",
                    updatedAt: updatedAt
                )
            ]
        )

        let accounts = DaemonCredentialSlotAccountProjection.accounts(from: [configuration], now: now)

        XCTAssertEqual(accounts.map(\.id), ["deepseek-default", "deepseek-gmail"])
        XCTAssertEqual(accounts.map(\.providerID), [ProviderID(rawValue: "deepseek"), ProviderID(rawValue: "deepseek")])
        XCTAssertEqual(accounts.map(\.status), [.connected, .error])
        XCTAssertEqual(accounts.first?.label, "Default plan")
        XCTAssertEqual(accounts.first?.identityHint, "Daemon credential slot")
        XCTAssertEqual(accounts.first?.storageScope, .deviceKeychain)
        XCTAssertEqual(accounts.first?.credentialKind, .bearer)
        XCTAssertEqual(accounts.first?.isDefault, true)
        XCTAssertEqual(accounts.first?.lastValidatedAt, updatedAt)
        XCTAssertEqual(accounts.first?.lastRefreshAt, updatedAt)
        XCTAssertEqual(accounts.last?.lastErrorCode, "missingSecret")
        XCTAssertEqual(accounts.last?.updatedAt, now)
    }

    private func makeProviderConfiguration(
        providerID: String,
        formatDisplayName: String,
        slotStatus: BurnBarProviderCredentialSlotStatus,
        slotIsEnabled: Bool = true,
        includeSlot: Bool = true
    ) -> OpenBurnBarDaemonProviderConfiguration {
        OpenBurnBarDaemonProviderConfiguration(
            providerID: providerID,
            provider: nil,
            displayName: formatDisplayName,
            isEnabled: true,
            baseURL: "https://\(providerID).example/v1",
            preferredModelIDs: [],
            preferredCredentialSlotID: "default",
            credentialSlots: includeSlot ? [
                OpenBurnBarDaemonProviderConfiguration.CredentialSlot(
                    slotID: "default",
                    label: "Default",
                    isEnabled: slotIsEnabled,
                    status: slotStatus,
                    cooldownUntil: nil,
                    lastSelectedAt: nil,
                    lastQuotaRemainingPercent: nil,
                    lastQuotaResetsAt: nil,
                    lastStatusMessage: nil,
                    updatedAt: Date()
                )
            ] : []
        )
    }

    private func makeProxyAdvertisedModel(
        modelID: String,
        displayName: String,
        providerID: String,
        providerName: String,
        formatFamily: String = "openai_compat",
        servedEndpoints: [String] = ["/v1/chat/completions", "/v1/responses"],
        routeEligible: Bool = true
    ) -> ProxyAdvertisedModel {
        ProxyAdvertisedModel(
            modelID: modelID,
            displayName: displayName,
            providerID: providerID,
            providerName: providerName,
            accountID: "default",
            accountLabel: "Default",
            sourceID: "\(providerID)#default",
            sourceKind: "upstream_models_endpoint",
            formatFamily: formatFamily,
            servedEndpoints: servedEndpoints,
            quotaState: "healthy",
            routeEligible: routeEligible,
            capabilities: [formatFamily, "routing"],
            lastError: nil
        )
    }

    private func makeRouteLogEntry(
        clientModelSlug: String,
        upstreamModelSlug: String,
        providerID: String,
        providerName: String,
        providerLogoKey: String,
        finalStatus: BurnBarProxyRouteFinalStatus
    ) -> BurnBarProxyRouteLogEntry {
        let occurredAt = Date(timeIntervalSince1970: 1_773_710_000)
        return BurnBarProxyRouteLogEntry(
            id: "\(clientModelSlug)-\(upstreamModelSlug)-\(finalStatus.rawValue)",
            occurredAt: occurredAt,
            completedAt: occurredAt.addingTimeInterval(0.2),
            durationMilliseconds: 200,
            requestPath: "/v1/chat/completions",
            endpoint: "Chat Completions",
            clientModelSlug: clientModelSlug,
            advertisedModelSlug: clientModelSlug,
            routingModelSlug: clientModelSlug,
            upstreamModelSlug: upstreamModelSlug,
            providerReportedModelSlug: upstreamModelSlug,
            clientModelDisplayName: clientModelSlug,
            routingModelDisplayName: clientModelSlug,
            upstreamModelDisplayName: upstreamModelSlug,
            providerID: providerID,
            providerName: providerName,
            providerLogoKey: providerLogoKey,
            accountID: "default",
            accountLabel: "Default",
            requestedCanonicalModelID: clientModelSlug,
            servedCanonicalModelID: upstreamModelSlug,
            formatFamily: "openai_compat",
            endpointProfileID: nil,
            transportKind: .http,
            rewriteKind: finalStatus == .crossVendorFallback ? .crossVendorFallback : .none,
            exactModelInvariant: finalStatus == .crossVendorFallback ? .notApplicable : .passed,
            finalStatus: finalStatus,
            streamed: false,
            streamInterrupted: false,
            httpStatus: 200,
            attempts: [
                BurnBarProxyRouteAttempt(
                    id: "\(providerID)-attempt",
                    sequence: 1,
                    startedAt: occurredAt,
                    completedAt: occurredAt.addingTimeInterval(0.2),
                    durationMilliseconds: 200,
                    providerID: providerID,
                    providerName: providerName,
                    providerLogoKey: providerLogoKey,
                    accountID: "default",
                    accountLabel: "Default",
                    routingModelSlug: clientModelSlug,
                    upstreamModelSlug: upstreamModelSlug,
                    canonicalModelID: upstreamModelSlug,
                    formatFamily: "openai_compat",
                    endpointProfileID: nil,
                    transportKind: .http,
                    status: finalStatus,
                    httpStatus: 200,
                    failureMessage: nil
                )
            ],
            usage: nil,
            failureMessage: nil
        )
    }

    func test_refreshProxyModelCatalog_decodesUserModelAliasMetadata() async {
        viewModel = ConnectionsViewModel(
            wiringFactory: { RoutingClientWiring(home: self.tempHome) },
            proxyCatalogFetcher: { _ in
                [
                    ProxyAdvertisedModel(
                        modelID: "my-fast-coder",
                        displayName: "My Claude",
                        providerID: "anthropic",
                        providerName: "Anthropic",
                        accountID: "default",
                        accountLabel: "Default",
                        sourceID: "anthropic#default::alias::my-fast-coder",
                        sourceKind: "user_model_alias",
                        quotaState: "healthy",
                        routeEligible: true,
                        capabilities: ["anthropic", "routing"],
                        lastError: nil,
                        baseModelID: "claude-sonnet-4-6",
                        hidesBaseModel: true
                    )
                ]
            }
        )

        await viewModel.refreshProxyModelCatalog(settings: settings)

        let alias = viewModel.proxyModels.first
        XCTAssertNotNil(alias)
        XCTAssertEqual(alias?.modelID, "my-fast-coder")
        XCTAssertEqual(alias?.baseModelID, "claude-sonnet-4-6")
        XCTAssertTrue(alias?.isUserModelAlias ?? false)
        XCTAssertTrue(alias?.hidesBaseModel ?? false)
    }

    // MARK: - Routed client model summary

    func test_modelSummary_returnsNilForNonSyncTargets() {
        XCTAssertNil(viewModel.modelSummary(for: .opencode))
        XCTAssertNil(viewModel.modelSummary(for: .forge))
        XCTAssertNil(viewModel.modelSummary(for: .grok))
        XCTAssertNil(viewModel.modelSummary(for: .antigravity))
        XCTAssertNil(viewModel.modelSummary(for: .cursorAgent))
    }

    func test_modelSummary_countsOpenBurnBarModelsByTargetEndpoint() async {
        viewModel.proxyModels = [
            makeProxyAdvertisedModel(
                modelID: "glm-5.2",
                displayName: "GLM 5.2",
                providerID: "zai",
                providerName: "Z.ai",
                servedEndpoints: ["/v1/messages", "/v1/responses"]
            ),
            makeProxyAdvertisedModel(
                modelID: "deepseek-chat",
                displayName: "DeepSeek Chat",
                providerID: "deepseek",
                providerName: "DeepSeek",
                servedEndpoints: ["/v1/chat/completions"]
            ),
            makeProxyAdvertisedModel(
                modelID: "minimax-m2",
                displayName: "MiniMax M2",
                providerID: "minimax",
                providerName: "MiniMax",
                servedEndpoints: ["/v1/chat/completions", "/v1/responses"]
            )
        ]

        // Claude Code: only /v1/messages models count
        let claudeSummary = viewModel.modelSummary(for: .claudeCode)
        XCTAssertNotNil(claudeSummary)
        XCTAssertEqual(claudeSummary?.openburnbarModelCount, 1)
        XCTAssertTrue(claudeSummary?.hasNativeModels ?? false)
        XCTAssertEqual(claudeSummary?.countLabel, "1 OpenBurnBar + native models")
        XCTAssertEqual(claudeSummary?.nativeBadgeText, "Native + OpenBurnBar")

        // Codex: /v1/responses models count (glm-5.2 + minimax-m2)
        let codexSummary = viewModel.modelSummary(for: .codex)
        XCTAssertNotNil(codexSummary)
        XCTAssertEqual(codexSummary?.openburnbarModelCount, 2)
        XCTAssertTrue(codexSummary?.hasNativeModels ?? false)
        XCTAssertEqual(codexSummary?.countLabel, "2 OpenBurnBar + native models")

        // Droid: /v1/chat/completions OR /v1/responses models count
        // (deepseek-chat + minimax-m2 via chat, glm-5.2 + minimax-m2 via responses)
        let droidSummary = viewModel.modelSummary(for: .droid)
        XCTAssertNotNil(droidSummary)
        XCTAssertEqual(droidSummary?.openburnbarModelCount, 3)
        XCTAssertFalse(droidSummary?.hasNativeModels ?? true)
        XCTAssertEqual(droidSummary?.countLabel, "3 OpenBurnBar models")
        XCTAssertNil(droidSummary?.nativeBadgeText)
    }

    func test_modelSummary_returnsZeroWhenNoModelsAvailable() {
        viewModel.proxyModels = []

        let summary = viewModel.modelSummary(for: .droid)
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.openburnbarModelCount, 0)
        XCTAssertNil(summary?.countLabel)
        XCTAssertNil(summary?.nativeBadgeText)
    }

    func test_modelSummary_excludesNonRouteEligibleModels() async {
        viewModel.proxyModels = [
            ProxyAdvertisedModel(
                modelID: "inactive-model",
                displayName: "Inactive Model",
                providerID: "minimax",
                providerName: "MiniMax",
                accountID: "default",
                accountLabel: "Default",
                sourceID: "minimax#default",
                sourceKind: "provider_account",
                servedEndpoints: ["/v1/chat/completions"],
                quotaState: "disabled",
                routeEligible: false,
                capabilities: [],
                lastError: nil
            ),
            makeProxyAdvertisedModel(
                modelID: "active-model",
                displayName: "Active Model",
                providerID: "minimax",
                providerName: "MiniMax",
                servedEndpoints: ["/v1/chat/completions"]
            )
        ]

        let droidSummary = viewModel.modelSummary(for: .droid)
        XCTAssertEqual(droidSummary?.openburnbarModelCount, 1)
    }

    // MARK: - RoutingClientWiringTarget probe endpoint info

    func test_probeEndpointLabel_returnsCorrectPathPerTarget() {
        XCTAssertEqual(RoutingClientWiringTarget.claudeCode.probeEndpointLabel, "POST /v1/messages")
        XCTAssertEqual(RoutingClientWiringTarget.codex.probeEndpointLabel, "POST /v1/responses")
        XCTAssertEqual(RoutingClientWiringTarget.droid.probeEndpointLabel, "POST /v1/chat/completions")
        XCTAssertNil(RoutingClientWiringTarget.antigravity.probeEndpointLabel)
        XCTAssertNil(RoutingClientWiringTarget.cursorAgent.probeEndpointLabel)
    }

    func test_supportsModelSync_flagsDroidCodexClaudeOnly() {
        XCTAssertTrue(RoutingClientWiringTarget.droid.supportsModelSync)
        XCTAssertTrue(RoutingClientWiringTarget.codex.supportsModelSync)
        XCTAssertTrue(RoutingClientWiringTarget.claudeCode.supportsModelSync)
        XCTAssertFalse(RoutingClientWiringTarget.opencode.supportsModelSync)
        XCTAssertFalse(RoutingClientWiringTarget.forge.supportsModelSync)
        XCTAssertFalse(RoutingClientWiringTarget.grok.supportsModelSync)
        XCTAssertFalse(RoutingClientWiringTarget.antigravity.supportsModelSync)
        XCTAssertFalse(RoutingClientWiringTarget.cursorAgent.supportsModelSync)
    }

    func test_endpointDescription_returnsReadableEndpointLabel() {
        XCTAssertTrue(RoutingClientWiringTarget.claudeCode.endpointDescription.contains("/v1/messages"))
        XCTAssertTrue(RoutingClientWiringTarget.codex.endpointDescription.contains("/v1/responses"))
        XCTAssertTrue(RoutingClientWiringTarget.droid.endpointDescription.contains("/v1/chat/completions"))
        XCTAssertTrue(RoutingClientWiringTarget.antigravity.endpointDescription.contains("Profile-scoped"))
    }

    // The VibeProxy migration path converts cached `proxyModels` rows with
    // `RoutingClientAdvertisedModel.init(proxyModel:)` instead of re-probing
    // /v1/models, so capability metadata must survive that conversion or
    // migrated Codex catalogs fall back to 65,536 tokens / text-only.
    func test_routingClientAdvertisedModel_fromProxyModel_carriesCapabilityMetadata() {
        let proxyModel = ProxyAdvertisedModel(
            modelID: "claude-opus-4-8",
            displayName: "Claude Opus 4.8",
            providerID: "anthropic",
            providerName: "Anthropic",
            accountID: "default",
            accountLabel: "Default",
            sourceID: "anthropic#default",
            sourceKind: "provider_account",
            servedEndpoints: ["/v1/responses"],
            contextWindowTokens: 1_000_000,
            inputModalities: ["text", "image"],
            quotaState: "healthy",
            routeEligible: true,
            capabilities: [],
            lastError: nil
        )

        let converted = RoutingClientAdvertisedModel(proxyModel: proxyModel)

        XCTAssertEqual(converted.contextWindowTokens, 1_000_000)
        XCTAssertEqual(converted.inputModalities, ["text", "image"])
    }

    func test_routingClientAdvertisedModel_fromLegacyProxyModel_defaultsCapabilityMetadata() {
        let legacyProxyModel = makeProxyAdvertisedModel(
            modelID: "glm-5",
            displayName: "GLM-5",
            providerID: "zai",
            providerName: "Z.AI"
        )

        let converted = RoutingClientAdvertisedModel(proxyModel: legacyProxyModel)

        XCTAssertNil(converted.contextWindowTokens)
        XCTAssertEqual(converted.inputModalities, ["text"])
    }

    func test_gatewayServes_respectsEndpointShape() {
        let chatOnlyModel = ProxyAdvertisedModel(
            modelID: "chat-model",
            displayName: "Chat Model",
            providerID: "minimax",
            providerName: "MiniMax",
            accountID: "default",
            accountLabel: "Default",
            sourceID: "minimax#default",
            sourceKind: "provider_account",
            servedEndpoints: ["/v1/chat/completions"],
            quotaState: "healthy",
            routeEligible: true,
            capabilities: [],
            lastError: nil
        )

        let messagesModel = ProxyAdvertisedModel(
            modelID: "messages-model",
            displayName: "Messages Model",
            providerID: "anthropic",
            providerName: "Anthropic",
            accountID: "default",
            accountLabel: "Default",
            sourceID: "anthropic#default",
            sourceKind: "provider_account",
            formatFamily: "anthropic",
            servedEndpoints: ["/v1/messages"],
            quotaState: "healthy",
            routeEligible: true,
            capabilities: [],
            lastError: nil
        )

        XCTAssertTrue(RoutingClientWiringTarget.droid.gatewayServes(model: chatOnlyModel))
        XCTAssertFalse(RoutingClientWiringTarget.claudeCode.gatewayServes(model: chatOnlyModel))
        XCTAssertTrue(RoutingClientWiringTarget.claudeCode.gatewayServes(model: messagesModel))
        XCTAssertFalse(RoutingClientWiringTarget.codex.gatewayServes(model: messagesModel))
    }

    func test_gatewayServes_emptyEndpointsTreatsGatewayClientsAsBridgeCompatible() {
        // Older gateway catalogs did not include servedEndpoints. The UI must
        // mirror the wiring service and count those legacy rows for gateway-
        // shaped clients because the daemon can bridge them at request time.
        let anthropicNoEndpoints = ProxyAdvertisedModel(
            modelID: "claude-empty",
            displayName: "Claude Empty",
            providerID: "anthropic",
            providerName: "Anthropic",
            accountID: "default",
            accountLabel: "Default",
            sourceID: "anthropic#default",
            sourceKind: "provider_account",
            formatFamily: "anthropic",
            servedEndpoints: [],
            quotaState: "healthy",
            routeEligible: true,
            capabilities: [],
            lastError: nil
        )

        let openaiNoEndpoints = ProxyAdvertisedModel(
            modelID: "gpt-empty",
            displayName: "GPT Empty",
            providerID: "openai",
            providerName: "OpenAI",
            accountID: "default",
            accountLabel: "Default",
            sourceID: "openai#default",
            sourceKind: "provider_account",
            formatFamily: "openai_compat",
            servedEndpoints: [],
            quotaState: "healthy",
            routeEligible: true,
            capabilities: [],
            lastError: nil
        )

        XCTAssertTrue(RoutingClientWiringTarget.claudeCode.gatewayServes(model: anthropicNoEndpoints),
                      "Claude Code should serve empty-endpoint anthropic models")
        XCTAssertTrue(RoutingClientWiringTarget.claudeCode.gatewayServes(model: openaiNoEndpoints),
                      "Claude Code should serve legacy empty-endpoint openai_compat models through the messages bridge")
        XCTAssertTrue(RoutingClientWiringTarget.codex.gatewayServes(model: openaiNoEndpoints),
                      "Codex should serve empty-endpoint openai_compat models")
        XCTAssertTrue(RoutingClientWiringTarget.droid.gatewayServes(model: openaiNoEndpoints),
                      "Droid should serve empty-endpoint openai_compat models")
        XCTAssertFalse(RoutingClientWiringTarget.antigravity.gatewayServes(model: openaiNoEndpoints),
                       "Profile-scoped clients should not count legacy gateway rows")
        XCTAssertFalse(RoutingClientWiringTarget.cursorAgent.gatewayServes(model: openaiNoEndpoints),
                       "Profile-scoped clients should not count legacy gateway rows")
    }

    func test_gatewayServes_excludesNonAdvertisedAndNonRouteEligible() {
        let nonAdvertised = ProxyAdvertisedModel(
            modelID: "hidden-model",
            displayName: "Hidden Model",
            providerID: "minimax",
            providerName: "MiniMax",
            accountID: "default",
            accountLabel: "Default",
            sourceID: "minimax#default",
            sourceKind: "provider_account",
            servedEndpoints: ["/v1/chat/completions"],
            quotaState: "healthy",
            advertisementEnabled: false,
            advertised: false,
            routeEligible: true,
            capabilities: [],
            lastError: nil
        )

        let nonRouteEligible = ProxyAdvertisedModel(
            modelID: "disabled-model",
            displayName: "Disabled Model",
            providerID: "minimax",
            providerName: "MiniMax",
            accountID: "default",
            accountLabel: "Default",
            sourceID: "minimax#default",
            sourceKind: "provider_account",
            servedEndpoints: ["/v1/chat/completions"],
            quotaState: "disabled",
            advertised: true,
            routeEligible: false,
            capabilities: [],
            lastError: nil
        )

        XCTAssertFalse(RoutingClientWiringTarget.droid.gatewayServes(model: nonAdvertised),
                       "Non-advertised models must not be counted")
        XCTAssertFalse(RoutingClientWiringTarget.droid.gatewayServes(model: nonRouteEligible),
                       "Non-route-eligible models must not be counted")
    }

    func test_modelSummary_hasNativeModelsFlagsCodexAndClaudeOnly() {
        // Droid has no native model catalog — BurnBar is its only model source.
        let droidSummary = viewModel.modelSummary(for: .droid)
        XCTAssertNotNil(droidSummary)
        XCTAssertFalse(droidSummary?.hasNativeModels ?? true)

        // Codex and Claude Code have native GPT/Claude rows that BurnBar preserves.
        let codexSummary = viewModel.modelSummary(for: .codex)
        XCTAssertTrue(codexSummary?.hasNativeModels ?? false)

        let claudeSummary = viewModel.modelSummary(for: .claudeCode)
        XCTAssertTrue(claudeSummary?.hasNativeModels ?? false)
    }

    func test_modelSummary_countLabelEdgeCases() {
        // Zero models: label is nil.
        let empty = RoutedClientModelSummary(openburnbarModelCount: 0, hasNativeModels: true)
        XCTAssertNil(empty.countLabel)
        XCTAssertNotNil(empty.nativeBadgeText)

        // One model, no native: "1 OpenBurnBar model" (singular).
        let oneNoNative = RoutedClientModelSummary(openburnbarModelCount: 1, hasNativeModels: false)
        XCTAssertEqual(oneNoNative.countLabel, "1 OpenBurnBar model")
        XCTAssertNil(oneNoNative.nativeBadgeText)

        // Multiple models, with native: "N OpenBurnBar + native models".
        let multiWithNative = RoutedClientModelSummary(openburnbarModelCount: 5, hasNativeModels: true)
        XCTAssertEqual(multiWithNative.countLabel, "5 OpenBurnBar + native models")
        XCTAssertEqual(multiWithNative.nativeBadgeText, "Native + OpenBurnBar")
    }

    // MARK: - Routed client model summary metadata strip labels

    func test_modelSummary_openburnbarCountLabelNilWhenZero() {
        let summary = RoutedClientModelSummary(openburnbarModelCount: 0, hasNativeModels: false)
        XCTAssertNil(summary.openburnbarCountLabel)
    }

    func test_modelSummary_openburnbarCountLabelShowsCount() {
        let summary = RoutedClientModelSummary(openburnbarModelCount: 3, hasNativeModels: false)
        XCTAssertEqual(summary.openburnbarCountLabel, "3 via OpenBurnBar")
    }

    func test_modelSummary_nativeCountLabelReflectsFlag() {
        let withNative = RoutedClientModelSummary(openburnbarModelCount: 1, hasNativeModels: true)
        XCTAssertEqual(withNative.nativeCountLabel, "native catalog")

        let withoutNative = RoutedClientModelSummary(openburnbarModelCount: 1, hasNativeModels: false)
        XCTAssertNil(withoutNative.nativeCountLabel)
    }

    // MARK: - Endpoint badge label

    func test_endpointBadgeLabel_returnsCompactShapePerTarget() {
        XCTAssertEqual(RoutingClientWiringTarget.claudeCode.endpointBadgeLabel, "Messages")
        XCTAssertEqual(RoutingClientWiringTarget.codex.endpointBadgeLabel, "Responses")
        XCTAssertEqual(RoutingClientWiringTarget.droid.endpointBadgeLabel, "Chat Completions")
        XCTAssertEqual(RoutingClientWiringTarget.forge.endpointBadgeLabel, "Chat Completions")
        XCTAssertEqual(RoutingClientWiringTarget.antigravity.endpointBadgeLabel, "Profile-scoped")
        XCTAssertEqual(RoutingClientWiringTarget.cursorAgent.endpointBadgeLabel, "Profile-scoped")
    }
}

private enum ProxyCatalogTestError: LocalizedError {
    case offline

    var errorDescription: String? { "Gateway offline" }
}

private enum ProxyRouteLogTestError: LocalizedError {
    case offline

    var errorDescription: String? { "Route log offline" }
}

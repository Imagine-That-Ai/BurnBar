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

    func test_refreshProxyModelCatalog_keepsSameModelDistinctBySourceID() async {
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
                        accountID: "default",
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

        XCTAssertEqual(Set(viewModel.proxyModels.map(\.id)).count, 2)
        XCTAssertEqual(viewModel.proxyModels.map(\.sourceID), ["provider-a#default", "provider-b#default"])
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

    // MARK: - Route-ready truth

    func test_routeReadiness_requiresRouteReadyAnthropicDaemonCredentialForClaude() {
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
    }

    func test_routeReadiness_mapsOpenAICompatibleCLIsToOpenAIShapeProvidersOnly() {
        let minimax = makeProviderConfiguration(
            providerID: "minimax",
            formatDisplayName: "MiniMax",
            slotStatus: .ready
        )

        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .codex, configurations: [minimax]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .opencode, configurations: [minimax]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .forge, configurations: [minimax]))
        XCTAssertTrue(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .droid, configurations: [minimax]))
        XCTAssertFalse(ConnectionsRouteReadiness.hasRouteReadyProvider(for: .claudeCode, configurations: [minimax]))
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
                ),
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
}

private enum ProxyCatalogTestError: LocalizedError {
    case offline

    var errorDescription: String? { "Gateway offline" }
}

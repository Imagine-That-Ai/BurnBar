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

    // MARK: - Auto-enable gateway on first Connect

    func test_connect_flipsGatewayOnAndUsesLoopbackDefaults() async {
        XCTAssertFalse(settings.gatewayEnabled)

        await viewModel.connect(target: .claudeCode, settings: settings)

        XCTAssertTrue(settings.gatewayEnabled, "Connect must enable the local gateway automatically")
        XCTAssertEqual(settings.gatewayHost, "127.0.0.1", "Connect must fill in loopback host defaults")
        XCTAssertEqual(settings.gatewayPort, 8317, "Connect must fill in the default gateway port")
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

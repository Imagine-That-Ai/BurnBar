import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore

/// Pure-function pin tests for the Agents settings landing page summary
/// strings. The landing has four drill rows; each one shows a one-line
/// summary derived from real state. These tests lock the wording so it
/// doesn't drift without us noticing.
@MainActor
final class AgentsLandingSummaryTests: XCTestCase {

    // MARK: - Accounts summary

    func test_accountsSummary_empty() {
        XCTAssertEqual(
            AgentsSummaries.accounts(providerCount: 0, keyCount: 0),
            "No accounts yet — bring your first API key"
        )
    }

    func test_accountsSummary_singleProviderSingleKey() {
        XCTAssertEqual(
            AgentsSummaries.accounts(providerCount: 1, keyCount: 1),
            "1 provider · 1 key"
        )
    }

    func test_accountsSummary_singleProviderMultipleKeys() {
        XCTAssertEqual(
            AgentsSummaries.accounts(providerCount: 1, keyCount: 4),
            "1 provider · 4 keys"
        )
    }

    func test_accountsSummary_multipleProviders() {
        XCTAssertEqual(
            AgentsSummaries.accounts(providerCount: 3, keyCount: 6),
            "3 providers · 6 keys"
        )
    }

    func test_accountsSummary_pluralBoundaryOnKeys() {
        // 2 providers, 1 key total (degenerate but valid) should keep
        // "key" singular.
        XCTAssertEqual(
            AgentsSummaries.accounts(providerCount: 2, keyCount: 1),
            "2 providers · 1 key"
        )
    }

    // MARK: - CLIs summary

    func test_clisSummary_noneConnected() {
        XCTAssertEqual(
            AgentsSummaries.clis(connected: 0, total: 5),
            "None of 5 CLIs connected yet"
        )
    }

    func test_clisSummary_partiallyConnected() {
        XCTAssertEqual(
            AgentsSummaries.clis(connected: 2, total: 5),
            "2 of 5 CLIs connected"
        )
    }

    func test_clisSummary_allConnected() {
        XCTAssertEqual(
            AgentsSummaries.clis(connected: 5, total: 5),
            "All 5 CLIs connected"
        )
    }

    func test_clisSummary_zeroTotal() {
        // Degenerate case — no CLIs detected on this Mac.
        XCTAssertEqual(
            AgentsSummaries.clis(connected: 0, total: 0),
            "No CLIs detected"
        )
    }

    // MARK: - Runtime summary

    func test_runtimesSummary_noneAutoLaunching() {
        let settings = freshSettingsManager()
        settings.launchHermesWithOpenBurnBar = false
        settings.launchPiAgentsWithOpenBurnBar = false
        settings.openClawGatewayBaseURL = ""

        XCTAssertEqual(
            AgentsSummaries.runtimes(settings: settings),
            "Hermes, Pi, and OpenClaw — none auto-launching"
        )
    }

    func test_runtimesSummary_hermesAuto() {
        let settings = freshSettingsManager()
        settings.launchHermesWithOpenBurnBar = true
        settings.launchPiAgentsWithOpenBurnBar = false
        settings.openClawGatewayBaseURL = ""

        XCTAssertEqual(
            AgentsSummaries.runtimes(settings: settings),
            "Hermes auto"
        )
    }

    func test_runtimesSummary_allConfigured() {
        let settings = freshSettingsManager()
        settings.launchHermesWithOpenBurnBar = true
        settings.launchPiAgentsWithOpenBurnBar = true
        settings.openClawGatewayBaseURL = "http://127.0.0.1:18789"

        XCTAssertEqual(
            AgentsSummaries.runtimes(settings: settings),
            "Hermes auto · Pi auto · OpenClaw set"
        )
    }

    // MARK: - Models summary

    func test_modelsSummary_idle() {
        XCTAssertEqual(
            AgentsSummaries.models(state: .idle, modelCount: 0, readyCount: 0, providerCount: 0),
            "Tap to see every model BurnBar advertises through the local gateway"
        )
    }

    func test_modelsSummary_loading() {
        XCTAssertEqual(
            AgentsSummaries.models(state: .loading, modelCount: 0, readyCount: 0, providerCount: 0),
            "Reading live /v1/models from the local gateway…"
        )
    }

    func test_modelsSummary_error() {
        XCTAssertEqual(
            AgentsSummaries.models(state: .error, modelCount: 0, readyCount: 0, providerCount: 0),
            "Could not read /v1/models — start the gateway to see your catalog"
        )
    }

    func test_modelsSummary_loadedButEmpty() {
        XCTAssertEqual(
            AgentsSummaries.models(state: .loaded, modelCount: 0, readyCount: 0, providerCount: 0),
            "Gateway is up but no models are advertised — add an account first"
        )
    }

    func test_modelsSummary_loadedAllReady() {
        XCTAssertEqual(
            AgentsSummaries.models(state: .loaded, modelCount: 12, readyCount: 12, providerCount: 4),
            "12 models · 12 route ready · 4 providers"
        )
    }

    func test_modelsSummary_loadedPartialReady() {
        XCTAssertEqual(
            AgentsSummaries.models(state: .loaded, modelCount: 8, readyCount: 3, providerCount: 3),
            "8 models · 3 route ready · 3 providers"
        )
    }

    func test_modelsSummary_loadedSingularBoundaries() {
        XCTAssertEqual(
            AgentsSummaries.models(state: .loaded, modelCount: 1, readyCount: 1, providerCount: 1),
            "1 model · 1 route ready · 1 provider"
        )
    }

    // MARK: - Test helpers

    private func freshSettingsManager() -> SettingsManager {
        let suiteName = "AgentsLandingSummaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsManager(defaults: defaults)
    }
}

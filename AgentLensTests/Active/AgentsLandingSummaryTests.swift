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

    // MARK: - Test helpers

    private func freshSettingsManager() -> SettingsManager {
        let suiteName = "AgentsLandingSummaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsManager(defaults: defaults)
    }
}

import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - ProviderLogoView

@MainActor
final class ProviderLogoViewTests: XCTestCase {

    func test_rendersForProviderWithLogoURL() throws {
        // Production switched to bundled-asset logos exclusively (`logoURL`
        // always returns nil now). Render every provider through the shared
        // ProviderLogoView — the test still proves `inspect()` succeeds for
        // each provider, regardless of remote-URL provenance.
        for provider in AgentProvider.allCases {
            let view = ProviderLogoView(provider: provider, size: 32)
            XCTAssertNoThrow(try view.inspect(), "Failed for \(provider.displayName)")
        }
    }

    func test_rendersForProviderWithFallbackEnabled() throws {
        for provider in AgentProvider.allCases {
            let view = ProviderLogoView(provider: provider, size: 32, useFallbackColor: true)
            XCTAssertNoThrow(try view.inspect(), "Failed for \(provider.displayName)")
        }
    }

    func test_respectsCustomSize() throws {
        let view = ProviderLogoView(provider: .aider, size: 48)
        XCTAssertEqual(view.size, 48)
    }

    func test_defaultSize() throws {
        let view = ProviderLogoView(provider: .aider)
        XCTAssertEqual(view.size, 24)
    }

    func test_allProvidersHaveIconNames() {
        for provider in AgentProvider.allCases {
            XCTAssertFalse(provider.iconName.isEmpty, "\(provider.displayName) has empty iconName")
        }
    }

    func test_allProvidersHaveDisplayNames() {
        for provider in AgentProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "Provider has empty displayName")
        }
    }

    func test_piAgentDoesNotReuseHermesLogo() {
        XCTAssertEqual(AgentProvider.piAgent.bundledLogoName, "PiAgentLogo")
        XCTAssertNotEqual(AgentProvider.piAgent.bundledLogoName, AgentProvider.hermes.bundledLogoName)
    }
}

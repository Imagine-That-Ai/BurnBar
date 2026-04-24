import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - ProviderLogoView

@MainActor
final class ProviderLogoViewTests: XCTestCase {

    func test_rendersForProviderWithLogoURL() throws {
        let providersWithURL = AgentProvider.allCases.filter { $0.logoURL != nil }
        XCTAssertFalse(providersWithURL.isEmpty, "At least some providers should have logo URLs")

        for provider in providersWithURL {
            let view = ProviderLogoView(provider: provider, size: 32)
            XCTAssertNoThrow(try view.inspect(), "Failed for \(provider.displayName)")
        }
    }

    func test_rendersForProviderWithoutLogoURL() throws {
        let providersWithoutURL = AgentProvider.allCases.filter { $0.logoURL == nil }
        XCTAssertFalse(providersWithoutURL.isEmpty, "At least some providers should lack logo URLs")

        for provider in providersWithoutURL {
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
}

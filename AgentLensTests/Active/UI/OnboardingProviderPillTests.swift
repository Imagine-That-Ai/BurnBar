import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

private typealias AppAgentProvider = OpenBurnBar.AgentProvider

// MARK: - OnboardingProviderPill

@MainActor
final class OnboardingProviderPillTests: XCTestCase {

    func test_rendersForFactory() throws {
        let view = OnboardingProviderPill(
            provider: AppAgentProvider.factory,
            isSelected: false,
            isDetected: false,
            onTap: {}
        )
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersForClaudeCode() throws {
        let view = OnboardingProviderPill(
            provider: AppAgentProvider.claudeCode,
            isSelected: true,
            isDetected: true,
            onTap: {}
        )
        XCTAssertNoThrow(try view.inspect())
    }

    func test_showsProviderDisplayName() throws {
        let view = OnboardingProviderPill(
            provider: .hermes,
            isSelected: false,
            isDetected: false,
            onTap: {}
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(text: "Hermes"))
    }

    func test_rendersAllProviders() {
        for provider in AppAgentProvider.allCases {
            let view = OnboardingProviderPill(
                provider: provider,
                isSelected: false,
                isDetected: false,
                onTap: {}
            )
            XCTAssertNotNil(view, "Failed to create pill for \(provider.displayName)")
        }
    }
}

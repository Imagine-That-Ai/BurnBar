import XCTest
import SwiftUI
// The AgentProvider / AssistantRuntimeID enums this test drives live in
// OpenBurnBarKernelModels; @testable import OpenBurnBarUI does not re-export them,
// so import the model module directly (WS-B B5).
import OpenBurnBarKernelModels
@testable import OpenBurnBarUI

final class AgentProviderLogoBackdropTests: XCTestCase {

    func test_grokBuildAndCursorAgentNeedDarkModeBackdrop() {
        XCTAssertTrue(
            AgentProvider.xAI.needsMonochromeLogoBackdrop(colorScheme: .dark),
            "Grok Build ships a dark glyph — needs a light disc on Aurora dark surfaces"
        )
        XCTAssertTrue(
            AgentProvider.cursorAgent.needsMonochromeLogoBackdrop(colorScheme: .dark),
            "Cursor Agent ships a dark glyph — needs a light disc on Aurora dark surfaces"
        )
    }

    func test_grokBuildAndCursorAgentSkipBackdropInLightMode() {
        XCTAssertFalse(AgentProvider.xAI.needsMonochromeLogoBackdrop(colorScheme: .light))
        XCTAssertFalse(AgentProvider.cursorAgent.needsMonochromeLogoBackdrop(colorScheme: .light))
    }

    func test_builtInHarnessesMapToBackdropProviders() {
        XCTAssertEqual(AssistantRuntimeID.grok.agentProvider, .xAI)
        XCTAssertEqual(AssistantRuntimeID.cursorAgent.agentProvider, .cursorAgent)
    }
}

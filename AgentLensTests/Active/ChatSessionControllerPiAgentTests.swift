import XCTest
@testable import OpenBurnBar

@MainActor
final class ChatSessionControllerPiAgentTests: XCTestCase {

    func test_piSystemPrompt_appendsInstanceContext_whenInstanceIDIsSet() {
        let composed = ChatSessionController.piSystemPrompt(
            base: "Base prompt body.",
            instanceID: "alpha"
        )

        XCTAssertTrue(composed.contains("Base prompt body."))
        XCTAssertTrue(composed.contains("Pi agent context"))
        XCTAssertTrue(composed.contains("alpha"))
    }

    func test_piSystemPrompt_doesNotAppendInstanceBlock_whenIDIsEmptyOrWhitespace() {
        let basePrompt = "Base prompt body."
        XCTAssertEqual(ChatSessionController.piSystemPrompt(base: basePrompt, instanceID: ""), basePrompt)
        XCTAssertEqual(ChatSessionController.piSystemPrompt(base: basePrompt, instanceID: "   "), basePrompt)
    }

    func test_chatBackendID_piAgent_hasPiAgentProvider() {
        XCTAssertEqual(ChatBackendID.piAgent.agentProvider, .piAgent)
    }

    func test_chatBackendID_piAgent_doesNotRequireCLIAssistantConsent() {
        XCTAssertFalse(ChatBackendID.piAgent.requiresCLIAssistantConsent)
    }

    func test_chatBackendID_allCases_includePiAgent() {
        XCTAssertTrue(ChatBackendID.allCases.contains(.piAgent))
    }
}

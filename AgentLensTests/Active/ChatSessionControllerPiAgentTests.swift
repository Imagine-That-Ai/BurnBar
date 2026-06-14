import XCTest
import OpenBurnBarCore
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

    // MARK: - T-CRY-02: Pi relay sender authentication + replay defense

    /// A request with NO authenticated-sender fields (the pre-T-CRY-02 anonymous
    /// shape) is rejected before any unwrap — `requireAuthenticatedFields`
    /// throws `senderAuthRequired`. This is the fail-closed precondition.
    func test_piSenderAuth_rejectsAnonymousRequest() {
        let anonymous = PiAgentRelaySender(
            publicKeyBase64: "",
            deviceID: "",
            peerNodeID: "",
            counter: -1,
            keyID: ""
        )
        XCTAssertThrowsError(try PiAgentRelaySenderAuthorizer.requireAuthenticatedFields(anonymous)) { error in
            XCTAssertEqual(error as? PiAgentRelaySenderAuthorizationError, .senderAuthRequired)
        }
    }

    /// A well-formed authenticated sender clears the precondition but is still
    /// denied at the pin step by the default deny-all resolver (no trusted Pi
    /// sender is published), so the lane is effectively retired / fail-closed.
    func test_piSenderAuth_wellFormedSenderDeniedByDefaultPinResolver() async {
        let key = Data(repeating: 0x04, count: 65).base64EncodedString()
        let sender = PiAgentRelaySender(
            publicKeyBase64: key,
            deviceID: "device-1",
            peerNodeID: "peer-1",
            counter: 0,
            keyID: "key-1"
        )
        // Precondition passes.
        XCTAssertNoThrow(try PiAgentRelaySenderAuthorizer.requireAuthenticatedFields(sender))

        let authorizer = PiAgentRelaySenderAuthorizer(
            pinResolver: DenyingPiAgentRelaySenderPinResolver(),
            replayCache: HermesRelayReplayCache(
                persistenceURL: nil,
                counterAnchor: InMemoryHermesReplayCounterAnchorBacking()
            )
        )
        do {
            try await authorizer.authorize(sender: sender, uid: "u1", connectionID: "c1", requestID: "r1")
            XCTFail("Default deny-all pin resolver must reject every sender")
        } catch let error as PiAgentRelaySenderAuthorizationError {
            XCTAssertEqual(error, .senderKeyUntrusted)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// With a stub pin resolver that DOES trust the sender, the first request is
    /// admitted and a replay (same counter + request id) is rejected by the
    /// shared replay cache — proving the counter/replay defense is wired.
    func test_piSenderAuth_admitsTrustedSenderAndRejectsReplay() async throws {
        let key = Data(repeating: 0x07, count: 65).base64EncodedString()
        let sender = PiAgentRelaySender(
            publicKeyBase64: key,
            deviceID: "device-9",
            peerNodeID: "peer-9",
            counter: 5,
            keyID: "key-9"
        )
        let authorizer = PiAgentRelaySenderAuthorizer(
            pinResolver: StubPinResolver(pinned: key),
            replayCache: HermesRelayReplayCache(
                persistenceURL: nil,
                counterAnchor: InMemoryHermesReplayCounterAnchorBacking()
            )
        )
        // First open: admitted.
        try await authorizer.authorize(sender: sender, uid: "u1", connectionID: "c1", requestID: "r-fresh")
        // Replay of the same request id: rejected.
        do {
            try await authorizer.authorize(sender: sender, uid: "u1", connectionID: "c1", requestID: "r-fresh")
            XCTFail("Replay of the same request must be rejected")
        } catch let error as PiAgentRelaySenderAuthorizationError {
            XCTAssertEqual(error, .senderReplay)
        }
    }

    private struct StubPinResolver: PiAgentRelaySenderPinResolving {
        let pinned: String
        func pinnedSenderPublicKeyBase64(
            uid: String,
            connectionID: String,
            sender: PiAgentRelaySender
        ) async throws -> String {
            pinned
        }
    }
}

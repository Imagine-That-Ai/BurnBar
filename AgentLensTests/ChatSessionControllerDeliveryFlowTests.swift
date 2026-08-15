import BurnBarCore
import Foundation
import XCTest

@testable import BurnBar

// MARK: - Chat Session Controller Delivery-Flow Tests (M4)

/// M4 directive delivery-flow tests (VAL-ORCH-014/030/037): approval →
/// delivery through the Hermes channel, typed failure with the documented
/// single-user-action retry, honest unsupported degradation with zero side
/// effects, and dismissal that never delivers.
///
/// Splitting the delivery flow out of `ChatSessionControllerOrchestratorTests`
/// keeps both classes under the 500-line type_body_length lint budget while
/// sharing setup helpers via `ChatSessionControllerOrchestratorTestCase`.
/// The deterministic PATH-shim fake CLI (`tools/burnbar-fake-cli.py`) is the
/// required M4 fixture — no live model anywhere.
@MainActor
final class ChatSessionControllerDeliveryFlowTests: ChatSessionControllerOrchestratorTestCase {

    /// A stub channel that records deliveries and returns a scripted outcome.
    private final class StubDeliveryChannel: BurnBarFleetDirectiveChannel, @unchecked Sendable {
        var outcome: BurnBarFleetDeliveryOutcome
        var deliveredDirectives: [BurnBarFleetDirective] = []
        init(outcome: BurnBarFleetDeliveryOutcome) {
            self.outcome = outcome
        }
        var channelName: String { "hermes" }
        func supports(targetAgent: BurnBarFleetAgentID) -> Bool {
            targetAgent == .hermes
        }
        func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome {
            deliveredDirectives.append(directive)
            return outcome
        }
    }

    private func waitForDeliveryState(
        _ controller: ChatSessionController,
        _ expected: ChatDeliveryState,
        timeout: TimeInterval = 15
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lastAssistantMessage(controller)?.deliveryState == expected {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_approvalDeliversThroughHermesChannelAndRecordsDelivered() async throws {
        let snapshot = freshSnapshot()
        let channel = StubDeliveryChannel(outcome: .delivered)
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { target in
                guard target == .hermes else { return nil }
                return channel
            }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        controller.approveProposal(messageID: last.id)
        // Approval is recorded BEFORE delivery: the approved record exists
        // with decidedAt, and the card shows delivering then delivered.
        XCTAssertEqual(directiveRecordCalls, 1)
        let approved = try XCTUnwrap(recordedDirectives.first)
        guard case .approved = approved.state else {
            return XCTFail("expected approved record, got \(approved.state)")
        }
        XCTAssertNotNil(approved.decidedAt)

        await waitForDeliveryState(controller, .delivered)
        XCTAssertEqual(channel.deliveredDirectives.count, 1, "the channel received exactly one delivery")
        XCTAssertEqual(channel.deliveredDirectives.first?.id, "m4-proposal-001")
        // The terminal record is written with deliveryChannel "hermes".
        XCTAssertEqual(directiveRecordCalls, 2, "approved + delivered records")
        let terminal = try XCTUnwrap(recordedDirectives.last)
        XCTAssertEqual(terminal.state, .delivered)
        XCTAssertEqual(terminal.deliveryChannel, "hermes")
        XCTAssertEqual(terminal.decidedAt, approved.decidedAt, "decidedAt preserved across delivery")
    }

    func test_gatewayFailureProducesTypedFailedRecordAndRetry() async throws {
        let snapshot = freshSnapshot()
        let channel = StubDeliveryChannel(outcome: .failed(reason: "hermes gateway unreachable: boom"))
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { target in
                guard target == .hermes else { return nil }
                return channel
            }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        controller.approveProposal(messageID: last.id)
        await waitForDeliveryState(controller, .failed(reason: "hermes gateway unreachable: boom"))
        let failed = try XCTUnwrap(recordedDirectives.last)
        guard case .failed(let reason) = failed.state else {
            return XCTFail("expected failed record, got \(failed.state)")
        }
        XCTAssertTrue(reason.contains("boom"))
        XCTAssertEqual(failed.deliveryChannel, "hermes")

        // The documented single user-action retry: the channel is invoked
        // again only on explicit retry — no silent background loop.
        XCTAssertEqual(channel.deliveredDirectives.count, 1)
        channel.outcome = .delivered
        controller.retryDelivery(messageID: last.id)
        await waitForDeliveryState(controller, .delivered)
        XCTAssertEqual(channel.deliveredDirectives.count, 2, "retry is a single user action")
        let terminal = try XCTUnwrap(recordedDirectives.last)
        XCTAssertEqual(terminal.state, .delivered)
        XCTAssertEqual(terminal.decidedAt, failed.decidedAt, "retry preserves the original decidedAt")
    }

    func test_unsupportedAgentHonestDegradesNoSideEffects() async throws {
        // The canonical proposal targets hermes, but the channel provider
        // resolves no channel for it (e.g. branch B or a missing gateway):
        // the record stays approved, the card shows typed unsupported, and
        // no channel call or terminal record occurs (VAL-ORCH-037).
        let snapshot = freshSnapshot()
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { _ in nil }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        controller.approveProposal(messageID: last.id)
        await waitForDeliveryState(controller, .unsupported(reason: "no documented writable channel for hermes"))
        XCTAssertEqual(directiveRecordCalls, 1, "only the approved record — no terminal record")
        let approved = try XCTUnwrap(recordedDirectives.first)
        guard case .approved = approved.state else {
            return XCTFail("record must stay approved, got \(approved.state)")
        }
        XCTAssertEqual(lastAssistantMessage(controller)?.proposalDecision, .approved)
    }

    func test_dismissedProposalNeverDelivered() async throws {
        let snapshot = freshSnapshot()
        let channel = StubDeliveryChannel(outcome: .delivered)
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "proposal"),
            deliveryChannelProvider: { target in
                guard target == .hermes else { return nil }
                return channel
            }
        )
        controller.startNewChatThread()
        controller.setMode(.orchestrator)
        controller.inputText = "ask hermes for status"
        await controller.send()
        await waitForProposal(controller)
        let last = try XCTUnwrap(lastAssistantMessage(controller))

        controller.dismissProposal(messageID: last.id)
        XCTAssertEqual(directiveRecordCalls, 1)
        let recorded = try XCTUnwrap(recordedDirectives.first)
        guard case .dismissed = recorded.state else {
            return XCTFail("expected dismissed record, got \(recorded.state)")
        }
        XCTAssertTrue(channel.deliveredDirectives.isEmpty, "a dismissed directive is never delivered")
        XCTAssertNil(lastAssistantMessage(controller)?.deliveryState, "no delivery state on a dismissed card")
    }
}

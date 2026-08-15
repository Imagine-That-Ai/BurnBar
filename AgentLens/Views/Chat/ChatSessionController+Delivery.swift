import BurnBarCore
import Foundation
import SwiftUI

// MARK: - Delivery (M4)

extension ChatSessionController {
    /// Starts the delivery flow for an approved directive. The card shows
    /// `delivering` while the channel call is in flight; the terminal outcome
    /// is typed (`delivered`, `failed(reason)`, or `unsupported(reason)`) and
    /// persisted on the message (VAL-ORCH-014/030/037).
    ///
    /// Honesty invariants:
    /// - a malformed acknowledgement fails closed — never `delivered`
    ///   (VAL-ORCH-036);
    /// - a gateway failure produces a typed `failed(reason)` record and a
    ///   documented single user-action retry — no silent background loop
    ///   (VAL-ORCH-030);
    /// - an agent with no documented writable channel honest-degrades to
    ///   `unsupported`: the record stays `approved`, no side effects, and
    ///   the card exposes copy/retry affordances (VAL-ORCH-037);
    /// - Claude's `/tmp/cc-socks/*.sock` messaging socket is NEVER used
    ///   (VAL-ORCH-016).
    func startDelivery(messageID: String, directive: BurnBarFleetDirective) {
        guard let channel = BurnBarFleetDeliveryRunner.channel(
            for: directive.targetAgent,
            provider: deliveryChannelProvider
        ) else {
            // No documented writable channel for this agent: honest
            // unsupported outcome, no side effects (VAL-ORCH-037).
            updateDeliveryState(
                messageID: messageID,
                state: .unsupported(
                    reason: "no documented writable channel for \(directive.targetAgent?.wireValue ?? "any")"
                )
            )
            return
        }

        updateDeliveryState(messageID: messageID, state: .delivering)

        Task { [weak self] in
            guard let self else { return }
            let result = await BurnBarFleetDeliveryRunner.run(
                directive: directive,
                channel: channel,
                record: { [weak self] terminal in
                    guard let self else {
                        throw BurnBarFleetClientError.daemonUnavailable("controller deallocated")
                    }
                    return try self.directiveRecordProvider(terminal, self.fleetService.socketURL)
                }
            )
            await MainActor.run {
                self.applyDeliveryResult(messageID: messageID, result: result)
            }
        }
    }

    /// Applies a delivery run result to the proposal card. The terminal
    /// state is typed and persisted; a failed record write surfaces as a
    /// typed failure on the card (VAL-ORCH-030).
    func applyDeliveryResult(
        messageID: String,
        result: BurnBarFleetDeliveryRunner.RunResult
    ) {
        switch result.outcome {
        case .delivered:
            updateDeliveryState(messageID: messageID, state: .delivered)
        case .failed(let reason):
            updateDeliveryState(messageID: messageID, state: .failed(reason: reason))
        case .unsupported(let reason):
            updateDeliveryState(messageID: messageID, state: .unsupported(reason: reason))
        }
    }

    /// Updates the persisted delivery state on the proposal card. The card
    /// keeps its decision and decision timestamp; only the delivery state
    /// changes (VAL-ORCH-014). A local save failure is surfaced as a visible
    /// card-level error — never a silent state that disappears on relaunch
    /// (scrutiny round 1, no-silent-`try?` on the delivery path).
    func updateDeliveryState(messageID: String, state: ChatDeliveryState) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let old = messages[idx]
        let updated = ChatMessageRecord(
            id: old.id,
            role: old.role,
            content: old.content,
            timestamp: old.timestamp,
            cliUsed: old.cliUsed,
            transcriptPieces: old.transcriptPieces,
            cancelled: old.cancelled,
            proposalJSON: old.proposalJSON,
            proposalDecision: old.proposalDecision,
            proposalDecidedAt: old.proposalDecidedAt,
            deliveryState: state,
            proposalError: old.proposalError
        )
        messages[idx] = updated
        do {
            try dataStore.saveChatMessage(updated, threadID: activeThreadID)
        } catch {
            setProposalError(
                messageID: messageID,
                error: "Delivery state (\(state.rawValue)) could not be saved locally: "
                    + error.localizedDescription
            )
        }
        refreshHistory()
    }

    /// Retries delivery of a failed/unsupported approved directive (the
    /// documented single user-action retry — no silent background loop,
    /// VAL-ORCH-030). The delivery flow restarts from the approved directive;
    /// the terminal record is written by the runner when the new attempt
    /// completes (failed → delivered or failed(newReason)).
    func retryDelivery(messageID: String) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              let proposalJSON = messages[idx].proposalJSON,
              messages[idx].proposalDecision == .approved,
              let deliveryState = messages[idx].deliveryState,
              deliveryState.isRetryable,
              let wire = BurnBarFleetProposalWire.decode(json: proposalJSON) else {
            return
        }
        let directive = BurnBarFleetDirective(
            id: wire.id,
            kind: wire.kind,
            targetAgent: wire.targetAgent,
            payload: wire.payload,
            state: .approved,
            createdAt: messages[idx].timestamp,
            decidedAt: messages[idx].proposalDecidedAt ?? messages[idx].timestamp
        )
        startDelivery(messageID: messageID, directive: directive)
    }
}

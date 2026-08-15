import BurnBarCore
import Foundation
import SwiftUI

// MARK: - Delivery (M4)

extension ChatSessionController {
    private struct RecoveryJournalEntry: Codable {
        let threadID: String
        let message: ChatMessageRecord
    }

    private static let recoveryJournalPrefix = "burnbar.chat.delivery-recovery."

    /// Restores rows whose local save failed before attempting any new
    /// action. The journal is deliberately local and small: it carries the
    /// complete message card so a pending proposal cannot disappear when the
    /// database was read-only or interrupted.
    func restoreJournaledMessages() {
        let defaults = UserDefaults.standard
        let prefix = Self.recoveryJournalPrefix + activeThreadID + "."
        let decoder = JSONDecoder()
        var restored: [ChatMessageRecord] = []
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let data = value as? Data else {
                persistenceError = "A local delivery recovery record was malformed and needs reconciliation."
                continue
            }
            do {
                let entry = try decoder.decode(RecoveryJournalEntry.self, from: data)
                guard entry.threadID == activeThreadID else { continue }
                restored.append(entry.message)
            } catch {
                persistenceError = "A local delivery recovery record could not be decoded: \(error.localizedDescription)"
            }
        }
        for message in restored {
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }
        messages.sort { $0.timestamp < $1.timestamp }
    }

    /// Persists an uncertain card in UserDefaults so a database failure
    /// cannot erase the proposal or its original decision timestamp.
    func persistRecoveryJournal(_ message: ChatMessageRecord) {
        let entry = RecoveryJournalEntry(threadID: activeThreadID, message: message)
        let data: Data
        do {
            data = try JSONEncoder().encode(entry)
        } catch {
            persistenceError = "Delivery recovery state could not be encoded locally."
            return
        }
        let key = Self.recoveryJournalPrefix + activeThreadID + "." + message.id
        UserDefaults.standard.set(data, forKey: key)
    }

    func clearRecoveryJournal(for messageID: String) {
        let key = Self.recoveryJournalPrefix + activeThreadID + "." + messageID
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Loads a recovered approved directive and asks the daemon for the
    /// authoritative record before allowing another delivery attempt. A
    /// terminal daemon record is adopted locally; an approved record becomes
    /// a retryable interrupted failure; an unavailable daemon keeps the card
    /// blocked and visibly typed.
    func reconcileRecoveredMessages() {
        restoreJournaledMessages()
        let messageIDs = messages.compactMap { message -> String? in
            guard message.proposalDecision == .approved,
                  message.deliveryState == .delivering || message.deliveryRecoveryRequired
            else { return nil }
            return message.id
        }
        for messageID in messageIDs {
            reconcileDelivery(messageID: messageID)
        }
    }

    /// Reconciles one uncertain delivery. This is also the explicit action
    /// behind the card's "Reconcile" affordance when the daemon was down
    /// during relaunch.
    func reconcileDelivery(messageID: String) {
        guard let message = messages.first(where: { $0.id == messageID }),
              message.proposalDecision == .approved,
              let proposalJSON = message.proposalJSON,
              let wire = BurnBarFleetProposalWire.decode(json: proposalJSON)
        else { return }

        let directive = BurnBarFleetDirective(
            id: wire.id,
            kind: wire.kind,
            targetAgent: wire.targetAgent,
            payload: wire.payload,
            state: .approved,
            createdAt: message.timestamp,
            decidedAt: message.proposalDecidedAt ?? message.timestamp
        )

        do {
            let authoritative = try directiveRecordProvider(directive, fleetService.socketURL)
            let state: ChatDeliveryState
            let recoveryRequired: Bool
            switch authoritative.state {
            case .delivered:
                state = .delivered
                recoveryRequired = false
            case .failed(let failure):
                state = .failed(reason: failure)
                recoveryRequired = false
            case .approved, .proposed:
                state = .failed(reason: "Delivery was interrupted before its outcome was saved; retry when ready.")
                recoveryRequired = false
            case .dismissed:
                state = .failed(reason: "Daemon reconciliation found the directive dismissed; no delivery was replayed.")
                recoveryRequired = true
            }
            replaceRecoveredMessage(
                messageID: messageID,
                deliveryState: state,
                recoveryRequired: recoveryRequired,
                proposalError: recoveryRequired ? "Daemon reconciliation found a terminal dismissed record; delivery is blocked." : nil
            )
        } catch {
            let messageText = "Delivery recovery could not reconcile with the daemon: \(error.localizedDescription)"
            replaceRecoveredMessage(
                messageID: messageID,
                deliveryState: .failed(reason: messageText),
                recoveryRequired: true,
                proposalError: messageText
            )
        }
    }

    private func replaceRecoveredMessage(
        messageID: String,
        deliveryState: ChatDeliveryState,
        recoveryRequired: Bool,
        proposalError: String?
    ) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let old = messages[index]
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
            deliveryState: deliveryState,
            deliveryRecoveryRequired: recoveryRequired,
            proposalError: proposalError
        )
        messages[index] = updated
        do {
            try saveChatMessageProvider(updated, activeThreadID)
            if !recoveryRequired {
                clearRecoveryJournal(for: messageID)
                persistenceError = nil
            }
        } catch {
            let saveMessage = "Recovered delivery state could not be saved locally: \(error.localizedDescription)"
            let failed = ChatMessageRecord(
                id: updated.id,
                role: updated.role,
                content: updated.content,
                timestamp: updated.timestamp,
                cliUsed: updated.cliUsed,
                transcriptPieces: updated.transcriptPieces,
                cancelled: updated.cancelled,
                proposalJSON: updated.proposalJSON,
                proposalDecision: updated.proposalDecision,
                proposalDecidedAt: updated.proposalDecidedAt,
                deliveryState: updated.deliveryState,
                deliveryRecoveryRequired: true,
                proposalError: saveMessage
            )
            messages[index] = failed
            persistenceError = saveMessage
            persistRecoveryJournal(failed)
        }
        refreshHistory()
    }

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
            deliveryRecoveryRequired: false,
            proposalError: nil
        )
        messages[idx] = updated
        do {
            try saveChatMessageProvider(updated, activeThreadID)
            clearRecoveryJournal(for: messageID)
            persistenceError = nil
        } catch {
            let stateFailure = "Delivery state (\(state.rawValue)) could not be saved locally: "
                + error.localizedDescription
            let message = [old.proposalError, stateFailure]
                .compactMap { $0 }
                .joined(separator: " ")
            let failed = ChatMessageRecord(
                id: updated.id,
                role: updated.role,
                content: updated.content,
                timestamp: updated.timestamp,
                cliUsed: updated.cliUsed,
                transcriptPieces: updated.transcriptPieces,
                cancelled: updated.cancelled,
                proposalJSON: updated.proposalJSON,
                proposalDecision: updated.proposalDecision,
                proposalDecidedAt: updated.proposalDecidedAt,
                deliveryState: updated.deliveryState,
                deliveryRecoveryRequired: true,
                proposalError: message
            )
            messages[idx] = failed
            persistenceError = message
            persistRecoveryJournal(failed)
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
              !messages[idx].deliveryRecoveryRequired,
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

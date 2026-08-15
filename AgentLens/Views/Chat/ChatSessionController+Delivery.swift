import BurnBarCore
import Foundation
import SwiftUI

// MARK: - Delivery (M4)

extension ChatSessionController {
    private enum RecoveryJournalEntryCodingKeys: String, CodingKey {
        case threadID, messageID, decisionAt, message
    }

    private struct RecoveryJournalEntry: Codable {
        let threadID: String
        let messageID: String
        let decisionAt: Date?
        let message: ChatMessageRecord

        init(threadID: String, message: ChatMessageRecord) {
            self.threadID = threadID
            messageID = message.id
            decisionAt = message.proposalDecidedAt
            self.message = message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RecoveryJournalEntryCodingKeys.self)
            threadID = try container.decode(String.self, forKey: .threadID)
            message = try container.decode(ChatMessageRecord.self, forKey: .message)
            messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? message.id
            decisionAt = try container.decodeIfPresent(Date.self, forKey: .decisionAt)
                ?? message.proposalDecidedAt
        }
    }

    private struct RecoveredMessageUpdate {
        let proposalDecision: ChatProposalDecision
        let proposalDecidedAt: Date?
        let deliveryState: ChatDeliveryState?
        let recoveryRequired: Bool
        let proposalError: String?
        let refreshHistory: Bool
    }

    private static let recoveryJournalPrefix = "burnbar.chat.delivery-recovery."

    /// A journal is a recovery candidate, not a newer source of truth. A
    /// database row that already carries a decision must win over a journal
    /// written before that decision, including the crash window between the
    /// database save and journal removal.
    private func journalCanOverlay(
        _ journal: RecoveryJournalEntry,
        currentMessage: ChatMessageRecord
    ) -> Bool {
        guard journal.messageID == journal.message.id else { return false }
        guard currentMessage.proposalDecision != nil else { return true }
        let journalMessage = journal.message
        guard journalMessage.proposalDecision != nil else { return false }
        guard let currentDecisionDate = currentMessage.proposalDecidedAt else { return false }
        guard let journalDecisionDate = journal.decisionAt else { return false }
        if journalDecisionDate > currentDecisionDate {
            return true
        }
        guard journalDecisionDate == currentDecisionDate,
              journalMessage.proposalDecision == currentMessage.proposalDecision,
              currentMessage.proposalDecision == .approved,
              currentMessage.deliveryState == nil
        else {
            return false
        }

        // A same-decision journal can carry delivery recovery detail that
        // failed to reach SQLite. Preserve it while the durable row has no
        // delivery state.
        return journalMessage.deliveryRecoveryRequired
            || journalMessage.deliveryState != nil
    }

    /// Restores rows whose local save failed before attempting any new
    /// action. The journal is deliberately local and small: it carries the
    /// complete message card so a pending proposal cannot disappear when the
    /// database was read-only or interrupted.
    func restoreJournaledMessages() {
        let defaults = UserDefaults.standard
        let prefix = Self.recoveryJournalPrefix + activeThreadID + "."
        let decoder = JSONDecoder()
        var restored: [RecoveryJournalEntry] = []
        for (key, value) in defaults.dictionaryRepresentation()
            where key.hasPrefix(prefix) {
            let keyedMessageID = String(key.dropFirst(prefix.count))
            guard let data = value as? Data else {
                persistenceError = "A local delivery recovery record was malformed and needs reconciliation."
                continue
            }
            do {
                let entry = try decoder.decode(RecoveryJournalEntry.self, from: data)
                guard entry.threadID == activeThreadID,
                      entry.messageID == keyedMessageID
                else {
                    persistenceError = "A local delivery recovery record did not match its message id."
                    continue
                }
                restored.append(entry)
            } catch {
                persistenceError =
                    "A local delivery recovery record could not be decoded: \(error.localizedDescription)"
            }
        }
        for journal in restored {
            let message = journal.message
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                let current = messages[index]
                if journalCanOverlay(journal, currentMessage: current) {
                    messages[index] = message
                } else if current.proposalDecision != nil {
                    // The durable row is newer or at least as authoritative.
                    // Removing this stale entry is safe and prevents the same
                    // crash-window journal from being reconsidered forever.
                    clearRecoveryJournal(for: message.id)
                }
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
    /// terminal daemon record is adopted locally; a dismissed record becomes
    /// terminal locally with no delivery state; an approved record becomes a
    /// retryable interrupted failure; an unavailable daemon keeps the card
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
            reconcileDelivery(messageID: messageID, refreshHistory: false)
        }
        if !messageIDs.isEmpty {
            refreshHistory()
        }
    }

    /// Reconciles one uncertain delivery. This is also the explicit action
    /// behind the card's "Reconcile" affordance when the daemon was down
    /// during relaunch.
    func reconcileDelivery(messageID: String, refreshHistory: Bool = true) {
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
            let update = recoveredMessageUpdate(
                for: authoritative,
                currentMessage: message,
                refreshHistory: refreshHistory,
                nonTerminalRequiresReconciliation: false
            )
            replaceRecoveredMessage(messageID: messageID, update: update)
        } catch {
            let messageText = "Delivery recovery could not reconcile with the daemon: \(error.localizedDescription)"
            let update = RecoveredMessageUpdate(
                proposalDecision: .approved,
                proposalDecidedAt: message.proposalDecidedAt,
                deliveryState: .failed(reason: messageText),
                recoveryRequired: true,
                proposalError: messageText,
                refreshHistory: refreshHistory
            )
            replaceRecoveredMessage(messageID: messageID, update: update)
        }
    }

    private func replaceRecoveredMessage(
        messageID: String,
        update: RecoveredMessageUpdate
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
            proposalDecision: update.proposalDecision,
            proposalDecidedAt: update.proposalDecidedAt,
            deliveryState: update.deliveryState,
            deliveryRecoveryRequired: update.recoveryRequired,
            proposalError: update.proposalError
        )
        messages[index] = updated
        do {
            try saveChatMessageProvider(updated, activeThreadID)
            if !update.recoveryRequired {
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
        if update.refreshHistory {
            self.refreshHistory()
        }
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

        guard updateDeliveryState(messageID: messageID, state: .delivering) else {
            // The local in-flight marker is the idempotency fence. Never call
            // Hermes until that marker has been durably persisted.
            return
        }

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
        if let recorded = result.recorded {
            applyAuthoritativeDeliveryRecord(messageID: messageID, recorded: recorded)
            return
        }
        if result.requiresReconciliation {
            let detail = result.recordError.map { " \($0)" } ?? ""
            let reason = "Delivery outcome is uncertain because the terminal record response was lost; "
                + "reconcile with the daemon before retry.\(detail)"
            _ = updateDeliveryState(
                messageID: messageID,
                state: .failed(reason: reason),
                recoveryRequired: true,
                proposalError: reason
            )
            return
        }
        switch result.outcome {
        case .delivered:
            updateDeliveryState(messageID: messageID, state: .delivered)
        case .failed(let reason):
            updateDeliveryState(messageID: messageID, state: .failed(reason: reason))
        case .unsupported(let reason):
            updateDeliveryState(messageID: messageID, state: .unsupported(reason: reason))
        }
    }

    private func applyAuthoritativeDeliveryRecord(
        messageID: String,
        recorded: BurnBarFleetDirective
    ) {
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        let update = recoveredMessageUpdate(
            for: recorded,
            currentMessage: message,
            refreshHistory: true,
            nonTerminalRequiresReconciliation: true
        )
        replaceRecoveredMessage(messageID: messageID, update: update)
    }

    private func recoveredMessageUpdate(
        for directive: BurnBarFleetDirective,
        currentMessage: ChatMessageRecord,
        refreshHistory: Bool,
        nonTerminalRequiresReconciliation: Bool
    ) -> RecoveredMessageUpdate {
        let decisionAt = directive.decidedAt ?? currentMessage.proposalDecidedAt
        switch directive.state {
        case .delivered:
            return RecoveredMessageUpdate(
                proposalDecision: .approved,
                proposalDecidedAt: decisionAt,
                deliveryState: .delivered,
                recoveryRequired: false,
                proposalError: nil,
                refreshHistory: refreshHistory
            )
        case .failed(let reason):
            return RecoveredMessageUpdate(
                proposalDecision: .approved,
                proposalDecidedAt: decisionAt,
                deliveryState: .failed(reason: reason),
                recoveryRequired: false,
                proposalError: nil,
                refreshHistory: refreshHistory
            )
        case .dismissed:
            // Dismissal is terminal authority. Adopt it locally with no
            // delivery state so the card cannot offer Reconcile or replay
            // delivery on the next relaunch.
            return RecoveredMessageUpdate(
                proposalDecision: .dismissed,
                proposalDecidedAt: decisionAt,
                deliveryState: nil,
                recoveryRequired: false,
                proposalError: nil,
                refreshHistory: refreshHistory
            )
        case .approved, .proposed:
            let reason = nonTerminalRequiresReconciliation
                ? "The daemon returned a non-terminal delivery record; reconcile before retry."
                : "Delivery was interrupted before its outcome was saved; retry when ready."
            return RecoveredMessageUpdate(
                proposalDecision: .approved,
                proposalDecidedAt: decisionAt,
                deliveryState: .failed(reason: reason),
                recoveryRequired: nonTerminalRequiresReconciliation,
                proposalError: reason,
                refreshHistory: refreshHistory
            )
        }
    }

    /// Updates the persisted delivery state on the proposal card. The card
    /// keeps its decision and decision timestamp; only the delivery state
    /// changes (VAL-ORCH-014). A local save failure is surfaced as a visible
    /// card-level error — never a silent state that disappears on relaunch
    /// (scrutiny round 1, no-silent-`try?` on the delivery path).
    @discardableResult
    func updateDeliveryState(
        messageID: String,
        state: ChatDeliveryState,
        recoveryRequired: Bool = false,
        proposalError: String? = nil
    ) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return false }
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
            deliveryRecoveryRequired: recoveryRequired,
            proposalError: proposalError
        )
        messages[idx] = updated
        do {
            try saveChatMessageProvider(updated, activeThreadID)
            if recoveryRequired {
                persistRecoveryJournal(updated)
            } else {
                clearRecoveryJournal(for: messageID)
            }
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
                deliveryState: state == .delivering
                    ? .failed(reason: stateFailure)
                    : updated.deliveryState,
                deliveryRecoveryRequired: true,
                proposalError: message
            )
            messages[idx] = failed
            persistenceError = message
            persistRecoveryJournal(failed)
            refreshHistory()
            return false
        }
        refreshHistory()
        return true
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

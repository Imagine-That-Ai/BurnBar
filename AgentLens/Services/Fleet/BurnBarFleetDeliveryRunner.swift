import OpenBurnBarKernel
import Foundation

// MARK: - Delivery state (persisted on the proposal card)

/// The delivery state of an approved directive proposal (M4). Persisted on
/// the chat message so the card's delivery outcome survives app relaunch.
/// Terminal states are typed: `delivered`, `failed(reason)`, or
/// `unsupported(reason)` — never a fabricated delivery (VAL-ORCH-014/030/037).
enum ChatDeliveryState: Codable, Equatable, Hashable, Sendable {
    case delivering
    case delivered
    case failed(reason: String)
    case unsupported(reason: String)

    /// The typed failure/unsupported reason, when one exists.
    var reason: String? {
        switch self {
        case .delivering, .delivered:
            return nil
        case .failed(let reason), .unsupported(let reason):
            return reason
        }
    }

    /// True when a user retry is offered (failed or unsupported).
    var isRetryable: Bool {
        switch self {
        case .failed, .unsupported:
            return true
        case .delivering, .delivered:
            return false
        }
    }

    /// The persisted wire value (raw string in `chat_messages.deliveryState`).
    /// Failure/unsupported reasons are encoded as `failed:<reason>` /
    /// `unsupported:<reason>` so the typed state round-trips through the
    /// text column.
    var rawValue: String {
        switch self {
        case .delivering:
            return "delivering"
        case .delivered:
            return "delivered"
        case .failed(let reason):
            return "failed:\(reason)"
        case .unsupported(let reason):
            return "unsupported:\(reason)"
        }
    }

    /// Decodes a persisted wire value (nil when malformed — the card then
    /// renders the typed malformed state, never a fabricated outcome).
    init?(rawValue: String) {
        if rawValue == "delivering" {
            self = .delivering
        } else if rawValue == "delivered" {
            self = .delivered
        } else if rawValue.hasPrefix("failed:") {
            let reason = String(rawValue.dropFirst("failed:".count))
            guard !reason.isEmpty else { return nil }
            self = .failed(reason: reason)
        } else if rawValue.hasPrefix("unsupported:") {
            let reason = String(rawValue.dropFirst("unsupported:".count))
            guard !reason.isEmpty else { return nil }
            self = .unsupported(reason: reason)
        } else {
            return nil
        }
    }
}

// MARK: - Delivery runner

/// Runs one directive delivery: resolves the channel for the target agent,
/// writes a durable approved attempt handoff, delivers, and records the
/// terminal outcome via `directive.record` (idempotent upsert). The handoff
/// is written BEFORE the external call starts, so a crash after the side
/// effect but before terminal recording remains blocked behind reconciliation
/// (VAL-ORCH-012).
///
/// Honesty invariants:
/// - a malformed acknowledgement fails closed — never `delivered`
///   (VAL-ORCH-036);
/// - a gateway failure produces a typed `failed(reason)` record and a
///   documented single user-action retry — no silent background loop
///   (VAL-ORCH-030);
/// - an agent with no documented writable channel honest-degrades to
///   `unsupported`: the record stays `approved`, no side effects, and the
///   card exposes copy/retry affordances (VAL-ORCH-037);
/// - Claude's `/tmp/cc-socks/*.sock` messaging socket is NEVER used
///   (VAL-ORCH-016).
enum BurnBarFleetDeliveryRunner {
    private enum HandoffResult {
        case ready(BurnBarFleetDirective)
        case failed(RunResult)
    }

    /// The outcome of a delivery run, including the record write result.
    struct RunResult: Equatable, Sendable {
        let outcome: BurnBarFleetDeliveryOutcome
        /// The directive record after the terminal write (nil when the
        /// outcome is `unsupported` — the record stays `approved`).
        let recorded: BurnBarFleetDirective?
        /// Non-nil when the terminal record write itself failed.
        let recordError: String?
        /// True when the external channel may have succeeded but the
        /// terminal directive record response was lost. The caller must
        /// reconcile with the daemon before permitting another channel call.
        let requiresReconciliation: Bool
    }

    /// Resolves the channel for a target agent. Returns nil when the agent
    /// has no documented writable channel (typed unsupported outcome).
    static func channel(
        for targetAgent: BurnBarFleetAgentID?,
        provider: (BurnBarFleetAgentID?) -> BurnBarFleetDirectiveChannel?
    ) -> BurnBarFleetDirectiveChannel? {
        guard let targetAgent else { return nil }
        guard let channel = provider(targetAgent), channel.supports(targetAgent: targetAgent) else {
            return nil
        }
        return channel
    }

    /// Delivers an approved directive and records the terminal outcome.
    /// Never throws: every failure is a typed outcome.
    static func run(
        directive: BurnBarFleetDirective,
        channel: BurnBarFleetDirectiveChannel,
        prepare: ((BurnBarFleetDirective) throws -> BurnBarFleetDirective)? = nil,
        record: (BurnBarFleetDirective) throws -> BurnBarFleetDirective
    ) async -> RunResult {
        switch prepareHandoff(for: directive, channel: channel, prepare: prepare) {
        case .failed(let result):
            return result
        case .ready(let prepared):
            return await deliverPrepared(
                prepared,
                channel: channel,
                record: record
            )
        }
    }

    private static func prepareHandoff(
        for directive: BurnBarFleetDirective,
        channel: BurnBarFleetDirectiveChannel,
        prepare: ((BurnBarFleetDirective) throws -> BurnBarFleetDirective)?
    ) -> HandoffResult {
        let attemptID = directive.deliveryAttemptID ?? UUID().uuidString
        let handoff = BurnBarFleetDirective(
            id: directive.id,
            kind: directive.kind,
            targetAgent: directive.targetAgent,
            payload: directive.payload,
            state: .approved,
            createdAt: directive.createdAt,
            decidedAt: directive.decidedAt,
            deliveryChannel: channel.channelName,
            deliveryAttemptID: attemptID
        )
        do {
            let prepared = try prepare?(handoff) ?? handoff
            return validateHandoff(prepared, attemptID: attemptID)
        } catch {
            return handoffFailure(
                outcome: .failed(reason: "delivery attempt handoff failed: \(error.localizedDescription)"),
                recordError: error.localizedDescription,
                requiresReconciliation: false
            )
        }
    }

    private static func validateHandoff(
        _ prepared: BurnBarFleetDirective,
        attemptID: String
    ) -> HandoffResult {
        guard prepared.deliveryAttemptID == attemptID else {
            return handoffFailure(
                outcome: .failed(reason: "delivery attempt handoff is not authoritative; reconcile before retry"),
                requiresReconciliation: true
            )
        }
        switch prepared.state {
        case .approved:
            return .ready(prepared)
        case .delivered, .failed, .dismissed:
            return handoffFailure(
                outcome: outcome(from: prepared.state),
                recorded: prepared,
                requiresReconciliation: false
            )
        case .proposed:
            return handoffFailure(
                outcome: .failed(reason: "delivery attempt handoff remained proposed"),
                recorded: prepared,
                requiresReconciliation: true
            )
        }
    }

    private static func handoffFailure(
        outcome: BurnBarFleetDeliveryOutcome,
        recorded: BurnBarFleetDirective? = nil,
        recordError: String? = nil,
        requiresReconciliation: Bool
    ) -> HandoffResult {
        .failed(
            RunResult(
                outcome: outcome,
                recorded: recorded,
                recordError: recordError,
                requiresReconciliation: requiresReconciliation
            )
        )
    }

    private static func deliverPrepared(
        _ prepared: BurnBarFleetDirective,
        channel: BurnBarFleetDirectiveChannel,
        record: (BurnBarFleetDirective) throws -> BurnBarFleetDirective
    ) async -> RunResult {
        let outcome = await channel.deliver(prepared)
        switch outcome {
        case .delivered:
            return recordTerminal(
                directive: prepared,
                state: .delivered,
                channelName: channel.channelName,
                record: record
            )
        case .failed(let reason):
            return recordTerminal(
                directive: prepared,
                state: .failed(reason: reason),
                channelName: channel.channelName,
                record: record
            )
        case .unsupported(let reason):
            // The record stays `approved`; the card shows the typed
            // unsupported state with copy/retry affordances (VAL-ORCH-037).
            return RunResult(
                outcome: outcome,
                recorded: nil,
                recordError: nil,
                requiresReconciliation: false
            )
        }
    }

    private static func recordTerminal(
        directive: BurnBarFleetDirective,
        state: BurnBarFleetDirectiveState,
        channelName: String,
        record: (BurnBarFleetDirective) throws -> BurnBarFleetDirective
    ) -> RunResult {
        let terminal = BurnBarFleetDirective(
            id: directive.id,
            kind: directive.kind,
            targetAgent: directive.targetAgent,
            payload: directive.payload,
            state: state,
            createdAt: directive.createdAt,
            decidedAt: directive.decidedAt,
            deliveryChannel: channelName,
            deliveryAttemptID: directive.deliveryAttemptID
        )
        do {
            let recorded = try record(terminal)
            return RunResult(
                // The daemon response is authoritative: another client may
                // have won a terminal race while this channel call was in
                // flight.
                outcome: outcome(from: recorded.state),
                recorded: recorded,
                recordError: nil,
                requiresReconciliation: false
            )
        } catch {
            return RunResult(
                outcome: .failed(reason: "delivery record failed: \(error.localizedDescription)"),
                recorded: nil,
                recordError: error.localizedDescription,
                // If the channel succeeded, a lost terminal record response
                // is uncertain. A definite channel failure remains retryable.
                requiresReconciliation: state == .delivered
            )
        }
    }

    private static func outcome(from state: BurnBarFleetDirectiveState) -> BurnBarFleetDeliveryOutcome {
        switch state {
        case .delivered:
            return .delivered
        case .failed(let reason):
            return .failed(reason: reason)
        case .proposed, .approved, .dismissed:
            return .failed(reason: "unexpected terminal state")
        }
    }
}

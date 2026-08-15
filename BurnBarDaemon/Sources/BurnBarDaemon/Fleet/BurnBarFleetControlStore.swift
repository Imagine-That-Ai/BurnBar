import BurnBarCore
import Foundation

/// M4 daemon-orchestrator-state: typed errors for orchestrator designation
/// and directive-record mutations. Validation errors are surfaced as typed
/// `-32603` RPC errors (the canonical validation home for `directive.record`
/// payloads is here — ORCH-029).
public enum BurnBarFleetControlError: Error, LocalizedError, Equatable, Sendable {
    /// `agent` designation with an id outside the declared ten-ID roster.
    case invalidDesignationAgent(String)
    /// A directive record with an empty (whitespace-only) id.
    case emptyDirectiveID
    /// A directive record with an empty (whitespace-only) payload.
    case emptyDirectivePayload
    /// A directive record whose `targetAgent` is outside the declared
    /// ten-ID roster.
    case invalidDirectiveTargetAgent(String)
    /// A directive record in the `failed(reason:)` state whose reason is
    /// empty (whitespace-only).
    case emptyDirectiveStateReason
    /// The fleet store is unavailable (not open) and the mutation cannot be
    /// persisted — the mutation is rejected rather than silently lost.
    case storeUnavailable(String)
    /// The persisted state payload could not be encoded.
    case payloadEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDesignationAgent(let id):
            return "Cannot designate agent '\(id)': it is not in the declared fleet roster."
        case .emptyDirectiveID:
            return "Directive id must be a non-empty string."
        case .emptyDirectivePayload:
            return "Directive payload must be a non-empty string."
        case .invalidDirectiveTargetAgent(let id):
            return "Directive target agent '\(id)' is not in the declared fleet roster."
        case .emptyDirectiveStateReason:
            return "Directive state failed(reason:) requires a non-empty reason."
        case .storeUnavailable(let detail):
            return "Fleet store is unavailable: \(detail)"
        case .payloadEncodingFailed:
            return "Fleet control state could not be encoded."
        }
    }
}

/// Daemon-owned orchestrator state + directive records (M4).
///
/// Owns:
/// - the orchestrator **designation** (`none | burnBarManaged | agent(id,
///   sessionRef?)`), persisted in `orchestrator_state` (single row, `id = 1`);
/// - the **directive history**, persisted in `fleet_directives` (keyed by the
///   unique `directive_id`).
///
/// Documented semantics (validators depend on them):
/// - **Fresh-daemon default:** designation `none`, `setAt` null, pending 0
///   (VAL-RPC-008).
/// - **Set semantics:** every accepted set stamps `setAt = now` (daemon-owned
///   timestamp — a client-supplied `setAt` is ignored). Setting while set
///   overwrites the designation and advances `setAt` (ORCH-017); exactly one
///   state row ever exists.
/// - **Idempotent clear:** setting `none` while `none` is set is a typed
///   success no-op — no phantom `setAt`, no state row is created (ORCH-018).
/// - **Declared non-running agent (ORCH-019, outcome A):** designating any
///   *declared roster* agent is accepted even when that agent is not running.
///   Designation is control-plane intent, not a liveness claim: the snapshot
///   reports the agent's real status independently, and the board renders an
///   honest "designated but not detected" state. Only ids outside the
///   declared ten-ID roster are rejected.
/// - **Directive record idempotency (VAL-RPC-015):** re-recording an existing
///   `directive_id` updates the record in place — a retry never creates a
///   duplicate row, and the response always describes the single persisted
///   record.
/// - **Monotonic terminal authority:** `dismissed` and `delivered` records are
///   immutable against every later candidate, including stale terminal
///   callbacks. A `failed` record is terminal for ordinary candidates; the
///   only retry transition it accepts is an explicit `failed → delivered`
///   completion (a repeated `failed` outcome may refresh its failure detail).
/// - **`pendingDirectives` definition (ORCH-038):** the count of directive
///   records in the non-terminal states `proposed` or `approved`. Terminal
///   records (`dismissed`, `delivered`, `failed(reason)`) never count. The
///   same definition drives `orchestrator.get`, the snapshot's
///   `orchestrator.pendingDirectives`, and the well-known file (which is the
///   snapshot payload).
/// - **Restart persistence (ORCH-004/015/039):** designation and all
///   directive records (including terminal `delivered`/`failed(reason)`
///   outcomes with their reasons and channels) survive daemon restarts; a
///   restart never replays a delivered directive and never loses a terminal
///   failure reason.
/// - **Serialized single-state integrity (ORCH-020):** this actor is the
///   single writer of control state — concurrent sets serialize, each
///   accepted payload is stored whole (never torn/merged), and the final
///   state equals exactly one accepted payload.
/// - **Read purity (VAL-CROSS-009):** `currentState()` and the snapshot
///   embed path only read; they never mutate control state.
///
/// Persistence modes: with a wired `BurnBarFleetStore`, mutations persist to
/// fleet.sqlite and reads come from the store. Without a store (unit-test
/// mode), state is held in memory. A wired-but-closed store rejects
/// mutations typed (`storeUnavailable`) — a mutation that cannot be
/// persisted is never silently accepted.
public actor BurnBarFleetControlStore {
    private let store: BurnBarFleetStore?
    private var inMemoryState: BurnBarOrchestratorState?
    private var inMemoryRecords: [BurnBarFleetDirective] = []

    public init(store: BurnBarFleetStore? = nil) {
        self.store = store
    }

    // MARK: - Loading

    /// Loads the persisted designation and directive history from the store
    /// (used at daemon start so a restarted daemon serves the prior
    /// designation from the first read; `currentState()` also lazy-loads).
    public func loadPersistedState() {
        guard let store, store.isOpen else {
            inMemoryState = nil
            return
        }
        inMemoryState = try? store.orchestratorStatePayload().flatMap { payload in
            guard let data = payload.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(BurnBarOrchestratorState.self, from: data)
        }
    }

    /// The current orchestrator state: the persisted (or default) designation
    /// plus the live `pendingDirectives` count. Never mutates control state.
    public func currentState() -> BurnBarOrchestratorState {
        let state = loadIfNeeded()
        let pending = (try? pendingDirectivesCount()) ?? state.pendingDirectives
        return BurnBarOrchestratorState(
            designation: state.designation,
            setAt: state.setAt,
            pendingDirectives: pending
        )
    }

    /// Sets the orchestrator designation with the documented semantics.
    /// Throws `BurnBarFleetControlError` for invalid payloads (typed
    /// rejection — the stored state is unchanged) and for an unavailable
    /// store.
    @discardableResult
    public func setOrchestratorState(_ requested: BurnBarOrchestratorState) throws -> BurnBarOrchestratorState {
        try Self.validateDesignation(requested.designation)
        let current = loadIfNeeded()

        // Idempotent clear: none → none is a typed success no-op (ORCH-018).
        // No phantom setAt is stamped and no state row is created. The
        // response is the UNCHANGED current state — including a retained
        // clear timestamp when the state was previously cleared (or restored
        // after restart) — so the set response and the immediately following
        // get always agree (set/get coherence; scrutiny round 1).
        if current.designation == .none, requested.designation == .none {
            let pending = (try? pendingDirectivesCount()) ?? current.pendingDirectives
            return BurnBarOrchestratorState(
                designation: .none,
                setAt: current.setAt,
                pendingDirectives: pending
            )
        }

        // Any real set overwrites the designation and stamps the daemon-owned
        // setAt (ORCH-001..003, 017).
        let updated = BurnBarOrchestratorState(
            designation: requested.designation,
            setAt: Date()
        )
        if let store {
            guard store.isOpen else {
                throw BurnBarFleetControlError.storeUnavailable("fleet.sqlite is not open")
            }
            try store.setOrchestratorState(payload: try Self.encodeState(updated))
            inMemoryState = updated
        } else {
            inMemoryState = updated
        }
        let pending = (try? pendingDirectivesCount()) ?? 0
        return BurnBarOrchestratorState(
            designation: updated.designation,
            setAt: updated.setAt,
            pendingDirectives: pending
        )
    }

    /// Records a directive candidate (upsert by `directive_id`). Throws typed
    /// validation errors for invalid payloads (ORCH-029) — no record is
    /// created on rejection. Terminal-authority rules may return an existing
    /// authoritative record instead of accepting the candidate.
    @discardableResult
    public func recordDirective(_ directive: BurnBarFleetDirective) throws -> BurnBarFleetDirective {
        try Self.validateDirective(directive)
        // Recovery reads use the same idempotent record surface with an
        // `approved` candidate. The daemon record is authoritative for
        // terminal outcomes: stale callbacks must not overwrite a dismissal
        // or a completed delivery, and an ordinary candidate must not
        // downgrade a failed delivery. The explicit failed → delivered
        // retry is the one exception.
        if let existing = try existingDirective(id: directive.id),
           Self.shouldPreserveExisting(existing.state, for: directive.state) {
            return existing
        }
        if let store {
            guard store.isOpen else {
                throw BurnBarFleetControlError.storeUnavailable("fleet.sqlite is not open")
            }
            try store.upsertDirective(directive)
            mirror(directive)
        } else {
            upsertInMemory(directive)
        }
        return directive
    }

    // MARK: - Validation

    /// Designation validation: `agent` ids must be in the declared ten-ID
    /// roster. `none`/`burnBarManaged` need no validation. Whether the
    /// designated agent is currently running is deliberately NOT validated
    /// (ORCH-019 outcome A).
    static func validateDesignation(_ designation: BurnBarOrchestratorDesignation) throws {
        if case .agent(let id, _) = designation {
            guard BurnBarFleetAgentID(wireValue: id.wireValue) != nil else {
                throw BurnBarFleetControlError.invalidDesignationAgent(id.wireValue)
            }
        }
    }

    /// Directive payload validation (the canonical home of ORCH-029): a
    /// non-empty id, a non-empty payload, a `targetAgent` in the declared
    /// roster when present, and a well-formed directive state — a
    /// `failed(reason:)` state must carry a non-empty reason (the contract
    /// invariant; an empty reason is rejected typed). The state invariants
    /// are validated here — BEFORE the persistence path is chosen — so
    /// validation never depends on the backing store: the store-less/in-
    /// memory mode rejects exactly the same invalid records as the wired
    /// mode (scrutiny round 1).
    static func validateDirective(_ directive: BurnBarFleetDirective) throws {
        guard !directive.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BurnBarFleetControlError.emptyDirectiveID
        }
        guard !directive.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BurnBarFleetControlError.emptyDirectivePayload
        }
        if case .failed(let reason) = directive.state {
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BurnBarFleetControlError.emptyDirectiveStateReason
            }
        }
        if let targetAgent = directive.targetAgent {
            guard BurnBarFleetAgentID(wireValue: targetAgent.wireValue) != nil else {
                throw BurnBarFleetControlError.invalidDirectiveTargetAgent(targetAgent.wireValue)
            }
        }
    }

    // MARK: - Internal

    private func loadIfNeeded() -> BurnBarOrchestratorState {
        if let inMemoryState {
            return inMemoryState
        }
        if let store, store.isOpen {
            loadPersistedState()
            if let inMemoryState {
                return inMemoryState
            }
        }
        return BurnBarOrchestratorState(designation: .none)
    }

    private func pendingDirectivesCount() throws -> Int {
        if let store, store.isOpen {
            return try store.directiveRecords().filter { Self.isPending($0.state) }.count
        }
        return inMemoryRecords.filter { Self.isPending($0.state) }.count
    }

    private func existingDirective(id: String) throws -> BurnBarFleetDirective? {
        if let store, store.isOpen {
            return try store.directiveRecord(id: id)
        }
        return inMemoryRecords.first { $0.id == id }
    }

    /// The documented `pendingDirectives` definition (ORCH-038): non-terminal
    /// records only — `proposed` or `approved`.
    static func isPending(_ state: BurnBarFleetDirectiveState) -> Bool {
        switch state {
        case .proposed, .approved:
            return true
        case .dismissed, .delivered, .failed:
            return false
        }
    }

    /// Returns whether an existing directive record has authority over an
    /// incoming candidate. Dismissed and delivered are immutable terminal
    /// outcomes. Failed remains terminal for all ordinary candidates, while
    /// an explicit delivered callback is the supported user-retry transition.
    private static func shouldPreserveExisting(
        _ existing: BurnBarFleetDirectiveState,
        for candidate: BurnBarFleetDirectiveState
    ) -> Bool {
        switch existing {
        case .dismissed, .delivered:
            return true
        case .failed:
            switch candidate {
            case .delivered, .failed:
                return false
            case .proposed, .approved, .dismissed:
                return true
            }
        case .proposed, .approved:
            return false
        }
    }

    private func upsertInMemory(_ directive: BurnBarFleetDirective) {
        if let index = inMemoryRecords.firstIndex(where: { $0.id == directive.id }) {
            inMemoryRecords[index] = directive
        } else {
            inMemoryRecords.append(directive)
        }
    }

    private func mirror(_ directive: BurnBarFleetDirective) {
        // Mirror for coherence when the store is temporarily unavailable;
        // the store remains the source of truth while open.
        upsertInMemory(directive)
    }

    private static func encodeState(_ state: BurnBarOrchestratorState) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw BurnBarFleetControlError.payloadEncodingFailed
        }
        return payload
    }
}

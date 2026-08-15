import BurnBarCore
import Foundation

/// The fleet service owns the snapshot cadence ticker and the latest completed
/// snapshot. It is the daemon-side control point for the fleet projection:
/// probes run on the ticker, the builder merges their results, and RPC reads
/// serve the latest completed snapshot.
///
/// Pre-first-tick behavior is typed: until the first tick completes, reads
/// return `notReady` — never a fabricated empty snapshot presented as probed
/// truth. The first tick runs immediately at start (no initial cadence wait),
/// so the not-ready window is one build duration.
public actor BurnBarFleetService {
    /// Typed pre-first-tick read state (documented in BURNBAR_FLEET_SIGNALS.md).
    public enum ReadState: Sendable {
        case notReady
        case ready(BurnBarFleetSnapshot)
    }

    /// The tick interval and the snapshot's reported `cadenceSeconds` both come
    /// from the builder — a single source of truth so the reported cadence
    /// always matches the observed tick interval.
    public let builder: BurnBarFleetSnapshotBuilder

    /// Daemon-owned persistence (fleet.sqlite + well-known file). Optional so
    /// tests can run the service without persistence; the daemon always wires
    /// one. When present, every completed tick persists the snapshot and the
    /// served snapshot carries the post-persist `persistenceHealth`.
    public let persister: BurnBarFleetPersister?

    /// M4 daemon-owned orchestrator state + directive store. Optional so
    /// tests can run the service without control state; the daemon always
    /// wires one. Every completed build embeds the live designation and
    /// `pendingDirectives` count into the snapshot's `orchestrator` block —
    /// the snapshot, `orchestrator.get`, and the well-known file (which is
    /// the snapshot payload) all derive from this single source.
    public let controlStore: BurnBarFleetControlStore?

    public var cadenceSeconds: Int { builder.cadenceSeconds }

    private var latestSnapshot: BurnBarFleetSnapshot?
    private var tickTask: Task<Void, Never>?
    private var isRunning = false

    public init(
        builder: BurnBarFleetSnapshotBuilder,
        persister: BurnBarFleetPersister? = nil,
        controlStore: BurnBarFleetControlStore? = nil
    ) {
        self.builder = builder
        self.persister = persister
        self.controlStore = controlStore
    }

    /// Starts the cadence ticker. The first tick runs immediately; subsequent
    /// ticks wait `cadenceSeconds` between builds. Idempotent.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        // Seed the transition baseline from the store so events after a
        // daemon restart compare against the last persisted snapshot.
        persister?.loadLastPersistedSnapshot()
        // Load the persisted designation/directive history so a restarted
        // daemon serves the prior designation from the first read.
        await controlStore?.loadPersistedState()
        tickTask = Task { [weak self] in
            await self?.runTicker()
        }
    }

    /// Stops the ticker. The latest completed snapshot is retained so reads
    /// after stop still serve the last probed truth.
    public func stop() {
        isRunning = false
        tickTask?.cancel()
        tickTask = nil
    }

    /// The latest completed snapshot, or the typed not-ready state before the
    /// first tick completes.
    public func readLatestSnapshot() -> ReadState {
        if let latestSnapshot {
            return .ready(latestSnapshot)
        }
        return .notReady
    }

    // MARK: - Orchestrator control state (M4)

    /// The live orchestrator state (designation + pendingDirectives) served
    /// by `daemon.fleet.orchestrator.get`. Read-only — never mutates control
    /// state (VAL-CROSS-009).
    public func orchestratorState() async -> BurnBarOrchestratorState {
        await controlStore?.currentState() ?? BurnBarOrchestratorState(designation: .none)
    }

    /// Sets the orchestrator designation with the documented overwrite and
    /// idempotent-clear semantics. Throws typed validation errors for invalid
    /// payloads (VAL-RPC-009). Serialized by the control store actor — the
    /// single writer of control state (ORCH-020).
    public func setOrchestratorState(_ state: BurnBarOrchestratorState) async throws -> BurnBarOrchestratorState {
        guard let controlStore else {
            throw BurnBarFleetControlError.storeUnavailable("control store is not wired")
        }
        return try await controlStore.setOrchestratorState(state)
    }

    /// Records an approved directive (idempotent upsert by directive id;
    /// ORCH-029 validation). Serialized by the control store actor.
    public func recordDirective(_ directive: BurnBarFleetDirective) async throws -> BurnBarFleetDirective {
        guard let controlStore else {
            throw BurnBarFleetControlError.storeUnavailable("control store is not wired")
        }
        return try await controlStore.recordDirective(directive)
    }

    /// Builds one snapshot immediately (used by the ticker and by tests).
    /// The live orchestrator state (designation + pendingDirectives) is
    /// embedded from the control store (or the default `none` state).
    /// When a persister is wired, the snapshot is persisted and the returned
    /// snapshot carries the post-persist `persistenceHealth`.
    @discardableResult
    public func buildOnce() async throws -> BurnBarFleetSnapshot {
        let orchestratorState = await controlStore?.currentState()
            ?? BurnBarOrchestratorState(designation: .none)
        let snapshot = try await builder.build(
            orchestrator: orchestratorState,
            persistenceHealth: persister?.persistenceHealth() ?? .ok
        )
        if let persister {
            let persisted = persister.persist(snapshot: snapshot)
            latestSnapshot = persisted
            return persisted
        }
        latestSnapshot = snapshot
        return snapshot
    }

    private func runTicker() async {
        while !Task.isCancelled {
            do {
                _ = try await buildOnce()
            } catch {
                // A failed build never fabricates a snapshot: the previous
                // completed snapshot (if any) keeps serving.
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(builder.cadenceSeconds) * 1_000_000_000)
            } catch {
                return
            }
        }
    }
}

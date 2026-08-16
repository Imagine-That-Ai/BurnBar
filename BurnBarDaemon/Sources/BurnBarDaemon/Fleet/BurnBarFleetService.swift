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
        /// The most recent tick failed validation. The previous snapshot is
        /// retained for diagnostics only and is not silently served as fresh
        /// truth by the RPC layer.
        case degraded(reason: String, previousSnapshot: BurnBarFleetSnapshot?)
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

    private let logger: BurnBarDaemonLogger
    private let startInitializationHook: (@Sendable () async -> Void)?
    private var latestSnapshot: BurnBarFleetSnapshot?
    private var currentTickDegradation: String?
    private var tickTask: Task<Void, Never>?
    private var startingTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var isRunning = false
    private var completedTickCount = 0

    public init(
        builder: BurnBarFleetSnapshotBuilder,
        persister: BurnBarFleetPersister? = nil,
        controlStore: BurnBarFleetControlStore? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "fleet")
    ) {
        self.builder = builder
        self.persister = persister
        self.controlStore = controlStore
        self.logger = logger
        self.startInitializationHook = nil
    }

    /// Internal initialization seam used to hold startup at the same
    /// suspension point as a store load in lifecycle regression tests.
    init(
        builder: BurnBarFleetSnapshotBuilder,
        persister: BurnBarFleetPersister? = nil,
        controlStore: BurnBarFleetControlStore? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "fleet"),
        startInitializationHook: (@Sendable () async -> Void)?
    ) {
        self.builder = builder
        self.persister = persister
        self.controlStore = controlStore
        self.logger = logger
        self.startInitializationHook = startInitializationHook
    }

    /// Starts the cadence ticker. The first tick runs immediately; subsequent
    /// ticks wait `cadenceSeconds` between builds. Idempotent.
    public func start() async {
        if let stoppingTask {
            await stoppingTask.value
        }

        if isRunning {
            return
        }
        if let startingTask {
            await startingTask.value
            return
        }

        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.initializeStart(generation: generation)
        }
        startingTask = task
        await task.value
        if lifecycleGeneration == generation {
            startingTask = nil
        }
    }

    /// Stops the ticker. The latest completed snapshot is retained so reads
    /// after stop still serve the last probed truth.
    public func stop() async {
        if let stoppingTask {
            await stoppingTask.value
            return
        }

        lifecycleGeneration &+= 1
        isRunning = false
        let startingTask = self.startingTask
        self.startingTask = nil
        startingTask?.cancel()
        let task = tickTask
        tickTask = nil
        task?.cancel()

        let stopTask = Task {
            await startingTask?.value
            await task?.value
        }
        stoppingTask = stopTask
        await stopTask.value
        stoppingTask = nil
    }

    private func initializeStart(generation: UInt64) async {
        // Seed the transition baseline from the store so events after a
        // daemon restart compare against the last persisted snapshot.
        persister?.loadLastPersistedSnapshot()
        await startInitializationHook?()
        // Load the persisted designation/directive history so a restarted
        // daemon serves the prior designation from the first read.
        await controlStore?.loadPersistedState()

        // `stop()` can re-enter this actor while either load is suspended.
        // Never publish a ticker for an invalidated generation.
        guard lifecycleGeneration == generation, !Task.isCancelled, !isRunning else {
            return
        }
        isRunning = true
        tickTask = Task { [weak self] in
            await self?.runTicker()
        }
    }

    /// The latest completed snapshot, or the typed not-ready state before the
    /// first tick completes.
    public func readLatestSnapshot() -> ReadState {
        if let currentTickDegradation {
            return .degraded(reason: currentTickDegradation, previousSnapshot: latestSnapshot)
        }
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
        (try? await orchestratorStateChecked()) ?? BurnBarOrchestratorState(designation: .none)
    }

    public func orchestratorStateChecked() async throws -> BurnBarOrchestratorState {
        persister?.prepareForBuild()
        return try await controlStore?.currentStateChecked() ?? BurnBarOrchestratorState(designation: .none)
    }

    /// Sets the orchestrator designation with the documented overwrite and
    /// idempotent-clear semantics. Throws typed validation errors for invalid
    /// payloads (VAL-RPC-009). Serialized by the control store actor — the
    /// single writer of control state (ORCH-020).
    public func setOrchestratorState(_ state: BurnBarOrchestratorState) async throws -> BurnBarOrchestratorState {
        guard let controlStore else {
            throw BurnBarFleetControlError.storeUnavailable("control store is not wired")
        }
        persister?.prepareForBuild()
        return try await controlStore.setOrchestratorState(state)
    }

    /// Records an approved directive (idempotent upsert by directive id;
    /// ORCH-029 validation). Serialized by the control store actor.
    public func recordDirective(_ directive: BurnBarFleetDirective) async throws -> BurnBarFleetDirective {
        guard let controlStore else {
            throw BurnBarFleetControlError.storeUnavailable("control store is not wired")
        }
        persister?.prepareForBuild()
        return try await controlStore.recordDirective(directive)
    }

    /// Builds one snapshot immediately (used by the ticker and by tests).
    /// The live orchestrator state (designation + pendingDirectives) is
    /// embedded from the control store (or the default `none` state).
    /// When a persister is wired, the snapshot is persisted and the returned
    /// snapshot carries the post-persist `persistenceHealth`.
    @discardableResult
    public func buildOnce() async throws -> BurnBarFleetSnapshot {
        // Reconcile an externally deleted/replaced fleet.sqlite before
        // reading control state. A rebuild intentionally clears the
        // daemon-owned designation/directive history, so the control store
        // must observe that boundary before embedding its state.
        persister?.prepareForBuild()
        let orchestratorState = try await controlStore?.currentStateChecked()
            ?? BurnBarOrchestratorState(designation: .none)
        let snapshot = try await builder.build(
            orchestrator: orchestratorState,
            persistenceHealth: persister?.persistenceHealth() ?? .ok
        )
        let completedSnapshot = persister?.persist(snapshot: snapshot) ?? snapshot
        completedTickCount += 1
        logProbeDegradations(in: completedSnapshot)
        latestSnapshot = completedSnapshot
        currentTickDegradation = nil
        return completedSnapshot
    }

    /// Emits one bounded, structured record per affected agent for each
    /// completed tick. Reasons intentionally stay out of the log: probe
    /// health payloads carry the typed detail, while the log only carries
    /// stable state and identity fields so malformed fixture contents,
    /// paths, and secrets cannot be disclosed.
    private func logProbeDegradations(in snapshot: BurnBarFleetSnapshot) {
        var loggedAgents = Set<String>()
        for health in snapshot.probeHealth {
            let state: String
            switch health.state {
            case .ok:
                continue
            case .degraded:
                state = "degraded"
            case .failed:
                state = "failed"
            }

            let agent = health.agent.wireValue
            guard loggedAgents.insert(agent).inserted else { continue }
            logger.notice(
                "fleet_probe_degraded",
                metadata: [
                    "agent": agent,
                    "state": state,
                    "tick": "\(completedTickCount)",
                    "daemon_pid": "\(ProcessInfo.processInfo.processIdentifier)"
                ]
            )
        }
    }

    private func runTicker() async {
        var cadenceSchedule = BurnBarFleetCadenceSchedule(
            startingAt: DispatchTime.now().uptimeNanoseconds,
            cadenceSeconds: builder.cadenceSeconds
        )

        while !Task.isCancelled {
            do {
                _ = try await buildOnce()
            } catch {
                currentTickDegradation = Self.tickDegradationReason(for: error)
                logger.error(
                    "fleet_tick_failed",
                    metadata: [
                        "error_type": String(describing: type(of: error)),
                        "daemon_pid": "\(ProcessInfo.processInfo.processIdentifier)"
                    ]
                )
            }

            // Anchor the next tick to the monotonic schedule. Sleeping for a
            // full cadence after a build would add build duration to every
            // interval and accumulate drift over long runs.
            let now = DispatchTime.now().uptimeNanoseconds
            let nextDeadline = cadenceSchedule.deadline(afterBuildAt: now)
            if nextDeadline > now {
                do {
                    try await Task.sleep(nanoseconds: nextDeadline - now)
                } catch {
                    return
                }
            }
        }
    }

    private static func tickDegradationReason(for error: Error) -> String {
        if let builderError = error as? BurnBarFleetSnapshotBuilderError,
           let description = builderError.errorDescription {
            return description
        }
        return "Fleet snapshot tick failed due to a daemon-side validation error."
    }
}

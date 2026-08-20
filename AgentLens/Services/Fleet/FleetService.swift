import OpenBurnBarKernel
import Foundation
import Observation

// MARK: - Fleet Load State

/// Typed load state for the fleet dashboard (M3). Every transition is
/// observable: `loading` is explicit, and each terminal state is typed —
/// `ready` (with a snapshot), `empty` (healthy zero-running snapshot), or
/// `daemonDown` (socket unreachable). No state ever fabricates agent or
/// machine data (VAL-DASH-026/028).
enum FleetLoadState: Equatable {
    /// No completed response yet; the first request is in flight.
    case loading
    /// A healthy snapshot with at least one running agent.
    case ready(BurnBarFleetSnapshot)
    /// A healthy snapshot with zero running agents (all ten declared rows
    /// present and non-running — never an empty `agents[]` payload).
    case empty(BurnBarFleetSnapshot)
    /// The daemon socket is unreachable (or the daemon is not serving fleet).
    case daemonDown(reason: String)

    /// The latest snapshot carried by any state, if one exists.
    var snapshot: BurnBarFleetSnapshot? {
        switch self {
        case .loading, .daemonDown:
            return nil
        case .ready(let snapshot), .empty(let snapshot):
            return snapshot
        }
    }

    /// True when the state carries a healthy snapshot (ready or empty).
    var isHealthy: Bool {
        snapshot != nil
    }
}

/// Reader for the daemon's well-known `fleet-snapshot.json`.
///
/// Same payload as `daemon.fleet.snapshot` (`docs/fleet/BURNBAR_FLEET_API.md`).
/// Used when the control socket accepts and then returns an empty or
/// undecodable body, so a live tick already on disk is not stranded.
enum BurnBarFleetSnapshotFile {
    static func readIfPresent(at url: URL) throws -> BurnBarFleetSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        guard data.isEmpty == false else { return nil }
        return try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)
    }
}

// MARK: - Fleet Service

/// App-side fleet client (M3). Owns the single polling loop that reads
/// `daemon.fleet.snapshot` at the daemon's snapshot cadence and exposes the
/// typed `FleetLoadState`.
///
/// Polling contract (documented in docs/fleet/BURNBAR_FLEET_SIGNALS.md):
/// - exactly one active poller at any time (start is idempotent; stop cancels
///   the only poller);
/// - at most one request per cadence interval after the documented initial
///   request (the first fetch runs immediately on start, then the loop waits
///   a full cadence between requests);
/// - the poller is lifecycle-aware: `start()` begins polling, `stop()` ends
///   it, and `restart()` is safe across window hide/close/reopen cycles
///   (VAL-DASH-015/018);
/// - staleness is computed with the documented threshold: a snapshot is stale
///   when `now - generatedAt > 2 * cadenceSeconds` (VAL-DASH-006/009).
@MainActor
@Observable
final class FleetService {
    /// Documented staleness threshold: a snapshot is stale when its age
    /// exceeds twice the snapshot cadence (pinned in
    /// docs/fleet/BURNBAR_FLEET_SIGNALS.md).
    static let stalenessThresholdMultiplier = 2

    /// The daemon socket URL the service polls.
    let socketURL: URL

    /// The fetch closure (injectable for tests). Defaults to the real
    /// `OpenBurnBarDaemonSocketClient.fleetSnapshot(at:)`.
    private let fetchSnapshot: (URL) throws -> BurnBarFleetSnapshot

    /// The orchestrator-state fetch closure (injectable for tests). Defaults
    /// to the real `daemon.fleet.orchestrator.get` RPC (M4).
    private let fetchOrchestratorState: (URL) throws -> BurnBarOrchestratorState

    /// The orchestrator-set closure (injectable for tests). Defaults to the
    /// real `daemon.fleet.orchestrator.set` RPC (M4).
    private let setOrchestratorState: (BurnBarOrchestratorDesignation, URL) throws -> BurnBarOrchestratorState

    /// The clock (injectable for deterministic staleness tests).
    private let nowProvider: () -> Date

    private(set) var loadState: FleetLoadState = .loading
    /// The daemon-owned orchestrator state (designation + pending count),
    /// fetched on demand (M4). nil while never fetched or while the daemon
    /// has never acknowledged a state. Once acknowledged, refresh failures
    /// retain the last state and expose the typed error separately.
    private(set) var orchestratorState: BurnBarOrchestratorState?
    /// Typed reason when the orchestrator state could not be fetched.
    private(set) var orchestratorStateError: String?
    /// True while a designation set request is in flight (the control
    /// changes only after daemon acknowledgement — VAL-ORCH-034).
    private(set) var isSettingDesignation = false
    /// True while the poller is active (exactly one poller exists when true).
    private(set) var isPolling = false
    /// Total fleet requests issued since the last `start()` (test seam).
    private(set) var requestCount = 0
    /// The last request's start time (test seam for cadence accounting).
    private(set) var lastRequestAt: Date?

    private var pollTask: Task<Void, Never>?
    private var isStarted = false

    init(
        socketURL: URL,
        fetchSnapshot: @escaping (URL) throws -> BurnBarFleetSnapshot = { url in
            try FleetService.fetchSnapshotWithFileFallback(at: url)
        },
        fetchOrchestratorState: @escaping (URL) throws -> BurnBarOrchestratorState = { url in
            try OpenBurnBarDaemonSocketClient.fleetOrchestratorGet(at: url)
        },
        setOrchestratorState: @escaping (BurnBarOrchestratorDesignation, URL) throws -> BurnBarOrchestratorState = { designation, url in
            try OpenBurnBarDaemonSocketClient.fleetOrchestratorSet(designation, at: url)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.socketURL = socketURL
        self.fetchSnapshot = fetchSnapshot
        self.fetchOrchestratorState = fetchOrchestratorState
        self.setOrchestratorState = setOrchestratorState
        self.nowProvider = now
    }

    /// The default app socket path (the daemon's default socket under the
    /// app support directory).
    static func defaultSocketURL() -> URL {
        OpenBurnBarDaemonRuntimePaths.live().socketURL
    }

    /// Live fetch: RPC first, then the well-known snapshot file. An empty
    /// socket body used to surface as Cocoa's "data isn't in the correct
    /// format" and blank the board while `fleet-snapshot.json` was current.
    static func fetchSnapshotWithFileFallback(
        at socketURL: URL,
        fileURL: URL = OpenBurnBarDaemonRuntimePaths.live().fleetSnapshotFileURL
    ) throws -> BurnBarFleetSnapshot {
        do {
            return try OpenBurnBarDaemonSocketClient.fleetSnapshot(at: socketURL)
        } catch {
            if let fileSnapshot = try BurnBarFleetSnapshotFile.readIfPresent(at: fileURL) {
                return fileSnapshot
            }
            throw error
        }
    }

    /// Starts the single polling loop. Idempotent: calling start while a
    /// poller is active is a no-op, so close/reopen cycles never accumulate
    /// pollers (VAL-DASH-015/018).
    ///
    /// The documented initial request runs synchronously here; the loop then
    /// waits a full cadence between subsequent requests (≤1 request per
    /// cadence interval after the initial request).
    func start() {
        guard !isStarted else { return }
        isStarted = true
        isPolling = true
        requestCount = 0
        lastRequestAt = nil
        fetchOnce()
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    /// Stops the only poller. The last load state is retained so the view can
    /// keep rendering the last honest state while hidden.
    func stop() {
        isStarted = false
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// Performs one immediate fetch (used by tests and by the poller).
    /// Updates `loadState` from the result.
    func fetchOnce() {
        // The poller must not blank a healthy board on a single timeout.
        // Staleness is already typed (`isStale` at 2× cadence). First-fetch
        // failures still go `daemonDown` because there is no snapshot yet.
        _ = applySnapshotFetch(clobberHealthyBoardOnError: false)
    }

    /// Chat/context read. While the Fleet poller owns cadence, reuse the
    /// board snapshot (no extra RPC). A miss must not blank a healthy board
    /// or overwrite a newer set-ack with a lagging snapshot embed.
    @discardableResult
    func fetchSnapshotForContext() -> BurnBarFleetSnapshot? {
        if isPolling, let snapshot = loadState.snapshot {
            return snapshot
        }
        return applySnapshotFetch(clobberHealthyBoardOnError: false)
    }

    private func applySnapshotFetch(clobberHealthyBoardOnError: Bool) -> BurnBarFleetSnapshot? {
        requestCount += 1
        lastRequestAt = Date()
        do {
            let snapshot = try fetchSnapshot(socketURL)
            loadState = snapshot.runningCount > 0
                ? .ready(snapshot)
                : .empty(snapshot)
            adoptOrchestratorFromSnapshot(snapshot.orchestrator)
            return snapshot
        } catch let error as BurnBarFleetClientError {
            switch error {
            case .notReady:
                if loadState.snapshot == nil {
                    loadState = .loading
                }
            default:
                applySnapshotFetchFailure(error.localizedDescription, clobberHealthyBoardOnError: clobberHealthyBoardOnError)
            }
            return loadState.snapshot
        } catch {
            applySnapshotFetchFailure(error.localizedDescription, clobberHealthyBoardOnError: clobberHealthyBoardOnError)
            return loadState.snapshot
        }
    }

    private func applySnapshotFetchFailure(_ reason: String, clobberHealthyBoardOnError: Bool) {
        if clobberHealthyBoardOnError || !loadState.isHealthy {
            loadState = .daemonDown(reason: reason)
        }
    }

    /// Snapshot embed can lag `orchestrator.set` by one cadence. A stamped
    /// ack wins until a snapshot carries an equal-or-newer `setAt`. A
    /// successful snapshot still clears a prior GET error so the picker is
    /// not left hidden behind a stale `orchestratorStateError`.
    private func adoptOrchestratorFromSnapshot(_ incoming: BurnBarOrchestratorState) {
        if orchestratorStateError != nil {
            orchestratorStateError = nil
        }
        if let current = orchestratorState, let currentSetAt = current.setAt {
            if let incomingSetAt = incoming.setAt {
                if incomingSetAt < currentSetAt { return }
            } else {
                return
            }
        }
        if orchestratorState != incoming {
            orchestratorState = incoming
        }
    }

    /// The cadence (seconds) of the last completed snapshot, or the default
    /// 15s when no snapshot has arrived yet.
    var cadenceSeconds: Int {
        loadState.snapshot?.cadenceSeconds ?? 15
    }

    /// Whether the current snapshot is stale per the documented threshold:
    /// `now - generatedAt > 2 * cadenceSeconds` (VAL-DASH-006/009).
    var isStale: Bool {
        guard let snapshot = loadState.snapshot else { return false }
        let age = nowProvider().timeIntervalSince(snapshot.generatedAt)
        return age > Double(Self.stalenessThresholdMultiplier * snapshot.cadenceSeconds)
    }

    /// The snapshot's age in seconds, or nil when no snapshot is loaded.
    var snapshotAgeSeconds: TimeInterval? {
        loadState.snapshot.map { nowProvider().timeIntervalSince($0.generatedAt) }
    }

    // MARK: - Orchestrator designation (M4)

    /// Fetches the daemon-owned orchestrator state (designation + pending
    /// count). Typed failure states are surfaced via `orchestratorStateError`
    /// — never fabricated (VAL-ORCH-034).
    func refreshOrchestratorState() {
        do {
            orchestratorState = try fetchOrchestratorState(socketURL)
            orchestratorStateError = nil
        } catch {
            orchestratorStateError = error.localizedDescription
        }
    }

    /// Sets the daemon-owned orchestrator designation. The control changes
    /// only after daemon acknowledgement: the returned state is stored, and a
    /// rejected/unavailable set preserves the prior acknowledged state and
    /// surfaces a typed error (VAL-ORCH-034). No optimistic local state.
    func setDesignation(_ designation: BurnBarOrchestratorDesignation) async {
        guard !isSettingDesignation else { return }
        isSettingDesignation = true
        defer { isSettingDesignation = false }
        do {
            let updated = try setOrchestratorState(designation, socketURL)
            orchestratorState = updated
            orchestratorStateError = nil
        } catch {
            orchestratorStateError = error.localizedDescription
        }
    }

    private func runPollLoop() async {
        // The initial request already ran in `start()`. Each loop iteration
        // waits a full cadence, then issues exactly one request (≤1 request
        // per cadence interval after the initial request).
        while !Task.isCancelled {
            let interval = UInt64(cadenceSeconds) * 1_000_000_000
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                return
            }
            if Task.isCancelled { return }
            fetchOnce()
        }
    }
}

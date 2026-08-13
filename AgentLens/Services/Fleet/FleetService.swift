import BurnBarCore
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
    /// `BurnBarDaemonSocketClient.fleetSnapshot(at:)`.
    private let fetchSnapshot: (URL) throws -> BurnBarFleetSnapshot

    /// The clock (injectable for deterministic staleness tests).
    private let nowProvider: () -> Date

    private(set) var loadState: FleetLoadState = .loading
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
            try BurnBarDaemonSocketClient.fleetSnapshot(at: url)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.socketURL = socketURL
        self.fetchSnapshot = fetchSnapshot
        self.nowProvider = now
    }

    /// The default app socket path (the daemon's default socket under the
    /// app support directory).
    static func defaultSocketURL() -> URL {
        BurnBarDaemonRuntimePaths.live().socketURL
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

    /// Performs one immediate fetch (used by tests and by the initial
    /// request). Updates `loadState` from the result.
    func fetchOnce() {
        requestCount += 1
        lastRequestAt = Date()
        do {
            let snapshot = try fetchSnapshot(socketURL)
            loadState = snapshot.runningCount > 0
                ? .ready(snapshot)
                : .empty(snapshot)
        } catch let error as BurnBarFleetClientError {
            switch error {
            case .notReady:
                // The daemon is alive but its first tick has not completed:
                // stay in the explicit loading state and retry on the next
                // poll (VAL-DASH-028) — never a fabricated empty board.
                if loadState.snapshot == nil {
                    loadState = .loading
                }
            default:
                loadState = .daemonDown(reason: error.localizedDescription)
            }
        } catch {
            loadState = .daemonDown(reason: error.localizedDescription)
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

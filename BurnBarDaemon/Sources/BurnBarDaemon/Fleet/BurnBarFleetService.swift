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

    public var cadenceSeconds: Int { builder.cadenceSeconds }

    private var latestSnapshot: BurnBarFleetSnapshot?
    private var tickTask: Task<Void, Never>?
    private var isRunning = false

    public init(builder: BurnBarFleetSnapshotBuilder) {
        self.builder = builder
    }

    /// Starts the cadence ticker. The first tick runs immediately; subsequent
    /// ticks wait `cadenceSeconds` between builds. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
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

    /// Builds one snapshot immediately (used by the ticker and by tests).
    @discardableResult
    public func buildOnce() async throws -> BurnBarFleetSnapshot {
        let snapshot = try await builder.build()
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

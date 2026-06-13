import Foundation
import OpenBurnBarIrohRelay

/// RR-18 mid-stream teardown for the host accept loop's per-stream serve tasks.
///
/// `HermesIrohRelayHostClient.acceptLoop` checks the inbound allowlist exactly
/// once — at accept — then spawns a serve task per inbound stream and tracks it
/// only by an opaque `UUID` so `stop()` can cancel them all. That leaves no way
/// to cancel just the tasks belonging to a peer that is de-allowlisted or
/// revoked mid-stream, so a revoked peer keeps its live stream until natural
/// close. This registry adds the missing per-peer index: the host records each
/// serve task here keyed by its remote NodeId, and on every allowlist/policy
/// refresh calls `cancelTasks(notAllowedBy:)` with a checker backed by the
/// fresh `IrohInboundPeerPolicy`, mirroring how `stop()` cancels all tasks.
///
/// Concurrency model: an actor so the accept loop (registering / releasing) and
/// the heartbeat (purging) stay linearizable. Tasks are tracked as
/// `Task<Void, Never>` references the host already owns; cancellation is
/// cooperative, exactly as `stop()` relies on.
public actor MediaServeTaskTeardownRegistry {
    private struct Entry {
        let remotePeerNodeId: String?
        let task: Task<Void, Never>
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// Track a serve task for `remotePeerNodeId`. The host passes the same
    /// `serveID` it uses in its own `serveTasks` map so `release` stays
    /// symmetric with the host's existing cleanup.
    public func register(serveID: UUID, remotePeerNodeId: String?, task: Task<Void, Never>) {
        entries[serveID] = Entry(remotePeerNodeId: remotePeerNodeId, task: task)
    }

    /// Forget a serve task that finished on its own. Matches the host's
    /// `releaseServeTask` so a completed task is not later "cancelled" as a
    /// stale entry.
    public func release(serveID: UUID) {
        entries.removeValue(forKey: serveID)
    }

    /// RR-18 — cancel every tracked serve task whose `remotePeerNodeId` is no
    /// longer allowed. A task with an unknown (`nil`) NodeId is treated as
    /// not-allowed and torn down, since a stream the policy can no longer
    /// identify must not keep serving. Returns the cancelled serve ids so the
    /// caller can drop the matching entries from its own `serveTasks` map.
    @discardableResult
    public func cancelTasks(notAllowedBy isAllowed: MediaInboundPeerAllowChecker) -> [UUID] {
        var cancelled: [UUID] = []
        for (serveID, entry) in entries where !isAllowed(entry.remotePeerNodeId) {
            entry.task.cancel()
            cancelled.append(serveID)
        }
        for serveID in cancelled {
            entries.removeValue(forKey: serveID)
        }
        return cancelled
    }

    /// Cancel and forget every tracked task. Lets the host route its `stop()`
    /// teardown through the same registry instead of keeping a parallel map.
    public func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
        entries.removeAll()
    }

    public func activeTaskCount() -> Int {
        entries.count
    }
}

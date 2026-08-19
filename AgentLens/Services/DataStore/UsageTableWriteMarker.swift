import Foundation
import OpenBurnBarKernel

// MARK: - Usage Table Write Marker

/// Monotonic in-process counter that advances once per committed write that
/// actually changed `token_usage` row content.
///
/// This is the cheap "new-event marker" the periodic refresh tick consults
/// before deciding to reload + re-aggregate the usage table
/// (`DataStoreCoordinator.reloadUsagesIfChanged`). At idle — when a tick's
/// parse pass re-upserts byte-identical rows and the value-diff `WHERE` gate
/// on the upserts suppresses the no-op `UPDATE`s — the marker stays put and
/// the tick skips the O(total-history) fetch/sort/aggregate entirely.
///
/// Invariants:
/// * Every production writer of `token_usage` must bump this marker when its
///   transaction changed at least one row. Today those writers are the
///   `UsageStore` mutators and (test-only) `AtomicIngestionTransaction`;
///   `scripts/debt/check-usage-fullfetch-budget.sh` trips if a new raw
///   `token_usage` writer appears outside the allowlisted files.
/// * A bump when nothing user-visible changed (over-signalling) only costs
///   one redundant reload — the `UsageReplaceGate` fingerprint downstream
///   still short-circuits the apply. A MISSED bump is the dangerous
///   direction (stale dashboard until the next window boundary), so writers
///   bump whenever SQLite reports any row change.
/// * Startup migrations may rewrite `token_usage` before this marker exists.
///   Background ticks record the current marker without hydrating presentation
///   state; the first explicit tray/dashboard load is exhaustive and records
///   the marker that preceded its snapshot.
final class UsageTableWriteMarker: Sendable {
    private let counter = Locked<Int>(0)

    /// Current marker value. Monotonically non-decreasing.
    var value: Int { counter.read() }

    /// Records that a committed transaction changed `token_usage` content.
    func bump() {
        counter.withLock { $0 += 1 }
    }
}

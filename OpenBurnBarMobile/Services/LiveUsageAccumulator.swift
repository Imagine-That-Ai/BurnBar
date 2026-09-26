import Foundation
import OpenBurnBarInboxModels
import OpenBurnBarInsights
import OpenBurnBarKernel
import OpenBurnBarQuota
import OpenBurnBarUI

// MARK: - Live Usage Incremental Listener Support
//
// Swift half of the shared iOS/Android incremental live-usage listener
// design (`FirestoreRepository.listenToUsageSince` on both platforms):
// identical query shape (`endTime >= cutoff`, endTime-descending,
// defensive 2000-doc cap), a docID-keyed delta cache patched from
// `documentChanges`, and a `(docID, updatedAt)` memo over the sealed
// project-name AEAD open. Android's counterpart lives in
// `android/.../data/firebase/LiveUsageAccumulator.kt`.

// AUDIT(@unchecked Sendable): untyped Firestore [String: Any]? payload across one
// confined decode hop. sendable-allowlist: firestore-any-payload
/// One snapshot-listener delta, captured on Firestore's callback thread and
/// consumed on the listener's serial decode queue. The `[String: Any]`
/// payload comes straight from `QueryDocumentSnapshot.data()` and crosses
/// exactly one hop onto the confining queue, hence `@unchecked Sendable`.
struct LiveUsageDocumentChange: @unchecked Sendable {
    enum Kind: Sendable {
        case upsert
        case removed
    }

    let kind: Kind
    let docID: String
    let payload: [String: Any]?
    let updatedAtMillis: Int64
}

/// Per-listener document cache for the Pulse live-usage snapshot listener.
///
/// Firestore delivers a full result set on every snapshot, but only
/// `documentChanges` actually differ. Patching this docID-keyed cache from
/// the deltas makes each delivery O(changed docs) instead of O(window) — on
/// a heavy agent day (hundreds to thousands of rows in the rolling 24h
/// window) every streamed usage write used to re-decode and re-decrypt the
/// entire window on the main actor.
///
/// The result order is maintained incrementally for the same reason: the
/// window used to be re-sorted whole on every delivery even when a single
/// document changed. Each mutation binary-searches the ordered id list and
/// splices one entry, so a delivery costs O(changed docs × window) pointer
/// moves instead of O(window log window) comparisons, and `snapshot()` is a
/// projection with no sort at all.
///
/// Not thread-safe by itself — the listener confines all access to its
/// serial decode queue (`@unchecked Sendable` reflects that confinement).
final class LiveUsageAccumulator: Sendable {
    private struct State: Sendable {
        var byDocID: [String: TokenUsage] = [:]
        /// Doc ids in snapshot order: `endTime` descending with the document
        /// id as the descending tiebreaker (Firestore implicitly appends
        /// `__name__` in the sort direction of the last explicit `orderBy`).
        /// The same ids as `byDocID.keys`, no more and no fewer.
        var orderedIDs: [String] = []
    }

    private let state = Locked(State())

    func upsert(_ usage: TokenUsage, docID: String) {
        state.withLock { state in
            if let old = state.byDocID[docID] {
                Self.removeID(docID, endTime: old.endTime, from: &state)
            }
            state.byDocID[docID] = usage
            state.orderedIDs.insert(docID, at: Self.insertionIndex(for: usage.endTime, docID: docID, in: state))
        }
    }

    func remove(docID: String) {
        state.withLock { state in
            guard let endTime = state.byDocID.removeValue(forKey: docID)?.endTime else { return }
            Self.removeID(docID, endTime: endTime, from: &state)
        }
    }

    /// The current window contents, ordered exactly like the raw query
    /// results this replaces: `endTime` descending with the document ID as
    /// the descending tiebreaker (Firestore implicitly appends `__name__`
    /// in the sort direction of the last explicit `orderBy`).
    func snapshot() -> [TokenUsage] {
        state.withLock { state in
            state.orderedIDs.compactMap { state.byDocID[$0] }
        }
    }

    /// Whether `(endTime, docID)` sorts strictly before the entry at `index`
    /// under the snapshot order (both keys descending).
    private static func isOrderedBefore(endTime: Date, docID: String, entryAt index: Int, in state: State) -> Bool {
        let entryID = state.orderedIDs[index]
        guard let entryEndTime = state.byDocID[entryID]?.endTime else { return false }
        if endTime != entryEndTime { return endTime > entryEndTime }
        return docID > entryID
    }

    /// The index at which `(endTime, docID)` belongs in `orderedIDs`.
    private static func insertionIndex(for endTime: Date, docID: String, in state: State) -> Int {
        var low = 0
        var high = state.orderedIDs.count
        while low < high {
            let mid = (low + high) / 2
            if isOrderedBefore(endTime: endTime, docID: docID, entryAt: mid, in: state) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// Drop `docID` from `orderedIDs` by its known sort key. `insertionIndex`
    /// is a lower bound, so for a key that is present it returns one past the
    /// entry (equal keys are not strictly-before); check both slots. The
    /// linear fallback keeps a missed index a slow removal rather than a
    /// stuck duplicate that would corrupt every later snapshot.
    private static func removeID(_ docID: String, endTime: Date?, from state: inout State) {
        if let endTime {
            let index = insertionIndex(for: endTime, docID: docID, in: state)
            for candidate in [index - 1, index] {
                if state.orderedIDs.indices.contains(candidate), state.orderedIDs[candidate] == docID {
                    state.orderedIDs.remove(at: candidate)
                    return
                }
            }
        }
        state.orderedIDs.removeAll { $0 == docID }
    }
}

/// Memoizes opened `sealedProjectName` values by `(docID, updatedAt)` so a
/// MODIFIED delivery (live rows advance token totals on every agent write)
/// only re-runs the AEAD open when the document actually changed since the
/// cached open — `updatedAt` is rewritten on every document rewrite, which
/// is what makes it a sound cache key.
///
/// A missing/unparseable `updatedAt` (`<= 0`) bypasses the cache entirely:
/// with no freshness signal a stale name must never be served.
///
/// Not thread-safe by itself — confined to the listener's decode queue.
final class SealedProjectNameCache: Sendable {
    private struct Entry {
        let updatedAtMillis: Int64
        let projectName: String?
    }

    private let byDocID = Locked<[String: Entry]>([:])

    func openOrCached(docID: String, updatedAtMillis: Int64, open: () -> String?) -> String? {
        guard updatedAtMillis > 0 else { return open() }
        if let cached = byDocID.withLock({ $0[docID] }), cached.updatedAtMillis == updatedAtMillis {
            return cached.projectName
        }
        let opened = open()
        byDocID.withLock { $0[docID] = Entry(updatedAtMillis: updatedAtMillis, projectName: opened) }
        return opened
    }

    func remove(docID: String) {
        byDocID.withLock { _ = $0.removeValue(forKey: docID) }
    }
}

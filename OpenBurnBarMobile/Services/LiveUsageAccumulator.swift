import Foundation
import OpenBurnBarCore

// MARK: - Live Usage Incremental Listener Support
//
// Swift half of the shared iOS/Android incremental live-usage listener
// design (`FirestoreRepository.listenToUsageSince` on both platforms):
// identical query shape (`endTime >= cutoff`, endTime-descending,
// defensive 2000-doc cap), a docID-keyed delta cache patched from
// `documentChanges`, and a `(docID, updatedAt)` memo over the sealed
// project-name AEAD open. Android's counterpart lives in
// `android/.../data/firebase/LiveUsageAccumulator.kt`.

/// One snapshot-listener delta, captured on Firestore's callback thread and
/// consumed on the listener's serial decode queue. The `[String: Any]`
/// payload comes straight from `QueryDocumentSnapshot.data()` and crosses
/// exactly one hop onto the confining queue, hence `@unchecked Sendable`.
// AUDIT(@unchecked Sendable): untyped Firestore [String: Any]? payload across one
// confined decode hop. sendable-allowlist: firestore-any-payload
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
/// Not thread-safe by itself — the listener confines all access to its
/// serial decode queue (`@unchecked Sendable` reflects that confinement).
final class LiveUsageAccumulator: Sendable {
    private let byDocID = Locked<[String: TokenUsage]>([:])

    func upsert(_ usage: TokenUsage, docID: String) {
        byDocID.withLock { $0[docID] = usage }
    }

    func remove(docID: String) {
        byDocID.withLock { _ = $0.removeValue(forKey: docID) }
    }

    /// The current window contents, ordered exactly like the raw query
    /// results this replaces: `endTime` descending with the document ID as
    /// the descending tiebreaker (Firestore implicitly appends `__name__`
    /// in the sort direction of the last explicit `orderBy`).
    func snapshot() -> [TokenUsage] {
        byDocID.withLock { byDocID in
            byDocID
                .sorted { lhs, rhs in
                    if lhs.value.endTime != rhs.value.endTime {
                        return lhs.value.endTime > rhs.value.endTime
                    }
                    return lhs.key > rhs.key
                }
                .map(\.value)
        }
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

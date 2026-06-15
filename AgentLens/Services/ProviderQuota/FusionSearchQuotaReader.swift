import FirebaseAuth
import FirebaseFirestore
import Foundation

// MARK: - Fusion Search Quota Reader (macOS)
//
// Reads the Elder Wand hosted-search quota snapshot the Cloud Function writes
// server-side on every successful hosted search:
//
//     users/{uid}/quota_snapshots/openburnbar_elder_wand_fusion
//
// and maps its "Elder Wand hosted searches" bucket into a macOS
// `ProviderQuotaBucket` for the fusion receipt ring + the Fusion Impact meter.
//
// WHY A DEDICATED READER (not the ProviderQuotaSnapshotStore):
// the standard store decodes each snapshot into a `ProviderQuotaSnapshot` whose
// `provider` is an `AgentProvider`. The fusion snapshot is stamped with provider
// id `openburnbar`, which is NOT an `AgentProvider` case, so the store drops it
// on decode. This reader instead does a raw document read and maps the bucket
// directly — the same approach the iOS surfaces use. Any failure (no uid, no
// document, missing numbers) returns `nil` so the ring is omitted rather than
// invented; the displayed limit is consumed as-is (the Function already wrote
// `min(monthlyCap, included + purchased)`), never re-derived from the tier.

enum FusionSearchQuotaReader {
    /// The canonical fusion-search quota-snapshot document id.
    static let snapshotDocID = "openburnbar_elder_wand_fusion"

    /// Read and map the live fusion-search quota bucket. Runs on the main actor
    /// (Firestore + Auth handles); the `getDocument` await yields, so it never
    /// blocks the UI. Returns `nil` on any failure so callers omit the ring.
    @MainActor
    static func fetchBucket() async -> ProviderQuotaBucket? {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else { return nil }
        let docRef = Firestore.firestore()
            .collection("users").document(uid)
            .collection("quota_snapshots").document(snapshotDocID)
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await docRef.getDocument()
        } catch {
            return nil
        }
        guard let data = snapshot.data() else { return nil }
        return bucket(from: data)
    }

    /// Pure mapping from the raw snapshot document to the searches bucket — the
    /// testable seam (no Firestore). The snapshot carries a `buckets` array; the
    /// fusion snapshot has a single hosted-searches bucket
    /// (`{ name, used, limit, remaining, unit, window, resetAt }`).
    static func bucket(from data: [String: Any]) -> ProviderQuotaBucket? {
        guard let buckets = data["buckets"] as? [[String: Any]] else { return nil }
        let searchBucket = buckets.first { entry in
            let name = ((entry["name"] as? String) ?? (entry["label"] as? String) ?? "").lowercased()
            return name.contains("search")
        } ?? buckets.first
        guard let searchBucket else { return nil }

        let used = number(searchBucket["used"])
        let limit = number(searchBucket["limit"])
        let remaining = number(searchBucket["remaining"])
        // At least one numeric signal is required to draw a meaningful ring.
        guard used != nil || limit != nil || remaining != nil else { return nil }

        let label = (searchBucket["name"] as? String)
            ?? (searchBucket["label"] as? String)
            ?? "Elder Wand hosted searches"

        return ProviderQuotaBucket(
            key: "fusion_searches",
            label: label,
            windowKind: .monthly,
            usedValue: used,
            limitValue: limit,
            remainingValue: remaining,
            usedPercent: nil,
            resetsAt: resetDate(searchBucket["resetAt"] ?? searchBucket["resetsAt"]),
            unit: .count,
            isEstimated: false
        )
    }

    // MARK: - Coercion helpers

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let ts = value as? Timestamp { return ts.dateValue() }
        if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = value as? String { return ISO8601DateFormatter().date(from: s) }
        return nil
    }
}

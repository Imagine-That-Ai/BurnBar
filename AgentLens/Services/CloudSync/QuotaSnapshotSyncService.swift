import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Uploads desktop quota snapshots to Firestore so iOS can read them.
/// Desktop writes: users/{uid}/quota_snapshots/{provider}_{deviceId}
@MainActor
final class QuotaSnapshotSyncService {
    private let context: CloudSyncContext

    init(context: CloudSyncContext) {
        self.context = context
    }

    func uploadSnapshots(_ snapshots: [ProviderQuotaSnapshot]) async {
        guard context.accountManager.isFirebaseAvailable,
              context.accountManager.isSignedIn,
              context.accountManager.isCloudSyncEnabled,
              !context.syncIsSuppressed(),
              let uid = context.currentUID else { return }

        do {
            let batch = context.firestoreGateway.batch()
            let collectionRef = context.firestoreGateway.collection("users").document(uid).collection("quota_snapshots")

            for snapshot in snapshots {
                let docId = "\(snapshot.provider.persistedToken)_\(context.deviceId)"
                let docRef = collectionRef.document(docId)
                let data = encodeSnapshot(snapshot, deviceId: context.deviceId)
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "quota_snapshot"
            ) {
                try await batch.commit()
            }
        } catch {
            let nsError = error as NSError
            guard nsError.domain == FirestoreErrorDomain,
                  let code = FirestoreErrorCode.Code(rawValue: nsError.code),
                  code == .permissionDenied || code == .unauthenticated else { return }
            context.suppressedSyncUntil = Date().addingTimeInterval(CloudSyncBackoffPolicy.permissionDeniedCooldown)
        }
    }

    /// Encodes a snapshot into the Firestore shape that the mobile app's
    /// `ProviderQuotaSnapshot` Codable type expects.  The desktop's in-memory
    /// model uses richer field names; this method translates to the canonical
    /// Firestore schema shared with iOS.
    private func encodeSnapshot(_ snapshot: ProviderQuotaSnapshot, deviceId: String) -> [String: Any] {
        var result: [String: Any] = [
            "provider": snapshot.provider.persistedToken,
            "sourceKind": snapshot.sourceKind.rawValue,
            "sourceId": deviceId,
            "source": snapshot.provider.displayName,
            "fetchedAt": Timestamp(date: snapshot.fetchedAt),
            "confidence": snapshot.confidence.rawValue,
            "statusMessage": snapshot.statusMessage,
            "buckets": snapshot.buckets.map(encodeBucket),
            "schemaVersion": snapshot.schemaVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let url = snapshot.managementURL {
            result["managementURL"] = url
        }
        return result
    }

    /// Encodes a bucket into the mobile-compatible Firestore schema.
    /// The desktop model uses `key`/`label`/`usedValue`; the shared Codable
    /// type expects `name`/`used`/`limit`/`remaining`/`window`/`meta`.
    private func encodeBucket(_ bucket: ProviderQuotaBucket) -> [String: Any] {
        var meta: [String: String] = [
            "label": bucket.label,
            "unit": bucket.unit.rawValue,
            "isEstimated": bucket.isEstimated ? "true" : "false"
        ]
        if let v = bucket.usedPercent { meta["usedPercent"] = String(format: "%.2f", v) }
        if let d = bucket.resetsAt {
            meta["resetsAt"] = ISO8601DateFormatter().string(from: d)
        }
        var result: [String: Any] = [
            "name": bucket.key,
            "used": bucket.usedValue ?? 0,
            "limit": bucket.limitValue ?? 0,
            "remaining": bucket.remainingValue ?? 0,
            "window": bucket.windowKind.rawValue,
            "meta": meta
        ]
        return result
    }
}

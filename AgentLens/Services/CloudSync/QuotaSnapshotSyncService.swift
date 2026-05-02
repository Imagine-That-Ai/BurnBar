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

    private func encodeSnapshot(_ snapshot: ProviderQuotaSnapshot, deviceId: String) -> [String: Any] {
        var result: [String: Any] = [
            "provider": snapshot.provider.persistedToken,
            "sourceKind": snapshot.sourceKind.rawValue,
            "sourceId": deviceId,
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

    private func encodeBucket(_ bucket: ProviderQuotaBucket) -> [String: Any] {
        var result: [String: Any] = [
            "key": bucket.key,
            "label": bucket.label,
            "windowKind": bucket.windowKind.rawValue,
            "unit": bucket.unit.rawValue,
            "isEstimated": bucket.isEstimated
        ]
        if let v = bucket.usedValue { result["usedValue"] = v }
        if let v = bucket.limitValue { result["limitValue"] = v }
        if let v = bucket.remainingValue { result["remainingValue"] = v }
        if let v = bucket.usedPercent { result["usedPercent"] = v }
        if let d = bucket.resetsAt { result["resetsAt"] = Timestamp(date: d) }
        return result
    }
}

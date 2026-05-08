import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Uploads non-secret provider account metadata so iOS/iPad can show the same
/// account list as macOS. Credentials remain in Keychain or server-private
/// Secret Manager references; this sync only writes public account state.
@MainActor
final class ProviderAccountSyncService {
    private let context: CloudSyncContext

    init(context: CloudSyncContext) {
        self.context = context
    }

    func uploadAccounts() async {
        guard context.accountManager.isFirebaseAvailable,
              context.accountManager.isSignedIn,
              context.accountManager.isCloudSyncEnabled,
              !context.syncIsSuppressed(),
              let uid = context.currentUID else { return }

        do {
            let accounts = try context.dataStore.providerAccountStore.fetchAll()
            guard !accounts.isEmpty else { return }

            let batch = context.firestoreGateway.batch()
            let collectionRef = context.firestoreGateway.collection("users").document(uid).collection("provider_accounts")

            for account in accounts {
                let docRef = collectionRef.document(sanitizeDocumentIDPart(account.id))
                batch.setData(encodeAccount(account, deviceId: context.deviceId), forDocument: docRef, merge: true)
            }

            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "provider_account"
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

    private func encodeAccount(_ account: ProviderAccountDoc, deviceId: String) -> [String: Any] {
        var result: [String: Any] = [
            "id": account.id,
            "providerID": account.providerID.rawValue,
            "label": account.label,
            "status": account.status.rawValue,
            "credentialKind": account.credentialKind.rawValue,
            "storageScope": account.storageScope.rawValue,
            "redactedLabel": account.redactedLabel,
            "isDefault": account.isDefault,
            "sortKey": account.sortKey,
            "schemaVersion": account.schemaVersion,
            "createdAt": Timestamp(date: account.createdAt),
            "updatedAt": Timestamp(date: account.updatedAt),
            "syncedAt": FieldValue.serverTimestamp()
        ]
        if let identityHint = account.identityHint {
            result["identityHint"] = identityHint
        }
        if let sourceDeviceID = account.sourceDeviceID ?? fallbackSourceDeviceID(for: account, deviceId: deviceId) {
            result["sourceDeviceID"] = sourceDeviceID
            result["deviceId"] = sourceDeviceID
        }
        if let linkedSwitcherProfileID = account.linkedSwitcherProfileID {
            result["linkedSwitcherProfileID"] = linkedSwitcherProfileID
        }
        if let lastValidatedAt = account.lastValidatedAt {
            result["lastValidatedAt"] = Timestamp(date: lastValidatedAt)
        }
        if let lastRefreshAt = account.lastRefreshAt {
            result["lastRefreshAt"] = Timestamp(date: lastRefreshAt)
        }
        if let lastErrorCode = account.lastErrorCode {
            result["lastErrorCode"] = lastErrorCode
        }
        return result
    }

    private func fallbackSourceDeviceID(for account: ProviderAccountDoc, deviceId: String) -> String? {
        switch account.storageScope {
        case .localOnly, .deviceKeychain:
            return deviceId
        case .cloudRefreshable, .serverPrivate:
            return nil
        }
    }

    private func sanitizeDocumentIDPart(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

/// Uploads desktop quota snapshots to Firestore so iOS can read them.
/// Desktop writes: users/{uid}/quota_snapshots/{providerID}_{accountID}_{sourceID}
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
            var didEnqueueWrite = false

            for snapshot in snapshots where snapshot.hasDisplayableQuotaSignal {
                let docId = snapshotDocumentID(snapshot, fallbackSourceID: context.deviceId)
                let docRef = collectionRef.document(docId)
                let data = encodeSnapshot(snapshot, deviceId: context.deviceId)
                batch.setData(data, forDocument: docRef, merge: true)
                didEnqueueWrite = true
            }

            guard didEnqueueWrite else { return }

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
        let sourceID = normalizedSourceID(snapshot, fallback: deviceId)
        var result: [String: Any] = [
            "provider": snapshot.provider.persistedToken,
            "providerID": snapshot.providerID.rawValue,
            "sourceKind": snapshot.sourceKind.rawValue,
            "sourceId": sourceID,
            "sourceID": sourceID,
            "source": snapshot.provider.displayName,
            "fetchedAt": Timestamp(date: snapshot.fetchedAt),
            "confidence": snapshot.confidence.rawValue,
            "statusMessage": snapshot.statusMessage,
            "buckets": snapshot.displayableQuotaBuckets.map(encodeBucket),
            "schemaVersion": snapshot.schemaVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let url = snapshot.managementURL {
            result["managementURL"] = url
        }
        if let accountID = snapshot.accountID {
            result["accountID"] = accountID
        }
        if let accountLabel = snapshot.accountLabel {
            result["accountLabel"] = accountLabel
        }
        if let accountStorageScope = snapshot.accountStorageScope {
            result["accountStorageScope"] = accountStorageScope.rawValue
        }
        return result
    }

    private func snapshotDocumentID(_ snapshot: ProviderQuotaSnapshot, fallbackSourceID: String) -> String {
        let accountPart = snapshot.accountID ?? "unattributed"
        let sourcePart = normalizedSourceID(snapshot, fallback: fallbackSourceID)
        return [snapshot.providerID.rawValue, accountPart, sourcePart]
            .map(sanitizeDocumentIDPart)
            .joined(separator: "_")
    }

    private func normalizedSourceID(_ snapshot: ProviderQuotaSnapshot, fallback: String) -> String {
        let trimmed = snapshot.sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "default" ? fallback : trimmed
    }

    private func sanitizeDocumentIDPart(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
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

extension CloudSyncService {
    func uploadProviderAccountsForIOS() async {
        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        await ProviderAccountSyncService(context: context).uploadAccounts()
    }

    func uploadQuotaSnapshotsForIOS(_ snapshots: [ProviderQuotaSnapshot]) async {
        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        await QuotaSnapshotSyncService(context: context).uploadSnapshots(snapshots)
    }
}

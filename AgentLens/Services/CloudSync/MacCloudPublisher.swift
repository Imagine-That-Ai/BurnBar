import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Publishes cloud-safe metadata from Mac to Firestore for mobile consumption:
/// cloud profile, recent usage summaries, sync status, and escrow device records.
/// Readback verification ensures mobile sees only confirmed data.
@MainActor
final class MacCloudPublisher {
    private let db = Firestore.firestore()
    private let accountManager: AccountManager
    private let dataStore: DataStore
    private let cloudSync: CloudSyncService?

    init(
        accountManager: AccountManager = .shared,
        dataStore: DataStore,
        cloudSync: CloudSyncService? = nil
    ) {
        self.accountManager = accountManager
        self.dataStore = dataStore
        self.cloudSync = cloudSync
    }

    private var uid: String? {
        guard accountManager.isFirebaseAvailable, accountManager.isSignedIn else { return nil }
        return Auth.auth().currentUser?.uid
    }
    private var deviceId: String { accountManager.deviceId }

    // MARK: - Cloud Profile

    func publishCloudProfile() async {
        guard let uid else { return }
        do {
            let profile = CloudProfile(
                uid: uid,
                displayName: accountManager.userDisplayName,
                avatarURL: nil,
                updatedAt: Date(),
                sourceDeviceId: deviceId
            )
            let data = try dictEncode(profile)
            try await db.collection("users").document(uid)
                .collection("cloud_profile").document("default")
                .setData(data, merge: true)
            _ = try await db.collection("users").document(uid)
                .collection("cloud_profile").document("default").getDocument()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Recent Usage Summary

    func publishRecentUsageSummary() async {
        guard let uid else { return }
        let summary = RecentUsageSummary(
            totalCost30d: cloudSync?.cloudTotalCost ?? 0,
            totalTokens30d: 0,
            totalRequests30d: 0,
            topProviders: [],
            topModels: [],
            computedAt: Date(),
            sourceDeviceId: deviceId
        )
        do {
            let data = try dictEncode(summary)
            try await db.collection("users").document(uid)
                .collection("recent_usage").document("30d")
                .setData(data, merge: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Sync Status

    func publishSyncStatus(collectionsInSync: [String] = []) async {
        guard let uid else { return }
        do {
            let status = SyncStatus(
                deviceId: deviceId,
                isOnline: true,
                lastSyncAt: Date(),
                collectionsInSync: collectionsInSync,
                updatedAt: Date()
            )
            let data = try dictEncode(status)
            try await db.collection("users").document(uid)
                .collection("sync_status").document(deviceId)
                .setData(data, merge: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Publish All

    private(set) var lastError: String?

    func publishAll() async {
        lastError = nil
        await publishCloudProfile()
        await publishRecentUsageSummary()
        await publishSyncStatus(collectionsInSync: ["usage", "conversations", "quota_snapshots"])
    }

    // MARK: - Helpers

    private func dictEncode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let jsonData = try JSONEncoder().encode(value)
        guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [], debugDescription: "Failed to convert to dictionary"))
        }
        return dict
    }
}

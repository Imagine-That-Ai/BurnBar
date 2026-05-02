import Foundation
import FirebaseAuth
import FirebaseFirestore
import OpenBurnBarCore

// MARK: - Firestore Repository

@MainActor
final class FirestoreRepository {
    static let shared = FirestoreRepository()

    private let db = Firestore.firestore()

    private func uid() throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        return uid
    }

    // MARK: - Usage Rollups

    func fetchRollups() async throws -> [UsageRollupDoc] {
        let uid = try uid()
        let keys = RollupWindowKey.allCases.map(\.rawValue)
        var results: [UsageRollupDoc] = []
        for key in keys {
            let doc = try await db.document("users/\(uid)/usage_rollups/\(key)").getDocument()
            if let data = doc.data(),
               let jsonData = try? JSONSerialization.data(withJSONObject: data),
               var rollup = try? JSONDecoder().decode(UsageRollupDoc.self, from: jsonData) {
                results.append(rollup)
            }
        }
        return results
    }

    func listenToRollups(
        onUpdate: @escaping @Sendable (Result<[UsageRollupDoc], Error>) -> Void
    ) -> ListenerRegistration? {
        guard let uid = Auth.auth().currentUser?.uid else {
            onUpdate(.failure(FirestoreError.notAuthenticated))
            return nil
        }
        return db.collection("users/\(uid)/usage_rollups").addSnapshotListener { snapshot, error in
            if let error {
                onUpdate(.failure(error))
                return
            }
            var results: [UsageRollupDoc] = []
            for doc in snapshot?.documents ?? [] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: doc.data()),
                   var rollup = try? JSONDecoder().decode(UsageRollupDoc.self, from: jsonData) {
                    results.append(rollup)
                }
            }
            onUpdate(.success(results))
        }
    }

    // MARK: - Quota Snapshots

    func fetchQuotaSnapshots() async throws -> [ProviderQuotaSnapshot] {
        let uid = try uid()
        let snapshot = try await db.collection("users/\(uid)/quota_snapshots").getDocuments()
        return snapshot.documents.compactMap { doc in
            guard let jsonData = try? JSONSerialization.data(withJSONObject: doc.data()),
                  var snap = try? JSONDecoder().decode(ProviderQuotaSnapshot.self, from: jsonData) else { return nil }
            return snap
        }
    }

    func listenToQuotaSnapshots(
        onUpdate: @escaping @Sendable (Result<[ProviderQuotaSnapshot], Error>) -> Void
    ) -> ListenerRegistration? {
        guard let uid = Auth.auth().currentUser?.uid else {
            onUpdate(.failure(FirestoreError.notAuthenticated))
            return nil
        }
        return db.collection("users/\(uid)/quota_snapshots").addSnapshotListener { snapshot, error in
            if let error {
                onUpdate(.failure(error))
                return
            }
            let results = (snapshot?.documents ?? []).compactMap { doc -> ProviderQuotaSnapshot? in
                guard let jsonData = try? JSONSerialization.data(withJSONObject: doc.data()),
                      let snap = try? JSONDecoder().decode(ProviderQuotaSnapshot.self, from: jsonData) else { return nil }
                return snap
            }
            onUpdate(.success(results))
        }
    }

    // MARK: - Usage Events (Activity)

    func fetchUsagePage(
        pageSize: Int,
        after: DocumentSnapshot?,
        provider: String?,
        model: String?,
        device: String?,
        startDate: Date?,
        endDate: Date?
    ) async throws -> ([TokenUsage], DocumentSnapshot?) {
        let uid = try uid()
        var query: Query = db.collection("users/\(uid)/usage")
            .order(by: "startTime", descending: true)
            .limit(to: pageSize)

        if let provider { query = query.whereField("provider", isEqualTo: provider) }
        if let model { query = query.whereField("model", isEqualTo: model) }
        if let device { query = query.whereField("sourceDeviceId", isEqualTo: device) }
        if let startDate { query = query.whereField("startTime", isGreaterThanOrEqualTo: Timestamp(date: startDate)) }
        if let endDate { query = query.whereField("startTime", isLessThanOrEqualTo: Timestamp(date: endDate)) }
        if let after { query = query.start(afterDocument: after) }

        let snapshot = try await query.getDocuments()
        let items = snapshot.documents.compactMap { doc -> TokenUsage? in
            guard let jsonData = try? JSONSerialization.data(withJSONObject: doc.data()),
                  let usage = try? JSONDecoder().decode(TokenUsage.self, from: jsonData) else { return nil }
            return usage
        }
        return (items, snapshot.documents.last)
    }

    // MARK: - Provider Connections

    func fetchProviderConnections() async throws -> [ProviderConnectionDoc] {
        let uid = try uid()
        let snapshot = try await db.collection("users/\(uid)/provider_connections").getDocuments()
        return snapshot.documents.compactMap { doc in
            guard let jsonData = try? JSONSerialization.data(withJSONObject: doc.data()),
                  let conn = try? JSONDecoder().decode(ProviderConnectionDoc.self, from: jsonData) else { return nil }
            return conn
        }
    }
}

// MARK: - Firestore Error

enum FirestoreError: Error, LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        }
    }
}

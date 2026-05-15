import Foundation
import Observation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore

@MainActor
@Observable
final class AgentSubscriptionTopicStore {
    static let shared = AgentSubscriptionTopicStore()

    private(set) var topics: [SubscriptionTopic] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    private let firestoreProvider: () -> Firestore
    private var authListenerHandle: AuthStateDidChangeListenerHandle?
    private var topicsListener: ListenerRegistration?

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func bootstrap() {
        guard authListenerHandle == nil else { return }
        guard FirebaseApp.app() != nil else {
            topics = []
            lastError = nil
            return
        }
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restartRealtimeListener(uid: user?.uid)
            }
        }
        restartRealtimeListener(uid: Auth.auth().currentUser?.uid)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard FirebaseApp.app() != nil else {
            topics = []
            lastError = nil
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            topics = []
            lastError = nil
            return
        }

        do {
            let snapshot = try await collection(uid: uid)
                .order(by: "consentGivenAt", descending: true)
                .getDocuments()
            topics = snapshot.documents.compactMap { Self.decodeTopic(documentID: $0.documentID, data: $0.data()) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func topic(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID
    ) -> SubscriptionTopic? {
        topics.first { $0.agentURI == agentURI && $0.topicID == topicID }
    }

    func isSubscribed(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID
    ) -> Bool {
        topic(agentURI: agentURI, topicID: topicID) != nil
    }

    func subscribe(
        agent: AgentIdentity,
        cadence: AgentManifest.PushTopic.Cadence
    ) async throws -> SubscriptionTopic {
        let topic = AgentBrandQuickActionComposer.defaultSubscriptionTopic(
            for: agent,
            cadence: cadence
        )
        try await upsert(topic)
        return topic
    }

    func upsert(_ topic: SubscriptionTopic) async throws {
        let uid = try currentUserID()
        var payload = Self.encodeTopic(topic)
        payload["updatedAt"] = FieldValue.serverTimestamp()
        try await collection(uid: uid).document(topic.id).setData(payload, merge: true)
        mergeLocal(topic)
        lastError = nil
    }

    func unsubscribe(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID
    ) async throws {
        let uid = try currentUserID()
        let id = "\(agentURI):\(topicID)"
        try await collection(uid: uid).document(id).delete()
        topics.removeAll { $0.id == id }
        lastError = nil
    }

    func setMuted(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID,
        muted: Bool
    ) async throws {
        let uid = try currentUserID()
        let id = "\(agentURI):\(topicID)"
        try await collection(uid: uid).document(id).setData([
            "isMuted": muted,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        guard let existing = topics.first(where: { $0.id == id }) else { return }
        let updated = SubscriptionTopic(
            agentURI: existing.agentURI,
            topicID: existing.topicID,
            displayName: existing.displayName,
            description: existing.description,
            cadence: existing.cadence,
            consentGivenAt: existing.consentGivenAt,
            isMuted: muted,
            deliveryCountThisMonth: existing.deliveryCountThisMonth,
            lastDeliveredAt: existing.lastDeliveredAt
        )
        mergeLocal(updated)
        lastError = nil
    }

    // MARK: - Internals

    private func restartRealtimeListener(uid: String?) {
        topicsListener?.remove()
        topicsListener = nil

        guard FirebaseApp.app() != nil, let uid else {
            topics = []
            lastError = nil
            return
        }

        topicsListener = collection(uid: uid)
            .order(by: "consentGivenAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.lastError = error.localizedDescription
                        return
                    }
                    guard let snapshot else { return }
                    self?.topics = snapshot.documents.compactMap {
                        Self.decodeTopic(documentID: $0.documentID, data: $0.data())
                    }
                    self?.lastError = nil
                }
            }
    }

    private func currentUserID() throws -> String {
        guard FirebaseApp.app() != nil else {
            throw StoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw StoreError.notAuthenticated
        }
        return uid
    }

    private func mergeLocal(_ topic: SubscriptionTopic) {
        if let idx = topics.firstIndex(where: { $0.id == topic.id }) {
            topics[idx] = topic
        } else {
            topics.append(topic)
        }
        topics.sort {
            ($0.consentGivenAt ?? .distantPast) > ($1.consentGivenAt ?? .distantPast)
        }
    }

    private func collection(uid: String) -> CollectionReference {
        firestoreProvider()
            .collection("users").document(uid)
            .collection("subscription_topics")
    }

    private static func encodeTopic(_ topic: SubscriptionTopic) -> [String: Any] {
        [
            "agentURI": topic.agentURI,
            "topicID": topic.topicID,
            "displayName": topic.displayName,
            "description": topic.description,
            "cadence": topic.cadence.rawValue,
            "consentGivenAt": topic.consentGivenAt ?? NSNull(),
            "isMuted": topic.isMuted,
            "deliveryCountThisMonth": topic.deliveryCountThisMonth,
            "lastDeliveredAt": topic.lastDeliveredAt ?? NSNull()
        ]
    }

    private static func decodeTopic(documentID: String, data: [String: Any]) -> SubscriptionTopic? {
        let agentURI = (data["agentURI"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topicID = (data["topicID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = (data["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !agentURI.isEmpty, !topicID.isEmpty else { return nil }

        let cadenceRaw = (data["cadence"] as? String) ?? AgentManifest.PushTopic.Cadence.weekly.rawValue
        let cadence = AgentManifest.PushTopic.Cadence(rawValue: cadenceRaw) ?? .weekly
        let consentGivenAt = decodeDate(data["consentGivenAt"])
        let isMuted = (data["isMuted"] as? Bool) ?? false
        let deliveryCount = (data["deliveryCountThisMonth"] as? Int) ?? 0
        let lastDeliveredAt = decodeDate(data["lastDeliveredAt"])

        let topic = SubscriptionTopic(
            agentURI: agentURI,
            topicID: topicID,
            displayName: displayName.isEmpty ? documentID : displayName,
            description: description,
            cadence: cadence,
            consentGivenAt: consentGivenAt,
            isMuted: isMuted,
            deliveryCountThisMonth: deliveryCount,
            lastDeliveredAt: lastDeliveredAt
        )
        return topic
    }

    private static func decodeDate(_ raw: Any?) -> Date? {
        if raw is NSNull { return nil }
        if let ts = raw as? Timestamp { return ts.dateValue() }
        if let date = raw as? Date { return date }
        if let str = raw as? String {
            return ISO8601DateFormatter().date(from: str)
        }
        return nil
    }

    enum StoreError: LocalizedError {
        case firebaseUnavailable
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable:
                return "Firebase is not configured on this device."
            case .notAuthenticated:
                return "Sign in to manage subscription topics."
            }
        }
    }
}

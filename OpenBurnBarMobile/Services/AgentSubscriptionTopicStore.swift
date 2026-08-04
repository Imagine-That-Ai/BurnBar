import Foundation
import Observation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore

// MARK: - Agent Subscription Topic Store (Hermes Square §6.3)
//
// Firestore-backed store for the per-agent subscription topics the brand
// zone's Subscribe quick action manages. Moved out of
// `Views/Hermes/Square/AgentBrandZoneView.swift` (audit wave 4, item 15 —
// views must not own persistence/networking) into the Services layer it
// always belonged to; this file previously carried a placeholder comment
// pointing back at the view.

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
            let resolvedKey = try? await MobileCloudVaultKeyAccess
                .keyForReading(uid: uid, firestore: firestoreProvider())
            let trustedKeys: [String: Data] = if let identity = resolvedKey?.signalIdentity {
                await MobileCloudVaultSignalPayloads.trustedSenderPublicKeys(
                    uid: uid,
                    firestore: firestoreProvider(),
                    localIdentity: identity
                )
            } else { [:] }
            topics = snapshot.documents.compactMap { document in
                let privateData = try? resolvedKey.flatMap { key in
                    try MobileCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                        document.data(),
                        uid: uid,
                        collection: "subscription_topics",
                        docId: document.documentID,
                        signalIdentity: key.signalIdentity,
                        trustedSenderPublicKeys: trustedKeys
                    )
                }
                return Self.decodeTopic(
                    documentID: document.documentID,
                    data: document.data(),
                    vaultKey: resolvedKey?.keyData,
                    signalPlaintext: privateData ?? nil
                )
            }
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
        cadence: AgentManifest.PushTopic.Cadence,
        deliveryMode: SkillRunDeliveryMode = .actionOnly
    ) async throws -> SubscriptionTopic {
        let topic = AgentBrandQuickActionComposer.defaultSubscriptionTopic(
            for: agent,
            cadence: cadence
        ).withDeliveryMode(deliveryMode)
        try await upsert(topic)
        return topic
    }

    func setDeliveryMode(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID,
        deliveryMode: SkillRunDeliveryMode
    ) async throws {
        let id = "\(agentURI):\(topicID)"
        guard let existing = topics.first(where: { $0.id == id }) else { return }
        let updated = existing.withDeliveryMode(deliveryMode)
        try await upsert(updated)
    }

    func upsert(_ topic: SubscriptionTopic) async throws {
        let uid = try currentUserID()
        let resolvedKey = try await MobileCloudVaultKeyAccess
            .keyForWriting(uid: uid, firestore: firestoreProvider())
        let vaultKey = resolvedKey.keyData
        var payload = try Self.encodeTopic(topic, vaultKey: vaultKey)
        let signalState = MobileCloudVaultSignalPayloads.signalActivationState(domainID: "conversations_chat")
        if signalState != .off {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(topic)
            do {
                if let envelope = try await MobileCloudVaultSignalPayloads.signalEnvelopeIfEnabled(
                    domainID: "conversations_chat",
                    uid: uid,
                    firestore: firestoreProvider(),
                    collection: "subscription_topics",
                    docId: try Self.documentID(agentURI: topic.agentURI, topicID: topic.topicID, vaultKey: vaultKey),
                    plaintext: plaintext,
                    resolvedKey: resolvedKey
                ) {
                    payload["signalEnvelope"] = envelope
                    if signalState == .required {
                        for key in [
                            "sealedAgentURI", "sealedTopicID", "sealedDisplayName", "sealedDescription",
                            "sealedPayload", "encryption"
                        ] {
                            payload[key] = FieldValue.delete()
                        }
                    }
                }
            } catch {
                if signalState == .required { throw error }
            }
        }
        payload["updatedAt"] = FieldValue.serverTimestamp()
        // Merge writes must actively remove legacy plaintext fields; otherwise
        // Firestore evaluates the post-merge document as sealed+plaintext and
        // rejects the reseal. `agentURI`/`topicID` join the display fields now
        // that the subscription graph itself is sealed.
        payload["displayName"] = FieldValue.delete()
        payload["description"] = FieldValue.delete()
        payload["agentURI"] = FieldValue.delete()
        payload["topicID"] = FieldValue.delete()
        let topicCollection = collection(uid: uid)
        let opaqueID = try Self.documentID(agentURI: topic.agentURI, topicID: topic.topicID, vaultKey: vaultKey)
        try await topicCollection.document(opaqueID).setData(payload, merge: true)
        for legacyID in Self.legacyCleartextDocumentIDs(agentURI: topic.agentURI, topicID: topic.topicID)
            where legacyID != opaqueID {
            try? await topicCollection.document(legacyID).delete()
        }
        mergeLocal(topic)
        lastError = nil
    }

    func unsubscribe(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID
    ) async throws {
        let uid = try currentUserID()
        let id = "\(agentURI):\(topicID)"
        let topicCollection = collection(uid: uid)

        // The authoritative subscription is the sealed doc, whose Firestore id is
        // an opaque HMAC keyed by the vault key. Deleting it REQUIRES the vault
        // key. If the key is transiently unavailable (cross-device write before
        // the wrapper synced, or a vault-key mismatch), we must NOT pretend the
        // unsubscribe succeeded: silently no-oping the delete here while still
        // removing the local row leaves a ghost cloud subscription that the next
        // snapshot resurrects — the user keeps getting opted-out digests behind a
        // success UI. Resolve the key first and fail loudly with a recoverable,
        // jargon-free message so the local row and cloud doc stay consistent.
        let vaultKey: Data
        do {
            guard let resolved = try await MobileCloudVaultKeyAccess
                .keyForReading(uid: uid, firestore: firestoreProvider())?.keyData else {
                lastError = StoreError.vaultKeyUnavailable.errorDescription
                throw StoreError.vaultKeyUnavailable
            }
            vaultKey = resolved
        } catch let error as StoreError {
            throw error
        } catch {
            // A thrown key-access error (locked / not yet synced) is the same
            // recoverable state as a nil key: surface it, do not orphan the doc.
            lastError = StoreError.vaultKeyUnavailable.errorDescription
            throw StoreError.vaultKeyUnavailable
        }

        // Delete the authoritative sealed doc first. Only after it succeeds do we
        // drop the local row, so a delete failure can't leave the UI claiming the
        // user is unsubscribed while the cloud subscription survives. Route
        // through the pure `resolveUnsubscribeDocID` so the live delete and the
        // orphan-prevention test exercise the same decision.
        let opaqueID = try Self.resolveUnsubscribeDocID(
            agentURI: agentURI,
            topicID: topicID,
            vaultKey: vaultKey
        )
        try await topicCollection.document(opaqueID).delete()
        // Best-effort cleanup of any legacy cleartext doc ids (key-independent).
        for legacyID in Self.legacyCleartextDocumentIDs(agentURI: agentURI, topicID: topicID) {
            try? await topicCollection.document(legacyID).delete()
        }
        topics.removeAll { $0.id == id }
        lastError = nil
    }

    func setMuted(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID,
        muted: Bool
    ) async throws {
        let id = "\(agentURI):\(topicID)"
        let existing = topics.first(where: { $0.id == id })
        let deliveryMode: SkillRunDeliveryMode = muted
            ? .muted
            : ((existing?.deliveryMode == .muted) ? .actionOnly : (existing?.deliveryMode ?? .actionOnly))
        guard let existing else { return }
        let updated = SubscriptionTopic(
            agentURI: existing.agentURI,
            topicID: existing.topicID,
            displayName: existing.displayName,
            description: existing.description,
            cadence: existing.cadence,
            consentGivenAt: existing.consentGivenAt,
            isMuted: muted,
            deliveryMode: deliveryMode,
            minimumEventImportance: deliveryMode == .fullStream ? .normal : .actionRequired,
            deliveryCountThisMonth: existing.deliveryCountThisMonth,
            lastDeliveredAt: existing.lastDeliveredAt
        )
        try await upsert(updated)
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
                    guard let self else { return }
                    if let error {
                        self.lastError = error.localizedDescription
                        return
                    }
                    guard let snapshot else { return }
                    // Resolve the vault key once per fire so sealed display
                    // text can be opened; legacy plaintext still decodes when nil.
                    let resolvedKey = try? await MobileCloudVaultKeyAccess
                        .keyForReading(uid: uid, firestore: self.firestoreProvider())
                    let trustedKeys: [String: Data] = if let identity = resolvedKey?.signalIdentity {
                        await MobileCloudVaultSignalPayloads.trustedSenderPublicKeys(
                            uid: uid,
                            firestore: self.firestoreProvider(),
                            localIdentity: identity
                        )
                    } else { [:] }
                    self.topics = snapshot.documents.compactMap { document in
                        let privateData = try? resolvedKey.flatMap { key in
                            try MobileCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                                document.data(),
                                uid: uid,
                                collection: "subscription_topics",
                                docId: document.documentID,
                                signalIdentity: key.signalIdentity,
                                trustedSenderPublicKeys: trustedKeys
                            )
                        }
                        return Self.decodeTopic(
                            documentID: document.documentID,
                            data: document.data(),
                            vaultKey: resolvedKey?.keyData,
                            signalPlaintext: privateData ?? nil
                        )
                    }
                    self.lastError = nil
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

    static func encodeTopic(_ topic: SubscriptionTopic, vaultKey: Data) throws -> [String: Any] {
        // Seal the whole subscription graph. `displayName`/`description` echo
        // which agent the user follows (a behavioral fingerprint); `agentURI`/
        // `topicID` ARE the graph edge — together with the opaque HMAC doc id,
        // sealing them keeps the server from enumerating who the user follows.
        // `cadence`/`consentGivenAt` (+ delivery fields) stay cleartext: they are
        // the server-side order/filter inputs and carry no graph identity.
        // CANONICAL TYPE: `consentGivenAt` is a Firestore Timestamp — the Firebase
        // SDK serializes this Swift `Date?` to a Timestamp, which is the canonical
        // type both platforms converge on and the type `.order(by:)` is designed
        // for. (Firestore sorts mixed-type fields by type-group first, so a Number
        // and a Timestamp would land in separate sort groups; Android now also
        // writes a Timestamp and its old Number docs self-heal on next update.)
        // The reader (`decodeDate`) stays fully type-tolerant so legacy
        // Number/String docs still decode while the corpus converges.
        [
            "sealedAgentURI": try dictionary(CloudVaultCrypto.sealText(topic.agentURI, keyData: vaultKey)),
            "sealedTopicID": try dictionary(CloudVaultCrypto.sealText(topic.topicID, keyData: vaultKey)),
            "sealedDisplayName": try dictionary(CloudVaultCrypto.sealText(topic.displayName, keyData: vaultKey)),
            "sealedDescription": try dictionary(CloudVaultCrypto.sealText(topic.description, keyData: vaultKey)),
            "cadence": topic.cadence.rawValue,
            "consentGivenAt": topic.consentGivenAt ?? NSNull(),
            "isMuted": topic.isMuted,
            "deliveryMode": topic.deliveryMode.rawValue,
            "minimumEventImportance": topic.minimumEventImportance.rawValue,
            "deliveryCountThisMonth": topic.deliveryCountThisMonth,
            "lastDeliveredAt": topic.lastDeliveredAt ?? NSNull()
        ]
    }

    /// Opaque, vault-keyed Firestore doc id for a topic. Replaces the legacy
    /// human-readable `agentURI:topicID` (with `/`,`:`→`_`) so the server can no
    /// longer enumerate which agents the user follows. Deterministic for a given
    /// `(agentURI, topicID, vaultKey)` — unsubscribe-by-id and upsert idempotency
    /// are preserved. Crypto lives in `CloudVaultCrypto.subscriptionDocID`.
    static func documentID(agentURI: String, topicID: String, vaultKey: Data) throws -> String {
        try CloudVaultCrypto.subscriptionDocID(agentURI: agentURI, topicID: topicID, keyData: vaultKey)
    }

    /// Pure decision for `unsubscribe`: resolve the authoritative sealed doc id
    /// to delete, or throw `vaultKeyUnavailable` when the vault key is missing.
    /// Extracted so the orphan-prevention is unit-testable without Firestore:
    /// a nil key MUST throw (never silently return a no-op) so the caller cannot
    /// drop the local row while the cloud subscription survives. Returns the
    /// opaque doc id when the key is present.
    static func resolveUnsubscribeDocID(
        agentURI: String,
        topicID: String,
        vaultKey: Data?
    ) throws -> String {
        guard let vaultKey else {
            throw StoreError.vaultKeyUnavailable
        }
        return try documentID(agentURI: agentURI, topicID: topicID, vaultKey: vaultKey)
    }

    static func legacyCleartextDocumentIDs(agentURI: String, topicID: String) -> [String] {
        let raw = "\(agentURI):\(topicID)"
        let slashOnly = raw.replacingOccurrences(of: "/", with: "_")
        let slashAndColon = slashOnly.replacingOccurrences(of: ":", with: "_")
        let collapsed = raw
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return Array(Set([slashOnly, slashAndColon, collapsed].filter { !$0.isEmpty && !$0.contains("/") }))
            .sorted()
    }

    static func decodeTopic(
        documentID: String,
        data: [String: Any],
        vaultKey: Data?,
        signalPlaintext: Data? = nil
    ) -> SubscriptionTopic? {
        if let signalPlaintext,
           let signalTopic = try? JSONDecoder().decode(SubscriptionTopic.self, from: signalPlaintext) {
            return signalTopic
        }
        if data["signalEnvelope"] != nil,
           MobileCloudVaultSignalPayloads.signalSealingIsRequired(domainID: "conversations_chat") {
            return nil
        }
        // Open the sealed graph edge, falling back to legacy plaintext for
        // pre-migration / in-flight documents.
        let agentURI = (openSealedString(
            data: data,
            sealedField: "sealedAgentURI",
            legacyField: "agentURI",
            vaultKey: vaultKey
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topicID = (openSealedString(
            data: data,
            sealedField: "sealedTopicID",
            legacyField: "topicID",
            vaultKey: vaultKey
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Open the sealed display text, falling back to legacy plaintext for
        // pre-migration / in-flight documents.
        let displayName = (openSealedString(
            data: data,
            sealedField: "sealedDisplayName",
            legacyField: "displayName",
            vaultKey: vaultKey
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = (openSealedString(
            data: data,
            sealedField: "sealedDescription",
            legacyField: "description",
            vaultKey: vaultKey
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !agentURI.isEmpty, !topicID.isEmpty else { return nil }

        let cadenceRaw = (data["cadence"] as? String) ?? AgentManifest.PushTopic.Cadence.weekly.rawValue
        let cadence = AgentManifest.PushTopic.Cadence(rawValue: cadenceRaw) ?? .weekly
        let consentGivenAt = decodeDate(data["consentGivenAt"])
        let isMuted = (data["isMuted"] as? Bool) ?? false
        let deliveryModeRaw = (data["deliveryMode"] as? String) ?? SkillRunDeliveryMode.actionOnly.rawValue
        let deliveryMode = SkillRunDeliveryMode(rawValue: deliveryModeRaw) ?? .actionOnly
        let eventImportanceRaw = (data["minimumEventImportance"] as? String)
            ?? (deliveryMode == .fullStream
                ? SkillRunEventImportance.normal.rawValue
                : SkillRunEventImportance.actionRequired.rawValue)
        let minimumEventImportance = SkillRunEventImportance(rawValue: eventImportanceRaw) ?? .actionRequired
        let deliveryCount = (data["deliveryCountThisMonth"] as? Int) ?? 0
        let lastDeliveredAt = decodeDate(data["lastDeliveredAt"])

        // Display fallback: the doc id is now an opaque vault-keyed HMAC, not
        // human text, so it can no longer stand in for a missing display name.
        // Fall back to the (decoded) agent URI — never to the opaque doc id.
        let topic = SubscriptionTopic(
            agentURI: agentURI,
            topicID: topicID,
            displayName: displayName.isEmpty ? agentURI : displayName,
            description: description,
            cadence: cadence,
            consentGivenAt: consentGivenAt,
            isMuted: isMuted,
            deliveryMode: isMuted ? .muted : deliveryMode,
            minimumEventImportance: minimumEventImportance,
            deliveryCountThisMonth: deliveryCount,
            lastDeliveredAt: lastDeliveredAt
        )
        return topic
    }

    // MARK: - Seal helpers

    /// Opens a sealed-text field, falling back to a legacy plaintext field only
    /// when the sealed field is absent. A present sealed field is authoritative:
    /// decrypt it or fail closed instead of leaking a stale plaintext sibling.
    private static func openSealedString(
        data: [String: Any],
        sealedField: String,
        legacyField: String,
        vaultKey: Data?
    ) -> String? {
        if let envelope = sealedText(from: data[sealedField]) {
            guard let vaultKey else { return nil }
            return try? CloudVaultCrypto.openText(envelope, keyData: vaultKey)
        }
        return data[legacyField] as? String
    }

    /// Encodes a `CloudVaultSealedText` envelope into a Firestore-compatible
    /// dictionary. Mirrors the adjacent sealed-text sync services.
    private static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return [:] }
        return dictionary
    }

    /// Decodes a stored sealed-text dictionary back into a `CloudVaultSealedText`.
    private static func sealedText(from value: Any?) -> CloudVaultSealedText? {
        guard let dictionary = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return nil
        }
        return try? JSONDecoder().decode(CloudVaultSealedText.self, from: data)
    }

    private static func decodeDate(_ raw: Any?) -> Date? {
        if raw is NSNull { return nil }
        if let ts = raw as? Timestamp { return ts.dateValue() }
        if let date = raw as? Date { return date }
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1000.0)
        }
        if let str = raw as? String {
            return ISO8601DateFormatter().date(from: str)
        }
        return nil
    }

    enum StoreError: LocalizedError {
        case firebaseUnavailable
        case notAuthenticated
        case vaultKeyUnavailable

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable:
                return "Firebase is not configured on this device."
            case .notAuthenticated:
                return "Sign in to manage subscription topics."
            case .vaultKeyUnavailable:
                // Recoverable, jargon-free: unlocking lets us finish the change.
                return "Unlock BurnBar on this device to update your subscriptions, then try again."
            }
        }
    }
}

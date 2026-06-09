#if canImport(AppKit)
import CryptoKit
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

final class AgentCapabilityGrantQueueListener: @unchecked Sendable {
    static let shared = AgentCapabilityGrantQueueListener()

    private let firestoreProvider: @Sendable () -> Firestore
    private let validator = PhoneControlAuthorityValidator()
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var listener: ListenerRegistration?
    private var activeUID: String?

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func start() {
        guard authHandle == nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.restart(uid: user?.uid)
        }
        restart(uid: Auth.auth().currentUser?.uid)
    }

    func stop() {
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
        authHandle = nil
        listener?.remove()
        listener = nil
        activeUID = nil
    }

    private func restart(uid: String?) {
        listener?.remove()
        listener = nil
        activeUID = uid
        guard let uid, !uid.isEmpty else { return }
        listener = firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("agent_capability_grant_requests")
            .whereField("status", isEqualTo: AgentGrantDecisionStatus.queued.rawValue)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let snapshot else { return }
                for change in snapshot.documentChanges where change.type == .added || change.type == .modified {
                    Task { await self.process(document: change.document, uid: uid) }
                }
            }
    }

    private func process(document: QueryDocumentSnapshot, uid: String) async {
        do {
            let wireRequest = try decodeWireRequest(from: document.data())
            let receipt = try await verifiedReceipt(for: wireRequest, uid: uid)
            try await write(receipt: receipt, to: document.reference)
        } catch {
            let receipt = fallbackReceipt(from: document.data(), message: error.localizedDescription)
            try? await write(receipt: receipt, to: document.reference)
        }
    }

    private func verifiedReceipt(
        for wireRequest: HermesRealtimeRelayAgentGrantRequest,
        uid: String
    ) async throws -> AgentCapabilityGrantReceipt {
        let authority = try await authorityPublicKey(uid: uid, sourceDeviceID: wireRequest.sourceDeviceId)
        guard authority.peerNodeId == wireRequest.authority.peerNodeId else {
            throw QueueError.authorityMismatch
        }
        // F1: the agent-grant authority key rides the SAME controller pin as
        // phone-control intents. A refused registration (unpinned-under-enforcement
        // or a key that differs from the operator-pinned key) must short-circuit
        // to a denied receipt — never validate a grant signed by an unverified key.
        guard validator.registerPeer(nodeId: authority.peerNodeId, publicKey: authority.publicKey, uid: uid) else {
            throw QueueError.untrustedControllerKey
        }
        _ = try validator.validate(
            envelope: wireRequest.authority,
            grantRequest: wireRequest,
            now: Date()
        )
        let request = try AgentCapabilityGrantRequest(wire: wireRequest)
        return await AgentCapabilityGrantStore.shared.apply(request)
    }

    private func authorityPublicKey(
        uid: String,
        sourceDeviceID: String
    ) async throws -> (peerNodeId: String, publicKey: Curve25519.Signing.PublicKey) {
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("agent_grant_authorities")
            .document(sourceDeviceID)
            .getDocument()
        guard let data = snapshot.data(),
              let peerNodeId = data["peerNodeId"] as? String,
              let publicKeyBase64 = data["publicKeyBase64"] as? String,
              let raw = Data(base64Encoded: publicKeyBase64) else {
            throw QueueError.missingAuthority
        }
        return (peerNodeId, try Curve25519.Signing.PublicKey(rawRepresentation: raw))
    }

    private func decodeWireRequest(from data: [String: Any]) throws -> HermesRealtimeRelayAgentGrantRequest {
        let keys = [
            "requestId", "runtime", "threadId", "preset", "capabilities",
            "trustMode", "deliveryMode", "requestedAt", "expiresAt",
            "grantDurationSeconds", "sourceDeviceId", "clientIntentId",
            "localAuthenticationSatisfied", "authority"
        ]
        var payload: [String: Any] = [:]
        for key in keys {
            if let value = data[key] {
                payload[key] = value
            }
        }
        let json = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(HermesRealtimeRelayAgentGrantRequest.self, from: json)
    }

    private func write(
        receipt: AgentCapabilityGrantReceipt,
        to reference: DocumentReference
    ) async throws {
        try await reference.setData([
            "status": receipt.status.rawValue,
            "receipt": try jsonObject(from: receipt.wire()),
            "updatedAt": Timestamp(date: Date())
        ], merge: true)
    }

    private func fallbackReceipt(
        from data: [String: Any],
        message: String
    ) -> AgentCapabilityGrantReceipt {
        let runtime = (data["runtime"] as? String).flatMap(AssistantRuntimeID.init(rawValue:)) ?? .hermes
        let trustMode = (data["trustMode"] as? String).flatMap(ComputerUseTrustMode.init(rawValue:)) ?? .manual
        let capabilities = Set((data["capabilities"] as? [String] ?? []).compactMap(AgentDesktopCapability.init(rawValue:)))
        return AgentCapabilityGrantReceipt(
            requestID: data["requestId"] as? String ?? UUID().uuidString,
            runtimeID: runtime,
            threadID: data["threadId"] as? String ?? "",
            status: .denied,
            capabilities: capabilities,
            trustMode: trustMode,
            receivedAt: Date(),
            sourceDeviceID: data["sourceDeviceId"] as? String,
            denialReason: .signatureFailure,
            message: message
        )
    }

    private func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    enum QueueError: Error {
        case missingAuthority
        case authorityMismatch
        /// The grant authority's signing key was refused by the F1 controller
        /// pin (unpinned-under-enforcement or a key that differs from the
        /// operator-pinned key). The caller writes a denied receipt.
        case untrustedControllerKey
    }
}
#endif

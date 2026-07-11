#if canImport(AppKit)
import CryptoKit
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

@MainActor
final class AgentCapabilityGrantQueueListener {
    static let shared = AgentCapabilityGrantQueueListener()

    /// Writes the receipt payload for `requestPath` to the backing store.
    /// Injected so the receipt-write path (including the denied-receipt write
    /// in `process`'s catch block) is exercisable without a live Firestore
    /// `DocumentReference`. `requestPath` is used only for log correlation.
    typealias ReceiptPayloadWriter = @MainActor @Sendable (
        _ requestPath: String,
        _ payload: [String: Any]
    ) async throws -> Void
    typealias DaemonPinProvisioner = @Sendable (
        _ request: DaemonPhoneControlPinProvisionRequest
    ) async throws -> Void

    private let firestoreProvider: @Sendable () -> Firestore
    private let receiptWriter: ReceiptPayloadWriter
    private let validator = PhoneControlAuthorityValidator()
    private let daemonPinProvisioner: DaemonPinProvisioner
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var listener: ListenerRegistration?
    private var activeUID: String?

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        receiptWriter: ReceiptPayloadWriter? = nil,
        daemonPinProvisioner: DaemonPinProvisioner? = nil
    ) {
        self.firestoreProvider = firestoreProvider
        self.daemonPinProvisioner = daemonPinProvisioner ?? { request in
            _ = try await OpenBurnBarDaemonManager.shared.provisionPhoneControlPin(request)
        }
        // Default writer: persists the receipt payload to the Firestore
        // document at `requestPath` (merging so the original request fields
        // survive) via the same provider the listener reads through.
        self.receiptWriter = receiptWriter ?? { requestPath, payload in
            try await firestoreProvider().document(requestPath).setData(payload, merge: true)
        }
    }

    func start() {
        guard authHandle == nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            // The auth callback is not guaranteed to run on the main thread, and
            // `restart` mutates main-actor-isolated state — marshal explicitly
            // (mirrors the snapshot-listener hop below).
            Task { @MainActor in self?.restart(uid: user?.uid) }
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
        let requestPath = document.reference.path
        do {
            let wireRequest = try decodeWireRequest(from: document.data())
            let receipt = try await verifiedReceipt(for: wireRequest, uid: uid)
            try await write(receipt: receipt, to: requestPath)
        } catch {
            await writeDenialReceipt(
                forData: document.data(),
                message: error.localizedDescription,
                to: requestPath
            )
        }
    }

    /// Writes the authoritative DENIED receipt for a request that failed
    /// verification. The receipt is the security decision returned to the
    /// requesting device, and a failed write leaves the request `.queued`
    /// (so it can be re-processed) — that loss MUST be observable rather than
    /// swallowed. We do not propagate: a throw here would only crash the
    /// detached `process` Task, never reaching a requester, so the durable
    /// failure is the error log. This never falls open: the receipt is already
    /// a denial; a missing write withholds approval, it never grants it.
    func writeDenialReceipt(
        forData data: [String: Any],
        message: String,
        to requestPath: String
    ) async {
        let receipt = fallbackReceipt(from: data, message: message)
        do {
            try await write(receipt: receipt, to: requestPath)
        } catch {
            AppLogger.daemon.error(
                "agentGrant.denialReceiptWriteFailed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: error)))",
                    "denialReason": receipt.denialReason?.rawValue ?? "unknown",
                    "status": receipt.status.rawValue
                ]
            )
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
        guard validator.registerPeer(
            nodeId: authority.peerNodeId,
            verifyingKey: authority.publicKey,
            uid: uid,
            requiredAttestationHashBlake3: authority.requiredAttestationHashBlake3
        ) else {
            throw QueueError.untrustedControllerKey
        }
        _ = try validator.validate(
            envelope: wireRequest.authority,
            grantRequest: wireRequest,
            attestation: authority.requiredAttestationHashBlake3.map { .required(digest: $0) },
            now: Date()
        )
        try await daemonPinProvisioner(
            DaemonPhoneControlPinProvisionRequest(
                deviceId: wireRequest.sourceDeviceId,
                peerNodeId: authority.peerNodeId,
                publicKeyBase64: authority.publicKey.publicKeyRepresentation.base64EncodedString(),
                keyKind: authority.publicKey.kind
            )
        )
        let request = try AgentCapabilityGrantRequest(wire: wireRequest)
        return await AgentCapabilityGrantStore.shared.apply(request)
    }

    private func authorityPublicKey(
        uid: String,
        sourceDeviceID: String
    ) async throws -> (peerNodeId: String, publicKey: PhoneControlVerifyingKey, requiredAttestationHashBlake3: String?) {
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
        let keyKind = try Self.signingKeyKind(fromRecordValue: data["signingKeyKind"] as? String)
        return (
            peerNodeId,
            try PhoneControlVerifyingKey(kind: keyKind, publicKeyRepresentation: raw),
            Self.normalizedAttestationDigest(data["appCheckAttestationHashBlake3"] as? String)
        )
    }

    /// F2: `signingKeyKind` mirrors the controller record. Absent ⇒ legacy
    /// Ed25519; present-but-unrecognized fails closed (no silent downgrade).
    nonisolated static func signingKeyKind(fromRecordValue kindRaw: String?) throws -> PhoneControlSigningKeyKind {
        guard let kindRaw else { return .ed25519 }
        guard let parsed = PhoneControlSigningKeyKind(rawValue: kindRaw) else {
            throw QueueError.missingAuthority
        }
        return parsed
    }

    nonisolated static func normalizedAttestationDigest(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private func decodeWireRequest(from data: [String: Any]) throws -> HermesRealtimeRelayAgentGrantRequest {
        let keys = [
            "requestId", "runtime", "threadId", "preset", "capabilities",
            "trustMode", "deliveryMode", "requestedAt", "expiresAt",
            "grantDurationSeconds", "sourceDeviceId", "clientIntentId",
            "localAuthenticationSatisfied", "localAuthProof", "authority"
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
        to requestPath: String
    ) async throws {
        let payload: [String: Any] = [
            "status": receipt.status.rawValue,
            "receipt": try jsonObject(from: receipt.wire()),
            "updatedAt": Timestamp(date: Date())
        ]
        try await receiptWriter(requestPath, payload)
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

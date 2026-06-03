#if canImport(AppKit)
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Process-scoped Firestore listener on `users/{uid}/escrow_devices`.
///
/// On `trustState -> revoked` it resolves the device's paired peer node id
/// and hands both identifiers to the coordinator, which (1) populates the
/// PhoneControlAuthorityValidator revocation sets — so future input intents,
/// agent-grant requests, and reconnect registrations all fail closed — and
/// (2) tears down any in-flight live session owned by that peer via panicHalt.
///
/// Mirrors `AgentCapabilityGrantQueueListener` (auth-state listener + restart
/// per uid + single snapshot listener) so lifecycle and back-compat match.
@MainActor
final class EscrowRevocationWatcher {
    typealias RevocationHandler = @MainActor (_ deviceId: String, _ peerNodeId: String?) async -> Void

    private let firestoreProvider: @Sendable () -> Firestore
    private let onRevoked: RevocationHandler
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var listener: ListenerRegistration?
    private var activeUID: String?
    /// Device ids already actioned this session — avoids re-firing teardown
    /// on every unrelated snapshot delta.
    private var revokedDeviceIds: Set<String> = []

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        onRevoked: @escaping RevocationHandler
    ) {
        self.firestoreProvider = firestoreProvider
        self.onRevoked = onRevoked
    }

    func start() {
        guard authHandle == nil else { return }
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.restart(uid: user?.uid) }
        }
        restart(uid: Auth.auth().currentUser?.uid)
    }

    func stop() {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
        authHandle = nil
        listener?.remove()
        listener = nil
        activeUID = nil
        revokedDeviceIds.removeAll()
    }

    private func restart(uid: String?) {
        listener?.remove()
        listener = nil
        revokedDeviceIds.removeAll()
        activeUID = uid
        guard let uid, !uid.isEmpty else { return }
        listener = firestoreProvider()
            .collection("users").document(uid)
            .collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.revoked.rawValue)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self, let snapshot else { return }
                Task { @MainActor in await self.handle(snapshot: snapshot, uid: uid) }
            }
    }

    private func handle(snapshot: QuerySnapshot, uid: String) async {
        for doc in snapshot.documents {
            let deviceId = doc.documentID
            guard !revokedDeviceIds.contains(deviceId) else { continue }
            revokedDeviceIds.insert(deviceId)
            let peerNodeId = await resolvePeerNodeId(uid: uid, deviceId: deviceId, deviceData: doc.data())
            await onRevoked(deviceId, peerNodeId)
        }
    }

    /// Best-effort peer-node resolution. The escrow device doc may carry
    /// `peerNodeId` directly; otherwise fall back to the agent-grant authority
    /// mapping keyed by the same device id. nil is acceptable — escrow-device
    /// revocation still fails closed on the grant path even without a peer.
    private func resolvePeerNodeId(uid: String, deviceId: String, deviceData: [String: Any]) async -> String? {
        if let direct = deviceData["peerNodeId"] as? String, !direct.isEmpty { return direct }
        let authority = try? await firestoreProvider()
            .collection("users").document(uid)
            .collection("agent_grant_authorities").document(deviceId)
            .getDocument()
        if let peer = authority?.data()?["peerNodeId"] as? String, !peer.isEmpty { return peer }
        return nil
    }
}
#endif

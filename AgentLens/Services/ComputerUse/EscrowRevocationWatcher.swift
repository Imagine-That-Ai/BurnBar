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

    /// Resolves the paired peer node id for an escrow device by reading the
    /// agent-grant authority mapping. Injectable so tests exercise the
    /// fail-closed path without a live Firestore. Returns `nil` for a genuinely
    /// peer-less authority doc; *throws* on a fetch fault so the caller can
    /// distinguish "no peer" from "could not determine the peer".
    typealias AuthorityPeerNodeIdProvider =
        @Sendable (_ uid: String, _ deviceId: String) async throws -> String?

    /// Outcome of peer resolution. The live-session teardown in the coordinator
    /// only fires for a *resolved* peer, so a fetch fault must never collapse to
    /// `noPeer` (that would silently fail open on the teardown lane). We keep the
    /// device unactioned and retry on the next snapshot instead.
    private enum PeerResolution {
        case resolved([String])
        case noPeer
        case unresolvable
    }

    private let firestoreProvider: @Sendable () -> Firestore
    private let authorityPeerNodeIdProvider: AuthorityPeerNodeIdProvider
    private let onRevoked: RevocationHandler
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var listener: ListenerRegistration?
    private var activeUID: String?
    /// Device ids already actioned this session — avoids re-firing teardown
    /// on every unrelated snapshot delta. A device is only recorded here once
    /// its peer was resolved *definitively* (a real peer or a confirmed absence),
    /// so a fetch fault leaves it eligible for re-resolution on the next delta.
    private var revokedDeviceIds: Set<String> = []

    /// Bounded in-resolution retry to ride out a transient Firestore blip before
    /// declaring a peer unresolvable. The revocation snapshot may not re-fire for
    /// an already-`revoked` doc, so recovering here is what keeps the teardown
    /// lane fail-closed against intermittent network faults.
    private let peerFetchMaxAttempts: Int
    private let peerFetchRetryDelay: Duration

    init(
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        authorityPeerNodeIdProvider: AuthorityPeerNodeIdProvider? = nil,
        peerFetchMaxAttempts: Int = 3,
        peerFetchRetryDelay: Duration = .milliseconds(250),
        onRevoked: @escaping RevocationHandler
    ) {
        self.firestoreProvider = firestoreProvider
        self.onRevoked = onRevoked
        self.peerFetchMaxAttempts = max(1, peerFetchMaxAttempts)
        self.peerFetchRetryDelay = peerFetchRetryDelay
        if let authorityPeerNodeIdProvider {
            self.authorityPeerNodeIdProvider = authorityPeerNodeIdProvider
        } else {
            // Default seam: read the agent-grant authority doc keyed by device id.
            self.authorityPeerNodeIdProvider = { uid, deviceId in
                let snapshot = try await firestoreProvider()
                    .collection("users").document(uid)
                    .collection("agent_grant_authorities").document(deviceId)
                    .getDocument()
                let peer = snapshot.data()?["peerNodeId"] as? String
                return (peer?.isEmpty == false) ? peer : nil
            }
        }
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

    func handle(snapshot: QuerySnapshot, uid: String) async {
        for doc in snapshot.documents {
            await processRevokedDevice(uid: uid, deviceId: doc.documentID, deviceData: doc.data())
        }
    }

    /// Action a single revoked escrow-device doc. Split out from `handle` so the
    /// security-critical resolve→dispatch decision is exercisable in tests with
    /// plain dictionaries (a live `QuerySnapshot` cannot be synthesized).
    func processRevokedDevice(uid: String, deviceId: String, deviceData: [String: Any]) async {
        guard !revokedDeviceIds.contains(deviceId) else { return }
        let resolution = await resolvePeerNodeId(
            uid: uid,
            deviceId: deviceId,
            deviceData: deviceData
        )
        switch resolution {
        case .resolved(let peerNodeIds):
            revokedDeviceIds.insert(deviceId)
            for peerNodeId in peerNodeIds {
                await onRevoked(deviceId, peerNodeId)
            }
        case .noPeer:
            revokedDeviceIds.insert(deviceId)
            await onRevoked(deviceId, nil)
        case .unresolvable:
            // SECURITY: a fetch fault must not silently degrade to a
            // peer-less teardown skip. Drive the grant-path revocation now
            // (the coordinator fails that lane closed regardless of peer),
            // but leave the device UNRECORDED so the next snapshot delta —
            // or a manual re-listen — re-attempts peer resolution and can
            // still tear down the in-flight session. We never mark it done
            // on an error, which is what keeps the teardown lane fail-closed.
            AppLogger.daemon.error(
                "escrowRevocation.peerUnresolvedRetryPending",
                metadata: [
                    "deviceId": deviceId,
                    "attempts": "\(peerFetchMaxAttempts)"
                ]
            )
            await onRevoked(deviceId, nil)
        }
    }

    /// Resolve all revoked device peer node ids.
    ///
    /// The escrow device doc may carry historical `peerNodeIds` plus the legacy
    /// `peerNodeId` directly; otherwise we read the agent-grant authority
    /// mapping keyed by the same device id. A genuine
    /// absence (`noPeer`) is safe — the grant path still fails closed without a
    /// peer. A *fetch fault* is reported as `unresolvable` (after a bounded
    /// retry), never as `noPeer`, so the live-session teardown lane can react
    /// instead of silently treating the revoked peer as absent.
    private func resolvePeerNodeId(
        uid: String,
        deviceId: String,
        deviceData: [String: Any]
    ) async -> PeerResolution {
        let directPeerNodeIds = normalizedPeerNodeIds(
            primary: deviceData["peerNodeId"],
            historical: deviceData["peerNodeIds"]
        )
        if !directPeerNodeIds.isEmpty {
            return .resolved(directPeerNodeIds)
        }

        var lastError: Error?
        for attempt in 1...peerFetchMaxAttempts {
            do {
                if let peer = try await authorityPeerNodeIdProvider(uid, deviceId), !peer.isEmpty {
                    return .resolved([peer])
                }
                // A successful read with no peer is a definitive absence.
                return .noPeer
            } catch {
                lastError = error
                if attempt < peerFetchMaxAttempts {
                    // Task.sleep only throws on cancellation; a cancelled backoff
                    // harmlessly proceeds to the next attempt (or exits the bounded
                    // loop). No security signal rides on the sleep itself.
                    try? await Task.sleep(for: peerFetchRetryDelay) // try?-ok(backoff cancellation only)
                }
            }
        }

        if let lastError {
            AppLogger.daemon.error(
                "escrowRevocation.authorityFetchFailed",
                metadata: [
                    "errorClass": "\(String(describing: type(of: lastError)))",
                    "deviceId": deviceId,
                    "attempts": "\(peerFetchMaxAttempts)"
                ]
            )
        }
        return .unresolvable
    }

    private func normalizedPeerNodeIds(primary: Any?, historical: Any?) -> [String] {
        var ids: [String] = []
        func append(_ value: Any?) {
            guard let raw = value as? String else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ids.contains(trimmed) else { return }
            ids.append(trimmed)
        }
        if let values = historical as? [Any] {
            for value in values { append(value) }
        }
        append(primary)
        return ids
    }
}
#endif

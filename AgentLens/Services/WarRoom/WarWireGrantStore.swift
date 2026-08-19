import Foundation
import Observation
import OpenBurnBarKernel
@preconcurrency import FirebaseFirestore

/// Live view of `users/{uid}/war_wire_grants` — the mutual-consent records that
/// let two of the account's Macs open the Wire (§ The Wire of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// The store only *supplies* consent; it never decides. Every admission
/// question goes through `WarWireGate`, so the dialing Mac and the answering
/// Mac reach the same verdict from the same pure evaluation.
@MainActor
@Observable
final class WarWireGrantStore {
    /// Grants keyed by canonical pair id, so a lookup is order-independent.
    private(set) var grantsByPairID: [String: WarWireGrant] = [:]
    private(set) var hasLoaded = false

    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    @ObservationIgnored private var listener: ListenerRegistration?
    @ObservationIgnored private var listenerUID: String?

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager = .shared
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
    }

    func start() {
        guard accountManager.isFirebaseAvailable,
              let uid = accountManager.currentUID else {
            stop()
            return
        }
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        // Grants belong to an account: switching accounts starts from consent
        // zero rather than carrying the previous account's cache.
        grantsByPairID = [:]
        hasLoaded = false
        listener = collection(uid: uid).addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor [weak self] in
                self?.apply(documents: snapshot?.documents.map { $0.data() }, error: error)
            }
        }
    }

    /// Listener seam: parses a snapshot's documents, or fails closed on error.
    /// Unverifiable consent reads as revoked — a failing listener clears the
    /// cache so the Wire closes instead of trusting grants it can no longer
    /// confirm.
    func apply(documents: [[String: Any]]?, error: Error?) {
        if let error {
            AppLogger.network.silentFailure("war_wire_grants_listen_failed", error: error)
            grantsByPairID = [:]
            hasLoaded = false
            return
        }
        var parsed: [String: WarWireGrant] = [:]
        for data in documents ?? [] {
            guard let grant = Self.grant(from: data) else { continue }
            parsed[grant.pairID] = grant
        }
        grantsByPairID = parsed
        hasLoaded = true
    }

    func stop() {
        listener?.remove()
        listener = nil
        listenerUID = nil
        // A stopped store can no longer verify consent; fail closed.
        grantsByPairID = [:]
        hasLoaded = false
    }

    func grant(between first: String, and second: String) -> WarWireGrant? {
        grantsByPairID[WarWireGrant.pairID(first, second)]
    }

    /// The single admission question the Wire asks. Fail-closed by delegation:
    /// an unloaded store yields no grant, and no grant is a denial.
    func decision(localBodyID: String, remoteBodyID: String, tier: CloudTier) -> WarWireDecision {
        WarWireGate.evaluate(
            localBodyID: localBodyID,
            remoteBodyID: remoteBodyID,
            tier: tier,
            killSwitchEngaged: settingsManager.warRoomKillSwitch,
            grant: grant(between: localBodyID, and: remoteBodyID)
        )
    }

    /// Open the Wire between two of this account's Macs. Endpoints are stored
    /// sorted because the rules enforce `bodyIdA < bodyIdB` and derive the
    /// document id from the pair.
    func grantWire(between first: String, and second: String) async {
        guard let uid = signedInUID(), let pair = Self.sortedPair(first, second) else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let reference = collection(uid: uid).document(pair.id)
        var payload: [String: Any] = [
            "id": pair.id,
            "bodyIdA": pair.a,
            "bodyIdB": pair.b,
            "state": WarWireGrant.State.active.rawValue,
            "grantedByDeviceID": accountManager.deviceId,
            "grantedAt": now,
            "schemaVersion": 1,
            "updatedAt": now
        ]
        do {
            // A re-grant after a revoke must clear the revocation stamps rather
            // than leave a document that claims to be both active and revoked.
            let snapshot = try await reference.getDocument()
            if snapshot.exists {
                payload["revokedByDeviceID"] = FieldValue.delete()
                payload["revokedAt"] = FieldValue.delete()
            } else {
                payload["createdAt"] = now
            }
            try await reference.setData(payload, merge: true)
        } catch {
            AppLogger.network.silentFailure("war_wire_grant_failed", error: error)
        }
    }

    /// Revoke from either machine. The pair is preserved; only the state moves.
    func revokeWire(between first: String, and second: String) async {
        guard let uid = signedInUID(), let pair = Self.sortedPair(first, second) else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try await collection(uid: uid).document(pair.id).setData([
                "state": WarWireGrant.State.revoked.rawValue,
                "revokedByDeviceID": accountManager.deviceId,
                "revokedAt": now,
                "updatedAt": now
            ], merge: true)
        } catch {
            AppLogger.network.silentFailure("war_wire_revoke_failed", error: error)
        }
    }

    private func signedInUID() -> String? {
        guard accountManager.isFirebaseAvailable, accountManager.isSignedIn else { return nil }
        return accountManager.currentUID
    }

    private func collection(uid: String) -> CollectionReference {
        WarRoomFirestoreGateway.grants(uid: uid)
    }

    /// Canonical endpoint ordering + document id, or nil when the pair is not
    /// two distinct, non-empty bodies.
    nonisolated static func sortedPair(_ first: String, _ second: String) -> (id: String, a: String, b: String)? {
        let left = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty, left != right else { return nil }
        let sorted = [left, right].sorted()
        return (WarWireGrant.pairID(left, right), sorted[0], sorted[1])
    }

    nonisolated static func grant(from data: [String: Any]) -> WarWireGrant? {
        guard let bodyIdA = data["bodyIdA"] as? String, !bodyIdA.isEmpty,
              let bodyIdB = data["bodyIdB"] as? String, !bodyIdB.isEmpty else { return nil }
        // Unverifiable state reads as revoked — the Wire never opens on a
        // document it cannot fully understand.
        let state = (data["state"] as? String)
            .flatMap(WarWireGrant.State.init(rawValue:)) ?? .revoked
        return WarWireGrant(bodyIDA: bodyIdA, bodyIDB: bodyIdB, state: state)
    }
}

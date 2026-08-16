import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

// MARK: - Mission group observation, merge, approval + cancel
//
// Split out of `CLIAgentMissionDispatcher.swift` (audit wave 4, item 14
// structural decomposition). Pure move — no behavior change.

extension CLIAgentMissionDispatcher {
    // MARK: - Mission group observation

    /// Subscribe to the newest mission group so a completed or in-flight Wand
    /// run returns after the app is relaunched.
    func observeLatestMissionGroup(
        onUpdate: @escaping @MainActor (MissionGroupDocument) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        let localVaultKey: Data?
        do {
            localVaultKey = try CloudVaultKeyStore().loadKey(uid: uid)
        } catch {
            localVaultKey = nil
        }
        let query = firestoreProvider()
            .collection("users").document(uid)
            .collection("mission_groups")
            .order(by: "createdAt", descending: true)
            .limit(to: 1)
        let registration = query.addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error.localizedDescription) }
                return
            }
            guard let snapshot = snapshot?.documents.first else { return }
            guard let doc = MissionGroupDocument(
                documentID: snapshot.documentID,
                data: snapshot.data(),
                vaultKey: localVaultKey
            ) else { return }
            Task { @MainActor in onUpdate(doc) }
        }
        return CLIAgentMissionObservation(registrations: [registration])
    }

    /// Subscribe to live updates of a mission group document. Returns an
    /// observation handle the caller stores for cancellation. Hits the
    /// `users/{uid}/mission_groups/{id}` doc.
    func observeMissionGroup(
        groupID: String,
        onUpdate: @escaping @MainActor (MissionGroupDocument) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        let localVaultKey: Data?
        do {
            localVaultKey = try CloudVaultKeyStore().loadKey(uid: uid)
        } catch {
            localVaultKey = nil
        }
        let ref = firestoreProvider()
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
        let registration = ref.addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error.localizedDescription) }
                return
            }
            guard let data = snapshot?.data() else { return }
            guard let doc = MissionGroupDocument(documentID: groupID, data: data, vaultKey: localVaultKey) else { return }
            Task { @MainActor in onUpdate(doc) }
        }
        return CLIAgentMissionObservation(registrations: [registration])
    }

    /// Apply the user's merge choice. Sets `phase = merged`, records
    /// `winnerMissionID`, and optionally seals a `synthesisSummary` into
    /// `sealedStatePayload`.
    ///
    /// `synthesisSummary` is private user-facing text, so it is NEVER written
    /// as a top-level plaintext field — `validMissionGroup` (firestore.rules)
    /// rejects a top-level `synthesisSummary` and the seal mirrors Android's
    /// `sealGroupPayload`/`sealedMissionStateUpdate` shape. The reader
    /// (`MissionGroupDocument`) already opens `sealedStatePayload` for the
    /// synthesis with a legacy top-level fallback during migration.
    func mergeMissionGroup(
        groupID: String,
        winnerMissionID: String?,
        synthesisSummary: String?
    ) async throws {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        let db = firestoreProvider()
        let update: [String: Any]
        if let synthesisSummary {
            // Sealing the synthesis requires the writable vault key; mirror the
            // dispatch path so a merge after dispatch always re-seals locally.
            let resolvedKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: db)
            update = try Self.mergeMissionGroupUpdate(
                winnerMissionID: winnerMissionID,
                synthesisSummary: synthesisSummary,
                vaultKey: resolvedKey.keyData,
                vaultKeyID: resolvedKey.vaultKeyID
            )
        } else {
            update = Self.mergeMissionGroupUpdate(winnerMissionID: winnerMissionID)
        }
        try await db
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
            .setData(update, merge: true)
    }

    /// Build the merge update WITHOUT a synthesis summary (no seal needed).
    /// Writes only non-private fields: `phase`, `winnerMissionID`, `updatedAt`.
    static func mergeMissionGroupUpdate(winnerMissionID: String?) -> [String: Any] {
        var update: [String: Any] = [
            "phase": MissionGroupPhase.merged.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let winnerMissionID { update["winnerMissionID"] = winnerMissionID }
        return update
    }

    /// Build the merge update WITH a sealed synthesis summary. The private
    /// `synthesisSummary` lives only inside `sealedStatePayload`; the triplet
    /// of state fields (`contentSealed`/`sealedStateSchemaVersion`/
    /// `sealedStateVaultKeyID`) matches the Firestore state-update contract.
    static func mergeMissionGroupUpdate(
        winnerMissionID: String?,
        synthesisSummary: String,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        var update = mergeMissionGroupUpdate(winnerMissionID: winnerMissionID)
        let privatePayload = CLIAgentMissionPrivatePayload(synthesisSummary: synthesisSummary)
        update["contentSealed"] = true
        update["sealedStateSchemaVersion"] = CLIAgentMissionCloudSealer.sealedStateSchemaVersion
        update["sealedStateVaultKeyID"] = vaultKeyID
        update["sealedStatePayload"] = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID
        )
        return update
    }

    func respondToApproval(
        requestID: String,
        approve: Bool
    ) async throws {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard Auth.auth().currentUser?.uid != nil else {
            throw DispatchError.notSignedIn
        }
        // Bind the approve/reject to this trusted native escrow device via the
        // App-Check-enforced callable. The bare Firestore status flip is no
        // longer accepted by firestore.rules (it must carry approvedByDeviceId
        // resolving to a trusted escrow device), so a stolen owner token cannot
        // self-approve a high-risk mission.
        let deviceId = await MainActor.run { MobileDeviceIdentity.loadOrCreateDeviceId() }
        try await ComputerUseSecurityCallableClient.respondMissionApproval(
            requestId: requestID,
            approve: approve,
            deviceId: deviceId
        )
    }

    func cancelMission(requestID: String) async throws {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }
        let db = firestoreProvider()
        // The user-facing cancel summary is private text. Seal it into
        // `sealedStatePayload` (mirroring Android `sealedMissionStateUpdate`)
        // instead of writing a top-level plaintext `liveSummary`. The reader
        // (`CLIAgentMissionSnapshot`) already prefers the sealed state summary
        // with a legacy top-level fallback. This shape also satisfies the new
        // `validMobileMissionCancel()` rule predicate (owned by stream SD):
        // diff hasOnly(status, contentSealed, sealedStatePayload,
        // sealedStateSchemaVersion, sealedStateVaultKeyID, updatedAt).
        let resolvedKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: db)
        let update = try Self.cancelMissionUpdate(
            uid: uid,
            requestID: requestID,
            vaultKey: resolvedKey.keyData,
            vaultKeyID: resolvedKey.vaultKeyID
        )
        try await db
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .setData(update, merge: true)
    }

    /// Build the sealed cancel update. `status` flips to `cancelled` and the
    /// cancel summary is sealed into `sealedStatePayload`; no plaintext
    /// `liveSummary` is written. Diff keys exactly match the
    /// `validMobileMissionCancel()` rule allowlist.
    static func cancelMissionUpdate(
        uid: String? = nil,
        requestID: String? = nil,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        let privatePayload = CLIAgentMissionPrivatePayload(liveSummary: "Mission cancelled by user.")
        let aadContext: CloudVaultAADContext?
        if let uid, let requestID {
            aadContext = try CLIAgentMissionCloudSealer.missionAADContext(
                uid: uid,
                documentID: requestID,
                field: "sealedStatePayload"
            )
        } else {
            aadContext = nil
        }
        return [
            "status": "cancelled",
            "contentSealed": true,
            "sealedStateSchemaVersion": CLIAgentMissionCloudSealer.sealedStateSchemaVersion,
            "sealedStateVaultKeyID": vaultKeyID,
            "sealedStatePayload": try CLIAgentMissionCloudSealer.seal(
                privatePayload,
                vaultKey: vaultKey,
                vaultKeyID: vaultKeyID,
                aadContext: aadContext
            ),
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }
}

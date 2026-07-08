import Foundation
import OpenBurnBarCore

extension SessionLogSyncService {
    func uploadProjectMemorySnapshot(_ snapshot: ProjectMemorySnapshot) async throws {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              gate.settings.sessionLogCloudBackupEnabled,
              !gate.syncSuppressed,
              let uid = gate.account.uid else { return }

        let resolvedVaultKey = try await writableVaultKey(uid: uid)
        let vaultKey = resolvedVaultKey.keyData

        let payload = try Self.jsonData(snapshot)
        let cloudContentHash = try CloudVaultCrypto.projectMemoryContentHash(payload, keyData: vaultKey)
        let visualKinds = Array(Set(snapshot.visuals.map(\.kind.rawValue))).sorted()

        // Opaque, deterministic, vault-key-keyed doc id so the server (and anyone
        // with raw Firestore read) never sees the project name — it lives only
        // inside `sealedSnapshot`. Same slug + key → same id, so upsert stays
        // idempotent. The plaintext `projectSlug`/`projectDisplayName` callable
        // fields are dropped (they were pure denormalization of the ciphertext).
        let docID = try CloudVaultCrypto.projectMemoryDocID(forSlug: snapshot.projectSlug, keyData: vaultKey)
        let sealedSnapshot = try CloudVaultCrypto.sealBlob(
            payload,
            keyData: vaultKey,
            aadContext: CloudVaultAADContext(
                uid: uid,
                collection: "project_memory_snapshots",
                docID: docID,
                field: "sealedSnapshot"
            )
        )

        var commitPayload: [String: Any] = [
            "docID": docID,
            "contentHash": cloudContentHash,
            "contentHashVersion": CloudVaultCrypto.projectMemoryContentHashVersion,
            "sourceSessionCount": snapshot.sourceSessionCount,
            "sourceConversationCount": snapshot.sourceConversationCount,
            "generatedAt": Self.iso8601.string(from: snapshot.generatedAt),
            "freshness": snapshot.freshness.rawValue,
            "visualKinds": visualKinds,
            "vaultKeyID": resolvedVaultKey.vaultKeyID,
            "sealedSnapshot": try Self.dictionary(sealedSnapshot)
        ]
        // Client-side migration: if this snapshot was previously stored under the
        // plaintext-slug doc id, tell the server to delete that legacy doc in the
        // same authed commit so the cleartext name/slug stops surviving. The
        // server cannot re-key on its own (it lacks the vault key).
        if snapshot.projectSlug != docID {
            commitPayload["legacyDocID"] = snapshot.projectSlug
        }

        do {
            try await encryptedCloudClient.commitEncryptedProjectMemorySnapshot(commitPayload)
        } catch {
            if Self.isPermissionDeniedFunctionsError(error) { return }
            throw error
        }
    }

    func fetchCloudProjectMemorySnapshot(projectSlug: String) async throws -> ProjectMemorySnapshot? {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              gate.settings.sessionLogCloudBackupEnabled,
              !gate.syncSuppressed,
              let uid = gate.account.uid else { return nil }

        guard let vaultKey = try await readableVaultKey(uid: uid)?.keyData else { return nil }

        // Look the snapshot up by the opaque vault-keyed doc id derived from the
        // candidate slug. LEGACY FALLBACK: a doc written before this change is keyed
        // by the plaintext slug, so if the opaque lookup misses, retry by slug so
        // in-flight/legacy docs still render during migration (the next upload
        // re-keys + deletes the legacy doc).
        let docID = try CloudVaultCrypto.projectMemoryDocID(forSlug: projectSlug, keyData: vaultKey)
        let payload: [String: Any]
        do {
            payload = try await encryptedCloudClient.getEncryptedProjectMemorySnapshot([
                "docID": docID
            ])
        } catch {
            if Self.isPermissionDeniedFunctionsError(error) { return nil }
            throw error
        }
        var snapshotPayload = payload["snapshot"] as? [String: Any]
        if snapshotPayload?["sealedSnapshot"] == nil {
            let legacyPayload: [String: Any]
            do {
                legacyPayload = try await encryptedCloudClient.getEncryptedProjectMemorySnapshot([
                    "projectSlug": projectSlug
                ])
            } catch {
                if Self.isPermissionDeniedFunctionsError(error) { return nil }
                throw error
            }
            snapshotPayload = legacyPayload["snapshot"] as? [String: Any]
        }
        guard let snapshotPayload,
              let sealedSnapshot = snapshotPayload["sealedSnapshot"] else {
            return nil
        }
        let sealedData = try JSONSerialization.data(withJSONObject: sealedSnapshot)
        let envelope = try JSONDecoder().decode(CloudVaultBlobEnvelope.self, from: sealedData)
        let snapshotDocID = snapshotPayload["docID"] as? String ?? docID
        let plaintext = try CloudVaultCrypto.openBlob(
            envelope,
            keyData: vaultKey,
            aadContext: CloudVaultAADContext(
                uid: uid,
                collection: "project_memory_snapshots",
                docID: snapshotDocID,
                field: "sealedSnapshot"
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectMemorySnapshot.self, from: plaintext)
    }
}

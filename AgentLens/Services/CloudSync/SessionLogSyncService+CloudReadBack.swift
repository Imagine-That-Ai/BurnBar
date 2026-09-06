import FirebaseFirestore
import Foundation
import OpenBurnBarCore

extension SessionLogSyncService {
    /// Fetches session log manifests from Firestore for the signed-in user.
    /// Returns ConversationRecords with empty fullText; body is fetched lazily via DownloadSyncService.
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [OpenBurnBarCore.ConversationRecord] {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              let uid = gate.account.uid else { return [] }
        let vaultKey: Data?
        do {
            vaultKey = try await readableVaultKey(uid: uid)?.keyData
        } catch {
            vaultKey = nil
        }

        let snapshot = try await context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .order(by: "updatedAt", descending: true)
            .limit(to: limit)
            .getDocuments()

        return snapshot.documents.compactMap { doc -> OpenBurnBarCore.ConversationRecord? in
            let data = doc.data()
            if let deletedAt = data["deletedAt"], !(deletedAt is NSNull) { return nil }
            guard let rawProvider = data["provider"] as? String,
                  let provider = AgentProvider(rawValue: rawProvider) else { return nil }

            let id = data["id"] as? String ?? doc.documentID
            let sourceTypeRaw = data["sourceType"] as? String ?? OpenBurnBarCore.ConversationSourceType.providerLog.rawValue
            let sourceType = OpenBurnBarCore.ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog
            let decryptedTitle: String? = vaultKey.flatMap { key in
                guard let envelope = CloudVaultCrypto.decodeSealedText(from: data["sealedTitle"]) else { return nil }
                do {
                    return try CloudVaultCrypto.openText(
                        envelope,
                        keyData: key,
                        aadContext: CloudVaultAADContext(
                            uid: uid,
                            collection: "session_logs",
                            docID: doc.documentID,
                            field: "sealedTitle"
                        )
                    )
                } catch {
                    return nil
                }
            }
            let title = decryptedTitle ?? data["inferredTaskTitle"] as? String ?? ""

            return OpenBurnBarCore.ConversationRecord(
                id: id,
                provider: provider,
                sessionId: doc.documentID,
                projectName: "",
                startTime: (data["startTime"] as? Timestamp)?.dateValue(),
                endTime: (data["endTime"] as? Timestamp)?.dateValue(),
                messageCount: data["messageCount"] as? Int ?? 0,
                userWordCount: 0,
                assistantWordCount: 0,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: title,
                lastAssistantMessage: "",
                fullText: "",
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: nil,
                summaryTitle: title.isEmpty ? nil : title,
                sourceType: sourceType
            )
        }
    }

    /// Fetches and decrypts a session-log body from encrypted Cloud Storage.
    /// Legacy Firestore chunk bodies are intentionally ignored; they are
    /// scrub-only data under the hardened cloud privacy boundary.
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              let uid = gate.account.uid else { return "" }
        guard let vaultKey = try await readableVaultKey(uid: uid)?.keyData else { return "" }

        let manifestData = try await context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .document(docId)
            .getData() ?? [:]
        guard manifestData["bodyStorage"] as? String == "firebase_storage_encrypted",
              let storagePath = manifestData["storagePath"] as? String else {
            return ""
        }

        let data = try await encryptedCloudClient.downloadEncryptedBody(storagePath: storagePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CloudVaultBlobEnvelope.self, from: data)
        let plaintext = try CloudVaultCrypto.openBlob(
            envelope,
            keyData: vaultKey,
            aadContext: CloudVaultAADContext(
                uid: uid,
                collection: "session_logs",
                docID: docId,
                field: "sealedBody"
            )
        )
        return String(data: plaintext, encoding: .utf8) ?? ""
    }
}

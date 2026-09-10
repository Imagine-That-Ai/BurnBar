import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import os

struct CloudVaultRotationRewrapProgress: Equatable, Sendable {
    let scannedDocuments: Int
    let rewrappedDocuments: Int
    let changedFields: Int
    let scannedStorageBlobs: Int
    let rewrappedStorageBlobs: Int
}

private struct CloudVaultNestedDocumentRewrapTarget {
    let parentCollectionID: String
    let childCollectionID: String
    let logicalCollectionID: String
    let checkpointID: String
}

struct CloudVaultRotationRewrapWorker {
    private static let logger = Logger(subsystem: "com.openburnbar.cloudsync", category: "CloudVaultRotationRewrapWorker")

    private static let cloudSearchChunkMaxBytes = 16_000
    private static let cloudSearchChunkTokenHashLimit = 1_024
    private static let cloudSearchIndexVersion = 5
    private static let nestedDocumentRewrapTargets = [
        CloudVaultNestedDocumentRewrapTarget(
            parentCollectionID: "cli_agent_mission_requests",
            childCollectionID: "events",
            logicalCollectionID: "cli_agent_mission_requests/events",
            checkpointID: "cli_agent_mission_requests_events"
        )
    ]

    /// The domains whose documents the rewrap pass re-seals, in the order it
    /// walks them. Named rather than inlined so the set is greppable and
    /// testable: the collections that get rewrapped are the ones a rotation must
    /// not strand, and "which collections are those" was previously answerable
    /// only by reading the registry and this filter together.
    ///
    /// `users/{uid}/memory_facts` is in it through the `pensieve` domain
    /// (`document_envelopes`), which is what carries Memory Blind Sync's sealed
    /// memories across a vault-key rotation: `rewrapCollection` opens every
    /// `[String: Any]` field under the AAD naming its own collection, document
    /// and field name, so `sealedMemory` is re-sealed under
    /// `(uid, "memory_facts", docID, "sealedMemory")` — exactly the AAD
    /// `MemoryCloudPullService.verify` requires — and stamped with the new
    /// `vaultGeneration` / `rewrapJobId`. Spec §6.
    static var documentRewrapDomains: [DataDomain] {
        DataDomains.all.filter { $0.cloudVaultRewrapStrategy?.hasPrefix("document") == true }
    }

    /// Every `users/{uid}/…` collection `documentRewrapDomains` covers.
    static var documentRewrapCollectionIDs: [String] {
        documentRewrapDomains.flatMap(\.firestorePaths)
    }

    var batchLimit: Int = 50
    var firestore: Firestore = .firestore()
    var encryptedCloudClient: SessionLogEncryptedCloudClient = FirebaseSessionLogEncryptedCloudClient()

    func runDocumentRewrap(
        uid: String,
        deviceId: String,
        jobId: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int
    ) async throws -> CloudVaultRotationRewrapProgress {
        let userRef = firestore.collection("users").document(uid)
        let jobRef = userRef.collection("cloud_vault_rotation_jobs").document(jobId)
        try await jobRef.setData([
            "status": "rewrapping",
            "clientDeviceId": deviceId,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        var scanned = 0
        var rewrapped = 0
        var changed = 0

        for domain in Self.documentRewrapDomains {
            if domain.cloudVaultRewrapStrategy == "document_and_storage_envelopes" {
                try await checkpoint(
                    jobRef: jobRef,
                    domainID: domain.id,
                    status: "documents_pending_storage",
                    scanned: scanned,
                    rewrapped: rewrapped,
                    changedFields: changed
                )
            }

            for collectionID in domain.firestorePaths {
                let result = try await rewrapCollection(
                    userRef: userRef,
                    collectionID: collectionID,
                    uid: uid,
                    jobId: jobId,
                    oldKeyData: oldKeyData,
                    newKeyData: newKeyData,
                    newVaultKeyID: newVaultKeyID,
                    vaultGeneration: vaultGeneration
                )
                scanned += result.scannedDocuments
                rewrapped += result.rewrappedDocuments
                changed += result.changedFields
            }

            try await checkpoint(
                jobRef: jobRef,
                domainID: domain.id,
                status: "documents_complete",
                scanned: scanned,
                rewrapped: rewrapped,
                changedFields: changed
            )
        }

        for target in Self.nestedDocumentRewrapTargets {
            let result = try await rewrapNestedCollection(
                userRef: userRef,
                target: target,
                uid: uid,
                jobId: jobId,
                oldKeyData: oldKeyData,
                newKeyData: newKeyData,
                newVaultKeyID: newVaultKeyID,
                vaultGeneration: vaultGeneration
            )
            scanned += result.scannedDocuments
            rewrapped += result.rewrappedDocuments
            changed += result.changedFields

            try await checkpoint(
                jobRef: jobRef,
                domainID: target.checkpointID,
                status: "documents_complete",
                scanned: scanned,
                rewrapped: rewrapped,
                changedFields: changed
            )
        }

        let storage = try await rewrapSessionLogStorage(
            uid: uid,
            deviceId: deviceId,
            jobId: jobId,
            oldKeyData: oldKeyData,
            newKeyData: newKeyData,
            newVaultKeyID: newVaultKeyID,
            vaultGeneration: vaultGeneration
        )
        try await jobRef.setData([
            "status": "complete",
            "documentRewrapComplete": true,
            "storageRewrapComplete": true,
            "storageRewrapPending": false,
            "processedDocumentCount": scanned,
            "rewrappedDocumentCount": rewrapped,
            "changedFieldCount": changed,
            "processedStorageBlobCount": storage.scannedStorageBlobs,
            "rewrappedStorageBlobCount": storage.rewrappedStorageBlobs,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        return CloudVaultRotationRewrapProgress(
            scannedDocuments: scanned,
            rewrappedDocuments: rewrapped,
            changedFields: changed,
            scannedStorageBlobs: storage.scannedStorageBlobs,
            rewrappedStorageBlobs: storage.rewrappedStorageBlobs
        )
    }

    private func rewrapSessionLogStorage(
        uid: String,
        deviceId: String,
        jobId: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int
    ) async throws -> CloudVaultRotationRewrapProgress {
        let userRef = firestore.collection("users").document(uid)
        let jobRef = userRef.collection("cloud_vault_rotation_jobs").document(jobId)
        let logsRef = userRef.collection("session_logs")
        var scanned = 0
        var rewrapped = 0
        var lastDocument: DocumentSnapshot?

        try await checkpoint(
            jobRef: jobRef,
            domainID: "session_logs_storage",
            status: "storage_rewrapping",
            scanned: 0,
            rewrapped: 0,
            changedFields: 0
        )

        while true {
            var query: Query = logsRef
                .whereField("bodyStorage", isEqualTo: "firebase_storage_encrypted")
                .order(by: FieldPath.documentID())
                .limit(to: batchLimit)
            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }
            let snapshot = try await query.getDocuments()
            if snapshot.documents.isEmpty { break }

            for document in snapshot.documents {
                scanned += 1
                let data = document.data()
                guard let storagePath = data["storagePath"] as? String, storagePath.isEmpty == false,
                      let bodyHash = data["bodyHash"] as? String, bodyHash.isEmpty == false else {
                    continue
                }
                // Init validates AAD parts and throws on malformed IDs; skip
                // the document like the field guards above rather than abort
                // the whole rewrap scan.
                let aad: CloudVaultAADContext
                do {
                    aad = try CloudVaultAADContext(
                        uid: uid,
                        collection: "session_logs",
                        docID: document.documentID,
                        field: "sealedBody"
                    )
                } catch {
                    Self.logger.warning("Skipping rewrap for malformed doc ID: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                let sealedData = try await encryptedCloudClient.downloadEncryptedBody(storagePath: storagePath)
                let envelope = try JSONDecoder().decode(CloudVaultBlobEnvelope.self, from: sealedData)
                let plaintext: Data
                do {
                    plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: oldKeyData, aadContext: aad)
                } catch let oldOpenError {
                    do {
                        let alreadyRotated = try CloudVaultCrypto.openBlob(envelope, keyData: newKeyData, aadContext: aad)
                        if try CloudVaultCrypto.sessionBodyHash(alreadyRotated, keyData: newKeyData) == bodyHash {
                            continue
                        }
                    } catch let rotatedOpenError {
                        NSLog("CloudVault rewrap could not open session blob \(storagePath) with new generation either: \(rotatedOpenError)")
                    }
                    throw oldOpenError
                }

                let newBodyHash = try CloudVaultCrypto.sessionBodyHash(plaintext, keyData: newKeyData)
                let bodyText = String(data: plaintext, encoding: .utf8) ?? ""
                let resealed = try CloudVaultCrypto.sealBlob(plaintext, keyData: newKeyData, aadContext: aad)
                let resealedData = try JSONEncoder().encode(resealed)
                let uploadTicket = try await encryptedCloudClient.beginEncryptedSessionBlobUpload(
                    documentID: document.documentID,
                    bodyHash: newBodyHash,
                    byteCount: resealedData.count
                )
                try await encryptedCloudClient.uploadEncryptedBody(data: resealedData, ticket: uploadTicket)

                let title = titlePlaintext(
                    from: data["sealedTitle"],
                    uid: uid,
                    docID: document.documentID,
                    oldKeyData: oldKeyData,
                    newKeyData: newKeyData
                ) ?? document.documentID
                let preview = String(bodyText.prefix(500))
                let provider = data["provider"] as? String ?? "unknown"
                let chunks = try Self.cloudSearchChunks(bodyText, title: title, provider: provider, maxBytes: Self.cloudSearchChunkMaxBytes)
                let sourceID = data["id"] as? String ?? document.documentID
                let sealedSearchTitle = try CloudVaultCrypto.sealText(
                    title,
                    keyData: newKeyData,
                    aadContext: CloudVaultAADContext(uid: uid, collection: "cloud_search_documents", docID: document.documentID, field: "sealedTitle")
                )
                let sealedSearchPreview = try CloudVaultCrypto.sealText(
                    preview,
                    keyData: newKeyData,
                    aadContext: CloudVaultAADContext(uid: uid, collection: "cloud_search_documents", docID: document.documentID, field: "sealedBodyPreview")
                )
                var cloudSearchChunks: [[String: Any]] = []
                for (index, chunk) in chunks.enumerated() {
                    let snippet = chunk
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let chunkID = "\(document.documentID)_\(index)"
                    let sealedSnippet = try CloudVaultCrypto.sealText(
                        String(snippet.prefix(500)),
                        keyData: newKeyData,
                        aadContext: CloudVaultAADContext(uid: uid, collection: "cloud_search_chunks", docID: chunkID, field: "sealedSnippet")
                    )
                    let searchText = "\(chunk) \(title) \(provider)"
                    cloudSearchChunks.append([
                        "chunkID": chunkID,
                        "documentID": document.documentID,
                        "sourceKind": "conversation",
                        "sourceID": sourceID,
                        "ordinal": index,
                        "startOffset": 0,
                        "endOffset": chunk.utf8.count,
                        "contentHash": try CloudVaultCrypto.sessionChunkHash(chunk, keyData: newKeyData),
                        "contentHashVersion": CloudVaultCrypto.sessionChunkHashVersion,
                        "bodyHash": newBodyHash,
                        "bodyHashVersion": CloudVaultCrypto.sessionBodyHashVersion,
                        "storagePath": uploadTicket.storagePath,
                        "sealedSnippet": try CloudVaultCrypto.firestoreDictionary(sealedSnippet),
                        "tokenHashes": try CloudVaultCrypto.searchIndexTokenHashes(
                            for: searchText,
                            keyData: newKeyData,
                            limit: Self.cloudSearchChunkTokenHashLimit
                        ),
                        "semanticHashes": try CloudVaultCrypto.semanticHashes(for: searchText, keyData: newKeyData),
                        "semanticHashVersion": CloudVaultCrypto.semanticHashVersion,
                        "provider": provider
                    ])
                }

                try await encryptedCloudClient.commitEncryptedSearchIndex(
                    deviceId: deviceId,
                    indexVersion: Self.cloudSearchIndexVersion,
                    document: [
                        "documentID": document.documentID,
                        "sourceKind": "conversation",
                        "sourceID": sourceID,
                        "sourceVersionID": newBodyHash,
                        "provider": provider,
                        "bodyHash": newBodyHash,
                        "bodyHashVersion": CloudVaultCrypto.sessionBodyHashVersion,
                        "storagePath": uploadTicket.storagePath,
                        "sealedTitle": try CloudVaultCrypto.firestoreDictionary(sealedSearchTitle),
                        "sealedBodyPreview": try CloudVaultCrypto.firestoreDictionary(sealedSearchPreview),
                        "byteCount": plaintext.count,
                        "encryptedByteCount": resealedData.count
                    ],
                    chunks: cloudSearchChunks
                )

                try await document.reference.updateData([
                    "storagePath": uploadTicket.storagePath,
                    "bodyHash": newBodyHash,
                    "bodyHashVersion": CloudVaultCrypto.sessionBodyHashVersion,
                    "encryptedByteCount": resealedData.count,
                    "vaultKeyID": newVaultKeyID,
                    "vaultGeneration": vaultGeneration,
                    "rewrapJobId": jobId,
                    "updatedAt": FieldValue.serverTimestamp()
                ])
                if uploadTicket.storagePath != storagePath {
                    do {
                        try await encryptedCloudClient.deleteEncryptedSessionBlob(
                            documentID: document.documentID,
                            storagePath: storagePath
                        )
                    } catch {
                        NSLog("CloudVault rewrap could not delete superseded session blob \(storagePath): \(error)")
                    }
                }
                rewrapped += 1
            }

            try await checkpoint(
                jobRef: jobRef,
                domainID: "session_logs_storage",
                status: "storage_rewrapping",
                scanned: scanned,
                rewrapped: rewrapped,
                changedFields: 0
            )
            lastDocument = snapshot.documents.last
        }

        try await checkpoint(
            jobRef: jobRef,
            domainID: "session_logs_storage",
            status: "storage_complete",
            scanned: scanned,
            rewrapped: rewrapped,
            changedFields: 0
        )

        return CloudVaultRotationRewrapProgress(
            scannedDocuments: 0,
            rewrappedDocuments: 0,
            changedFields: 0,
            scannedStorageBlobs: scanned,
            rewrappedStorageBlobs: rewrapped
        )
    }

    static func cloudSearchChunks(
        _ bodyText: String,
        title: String,
        provider: String,
        maxBytes: Int
    ) throws -> [String] {
        let searchMetadata = "\(title) \(provider)"
        return try CloudVaultCrypto.cloudSearchBodyChunks(
            bodyText,
            metadata: searchMetadata,
            maxBytes: maxBytes
        )
    }

    private func titlePlaintext(
        from raw: Any?,
        uid: String,
        docID: String,
        oldKeyData: Data,
        newKeyData: Data
    ) -> String? {
        guard let envelope = CloudVaultCrypto.decodeSealedText(from: raw) else { return nil }
        let aad: CloudVaultAADContext
        do {
            aad = try CloudVaultAADContext(uid: uid, collection: "session_logs", docID: docID, field: "sealedTitle")
        } catch {
            Self.logger.warning("Skipping title open for malformed doc ID: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return openOptionalText(envelope, keyData: newKeyData, aadContext: aad)
            ?? openOptionalText(envelope, keyData: oldKeyData, aadContext: aad)
    }

    private func openOptionalText(
        _ envelope: CloudVaultSealedText,
        keyData: Data,
        aadContext: CloudVaultAADContext
    ) -> String? {
        do {
            return try CloudVaultCrypto.openText(envelope, keyData: keyData, aadContext: aadContext)
        } catch {
            return nil
        }
    }

    private func rewrapCollection(
        userRef: DocumentReference,
        collectionID: String,
        uid: String,
        jobId: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int
    ) async throws -> CloudVaultRotationRewrapProgress {
        var scanned = 0
        var rewrapped = 0
        var changed = 0
        var lastDocument: DocumentSnapshot?

        while true {
            var query: Query = userRef.collection(collectionID)
                .order(by: FieldPath.documentID())
                .limit(to: batchLimit)
            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }
            let snapshot = try await query.getDocuments()
            if snapshot.documents.isEmpty { break }

            for document in snapshot.documents {
                scanned += 1
                let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
                    document.data(),
                    uid: uid,
                    collection: collectionID,
                    docID: document.documentID,
                    oldKeyData: oldKeyData,
                    newKeyData: newKeyData,
                    newVaultKeyID: newVaultKeyID,
                    vaultGeneration: vaultGeneration,
                    rotationJobId: jobId
                )
                guard result.changed else { continue }
                try await document.reference.updateData(updatePayload(from: result, vaultGeneration: vaultGeneration, jobId: jobId))
                rewrapped += 1
                changed += result.changedFields.count
            }

            lastDocument = snapshot.documents.last
        }

        return CloudVaultRotationRewrapProgress(
            scannedDocuments: scanned,
            rewrappedDocuments: rewrapped,
            changedFields: changed,
            scannedStorageBlobs: 0,
            rewrappedStorageBlobs: 0
        )
    }

    private func rewrapNestedCollection(
        userRef: DocumentReference,
        target: CloudVaultNestedDocumentRewrapTarget,
        uid: String,
        jobId: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int
    ) async throws -> CloudVaultRotationRewrapProgress {
        var scanned = 0
        var rewrapped = 0
        var changed = 0
        var lastParent: DocumentSnapshot?

        while true {
            var query: Query = userRef.collection(target.parentCollectionID)
                .order(by: FieldPath.documentID())
                .limit(to: batchLimit)
            if let lastParent {
                query = query.start(afterDocument: lastParent)
            }
            let snapshot = try await query.getDocuments()
            if snapshot.documents.isEmpty { break }

            for parent in snapshot.documents {
                let progress = try await rewrapChildCollection(
                    parentDocument: parent,
                    target: target,
                    uid: uid,
                    jobId: jobId,
                    oldKeyData: oldKeyData,
                    newKeyData: newKeyData,
                    newVaultKeyID: newVaultKeyID,
                    vaultGeneration: vaultGeneration
                )
                scanned += progress.scannedDocuments
                rewrapped += progress.rewrappedDocuments
                changed += progress.changedFields
            }

            lastParent = snapshot.documents.last
        }

        return CloudVaultRotationRewrapProgress(
            scannedDocuments: scanned,
            rewrappedDocuments: rewrapped,
            changedFields: changed,
            scannedStorageBlobs: 0,
            rewrappedStorageBlobs: 0
        )
    }

    private func rewrapChildCollection(
        parentDocument: DocumentSnapshot,
        target: CloudVaultNestedDocumentRewrapTarget,
        uid: String,
        jobId: String,
        oldKeyData: Data,
        newKeyData: Data,
        newVaultKeyID: String,
        vaultGeneration: Int
    ) async throws -> CloudVaultRotationRewrapProgress {
        var scanned = 0
        var rewrapped = 0
        var changed = 0
        var lastDocument: DocumentSnapshot?

        while true {
            var query: Query = parentDocument.reference.collection(target.childCollectionID)
                .order(by: FieldPath.documentID())
                .limit(to: batchLimit)
            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }
            let snapshot = try await query.getDocuments()
            if snapshot.documents.isEmpty { break }

            for document in snapshot.documents {
                scanned += 1
                let result = try CloudVaultCrypto.rewrapCloudVaultDocument(
                    document.data(),
                    uid: uid,
                    collection: target.logicalCollectionID,
                    docID: "\(parentDocument.documentID)/\(document.documentID)",
                    oldKeyData: oldKeyData,
                    newKeyData: newKeyData,
                    newVaultKeyID: newVaultKeyID,
                    vaultGeneration: vaultGeneration,
                    rotationJobId: jobId
                )
                guard result.changed else { continue }
                try await document.reference.updateData(updatePayload(from: result, vaultGeneration: vaultGeneration, jobId: jobId))
                rewrapped += 1
                changed += result.changedFields.count
            }

            lastDocument = snapshot.documents.last
        }

        return CloudVaultRotationRewrapProgress(
            scannedDocuments: scanned,
            rewrappedDocuments: rewrapped,
            changedFields: changed,
            scannedStorageBlobs: 0,
            rewrappedStorageBlobs: 0
        )
    }

    private func updatePayload(
        from result: CloudVaultDocumentRewrapResult,
        vaultGeneration: Int,
        jobId: String
    ) -> [AnyHashable: Any] {
        var updates: [AnyHashable: Any] = [:]
        for field in result.changedFields {
            if let value = result.data[field] {
                updates[field] = value
            }
        }
        for companion in ["vaultKeyID", "sealedStateVaultKeyID"] {
            if let value = result.data[companion] {
                updates[companion] = value
            }
        }
        updates["vaultGeneration"] = vaultGeneration
        updates["rewrapJobId"] = jobId
        updates["updatedAt"] = FieldValue.serverTimestamp()
        return updates
    }

    private func checkpoint(
        jobRef: DocumentReference,
        domainID: String,
        status: String,
        scanned: Int,
        rewrapped: Int,
        changedFields: Int
    ) async throws {
        try await jobRef.collection("checkpoints").document(domainID).setData([
            "domainID": domainID,
            "status": status,
            "scannedDocumentCount": scanned,
            "rewrappedDocumentCount": rewrapped,
            "changedFieldCount": changedFields,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }
}

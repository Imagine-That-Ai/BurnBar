// Security-pinned E2EE/trust code under active remediation; behavior is pinned by tests and
// a P0 migration gate. Lint findings here are wire-format/defensive-coding by design -
package com.openburnbar.data.cloud

import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldPath
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.ktx.functions
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.domains.DataDomains
import java.net.URL
import kotlinx.coroutines.tasks.await
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

data class CloudVaultRotationRewrapProgress(
    val scannedDocuments: Int,
    val rewrappedDocuments: Int,
    val changedFields: Int,
    val scannedStorageBlobs: Int = 0,
    val rewrappedStorageBlobs: Int = 0,
)

private data class CloudVaultRotationUploadTicket(
    val storagePath: String,
    val uploadURL: String,
)

class CloudVaultRotationRewrapWorker(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val functions: FirebaseFunctions = Firebase.functions("us-central1"),
    private val httpClient: OkHttpClient = OkHttpClient(),
    private val batchLimit: Long = 50,
) {
    private val cloudSearchChunkMaxBytes = 16_000
    private val cloudSearchChunkTokenHashLimit = 1_024
    private val cloudSearchIndexVersion = 5

    suspend fun runDocumentRewrap(
        uid: String,
        deviceId: String,
        jobId: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String = CloudVaultCrypto.vaultKeyID(newKey),
        vaultGeneration: Int,
    ): CloudVaultRotationRewrapProgress {
        val userRef = firestore.collection("users").document(uid)
        val jobRef = userRef.collection("cloud_vault_rotation_jobs").document(jobId)
        jobRef
            .set(
                mapOf(
                    "status" to "rewrapping",
                    "clientDeviceId" to deviceId,
                    "updatedAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            ).await()

        var scanned = 0
        var rewrapped = 0
        var changed = 0

        for (domain in DataDomains.all.filter { it.cloudVaultRewrapStrategy?.startsWith("document") == true }) {
            for (collectionID in domain.firestorePaths) {
                val progress =
                    rewrapCollection(
                        uid = uid,
                        collectionID = collectionID,
                        jobId = jobId,
                        oldKey = oldKey,
                        newKey = newKey,
                        newVaultKeyID = newVaultKeyID,
                        vaultGeneration = vaultGeneration,
                    )
                scanned += progress.scannedDocuments
                rewrapped += progress.rewrappedDocuments
                changed += progress.changedFields
            }
            checkpoint(jobId = jobId, uid = uid, domainID = domain.id, scanned = scanned, rewrapped = rewrapped, changed = changed)
        }

        val storage =
            rewrapSessionLogStorage(
                uid = uid,
                deviceId = deviceId,
                jobId = jobId,
                oldKey = oldKey,
                newKey = newKey,
                newVaultKeyID = newVaultKeyID,
                vaultGeneration = vaultGeneration,
            )
        jobRef
            .set(
                mapOf(
                    "status" to "complete",
                    "documentRewrapComplete" to true,
                    "storageRewrapComplete" to true,
                    "storageRewrapPending" to false,
                    "processedDocumentCount" to scanned,
                    "rewrappedDocumentCount" to rewrapped,
                    "changedFieldCount" to changed,
                    "processedStorageBlobCount" to storage.scannedStorageBlobs,
                    "rewrappedStorageBlobCount" to storage.rewrappedStorageBlobs,
                    "updatedAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            ).await()

        return CloudVaultRotationRewrapProgress(
            scannedDocuments = scanned,
            rewrappedDocuments = rewrapped,
            changedFields = changed,
            scannedStorageBlobs = storage.scannedStorageBlobs,
            rewrappedStorageBlobs = storage.rewrappedStorageBlobs,
        )
    }

    private suspend fun rewrapSessionLogStorage(
        uid: String,
        deviceId: String,
        jobId: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String,
        vaultGeneration: Int,
    ): CloudVaultRotationRewrapProgress {
        val userRef = firestore.collection("users").document(uid)
        val jobRef = userRef.collection("cloud_vault_rotation_jobs").document(jobId)
        val collection = userRef.collection("session_logs")
        var scanned = 0
        var rewrapped = 0
        var lastDocument: DocumentSnapshot? = null

        while (true) {
            var query =
                collection
                    .whereEqualTo("bodyStorage", "firebase_storage_encrypted")
                    .orderBy(FieldPath.documentId())
                    .limit(batchLimit)
            lastDocument?.let { query = query.startAfter(it) }
            val snapshot = query.get().await()
            if (snapshot.documents.isEmpty()) break

            for (document in snapshot.documents) {
                scanned += 1
                val data = document.data.orEmpty()
                val storagePath = data["storagePath"] as? String ?: continue
                val bodyHash = data["bodyHash"] as? String ?: continue
                if (storagePath.isBlank() || bodyHash.isBlank()) continue

                val aad = CloudVaultAADContext(uid = uid, collection = "session_logs", docID = document.id, field = "sealedBody")
                val sealedData = downloadEncryptedBody(storagePath)
                val envelope = blobEnvelopeFromJson(sealedData)
                val plaintext =
                    try {
                        CloudVaultCrypto.openBlob(envelope, oldKey, aad)
                    } catch (error: Throwable) {
                        val alreadyRotated = runCatching { CloudVaultCrypto.openBlob(envelope, newKey, aad) }.getOrNull()
                        if (alreadyRotated != null && CloudVaultCrypto.sessionBodyHash(alreadyRotated, newKey) == bodyHash) {
                            continue
                        }
                        throw error
                    }

                val newBodyHash = CloudVaultCrypto.sessionBodyHash(plaintext, newKey)
                val bodyText = plaintext.toString(Charsets.UTF_8)
                val resealed = CloudVaultCrypto.sealBlob(plaintext, newKey, aad)
                val resealedData = JSONObject(CloudVaultCrypto.blobEnvelopeMap(resealed)).toString().toByteArray(Charsets.UTF_8)
                val uploadTicket =
                    beginEncryptedSessionBlobUpload(
                        documentID = document.id,
                        bodyHash = newBodyHash,
                        byteCount = resealedData.size,
                    )
                uploadEncryptedBody(resealedData, uploadTicket)

                val title =
                    titlePlaintext(data["sealedTitle"], uid, document.id, oldKey, newKey)
                        ?: document.id
                val preview = bodyText.take(500)
                val chunks = chunkUtf8String(bodyText, cloudSearchChunkMaxBytes)
                val provider = data["provider"] as? String ?: "unknown"
                val sourceID = data["id"] as? String ?: document.id
                val sealedSearchTitle =
                    CloudVaultCrypto.sealText(
                        title,
                        newKey,
                        CloudVaultAADContext(uid = uid, collection = "cloud_search_documents", docID = document.id, field = "sealedTitle"),
                    )
                val sealedSearchPreview =
                    CloudVaultCrypto.sealText(
                        preview,
                        newKey,
                        CloudVaultAADContext(uid = uid, collection = "cloud_search_documents", docID = document.id, field = "sealedBodyPreview"),
                    )
                val cloudSearchChunks =
                    chunks.mapIndexed { index, chunk ->
                        val snippet = chunk.replace("\n", " ").trim().take(500)
                        val chunkID = "${document.id}_$index"
                        val sealedSnippet =
                            CloudVaultCrypto.sealText(
                                snippet,
                                newKey,
                                CloudVaultAADContext(uid = uid, collection = "cloud_search_chunks", docID = chunkID, field = "sealedSnippet"),
                            )
                        val searchText = "$chunk $title $provider"
                        mapOf(
                            "chunkID" to chunkID,
                            "documentID" to document.id,
                            "sourceKind" to "conversation",
                            "sourceID" to sourceID,
                            "ordinal" to index,
                            "startOffset" to 0,
                            "endOffset" to chunk.toByteArray(Charsets.UTF_8).size,
                            "contentHash" to CloudVaultCrypto.sessionChunkHash(chunk, newKey),
                            "contentHashVersion" to CloudVaultCrypto.sessionChunkHashVersion,
                            "bodyHash" to newBodyHash,
                            "bodyHashVersion" to CloudVaultCrypto.sessionBodyHashVersion,
                            "storagePath" to uploadTicket.storagePath,
                            "sealedSnippet" to CloudVaultCrypto.sealedTextMap(sealedSnippet),
                            "tokenHashes" to
                                CloudVaultCrypto.tokenHashes(
                                    searchText,
                                    newKey,
                                    cloudSearchChunkTokenHashLimit,
                                ),
                            "semanticHashes" to CloudVaultCrypto.semanticHashes(searchText, newKey),
                            "semanticHashVersion" to CloudVaultCrypto.semanticHashVersion,
                            "provider" to provider,
                        )
                    }

                commitEncryptedSearchIndex(
                    deviceId = deviceId,
                    indexVersion = cloudSearchIndexVersion,
                    document =
                        mapOf(
                            "documentID" to document.id,
                            "sourceKind" to "conversation",
                            "sourceID" to sourceID,
                            "sourceVersionID" to newBodyHash,
                            "provider" to provider,
                            "bodyHash" to newBodyHash,
                            "bodyHashVersion" to CloudVaultCrypto.sessionBodyHashVersion,
                            "storagePath" to uploadTicket.storagePath,
                            "sealedTitle" to CloudVaultCrypto.sealedTextMap(sealedSearchTitle),
                            "sealedBodyPreview" to CloudVaultCrypto.sealedTextMap(sealedSearchPreview),
                            "byteCount" to plaintext.size,
                            "encryptedByteCount" to resealedData.size,
                        ),
                    chunks = cloudSearchChunks,
                )

                document.reference
                    .update(
                        mapOf(
                            "storagePath" to uploadTicket.storagePath,
                            "bodyHash" to newBodyHash,
                            "bodyHashVersion" to CloudVaultCrypto.sessionBodyHashVersion,
                            "encryptedByteCount" to resealedData.size,
                            "vaultKeyID" to newVaultKeyID,
                            "vaultGeneration" to vaultGeneration,
                            "rewrapJobId" to jobId,
                            "updatedAt" to FieldValue.serverTimestamp(),
                        ),
                    ).await()
                if (uploadTicket.storagePath != storagePath) {
                    runCatching { deleteEncryptedSessionBlob(document.id, storagePath) }
                }
                rewrapped += 1
            }

            checkpoint(jobId = jobId, uid = uid, domainID = "session_logs_storage", scanned = scanned, rewrapped = rewrapped, changed = 0)
            lastDocument = snapshot.documents.lastOrNull()
        }

        checkpoint(jobId = jobId, uid = uid, domainID = "session_logs_storage", scanned = scanned, rewrapped = rewrapped, changed = 0)
        return CloudVaultRotationRewrapProgress(0, 0, 0, scannedStorageBlobs = scanned, rewrappedStorageBlobs = rewrapped)
    }

    private suspend fun rewrapCollection(
        uid: String,
        collectionID: String,
        jobId: String,
        oldKey: ByteArray,
        newKey: ByteArray,
        newVaultKeyID: String,
        vaultGeneration: Int,
    ): CloudVaultRotationRewrapProgress {
        val collection = firestore.collection("users").document(uid).collection(collectionID)
        var scanned = 0
        var rewrapped = 0
        var changed = 0
        var lastDocument: DocumentSnapshot? = null

        while (true) {
            var query = collection.orderBy(FieldPath.documentId()).limit(batchLimit)
            lastDocument?.let { query = query.startAfter(it) }
            val snapshot = query.get().await()
            if (snapshot.documents.isEmpty()) break

            for (document in snapshot.documents) {
                scanned += 1
                val result =
                    CloudVaultCrypto.rewrapCloudVaultDocument(
                        data = document.data.orEmpty(),
                        uid = uid,
                        collection = collectionID,
                        docID = document.id,
                        oldKey = oldKey,
                        newKey = newKey,
                        newVaultKeyID = newVaultKeyID,
                        vaultGeneration = vaultGeneration,
                        rotationJobId = jobId,
                    )
                if (!result.changed) continue
                document.reference.update(updatePayload(result, vaultGeneration, jobId)).await()
                rewrapped += 1
                changed += result.changedFields.size
            }

            lastDocument = snapshot.documents.lastOrNull()
        }

        return CloudVaultRotationRewrapProgress(
            scannedDocuments = scanned,
            rewrappedDocuments = rewrapped,
            changedFields = changed,
        )
    }

    private suspend fun beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int,
    ): CloudVaultRotationUploadTicket {
        val raw =
            functions
                .getHttpsCallable("beginEncryptedSessionBlobUpload")
                .call(
                    mapOf(
                        "documentID" to documentID,
                        "bodyHash" to bodyHash,
                        "encryptedByteCount" to byteCount,
                        "contentType" to "application/octet-stream",
                    ),
                ).await()
                .getData() as? Map<*, *> ?: error("Invalid encrypted blob upload ticket")
        return CloudVaultRotationUploadTicket(
            storagePath = raw["storagePath"] as? String ?: error("Missing storagePath"),
            uploadURL = raw["uploadURL"] as? String ?: error("Missing uploadURL"),
        )
    }

    private fun uploadEncryptedBody(data: ByteArray, ticket: CloudVaultRotationUploadTicket) {
        val request =
            Request
                .Builder()
                .url(ticket.uploadURL)
                .put(data.toRequestBody("application/octet-stream".toMediaType()))
                .build()
        httpClient.newCall(request).execute().use { response ->
            check(response.isSuccessful) { "Encrypted session blob upload failed: ${response.code}" }
        }
    }

    private suspend fun commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: Map<String, Any>,
        chunks: List<Map<String, Any>>,
    ) {
        functions
            .getHttpsCallable("commitEncryptedSearchIndexBatch")
            .call(
                mapOf(
                    "deviceId" to deviceId,
                    "indexVersion" to indexVersion,
                    "documents" to listOf(document),
                    "chunks" to chunks,
                ),
            ).await()
    }

    private suspend fun downloadEncryptedBody(storagePath: String): ByteArray {
        val raw =
            functions
                .getHttpsCallable("getEncryptedSessionBlobDownloadUrl")
                .call(mapOf("storagePath" to storagePath))
                .await()
                .getData() as? Map<*, *> ?: error("Invalid encrypted blob download URL")
        val downloadURL = raw["downloadURL"] as? String ?: error("Missing downloadURL")
        return URL(downloadURL).openStream().use { it.readBytes() }
    }

    private suspend fun deleteEncryptedSessionBlob(documentID: String, storagePath: String) {
        functions
            .getHttpsCallable("deleteEncryptedSessionBlob")
            .call(mapOf("documentID" to documentID, "storagePath" to storagePath))
            .await()
    }

    private fun titlePlaintext(
        raw: Any?,
        uid: String,
        docID: String,
        oldKey: ByteArray,
        newKey: ByteArray,
    ): String? {
        val sealed = CloudVaultCrypto.sealedTextFromMap(raw as? Map<*, *>) ?: return null
        val aad = CloudVaultAADContext(uid = uid, collection = "session_logs", docID = docID, field = "sealedTitle")
        return runCatching { CloudVaultCrypto.openText(sealed, newKey, aad) }.getOrNull()
            ?: runCatching { CloudVaultCrypto.openText(sealed, oldKey, aad) }.getOrNull()
    }

    private fun blobEnvelopeFromJson(data: ByteArray): CloudVaultBlobEnvelope {
        val objectJson = JSONObject(data.toString(Charsets.UTF_8))
        val map =
            objectJson
                .keys()
                .asSequence()
                .associateWith { key ->
                    objectJson.get(key).takeUnless { it == JSONObject.NULL }
                }
        return CloudVaultCrypto.blobEnvelopeFromMap(map) ?: error("Invalid encrypted blob envelope")
    }

    private fun chunkUtf8String(text: String, maxBytes: Int): List<String> {
        if (text.toByteArray(Charsets.UTF_8).size <= maxBytes) return listOf(text)
        val chunks = mutableListOf<String>()
        var current = StringBuilder()
        var currentBytes = 0
        for (ch in text) {
            val charBytes = ch.toString().toByteArray(Charsets.UTF_8).size
            if (currentBytes > 0 && currentBytes + charBytes > maxBytes) {
                chunks += current.toString()
                current = StringBuilder()
                currentBytes = 0
            }
            current.append(ch)
            currentBytes += charBytes
        }
        if (current.isNotEmpty()) chunks += current.toString()
        return chunks.ifEmpty { listOf(text) }
    }

    private fun updatePayload(
        result: CloudVaultDocumentRewrapResult,
        vaultGeneration: Int,
        jobId: String,
    ): Map<String, Any> {
        val updates = linkedMapOf<String, Any>()
        for (field in result.changedFields) {
            result.data[field]?.let { updates[field] = it }
        }
        for (companion in listOf("vaultKeyID", "sealedStateVaultKeyID")) {
            result.data[companion]?.let { updates[companion] = it }
        }
        updates["vaultGeneration"] = vaultGeneration
        updates["rewrapJobId"] = jobId
        updates["updatedAt"] = FieldValue.serverTimestamp()
        return updates
    }

    private suspend fun checkpoint(
        jobId: String,
        uid: String,
        domainID: String,
        scanned: Int,
        rewrapped: Int,
        changed: Int,
    ) {
        firestore
            .collection("users")
            .document(uid)
            .collection("cloud_vault_rotation_jobs")
            .document(jobId)
            .collection("checkpoints")
            .document(domainID)
            .set(
                mapOf(
                    "domainID" to domainID,
                    "status" to "documents_complete",
                    "scannedDocumentCount" to scanned,
                    "rewrappedDocumentCount" to rewrapped,
                    "changedFieldCount" to changed,
                    "updatedAt" to FieldValue.serverTimestamp(),
                ),
                SetOptions.merge(),
            ).await()
    }
}

package com.openburnbar.data.cloud

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.firebase.FunctionsRepository
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import org.json.JSONObject

private const val VAULT_KEY_WRAPPER_QUERY_LIMIT = 5

data class CloudConversationSearchRow(
    val id: String,
    val documentID: String,
    val title: String,
    val snippet: String,
    val provider: String?,
    val storagePath: String,
    val bodyHash: String,
    val bodyHashVersion: Int,
    val score: Double,
)

class CloudConversationSearchService(
    private val functions: FunctionsRepository = FunctionsRepository(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
) {
    private val firestore = Firebase.firestore

    fun isSignedIn(): Boolean = auth.currentUser != null

    suspend fun prepareCallableAuth(forceRefresh: Boolean = false): Boolean {
        val user = auth.currentUser ?: return false
        return try {
            user.getIdToken(forceRefresh).await().token?.isNotBlank() == true
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            false
        }
    }

    suspend fun search(query: String, limit: Int = 25): List<CloudConversationSearchRow> {
        val uid = auth.currentUser?.uid ?: return emptyList()
        val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        registerDevice(uid, keypair)
        val vaultKey = unlockVaultKey(uid, keypair) ?: return emptyList()
        val tokenHashes = CloudVaultCrypto.tokenHashes(query, vaultKey, limit = 10)
        val semanticHashes = CloudVaultCrypto.semanticHashes(query, vaultKey, limit = 12)
        if (tokenHashes.isEmpty() && semanticHashes.isEmpty()) return emptyList()

        return functions.searchEncryptedConversationIndex(tokenHashes, semanticHashes, limit)
            .mapNotNull { hit ->
                runCatching {
                    CloudConversationSearchRow(
                        id = hit.id,
                        documentID = hit.documentID,
                        title =
                            CloudVaultCrypto.openText(
                                hit.sealedTitle,
                                vaultKey,
                                CloudVaultAADContext(
                                    uid = uid,
                                    collection = "cloud_search_documents",
                                    docID = hit.documentID,
                                    field = "sealedTitle",
                                ),
                            ),
                        snippet =
                            CloudVaultCrypto.openText(
                                hit.sealedSnippet,
                                vaultKey,
                                CloudVaultAADContext(
                                    uid = uid,
                                    collection = "cloud_search_chunks",
                                    docID = hit.chunkID,
                                    field = "sealedSnippet",
                                ),
                            ),
                        provider = hit.provider,
                        storagePath = hit.storagePath,
                        bodyHash = hit.bodyHash,
                        bodyHashVersion = hit.bodyHashVersion ?: 0,
                        score = hit.score,
                    )
                }.getOrNull()
            }
    }

    /**
     * Unlocks the 32-byte cloud vault key for the signed-in user, registering this device's escrow
     * keypair on first use. Returns `null` when signed out or no active key wrapper has reached this
     * device yet (so the cockpit can show a "vault locked on this device" notice).
     */
    suspend fun unlockVaultKeyOrNull(): ByteArray? {
        val uid = auth.currentUser?.uid ?: return null
        val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        registerDevice(uid, keypair)
        return unlockVaultKey(uid, keypair)
    }

    /**
     * Downloads and decrypts the encrypted session body at [storagePath], verifying the integrity
     * identifier matches [bodyHash]. New rows use a vault-keyed HMAC; legacy v1 rows used plaintext
     * SHA-256. Used by the cockpit to open a full transcript on demand without a pre-built search row.
     */
    suspend fun loadBodyAt(storagePath: String, bodyHash: String, bodyHashVersion: Int = 0): String = loadBody(
        CloudConversationSearchRow(
            id = "",
            documentID = sessionLogDocumentID(storagePath) ?: "",
            title = "",
            snippet = "",
            provider = null,
            storagePath = storagePath,
            bodyHash = bodyHash,
            bodyHashVersion = bodyHashVersion,
            score = 0.0,
        ),
    )

    suspend fun loadBody(row: CloudConversationSearchRow): String {
        val uid = auth.currentUser?.uid ?: error("Sign in before opening cloud conversations.")
        val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        registerDevice(uid, keypair)
        val vaultKey =
            unlockVaultKey(uid, keypair)
                ?: error("This device does not have the cloud vault key yet.")
        val documentID = row.documentID.ifBlank { sessionLogDocumentID(row.storagePath) ?: "" }
        require(documentID.isNotBlank()) { "Invalid encrypted conversation body path" }
        val aadContext =
            CloudVaultAADContext(
                uid = uid,
                collection = "session_logs",
                docID = documentID,
                field = "sealedBody",
            )
        val cachedBytes = CloudTranscriptCache.cachedEnvelopeBytes(
            row.storagePath,
            row.bodyHash,
            row.bodyHashVersion,
        )
        val envelopeBytes = cachedBytes ?: downloadEnvelopeBytes(row.storagePath)

        return runCatching {
            openBodyEnvelope(envelopeBytes, row.bodyHash, row.bodyHashVersion, vaultKey, aadContext)
        }.getOrElse { error ->
            if (cachedBytes == null) throw error
            CloudTranscriptCache.remove(row.storagePath, row.bodyHash, row.bodyHashVersion)
            val freshBytes = downloadEnvelopeBytes(row.storagePath)
            openBodyEnvelope(freshBytes, row.bodyHash, row.bodyHashVersion, vaultKey, aadContext).also {
                CloudTranscriptCache.storeEnvelopeBytes(
                    row.storagePath,
                    row.bodyHash,
                    row.bodyHashVersion,
                    freshBytes,
                )
            }
        }.also {
            if (cachedBytes == null) {
                CloudTranscriptCache.storeEnvelopeBytes(
                    row.storagePath,
                    row.bodyHash,
                    row.bodyHashVersion,
                    envelopeBytes,
                )
            }
        }
    }

    private suspend fun downloadEnvelopeBytes(storagePath: String): ByteArray {
        val downloadURL = functions.encryptedSessionBlobDownloadURL(storagePath)
        return withContext(Dispatchers.IO) {
            URL(downloadURL).openStream().use { it.readBytes() }
        }
    }

    private fun openBodyEnvelope(
        bytes: ByteArray,
        bodyHash: String,
        bodyHashVersion: Int,
        vaultKey: ByteArray,
        aadContext: CloudVaultAADContext,
    ): String {
        val envelope = parseBlobEnvelope(bytes.toString(Charsets.UTF_8))
        val plaintext = CloudVaultCrypto.openBlob(envelope, vaultKey, aadContext)
        require(CloudVaultCrypto.expectedSessionBodyHash(plaintext, vaultKey, bodyHashVersion) == bodyHash) {
            "Encrypted conversation body hash mismatch"
        }
        return plaintext.toString(Charsets.UTF_8)
    }

    private fun sessionLogDocumentID(storagePath: String): String? {
        val parts = storagePath.split("/")
        val index = parts.indexOf("session_logs")
        return if (index >= 0 && index + 2 < parts.size && parts[index + 2] == "bodies") {
            parts[index + 1]
        } else {
            null
        }
    }

    private suspend fun registerDevice(uid: String, keypair: AndroidCloudVaultDeviceKeypair) {
        AndroidEscrowDeviceRegistry(firestore).registerSelf(uid = uid, keypair = keypair)
    }

    private suspend fun unlockVaultKey(uid: String, keypair: AndroidCloudVaultDeviceKeypair): ByteArray? {
        val snapshot =
            firestore.collection("users")
                .document(uid)
                .collection("cloud_vault_key_wrappers")
                .whereEqualTo("targetDeviceId", keypair.deviceId)
                .whereEqualTo("status", "active")
                .limit(VAULT_KEY_WRAPPER_QUERY_LIMIT.toLong())
                .get()
                .await()

        for (document in snapshot.documents) {
            val wrapped = document.getString("wrappedVaultKey")
            val version = document.getLong("keyVersion")?.toInt()
            if (wrapped != null && version == keypair.keyVersion) {
                val decrypted = runCatching { keypair.decryptWrappedVaultKey(wrapped) }.getOrNull()
                if (decrypted != null) return decrypted
            }
        }
        return null
    }

    private fun parseBlobEnvelope(json: String): CloudVaultBlobEnvelope {
        val objectJson = JSONObject(json)
        return CloudVaultBlobEnvelope(
            schemaVersion = objectJson.optInt("schemaVersion", 1),
            algorithm = objectJson.getString("algorithm"),
            keyVersion = objectJson.optInt("keyVersion", 1),
            plaintextSHA256 = objectJson.optString("plaintextSHA256").takeIf { it.isNotBlank() },
            plaintextHMAC = objectJson.optString("plaintextHMAC").takeIf { it.isNotBlank() },
            integrityHashVersion = if (objectJson.has("integrityHashVersion")) objectJson.optInt("integrityHashVersion") else null,
            sealedBoxBase64 = objectJson.getString("sealedBoxBase64"),
            aad = objectJson.optString("aad").takeIf { it.isNotBlank() },
        )
    }
}

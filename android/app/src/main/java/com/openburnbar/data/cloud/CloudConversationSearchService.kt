package com.openburnbar.data.cloud

import com.google.firebase.Timestamp
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

data class CloudConversationSearchRow(
    val id: String,
    val title: String,
    val snippet: String,
    val provider: String?,
    val projectName: String?,
    val storagePath: String,
    val bodyHash: String,
    val score: Double
)

class CloudConversationSearchService(
    private val functions: FunctionsRepository = FunctionsRepository(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()
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
                        title = CloudVaultCrypto.openText(hit.sealedTitle, vaultKey),
                        snippet = CloudVaultCrypto.openText(hit.sealedSnippet, vaultKey),
                        provider = hit.provider,
                        projectName = hit.projectName,
                        storagePath = hit.storagePath,
                        bodyHash = hit.bodyHash,
                        score = hit.score
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
     * Downloads and decrypts the encrypted session body at [storagePath], verifying the plaintext
     * SHA-256 matches [bodyHash]. Used by the cockpit to open a full transcript on demand without a
     * pre-built search row.
     */
    suspend fun loadBodyAt(storagePath: String, bodyHash: String): String =
        loadBody(
            CloudConversationSearchRow(
                id = "",
                title = "",
                snippet = "",
                provider = null,
                projectName = null,
                storagePath = storagePath,
                bodyHash = bodyHash,
                score = 0.0
            )
        )

    suspend fun loadBody(row: CloudConversationSearchRow): String {
        val uid = auth.currentUser?.uid ?: throw IllegalStateException("Sign in before opening cloud conversations.")
        val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
        registerDevice(uid, keypair)
        val vaultKey = unlockVaultKey(uid, keypair)
            ?: throw IllegalStateException("This device does not have the cloud vault key yet.")
        val cachedBytes = CloudTranscriptCache.cachedEnvelopeBytes(row.storagePath, row.bodyHash)
        val envelopeBytes = cachedBytes ?: downloadEnvelopeBytes(row.storagePath)

        return runCatching {
            openBodyEnvelope(envelopeBytes, row.bodyHash, vaultKey)
        }.getOrElse { error ->
            if (cachedBytes == null) throw error
            CloudTranscriptCache.remove(row.storagePath, row.bodyHash)
            val freshBytes = downloadEnvelopeBytes(row.storagePath)
            openBodyEnvelope(freshBytes, row.bodyHash, vaultKey).also {
                CloudTranscriptCache.storeEnvelopeBytes(row.storagePath, row.bodyHash, freshBytes)
            }
        }.also {
            if (cachedBytes == null) {
                CloudTranscriptCache.storeEnvelopeBytes(row.storagePath, row.bodyHash, envelopeBytes)
            }
        }
    }

    private suspend fun downloadEnvelopeBytes(storagePath: String): ByteArray {
        val downloadURL = functions.encryptedSessionBlobDownloadURL(storagePath)
        return withContext(Dispatchers.IO) {
            URL(downloadURL).openStream().use { it.readBytes() }
        }
    }

    private fun openBodyEnvelope(bytes: ByteArray, bodyHash: String, vaultKey: ByteArray): String {
        val envelope = parseBlobEnvelope(bytes.toString(Charsets.UTF_8))
        val plaintext = CloudVaultCrypto.openBlob(envelope, vaultKey)
        require(CloudVaultCrypto.sha256Hex(plaintext) == bodyHash) {
            "Encrypted conversation body hash mismatch"
        }
        return plaintext.toString(Charsets.UTF_8)
    }

    private suspend fun registerDevice(uid: String, keypair: AndroidCloudVaultDeviceKeypair) {
        AndroidEscrowDeviceRegistry(firestore).registerSelf(uid = uid, keypair = keypair)
    }

    private suspend fun unlockVaultKey(uid: String, keypair: AndroidCloudVaultDeviceKeypair): ByteArray? {
        val snapshot = firestore.collection("users")
            .document(uid)
            .collection("cloud_vault_key_wrappers")
            .whereEqualTo("targetDeviceId", keypair.deviceId)
            .whereEqualTo("status", "active")
            .limit(5)
            .get()
            .await()

        for (document in snapshot.documents) {
            val wrapped = document.getString("wrappedVaultKey") ?: continue
            val version = document.getLong("keyVersion")?.toInt() ?: continue
            if (version != keypair.keyVersion) continue
            return runCatching { keypair.decryptWrappedVaultKey(wrapped) }.getOrNull() ?: continue
        }
        return null
    }

    private fun parseBlobEnvelope(json: String): CloudVaultBlobEnvelope {
        val objectJson = JSONObject(json)
        return CloudVaultBlobEnvelope(
            schemaVersion = objectJson.optInt("schemaVersion", 1),
            algorithm = objectJson.getString("algorithm"),
            keyVersion = objectJson.optInt("keyVersion", 1),
            plaintextSHA256 = objectJson.getString("plaintextSHA256"),
            sealedBoxBase64 = objectJson.getString("sealedBoxBase64")
        )
    }
}

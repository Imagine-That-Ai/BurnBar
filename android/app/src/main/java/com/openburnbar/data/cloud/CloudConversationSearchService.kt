package com.openburnbar.data.cloud

import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import com.openburnbar.data.firebase.FunctionsRepository
import java.net.URL
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
        val downloadURL = functions.encryptedSessionBlobDownloadURL(row.storagePath)
        val bytes = withContext(Dispatchers.IO) {
            URL(downloadURL).openStream().use { it.readBytes() }
        }
        val envelope = parseBlobEnvelope(bytes.toString(Charsets.UTF_8))
        val plaintext = CloudVaultCrypto.openBlob(envelope, vaultKey)
        require(CloudVaultCrypto.sha256Hex(plaintext) == row.bodyHash) {
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

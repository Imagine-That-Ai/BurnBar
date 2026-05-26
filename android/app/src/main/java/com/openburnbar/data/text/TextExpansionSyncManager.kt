package com.openburnbar.data.text

import android.content.Context
import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.cloud.CloudVaultSealedText
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.db.TextExpansionDao
import com.openburnbar.data.db.TextExpansionSnippetEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.util.Date

class TextExpansionSyncManager(
    private val context: Context,
    private val dao: TextExpansionDao = AppDatabase.getDatabase(context).textExpansionDao(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
) {
    suspend fun sync(): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            // 1. Check sync toggle in SharedPreferences
            val prefs = context.getSharedPreferences("text_expansion_settings", Context.MODE_PRIVATE)
            val isEnabled = prefs.getBoolean("cloud_sync_enabled", true)
            if (!isEnabled) {
                Log.d("TextExpansionSync", "Cloud sync is disabled by user setting.")
                return@withContext Result.success(Unit)
            }

            // 2. Check current authenticated user
            val uid = FirebaseAuth.getInstance().currentUser?.uid
            if (uid == null) {
                Log.d("TextExpansionSync", "No user signed in. Skipping sync.")
                return@withContext Result.success(Unit)
            }

            Log.d("TextExpansionSync", "Starting text expansion sync for $uid...")

            // 3. Load device keypair and register
            val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
            val registry = AndroidEscrowDeviceRegistry(firestore)
            registry.registerSelf(uid = uid, keypair = keypair)

            // 4. Retrieve and unlock vault key
            val vaultKey = unlockVaultKey(uid, keypair)
                ?: return@withContext Result.failure(IllegalStateException("Cloud vault key is not active on this device yet. Please approve this device from your Mac/iPhone."))

            // 5. Upload pending local snippets
            val unsynced = dao.getUnsynced(limit = 200)
            if (unsynced.isNotEmpty()) {
                Log.d("TextExpansionSync", "Uploading ${unsynced.size} unsynced snippets...")
                val collection = firestore.collection("users").document(uid).collection("text_snippets")
                val batch = firestore.batch()

                for (entity in unsynced) {
                    val triggerHash = CloudVaultCrypto.tokenHashes(entity.trigger, vaultKey, limit = 1).firstOrNull()
                        ?: CloudVaultCrypto.sha256Hex(entity.trigger.toByteArray(Charsets.UTF_8))

                    val doc = mapOf(
                        "id" to entity.id,
                        "uid" to uid,
                        "sourceDeviceID" to (entity.sourceDeviceID ?: keypair.deviceId),
                        "triggerHash" to triggerHash,
                        "sealedTitle" to CloudVaultCrypto.sealText(entity.title, vaultKey).toMap(),
                        "sealedTrigger" to CloudVaultCrypto.sealText(entity.trigger, vaultKey).toMap(),
                        "sealedBody" to CloudVaultCrypto.sealText(entity.body, vaultKey).toMap(),
                        "sealedScope" to CloudVaultCrypto.sealText(entity.scopeJson, vaultKey).toMap(),
                        "mode" to entity.mode,
                        "isEnabled" to entity.isEnabled,
                        "revision" to entity.revision,
                        "createdAt" to com.google.firebase.Timestamp(Date(entity.createdAtMillis)),
                        "updatedAt" to com.google.firebase.Timestamp(Date(entity.updatedAtMillis)),
                        "deletedAt" to entity.deletedAtMillis?.let { com.google.firebase.Timestamp(Date(it)) },
                        "schemaVersion" to 1,
                        "encryption" to mapOf(
                            "algorithm" to "AES-256-GCM",
                            "keyVersion" to 1,
                            "tokenHashVersion" to 1
                        )
                    )
                    batch.set(collection.document(entity.id), doc, SetOptions.merge())
                }
                batch.commit().await()
                dao.markSynced(unsynced.map { it.id })
                Log.d("TextExpansionSync", "Uploaded all pending snippets successfully.")
            }

            // 6. Download remote changes and merge (last-write-wins)
            Log.d("TextExpansionSync", "Downloading remote snippets...")
            val remoteSnapshot = firestore.collection("users")
                .document(uid)
                .collection("text_snippets")
                .limit(500)
                .get()
                .await()

            val localMap = dao.getAllIncludingDeleted().associateBy { it.id }

            for (doc in remoteSnapshot.documents) {
                try {
                    val id = doc.getString("id") ?: doc.id
                    val sealedTitleMap = doc.get("sealedTitle") as? Map<*, *> ?: continue
                    val sealedTriggerMap = doc.get("sealedTrigger") as? Map<*, *> ?: continue
                    val sealedBodyMap = doc.get("sealedBody") as? Map<*, *> ?: continue
                    val sealedScopeMap = doc.get("sealedScope") as? Map<*, *> ?: continue
                    val mode = doc.getString("mode") ?: "static"
                    val isEnabled = doc.getBoolean("isEnabled") ?: true
                    val revision = doc.getLong("revision")?.toInt() ?: 1

                    val createdAt = parseTimestamp(doc.get("createdAt")) ?: Date()
                    val updatedAt = parseTimestamp(doc.get("updatedAt")) ?: Date()
                    val deletedAt = parseTimestamp(doc.get("deletedAt"))

                    // Decrypt fields
                    val title = CloudVaultCrypto.openText(sealedTitleMap.toSealedText(), vaultKey)
                    val trigger = CloudVaultCrypto.openText(sealedTriggerMap.toSealedText(), vaultKey)
                    val body = CloudVaultCrypto.openText(sealedBodyMap.toSealedText(), vaultKey)
                    val scopeJson = CloudVaultCrypto.openText(sealedScopeMap.toSealedText(), vaultKey)

                    val localSnippet = localMap[id]
                    if (localSnippet != null && localSnippet.updatedAtMillis >= updatedAt.time) {
                        // Local is newer or identical, skip saving remote
                        continue
                    }

                    val merged = TextExpansionSnippetEntity(
                        id = id,
                        title = title,
                        trigger = trigger,
                        body = body,
                        mode = mode,
                        isEnabled = isEnabled,
                        scopeJson = scopeJson,
                        revision = revision,
                        createdAtMillis = createdAt.time,
                        updatedAtMillis = updatedAt.time,
                        deletedAtMillis = deletedAt?.time,
                        syncedAtMillis = System.currentTimeMillis(),
                        sourceDeviceID = doc.getString("sourceDeviceID") ?: keypair.deviceId
                    )
                    dao.upsert(merged)
                } catch (e: Exception) {
                    Log.e("TextExpansionSync", "Failed to decrypt or merge remote snippet ${doc.id}: ${e.message}", e)
                }
            }

            Log.d("TextExpansionSync", "Text expansion sync complete.")
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e("TextExpansionSync", "Failed to sync text expansion snippets: ${e.message}", e)
            Result.failure(e)
        }
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

    private fun Map<*, *>.toSealedText(): CloudVaultSealedText {
        return CloudVaultSealedText(
            algorithm = this["algorithm"] as? String ?: "AES-256-GCM",
            keyVersion = (this["keyVersion"] as? Number)?.toInt() ?: 1,
            nonce = this["nonce"] as? String ?: "",
            ciphertext = this["ciphertext"] as? String ?: "",
            tag = this["tag"] as? String ?: ""
        )
    }

    private fun CloudVaultSealedText.toMap(): Map<String, Any> {
        return mapOf(
            "algorithm" to algorithm,
            "keyVersion" to keyVersion,
            "nonce" to nonce,
            "ciphertext" to ciphertext,
            "tag" to tag
        )
    }

    private fun parseTimestamp(value: Any?): Date? {
        if (value == null) return null
        if (value is com.google.firebase.Timestamp) return value.toDate()
        if (value is Date) return value
        if (value is Number) return Date(value.toLong())
        return null
    }
}

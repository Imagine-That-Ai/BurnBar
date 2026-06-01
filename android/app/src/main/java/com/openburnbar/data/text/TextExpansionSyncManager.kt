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
import java.lang.IllegalStateException
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext

private const val VAL_5 = 5
private const val VAL_500 = 500

class TextExpansionSyncManager(
    private val context: Context,
    private val dao: TextExpansionDao = AppDatabase.getDatabase(context).textExpansionDao(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
) {
    suspend fun sync(): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            if (!isCloudSyncEnabled()) {
                Log.d("TextExpansionSync", "Cloud sync is disabled by user setting.")
                return@withContext Result.success(Unit)
            }

            val uid = FirebaseAuth.getInstance().currentUser?.uid
            if (uid == null) {
                Log.d("TextExpansionSync", "No user signed in. Skipping sync.")
                return@withContext Result.success(Unit)
            }

            Log.d("TextExpansionSync", "Starting text expansion sync for $uid...")

            val keypair = AndroidCloudVaultDeviceKeypair.loadOrCreate()
            val registry = AndroidEscrowDeviceRegistry(firestore)
            registry.registerSelf(uid = uid, keypair = keypair)

            val vaultKey =
                unlockVaultKey(uid, keypair)
                    ?: return@withContext Result.failure(IllegalStateException("Cloud vault key is not active on this device yet. Please approve this device from your Mac/iPhone."))

            uploadPendingSnippets(uid, vaultKey, keypair)
            downloadAndMergeSnippets(uid, vaultKey, keypair)

            Log.d("TextExpansionSync", "Text expansion sync complete.")
            Result.success(Unit)
        } catch (e: IllegalStateException) {
            Log.e("TextExpansionSync", "Failed to sync text expansion snippets: ${e.message}", e)
            Result.failure(e)
        }
    }

    private fun isCloudSyncEnabled(): Boolean {
        val prefs = context.getSharedPreferences("text_expansion_settings", Context.MODE_PRIVATE)
        return prefs.getBoolean("cloud_sync_enabled", true)
    }

    private suspend fun uploadPendingSnippets(uid: String, vaultKey: ByteArray, keypair: AndroidCloudVaultDeviceKeypair) {
        val unsynced = dao.getUnsynced(limit = 200)
        if (unsynced.isEmpty()) return

        Log.d("TextExpansionSync", "Uploading ${unsynced.size} unsynced snippets...")
        val collection = firestore.collection("users").document(uid).collection("text_snippets")
        val batch = firestore.batch()

        for (entity in unsynced) {
            val triggerHash =
                CloudVaultCrypto.tokenHashes(entity.trigger, vaultKey, limit = 1).firstOrNull()
                    ?: CloudVaultCrypto.sha256Hex(entity.trigger.toByteArray(Charsets.UTF_8))

            val doc =
                mapOf(
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
                    "encryption" to
                        mapOf(
                            "algorithm" to "AES-256-GCM",
                            "keyVersion" to 1,
                            "tokenHashVersion" to 1,
                        ),
                )
            batch.set(collection.document(entity.id), doc, SetOptions.merge())
        }
        batch.commit().await()
        dao.markSynced(unsynced.map { it.id })
        Log.d("TextExpansionSync", "Uploaded all pending snippets successfully.")
    }

    private suspend fun downloadAndMergeSnippets(uid: String, vaultKey: ByteArray, keypair: AndroidCloudVaultDeviceKeypair) {
        Log.d("TextExpansionSync", "Downloading remote snippets...")
        val remoteSnapshot =
            firestore.collection("users")
                .document(uid)
                .collection("text_snippets")
                .limit(VAL_500.toLong())
                .get()
                .await()

        val localMap = dao.getAllIncludingDeleted().associateBy { it.id }

        for (doc in remoteSnapshot.documents) {
            runCatching {
                mergeRemoteSnippet(doc, localMap, vaultKey, keypair, dao)
            }.onFailure { e ->
                if (e is IllegalStateException) {
                    Log.e("TextExpansionSync", "Failed to decrypt or merge remote snippet ${doc.id}: ${e.message}", e)
                } else {
                    throw e
                }
            }
        }
    }

    private suspend fun mergeRemoteSnippet(
        doc: com.google.firebase.firestore.DocumentSnapshot,
        localMap: Map<String, TextExpansionSnippetEntity>,
        vaultKey: ByteArray,
        keypair: AndroidCloudVaultDeviceKeypair,
        dao: TextExpansionDao,
    ) {
        val id = doc.getString("id") ?: doc.id
        val sealedTitleMap = doc.get("sealedTitle") as? Map<*, *>
        val sealedTriggerMap = doc.get("sealedTrigger") as? Map<*, *>
        val sealedBodyMap = doc.get("sealedBody") as? Map<*, *>
        val sealedScopeMap = doc.get("sealedScope") as? Map<*, *>
        val hasRequiredSealedMaps =
            sealedTitleMap != null &&
                sealedTriggerMap != null &&
                sealedBodyMap != null &&
                sealedScopeMap != null
        if (!hasRequiredSealedMaps) {
            return
        }
        val mode = doc.getString("mode") ?: "static"
        val isEnabled = doc.getBoolean("isEnabled") ?: true
        val revision = doc.getLong("revision")?.toInt() ?: 1

        val createdAt = parseTimestamp(doc.get("createdAt")) ?: Date()
        val updatedAt = parseTimestamp(doc.get("updatedAt")) ?: Date()
        val deletedAt = parseTimestamp(doc.get("deletedAt"))

        val title = CloudVaultCrypto.openText(sealedTitleMap.toSealedText(), vaultKey)
        val trigger = CloudVaultCrypto.openText(sealedTriggerMap.toSealedText(), vaultKey)
        val body = CloudVaultCrypto.openText(sealedBodyMap.toSealedText(), vaultKey)
        val scopeJson = CloudVaultCrypto.openText(sealedScopeMap.toSealedText(), vaultKey)

        val localSnippet = localMap[id]
        val localIsCurrent = localSnippet != null && localSnippet.updatedAtMillis >= updatedAt.time
        if (localIsCurrent) return

        val merged =
            TextExpansionSnippetEntity(
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
                sourceDeviceID = doc.getString("sourceDeviceID") ?: keypair.deviceId,
            )
        dao.upsert(merged)
    }

    private suspend fun unlockVaultKey(uid: String, keypair: AndroidCloudVaultDeviceKeypair): ByteArray? {
        val snapshot =
            firestore.collection("users")
                .document(uid)
                .collection("cloud_vault_key_wrappers")
                .whereEqualTo("targetDeviceId", keypair.deviceId)
                .whereEqualTo("status", "active")
                .limit(VAL_5.toLong())
                .get()
                .await()

        return snapshot.documents.firstNotNullOfOrNull { document ->
            val wrapped = document.getString("wrappedVaultKey")
            val version = document.getLong("keyVersion")?.toInt()
            if (wrapped != null && version == keypair.keyVersion) {
                runCatching { keypair.decryptWrappedVaultKey(wrapped) }.getOrNull()
            } else {
                null
            }
        }
    }

    private fun Map<*, *>.toSealedText(): CloudVaultSealedText {
        return CloudVaultSealedText(
            algorithm = this["algorithm"] as? String ?: "AES-256-GCM",
            keyVersion = (this["keyVersion"] as? Number)?.toInt() ?: 1,
            nonce = this["nonce"] as? String ?: "",
            ciphertext = this["ciphertext"] as? String ?: "",
            tag = this["tag"] as? String ?: "",
        )
    }

    private fun CloudVaultSealedText.toMap(): Map<String, Any> {
        return mapOf(
            "algorithm" to algorithm,
            "keyVersion" to keyVersion,
            "nonce" to nonce,
            "ciphertext" to ciphertext,
            "tag" to tag,
        )
    }

    private fun parseTimestamp(value: Any?): Date? = when (value) {
        null -> null
        is com.google.firebase.Timestamp -> value.toDate()
        is Date -> value
        is Number -> Date(value.toLong())
        else -> null
    }
}

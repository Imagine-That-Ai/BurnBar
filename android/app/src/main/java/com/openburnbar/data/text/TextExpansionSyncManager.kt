package com.openburnbar.data.text

import android.content.Context
import android.util.Log
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.openburnbar.data.cloud.AndroidCloudVaultDeviceKeypair
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.AndroidEscrowDeviceRegistry
import com.openburnbar.data.cloud.CloudVaultAADContext
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

private const val REMOTE_SNIPPET_FETCH_LIMIT = 500

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
                AndroidCloudVaultKeyAccess.keyForWriting(uid = uid, firestore = firestore).keyData

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
            fun seal(value: String, field: String) = CloudVaultCrypto.sealText(
                value,
                vaultKey,
                CloudVaultAADContext(
                    uid = uid,
                    collection = "text_snippets",
                    docID = entity.id,
                    field = field,
                ),
            ).toMap()

            val doc =
                mapOf(
                    "id" to entity.id,
                    "uid" to uid,
                    "sourceDeviceID" to (entity.sourceDeviceID ?: keypair.deviceId),
                    "triggerHash" to triggerHash,
                    "sealedTitle" to seal(entity.title, "sealedTitle"),
                    "sealedTrigger" to seal(entity.trigger, "sealedTrigger"),
                    "sealedBody" to seal(entity.body, "sealedBody"),
                    "sealedScope" to seal(entity.scopeJson, "sealedScope"),
                    "mode" to entity.mode,
                    "isEnabled" to entity.isEnabled,
                    "revision" to entity.revision,
                    "createdAt" to com.google.firebase.Timestamp(Date(entity.createdAtMillis)),
                    "updatedAt" to com.google.firebase.Timestamp(Date(entity.updatedAtMillis)),
                    "deletedAt" to entity.deletedAtMillis?.let { com.google.firebase.Timestamp(Date(it)) },
                    "schemaVersion" to CloudVaultCrypto.CURRENT_SEALED_TEXT_SCHEMA_VERSION,
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
                .limit(REMOTE_SNIPPET_FETCH_LIMIT.toLong())
                .get()
                .await()

        val localMap = dao.getAllIncludingDeleted().associateBy { it.id }

        for (doc in remoteSnapshot.documents) {
            runCatching {
                mergeRemoteSnippet(doc, uid, localMap, vaultKey, keypair, dao)
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
        uid: String,
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

        fun context(field: String) = CloudVaultAADContext(
            uid = uid,
            collection = "text_snippets",
            docID = id,
            field = field,
        )
        val title = CloudVaultCrypto.openText(sealedTitleMap.toSealedText(), vaultKey, context("sealedTitle"))
        val trigger = CloudVaultCrypto.openText(sealedTriggerMap.toSealedText(), vaultKey, context("sealedTrigger"))
        val body = CloudVaultCrypto.openText(sealedBodyMap.toSealedText(), vaultKey, context("sealedBody"))
        val scopeJson = CloudVaultCrypto.openText(sealedScopeMap.toSealedText(), vaultKey, context("sealedScope"))

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

    private fun Map<*, *>.toSealedText(): CloudVaultSealedText {
        return CloudVaultSealedText(
            algorithm = this["algorithm"] as? String ?: "AES-256-GCM",
            keyVersion = (this["keyVersion"] as? Number)?.toInt() ?: 1,
            nonce = this["nonce"] as? String ?: "",
            ciphertext = this["ciphertext"] as? String ?: "",
            tag = this["tag"] as? String ?: "",
            schemaVersion = (this["schemaVersion"] as? Number)?.toInt(),
            aad = this["aad"] as? String,
        )
    }

    private fun CloudVaultSealedText.toMap(): Map<String, Any> {
        return buildMap {
            schemaVersion?.let { put("schemaVersion", it) }
            aad?.let { put("aad", it) }
            putAll(
                mapOf(
                    "algorithm" to algorithm,
                    "keyVersion" to keyVersion,
                    "nonce" to nonce,
                    "ciphertext" to ciphertext,
                    "tag" to tag,
                ),
            )
        }
    }

    private fun parseTimestamp(value: Any?): Date? = when (value) {
        null -> null
        is com.google.firebase.Timestamp -> value.toDate()
        is Date -> value
        is Number -> Date(value.toLong())
        else -> null
    }
}

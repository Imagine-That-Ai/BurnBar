package com.openburnbar.data.square

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.cloud.AndroidCloudVaultKeyAccess
import com.openburnbar.data.cloud.CloudVaultCrypto
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.missions.MobileMissionConsoleHost
import java.lang.IllegalStateException
import kotlinx.coroutines.tasks.await

private const val VAL_10000000000_L = 10_000_000_000L
private const val VAL_200 = 200

data class CLIAgentToolUse(
    val id: String,
    val name: String,
    val status: String,
    val detail: String?,
    val startedAtEpoch: Long?,
)

data class CLIAgentMessage(
    val id: String,
    val role: String,
    val text: String,
    val timestampEpoch: Long?,
    val isError: Boolean,
    val toolUses: List<CLIAgentToolUse>,
)

data class CLIAgentSessionRecord(
    val id: String,
    val agent: String,
    val agentURI: String,
    val sourceKind: String,
    val title: String,
    val preview: String,
    val modelName: String?,
    val workspaceLabel: String?,
    val updatedAtEpoch: Long,
    val messages: List<CLIAgentMessage>,
    val resumeProviderSessionID: String? = null,
    val canResume: Boolean = false,
    val canForward: Boolean = true,
    val customTitle: String? = null,
    val labelColorHex: String? = null,
    val isPinned: Boolean = false,
    val priorityOrder: Int? = null,
) {
    val searchableText: String =
        listOf(
            title,
            preview,
            agent,
            modelName.orEmpty(),
            workspaceLabel.orEmpty(),
            messages.joinToString(" ") { message ->
                listOf(
                    message.role,
                    message.text,
                    message.toolUses.joinToString(" ") { tool ->
                        listOf(tool.name, tool.status, tool.detail.orEmpty()).joinToString(" ")
                    },
                ).joinToString(" ")
            },
        ).joinToString(" ")

    val resumeLookupID: String
        get() {
            val prefix = "archive:${agent.lowercase()}:"
            return if (sourceKind == "archived_log" && id.startsWith(prefix)) {
                id.removePrefix(prefix)
            } else {
                id
            }
        }
}

// MARK: - Thread Inbox Store (Android parity)
//
// Aggregator that holds the merged list of inbox items + last-refresh
// timestamp. Reads the same `cli_sessions` mirror used by iOS so Codex,
// Claude Code, and OpenClaw sessions appear in Android Hermes Square.

class ThreadInboxStore private constructor(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
) {
    var items by mutableStateOf<List<ThreadInboxItem>>(emptyList())
        private set
    var isLoading by mutableStateOf(false)
        private set
    var refreshError by mutableStateOf<String?>(null)
        private set
    var lastRefreshedAtEpoch by mutableStateOf<Long?>(null)
        private set
    var cliSessionsByItemID by mutableStateOf<Map<String, CLIAgentSessionRecord>>(emptyMap())
        private set

    private var historyStore: AssistantChatHistoryStore? = null
    private var missionHost: MobileMissionConsoleHost? = null

    fun bind(historyStore: AssistantChatHistoryStore? = null, missionHost: MobileMissionConsoleHost? = null) {
        if (historyStore != null) this.historyStore = historyStore
        if (missionHost != null) this.missionHost = missionHost
    }

    fun replace(items: List<ThreadInboxItem>) {
        this.items = items.sortedForInbox()
        this.lastRefreshedAtEpoch = System.currentTimeMillis()
        this.isLoading = false
        this.refreshError = null
    }

    fun beginLoading() {
        isLoading = true
    }

    suspend fun refreshFromCloud() {
        if (isLoading) return
        isLoading = true
        refreshError = null
        try {
            val uid = auth.currentUser?.uid
            if (uid.isNullOrBlank()) {
                items = emptyList()
                lastRefreshedAtEpoch = null
                return
            }

            // 1. Fetch CLI mirrored sessions
            val snapshot =
                firestore.collection("users")
                    .document(uid)
                    .collection("cli_sessions")
                    .orderBy("updatedAt", Query.Direction.DESCENDING)
                    .limit(VAL_200.toLong())
                    .get()
                    .await()

            // Resolve the Cloud Vault key so sealed sessions (Mac writes the whole
            // record sealed — transcript + customTitle inside `sealedPayload`) can be
            // opened on-device. A missing key (vault not yet active here) leaves
            // sealed docs unrenderable; legacy plaintext docs still parse without it.
            val vaultKey =
                runCatching {
                    AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore)?.keyData
                }.getOrNull()

            val parsed = snapshot.documents.mapNotNull { document -> parseCLISession(document.data.orEmpty(), document.id, vaultKey) }
            val parts = buildThreadInboxRefreshParts(parsed, historyStore, missionHost)
            cliSessionsByItemID = parts.cliSessionsByItemID
            items = parts.items
            lastRefreshedAtEpoch = System.currentTimeMillis()
        } catch (e: IllegalStateException) {
            refreshError = e.message ?: e::class.java.simpleName
        } finally {
            isLoading = false
        }
    }

    suspend fun updateSessionMetadata(
        id: String,
        customTitle: String? = null,
        labelColorHex: String? = null,
        isPinned: Boolean? = null,
        priorityOrder: Int? = null,
    ) {
        val uid = auth.currentUser?.uid ?: return
        val docRef =
            firestore.collection("users")
                .document(uid)
                .collection("cli_sessions")
                .document(id)

        // `customTitle` is private text and may legally exist only inside the
        // sealed payload — never top-level (the tightened rules reject a
        // plaintext customTitle). So a rename re-seals the whole record, mirroring
        // the already-correct `AssistantChatHistoryStore.updateThreadMetadata`
        // (read → mutate the full record → re-seal → write). `labelColorHex` /
        // `isPinned` / `priorityOrder` stay as the existing top-level merge write.
        if (customTitle != null) {
            val resealed =
                runCatching { resealSessionWithCustomTitle(uid, docRef, customTitle) }.getOrDefault(false)
            // If we couldn't read/re-seal (legacy plaintext doc with no sealed
            // body, or vault key unavailable), fall back to a top-level merge so
            // the rename still lands; the next Mac mirror reconciles it sealed.
            if (resealed) {
                applyTopLevelMetadata(docRef, labelColorHex, isPinned, priorityOrder)
                refreshFromCloud()
                return
            }
        }

        val updates = mutableMapOf<String, Any?>()
        if (customTitle != null) {
            updates["customTitle"] = if (customTitle.isEmpty()) FieldValue.delete() else customTitle
        }
        if (labelColorHex != null) {
            updates["labelColorHex"] = if (labelColorHex == "#NONE#") FieldValue.delete() else labelColorHex
        }
        if (isPinned != null) {
            updates["isPinned"] = isPinned
        }
        if (priorityOrder != null) {
            updates["priorityOrder"] = if (priorityOrder <= 0) FieldValue.delete() else priorityOrder
        }

        if (updates.isNotEmpty()) {
            docRef.update(updates).await()
            refreshFromCloud()
        }
    }

    /**
     * Re-seals the existing session record with a new (or cleared) `customTitle`
     * folded into the sealed payload. Returns `true` when the doc was sealed and
     * has been re-written; `false` when there's no sealed body to re-seal (legacy
     * plaintext doc) or the vault key is unavailable, so the caller can fall back
     * to a top-level merge.
     *
     * The whole `CLIAgentSealedSessionPayload` is decoded and re-encoded so every
     * Mac-written field (transcript, tokenUsage, endedAt, resume handle, …)
     * survives the rename losslessly.
     */
    private suspend fun resealSessionWithCustomTitle(
        uid: String,
        docRef: com.google.firebase.firestore.DocumentReference,
        customTitle: String,
    ): Boolean {
        val snapshot = docRef.get().await()
        val data = snapshot.data ?: return false
        val isSealed = data["contentSealed"] == true || data["sealedPayload"] != null
        if (!isSealed) return false

        val resolvedKey = AndroidCloudVaultKeyAccess.keyForReading(uid = uid, firestore = firestore) ?: return false
        val envelope = CloudVaultCrypto.sealedPayloadFromMap(data["sealedPayload"] as? Map<*, *>) ?: return false

        val current =
            runCatching {
                cliAgentSealedSessionJson.decodeFromString(
                    CLIAgentSealedSessionPayload.serializer(),
                    CloudVaultCrypto.openPayload(envelope, resolvedKey.keyData).toString(Charsets.UTF_8),
                )
            }.getOrNull() ?: return false

        val updated = current.copy(customTitle = customTitle.ifEmpty { null })
        val sealed =
            CloudVaultCrypto.sealPayload(
                cliAgentSealedSessionJson.encodeToString(CLIAgentSealedSessionPayload.serializer(), updated)
                    .toByteArray(Charsets.UTF_8),
                resolvedKey.keyData,
                resolvedKey.vaultKeyID,
            )

        val payload =
            mapOf(
                "contentSealed" to true,
                "sealedSchemaVersion" to 1,
                "vaultKeyID" to resolvedKey.vaultKeyID,
                "updatedAt" to FieldValue.serverTimestamp(),
                "sealedPayload" to CloudVaultCrypto.sealedPayloadMap(sealed),
                // Defensively clear any legacy top-level plaintext customTitle so a
                // re-sealed doc never carries the private title outside the vault.
                "customTitle" to FieldValue.delete(),
            )
        docRef.set(payload, com.google.firebase.firestore.SetOptions.merge()).await()
        return true
    }

    private suspend fun applyTopLevelMetadata(
        docRef: com.google.firebase.firestore.DocumentReference,
        labelColorHex: String?,
        isPinned: Boolean?,
        priorityOrder: Int?,
    ) {
        val updates = mutableMapOf<String, Any?>()
        if (labelColorHex != null) {
            updates["labelColorHex"] = if (labelColorHex == "#NONE#") FieldValue.delete() else labelColorHex
        }
        if (isPinned != null) {
            updates["isPinned"] = isPinned
        }
        if (priorityOrder != null) {
            updates["priorityOrder"] = if (priorityOrder <= 0) FieldValue.delete() else priorityOrder
        }
        if (updates.isNotEmpty()) {
            docRef.update(updates).await()
        }
    }

    fun cliSessionFor(item: ThreadInboxItem): CLIAgentSessionRecord? = cliSessionsByItemID[item.id]

    private fun parseCLISession(
        data: Map<String, Any>,
        documentID: String,
        vaultKey: ByteArray? = null,
    ): CLIAgentSessionRecord? {
        // Sealed branch (current Mac/iOS writers): the whole record — transcript,
        // customTitle, workspace label — lives inside `sealedPayload`. Top-level
        // fields carry only non-private routing/sort metadata. Mirror the iOS
        // reader (`CLIAgentSessionCodec.decodeSealed`) and the Android assistant
        // sealed-read in `AssistantChatHistoryStore.decodeThread`.
        if (data["contentSealed"] == true || data["sealedPayload"] != null) {
            return parseSealedCLISession(data, documentID, vaultKey)
        }

        // Legacy plaintext branch — kept so in-flight/legacy docs written before
        // the seal migration still render. New writers never take this path.
        val agent = data["agent"] as? String ?: return null
        val runtime = runtimeForAgent(agent) ?: return null
        val recordID = (data["id"] as? String)?.ifBlank { null } ?: documentID
        val updatedAt = epochMillis(data["updatedAt"]) ?: System.currentTimeMillis()
        val customTitle = data["customTitle"] as? String
        val labelColorHex = data["labelColorHex"] as? String
        val isPinned = data["isPinned"] as? Boolean ?: false
        val priorityOrder = (data["priorityOrder"] as? Number)?.toInt()
        val resumeHandle = data["resumeHandle"] as? Map<*, *>
        return CLIAgentSessionRecord(
            id = recordID,
            agent = agent,
            agentURI = AgentIdentity.builtInURI(runtime),
            sourceKind = data["sourceKind"] as? String ?: "live_chat",
            title = (data["title"] as? String)?.ifBlank { "(no title)" } ?: "(no title)",
            preview = data["preview"] as? String ?: "",
            modelName = data["modelName"] as? String,
            workspaceLabel = data["workspaceLabel"] as? String,
            updatedAtEpoch = updatedAt,
            messages = parseMessages(data["messages"]),
            resumeProviderSessionID = resumeHandle?.get("providerSessionID") as? String,
            canResume = resumeHandle?.get("canResume") as? Boolean ?: false,
            canForward = resumeHandle?.get("canForward") as? Boolean ?: true,
            customTitle = customTitle,
            labelColorHex = labelColorHex,
            isPinned = isPinned,
            priorityOrder = priorityOrder,
        )
    }

    /**
     * Opens a sealed `cli_sessions` document and rebuilds the in-app record from
     * the decrypted `CLIAgentSessionRecord` JSON. Returns `null` (the doc is
     * skipped) when the vault key is unavailable, the envelope is malformed, the
     * payload fails to decode, or the agent token isn't recognised — the same
     * fail-soft contract the plaintext branch and the iOS reader use.
     */
    private fun parseSealedCLISession(
        data: Map<String, Any>,
        documentID: String,
        vaultKey: ByteArray?,
    ): CLIAgentSessionRecord? {
        val key = vaultKey ?: return null
        val envelope = CloudVaultCrypto.sealedPayloadFromMap(data["sealedPayload"] as? Map<*, *>) ?: return null
        val payload =
            runCatching {
                val bytes = CloudVaultCrypto.openPayload(envelope, key)
                cliAgentSealedSessionJson.decodeFromString(
                    CLIAgentSealedSessionPayload.serializer(),
                    bytes.toString(Charsets.UTF_8),
                )
            }.getOrNull() ?: return null

        // Refuse records stamped newer than this build (matches iOS forward guard).
        if (payload.schemaVersion > 1) return null

        val agent = payload.agent.ifBlank { data["agent"] as? String ?: "" }
        val runtime = runtimeForAgent(agent) ?: return null
        val recordID = payload.id.ifBlank { (data["id"] as? String)?.ifBlank { null } ?: documentID }

        // Non-private sort/routing fields prefer the sealed payload but fall back
        // to the top-level mirror (the Mac writes labelColorHex/isPinned/
        // priorityOrder/updatedAt top-level too for ordering without decrypt).
        val updatedAt =
            payload.updatedAt?.let(::epochMillisFromIso)
                ?: epochMillis(data["updatedAt"])
                ?: System.currentTimeMillis()

        return CLIAgentSessionRecord(
            id = recordID,
            agent = agent,
            agentURI = AgentIdentity.builtInURI(runtime),
            sourceKind = payload.sourceKind.ifBlank { "live_chat" },
            title = payload.title.ifBlank { "(no title)" },
            preview = payload.preview,
            modelName = payload.modelName?.ifBlank { null },
            workspaceLabel = payload.workspaceLabel?.ifBlank { null },
            updatedAtEpoch = updatedAt,
            messages = payload.messages.map(::sealedMessageToRecord),
            resumeProviderSessionID = payload.resumeHandle?.providerSessionID?.ifBlank { null },
            canResume = payload.resumeHandle?.canResume ?: false,
            canForward = payload.resumeHandle?.canForward ?: true,
            customTitle = payload.customTitle?.ifBlank { null },
            labelColorHex = (payload.labelColorHex ?: data["labelColorHex"] as? String)?.ifBlank { null },
            isPinned = payload.isPinned ?: (data["isPinned"] as? Boolean) ?: false,
            priorityOrder = payload.priorityOrder ?: (data["priorityOrder"] as? Number)?.toInt(),
        )
    }

    private fun sealedMessageToRecord(message: CLIAgentSealedMessage): CLIAgentMessage =
        CLIAgentMessage(
            id = message.id.ifBlank { java.util.UUID.randomUUID().toString() },
            role = message.role.ifBlank { "assistant" },
            text = message.text,
            timestampEpoch = message.timestamp?.let(::epochMillisFromIso),
            isError = message.isError,
            toolUses =
                message.toolUses.map { tool ->
                    CLIAgentToolUse(
                        id = tool.id.ifBlank { java.util.UUID.randomUUID().toString() },
                        name = tool.name.ifBlank { "tool" },
                        status = tool.status,
                        detail = tool.detail?.ifBlank { null },
                        startedAtEpoch = tool.startedAt?.let(::epochMillisFromIso),
                    )
                },
        )

    private fun epochMillisFromIso(raw: String): Long? =
        runCatching { java.time.Instant.parse(raw.trim()).toEpochMilli() }.getOrNull()

    private fun parseMessages(raw: Any?): List<CLIAgentMessage> = (raw as? List<*>)?.mapNotNull { entry ->
        val map = entry as? Map<*, *> ?: return@mapNotNull null
        CLIAgentMessage(
            id = map["id"] as? String ?: java.util.UUID.randomUUID().toString(),
            role = map["role"] as? String ?: "assistant",
            text = map["text"] as? String ?: "",
            timestampEpoch = epochMillis(map["timestamp"]),
            isError = map["isError"] as? Boolean ?: false,
            toolUses = parseToolUses(map["toolUses"]),
        )
    } ?: emptyList()

    private fun parseToolUses(raw: Any?): List<CLIAgentToolUse> = (raw as? List<*>)?.mapNotNull { entry ->
        val map = entry as? Map<*, *> ?: return@mapNotNull null
        CLIAgentToolUse(
            id = map["id"] as? String ?: java.util.UUID.randomUUID().toString(),
            name = map["name"] as? String ?: "tool",
            status = map["status"] as? String ?: "",
            detail = map["detail"] as? String,
            startedAtEpoch = epochMillis(map["startedAt"]),
        )
    } ?: emptyList()

    private fun runtimeForAgent(agent: String): AssistantRuntimeID? = when (agent.lowercase()) {
        "codex" -> AssistantRuntimeID.CODEX
        "claude" -> AssistantRuntimeID.CLAUDE
        "openclaw", "open_claw", "open-claw" -> AssistantRuntimeID.OPEN_CLAW
        "droid", "factory", "factory_droid", "factory-droid" -> AssistantRuntimeID.DROID
        "forge", "forge_dev", "forge-dev" -> AssistantRuntimeID.FORGE
        "antigravity", "agy", "google_antigravity", "google-antigravity" -> AssistantRuntimeID.ANTIGRAVITY
        "grok", "xai", "x-ai" -> AssistantRuntimeID.GROK
        "cursoragent", "cursor_agent", "cursor-agent" -> AssistantRuntimeID.CURSOR_AGENT
        else -> null
    }

    private fun epochMillis(raw: Any?): Long? = when (raw) {
        is Timestamp -> raw.toDate().time
        is java.util.Date -> raw.time
        is Number -> raw.toLong().let { if (it < VAL_10000000000_L) it * 1000L else it }
        is String -> runCatching { java.time.Instant.parse(raw).toEpochMilli() }.getOrNull()
        else -> null
    }

    companion object {
        @Volatile
        private var instance: ThreadInboxStore? = null

        fun shared(): ThreadInboxStore = instance ?: synchronized(this) {
            instance ?: ThreadInboxStore().also { instance = it }
        }
    }
}

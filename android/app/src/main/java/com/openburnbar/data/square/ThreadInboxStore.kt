package com.openburnbar.data.square

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.openburnbar.data.hermes.AssistantRuntimeID
import kotlinx.coroutines.tasks.await

data class CLIAgentToolUse(
    val id: String,
    val name: String,
    val status: String,
    val detail: String?,
    val startedAtEpoch: Long?
)

data class CLIAgentMessage(
    val id: String,
    val role: String,
    val text: String,
    val timestampEpoch: Long?,
    val isError: Boolean,
    val toolUses: List<CLIAgentToolUse>
)

data class CLIAgentSessionRecord(
    val id: String,
    val agent: String,
    val agentURI: String,
    val title: String,
    val preview: String,
    val modelName: String?,
    val workspaceLabel: String?,
    val updatedAtEpoch: Long,
    val messages: List<CLIAgentMessage>
) {
    val searchableText: String = listOf(
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
                }
            ).joinToString(" ")
        }
    ).joinToString(" ")
}

// MARK: - Thread Inbox Store (Android parity)
//
// Aggregator that holds the merged list of inbox items + last-refresh
// timestamp. Reads the same `cli_sessions` mirror used by iOS so Codex,
// Claude Code, and OpenClaw sessions appear in Android Hermes Square.

class ThreadInboxStore private constructor(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()
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

            val snapshot = firestore.collection("users")
                .document(uid)
                .collection("cli_sessions")
                .orderBy("updatedAt", Query.Direction.DESCENDING)
                .limit(200)
                .get()
                .await()

            val parsed = snapshot.documents.mapNotNull { document -> parseCLISession(document.data.orEmpty(), document.id) }
            cliSessionsByItemID = parsed.associateBy { "cli:${it.id}" }
            items = parsed.map { record ->
                ThreadInboxItem(
                    id = "cli:${record.id}",
                    agentURI = record.agentURI,
                    title = record.title.ifBlank { "(no title)" },
                    preview = record.preview,
                    lastActivityAtEpoch = record.updatedAtEpoch,
                    unreadCount = 0,
                    needsAttention = false,
                    source = ThreadInboxItem.Source.CLI_MIRROR,
                    liveMissionID = null,
                    searchText = record.searchableText
                )
            }.sortedForInbox()
            lastRefreshedAtEpoch = System.currentTimeMillis()
        } catch (e: Exception) {
            refreshError = e.message ?: e::class.java.simpleName
        } finally {
            isLoading = false
        }
    }

    fun cliSessionFor(item: ThreadInboxItem): CLIAgentSessionRecord? =
        cliSessionsByItemID[item.id]

    private fun parseCLISession(data: Map<String, Any>, documentID: String): CLIAgentSessionRecord? {
        val agent = data["agent"] as? String ?: return null
        val runtime = runtimeForAgent(agent) ?: return null
        val recordID = (data["id"] as? String)?.ifBlank { null } ?: documentID
        val updatedAt = epochMillis(data["updatedAt"]) ?: System.currentTimeMillis()
        return CLIAgentSessionRecord(
            id = recordID,
            agent = agent,
            agentURI = AgentIdentity.builtInURI(runtime),
            title = (data["title"] as? String)?.ifBlank { "(no title)" } ?: "(no title)",
            preview = data["preview"] as? String ?: "",
            modelName = data["modelName"] as? String,
            workspaceLabel = data["workspaceLabel"] as? String,
            updatedAtEpoch = updatedAt,
            messages = parseMessages(data["messages"])
        )
    }

    private fun parseMessages(raw: Any?): List<CLIAgentMessage> =
        (raw as? List<*>)?.mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            CLIAgentMessage(
                id = map["id"] as? String ?: java.util.UUID.randomUUID().toString(),
                role = map["role"] as? String ?: "assistant",
                text = map["text"] as? String ?: "",
                timestampEpoch = epochMillis(map["timestamp"]),
                isError = map["isError"] as? Boolean ?: false,
                toolUses = parseToolUses(map["toolUses"])
            )
        } ?: emptyList()

    private fun parseToolUses(raw: Any?): List<CLIAgentToolUse> =
        (raw as? List<*>)?.mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            CLIAgentToolUse(
                id = map["id"] as? String ?: java.util.UUID.randomUUID().toString(),
                name = map["name"] as? String ?: "tool",
                status = map["status"] as? String ?: "",
                detail = map["detail"] as? String,
                startedAtEpoch = epochMillis(map["startedAt"])
            )
        } ?: emptyList()

    private fun runtimeForAgent(agent: String): AssistantRuntimeID? =
        when (agent.lowercase()) {
            "codex" -> AssistantRuntimeID.CODEX
            "claude" -> AssistantRuntimeID.CLAUDE
            "openclaw", "open_claw", "open-claw" -> AssistantRuntimeID.OPEN_CLAW
            else -> null
        }

    private fun epochMillis(raw: Any?): Long? = when (raw) {
        is Timestamp -> raw.toDate().time
        is java.util.Date -> raw.time
        is Number -> raw.toLong().let { if (it < 10_000_000_000L) it * 1000L else it }
        is String -> runCatching { java.time.Instant.parse(raw).toEpochMilli() }.getOrNull()
        else -> null
    }

    companion object {
        @Volatile
        private var instance: ThreadInboxStore? = null

        fun shared(): ThreadInboxStore =
            instance ?: synchronized(this) {
                instance ?: ThreadInboxStore().also { instance = it }
            }
    }
}

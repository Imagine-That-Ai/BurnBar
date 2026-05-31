package com.openburnbar.data.square

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.FieldValue
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.missions.ActiveMission
import kotlinx.coroutines.tasks.await
import java.time.Instant

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
    val priorityOrder: Int? = null
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
            val snapshot = firestore.collection("users")
                .document(uid)
                .collection("cli_sessions")
                .orderBy("updatedAt", Query.Direction.DESCENDING)
                .limit(200)
                .get()
                .await()

            val parsed = snapshot.documents.mapNotNull { document -> parseCLISession(document.data.orEmpty(), document.id) }
            cliSessionsByItemID = parsed.associateBy { "cli:${it.id}" }

            val merged = mutableListOf<ThreadInboxItem>()

            // A. Add mobile assistant chat threads from historyStore
            val history = historyStore
            val mobileCLIThreadIDs = mutableSetOf<String>()
            if (history != null) {
                val historyThreads = history.threads.value.mapNotNull { thread ->
                    val agentURI: String
                    val source: ThreadInboxItem.Source
                    val runtimeLower = thread.runtime.lowercase().trim()
                    when (runtimeLower) {
                        "hermes" -> {
                            agentURI = AgentIdentity.builtInURI(AssistantRuntimeID.HERMES)
                            source = ThreadInboxItem.Source.HERMES
                        }
                        "pi" -> {
                            agentURI = AgentIdentity.builtInURI(AssistantRuntimeID.PI)
                            source = ThreadInboxItem.Source.PI
                        }
                        "codex", "claude", "openclaw", "droid", "forge", "antigravity", "grok", "cursoragent", "cursor_agent", "cursor-agent" -> {
                            val runtime = when (runtimeLower) {
                                "codex" -> AssistantRuntimeID.CODEX
                                "claude" -> AssistantRuntimeID.CLAUDE
                                "openclaw" -> AssistantRuntimeID.OPEN_CLAW
                                "droid" -> AssistantRuntimeID.DROID
                                "forge" -> AssistantRuntimeID.FORGE
                                "antigravity" -> AssistantRuntimeID.ANTIGRAVITY
                                "grok" -> AssistantRuntimeID.GROK
                                "cursoragent", "cursor_agent", "cursor-agent" -> AssistantRuntimeID.CURSOR_AGENT
                                else -> return@mapNotNull null
                            }
                            agentURI = AgentIdentity.builtInURI(runtime)
                            source = ThreadInboxItem.Source.CLI_MIRROR
                            mobileCLIThreadIDs.add(thread.id)
                        }
                        else -> return@mapNotNull null
                    }
                    ThreadInboxItem(
                        id = "${source.token}:${thread.id}",
                        agentURI = agentURI,
                        title = thread.title.ifBlank { "(untitled)" },
                        preview = thread.preview,
                        lastActivityAtEpoch = thread.updatedAtMillis,
                        unreadCount = 0,
                        needsAttention = false,
                        source = source,
                        liveMissionID = null,
                        searchText = listOf(thread.title, thread.preview, agentURI).joinToString(" "),
                        customTitle = thread.customTitle,
                        labelColorHex = thread.labelColorHex,
                        isPinned = thread.isPinned,
                        priorityOrder = thread.priorityOrder
                    )
                }
                merged.addAll(historyThreads)
            }

            // B. Add parsed CLI sessions excluding mobileCLIThreadIDs
            val cliItems = parsed.filter { it.id !in mobileCLIThreadIDs }.map { record ->
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
                    searchText = record.searchableText,
                    customTitle = record.customTitle,
                    labelColorHex = record.labelColorHex,
                    isPinned = record.isPinned,
                    priorityOrder = record.priorityOrder
                )
            }
            merged.addAll(cliItems)

            // C. Add active missions from missionHost
            val host = missionHost
            if (host != null) {
                val missionItems = host.snapshot.value.activeMissions.map { tile ->
                    val runtimeID = tile.runtimeID?.let { runtimeStr ->
                        AssistantRuntimeID.values().firstOrNull { it.token == runtimeStr }
                    }
                    val agentURI = runtimeID?.let { AgentIdentity.builtInURI(it) } ?: "agent://burnbar/auto"
                    ThreadInboxItem(
                        id = "mission:${tile.id}",
                        agentURI = agentURI,
                        title = tile.title,
                        preview = tile.phaseDetail ?: tile.phase.displayLabel,
                        lastActivityAtEpoch = tile.startedAt?.toEpochMilli() ?: System.currentTimeMillis(),
                        unreadCount = if (tile.approvalPending) 1 else 0,
                        needsAttention = tile.approvalPending || tile.phase == ActiveMission.Phase.FAILED || tile.phase == ActiveMission.Phase.BLOCKED,
                        source = ThreadInboxItem.Source.MISSION_GROUP,
                        liveMissionID = tile.id
                    )
                }
                merged.addAll(missionItems)
            }

            items = merged.sortedForInbox()
            lastRefreshedAtEpoch = System.currentTimeMillis()
        } catch (e: Exception) {
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
        priorityOrder: Int? = null
    ) {
        val uid = auth.currentUser?.uid ?: return
        val docRef = firestore.collection("users")
            .document(uid)
            .collection("cli_sessions")
            .document(id)

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

    fun cliSessionFor(item: ThreadInboxItem): CLIAgentSessionRecord? =
        cliSessionsByItemID[item.id]

    private fun parseCLISession(data: Map<String, Any>, documentID: String): CLIAgentSessionRecord? {
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
            priorityOrder = priorityOrder
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

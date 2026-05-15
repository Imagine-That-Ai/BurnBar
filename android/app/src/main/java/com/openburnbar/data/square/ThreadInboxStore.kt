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

            items = snapshot.documents.mapNotNull { document ->
                val agent = document.getString("agent") ?: return@mapNotNull null
                val runtime = runtimeForAgent(agent) ?: return@mapNotNull null
                val data = document.data.orEmpty()
                val recordID = (data["id"] as? String)?.ifBlank { null } ?: document.id
                ThreadInboxItem(
                    id = "cli:$recordID",
                    agentURI = AgentIdentity.builtInURI(runtime),
                    title = (data["title"] as? String)?.ifBlank { "(no title)" } ?: "(no title)",
                    preview = data["preview"] as? String ?: "",
                    lastActivityAtEpoch = epochMillis(data["updatedAt"]) ?: System.currentTimeMillis(),
                    unreadCount = 0,
                    needsAttention = false,
                    source = ThreadInboxItem.Source.CLI_MIRROR,
                    liveMissionID = null
                )
            }.sortedForInbox()
            lastRefreshedAtEpoch = System.currentTimeMillis()
        } catch (e: Exception) {
            refreshError = e.message ?: e::class.java.simpleName
        } finally {
            isLoading = false
        }
    }

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

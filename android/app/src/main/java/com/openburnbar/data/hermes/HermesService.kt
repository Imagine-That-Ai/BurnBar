package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.AssistantChatHermesMetadata
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.assistants.AssistantChatTokenUsage
import com.openburnbar.data.assistants.AssistantChatToolCall
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.*
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

data class HermesMessage(
    val id: String = "",
    val role: String = "assistant",
    val content: String = "",
    val modelName: String = "hermes",
    val tokensPerSecond: Double? = null,
    val toolCalls: List<ToolCall> = emptyList(),
    val isStreaming: Boolean = false,
    val timestamp: Long = System.currentTimeMillis()
)

data class ToolCall(
    val id: String = "",
    val name: String = "",
    val arguments: String = "",
    val result: String? = null
)

data class HermesConnection(
    val type: ConnectionType = ConnectionType.LOCAL,
    val host: String = "localhost",
    val port: Int = 8642,
    val relayUrl: String? = null
)

enum class ConnectionType { LOCAL, LAN, REMOTE_RELAY }

class HermesService {
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val _messages = MutableStateFlow<List<HermesMessage>>(emptyList())
    val messages: StateFlow<List<HermesMessage>> = _messages

    private val _isConnected = MutableStateFlow(false)
    val isConnected: StateFlow<Boolean> = _isConnected

    private val _availableModels = MutableStateFlow<List<String>>(emptyList())
    val availableModels: StateFlow<List<String>> = _availableModels

    private val _runtimeInfo = MutableStateFlow<Map<String, String>>(emptyMap())
    val runtimeInfo: StateFlow<Map<String, String>> = _runtimeInfo

    // ── Settings / runtime state ──
    private val _connections = MutableStateFlow<List<HermesConnectionRecord>>(listOf(HermesConnectionRecord.localDefault))
    val connections: StateFlow<List<HermesConnectionRecord>> = _connections

    private val _selectedConnection = MutableStateFlow<HermesConnectionRecord>(HermesConnectionRecord.localDefault)
    val selectedConnection: StateFlow<HermesConnectionRecord> = _selectedConnection

    private val _modelOptions = MutableStateFlow<List<HermesRuntimeModelOption>>(emptyList())
    val modelOptions: StateFlow<List<HermesRuntimeModelOption>> = _modelOptions

    private val _selectedModelID = MutableStateFlow<String?>(null)
    val selectedModelID: StateFlow<String?> = _selectedModelID

    private val _favoriteModelIDs = MutableStateFlow<Set<String>>(emptySet())
    val favoriteModelIDs: StateFlow<Set<String>> = _favoriteModelIDs

    private val _isReachable = MutableStateFlow(false)
    val isReachable: StateFlow<Boolean> = _isReachable

    private val _runtimeErrorText = MutableStateFlow<String?>(null)
    val runtimeErrorText: StateFlow<String?> = _runtimeErrorText

    private val _isLoadingRuntime = MutableStateFlow(false)
    val isLoadingRuntime: StateFlow<Boolean> = _isLoadingRuntime

    private val _profiles = MutableStateFlow<List<HermesRuntimeProfile>>(emptyList())
    val profiles: StateFlow<List<HermesRuntimeProfile>> = _profiles

    private val _jobs = MutableStateFlow<List<HermesRuntimeJob>>(emptyList())
    val jobs: StateFlow<List<HermesRuntimeJob>> = _jobs

    private var webSocket: WebSocket? = null
    private var connection = HermesConnection()
    private var chatTilePreferences = ChatTilePreferences.DEFAULT
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /**
     * Identifies the conversation currently in [_messages]. Minted on the first
     * send of a fresh thread so chat history can survive app relaunches.
     */
    private val _currentThreadID = MutableStateFlow<String?>(null)
    val currentThreadID: StateFlow<String?> = _currentThreadID

    /**
     * Persistence bridge. Wired by [bindHistoryStore]; null while running in
     * the test target without an Android Context.
     */
    private var historyStore: AssistantChatHistoryStore? = null

    /** Wire the service to the per-app persistence singleton. */
    fun bindHistoryStore(store: AssistantChatHistoryStore) {
        this.historyStore = store
    }

    fun setChatTilePreferences(preferences: ChatTilePreferences) {
        chatTilePreferences = preferences.sanitized()
    }

    fun connect(connection: HermesConnection = HermesConnection()) {
        this.connection = connection
        val url = when (connection.type) {
            ConnectionType.LOCAL -> "ws://${connection.host}:${connection.port}/ws"
            ConnectionType.LAN -> "ws://${connection.host}:${connection.port}/ws"
            ConnectionType.REMOTE_RELAY -> connection.relayUrl ?: return
        }

        val request = Request.Builder().url(url).build()
        webSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                _isConnected.value = true
                fetchRuntimeInfo()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                _isConnected.value = false
                webSocket.close(1000, null)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                _isConnected.value = false
            }
        })
    }

    fun disconnect() {
        webSocket?.close(1000, "User disconnected")
        webSocket = null
        _isConnected.value = false
    }

    fun sendMessage(content: String, modelName: String = "hermes", conversationId: String? = null) {
        val resolvedModelName = chatTilePreferences.selectedHermesModelOverride
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: modelName.trim().takeIf { it.isNotEmpty() }
            ?: "hermes"
        if (_currentThreadID.value == null) {
            _currentThreadID.value = UUID.randomUUID().toString()
        }
        val json = JSONObject().apply {
            put("type", "chat")
            put("content", content)
            put("model", resolvedModelName)
            conversationId?.let { put("conversation_id", it) }
        }
        webSocket?.send(json.toString())

        _messages.value = _messages.value + HermesMessage(
            role = "user",
            content = content,
            modelName = resolvedModelName,
            timestamp = System.currentTimeMillis()
        )
        persistCurrentThread()
    }

    fun clearMessages() {
        _messages.value = emptyList()
        _currentThreadID.value = null
    }

    /** Starts a brand-new conversation. The previous thread remains in history. */
    fun startNewThread() {
        _messages.value = emptyList()
        _currentThreadID.value = null
    }

    /** Restores messages from a persisted thread. */
    fun loadThread(id: String) {
        val store = historyStore ?: return
        val thread = store.thread(id) ?: return
        if (thread.runtime != "hermes") return
        _currentThreadID.value = thread.id
        _messages.value = thread.messages.map { stored ->
            val hermes = stored.hermes
            val usage = hermes?.usage
            HermesMessage(
                id = stored.id,
                role = stored.role,
                content = stored.text,
                modelName = stored.modelName ?: "hermes",
                tokensPerSecond = usage?.outputTokens?.let { tokens ->
                    val seconds = usage.providerGenerationDurationSeconds
                    if (seconds != null && seconds > 0) tokens.toDouble() / seconds else null
                },
                toolCalls = hermes?.toolCalls.orEmpty().map { tc ->
                    ToolCall(id = tc.id, name = tc.name)
                },
                isStreaming = false,
                timestamp = stored.timestampMillis
            )
        }
    }

    /** Removes a thread from chat history. Clears the active chat if it matches. */
    fun deleteThread(id: String) {
        historyStore?.delete(id)
        if (_currentThreadID.value == id) startNewThread()
    }

    internal fun persistCurrentThread() {
        val store = historyStore ?: return
        val threadID = _currentThreadID.value ?: return
        val msgs = _messages.value
        if (msgs.isEmpty()) return
        val now = System.currentTimeMillis()
        val existing = store.thread(threadID)
        val createdAt = existing?.createdAtMillis ?: msgs.firstOrNull()?.timestamp ?: now
        val storedMessages = msgs.mapNotNull { msg ->
            val trimmed = msg.content.trim()
            if (trimmed.isEmpty() && msg.toolCalls.isEmpty()) return@mapNotNull null
            val toolCalls = msg.toolCalls.map { AssistantChatToolCall(id = it.id, name = it.name, status = "done") }
            val usage = if (msg.tokensPerSecond != null) {
                AssistantChatTokenUsage(source = "providerUsage")
            } else null
            val hermes = if (toolCalls.isNotEmpty() || usage != null) {
                AssistantChatHermesMetadata(toolCalls = toolCalls, usage = usage)
            } else null
            AssistantChatMessage(
                id = msg.id.ifEmpty { UUID.randomUUID().toString() },
                role = msg.role,
                text = msg.content,
                timestampMillis = msg.timestamp,
                modelName = msg.modelName,
                isError = false,
                attachments = emptyList(),
                hermes = hermes
            )
        }
        if (storedMessages.isEmpty()) return

        val firstUser = msgs.firstOrNull { it.role == "user" }?.content?.trim().orEmpty()
        val lastNonEmpty = msgs.lastOrNull { it.content.trim().isNotEmpty() }?.content?.trim().orEmpty()
        val thread = AssistantChatThread(
            id = threadID,
            runtime = "hermes",
            title = if (firstUser.isNotEmpty()) firstUser.take(64) else "Hermes conversation",
            preview = lastNonEmpty.take(140),
            modelName = selectedModelID.value,
            createdAtMillis = createdAt,
            updatedAtMillis = now,
            messages = storedMessages
        )
        store.upsert(thread)
    }

    suspend fun refreshRuntime() {
        fetchRuntimeInfo()
    }

    private fun fetchRuntimeInfo() {
        scope.launch {
            try {
                val url = when (connection.type) {
                    ConnectionType.REMOTE_RELAY -> "${connection.relayUrl?.replace("ws", "http")}/info"
                    else -> "http://${connection.host}:${connection.port}/info"
                }
                val request = Request.Builder().url(url).build()
                val response = client.newCall(request).execute()
                val body = response.body?.string()
                if (body != null) {
                    val json = JSONObject(body)
                    val info = mutableMapOf<String, String>()
                    json.keys().forEach { key ->
                        info[key] = json.optString(key)
                    }
                    _runtimeInfo.value = info
                    json.optJSONArray("models")?.let { arr ->
                        _availableModels.value = (0 until arr.length()).map { arr.getString(it) }
                    }
                }
            } catch (_: Exception) { }
        }
    }

    private fun handleMessage(text: String) {
        try {
            val json = JSONObject(text)
            val type = json.optString("type", "")
            when (type) {
                "token" -> {
                    val msg = HermesMessage(
                        id = json.optString("id"),
                        role = "assistant",
                        content = json.optString("content", ""),
                        modelName = json.optString("model", "hermes"),
                        isStreaming = true,
                        timestamp = System.currentTimeMillis()
                    )
                    _messages.value = _messages.value.dropLastWhile { it.isStreaming } + msg
                }
                "done" -> {
                    val msg = HermesMessage(
                        id = json.optString("id"),
                        role = "assistant",
                        content = json.optString("content", ""),
                        modelName = json.optString("model", "hermes"),
                        tokensPerSecond = json.optDouble("tokens_per_second", 0.0).takeIf { it > 0 },
                        isStreaming = false,
                        timestamp = System.currentTimeMillis()
                    )
                    _messages.value = _messages.value.dropLastWhile { it.isStreaming } + msg
                    persistCurrentThread()
                }
                "error" -> {
                    val msg = HermesMessage(
                        id = json.optString("id"),
                        role = "assistant",
                        content = "Error: ${json.optString("message", "Unknown error")}",
                        modelName = json.optString("model", "hermes"),
                        timestamp = System.currentTimeMillis()
                    )
                    _messages.value = _messages.value + msg
                    persistCurrentThread()
                }
                "tool_call" -> {
                    val toolCall = ToolCall(
                        id = json.optString("call_id"),
                        name = json.optString("tool_name", ""),
                        arguments = json.optString("arguments", ""),
                        result = json.optString("result").takeIf { it.isNotEmpty() }
                    )
                    _messages.value = _messages.value.map { msg ->
                        if (msg.isStreaming) msg.copy(toolCalls = msg.toolCalls + toolCall) else msg
                    }
                }
            }
        } catch (_: Exception) { }
    }

    fun selectConnection(connection: HermesConnectionRecord) {
        _selectedConnection.value = connection
    }

    fun selectModel(option: HermesRuntimeModelOption) {
        _selectedModelID.value = option.modelID
    }

    fun toggleFavoriteModel(option: HermesRuntimeModelOption) {
        val current = _favoriteModelIDs.value.toMutableSet()
        if (current.contains(option.modelID)) {
            current.remove(option.modelID)
        } else {
            current.add(option.modelID)
        }
        _favoriteModelIDs.value = current
    }

    fun destroy() {
        disconnect()
        scope.cancel()
    }
}

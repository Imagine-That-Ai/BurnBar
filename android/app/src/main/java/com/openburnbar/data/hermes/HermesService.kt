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
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
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
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()
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
        scope.launch {
            probeSelectedRuntime(legacyEndpointURL(connection))
        }
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
            ?: _selectedModelID.value?.trim()?.takeIf { it.isNotEmpty() }
            ?: modelName.trim().takeIf { it.isNotEmpty() }
            ?: "hermes"
        if (_currentThreadID.value == null) {
            _currentThreadID.value = UUID.randomUUID().toString()
        }

        _messages.value = _messages.value + HermesMessage(
            role = "user",
            content = content,
            modelName = resolvedModelName,
            timestamp = System.currentTimeMillis()
        )
        persistCurrentThread()

        val endpoint = selectedEndpointURL() ?: legacyEndpointURL(connection)
        if (endpoint == null) {
            appendAssistantError("No HTTP Hermes endpoint is configured.", resolvedModelName)
            return
        }

        scope.launch {
            streamChatCompletion(endpoint, content, resolvedModelName, conversationId)
        }
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
        probeSelectedRuntime()
    }

    private suspend fun probeSelectedRuntime(endpointOverride: String? = null) {
        val selected = _selectedConnection.value
        val endpoint = endpointOverride ?: selectedEndpointURL()
        if (endpoint == null) {
            val error = "Android does not have an HTTP Hermes endpoint for ${selected.displayName}."
            _runtimeErrorText.value = error
            _isReachable.value = false
            _isConnected.value = false
            updateConnectionStatus(selected, HermesConnectionStatus.OFFLINE, error = error)
            return
        }

        _isLoadingRuntime.value = true
        _runtimeErrorText.value = null
        updateConnectionStatus(selected, HermesConnectionStatus.PENDING)
        try {
            val healthInfo = fetchHealth(endpoint)
            val models = fetchModels(endpoint)
            val modelIDs = models.map { it.modelID }.ifEmpty {
                healthInfo["model"]?.let { listOf(it) }.orEmpty()
            }
            _runtimeInfo.value = healthInfo + mapOf("endpoint" to endpoint)
            _availableModels.value = modelIDs
            _modelOptions.value = models.ifEmpty {
                modelIDs.map { id ->
                    HermesRuntimeModelOption(
                        providerID = "hermes",
                        providerName = "Hermes",
                        modelID = id,
                        displayName = id
                    )
                }
            }
            if (_selectedModelID.value == null) {
                _selectedModelID.value = modelIDs.firstOrNull()
            }
            _isReachable.value = true
            _isConnected.value = true
            updateConnectionStatus(
                selected,
                HermesConnectionStatus.ONLINE,
                advertisedModel = modelIDs.firstOrNull(),
                capabilities = listOf("health", "models", "chat_completions")
            )
        } catch (e: Exception) {
            val error = e.message ?: e.javaClass.simpleName
            _runtimeErrorText.value = error
            _isReachable.value = false
            _isConnected.value = false
            updateConnectionStatus(selected, HermesConnectionStatus.OFFLINE, error = error)
        } finally {
            _isLoadingRuntime.value = false
        }
    }

    private fun fetchHealth(endpoint: String): Map<String, String> {
        val request = Request.Builder().url("$endpoint/health").get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return emptyMap()
            val body = response.body?.string()?.takeIf { it.isNotBlank() } ?: return emptyMap()
            val json = JSONObject(body)
            val info = mutableMapOf<String, String>()
            json.keys().forEach { key ->
                val value = json.opt(key)
                if (value != null) info[key] = value.toString()
            }
            return info
        }
    }

    private fun fetchModels(endpoint: String): List<HermesRuntimeModelOption> {
        val request = Request.Builder().url("$endpoint/v1/models").get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("Hermes models probe failed: HTTP ${response.code}")
            }
            val body = response.body?.string()?.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException("Hermes models probe returned an empty body.")
            val json = JSONObject(body)
            val data = json.optJSONArray("data") ?: JSONArray()
            return (0 until data.length()).mapNotNull { index ->
                val item = data.optJSONObject(index) ?: return@mapNotNull null
                val id = item.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null
                val owner = item.optString("owned_by", "hermes").takeIf { it.isNotBlank() } ?: "hermes"
                HermesRuntimeModelOption(
                    providerID = owner,
                    providerName = owner.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() },
                    modelID = id,
                    displayName = id
                )
            }
        }
    }

    private fun streamChatCompletion(
        endpoint: String,
        content: String,
        modelName: String,
        conversationId: String?
    ) {
        val assistantID = UUID.randomUUID().toString()
        var accumulated = ""
        val body = JSONObject().apply {
            put("model", modelName)
            put("stream", true)
            put("messages", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "user")
                    put("content", content)
                })
            })
            conversationId?.let { put("conversation_id", it) }
        }.toString().toRequestBody(jsonMediaType)

        val request = Request.Builder()
            .url("$endpoint/v1/chat/completions")
            .post(body)
            .build()

        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    throw IllegalStateException("Hermes chat failed: HTTP ${response.code}")
                }
                val source = response.body?.source()
                    ?: throw IllegalStateException("Hermes chat returned an empty body.")
                while (!source.exhausted()) {
                    val line = source.readUtf8Line() ?: break
                    val payload = line.removePrefix("data:").trim()
                    if (!line.startsWith("data:") || payload.isEmpty()) continue
                    if (payload == "[DONE]") break
                    val delta = parseCompletionText(JSONObject(payload))
                    if (delta.isNotEmpty()) {
                        accumulated += delta
                        upsertStreamingAssistant(assistantID, accumulated, modelName, isStreaming = true)
                    }
                }
            }
            if (accumulated.isBlank()) {
                accumulated = "Hermes finished without returning text."
            }
            upsertStreamingAssistant(assistantID, accumulated, modelName, isStreaming = false)
            persistCurrentThread()
            _isConnected.value = true
            _isReachable.value = true
            _runtimeErrorText.value = null
        } catch (e: Exception) {
            val error = e.message ?: e.javaClass.simpleName
            appendAssistantError(error, modelName)
            _runtimeErrorText.value = error
            _isConnected.value = false
            _isReachable.value = false
        }
    }

    private fun parseCompletionText(json: JSONObject): String {
        val choices = json.optJSONArray("choices")
        if (choices != null && choices.length() > 0) {
            val choice = choices.optJSONObject(0)
            val parsedDelta = parseContentValue(choice?.optJSONObject("delta")?.opt("content"))
            if (parsedDelta.isNotEmpty()) return parsedDelta

            val messageContent = parseContentValue(choice?.optJSONObject("message")?.opt("content"))
            if (messageContent.isNotEmpty()) return messageContent

            val text = choice?.optString("text").orEmpty()
            if (text.isNotEmpty()) return text
        }

        return parseContentValue(json.opt("content")).ifEmpty {
            json.optString("output_text").takeIf { it.isNotEmpty() }
                ?: json.optString("text").takeIf { it.isNotEmpty() }
                ?: ""
        }
    }

    private fun parseContentValue(value: Any?): String {
        return when (value) {
            is String -> value
            is JSONArray -> (0 until value.length()).joinToString("") { index ->
                val item = value.opt(index)
                when (item) {
                    is String -> item
                    is JSONObject -> item.optString("text")
                        .takeIf { it.isNotEmpty() }
                        ?: item.optString("content")
                    else -> ""
                }
            }
            is JSONObject -> value.optString("text")
                .takeIf { it.isNotEmpty() }
                ?: value.optString("content")
            else -> ""
        }
    }

    private fun upsertStreamingAssistant(id: String, content: String, modelName: String, isStreaming: Boolean) {
        val message = HermesMessage(
            id = id,
            role = "assistant",
            content = content,
            modelName = modelName,
            isStreaming = isStreaming,
            timestamp = System.currentTimeMillis()
        )
        _messages.value = _messages.value.filterNot { it.id == id || it.isStreaming } + message
    }

    private fun appendAssistantError(error: String, modelName: String) {
        _messages.value = _messages.value + HermesMessage(
            id = UUID.randomUUID().toString(),
            role = "assistant",
            content = "Error: $error",
            modelName = modelName,
            timestamp = System.currentTimeMillis()
        )
        persistCurrentThread()
    }

    private fun selectedEndpointURL(): String? {
        val selected = _selectedConnection.value
        return when (selected.mode) {
            HermesConnectionMode.LOCAL, HermesConnectionMode.DIRECT_URL -> selected.endpointURL
            HermesConnectionMode.RELAY_LINK -> selected.endpointURL
        }?.let(::normalizeHTTPBaseURL)
    }

    private fun legacyEndpointURL(connection: HermesConnection): String? {
        return when (connection.type) {
            ConnectionType.LOCAL, ConnectionType.LAN -> "http://${connection.host}:${connection.port}"
            ConnectionType.REMOTE_RELAY -> connection.relayUrl
        }?.let(::normalizeHTTPBaseURL)
    }

    private fun normalizeHTTPBaseURL(raw: String): String? {
        val trimmed = raw.trim().trimEnd('/')
        if (trimmed.isBlank()) return null
        val httpURL = when {
            trimmed.startsWith("ws://") -> "http://" + trimmed.removePrefix("ws://")
            trimmed.startsWith("wss://") -> "https://" + trimmed.removePrefix("wss://")
            trimmed.startsWith("http://") || trimmed.startsWith("https://") -> trimmed
            else -> "http://$trimmed"
        }
        return httpURL
            .substringBefore("/v1/chat/completions")
            .substringBefore("/v1/models")
            .substringBefore("/health")
            .trimEnd('/')
    }

    private fun updateConnectionStatus(
        connection: HermesConnectionRecord,
        status: HermesConnectionStatus,
        advertisedModel: String? = null,
        capabilities: List<String>? = null,
        error: String? = null
    ) {
        val now = System.currentTimeMillis()
        val updated = connection.copy(
            status = status,
            advertisedModel = advertisedModel ?: connection.advertisedModel,
            capabilities = capabilities ?: connection.capabilities,
            updatedAt = now,
            lastSeenAt = if (status == HermesConnectionStatus.ONLINE) now else connection.lastSeenAt
        )
        _connections.value = _connections.value.map { if (it.id == updated.id) updated else it }
        if (_selectedConnection.value.id == updated.id) {
            _selectedConnection.value = updated
        }
        if (error != null) {
            _runtimeInfo.value = _runtimeInfo.value + ("last_error" to error)
        }
    }

    fun selectConnection(connection: HermesConnectionRecord) {
        _selectedConnection.value = connection
        scope.launch {
            probeSelectedRuntime()
        }
    }

    fun addDirectConnection(name: String, url: String): HermesConnectionRecord? {
        val endpoint = normalizeHTTPBaseURL(url) ?: return null
        val connection = HermesConnectionRecord(
            id = "android-${UUID.randomUUID()}",
            displayName = name.trim(),
            mode = HermesConnectionMode.DIRECT_URL,
            endpointURL = endpoint,
            status = HermesConnectionStatus.PENDING
        )
        _connections.value = _connections.value + connection
        selectConnection(connection)
        return connection
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

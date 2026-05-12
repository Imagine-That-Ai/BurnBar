package com.openburnbar.data.hermes

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.*
import org.json.JSONObject
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
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

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
        val json = JSONObject().apply {
            put("type", "chat")
            put("content", content)
            put("model", modelName)
            conversationId?.let { put("conversation_id", it) }
        }
        webSocket?.send(json.toString())

        // Add user message immediately
        _messages.value = _messages.value + HermesMessage(
            role = "user",
            content = content,
            modelName = modelName,
            timestamp = System.currentTimeMillis()
        )
    }

    fun clearMessages() {
        _messages.value = emptyList()
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

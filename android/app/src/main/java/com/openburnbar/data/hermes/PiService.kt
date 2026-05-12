package com.openburnbar.data.hermes

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

// Plan 2 — Android Pi assistant runtime. Mirrors `HermesService` so the
// shared `AssistantsScreen` composable can drive either runtime through a
// single `AssistantRuntimeID` selection.

data class PiChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String = "assistant",
    val content: String = "",
    val modelName: String? = null,
    val isStreaming: Boolean = false,
    val isError: Boolean = false,
    val timestamp: Long = System.currentTimeMillis()
)

class PiService {

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var streamJob: Job? = null

    // MARK: - Observable state

    private val _messages = MutableStateFlow<List<PiChatMessage>>(emptyList())
    val messages: StateFlow<List<PiChatMessage>> = _messages

    private val _connections = MutableStateFlow<List<PiConnectionRecord>>(
        listOf(PiConnectionRecord.localDefault)
    )
    val connections: StateFlow<List<PiConnectionRecord>> = _connections

    private val _selectedConnection = MutableStateFlow(PiConnectionRecord.localDefault)
    val selectedConnection: StateFlow<PiConnectionRecord> = _selectedConnection

    private val _modelOptions = MutableStateFlow<List<HermesRuntimeModelOption>>(emptyList())
    val modelOptions: StateFlow<List<HermesRuntimeModelOption>> = _modelOptions

    private val _selectedModelID = MutableStateFlow<String?>(null)
    val selectedModelID: StateFlow<String?> = _selectedModelID

    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming

    private val _isReachable = MutableStateFlow(false)
    val isReachable: StateFlow<Boolean> = _isReachable

    private val _runtimeErrorText = MutableStateFlow<String?>(null)
    val runtimeErrorText: StateFlow<String?> = _runtimeErrorText

    // MARK: - Selection

    fun selectConnection(connection: PiConnectionRecord): Boolean {
        if (_connections.value.none { it.id == connection.id }) return false
        _selectedConnection.value = connection
        scope.launch { refreshRuntime() }
        return true
    }

    fun addDirectConnection(name: String, urlString: String): PiConnectionRecord? {
        val trimmedName = name.trim()
        val trimmedURL = urlString.trim()
        if (trimmedName.isEmpty() || trimmedURL.isEmpty()) return null
        val record = PiConnectionRecord(
            id = "direct-${UUID.randomUUID()}",
            displayName = trimmedName,
            mode = PiConnectionMode.DIRECT_URL.token,
            status = PiConnectionStatus.PENDING.token,
            endpointURL = trimmedURL,
            capabilities = listOf("chat_completions"),
        )
        _connections.value = _connections.value + record
        selectConnection(record)
        return record
    }

    fun selectModel(option: HermesRuntimeModelOption) {
        _selectedModelID.value = option.modelID
    }

    fun clear() {
        _messages.value = emptyList()
    }

    // MARK: - Probes

    suspend fun refreshRuntime() {
        runtimeError(null)
        probeReachability()
        if (_isReachable.value) loadModels()
    }

    private suspend fun probeReachability() {
        val base = resolvedBaseURL() ?: return
        val request = Request.Builder()
            .url("$base/v1/models")
            .get()
            .build()
        runCatching {
            client.newCall(request).execute().use { response: Response ->
                _isReachable.value = response.isSuccessful
                if (!response.isSuccessful) {
                    runtimeError("Pi gateway returned HTTP ${response.code}.")
                }
            }
        }.onFailure {
            _isReachable.value = false
            runtimeError("Pi gateway not reachable: ${it.message ?: "unknown error"}")
        }
    }

    private suspend fun loadModels() {
        val base = resolvedBaseURL() ?: return
        val request = Request.Builder()
            .url("$base/v1/models")
            .get()
            .build()
        runCatching {
            client.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                val json = JSONObject(body)
                val data = json.optJSONArray("data") ?: JSONArray()
                val options = mutableListOf<HermesRuntimeModelOption>()
                for (i in 0 until data.length()) {
                    val entry = data.getJSONObject(i)
                    val id = entry.optString("id")
                    if (id.isNullOrEmpty()) continue
                    val provider = entry.optString("owned_by", "pi")
                    options += HermesRuntimeModelOption(
                        providerID = provider,
                        providerName = provider.replaceFirstChar { it.titlecase() },
                        modelID = id,
                        displayName = id
                    )
                }
                _modelOptions.value = options
                if (_selectedModelID.value == null) {
                    _selectedModelID.value = options.firstOrNull()?.modelID
                }
            }
        }.onFailure { runtimeError("Failed to list Pi models: ${it.message ?: ""}") }
    }

    // MARK: - Chat

    fun send(prompt: String) {
        val trimmed = prompt.trim()
        if (trimmed.isEmpty()) return

        val userMessage = PiChatMessage(role = "user", content = trimmed)
        val assistantPlaceholder = PiChatMessage(
            role = "assistant",
            content = "",
            modelName = _selectedModelID.value,
            isStreaming = true
        )
        _messages.value = _messages.value + userMessage + assistantPlaceholder
        _isStreaming.value = true

        val assistantId = assistantPlaceholder.id
        streamJob?.cancel()
        streamJob = scope.launch {
            try {
                streamChat(prompt = trimmed, assistantId = assistantId)
            } catch (e: Exception) {
                applyError(assistantId, e.message ?: "Pi stream failed.")
            } finally {
                _isStreaming.value = false
                appendToAssistant(assistantId, "") { msg -> msg.copy(isStreaming = false) }
            }
        }
    }

    fun cancel() {
        streamJob?.cancel()
        streamJob = null
        _isStreaming.value = false
    }

    private suspend fun streamChat(prompt: String, assistantId: String) {
        val base = resolvedBaseURL() ?: throw IllegalStateException("Pi base URL missing.")
        val payload = JSONObject().apply {
            put("model", _selectedModelID.value ?: "pi")
            put("stream", true)
            val messages = JSONArray()
            _messages.value.forEach { msg ->
                if (msg.id == assistantId) return@forEach
                if (msg.isError) return@forEach
                val obj = JSONObject().apply {
                    put("role", msg.role)
                    put("content", msg.content)
                }
                messages.put(obj)
            }
            messages.put(JSONObject().apply {
                put("role", "user")
                put("content", prompt)
            })
            put("messages", messages)
        }
        val body = payload.toString().toRequestBody("application/json".toMediaType())
        val request = Request.Builder()
            .url("$base/v1/chat/completions")
            .post(body)
            .addHeader("Accept", "text/event-stream")
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                applyError(assistantId, "Pi gateway HTTP ${response.code}.")
                return
            }
            val source = response.body?.source() ?: return
            while (!source.exhausted()) {
                val raw = source.readUtf8Line() ?: continue
                if (raw.isBlank()) continue
                if (!raw.startsWith("data:")) continue
                val payloadText = raw.removePrefix("data:").trim()
                if (payloadText == "[DONE]") return
                runCatching {
                    val json = JSONObject(payloadText)
                    val choices = json.optJSONArray("choices") ?: return@runCatching
                    if (choices.length() == 0) return@runCatching
                    val delta = choices.getJSONObject(0).optJSONObject("delta") ?: return@runCatching
                    val content = delta.optString("content")
                    if (content.isNotEmpty()) {
                        appendToAssistant(assistantId, content)
                    }
                }
            }
        }
    }

    private fun appendToAssistant(
        assistantId: String,
        delta: String,
        transform: ((PiChatMessage) -> PiChatMessage)? = null
    ) {
        _messages.value = _messages.value.map { existing ->
            if (existing.id == assistantId) {
                val withDelta = if (delta.isEmpty()) existing else existing.copy(content = existing.content + delta)
                transform?.invoke(withDelta) ?: withDelta
            } else existing
        }
    }

    private fun applyError(assistantId: String, text: String) {
        _messages.value = _messages.value.map { existing ->
            if (existing.id == assistantId) {
                existing.copy(content = "Pi error: $text", isError = true, isStreaming = false)
            } else existing
        }
        runtimeError(text)
    }

    private fun runtimeError(value: String?) {
        _runtimeErrorText.value = value
    }

    private fun resolvedBaseURL(): String? {
        val configured = _selectedConnection.value.endpointURL?.trim().orEmpty()
        if (configured.isEmpty()) return "http://127.0.0.1:8765"
        return configured.removeSuffix("/")
    }
}

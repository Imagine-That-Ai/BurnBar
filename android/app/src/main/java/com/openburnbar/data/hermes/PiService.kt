package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
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

/// One tool the Pi-served model decided to invoke during this turn. Mirrors
/// the iOS `PiToolCall` shape so the SwiftUI and Compose pills stay in sync.
data class PiToolCall(
    val id: String,
    val name: String,
    val status: String,
    val arguments: String,
    val detail: String?
)

data class PiChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String = "assistant",
    val content: String = "",
    val modelName: String? = null,
    val isStreaming: Boolean = false,
    val isError: Boolean = false,
    val timestamp: Long = System.currentTimeMillis(),
    val toolCalls: List<PiToolCall> = emptyList()
)

class PiService {

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var streamJob: Job? = null

    private val _currentThreadID = MutableStateFlow<String?>(null)
    val currentThreadID: StateFlow<String?> = _currentThreadID

    private var historyStore: AssistantChatHistoryStore? = null
    fun bindHistoryStore(store: AssistantChatHistoryStore) {
        this.historyStore = store
    }

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
        if (thread.runtime != "pi") return
        _currentThreadID.value = thread.id
        _messages.value = thread.messages.map { stored ->
            PiChatMessage(
                id = stored.id,
                role = stored.role,
                content = stored.text,
                modelName = stored.modelName,
                isStreaming = false,
                isError = stored.isError,
                timestamp = stored.timestampMillis,
                toolCalls = emptyList()
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

        val storedMessages = msgs.map { msg ->
            AssistantChatMessage(
                id = msg.id,
                role = msg.role,
                text = msg.content,
                timestampMillis = msg.timestamp,
                modelName = msg.modelName,
                isError = msg.isError
            )
        }
        val firstUser = msgs.firstOrNull { it.role == "user" }?.content?.trim().orEmpty()
        val lastNonEmpty = msgs.lastOrNull { it.content.trim().isNotEmpty() }?.content?.trim().orEmpty()
        val thread = AssistantChatThread(
            id = threadID,
            runtime = "pi",
            title = if (firstUser.isNotEmpty()) firstUser.take(64) else "New Pi chat",
            preview = lastNonEmpty.take(140),
            modelName = _selectedModelID.value,
            createdAtMillis = createdAt,
            updatedAtMillis = now,
            messages = storedMessages
        )
        store.upsert(thread)
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

        if (_currentThreadID.value == null) {
            _currentThreadID.value = UUID.randomUUID().toString()
        }

        val userMessage = PiChatMessage(role = "user", content = trimmed)
        val assistantPlaceholder = PiChatMessage(
            role = "assistant",
            content = "",
            modelName = _selectedModelID.value,
            isStreaming = true
        )
        _messages.value = _messages.value + userMessage + assistantPlaceholder
        _isStreaming.value = true
        persistCurrentThread()

        val assistantId = assistantPlaceholder.id
        streamJob?.cancel()
        streamJob = scope.launch {
            try {
                streamChat(prompt = trimmed, assistantId = assistantId)
            } catch (e: Exception) {
                applyError(assistantId, e.message ?: "Pi stream failed.")
            } finally {
                _isStreaming.value = false
                appendToAssistant(assistantId, "") { msg ->
                    msg.copy(
                        isStreaming = false,
                        toolCalls = msg.toolCalls.map { tc ->
                            tc.copy(
                                status = "done",
                                detail = tc.detail ?: summarizeToolArguments(tc.arguments)
                            )
                        }
                    )
                }
                persistCurrentThread()
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
                    val first = choices.getJSONObject(0)
                    val delta = first.optJSONObject("delta")
                    val finalMessage = first.optJSONObject("message")

                    val content = extractContent(delta) ?: extractContent(finalMessage)
                    if (!content.isNullOrEmpty()) {
                        appendToAssistant(assistantId, content)
                    }
                    val toolCallsArr = extractToolCalls(delta) ?: extractToolCalls(finalMessage)
                    if (toolCallsArr != null && toolCallsArr.length() > 0) {
                        mergeToolCallsForAssistant(assistantId, toolCallsArr)
                    }
                }
            }
        }
    }

    private fun extractContent(item: JSONObject?): String? {
        if (item == null) return null
        val direct = item.optString("content")
        if (!direct.isNullOrEmpty()) return direct
        val arr = item.optJSONArray("content") ?: return null
        val buf = StringBuilder()
        for (i in 0 until arr.length()) {
            when (val piece = arr.get(i)) {
                is String -> buf.append(piece)
                is JSONObject -> {
                    piece.optString("text").takeIf { it.isNotEmpty() }?.let { buf.append(it) }
                        ?: piece.optString("value").takeIf { it.isNotEmpty() }?.let { buf.append(it) }
                }
            }
        }
        return buf.toString().ifEmpty { null }
    }

    private fun extractToolCalls(item: JSONObject?): JSONArray? {
        if (item == null) return null
        item.optJSONArray("tool_calls")?.takeIf { it.length() > 0 }?.let { return it }
        item.optJSONArray("toolCalls")?.takeIf { it.length() > 0 }?.let { return it }
        item.optJSONObject("function_call")?.let { return JSONArray().put(it) }
        item.optJSONObject("functionCall")?.let { return JSONArray().put(it) }
        return null
    }

    /// Folds an OpenAI-compatible `tool_calls` delta array into the live
    /// assistant message identified by [assistantId]. Mirrors the iOS Pi
    /// implementation: the streaming protocol splits a single tool call across
    /// many chunks (name first, then partial `arguments` strings), so we
    /// accumulate by index or id and recompute the human-readable preview as
    /// more fragments arrive.
    private fun mergeToolCallsForAssistant(assistantId: String, calls: JSONArray) {
        _messages.value = _messages.value.map { existing ->
            if (existing.id != assistantId) return@map existing
            val current = existing.toolCalls.toMutableList()
            for (i in 0 until calls.length()) {
                val raw = calls.optJSONObject(i) ?: continue
                val function = raw.optJSONObject("function")
                val nameFragment = (function?.optString("name") ?: raw.optString("name"))?.ifEmpty { null }
                val argsFragment = (function?.optString("arguments") ?: raw.optString("arguments"))?.ifEmpty { null }
                val indexHint = if (raw.has("index")) raw.optInt("index", -1).takeIf { it >= 0 } else null
                val idFromPayload = raw.optString("id").ifEmpty { null }

                val resolvedID: String = when {
                    indexHint != null && indexHint < current.size -> current[indexHint].id
                    idFromPayload != null -> idFromPayload
                    indexHint != null -> "pi-tool-index-$indexHint"
                    else -> "pi-tool-${current.size + 1}"
                }
                val existingIdx = current.indexOfFirst { it.id == resolvedID }
                if (existingIdx >= 0) {
                    val tc = current[existingIdx]
                    val newName = if (!nameFragment.isNullOrEmpty()) nameFragment else tc.name
                    val newArgs = tc.arguments + (argsFragment ?: "")
                    current[existingIdx] = tc.copy(
                        name = newName,
                        arguments = newArgs,
                        status = "running",
                        detail = summarizeToolArguments(newArgs) ?: tc.detail
                    )
                } else {
                    val newName = if (!nameFragment.isNullOrEmpty()) nameFragment else "Pi tool"
                    val newArgs = argsFragment ?: ""
                    current += PiToolCall(
                        id = resolvedID,
                        name = newName,
                        status = "running",
                        arguments = newArgs,
                        detail = summarizeToolArguments(newArgs)
                    )
                }
            }
            existing.copy(toolCalls = current)
        }
    }

    /// Short human-readable preview pulled out of a (possibly partial) JSON
    /// arguments string. Mirrors `PiService.summarizeToolArguments` on iOS so
    /// the SwiftUI and Compose pills stay in sync.
    internal fun summarizeToolArguments(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        runCatching {
            val obj = JSONObject(trimmed)
            for (key in listOf("path", "file_path", "command", "pattern", "query", "url", "prompt")) {
                val value = obj.optString(key)
                if (!value.isNullOrEmpty()) return value.take(200)
            }
            val keys = obj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val value = obj.optString(k)
                if (!value.isNullOrEmpty()) return value.take(200)
            }
        }
        // Mid-stream: arguments may still be a partial JSON fragment.
        for (key in listOf("path", "file_path", "command", "pattern", "query", "url", "prompt")) {
            val pattern = "\"$key\"\\s*:\\s*\"([^\"]+)\"".toRegex()
            val match = pattern.find(trimmed)
            if (match != null && match.groupValues.size >= 2) {
                val value = match.groupValues[1]
                if (value.isNotEmpty()) return value.take(200)
            }
        }
        return null
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

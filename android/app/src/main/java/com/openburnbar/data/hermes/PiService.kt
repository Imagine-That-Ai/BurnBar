package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

private object PiServiceConstants {
    const val CHAT_TITLE_MAX_CHARS = 64
    const val CHAT_PREVIEW_MAX_CHARS = 140
}

// Plan 2 — Android Pi assistant runtime. Mirrors `HermesService` so the
// shared `AssistantsScreen` composable can drive either runtime through a
// single `AssistantRuntimeID` selection.

// / One tool the Pi-served model decided to invoke during this turn. Mirrors
// / the iOS `PiToolCall` shape so the SwiftUI and Compose pills stay in sync.
data class PiToolCall(
    val id: String,
    val name: String,
    val status: String,
    val arguments: String,
    val detail: String?,
)

data class PiChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: String = "assistant",
    val content: String = "",
    val modelName: String? = null,
    val isStreaming: Boolean = false,
    val isError: Boolean = false,
    val timestamp: Long = System.currentTimeMillis(),
    val toolCalls: List<PiToolCall> = emptyList(),
)

class PiService {
    private val client: OkHttpClient =
        OkHttpClient.Builder()
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

    private val _connections =
        MutableStateFlow<List<PiConnectionRecord>>(
            listOf(PiConnectionRecord.localDefault),
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

    private val runtimeSupport =
        PiServiceRuntimeSupport(
            client = client,
            selectedConnection = { _selectedConnection.value },
            modelOptions = _modelOptions,
            selectedModelID = _selectedModelID,
            isReachable = _isReachable,
            runtimeError = { value -> _runtimeErrorText.value = value },
        )

    private val chatStreamSupport =
        PiServiceChatStreamSupport(
            client = client,
            messages = _messages,
            selectedModelID = { _selectedModelID.value },
            runtimeSupport = runtimeSupport,
            appendToAssistant = ::appendToAssistant,
            applyError = ::applyError,
        ).also { it.currentThreadID = { _currentThreadID.value } }

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
        val record =
            PiConnectionRecord(
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
        val cleanId = id.removePrefix("pi:")
        val store = historyStore ?: return
        val thread = store.thread(cleanId) ?: return
        if (thread.runtime != "pi") return
        _currentThreadID.value = thread.id
        _messages.value =
            thread.messages.map { stored ->
                PiChatMessage(
                    id = stored.id,
                    role = stored.role,
                    content = stored.text,
                    modelName = stored.modelName,
                    isStreaming = false,
                    isError = stored.isError,
                    timestamp = stored.timestampMillis,
                    toolCalls = emptyList(),
                )
            }
    }

    /** Removes a thread from chat history. Clears the active chat if it matches. */
    fun deleteThread(id: String) {
        val cleanId = id.removePrefix("pi:")
        historyStore?.delete(cleanId)
        if (_currentThreadID.value == cleanId) startNewThread()
    }

    internal fun persistCurrentThread() {
        val store = historyStore ?: return
        val threadID = _currentThreadID.value ?: return
        val msgs = _messages.value
        if (msgs.isEmpty()) return
        val now = System.currentTimeMillis()
        val existing = store.thread(threadID)
        val createdAt = existing?.createdAtMillis ?: msgs.firstOrNull()?.timestamp ?: now

        val storedMessages =
            msgs.map { msg ->
                AssistantChatMessage(
                    id = msg.id,
                    role = msg.role,
                    text = msg.content,
                    timestampMillis = msg.timestamp,
                    modelName = msg.modelName,
                    isError = msg.isError,
                )
            }
        val firstUser = msgs.firstOrNull { it.role == "user" }?.content?.trim().orEmpty()
        val lastNonEmpty = msgs.lastOrNull { it.content.trim().isNotEmpty() }?.content?.trim().orEmpty()
        val thread =
            AssistantChatThread(
                id = threadID,
                runtime = "pi",
                title =
                if (firstUser.isNotEmpty()) {
                    firstUser.take(PiServiceConstants.CHAT_TITLE_MAX_CHARS)
                } else {
                    "New Pi chat"
                },
                preview = lastNonEmpty.take(PiServiceConstants.CHAT_PREVIEW_MAX_CHARS),
                modelName = _selectedModelID.value,
                createdAtMillis = createdAt,
                updatedAtMillis = now,
                messages = storedMessages,
            )
        store.upsert(thread)
    }

    // MARK: - Probes

    suspend fun refreshRuntime() = runtimeSupport.refreshRuntime()

    // MARK: - Chat

    fun send(prompt: String) {
        val trimmed = prompt.trim()
        if (trimmed.isEmpty()) return

        if (_currentThreadID.value == null) {
            _currentThreadID.value = UUID.randomUUID().toString()
        }

        val userMessage = PiChatMessage(role = "user", content = trimmed)
        val assistantPlaceholder =
            PiChatMessage(
                role = "assistant",
                content = "",
                modelName = _selectedModelID.value,
                isStreaming = true,
            )
        _messages.value = _messages.value + userMessage + assistantPlaceholder
        _isStreaming.value = true
        persistCurrentThread()

        val assistantId = assistantPlaceholder.id
        streamJob?.cancel()
        streamJob =
            scope.launch {
                try {
                    if (shouldUseDesktopAgentRelay()) {
                        chatStreamSupport.streamDesktopAgentChat(prompt = trimmed, assistantId = assistantId)
                    } else {
                        chatStreamSupport.streamChat(prompt = trimmed, assistantId = assistantId)
                    }
                } catch (e: IOException) {
                    applyError(assistantId, e.message ?: "Pi stream failed.")
                } finally {
                    _isStreaming.value = false
                    appendToAssistant(assistantId, "") { msg ->
                        msg.copy(
                            isStreaming = false,
                            toolCalls =
                            msg.toolCalls.map { tc ->
                                tc.copy(
                                    status = "done",
                                    detail = tc.detail ?: PiServiceToolArgumentSummarizer.summarize(tc.arguments),
                                )
                            },
                        )
                    }
                    persistCurrentThread()
                }
            }
    }

    fun ensureDesktopGrantThreadID(): String {
        if (_currentThreadID.value == null) {
            _currentThreadID.value = UUID.randomUUID().toString()
        }
        return _currentThreadID.value ?: UUID.randomUUID().toString()
    }

    private fun shouldUseDesktopAgentRelay(): Boolean {
        val threadID = _currentThreadID.value ?: return false
        return AgentCapabilityGrantState.optimisticGrant(AssistantRuntimeID.PI.token, threadID) != null
    }

    fun cancel() {
        streamJob?.cancel()
        streamJob = null
        _isStreaming.value = false
    }

    internal fun summarizeToolArguments(raw: String): String? = PiServiceToolArgumentSummarizer.summarize(raw)

    private fun appendToAssistant(assistantId: String, delta: String, transform: ((PiChatMessage) -> PiChatMessage)? = null) {
        _messages.value =
            _messages.value.map { existing ->
                if (existing.id == assistantId) {
                    val withDelta = if (delta.isEmpty()) existing else existing.copy(content = existing.content + delta)
                    transform?.invoke(withDelta) ?: withDelta
                } else {
                    existing
                }
            }
    }

    private fun applyError(assistantId: String, text: String) {
        _messages.value =
            _messages.value.map { existing ->
                if (existing.id == assistantId) {
                    existing.copy(content = "Pi error: $text", isError = true, isStreaming = false)
                } else {
                    existing
                }
            }
        _runtimeErrorText.value = text
    }
}

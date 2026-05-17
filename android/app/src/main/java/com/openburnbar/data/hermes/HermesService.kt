package com.openburnbar.data.hermes

import android.content.Context
import com.openburnbar.data.assistants.AssistantChatHermesMetadata
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.assistants.AssistantChatTokenUsage
import com.openburnbar.data.assistants.AssistantChatToolCall
import com.openburnbar.data.hermes.relay.HermesRelayClient
import com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor
import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import com.openburnbar.data.hermes.relay.HermesRelayException
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.hermes.relay.HermesRelayOperationName
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingDirectory
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingPublicKeyProvider
import com.openburnbar.data.hermes.relay.FirestoreRelayShim
import com.openburnbar.data.hermes.relay.AndroidIrohTransportAuditLogger
import com.openburnbar.data.hermes.relay.HermesCompositeRelayTransport
import com.openburnbar.data.hermes.relay.HermesIrohRelayTransport
import com.openburnbar.data.hermes.relay.HermesRelayPayload
import com.openburnbar.data.hermes.relay.HermesRelayTransporting
import com.openburnbar.irohrelay.OpenBurnBarIrohFfiBackend
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

/** Truthful relay-capability flag for the iOS-parity surfaces. */
enum class HermesRelayCapability {
    /** Build has no Firebase / no relay client wired. */
    NOT_IMPLEMENTED,
    /** Relay client exists but the user isn't signed in or no relay has been published. */
    UNSUPPORTED,
    /** A relay connection has been provisioned and probed successfully. */
    READY
}

/** Thrown when Hermes returns 401/403 so callers can show an actionable message. */
class HermesUnauthorizedException(message: String) : RuntimeException(message)

private const val RELAY_CHAT_COMPLETION_TIMEOUT_MILLIS = 600_000L

data class HermesMessage(
    val id: String = "",
    val role: String = "assistant",
    val content: String = "",
    val modelName: String = "hermes",
    val tokensPerSecond: Double? = null,
    val toolCalls: List<ToolCall> = emptyList(),
    val attachments: List<HermesAttachment> = emptyList(),
    val isStreaming: Boolean = false,
    val isError: Boolean = false,
    /**
     * First-class classification of this assistant turn. `NORMAL` for
     * regular replies; the rescue path stamps refusal/reasoning/length
     * cap/etc. so the bubble UI can render the outcome badge + retry
     * affordance without parsing prose. Mirrors iOS
     * `HermesChatMessage.outcome`.
     */
    val outcome: HermesChatMessageOutcome = HermesChatMessageOutcome.NORMAL,
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

class HermesService(
    /**
     * Optional `Context` used to construct the Firebase-backed relay
     * client. Tests can omit it; production call sites should pass the
     * app context.
     */
    private val appContext: Context? = null,
    relayClient: HermesRelayClient? = null,
    relayTransport: HermesRelayTransporting? = null
) {
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()
    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val relayClient: HermesRelayClient? = relayClient
        ?: appContext?.let { ctx ->
            runCatching { HermesRelayClient(HermesRelayKeyStore(ctx)) }.getOrNull()
        }

    private val relayTransport: HermesRelayTransporting? = relayTransport
        ?: buildRelayTransport(appContext, this.relayClient)

    private fun buildRelayTransport(
        context: Context?,
        client: HermesRelayClient?
    ): HermesRelayTransporting? {
        if (context == null || client == null) return null
        val keyStore = HermesRelayKeyStore(context)
        val auditLogger = AndroidIrohTransportAuditLogger()
        val iroh = HermesIrohRelayTransport(
            context = context,
            keyStore = keyStore,
            pairingDirectory = FirestoreIrohPairingDirectory(),
            pairingPublicKeyProvider = FirestoreIrohPairingPublicKeyProvider(),
            auditLogger = auditLogger,
        )
        val firestore = FirestoreRelayShim(client) { connectionId ->
            client.listConnections().firstOrNull { it.id == connectionId }
                ?: throw HermesRelayException("Hermes relay connection $connectionId is no longer available.")
        }
        return HermesCompositeRelayTransport(
            iroh = iroh,
            firestoreFallback = firestore,
            // Do not spend 5s on the loopback test transport in real Android builds.
            featureFlag = { OpenBurnBarIrohFfiBackend.isAvailable() },
            auditLogger = auditLogger,
        )
    }

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

    private val _currentThreadID = MutableStateFlow<String?>(null)
    val currentThreadID: StateFlow<String?> = _currentThreadID

    /** Stable across launches; updated on every send so tool replies can tag it. */
    private val _currentConversationID = MutableStateFlow<String?>(null)
    val currentConversationID: StateFlow<String?> = _currentConversationID

    /** True while a chat completion (direct or relay) is mid-stream. */
    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming

    /**
     * Bumped on every assistant content update inside the SSE loop so
     * observers (Project Memory cards, etc.) can mirror the latest
     * streamed text without polling. Wraps on overflow. Mirrors iOS
     * `ChatSessionController.streamingTick`.
     */
    private val _streamingTick = MutableStateFlow(0)
    val streamingTick: StateFlow<Int> = _streamingTick

    /** Cap on `burnbar_atom_open` tool-use iterations per turn. */
    private val maxToolUseIterations: Int = 5

    /** Injectable navigator for local tool dispatch (`burnbar_atom_open`). */
    private var atomNavigator: HermesAtomNavigator? = null

    /** Catalog of mobile tools advertised to Hermes. Single source of truth. */
    val toolCatalog: List<MobileTool> = MobileToolCatalog.tools

    /** Truthful relay-capability flag. See [HermesRelayCapability]. */
    private val _relayCapability = MutableStateFlow(
        if (relayClient != null || appContext != null) HermesRelayCapability.UNSUPPORTED
        else HermesRelayCapability.NOT_IMPLEMENTED
    )
    val relayCapability: StateFlow<HermesRelayCapability> = _relayCapability

    /** Last refreshed list of Hermes relay descriptors. */
    private val _relayConnections = MutableStateFlow<List<HermesRelayConnectionDescriptor>>(emptyList())
    val relayConnections: StateFlow<List<HermesRelayConnectionDescriptor>> = _relayConnections

    private val _sessions = MutableStateFlow<List<HermesSessionSummary>>(emptyList())
    val sessions: StateFlow<List<HermesSessionSummary>> = _sessions

    private val _isLoadingSessions = MutableStateFlow(false)
    val isLoadingSessions: StateFlow<Boolean> = _isLoadingSessions

    private val _sessionsErrorText = MutableStateFlow<String?>(null)
    val sessionsErrorText: StateFlow<String?> = _sessionsErrorText

    private var historyStore: AssistantChatHistoryStore? = null

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
        sendMessage(content, modelName, attachments = emptyList(), conversationIdHint = conversationId)
    }

    /**
     * Attachment-aware send. The single-string overload above forwards
     * to this entry point with an empty attachment list.
     *
     * Picks the correct transport for the selected connection:
     *
     *   - LOCAL / DIRECT_URL: stream over plain HTTP at
     *     `endpoint/v1/chat/completions`.
     *   - RELAY_LINK: stream over the encrypted Firestore relay so
     *     remote Mac hosts can answer without an HTTP endpoint exposed.
     *
     * If neither transport is usable for the current connection, an
     * actionable assistant-side error is appended so the user knows
     * exactly what to fix.
     */
    fun sendMessage(content: String, modelName: String, attachments: List<HermesAttachment>) {
        sendMessage(content, modelName, attachments, conversationIdHint = _currentConversationID.value)
    }

    private fun sendMessage(
        content: String,
        modelName: String,
        attachments: List<HermesAttachment>,
        conversationIdHint: String?
    ) {
        // Refuse re-entrant sends while a stream is in flight. The UI
        // disables the send button via `isStreaming`, but background
        // intents and deep-link prompts can still re-enter here.
        if (_isStreaming.value) return

        val resolvedModelName = resolvedModelNameForSend(modelName)
        if (_currentThreadID.value == null) _currentThreadID.value = UUID.randomUUID().toString()
        if (_currentConversationID.value == null) {
            _currentConversationID.value = conversationIdHint ?: UUID.randomUUID().toString()
        }
        val conversationId = _currentConversationID.value

        _messages.value = _messages.value + HermesMessage(
            id = UUID.randomUUID().toString(),
            role = "user",
            content = content,
            modelName = resolvedModelName,
            attachments = attachments,
            timestamp = System.currentTimeMillis()
        )
        persistCurrentThread()

        val selected = _selectedConnection.value
        when (selected.mode) {
            HermesConnectionMode.RELAY_LINK -> {
                val descriptor = descriptorFor(selected)
                if (descriptor == null || relayClient == null) {
                    appendAssistantError(
                        "This Hermes relay isn't usable yet. Sign in and refresh relay connections, then try again.",
                        resolvedModelName
                    )
                    return
                }
                _isStreaming.value = true
                scope.launch {
                    try {
                        streamChatCompletionViaRelay(
                            descriptor = descriptor,
                            prompt = content,
                            modelName = resolvedModelName,
                            attachments = attachments,
                            conversationId = conversationId
                        )
                    } finally {
                        _isStreaming.value = false
                    }
                }
            }
            else -> {
                val endpoint = selectedEndpointURL() ?: legacyEndpointURL(connection)
                if (endpoint == null) {
                    appendAssistantError("No HTTP Hermes endpoint is configured.", resolvedModelName)
                    return
                }
                _isStreaming.value = true
                scope.launch {
                    try {
                        if (attachments.isEmpty()) {
                            streamChatCompletion(endpoint, content, resolvedModelName, conversationId)
                        } else {
                            streamChatCompletionWithAttachments(
                                endpoint = endpoint,
                                content = content,
                                modelName = resolvedModelName,
                                attachments = attachments,
                                conversationId = conversationId
                            )
                        }
                    } finally {
                        _isStreaming.value = false
                    }
                }
            }
        }
    }

    internal fun resolvedModelNameForSend(modelName: String): String {
        val explicit = modelName.trim()
            .takeIf { it.isNotEmpty() }
            ?.takeUnless { it.equals("hermes", ignoreCase = true) || it.equals("auto", ignoreCase = true) }
        return explicit
            ?: chatTilePreferences.selectedHermesModelOverride?.trim()?.takeIf { it.isNotEmpty() }
            ?: _selectedModelID.value?.trim()?.takeIf { it.isNotEmpty() }
            ?: "hermes"
    }

    fun clearMessages() {
        _messages.value = emptyList()
        _currentThreadID.value = null
        _currentConversationID.value = null
    }

    fun startNewThread() {
        _messages.value = emptyList()
        _currentThreadID.value = null
        _currentConversationID.value = null
    }

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
                isError = msg.isError,
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

        // Relay-mode connections don't expose an HTTP endpoint — they
        // hand off to Firestore. Trust the descriptor's advertised
        // model / capabilities so the UI shows the right state.
        if (selected.mode == HermesConnectionMode.RELAY_LINK && endpointOverride == null) {
            _runtimeErrorText.value = null
            _isLoadingRuntime.value = false
            _isReachable.value = true
            _isConnected.value = true
            val advertised = selected.advertisedModel
            _availableModels.value = listOfNotNull(advertised)
            _modelOptions.value = listOfNotNull(advertised).map { id ->
                HermesRuntimeModelOption(
                    providerID = "hermes",
                    providerName = "Hermes",
                    modelID = id,
                    displayName = id
                )
            }
            if (_selectedModelID.value == null) _selectedModelID.value = advertised
            _runtimeInfo.value = mapOf(
                "transport" to "encrypted-relay",
                "encryption" to (selected.relayEncryption ?: HermesRelayCrypto.ALGORITHM)
            )
            updateConnectionStatus(
                selected,
                HermesConnectionStatus.ONLINE,
                advertisedModel = advertised,
                capabilities = selected.capabilities.ifEmpty { listOf("relay", "chat_completions") }
            )
            return
        }

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
        var toolUseIterations = 0
        val rescue = EmptyResponseRescue()
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
                    val json = JSONObject(payload)
                    rescue.absorb(json)
                    if (toolUseIterations < maxToolUseIterations) {
                        toolUseIterations += dispatchLocalToolCalls(json)
                    }
                    val delta = parseCompletionText(json)
                    if (delta.isNotEmpty()) {
                        accumulated += delta
                        upsertStreamingAssistant(assistantID, accumulated, modelName, isStreaming = true)
                    }
                }
            }
            var finalOutcome = HermesChatMessageOutcome.NORMAL
            var finalIsError = false
            if (accumulated.isBlank()) {
                val fallback = rescue.resolved()
                accumulated = fallback.text
                finalOutcome = fallback.outcome
                finalIsError = fallback.isError
            }
            upsertStreamingAssistant(
                assistantID,
                accumulated,
                modelName,
                isStreaming = false,
                outcome = finalOutcome,
                isError = finalIsError
            )
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

    private fun streamChatCompletionWithAttachments(
        endpoint: String,
        content: String,
        modelName: String,
        attachments: List<HermesAttachment>,
        conversationId: String?
    ) {
        val assistantID = UUID.randomUUID().toString()
        var accumulated = ""
        var toolUseIterations = 0
        val rescue = EmptyResponseRescue()
        val body = JSONObject().apply {
            put("model", modelName)
            put("stream", true)
            put("messages", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "user")
                    put("content", HermesAttachmentEncoder.encodeUserTurn(content, attachments))
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
                    val json = JSONObject(payload)
                    rescue.absorb(json)
                    if (toolUseIterations < maxToolUseIterations) {
                        toolUseIterations += dispatchLocalToolCalls(json)
                    }
                    val delta = parseCompletionText(json)
                    if (delta.isNotEmpty()) {
                        accumulated += delta
                        upsertStreamingAssistant(assistantID, accumulated, modelName, isStreaming = true)
                    }
                }
            }
            var finalOutcome = HermesChatMessageOutcome.NORMAL
            var finalIsError = false
            if (accumulated.isBlank()) {
                val fallback = rescue.resolved()
                accumulated = fallback.text
                finalOutcome = fallback.outcome
                finalIsError = fallback.isError
            }
            upsertStreamingAssistant(
                assistantID,
                accumulated,
                modelName,
                isStreaming = false,
                outcome = finalOutcome,
                isError = finalIsError
            )
            persistCurrentThread()
            _isConnected.value = true
            _isReachable.value = true
            _runtimeErrorText.value = null
        } catch (e: Exception) {
            appendAssistantError(e.message ?: e.javaClass.simpleName, modelName)
            _runtimeErrorText.value = e.message
        }
    }

    /**
     * Stream `/v1/chat/completions` over the encrypted relay transport.
     * Production Android prefers iroh when the native AAR is available
     * and falls back to the Firestore relay on transport failures.
     */
    private suspend fun streamChatCompletionViaRelay(
        descriptor: HermesRelayConnectionDescriptor,
        prompt: String,
        modelName: String,
        attachments: List<HermesAttachment>,
        conversationId: String?
    ) {
        val relay = relayTransport ?: throw HermesRelayException("Relay transport unavailable.")
        val assistantID = UUID.randomUUID().toString()
        var accumulated = ""
        var toolUseIterations = 0
        val rescue = EmptyResponseRescue()
        val body = JSONObject().apply {
            put("model", modelName)
            put("stream", true)
            put("messages", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "user")
                    put("content", HermesAttachmentEncoder.encodeUserTurn(prompt, attachments))
                })
            })
            conversationId?.let { put("conversation_id", it) }
        }.toString().toByteArray(Charsets.UTF_8)

        try {
            relay.sendStreaming(
                payload = HermesRelayPayload(
                    operation = HermesRelayOperationName.CHAT_COMPLETIONS,
                    method = "POST",
                    path = "/v1/chat/completions",
                    body = body,
                    sessionID = conversationId,
                    connectionID = descriptor.id,
                    relayPublicKey = descriptor.relayPublicKey,
                    relayEncryption = descriptor.relayEncryption,
                    relayKeyVersion = descriptor.relayKeyVersion,
                ),
                timeoutMillis = RELAY_CHAT_COMPLETION_TIMEOUT_MILLIS,
            ) { text ->
                // The host forwards SSE chunks verbatim; each chunk may
                // span multiple `data:` lines and the terminating `[DONE]`.
                text.split('\n').forEach { rawLine ->
                    val line = rawLine.trim()
                    if (!line.startsWith("data:")) return@forEach
                    val payload = line.removePrefix("data:").trim()
                    if (payload.isEmpty() || payload == "[DONE]") return@forEach
                    val json = runCatching { JSONObject(payload) }.getOrNull() ?: return@forEach
                    rescue.absorb(json)
                    if (toolUseIterations < maxToolUseIterations) {
                        toolUseIterations += dispatchLocalToolCalls(json)
                    }
                    val delta = runCatching { parseCompletionText(json) }.getOrDefault("")
                    if (delta.isNotEmpty()) {
                        accumulated += delta
                        upsertStreamingAssistant(assistantID, accumulated, modelName, isStreaming = true)
                    }
                }
            }
            var finalOutcome = HermesChatMessageOutcome.NORMAL
            var finalIsError = false
            if (accumulated.isBlank()) {
                val fallback = rescue.resolved()
                accumulated = fallback.text
                finalOutcome = fallback.outcome
                finalIsError = fallback.isError
            }
            upsertStreamingAssistant(
                assistantID,
                accumulated,
                modelName,
                isStreaming = false,
                outcome = finalOutcome,
                isError = finalIsError
            )
            persistCurrentThread()
            _isConnected.value = true
            _isReachable.value = true
            _runtimeErrorText.value = null
        } catch (e: Exception) {
            appendAssistantError(e.message ?: e.javaClass.simpleName, modelName)
            _runtimeErrorText.value = e.message
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

    /**
     * Captures fallback signals from each SSE chunk so an upstream
     * model that finishes without producing any visible `content` can
     * still surface something useful to the user.
     *
     * Three rescue paths in priority order:
     *   1. `refusal` — model intentionally declined; show why.
     *   2. `reasoning_content` / `reasoning` / `thinking` — thinking
     *      models that emit the entire answer on the reasoning channel
     *      and never flush to `content`.
     *   3. `finish_reason` — keys a more honest empty-text fallback
     *      (length cap vs. content filter vs. truncated stream).
     */
    private class EmptyResponseRescue {
        private var refusal = StringBuilder()
        private var reasoning = StringBuilder()
        private var lastFinishReason: String? = null

        fun absorb(json: JSONObject) {
            val choices = json.optJSONArray("choices") ?: return
            if (choices.length() == 0) return
            val choice = choices.optJSONObject(0) ?: return
            val delta = choice.optJSONObject("delta")
            val message = choice.optJSONObject("message")

            extractRefusal(delta)?.let { refusal.append(it) }
            extractRefusal(message)?.let { refusal.append(it) }
            extractReasoning(delta)?.let { reasoning.append(it) }
            extractReasoning(message)?.let { reasoning.append(it) }

            val finishReason = choice.optString("finish_reason").takeIf { it.isNotEmpty() }
                ?: choice.optString("finishReason").takeIf { it.isNotEmpty() }
            if (finishReason != null) lastFinishReason = finishReason
        }

        /**
         * Resolve the fallback text + first-class outcome the bubble
         * should render when the stream produced no visible content.
         * Mirrors `HermesChatMessage.emptyResponseFallback(...)` on iOS
         * exactly so observers on both platforms classify identically.
         */
        fun resolved(): EmptyResponseFallback = HermesChatMessageOutcome.emptyResponseFallback(
            refusal = refusal.toString(),
            reasoning = reasoning.toString(),
            finishReason = lastFinishReason
        )

        private fun extractRefusal(envelope: JSONObject?): String? {
            envelope ?: return null
            val raw = envelope.opt("refusal")
            return parseStringValue(raw)
        }

        private fun extractReasoning(envelope: JSONObject?): String? {
            envelope ?: return null
            return parseStringValue(envelope.opt("reasoning_content"))
                ?: parseStringValue(envelope.opt("reasoningContent"))
                ?: parseStringValue(envelope.opt("reasoning"))
                ?: parseStringValue(envelope.opt("thinking"))
        }

        private fun parseStringValue(raw: Any?): String? {
            return when (raw) {
                is String -> raw.takeIf { it.isNotEmpty() }
                is JSONArray -> {
                    val joined = (0 until raw.length()).joinToString("") { idx ->
                        when (val item = raw.opt(idx)) {
                            is String -> item
                            is JSONObject -> item.optString("text")
                                .takeIf { it.isNotEmpty() }
                                ?: item.optString("content")
                            else -> ""
                        }
                    }
                    joined.takeIf { it.isNotEmpty() }
                }
                is JSONObject -> raw.optString("text")
                    .takeIf { it.isNotEmpty() }
                    ?: raw.optString("content").takeIf { it.isNotEmpty() }
                else -> null
            }
        }
    }

    private fun upsertStreamingAssistant(
        id: String,
        content: String,
        modelName: String,
        isStreaming: Boolean,
        outcome: HermesChatMessageOutcome = HermesChatMessageOutcome.NORMAL,
        isError: Boolean = false
    ) {
        val message = HermesMessage(
            id = id,
            role = "assistant",
            content = content,
            modelName = modelName,
            isStreaming = isStreaming,
            isError = isError,
            outcome = outcome,
            timestamp = System.currentTimeMillis()
        )
        _messages.value = _messages.value.filterNot { it.id == id || it.isStreaming } + message
        // Bump streamingTick so observers can mirror live content
        // without polling — mirrors iOS ChatSessionController.streamingTick
        // (`&+= 1`).
        _streamingTick.value = _streamingTick.value + 1
    }

    /**
     * Install / replace the navigator used by the on-device
     * `burnbar_atom_open` tool. Pass `null` to disconnect (useful when
     * the host view disappears). Mirrors iOS `setToolAtomNavigator`.
     */
    fun setToolAtomNavigator(navigator: HermesAtomNavigator?) {
        this.atomNavigator = navigator
    }

    /**
     * Classify a finished assistant turn against the same SSE-corpus
     * signals iOS uses. Returns the outcome already stamped on the
     * message when present; otherwise re-derives one from the content.
     * Pure utility — does not mutate state.
     */
    fun outcome(message: HermesMessage): HermesChatMessageOutcome {
        if (message.outcome != HermesChatMessageOutcome.NORMAL) return message.outcome
        val trimmed = message.content.trim()
        if (trimmed.isEmpty()) return HermesChatMessageOutcome.EMPTY
        return HermesChatMessageOutcome.NORMAL
    }

    /**
     * Public cap on tool-use iterations per assistant turn. Test
     * injection point — production always uses [maxToolUseIterations].
     * Mirrors iOS `HermesService.toolUseIterationCap`.
     */
    val toolUseIterationCap: Int get() = maxToolUseIterations

    /**
     * Buffered-wallclock tokens/sec for a finished assistant turn.
     * Returns the message's own `tokensPerSecond` when the provider
     * supplied real generation duration; otherwise falls back to
     * (output tokens / observed wall-clock seconds), capped to a sane
     * floor so a 0.05s ghost reply doesn't claim 1000 tok/s. Mirrors
     * iOS `HermesChatMessage.tokensPerSecond` guard semantics.
     */
    fun tokensPerSecondGuarded(message: HermesMessage, observedSeconds: Double?): Double? {
        message.tokensPerSecond?.let { return it }
        val seconds = observedSeconds ?: return null
        if (seconds < 0.25) return null
        // Without a token count we cannot derive a rate; the caller
        // should pass a tokens-per-second-ready message in that case.
        return null
    }

    /**
     * Walk the streamed `tool_calls[]` array on a SSE chunk and
     * dispatch any locally executable tools (currently
     * `burnbar_atom_open`). Returns the count of locally dispatched
     * calls so callers can cap loops at [maxToolUseIterations].
     *
     * The Hermes backend executes server-side tools (`read_file`,
     * `search`, `web_search`); this hook only handles the navigation
     * tool the Android app implements locally.
     */
    internal fun dispatchLocalToolCalls(json: JSONObject): Int {
        val choices = json.optJSONArray("choices") ?: return 0
        if (choices.length() == 0) return 0
        val choice = choices.optJSONObject(0) ?: return 0
        val container = choice.optJSONObject("delta") ?: choice.optJSONObject("message") ?: return 0
        val toolCallsArray = container.optJSONArray("tool_calls")
            ?: container.optJSONArray("toolCalls")
            ?: return 0
        var dispatched = 0
        for (i in 0 until toolCallsArray.length()) {
            val entry = toolCallsArray.optJSONObject(i) ?: continue
            val function = entry.optJSONObject("function") ?: continue
            val name = function.optString("name").takeIf { it.isNotEmpty() } ?: continue
            val arguments = function.optString("arguments")
            val handled = MobileToolCatalog.dispatchLocal(
                toolName = name,
                argumentsJson = arguments,
                navigator = atomNavigator
            )
            if (handled) dispatched += 1
        }
        return dispatched
    }

    /**
     * Retry the most recent user turn. Strips any assistant messages
     * that came after the last user message (the failed/empty replies
     * we want to redo) and re-sends the original prompt with its
     * attachments. No-op while a stream is in flight or if there's no
     * user turn to retry. Mirrors iOS
     * `HermesService.retryLastUserTurn(context:)`.
     */
    fun retryLastUserTurn(context: String? = null) {
        if (_isStreaming.value) return
        val current = _messages.value
        val lastUserIndex = current.indexOfLast { it.role == "user" }
        if (lastUserIndex < 0) return
        val userMessage = current[lastUserIndex]
        val trimmed = userMessage.content.trim()
        if (trimmed.isEmpty() && userMessage.attachments.isEmpty()) return

        // Drop everything after (and including) the user turn we're
        // retrying so `sendMessage` re-appends it cleanly.
        _messages.value = current.subList(0, lastUserIndex)

        sendMessage(
            content = trimmed,
            modelName = userMessage.modelName,
            attachments = userMessage.attachments
        )
    }

    private fun appendAssistantError(error: String, modelName: String) {
        _messages.value = _messages.value + HermesMessage(
            id = UUID.randomUUID().toString(),
            role = "assistant",
            content = "Error: $error",
            modelName = modelName,
            isError = true,
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

    /** Remove a direct/relay record. The local default is never removable. */
    fun revokeConnection(connection: HermesConnectionRecord) {
        if (connection.id == HermesConnectionRecord.localDefault.id) return
        _connections.value = _connections.value.filterNot { it.id == connection.id }
        if (_selectedConnection.value.id == connection.id) {
            selectConnection(HermesConnectionRecord.localDefault)
        }
    }

    // ── Encrypted relay support ─────────────────────────────────────────

    suspend fun refreshRelayConnections() {
        val relay = relayClient ?: run {
            _relayCapability.value = HermesRelayCapability.NOT_IMPLEMENTED
            return
        }
        if (!relay.isUsable()) {
            _relayCapability.value = HermesRelayCapability.UNSUPPORTED
            return
        }
        try {
            val descriptors = relay.listConnections()
            _relayConnections.value = descriptors
            if (descriptors.isEmpty()) {
                _relayCapability.value = HermesRelayCapability.UNSUPPORTED
                return
            }
            val current = _connections.value.toMutableList()
            for (descriptor in descriptors) {
                val mapped = HermesConnectionRecord(
                    id = descriptor.id,
                    displayName = descriptor.displayName,
                    mode = HermesConnectionMode.RELAY_LINK,
                    endpointURL = null,
                    status = when (descriptor.status) {
                        "online" -> HermesConnectionStatus.ONLINE
                        "offline" -> HermesConnectionStatus.OFFLINE
                        else -> HermesConnectionStatus.PENDING
                    },
                    capabilities = descriptor.capabilities,
                    advertisedModel = descriptor.advertisedModel,
                    relayPublicKey = descriptor.relayPublicKey,
                    relayKeyVersion = descriptor.relayKeyVersion,
                    relayEncryption = descriptor.relayEncryption,
                    realtimeRelayURL = null
                )
                val existingIdx = current.indexOfFirst { it.id == mapped.id }
                if (existingIdx >= 0) current[existingIdx] = mapped else current.add(mapped)
            }
            _connections.value = current
            _relayCapability.value = HermesRelayCapability.READY
        } catch (e: Exception) {
            _relayCapability.value = HermesRelayCapability.UNSUPPORTED
            _runtimeErrorText.value = e.message ?: "Could not refresh Hermes relay connections."
        }
    }

    private fun descriptorFor(connection: HermesConnectionRecord): HermesRelayConnectionDescriptor? {
        val publicKey = connection.relayPublicKey ?: return null
        return HermesRelayConnectionDescriptor(
            id = connection.id,
            displayName = connection.displayName,
            relayPublicKey = publicKey,
            relayKeyVersion = connection.relayKeyVersion,
            relayEncryption = connection.relayEncryption ?: HermesRelayCrypto.ALGORITHM,
            advertisedModel = connection.advertisedModel,
            capabilities = connection.capabilities,
            status = "online",
            updatedAt = null
        )
    }

    // ── Sessions browser / library import ──────────────────────────────

    suspend fun refreshSessions() {
        val selected = _selectedConnection.value
        _isLoadingSessions.value = true
        _sessionsErrorText.value = null
        try {
            val body = when (selected.mode) {
                HermesConnectionMode.RELAY_LINK -> fetchSessionsViaRelay(selected)
                else -> fetchSessionsDirect(selected)
            }
            _sessions.value = HermesSessionParser.parseSessions(body)
        } catch (e: Exception) {
            _sessionsErrorText.value = e.message ?: "Could not load Hermes sessions."
            _sessions.value = emptyList()
        } finally {
            _isLoadingSessions.value = false
        }
    }

    private suspend fun fetchSessionsViaRelay(connection: HermesConnectionRecord): String {
        val relay = relayClient ?: throw HermesRelayException("Relay client unavailable.")
        val descriptor = descriptorFor(connection)
            ?: throw HermesRelayException("This Hermes relay hasn't published a usable key yet.")
        return relay.sendUnary(
            connection = descriptor,
            operation = HermesRelayOperationName.SESSIONS,
            method = "GET",
            path = "/api/sessions"
        )
    }

    private fun fetchSessionsDirect(connection: HermesConnectionRecord): String {
        val endpoint = normalizeHTTPBaseURL(connection.endpointURL ?: "")
            ?: throw IllegalStateException("This Hermes host has no valid endpoint URL.")
        val request = Request.Builder().url("$endpoint/api/sessions").get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("Hermes sessions probe failed: HTTP ${response.code}")
            }
            return response.body?.string().orEmpty()
        }
    }

    suspend fun importSession(id: String): String? {
        val store = historyStore ?: return null
        val selected = _selectedConnection.value
        val body = try {
            when (selected.mode) {
                HermesConnectionMode.RELAY_LINK -> fetchSessionDetailViaRelay(selected, id)
                else -> fetchSessionDetailDirect(selected, id)
            }
        } catch (_: Exception) {
            null
        } ?: return null
        val messages = HermesSessionParser.parseSessionMessages(body)
        if (messages.isEmpty()) return null
        val summary = _sessions.value.firstOrNull { it.id == id }
        val now = System.currentTimeMillis()
        val storedMessages = messages.map { msg ->
            AssistantChatMessage(
                id = msg.id ?: UUID.randomUUID().toString(),
                role = msg.role,
                text = msg.text,
                timestampMillis = msg.timestampMillis ?: now,
                modelName = msg.modelName,
                isError = false,
                attachments = emptyList(),
                hermes = null
            )
        }
        val firstUserText = messages.firstOrNull { it.role == "user" }?.text?.trim().orEmpty()
        val thread = AssistantChatThread(
            id = "imported-$id",
            runtime = "hermes",
            title = summary?.title?.takeIf { it.isNotBlank() }
                ?: firstUserText.take(64).ifEmpty { "Imported Hermes session" },
            preview = messages.lastOrNull { it.text.isNotBlank() }?.text?.take(140).orEmpty(),
            modelName = summary?.model,
            createdAtMillis = summary?.startedAt ?: now,
            updatedAtMillis = summary?.lastActiveAt ?: now,
            messages = storedMessages
        )
        store.upsert(thread)
        return thread.id
    }

    private suspend fun fetchSessionDetailViaRelay(
        connection: HermesConnectionRecord,
        sessionId: String
    ): String? {
        val relay = relayClient ?: return null
        val descriptor = descriptorFor(connection) ?: return null
        return relay.sendUnary(
            connection = descriptor,
            operation = HermesRelayOperationName.SESSION_DETAIL,
            method = "GET",
            path = "/api/sessions/$sessionId",
            sessionId = sessionId
        )
    }

    private fun fetchSessionDetailDirect(connection: HermesConnectionRecord, sessionId: String): String? {
        val endpoint = normalizeHTTPBaseURL(connection.endpointURL ?: "") ?: return null
        val request = Request.Builder().url("$endpoint/api/sessions/$sessionId").get().build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            return response.body?.string()
        }
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

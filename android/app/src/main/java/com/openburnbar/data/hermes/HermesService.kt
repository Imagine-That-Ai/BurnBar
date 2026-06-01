package com.openburnbar.data.hermes

import android.content.Context
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.hermes.relay.AndroidIrohTransportAuditLogger
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingDirectory
import com.openburnbar.data.hermes.relay.FirestoreIrohPairingPublicKeyProvider
import com.openburnbar.data.hermes.relay.FirestoreRelayShim
import com.openburnbar.data.hermes.relay.HermesCompositeRelayTransport
import com.openburnbar.data.hermes.relay.HermesIrohRelayTransport
import com.openburnbar.data.hermes.relay.HermesRelayClient
import com.openburnbar.data.hermes.relay.HermesRelayException
import com.openburnbar.data.hermes.relay.HermesRelayKeyStore
import com.openburnbar.data.hermes.relay.HermesRelayTransporting
import com.openburnbar.irohrelay.OpenBurnBarIrohFfiBackend
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.WebSocket
import org.json.JSONObject

private const val VAL_0_25 = 0.25

/** Truthful relay-capability flag for the iOS-parity surfaces. */
enum class HermesRelayCapability {
    /** Build has no Firebase / no relay client wired. */
    NOT_IMPLEMENTED,

    /** Relay client exists but the user isn't signed in or no relay has been published. */
    UNSUPPORTED,

    /** A relay connection has been provisioned and probed successfully. */
    READY,
}

/** Thrown when Hermes returns 401/403 so callers can show an actionable message. */
class HermesUnauthorizedException(message: String) : RuntimeException(message)

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
    val outcome: HermesChatMessageOutcome = HermesChatMessageOutcome.NORMAL,
    val timestamp: Long = System.currentTimeMillis(),
)

data class ToolCall(
    val id: String = "",
    val name: String = "",
    val arguments: String = "",
    val result: String? = null,
)

data class HermesConnection(
    val type: ConnectionType = ConnectionType.LOCAL,
    val host: String = "localhost",
    val port: Int = 8642,
    val relayUrl: String? = null,
)

enum class ConnectionType { LOCAL, LAN, REMOTE_RELAY }

class HermesService(
    private val appContext: Context? = null,
    relayClient: HermesRelayClient? = null,
    relayTransport: HermesRelayTransporting? = null,
) {
    private val client =
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()

    private val relayClient: HermesRelayClient? =
        relayClient
            ?: appContext?.let { ctx ->
                runCatching { HermesRelayClient(HermesRelayKeyStore(ctx)) }.getOrNull()
            }

    internal val relayTransportInternal: HermesRelayTransporting? =
        relayTransport
            ?: buildHermesRelayTransport(appContext, this.relayClient)

    private val _messages = MutableStateFlow<List<HermesMessage>>(emptyList())
    val messages: StateFlow<List<HermesMessage>> = _messages

    private val _isConnected = MutableStateFlow(false)
    val isConnected: StateFlow<Boolean> = _isConnected

    private val _availableModels = MutableStateFlow<List<String>>(emptyList())
    val availableModels: StateFlow<List<String>> = _availableModels

    private val _runtimeInfo = MutableStateFlow<Map<String, String>>(emptyMap())
    val runtimeInfo: StateFlow<Map<String, String>> = _runtimeInfo

    private val _connections = MutableStateFlow<List<HermesConnectionRecord>>(listOf(HermesConnectionRecord.localDefault))
    val connections: StateFlow<List<HermesConnectionRecord>> = _connections

    private val _selectedConnection = MutableStateFlow<HermesConnectionRecord>(HermesConnectionRecord.localDefault)
    val selectedConnection: StateFlow<HermesConnectionRecord> = _selectedConnection

    val suggestedRelayConnection: HermesConnectionRecord?
        get() {
            val list =
                _connections.value.filter {
                    it.mode == HermesConnectionMode.RELAY_LINK &&
                        it.status == HermesConnectionStatus.ONLINE &&
                        !it.relayPublicKey.isNullOrBlank()
                }
            return list.sortedWith(
                compareByDescending<HermesConnectionRecord> {
                    it.lastSeenAt ?: it.updatedAt
                },
            ).firstOrNull()
        }

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
    internal var legacyConnectionInternal = HermesConnection()
    private var chatTilePreferences = ChatTilePreferences.DEFAULT
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private val _currentThreadID = MutableStateFlow<String?>(null)
    val currentThreadID: StateFlow<String?> = _currentThreadID

    private val _currentConversationID = MutableStateFlow<String?>(null)
    val currentConversationID: StateFlow<String?> = _currentConversationID

    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming

    private val _streamingTick = MutableStateFlow(0)
    val streamingTick: StateFlow<Int> = _streamingTick

    val toolUseIterationCap: Int = 5

    private var atomNavigator: HermesAtomNavigator? = null

    val toolCatalog: List<MobileTool> = MobileToolCatalog.tools

    private val _relayCapability =
        MutableStateFlow(
            if (relayClient != null || appContext != null) {
                HermesRelayCapability.UNSUPPORTED
            } else {
                HermesRelayCapability.NOT_IMPLEMENTED
            },
        )
    val relayCapability: StateFlow<HermesRelayCapability> = _relayCapability

    private val _relayConnections = MutableStateFlow<List<com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor>>(emptyList())
    val relayConnections: StateFlow<List<com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor>> = _relayConnections

    private val _sessions = MutableStateFlow<List<HermesSessionSummary>>(emptyList())
    val sessions: StateFlow<List<HermesSessionSummary>> = _sessions

    private val _isLoadingSessions = MutableStateFlow(false)
    val isLoadingSessions: StateFlow<Boolean> = _isLoadingSessions

    private val _sessionsErrorText = MutableStateFlow<String?>(null)
    val sessionsErrorText: StateFlow<String?> = _sessionsErrorText

    private var historyStore: AssistantChatHistoryStore? = null

    internal val messagesInternal get() = _messages
    internal val isConnectedInternal get() = _isConnected
    internal val isReachableInternal get() = _isReachable
    internal val isStreamingInternal get() = _isStreaming
    internal val streamingTickInternal get() = _streamingTick
    internal val currentThreadIDInternal get() = _currentThreadID
    internal val currentConversationIDInternal get() = _currentConversationID
    internal val selectedModelIDInternal get() = _selectedModelID
    internal val connectionsInternal get() = _connections
    internal val selectedConnectionInternal get() = _selectedConnection
    internal val relayCapabilityInternal get() = _relayCapability
    internal val relayConnectionsInternal get() = _relayConnections
    internal val runtimeErrorTextInternal get() = _runtimeErrorText
    internal val sessionsInternal get() = _sessions
    internal val isLoadingSessionsInternal get() = _isLoadingSessions
    internal val sessionsErrorTextInternal get() = _sessionsErrorText
    internal val relayClientInternal get() = relayClient
    internal val httpClientInternal get() = client
    internal val historyStoreInternal get() = historyStore

    private val runtimeSupport =
        HermesServiceRuntimeSupport(
            client = client,
            selectedConnection = { _selectedConnection.value },
            modelState =
            HermesRuntimeModelState(
                availableModels = _availableModels,
                modelOptions = _modelOptions,
                selectedModelID = _selectedModelID,
            ),
            probeState =
            HermesRuntimeProbeState(
                runtimeInfo = _runtimeInfo,
                isReachable = _isReachable,
                isConnected = _isConnected,
                runtimeErrorText = _runtimeErrorText,
                isLoadingRuntime = _isLoadingRuntime,
                connections = _connections,
                selectedConnectionFlow = _selectedConnection,
            ),
        )

    private val toolDispatch = HermesServiceToolDispatch { atomNavigator }

    internal val connectionActions = HermesServiceConnectionActions(this)
    internal val sessionActions = HermesServiceSessionActions(this)
    internal val threadActions = HermesServiceThreadActions(this)
    internal val messageActions =
        HermesServiceMessageActions(
            service = this,
            runtimeSupport = runtimeSupport,
            toolDispatch = toolDispatch,
            threadActions = threadActions,
            scope = scope,
        )
    internal val relayActions = HermesServiceRelayActions(this)

    internal fun launchRuntimeProbe(endpointOverride: String? = null) {
        scope.launch { runtimeSupport.probeSelectedRuntime(endpointOverride) }
    }

    fun bindHistoryStore(store: AssistantChatHistoryStore) {
        historyStore = store
    }

    fun setChatTilePreferences(preferences: ChatTilePreferences) {
        chatTilePreferences = preferences.sanitized()
    }

    fun connect(connection: HermesConnection = HermesConnection()) {
        legacyConnectionInternal = connection
        scope.launch {
            connectionActions.refreshRelayConnections()
            if (_selectedConnection.value.id == HermesConnectionRecord.localDefault.id) {
                connectToSuggestedRelay(refresh = false)
            }
            launchRuntimeProbe(HermesServiceEndpointSupport.legacyEndpointURL(connection))
        }
    }

    fun disconnect() {
        webSocket?.close(1000, "User disconnected")
        webSocket = null
        _isConnected.value = false
    }

    fun ensureDesktopGrantThreadID(): String {
        if (_currentConversationID.value == null) {
            _currentConversationID.value = UUID.randomUUID().toString()
        }
        if (_currentThreadID.value == null) {
            _currentThreadID.value = _currentConversationID.value
        }
        return _currentConversationID.value ?: UUID.randomUUID().toString()
    }

    fun sendMessage(content: String, modelName: String = "hermes", conversationId: String? = null) {
        sendMessage(content, modelName, attachments = emptyList(), conversationId = conversationId)
    }

    fun sendMessage(content: String, modelName: String, attachments: List<HermesAttachment>) {
        sendMessage(content, modelName, attachments, conversationId = _currentConversationID.value)
    }

    private fun sendMessage(content: String, modelName: String, attachments: List<HermesAttachment>, conversationId: String?) {
        messageActions.sendMessage(content, modelName, attachments, conversationId)
    }

    internal fun resolvedModelNameForSend(modelName: String): String {
        val explicit =
            modelName.trim()
                .takeIf { it.isNotEmpty() }
                ?.takeUnless { it.equals("hermes", ignoreCase = true) || it.equals("auto", ignoreCase = true) }
        return explicit
            ?: chatTilePreferences.selectedHermesModelOverride?.trim()?.takeIf { it.isNotEmpty() }
            ?: _selectedModelID.value?.trim()?.takeIf { it.isNotEmpty() }
            ?: "hermes"
    }

    suspend fun refreshRuntime() = runtimeSupport.probeSelectedRuntime()

    fun setToolAtomNavigator(navigator: HermesAtomNavigator?) {
        atomNavigator = navigator
    }

    fun outcome(message: HermesMessage): HermesChatMessageOutcome {
        if (message.outcome != HermesChatMessageOutcome.NORMAL) return message.outcome
        val trimmed = message.content.trim()
        if (trimmed.isEmpty()) return HermesChatMessageOutcome.EMPTY
        return HermesChatMessageOutcome.NORMAL
    }

    fun tokensPerSecondGuarded(message: HermesMessage, observedSeconds: Double?): Double? {
        message.tokensPerSecond?.let { return it }
        val seconds = observedSeconds ?: return null
        if (seconds < VAL_0_25) return null
        return null
    }

    internal fun dispatchLocalToolCalls(json: JSONObject): Int = messageActions.dispatchLocalToolCalls(json)

    fun connectToSuggestedRelay(refresh: Boolean = true): Boolean {
        val relay = suggestedRelayConnection ?: return false
        selectConnection(relay)
        if (refresh) {
            scope.launch { refreshRuntime() }
        }
        return true
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

private fun buildHermesRelayTransport(context: Context?, client: HermesRelayClient?): HermesRelayTransporting? {
    if (context == null || client == null) return null
    val keyStore = HermesRelayKeyStore(context)
    val auditLogger = AndroidIrohTransportAuditLogger()
    val iroh =
        HermesIrohRelayTransport(
            context = context,
            keyStore = keyStore,
            pairingDirectory = FirestoreIrohPairingDirectory(),
            pairingPublicKeyProvider = FirestoreIrohPairingPublicKeyProvider(),
            auditLogger = auditLogger,
        )
    val firestore =
        FirestoreRelayShim(client) { connectionId ->
            client.listConnections().firstOrNull { it.id == connectionId }
                ?: throw HermesRelayException("Hermes relay connection $connectionId is no longer available.")
        }
    return HermesCompositeRelayTransport(
        iroh = iroh,
        firestoreFallback = firestore,
        featureFlag = { OpenBurnBarIrohFfiBackend.isAvailable() },
        auditLogger = auditLogger,
    )
}

fun HermesService.clearMessages() = threadActions.clearMessages()

fun HermesService.startNewThread() = threadActions.startNewThread()

fun HermesService.loadThread(id: String) = threadActions.loadThread(id)

fun HermesService.deleteThread(id: String) = threadActions.deleteThread(id)

fun HermesService.retryLastUserTurn(context: String? = null) = messageActions.retryLastUserTurn(context)

fun HermesService.selectConnection(connection: HermesConnectionRecord) = connectionActions.selectConnection(connection)

fun HermesService.addDirectConnection(name: String, url: String): HermesConnectionRecord? =
    connectionActions.addDirectConnection(name, url)

fun HermesService.revokeConnection(connection: HermesConnectionRecord) = connectionActions.revokeConnection(connection)

suspend fun HermesService.refreshRelayConnections() = connectionActions.refreshRelayConnections()

suspend fun HermesService.refreshSessions() = sessionActions.refreshSessions()

suspend fun HermesService.importSession(id: String): String? = sessionActions.importSession(id)

suspend fun HermesService.streamCLIAgentChatPayload(body: ByteArray, sessionID: String, onRawEvent: suspend (String) -> Unit) =
    relayActions.streamCLIAgentChatPayload(body, sessionID, onRawEvent)

suspend fun HermesService.macRelayPayloadForCLIAgentChat(body: ByteArray, sessionID: String) =
    relayActions.macRelayPayloadForCLIAgentChat(body, sessionID)

suspend fun HermesService.sendCLIAgentSessionActionPayload(body: ByteArray, sessionID: String) =
    relayActions.sendCLIAgentSessionActionPayload(body, sessionID)

suspend fun HermesService.macRelayPayloadForCLIAgentSessionAction(body: ByteArray, sessionID: String) =
    relayActions.macRelayPayloadForCLIAgentSessionAction(body, sessionID)

suspend fun HermesService.fetchCLIRuntimeModelCatalog(runtime: AssistantRuntimeID) =
    relayActions.fetchCLIRuntimeModelCatalog(runtime)

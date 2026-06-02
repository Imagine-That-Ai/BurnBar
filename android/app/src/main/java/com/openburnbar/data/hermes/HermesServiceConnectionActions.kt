package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor
import com.openburnbar.data.hermes.relay.HermesRelayCrypto
import com.openburnbar.data.hermes.relay.HermesRelayException
import com.openburnbar.data.hermes.relay.HermesRelayOperationName
import java.io.IOException
import java.util.UUID
import okhttp3.Request

private const val SESSION_TITLE_MAX = 64
private const val SESSION_PREVIEW_MAX = 140

/** Connection registry mutations for [HermesService]. */
internal class HermesServiceConnectionActions(
    private val service: HermesService,
) {
    fun selectConnection(connection: HermesConnectionRecord) {
        service.selectedConnectionInternal.value = connection
        service.launchRuntimeProbe()
    }

    fun addDirectConnection(name: String, url: String): HermesConnectionRecord? {
        val endpoint = HermesServiceEndpointSupport.normalizeHTTPBaseURL(url) ?: return null
        val connection =
            HermesConnectionRecord(
                id = "android-${UUID.randomUUID()}",
                displayName = name.trim(),
                mode = HermesConnectionMode.DIRECT_URL,
                endpointURL = endpoint,
                status = HermesConnectionStatus.PENDING,
            )
        service.connectionsInternal.value = service.connectionsInternal.value + connection
        selectConnection(connection)
        return connection
    }

    fun revokeConnection(connection: HermesConnectionRecord) {
        if (connection.id == HermesConnectionRecord.localDefault.id) return
        service.connectionsInternal.value = service.connectionsInternal.value.filterNot { it.id == connection.id }
        if (service.selectedConnectionInternal.value.id == connection.id) {
            selectConnection(HermesConnectionRecord.localDefault)
        }
    }

    suspend fun refreshRelayConnections() {
        val relay =
            service.relayClientInternal ?: run {
                service.relayCapabilityInternal.value = HermesRelayCapability.NOT_IMPLEMENTED
                return
            }
        if (!relay.isUsable()) {
            service.relayCapabilityInternal.value = HermesRelayCapability.UNSUPPORTED
            return
        }
        try {
            val descriptors = relay.listConnections()
            service.relayConnectionsInternal.value = descriptors
            if (descriptors.isEmpty()) {
                service.relayCapabilityInternal.value = HermesRelayCapability.UNSUPPORTED
                return
            }
            val current = service.connectionsInternal.value.toMutableList()
            for (descriptor in descriptors) {
                val mapped = descriptor.toConnectionRecord()
                val existingIdx = current.indexOfFirst { it.id == mapped.id }
                if (existingIdx >= 0) current[existingIdx] = mapped else current.add(mapped)
            }
            service.connectionsInternal.value = current
            service.relayCapabilityInternal.value = HermesRelayCapability.READY
        } catch (e: IOException) {
            service.relayCapabilityInternal.value = HermesRelayCapability.UNSUPPORTED
            service.runtimeErrorTextInternal.value = e.message ?: "Could not refresh Hermes relay connections."
        }
    }

    private fun HermesRelayConnectionDescriptor.toConnectionRecord(): HermesConnectionRecord = HermesConnectionRecord(
        id = id,
        displayName = displayName,
        mode = HermesConnectionMode.RELAY_LINK,
        endpointURL = null,
        status =
        when (status) {
            "online" -> HermesConnectionStatus.ONLINE
            "offline" -> HermesConnectionStatus.OFFLINE
            else -> HermesConnectionStatus.PENDING
        },
        capabilities = capabilities,
        advertisedModel = advertisedModel,
        relayPublicKey = relayPublicKey,
        relayKeyVersion = relayKeyVersion,
        relayEncryption = relayEncryption,
        realtimeRelayURL = null,
        updatedAt = updatedAt ?: System.currentTimeMillis(),
    )
}

/** Session library browser for [HermesService]. */
internal class HermesServiceSessionActions(
    private val service: HermesService,
) {
    suspend fun refreshSessions() {
        val selected = service.selectedConnectionInternal.value
        service.isLoadingSessionsInternal.value = true
        service.sessionsErrorTextInternal.value = null
        try {
            val body =
                when (selected.mode) {
                    HermesConnectionMode.RELAY_LINK -> fetchSessionsViaRelay(selected)
                    else -> fetchSessionsDirect(selected)
                }
            service.sessionsInternal.value = HermesSessionParser.parseSessions(body)
        } catch (e: IOException) {
            service.sessionsErrorTextInternal.value = e.message ?: "Could not load Hermes sessions."
            service.sessionsInternal.value = emptyList()
        } finally {
            service.isLoadingSessionsInternal.value = false
        }
    }

    suspend fun importSession(id: String): String? {
        val store = service.historyStoreInternal ?: return null
        val selected = service.selectedConnectionInternal.value
        val body =
            try {
                when (selected.mode) {
                    HermesConnectionMode.RELAY_LINK -> fetchSessionDetailViaRelay(selected, id)
                    else -> fetchSessionDetailDirect(selected, id)
                }
            } catch (_: Exception) {
                null
            } ?: return null
        val messages = HermesSessionParser.parseSessionMessages(body)
        if (messages.isEmpty()) return null
        val summary = service.sessionsInternal.value.firstOrNull { it.id == id }
        val now = System.currentTimeMillis()
        val storedMessages =
            messages.map { msg ->
                AssistantChatMessage(
                    id = msg.id ?: UUID.randomUUID().toString(),
                    role = msg.role,
                    text = msg.text,
                    timestampMillis = msg.timestampMillis ?: now,
                    modelName = msg.modelName,
                    isError = false,
                    attachments = emptyList(),
                    hermes = null,
                )
            }
        val firstUserText = messages.firstOrNull { it.role == "user" }?.text?.trim().orEmpty()
        val thread =
            AssistantChatThread(
                id = "imported-$id",
                runtime = "hermes",
                title =
                summary?.title?.takeIf { it.isNotBlank() }
                    ?: firstUserText.take(SESSION_TITLE_MAX).ifEmpty { "Imported Hermes session" },
                preview = messages.lastOrNull { it.text.isNotBlank() }?.text?.take(SESSION_PREVIEW_MAX).orEmpty(),
                modelName = summary?.model,
                createdAtMillis = summary?.startedAt ?: now,
                updatedAtMillis = summary?.lastActiveAt ?: now,
                messages = storedMessages,
            )
        store.upsert(thread)
        return thread.id
    }

    private suspend fun fetchSessionsViaRelay(connection: HermesConnectionRecord): String {
        val relay = service.relayClientInternal ?: throw HermesRelayException("Relay client unavailable.")
        val descriptor =
            HermesServiceRelayDescriptorSupport.descriptorFor(connection)
                ?: throw HermesRelayException("This Hermes relay hasn't published a usable key yet.")
        return relay.sendUnary(
            connection = descriptor,
            operation = HermesRelayOperationName.SESSIONS,
            method = "GET",
            path = "/api/sessions",
        )
    }

    private fun fetchSessionsDirect(connection: HermesConnectionRecord): String {
        val endpoint =
            HermesServiceEndpointSupport.normalizeHTTPBaseURL(connection.endpointURL ?: "")
                ?: error("This Hermes host has no valid endpoint URL.")
        val request = Request.Builder().url("$endpoint/api/sessions").get().build()
        service.httpClientInternal.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                error("Hermes sessions probe failed: HTTP ${response.code}")
            }
            return response.body?.string().orEmpty()
        }
    }

    private suspend fun fetchSessionDetailViaRelay(connection: HermesConnectionRecord, sessionId: String): String? {
        val relay = service.relayClientInternal ?: return null
        val descriptor = HermesServiceRelayDescriptorSupport.descriptorFor(connection) ?: return null
        return relay.sendUnary(
            connection = descriptor,
            operation = HermesRelayOperationName.SESSION_DETAIL,
            method = "GET",
            path = "/api/sessions/$sessionId",
            sessionId = sessionId,
        )
    }

    private fun fetchSessionDetailDirect(connection: HermesConnectionRecord, sessionId: String): String? {
        val endpoint = HermesServiceEndpointSupport.normalizeHTTPBaseURL(connection.endpointURL ?: "") ?: return null
        val request = Request.Builder().url("$endpoint/api/sessions/$sessionId").get().build()
        service.httpClientInternal.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            return response.body?.string()
        }
    }
}

internal object HermesServiceEndpointSupport {
    fun normalizeHTTPBaseURL(raw: String): String? {
        val trimmed = raw.trim().trimEnd('/')
        if (trimmed.isBlank()) return null
        val httpURL =
            when {
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

    fun selectedEndpointURL(connection: HermesConnectionRecord): String? {
        return when (connection.mode) {
            HermesConnectionMode.LOCAL, HermesConnectionMode.DIRECT_URL -> connection.endpointURL
            HermesConnectionMode.RELAY_LINK -> connection.endpointURL
        }?.let(::normalizeHTTPBaseURL)
    }

    fun legacyEndpointURL(connection: HermesConnection): String? {
        return when (connection.type) {
            ConnectionType.LOCAL, ConnectionType.LAN -> "http://${connection.host}:${connection.port}"
            ConnectionType.REMOTE_RELAY -> connection.relayUrl
        }?.let(::normalizeHTTPBaseURL)
    }
}

internal object HermesServiceRelayDescriptorSupport {
    fun descriptorFor(connection: HermesConnectionRecord): HermesRelayConnectionDescriptor? {
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
            updatedAt = null,
        )
    }
}

package com.openburnbar.data.hermes

import com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor
import com.openburnbar.data.hermes.relay.HermesRelayException
import com.openburnbar.data.hermes.relay.HermesRelayOperationName
import com.openburnbar.data.hermes.relay.HermesRelayPayload
import com.openburnbar.data.hermes.relay.HermesRelayTransporting
import org.json.JSONObject

private const val RELAY_CHAT_COMPLETION_TIMEOUT_MILLIS = 600_000L
private const val RELAY_CONTROL_TIMEOUT_MILLIS = 20_000L

/** Encrypted Mac relay payloads for CLI agent operations. */
internal class HermesServiceRelayActions(
    private val service: HermesService,
) {
    suspend fun streamCLIAgentChatPayload(body: ByteArray, sessionID: String, onRawEvent: suspend (String) -> Unit) {
        val relay = service.relayTransportInternal ?: throw HermesRelayException("Relay transport unavailable.")
        relay.sendStreaming(
            payload = macRelayPayloadForCLIAgentChat(body = body, sessionID = sessionID),
            timeoutMillis = RELAY_CHAT_COMPLETION_TIMEOUT_MILLIS,
            onSseEvent = onRawEvent,
        )
    }

    suspend fun macRelayPayloadForCLIAgentChat(body: ByteArray, sessionID: String): HermesRelayPayload {
        val connection = resolveCLIAgentChatRelayConnection()
        val descriptor =
            descriptorFor(connection)
                ?: throw HermesRelayException("This Mac relay has not published a usable encrypted relay key yet.")
        return buildRelayPayload(
            descriptor = descriptor,
            operation = HermesRelayOperationName.CLI_AGENT_CHAT,
            path = "/v1/cli-agent/chat",
            body = body,
            sessionID = sessionID,
        )
    }

    suspend fun sendCLIAgentSessionActionPayload(body: ByteArray, sessionID: String): String {
        val relay = service.relayTransportInternal ?: throw HermesRelayException("Relay transport unavailable.")
        return relay.sendUnary(
            payload = macRelayPayloadForCLIAgentSessionAction(body = body, sessionID = sessionID),
            timeoutMillis = RELAY_CONTROL_TIMEOUT_MILLIS,
        )
    }

    suspend fun macRelayPayloadForCLIAgentSessionAction(body: ByteArray, sessionID: String): HermesRelayPayload {
        val connection = resolveCLIAgentSessionActionRelayConnection()
        val descriptor =
            descriptorFor(connection)
                ?: throw HermesRelayException("This Mac relay has not published a usable encrypted relay key yet.")
        return buildRelayPayload(
            descriptor = descriptor,
            operation = HermesRelayOperationName.CLI_AGENT_SESSION_ACTION,
            path = "/v1/cli-agent/session-action",
            body = body,
            sessionID = sessionID,
        )
    }

    suspend fun fetchCLIRuntimeModelCatalog(runtime: AssistantRuntimeID): CliRuntimeModelCatalogResponse {
        val relay = service.relayTransportInternal ?: throw HermesRelayException("Relay transport unavailable.")
        val body =
            JSONObject()
                .put("runtime", runtime.token)
                .toString()
                .toByteArray(Charsets.UTF_8)
        val raw =
            relay.sendUnary(
                payload =
                macRelayPayloadForCLIRuntimeModelCatalog(
                    body = body,
                    sessionID = "cli-model-catalog-${runtime.token}",
                ),
                timeoutMillis = RELAY_CONTROL_TIMEOUT_MILLIS,
            )
        return CliRuntimeModelCatalogResponse.decode(raw)
    }

    private suspend fun macRelayPayloadForCLIRuntimeModelCatalog(body: ByteArray, sessionID: String): HermesRelayPayload {
        val connection = resolveCLIAgentModelCatalogRelayConnection()
        val descriptor =
            descriptorFor(connection)
                ?: throw HermesRelayException("This Mac relay has not published a usable encrypted relay key yet.")
        return buildRelayPayload(
            descriptor = descriptor,
            operation = HermesRelayOperationName.CLI_AGENT_MODEL_CATALOG,
            path = "/v1/cli-agent/model-catalog",
            body = body,
            sessionID = sessionID,
        )
    }

    private fun buildRelayPayload(
        descriptor: HermesRelayConnectionDescriptor,
        operation: String,
        path: String,
        body: ByteArray,
        sessionID: String,
    ): HermesRelayPayload = HermesRelayPayload(
        operation = operation,
        method = "POST",
        path = path,
        body = body,
        sessionID = sessionID,
        connectionID = descriptor.id,
        relayPublicKey = descriptor.relayPublicKey,
        relayEncryption = descriptor.relayEncryption,
        relayKeyVersion = descriptor.relayKeyVersion,
    )

    private suspend fun resolveCLIAgentChatRelayConnection(): HermesConnectionRecord = resolveRelayConnection(
        predicate = { it.isCLIAgentChatRelay() },
        onlineError =
        "Your Mac relay is online but does not advertise CLI agent chat yet. Update or restart OpenBurnBar on the Mac.",
        missingError =
        "No paired Mac relay is available for CLI agent chat. Keep OpenBurnBar open on your Mac, sign in, and enable Hermes Remote Relay.",
    )

    private suspend fun resolveCLIAgentModelCatalogRelayConnection(): HermesConnectionRecord = resolveRelayConnection(
        predicate = { it.isCLIAgentModelCatalogRelay() },
        onlineError =
        "Your Mac relay is online but does not advertise live CLI model discovery yet. Update or restart OpenBurnBar on the Mac.",
        missingError =
        "No paired Mac relay is available for CLI model discovery. Keep OpenBurnBar open on your Mac, sign in, and enable Hermes Remote Relay.",
    )

    private suspend fun resolveCLIAgentSessionActionRelayConnection(): HermesConnectionRecord = resolveRelayConnection(
        predicate = { it.isCLIAgentSessionActionRelay() },
        onlineError =
        "Your Mac relay is online but does not advertise CLI session restart yet. Update or restart OpenBurnBar on the Mac.",
        missingError =
        "No paired Mac relay is available for CLI session restart. Keep OpenBurnBar open on your Mac, sign in, and enable Hermes Remote Relay.",
    )

    private suspend fun resolveRelayConnection(
        predicate: (HermesConnectionRecord) -> Boolean,
        onlineError: String,
        missingError: String,
    ): HermesConnectionRecord {
        if (service.selectedConnectionInternal.value.mode != HermesConnectionMode.RELAY_LINK) {
            service.connectionActions.refreshRelayConnections()
            service.connectToSuggestedRelay(refresh = false)
        }
        val selected = service.selectedConnectionInternal.value
        if (predicate(selected)) return selected

        service.connectionActions.refreshRelayConnections()

        val selectedAfterRefresh = service.selectedConnectionInternal.value
        if (predicate(selectedAfterRefresh)) return selectedAfterRefresh

        val relayConnections = service.connectionsInternal.value.filter { it.mode == HermesConnectionMode.RELAY_LINK }
        relayConnections.firstOrNull(predicate)?.let { return it }

        if (relayConnections.isNotEmpty()) {
            throw HermesRelayException(onlineError)
        }
        throw HermesRelayException(missingError)
    }

    private fun descriptorFor(connection: HermesConnectionRecord): HermesRelayConnectionDescriptor? =
        HermesServiceRelayDescriptorSupport.descriptorFor(connection)

    private fun HermesConnectionRecord.isCLIAgentChatRelay(): Boolean = mode == HermesConnectionMode.RELAY_LINK &&
        !relayPublicKey.isNullOrBlank() &&
        capabilities.any { it == "cli_agent_chat" || it == HermesRelayOperationName.CLI_AGENT_CHAT }

    private fun HermesConnectionRecord.isCLIAgentModelCatalogRelay(): Boolean = mode == HermesConnectionMode.RELAY_LINK &&
        !relayPublicKey.isNullOrBlank() &&
        capabilities.any {
            it == "cli_agent_model_catalog" || it == HermesRelayOperationName.CLI_AGENT_MODEL_CATALOG
        }

    private fun HermesConnectionRecord.isCLIAgentSessionActionRelay(): Boolean = mode == HermesConnectionMode.RELAY_LINK &&
        !relayPublicKey.isNullOrBlank() &&
        capabilities.any {
            it == "cli_agent_session_action" || it == HermesRelayOperationName.CLI_AGENT_SESSION_ACTION
        }
}

internal fun HermesService.relayTransportOrThrow(): HermesRelayTransporting =
    relayTransportInternal ?: throw HermesRelayException("Relay transport unavailable.")

internal const val HERMES_RELAY_CHAT_COMPLETION_TIMEOUT_MILLIS = RELAY_CHAT_COMPLETION_TIMEOUT_MILLIS

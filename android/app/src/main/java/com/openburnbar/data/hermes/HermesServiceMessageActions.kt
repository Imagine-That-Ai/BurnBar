package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.CLIAgentChatPresentationMode
import com.openburnbar.data.assistants.CLIAgentRelayChatStreamRequest
import com.openburnbar.data.assistants.CLIAgentRelayChatTransport
import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder
import com.openburnbar.data.computeruse.SystemPermissionTextClassifier
import com.openburnbar.data.hermes.relay.HermesRelayConnectionDescriptor
import com.openburnbar.data.hermes.relay.HermesRelayOperationName
import com.openburnbar.data.hermes.relay.HermesRelayPayload
import com.openburnbar.irohrelay.HermesChatMessageOutcome as RelayHermesChatMessageOutcome
import com.openburnbar.irohrelay.HermesStreamEvent
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

private const val DESKTOP_RELAY_TITLE_MAX = 64

private data class HermesStreamEventContext(
    val service: HermesService,
    val toolDispatch: HermesServiceToolDispatch,
    val assistantID: String,
    val modelName: String,
)

private fun hasDesktopAgentRelayGrant(threadId: String?): Boolean {
    val resolved = threadId ?: return false
    return AgentCapabilityGrantState.optimisticGrant(AssistantRuntimeID.HERMES.token, resolved) != null
}

private fun buildHermesStreamRequestBody(
    modelName: String,
    conversationId: String?,
    contentBuilder: JSONObject.() -> Unit,
): String =
    JSONObject().apply {
        put("model", modelName)
        put("stream", true)
        put(
            "messages",
            JSONArray().apply {
                put(
                    JSONObject().apply {
                        put("role", "user")
                        contentBuilder()
                    },
                )
            },
        )
        conversationId?.let { put("conversation_id", it) }
    }.toString()

private fun reduceHermesStreamEvent(
    context: HermesStreamEventContext,
    event: HermesStreamEvent,
    accumulated: String,
    toolUseIterations: Int,
): Pair<String, Int> {
    return when (event) {
        is HermesStreamEvent.MessageChunk -> {
            val next = accumulated + event.text
            context.service.upsertStreamingAssistant(context.assistantID, next, context.modelName, isStreaming = true)
            next to toolUseIterations
        }
        is HermesStreamEvent.ReasoningChunk,
        is HermesStreamEvent.RefusalChunk,
        -> accumulated to toolUseIterations
        is HermesStreamEvent.ToolCallChunk -> {
            context.service.mergeToolCallForAssistant(
                assistantID = context.assistantID,
                id = event.id,
                index = event.index,
                nameFragment = event.name,
                argumentsDelta = event.argumentsDelta,
            )
            accumulated to toolUseIterations
        }
        is HermesStreamEvent.ToolCallFinished -> context.applyToolCallFinished(event, accumulated, toolUseIterations)
        is HermesStreamEvent.MessageStop -> context.applyMessageStop(event, accumulated, toolUseIterations)
        is HermesStreamEvent.Notice -> context.applyNotice(event, accumulated, toolUseIterations)
        is HermesStreamEvent.ToolResult,
        is HermesStreamEvent.LongToolHint,
        -> accumulated to toolUseIterations
    }
}

private fun HermesStreamEventContext.applyToolCallFinished(
    event: HermesStreamEvent.ToolCallFinished,
    accumulated: String,
    toolUseIterations: Int,
): Pair<String, Int> {
    service.markToolCallFinished(assistantID = assistantID, id = event.id, name = event.name, arguments = event.arguments)
    val nextIterations =
        if (toolUseIterations < service.toolUseIterationCap) {
            toolUseIterations + toolDispatch.dispatchLocalToolCall(event.name, event.arguments)
        } else {
            toolUseIterations
        }
    return accumulated to nextIterations
}

private fun HermesStreamEventContext.applyMessageStop(
    event: HermesStreamEvent.MessageStop,
    accumulated: String,
    toolUseIterations: Int,
): Pair<String, Int> {
    val outcome = event.outcome.toLocalHermesOutcome()
    if (outcome != HermesChatMessageOutcome.NORMAL) {
        val existing = service.messagesInternal.value.firstOrNull { it.id == assistantID }
        service.upsertStreamingAssistant(
            assistantID,
            existing?.content.orEmpty(),
            modelName,
            isStreaming = true,
            outcome = outcome,
            isError = existing?.isError == true,
        )
    }
    return accumulated to toolUseIterations
}

private fun HermesStreamEventContext.applyNotice(
    event: HermesStreamEvent.Notice,
    accumulated: String,
    toolUseIterations: Int,
): Pair<String, Int> {
    if (event.level != "error") return accumulated to toolUseIterations
    service.upsertStreamingAssistant(
        assistantID,
        event.text,
        modelName,
        isStreaming = true,
        outcome = HermesChatMessageOutcome.EMPTY,
        isError = true,
    )
    return event.text to toolUseIterations
}

private fun RelayHermesChatMessageOutcome.toLocalHermesOutcome(): HermesChatMessageOutcome =
    when (this) {
        RelayHermesChatMessageOutcome.NORMAL -> HermesChatMessageOutcome.NORMAL
        RelayHermesChatMessageOutcome.REFUSAL -> HermesChatMessageOutcome.REFUSAL
        RelayHermesChatMessageOutcome.REASONING_FALLBACK -> HermesChatMessageOutcome.REASONING_FALLBACK
        RelayHermesChatMessageOutcome.LENGTH_CAP -> HermesChatMessageOutcome.LENGTH_CAP
        RelayHermesChatMessageOutcome.CONTENT_FILTER -> HermesChatMessageOutcome.CONTENT_FILTER
        RelayHermesChatMessageOutcome.TOOL_CALL_NO_FOLLOW_UP -> HermesChatMessageOutcome.TOOL_CALL_NO_FOLLOW_UP
        RelayHermesChatMessageOutcome.EMPTY -> HermesChatMessageOutcome.EMPTY
    }

/** Send, stream, and retry chat turns for [HermesService]. */
internal class HermesServiceMessageActions(
    private val service: HermesService,
    private val runtimeSupport: HermesServiceRuntimeSupport,
    private val toolDispatch: HermesServiceToolDispatch,
    private val threadActions: HermesServiceThreadActions,
    scope: CoroutineScope,
) {
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()
    private val launchSupport = HermesServiceMessageLaunch(service, this, scope)
    private var streamEventParser = HermesOpenAICompatibleStreamParser()

    fun sendMessage(content: String, modelName: String, attachments: List<HermesAttachment>, conversationIdHint: String?) {
        if (service.isStreamingInternal.value) return

        val resolvedModelName = service.resolvedModelNameForSend(modelName)
        ensureThreadIDs(conversationIdHint)

        val conversationId = service.currentConversationIDInternal.value
        appendUserMessage(content, resolvedModelName, attachments)
        threadActions.persistCurrentThread()

        if (hasDesktopAgentRelayGrant(conversationId)) {
            launchSupport.launchDesktopAgentRelaySend(content, resolvedModelName, attachments, conversationId)
            return
        }
        launchSupport.launchSelectedConnectionSend(content, resolvedModelName, attachments, conversationId)
    }

    fun retryLastUserTurn() {
        if (service.isStreamingInternal.value) return
        val current = service.messagesInternal.value
        val lastUserIndex = current.indexOfLast { it.role == "user" }
        if (lastUserIndex < 0) return
        val userMessage = current[lastUserIndex]
        val trimmed = userMessage.content.trim()
        if (trimmed.isEmpty() && userMessage.attachments.isEmpty()) return

        service.messagesInternal.value = current.subList(0, lastUserIndex)
        sendMessage(
            content = trimmed,
            modelName = userMessage.modelName,
            attachments = userMessage.attachments,
            conversationIdHint = service.currentConversationIDInternal.value,
        )
    }

    internal fun dispatchLocalToolCalls(json: JSONObject): Int = toolDispatch.dispatchLocalToolCalls(json)

    fun streamHttpChatCompletion(
        endpoint: String,
        content: String,
        resolvedModelName: String,
        attachments: List<HermesAttachment>,
        conversationId: String?,
    ) {
        val userContent =
            if (attachments.isEmpty()) {
                content
            } else {
                HermesAttachmentEncoder.encodeUserTurn(
                    content,
                    attachments,
                    runtimeSupport.modelCapabilitiesFor(resolvedModelName),
                )
            }
        executeHttpChatStream(
            endpoint = runtimeSupport.endpointForModel(endpoint, resolvedModelName),
            modelName = resolvedModelName,
            conversationId = conversationId,
            userContent = userContent,
        )
    }

    suspend fun streamChatCompletionViaRelay(
        descriptor: HermesRelayConnectionDescriptor,
        prompt: String,
        modelName: String,
        attachments: List<HermesAttachment>,
        conversationId: String?,
    ) {
        val relay = service.relayTransportOrThrow()
        val assistantID = UUID.randomUUID().toString()
        var accumulated = ""
        var toolUseIterations = 0
        val rescue = HermesEmptyResponseRescue()
        streamEventParser = HermesOpenAICompatibleStreamParser()
        val body =
            buildHermesStreamRequestBody(modelName, conversationId) {
                put(
                    "content",
                    HermesAttachmentEncoder.encodeUserTurn(
                        prompt,
                        attachments,
                        runtimeSupport.modelCapabilitiesFor(modelName),
                    ),
                )
            }.toByteArray(Charsets.UTF_8)

        try {
            relay.sendStreaming(
                payload =
                HermesRelayPayload(
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
                timeoutMillis = HERMES_RELAY_CHAT_COMPLETION_TIMEOUT_MILLIS,
            ) { text ->
                text.split('\n').forEach { rawLine ->
                    val payload = HermesSseChunkReader.parseRelayLine(rawLine) ?: return@forEach
                    val result =
                        processStreamPayload(
                            payload = payload,
                            assistantID = assistantID,
                            modelName = modelName,
                            accumulated = accumulated,
                            rescue = rescue,
                            toolUseIterations = toolUseIterations,
                        )
                    accumulated = result.first
                    toolUseIterations = result.second
                }
            }
            finalizeAssistantStream(assistantID, accumulated, modelName, rescue)
        } catch (e: IOException) {
            appendAssistantError(e.message ?: e.javaClass.simpleName, modelName)
            service.runtimeErrorTextInternal.value = e.message
        }
    }

    suspend fun streamDesktopAgentRelayCompletion(prompt: String, modelName: String, conversationId: String) {
        AgentCapabilityGrantState.optimisticGrant(AssistantRuntimeID.HERMES.token, conversationId)
            ?: error("Hermes desktop permissions are not active.")
        val assistantID = UUID.randomUUID().toString()
        service.upsertStreamingAssistant(
            id = assistantID,
            content = "",
            modelName = modelName,
            isStreaming = true,
        )
        CLIAgentRelayChatTransport(service).stream(
            request =
            CLIAgentRelayChatStreamRequest(
                runtime = AssistantRuntimeID.HERMES,
                threadID = conversationId,
                prompt = prompt,
                title = derivedTitleForDesktopRelay(),
                modelID = modelName,
                parentSessionID = null,
                resumeAction = "continue",
                presentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
            ),
        ) { event ->
            val text =
                event.text?.trim()?.takeIf { it.isNotEmpty() }
                    ?: event.errorMessage?.trim()?.takeIf { it.isNotEmpty() }?.let { "Error: $it" }
                    ?: ""
            service.upsertStreamingAssistant(
                id = assistantID,
                content = text,
                modelName = event.modelID ?: modelName,
                isStreaming = !event.isTerminal,
                isError = event.isError,
            )
            if (text.isNotEmpty()) {
                SystemPermissionTextClassifier.classifyAssistantText(text)?.let { match ->
                    SystemPermissionInboxStoreHolder.ingestHeuristic(
                        kind = match.kind,
                        bundleId = match.bundleId,
                        threadId = conversationId,
                        originatingToolCallId = assistantID,
                        originatingToolName = null,
                    )
                }
            }
        }
        finalizeDesktopRelayAssistant(assistantID, modelName)
        threadActions.persistCurrentThread()
    }

    internal fun appendAssistantError(error: String, modelName: String) {
        service.messagesInternal.value = service.messagesInternal.value +
            HermesMessage(
                id = UUID.randomUUID().toString(),
                role = "assistant",
                content = "Error: $error",
                modelName = modelName,
                isError = true,
                timestamp = System.currentTimeMillis(),
            )
        threadActions.persistCurrentThread()
    }

    private fun ensureThreadIDs(conversationIdHint: String?) {
        if (service.currentThreadIDInternal.value == null) {
            service.currentThreadIDInternal.value = UUID.randomUUID().toString()
        }
        if (service.currentConversationIDInternal.value == null) {
            service.currentConversationIDInternal.value = conversationIdHint ?: UUID.randomUUID().toString()
        }
    }

    private fun appendUserMessage(content: String, modelName: String, attachments: List<HermesAttachment>) {
        service.messagesInternal.value = service.messagesInternal.value +
            HermesMessage(
                id = UUID.randomUUID().toString(),
                role = "user",
                content = content,
                modelName = modelName,
                attachments = attachments,
                timestamp = System.currentTimeMillis(),
            )
    }

    private fun executeHttpChatStream(
        endpoint: String,
        modelName: String,
        conversationId: String?,
        userContent: Any,
    ) {
        val assistantID = UUID.randomUUID().toString()
        var accumulated = ""
        var toolUseIterations = 0
        val rescue = HermesEmptyResponseRescue()
        streamEventParser = HermesOpenAICompatibleStreamParser()
        val body =
            buildHermesStreamRequestBody(modelName, conversationId) {
                put("content", userContent)
            }.toRequestBody(jsonMediaType)

        val request =
            Request.Builder()
                .url("$endpoint/v1/chat/completions")
                .post(body)
                .build()

        try {
            service.httpClientInternal.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    error("Hermes chat failed: HTTP ${response.code}")
                }
                val source =
                    response.body?.source()
                        ?: error("Hermes chat returned an empty body.")
                while (!source.exhausted()) {
                    val payload = HermesSseChunkReader.readNextPayload(source) ?: break
                    val result =
                        processStreamPayload(
                            payload = payload,
                            assistantID = assistantID,
                            modelName = modelName,
                            accumulated = accumulated,
                            rescue = rescue,
                            toolUseIterations = toolUseIterations,
                        )
                    accumulated = result.first
                    toolUseIterations = result.second
                }
            }
            finalizeAssistantStream(assistantID, accumulated, modelName, rescue)
            markRuntimeHealthy()
        } catch (e: IOException) {
            val error = e.message ?: e.javaClass.simpleName
            appendAssistantError(error, modelName)
            service.runtimeErrorTextInternal.value = error
            service.isConnectedInternal.value = false
            service.isReachableInternal.value = false
        }
    }

    private fun processStreamPayload(
        payload: String,
        assistantID: String,
        modelName: String,
        accumulated: String,
        rescue: HermesEmptyResponseRescue,
        toolUseIterations: Int,
    ): Pair<String, Int> {
        val json = runCatching { JSONObject(payload) }.getOrNull()
        json?.let { rescue.absorb(it) }
        var iterations = toolUseIterations
        val parsed = streamEventParser.eventsFromPayload(payload)
        var nextAccumulated = accumulated
        parsed.events.forEach { event ->
            val result =
                applyStreamEvent(
                    event = event,
                    assistantID = assistantID,
                    modelName = modelName,
                    accumulated = nextAccumulated,
                    toolUseIterations = iterations,
                )
            nextAccumulated = result.first
            iterations = result.second
        }
        return nextAccumulated to iterations
    }

    private fun applyStreamEvent(
        event: HermesStreamEvent,
        assistantID: String,
        modelName: String,
        accumulated: String,
        toolUseIterations: Int,
    ): Pair<String, Int> {
        return reduceHermesStreamEvent(
            context = HermesStreamEventContext(service, toolDispatch, assistantID, modelName),
            event = event,
            accumulated = accumulated,
            toolUseIterations = toolUseIterations,
        )
    }

    private fun finalizeAssistantStream(
        assistantID: String,
        accumulated: String,
        modelName: String,
        rescue: HermesEmptyResponseRescue,
    ) {
        val existing = service.messagesInternal.value.firstOrNull { it.id == assistantID }
        var finalText = accumulated.ifBlank { existing?.content.orEmpty() }
        var finalOutcome = existing?.outcome ?: HermesChatMessageOutcome.NORMAL
        var finalIsError = existing?.isError == true
        if (finalText.isBlank()) {
            val fallback = rescue.resolved()
            finalText = fallback.text
            finalOutcome = fallback.outcome
            finalIsError = fallback.isError
        }
        service.upsertStreamingAssistant(
            assistantID,
            finalText,
            modelName,
            isStreaming = false,
            outcome = finalOutcome,
            isError = finalIsError,
        )
        threadActions.persistCurrentThread()
    }

    private fun finalizeDesktopRelayAssistant(assistantID: String, modelName: String) {
        val finalMessage = service.messagesInternal.value.firstOrNull { it.id == assistantID }
        if (finalMessage != null && finalMessage.content.isBlank()) {
            service.upsertStreamingAssistant(
                id = assistantID,
                content = "The Mac relay completed without returning text.",
                modelName = modelName,
                isStreaming = false,
            )
        } else if (finalMessage != null && finalMessage.isStreaming) {
            service.upsertStreamingAssistant(
                id = assistantID,
                content = finalMessage.content,
                modelName = finalMessage.modelName,
                isStreaming = false,
                isError = finalMessage.isError,
            )
        }
    }

    private fun markRuntimeHealthy() {
        service.isConnectedInternal.value = true
        service.isReachableInternal.value = true
        service.runtimeErrorTextInternal.value = null
    }

    private fun derivedTitleForDesktopRelay(): String {
        val firstUserText = service.messagesInternal.value.firstOrNull { it.role == "user" }?.content.orEmpty()
        return firstUserText.take(DESKTOP_RELAY_TITLE_MAX).ifBlank { "Hermes desktop chat" }
    }
}

private fun HermesService.upsertStreamingAssistant(
    id: String,
    content: String,
    modelName: String,
    isStreaming: Boolean,
    outcome: HermesChatMessageOutcome = HermesChatMessageOutcome.NORMAL,
    isError: Boolean = false,
) {
    val existing = messagesInternal.value.firstOrNull { it.id == id }
    val message =
        HermesMessage(
            id = id,
            role = "assistant",
            content = content,
            modelName = modelName,
            isStreaming = isStreaming,
            isError = isError,
            outcome = outcome,
            toolCalls = existing?.toolCalls ?: emptyList(),
            timestamp = System.currentTimeMillis(),
        )
    messagesInternal.value = messagesInternal.value.filterNot { it.id == id || it.isStreaming } + message
    streamingTickInternal.value = streamingTickInternal.value + 1
}

private fun HermesService.mergeToolCallForAssistant(
    assistantID: String,
    id: String,
    index: Int,
    nameFragment: String?,
    argumentsDelta: String,
) {
    messagesInternal.value =
        messagesInternal.value.map { existing ->
            if (existing.id != assistantID) return@map existing
            val calls = existing.toolCalls.toMutableList()
            val resolvedID =
                when {
                    index >= 0 && index < calls.size -> calls[index].id
                    id.isNotBlank() -> id
                    else -> "tool-index-$index"
                }
            existing.copy(toolCalls = calls.withMergedToolCall(resolvedID, nameFragment, argumentsDelta))
        }
    streamingTickInternal.value = streamingTickInternal.value + 1
}

private fun MutableList<ToolCall>.withMergedToolCall(
    resolvedID: String,
    nameFragment: String?,
    argumentsDelta: String,
): List<ToolCall> {
    val existingIndex = indexOfFirst { it.id == resolvedID }
    if (existingIndex >= 0) {
        val current = this[existingIndex]
        this[existingIndex] =
            current.copy(
                name = nameFragment?.takeIf { it.isNotBlank() } ?: current.name,
                arguments = current.arguments + argumentsDelta,
            )
    } else {
        this +=
            ToolCall(
                id = resolvedID,
                name = nameFragment?.takeIf { it.isNotBlank() } ?: "Hermes tool",
                arguments = argumentsDelta,
            )
    }
    return this
}

private fun HermesService.markToolCallFinished(assistantID: String, id: String, name: String, arguments: String) {
    messagesInternal.value =
        messagesInternal.value.map { existing ->
            if (existing.id != assistantID) return@map existing
            existing.copy(toolCalls = existing.toolCalls.toMutableList().withFinishedToolCall(id, name, arguments))
        }
    streamingTickInternal.value = streamingTickInternal.value + 1
}

private fun MutableList<ToolCall>.withFinishedToolCall(id: String, name: String, arguments: String): List<ToolCall> {
    val index = indexOfFirst { it.id == id }
    if (index >= 0) {
        val current = this[index]
        this[index] =
            current.copy(
                name = name.ifBlank { current.name },
                arguments = current.arguments.ifBlank { arguments },
            )
    } else {
        this +=
            ToolCall(
                id = id,
                name = name.ifBlank { "Hermes tool" },
                arguments = arguments,
            )
    }
    return this
}

internal object HermesSseChunkReader {
    fun readNextPayload(source: okio.BufferedSource): String? {
        while (!source.exhausted()) {
            val payload = parseHttpLine(source.readUtf8Line()) ?: continue
            return payload
        }
        return null
    }

    fun readNextJson(source: okio.BufferedSource): JSONObject? {
        while (!source.exhausted()) {
            val payload = parseHttpLine(source.readUtf8Line()) ?: continue
            return runCatching { JSONObject(payload) }.getOrNull()
        }
        return null
    }

    fun parseRelayLine(rawLine: String): String? {
        val line = rawLine.trim()
        if (!line.startsWith("data:")) return null
        val payload = line.removePrefix("data:").trim()
        if (payload.isEmpty()) return null
        return payload
    }

    private fun parseHttpLine(line: String?): String? {
        if (line == null) return null
        if (!line.startsWith("data:")) return null
        val payload = line.removePrefix("data:").trim()
        if (payload.isEmpty()) return null
        return payload
    }
}

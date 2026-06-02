package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import com.openburnbar.data.computeruse.AgentDesktopCapability
import com.openburnbar.irohrelay.HermesStreamEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

private const val TOOL_ARGUMENT_PREVIEW_CHARS = 200

internal class PiServiceChatStreamSupport(
    private val client: OkHttpClient,
    private val messages: MutableStateFlow<List<PiChatMessage>>,
    private val selectedModelID: () -> String?,
    private val runtimeSupport: PiServiceRuntimeSupport,
    private val appendToAssistant: (assistantId: String, delta: String, transform: ((PiChatMessage) -> PiChatMessage)?) -> Unit,
    private val applyError: (assistantId: String, text: String) -> Unit,
) {
    private var streamEventParser = HermesOpenAICompatibleStreamParser()

    suspend fun streamDesktopAgentChat(prompt: String, assistantId: String) {
        val threadID = currentThreadID() ?: error("Create a Pi thread before granting desktop permissions.")
        val grant =
            AgentCapabilityGrantState.optimisticGrant(AssistantRuntimeID.PI.token, threadID)
                ?: error("Pi desktop permissions are not active.")
        val requestID =
            CLIAgentMissionDispatcher().dispatch(
                title = "Pi desktop chat",
                prompt = prompt,
                missionKind = "chat",
                requestedRuntime = AssistantRuntimeID.PI.token,
                approvalMode = "existing_policy",
                commandsAllowed =
                grant.capabilities.any {
                    it == AgentDesktopCapability.SHELL.wireValue ||
                        it == AgentDesktopCapability.SHELL_UNRESTRICTED.wireValue
                },
                fileEditsAllowed = grant.capabilities.contains(AgentDesktopCapability.WORKSPACE_WRITE.wireValue),
                clientThreadID = threadID,
                resumeAction = "continue",
            )
        CLIAgentMissionDispatcher().observe(requestID).first { snapshot ->
            val text =
                snapshot.errorMessage
                    ?: snapshot.resultPreview
                    ?: snapshot.displayLiveSummary
                    ?: snapshot.events.lastOrNull()?.message
                    ?: "Waiting for your Mac..."
            appendToAssistant(assistantId, "") { msg ->
                msg.copy(
                    content = text,
                    isStreaming = !snapshot.isTerminal,
                    isError = snapshot.errorMessage != null,
                    modelName = snapshot.selectedModelID ?: msg.modelName,
                )
            }
            snapshot.isTerminal
        }
    }

    suspend fun streamChat(prompt: String, assistantId: String) {
        streamEventParser = HermesOpenAICompatibleStreamParser()
        val base = runtimeSupport.resolvedBaseURL() ?: error("Pi base URL missing.")
        val modelID = selectedModelID() ?: "pi"
        val body = buildStreamChatPayload(modelID, prompt, assistantId).toRequestBody("application/json".toMediaType())
        val endpoint = runtimeSupport.endpointForModel(base, modelID)
        val request =
            Request.Builder()
                .url("$endpoint/v1/chat/completions")
                .post(body)
                .addHeader("Accept", "text/event-stream")
                .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                applyError(assistantId, "Pi gateway HTTP ${response.code}.")
                return
            }
            val source = response.body?.source() ?: return
            consumeSseChatStream(source, assistantId)
        }
    }

    private fun buildStreamChatPayload(modelID: String, prompt: String, assistantId: String): String = JSONObject().apply {
        put("model", modelID)
        put("stream", true)
        put("messages", buildChatMessageArray(prompt, assistantId))
    }.toString()

    private fun buildChatMessageArray(prompt: String, assistantId: String): JSONArray {
        val messageArray = JSONArray()
        messages.value.forEach { msg ->
            if (msg.id == assistantId || msg.isError) return@forEach
            messageArray.put(
                JSONObject().apply {
                    put("role", msg.role)
                    put("content", msg.content)
                },
            )
        }
        messageArray.put(
            JSONObject().apply {
                put("role", "user")
                put("content", prompt)
            },
        )
        return messageArray
    }

    private fun consumeSseChatStream(source: okio.BufferedSource, assistantId: String) {
        while (!source.exhausted()) {
            val payload = HermesSseChunkReader.parseRelayLine(source.readUtf8Line() ?: continue) ?: continue
            if (applySsePayload(payload, assistantId)) return
        }
    }

    internal fun applySsePayload(payloadText: String, assistantId: String): Boolean {
        val result = streamEventParser.eventsFromPayload(payloadText)
        result.events.forEach { event ->
            when (event) {
                is HermesStreamEvent.MessageChunk -> appendToAssistant(assistantId, event.text, null)
                is HermesStreamEvent.ToolCallChunk ->
                    mergeToolCallForAssistant(
                        assistantId = assistantId,
                        id = event.id,
                        index = event.index,
                        nameFragment = event.name,
                        argumentsDelta = event.argumentsDelta,
                    )
                is HermesStreamEvent.ToolCallFinished ->
                    markToolCallFinished(
                        assistantId = assistantId,
                        id = event.id,
                        name = event.name,
                        arguments = event.arguments,
                    )
                is HermesStreamEvent.Notice -> {
                    if (event.level == "error") {
                        applyError(assistantId, event.text)
                    }
                }
                is HermesStreamEvent.ReasoningChunk,
                is HermesStreamEvent.RefusalChunk,
                is HermesStreamEvent.MessageStop,
                is HermesStreamEvent.ToolResult,
                is HermesStreamEvent.LongToolHint,
                -> Unit
            }
        }
        return result.done
    }

    fun mergeToolCallsForAssistant(assistantId: String, calls: JSONArray) {
        messages.value =
            messages.value.map { existing ->
                if (existing.id != assistantId) return@map existing
                val current = existing.toolCalls.toMutableList()
                for (i in 0 until calls.length()) {
                    calls.optJSONObject(i)?.let { raw ->
                        mergeToolCallFragment(current, raw)
                    }
                }
                existing.copy(toolCalls = current)
            }
    }

    private fun mergeToolCallFragment(current: MutableList<PiToolCall>, raw: org.json.JSONObject) {
        val function = raw.optJSONObject("function")
        val nameFragment = (function?.optString("name") ?: raw.optString("name"))?.ifEmpty { null }
        val argsFragment = (function?.optString("arguments") ?: raw.optString("arguments"))?.ifEmpty { null }
        val indexHint = if (raw.has("index")) raw.optInt("index", -1).takeIf { it >= 0 } else null
        val idFromPayload = raw.optString("id").ifEmpty { null }

        val resolvedID: String =
            when {
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
            current[existingIdx] =
                tc.copy(
                    name = newName,
                    arguments = newArgs,
                    status = "running",
                    detail = PiServiceToolArgumentSummarizer.summarize(newArgs) ?: tc.detail,
                )
        } else {
            val newName = if (!nameFragment.isNullOrEmpty()) nameFragment else "Pi tool"
            val newArgs = argsFragment ?: ""
            current +=
                PiToolCall(
                    id = resolvedID,
                    name = newName,
                    status = "running",
                    arguments = newArgs,
                    detail = PiServiceToolArgumentSummarizer.summarize(newArgs),
                )
        }
    }

    private fun mergeToolCallForAssistant(
        assistantId: String,
        id: String,
        index: Int,
        nameFragment: String?,
        argumentsDelta: String,
    ) {
        messages.value =
            messages.value.map { existing ->
                if (existing.id != assistantId) return@map existing
                val current = existing.toolCalls.toMutableList()
                val resolvedID =
                    when {
                        index >= 0 && index < current.size -> current[index].id
                        id.isNotBlank() -> id
                        else -> "pi-tool-index-$index"
                    }
                val existingIdx = current.indexOfFirst { it.id == resolvedID }
                if (existingIdx >= 0) {
                    val tc = current[existingIdx]
                    val newArgs = tc.arguments + argumentsDelta
                    current[existingIdx] =
                        tc.copy(
                            name = nameFragment?.takeIf { it.isNotBlank() } ?: tc.name,
                            arguments = newArgs,
                            status = "running",
                            detail = PiServiceToolArgumentSummarizer.summarize(newArgs) ?: tc.detail,
                        )
                } else {
                    val newArgs = argumentsDelta
                    current +=
                        PiToolCall(
                            id = resolvedID,
                            name = nameFragment?.takeIf { it.isNotBlank() } ?: "Pi tool",
                            status = "running",
                            arguments = newArgs,
                            detail = PiServiceToolArgumentSummarizer.summarize(newArgs),
                        )
                }
                existing.copy(toolCalls = current)
            }
    }

    private fun markToolCallFinished(assistantId: String, id: String, name: String, arguments: String) {
        messages.value =
            messages.value.map { existing ->
                if (existing.id != assistantId) return@map existing
                val current = existing.toolCalls.toMutableList()
                val existingIdx = current.indexOfFirst { it.id == id }
                if (existingIdx >= 0) {
                    val tc = current[existingIdx]
                    val resolvedArguments = tc.arguments.ifBlank { arguments }
                    current[existingIdx] =
                        tc.copy(
                            name = name.ifBlank { tc.name },
                            arguments = resolvedArguments,
                            detail = PiServiceToolArgumentSummarizer.summarize(resolvedArguments) ?: tc.detail,
                        )
                } else {
                    current +=
                        PiToolCall(
                            id = id,
                            name = name.ifBlank { "Pi tool" },
                            status = "running",
                            arguments = arguments,
                            detail = PiServiceToolArgumentSummarizer.summarize(arguments),
                        )
                }
                existing.copy(toolCalls = current)
            }
    }

    lateinit var currentThreadID: () -> String?
}

internal object PiServiceToolArgumentSummarizer {
    fun summarize(raw: String): String? = summarizeToolArguments(raw.trim())

    private fun summarizeToolArguments(trimmed: String): String? {
        if (trimmed.isEmpty()) return null
        val preferredKeys = listOf("path", "file_path", "command", "pattern", "query", "url", "prompt")
        runCatching {
            val obj = JSONObject(trimmed)
            preferredKeys.firstNotNullOfOrNull { key ->
                obj.optString(key).takeIf { it.isNotEmpty() }?.take(TOOL_ARGUMENT_PREVIEW_CHARS)
            }?.let { return it }
            val keys = obj.keys()
            while (keys.hasNext()) {
                val value = obj.optString(keys.next())
                if (value.isNotEmpty()) return value.take(TOOL_ARGUMENT_PREVIEW_CHARS)
            }
        }
        return preferredKeys.firstNotNullOfOrNull { key ->
            val pattern = "\"$key\"\\s*:\\s*\"([^\"]+)\"".toRegex()
            pattern.find(trimmed)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }?.take(TOOL_ARGUMENT_PREVIEW_CHARS)
        }
    }
}

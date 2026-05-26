package com.openburnbar.data.assistants

import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.hermes.CliRuntimeModelCatalogResponse
import com.openburnbar.data.hermes.HermesService
import org.json.JSONArray
import org.json.JSONObject

interface CLIAgentRelayChatTransporting {
    suspend fun fetchModelCatalog(runtime: AssistantRuntimeID): CliRuntimeModelCatalogResponse

    suspend fun stream(
        runtime: AssistantRuntimeID,
        threadID: String,
        prompt: String,
        title: String,
        modelID: String?,
        parentSessionID: String?,
        resumeAction: String?,
        presentationMode: CLIAgentChatPresentationMode,
        onEvent: suspend (CLIAgentRelayChatEvent) -> Unit,
    )
}

interface CLIAgentRelayChatPayloadStreamer {
    suspend fun fetchCLIRuntimeModelCatalog(runtime: AssistantRuntimeID): CliRuntimeModelCatalogResponse

    suspend fun streamCLIAgentChatPayload(
        body: ByteArray,
        sessionID: String,
        onRawEvent: suspend (String) -> Unit,
    )
}

private class HermesServiceCLIAgentRelayChatPayloadStreamer(
    private val hermesService: HermesService,
) : CLIAgentRelayChatPayloadStreamer {
    override suspend fun fetchCLIRuntimeModelCatalog(runtime: AssistantRuntimeID): CliRuntimeModelCatalogResponse =
        hermesService.fetchCLIRuntimeModelCatalog(runtime)

    override suspend fun streamCLIAgentChatPayload(
        body: ByteArray,
        sessionID: String,
        onRawEvent: suspend (String) -> Unit,
    ) {
        hermesService.streamCLIAgentChatPayload(
            body = body,
            sessionID = sessionID,
            onRawEvent = onRawEvent,
        )
    }
}

class CLIAgentRelayChatTransport(
    private val payloadStreamer: CLIAgentRelayChatPayloadStreamer,
) : CLIAgentRelayChatTransporting {
    constructor(hermesService: HermesService) : this(
        HermesServiceCLIAgentRelayChatPayloadStreamer(hermesService),
    )

    override suspend fun fetchModelCatalog(runtime: AssistantRuntimeID): CliRuntimeModelCatalogResponse =
        payloadStreamer.fetchCLIRuntimeModelCatalog(runtime)

    override suspend fun stream(
        runtime: AssistantRuntimeID,
        threadID: String,
        prompt: String,
        title: String,
        modelID: String?,
        parentSessionID: String?,
        resumeAction: String?,
        presentationMode: CLIAgentChatPresentationMode,
        onEvent: suspend (CLIAgentRelayChatEvent) -> Unit,
    ) {
        val trimmedPrompt = prompt.trim()
        require(trimmedPrompt.isNotEmpty()) { "Cannot send an empty CLI agent prompt." }

        val request = CLIAgentRelayChatRequest(
            runtime = runtime.token,
            prompt = trimmedPrompt,
            clientThreadID = threadID,
            modelID = modelID?.trim()?.takeIf { it.isNotEmpty() },
            title = title.trim().takeIf { it.isNotEmpty() },
            parentSessionID = parentSessionID?.trim()?.takeIf { it.isNotEmpty() },
            resumeAction = resumeAction?.trim()?.takeIf { it.isNotEmpty() },
            presentationMode = presentationMode,
        )
        var decodeError: Throwable? = null
        payloadStreamer.streamCLIAgentChatPayload(
            body = request.toJsonByteArray(),
            sessionID = threadID,
        ) { rawEvent ->
            if (decodeError != null) return@streamCLIAgentChatPayload
            try {
                onEvent(CLIAgentRelayChatEvent.decode(rawEvent))
            } catch (t: Throwable) {
                decodeError = t
            }
        }
        decodeError?.let { throw it }
    }
}

data class CLIAgentRelayChatRequest(
    val runtime: String,
    val prompt: String,
    val clientThreadID: String,
    val modelID: String? = null,
    val title: String? = null,
    val parentSessionID: String? = null,
    val resumeAction: String? = null,
    val presentationMode: CLIAgentChatPresentationMode = CLIAgentChatPresentationMode.NATIVE_CHAT,
) {
    fun toJsonByteArray(): ByteArray {
        val json = JSONObject()
            .put("runtime", runtime)
            .put("prompt", prompt)
            .put("clientThreadID", clientThreadID)
            .put("presentationMode", presentationMode.wire)
        json.putIfPresent("modelID", modelID)
        json.putIfPresent("title", title)
        json.putIfPresent("parentSessionID", parentSessionID)
        json.putIfPresent("resumeAction", resumeAction)
        return json.toString().toByteArray(Charsets.UTF_8)
    }
}

enum class CLIAgentRelayChatEventKind(val wire: String) {
    ASSISTANT_SNAPSHOT("assistantSnapshot"),
    COMPLETED("completed"),
    FAILED("failed");

    companion object {
        fun fromWire(value: String?): CLIAgentRelayChatEventKind? =
            values().firstOrNull { it.wire == value }
                ?: when (value) {
                    "assistant_snapshot" -> ASSISTANT_SNAPSHOT
                    else -> null
                }
    }
}

enum class CLIAgentRelayTranscriptPieceKind(val wire: String) {
    TEXT("text"),
    TOOL_USE("toolUse"),
    TOOL_RESULT("toolResult");

    companion object {
        fun fromWire(value: String?): CLIAgentRelayTranscriptPieceKind? =
            values().firstOrNull { it.wire == value }
                ?: when (value) {
                    "tool_use" -> TOOL_USE
                    "tool_result" -> TOOL_RESULT
                    else -> null
                }
    }
}

data class CLIAgentRelayTranscriptPiece(
    val id: String,
    val kind: CLIAgentRelayTranscriptPieceKind,
    val value: String,
    val detail: String? = null,
)

data class CLIAgentRelayChatEvent(
    val kind: CLIAgentRelayChatEventKind,
    val text: String? = null,
    val modelID: String? = null,
    val transcriptPieces: List<CLIAgentRelayTranscriptPiece> = emptyList(),
    val errorMessage: String? = null,
) {
    val isTerminal: Boolean
        get() = kind == CLIAgentRelayChatEventKind.COMPLETED ||
            kind == CLIAgentRelayChatEventKind.FAILED

    val isError: Boolean
        get() = kind == CLIAgentRelayChatEventKind.FAILED

    companion object {
        fun decode(raw: String): CLIAgentRelayChatEvent {
            val json = JSONObject(raw)
            val kind = CLIAgentRelayChatEventKind.fromWire(json.optNullableString("kind"))
                ?: throw IllegalArgumentException("Unknown CLI agent relay chat event kind.")
            return CLIAgentRelayChatEvent(
                kind = kind,
                text = json.optNullableString("text"),
                modelID = json.optNullableString("modelID"),
                transcriptPieces = json.optJSONArray("transcriptPieces").toTranscriptPieces(),
                errorMessage = json.optNullableString("errorMessage"),
            )
        }
    }
}

private fun JSONObject.putIfPresent(key: String, value: String?) {
    val trimmed = value?.trim()?.takeIf { it.isNotEmpty() } ?: return
    put(key, trimmed)
}

private fun JSONObject.optNullableString(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return optString(key).takeIf { it.isNotEmpty() }
}

private fun JSONArray?.toTranscriptPieces(): List<CLIAgentRelayTranscriptPiece> {
    if (this == null) return emptyList()
    val pieces = mutableListOf<CLIAgentRelayTranscriptPiece>()
    for (index in 0 until length()) {
        val item = optJSONObject(index) ?: continue
        val id = item.optNullableString("id") ?: continue
        val kind = CLIAgentRelayTranscriptPieceKind.fromWire(item.optNullableString("kind")) ?: continue
        val value = item.optNullableString("value") ?: ""
        pieces += CLIAgentRelayTranscriptPiece(
            id = id,
            kind = kind,
            value = value,
            detail = item.optNullableString("detail"),
        )
    }
    return pieces
}

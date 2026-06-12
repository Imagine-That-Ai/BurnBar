
package com.openburnbar.ui.hermes

import com.openburnbar.data.assistants.CLIAgentRelayChatStreamRequest

import com.openburnbar.data.models.AgentProvider
import android.net.Uri
import com.openburnbar.data.assistants.AssistantChatAttachment
import com.openburnbar.data.assistants.AssistantChatHermesMetadata
import com.openburnbar.data.assistants.AssistantChatHistoryStore
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.assistants.AssistantChatToolCall
import com.openburnbar.data.assistants.CLIAgentChatPresentationMode
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.data.assistants.CLIAgentRelayChatEvent
import com.openburnbar.data.assistants.CLIAgentRelayChatTransporting
import com.openburnbar.data.assistants.CLIAgentRelayTranscriptPieceKind
import com.openburnbar.data.computeruse.AgentCapabilityGrantState
import com.openburnbar.data.computeruse.AgentDesktopCapability
import com.openburnbar.data.hermes.AssistantRuntimeID
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

// MARK: - Helpers

internal val CLIAgentChatPresentationMode.androidSourceSurface: String
    get() =
        when (this) {
            CLIAgentChatPresentationMode.NATIVE_CHAT -> "android-chat-native"
            CLIAgentChatPresentationMode.MAC_VISIBLE_CLI -> "android-chat-mac-visible-cli"
            CLIAgentChatPresentationMode.MAC_INTERACTIVE_CLI -> "android-chat-mac-interactive-cli"
        }

internal val CLIAgentChatPresentationMode.deliveryMode: com.openburnbar.data.assistants.SkillRunDeliveryMode
    get() =
        when (this) {
            CLIAgentChatPresentationMode.NATIVE_CHAT -> com.openburnbar.data.assistants.SkillRunDeliveryMode.ACTION_ONLY
            CLIAgentChatPresentationMode.MAC_VISIBLE_CLI -> com.openburnbar.data.assistants.SkillRunDeliveryMode.FULL_STREAM
            CLIAgentChatPresentationMode.MAC_INTERACTIVE_CLI -> com.openburnbar.data.assistants.SkillRunDeliveryMode.FULL_STREAM
        }

internal fun cliModelPreferenceKey(runtime: AssistantRuntimeID): String = "assistants.preferredModelID.${runtime.token}"

internal fun cliPresentationModePreferenceKey(runtime: AssistantRuntimeID): String = "assistants.presentationMode.${runtime.token}"

internal fun preferredCliModelID(context: android.content.Context, runtime: AssistantRuntimeID): String? =
    context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
        .getString(cliModelPreferenceKey(runtime), null)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }

internal fun preferredCliPresentationMode(context: android.content.Context, runtime: AssistantRuntimeID): CLIAgentChatPresentationMode =
    CLIAgentChatPresentationMode.fromWire(
        context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
            .getString(cliPresentationModePreferenceKey(runtime), null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() },
    )

internal fun setPreferredCliModelID(context: android.content.Context, runtime: AssistantRuntimeID, modelID: String?) {
    val prefs = context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
    prefs.edit().apply {
        val trimmed = modelID?.trim()?.takeIf { it.isNotEmpty() }
        if (trimmed == null) remove(cliModelPreferenceKey(runtime)) else putString(cliModelPreferenceKey(runtime), trimmed)
    }.apply()
}

internal fun setPreferredCliPresentationMode(context: android.content.Context, runtime: AssistantRuntimeID, mode: CLIAgentChatPresentationMode) {
    context.getSharedPreferences("assistant_model_preferences", android.content.Context.MODE_PRIVATE)
        .edit()
        .putString(cliPresentationModePreferenceKey(runtime), mode.wire)
        .apply()
}

internal fun attachmentFor(context: android.content.Context, uri: Uri, fallbackMime: String): AssistantChatAttachment {
    val resolver = context.contentResolver
    val mime = resolver.getType(uri) ?: fallbackMime
    var displayName = uri.lastPathSegment ?: "attachment"
    var byteSize: Long = 0
    runCatching {
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                if (nameIdx >= 0 && !cursor.isNull(nameIdx)) displayName = cursor.getString(nameIdx)
                if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) byteSize = cursor.getLong(sizeIdx)
            }
        }
    }
    return AssistantChatAttachment(
        id = UUID.randomUUID().toString(),
        kind = if (mime.startsWith("image/")) "image" else "file",
        displayName = displayName,
        mimeType = mime,
        byteSize = byteSize,
        workspaceRelativePath = uri.toString(),
    )
}

internal fun createThread(historyStore: AssistantChatHistoryStore, runtime: AssistantRuntimeID): AssistantChatThread {
    val now = System.currentTimeMillis()
    val thread =
        AssistantChatThread(
            id = "android-${runtime.token}-${UUID.randomUUID()}",
            runtime = runtime.token,
            title = "New Chat",
            preview = "",
            createdAtMillis = now,
            updatedAtMillis = now,
            messages = emptyList(),
        )
    historyStore.upsert(thread)
    return thread
}

internal data class CliSendMessageRequest(
    val text: String,
    val attachments: List<AssistantChatAttachment>,
    val runtime: AssistantRuntimeID,
    val requestedModelID: String?,
    val presentationMode: CLIAgentChatPresentationMode,
    val threadID: String,
)

internal data class CliSendMessageDeps(
    val historyStore: AssistantChatHistoryStore,
    val relayChatTransport: CLIAgentRelayChatTransporting,
    val dispatcher: CLIAgentMissionDispatcher,
    val scope: kotlinx.coroutines.CoroutineScope,
)

internal data class CliSendMessageCallbacks(
    val onPending: (requestID: String?, streamingMessageID: String?, job: Job?) -> Unit,
    val onStreamComplete: () -> Unit,
)

internal data class CliMissionFallbackRequest(
    val text: String,
    val runtime: AssistantRuntimeID,
    val requestedModelID: String?,
    val presentationMode: CLIAgentChatPresentationMode,
    val threadID: String,
    val threadTitle: String,
    val placeholderID: String,
)

internal fun sendMessage(request: CliSendMessageRequest, deps: CliSendMessageDeps, callbacks: CliSendMessageCallbacks) {
    val thread = deps.historyStore.thread(request.threadID) ?: return
    val placeholder = appendCliSendMessages(deps.historyStore, thread, request)
    callbacks.onPending(null, placeholder.id, null)
    val job = deps.scope.launch {
        runCliSendJob(request = request, thread = thread, placeholderID = placeholder.id, deps = deps, callbacks = callbacks)
    }
    callbacks.onPending(null, placeholder.id, job)
}

private fun appendCliSendMessages(
    historyStore: AssistantChatHistoryStore,
    thread: AssistantChatThread,
    request: CliSendMessageRequest,
): AssistantChatMessage {
    val now = System.currentTimeMillis()
    val userMessage =
        AssistantChatMessage(
            role = "user",
            text = request.text,
            timestampMillis = now,
            attachments = request.attachments,
        )
    val placeholder =
        AssistantChatMessage(
            role = "assistant",
            text = "",
            timestampMillis = now + 1,
            modelName = null,
        )
    historyStore.upsert(
        thread.copy(
            messages = thread.messages + userMessage + placeholder,
            preview = request.text.take(80),
            updatedAtMillis = now,
        ),
    )
    return placeholder
}

private suspend fun runCliSendJob(
    request: CliSendMessageRequest,
    thread: AssistantChatThread,
    placeholderID: String,
    deps: CliSendMessageDeps,
    callbacks: CliSendMessageCallbacks,
) {
    if (request.presentationMode != CLIAgentChatPresentationMode.NATIVE_CHAT) {
        dispatchMissionFallback(
            request =
            CliMissionFallbackRequest(
                text = request.text,
                runtime = request.runtime,
                requestedModelID = request.requestedModelID,
                presentationMode = request.presentationMode,
                threadID = request.threadID,
                threadTitle = thread.title,
                placeholderID = placeholderID,
            ),
            historyStore = deps.historyStore,
            dispatcher = deps.dispatcher,
            callbacks = callbacks,
        )
        return
    }
    streamCliRelayResponse(request = request, thread = thread, placeholderID = placeholderID, deps = deps, callbacks = callbacks)
}

private suspend fun streamCliRelayResponse(
    request: CliSendMessageRequest,
    thread: AssistantChatThread,
    placeholderID: String,
    deps: CliSendMessageDeps,
    callbacks: CliSendMessageCallbacks,
) {
    try {
        deps.relayChatTransport.stream(
            request =
            CLIAgentRelayChatStreamRequest(
                runtime = request.runtime,
                threadID = request.threadID,
                prompt = request.text,
                title = thread.title,
                modelID = request.requestedModelID,
                parentSessionID = null,
                resumeAction = "continue",
                presentationMode = request.presentationMode,
            ),
        ) { event ->
            applyRelayEvent(
                historyStore = deps.historyStore,
                threadID = request.threadID,
                placeholderID = placeholderID,
                event = event,
                fallbackModelName = request.requestedModelID,
            )
            if (event.isTerminal) {
                callbacks.onStreamComplete()
            }
        }
        val finalThread = deps.historyStore.thread(request.threadID)
        val finalMessage = finalThread?.messages?.firstOrNull { it.id == placeholderID }
        if (finalMessage == null || finalMessage.text.isBlank()) {
            finalizeMessage(
                historyStore = deps.historyStore,
                threadID = request.threadID,
                placeholderID = placeholderID,
                text = "${request.runtime.displayName} finished without a visible reply.",
                isError = false,
                modelName = request.requestedModelID,
            )
        }
        callbacks.onStreamComplete()
    } catch (t: IOException) {
        handleCliRelaySendFailure(
            error = t,
            request = request,
            thread = thread,
            placeholderID = placeholderID,
            deps = deps,
            callbacks = callbacks,
        )
    }
}

private suspend fun handleCliRelaySendFailure(
    error: IOException,
    request: CliSendMessageRequest,
    thread: AssistantChatThread,
    placeholderID: String,
    deps: CliSendMessageDeps,
    callbacks: CliSendMessageCallbacks,
) {
    if (shouldFallBackToMissionAfterRelayError(error)) {
        dispatchMissionFallback(
            request =
            CliMissionFallbackRequest(
                text = request.text,
                runtime = request.runtime,
                requestedModelID = request.requestedModelID,
                presentationMode = request.presentationMode,
                threadID = request.threadID,
                threadTitle = thread.title,
                placeholderID = placeholderID,
            ),
            historyStore = deps.historyStore,
            dispatcher = deps.dispatcher,
            callbacks = callbacks,
        )
        return
    }
    finalizeMessage(
        historyStore = deps.historyStore,
        threadID = request.threadID,
        placeholderID = placeholderID,
        text = "Couldn't reach ${request.runtime.displayName} on your Mac: ${error.localizedMessage ?: error::class.java.simpleName}",
        isError = true,
    )
    callbacks.onStreamComplete()
}

private suspend fun dispatchMissionFallback(
    request: CliMissionFallbackRequest,
    historyStore: AssistantChatHistoryStore,
    dispatcher: CLIAgentMissionDispatcher,
    callbacks: CliSendMessageCallbacks,
) {
    val text = request.text
    val runtime = request.runtime
    val requestedModelID = request.requestedModelID
    val presentationMode = request.presentationMode
    val threadID = request.threadID
    val threadTitle = request.threadTitle
    val placeholderID = request.placeholderID
    val onPending = callbacks.onPending
    val onStreamComplete = callbacks.onStreamComplete
    val requestID =
        try {
            val grant = AgentCapabilityGrantState.optimisticGrant(runtime.token, threadID)
            dispatcher.dispatch(
                title = threadTitle,
                prompt = text,
                missionKind = "chat",
                requestedRuntime = runtime.token,
                approvalMode = "existing_policy",
                commandsAllowed =
                grant?.capabilities?.any {
                    it == AgentDesktopCapability.SHELL.wireValue ||
                        it == AgentDesktopCapability.SHELL_UNRESTRICTED.wireValue
                } == true,
                fileEditsAllowed = grant?.capabilities?.contains(AgentDesktopCapability.WORKSPACE_WRITE.wireValue) == true,
                requestedModelID = requestedModelID?.trim()?.takeIf { it.isNotEmpty() },
                clientThreadID = threadID,
                resumeAction = "continue",
                sourceSurface = presentationMode.androidSourceSurface,
                deliveryMode = presentationMode.deliveryMode,
                presentationMode = presentationMode,
            )
        } catch (t: IOException) {
            finalizeMessage(
                historyStore = historyStore,
                threadID = threadID,
                placeholderID = placeholderID,
                text = "Couldn't reach the Mac runtime: ${t.localizedMessage ?: t::class.java.simpleName}",
                isError = true,
            )
            onStreamComplete()
            return
        }
    onPending(requestID, placeholderID, null)
    dispatcher.observe(requestID).first { snapshot ->
        applySnapshot(
            historyStore = historyStore,
            threadID = threadID,
            placeholderID = placeholderID,
            snapshot = snapshot,
        )
        if (snapshot.isTerminal) {
            onStreamComplete()
        }
        snapshot.isTerminal
    }
}

internal fun shouldFallBackToMissionAfterRelayError(error: Throwable): Boolean {
    val lower = (error.localizedMessage ?: error.message ?: "").lowercase()
    if (lower.contains("already responding") ||
        lower.contains("unsupported runtime") ||
        lower.contains("cannot send an empty")
    ) {
        return false
    }
    return true
}

internal fun applyRelayEvent(
    historyStore: AssistantChatHistoryStore,
    threadID: String,
    placeholderID: String,
    event: CLIAgentRelayChatEvent,
    fallbackModelName: String?,
) {
    val relayText = event.text?.trim()?.takeIf { it.isNotEmpty() }
    val errorText = event.errorMessage?.trim()?.takeIf { it.isNotEmpty() }
    val visibleText = relayText ?: errorText?.let { "Error: $it" } ?: ""
    val toolCalls = mobileToolCalls(event = event)
    finalizeMessage(
        historyStore = historyStore,
        threadID = threadID,
        placeholderID = placeholderID,
        text = visibleText,
        isError = event.isError,
        modelName = event.modelID ?: fallbackModelName,
        toolCalls = toolCalls,
    )
}

internal fun mobileToolCalls(event: CLIAgentRelayChatEvent): List<AssistantChatToolCall> = event.transcriptPieces.mapNotNull { piece ->
    when (piece.kind) {
        CLIAgentRelayTranscriptPieceKind.TOOL_USE,
        CLIAgentRelayTranscriptPieceKind.TOOL_RESULT,
        ->
            AssistantChatToolCall(
                id = piece.id,
                name = piece.value.ifBlank { piece.kind.wire },
                status = piece.detail?.trim()?.takeIf { it.isNotEmpty() } ?: "done",
            )
        CLIAgentRelayTranscriptPieceKind.TEXT -> null
    }
}

internal fun applySnapshot(historyStore: AssistantChatHistoryStore, threadID: String, placeholderID: String, snapshot: CLIAgentMissionSnapshot) {
    val resultPreview = snapshot.resultPreview?.takeIf { it.isNotBlank() }
    val liveSummary = snapshot.displayLiveSummary?.takeIf { it.isNotBlank() }
    val nextText =
        when {
            snapshot.status == "completed" && resultPreview != null -> resultPreview
            snapshot.errorMessage?.isNotBlank() == true -> "Error: ${snapshot.errorMessage}"
            resultPreview != null -> resultPreview
            liveSummary != null -> liveSummary
            else -> snapshot.currentStepLabel
        }
    val isError =
        snapshot.status in setOf("failed", "agent_launch_failed", "unauthorized") ||
            snapshot.errorMessage?.isNotBlank() == true
    finalizeMessage(
        historyStore = historyStore,
        threadID = threadID,
        placeholderID = placeholderID,
        text = nextText,
        isError = isError,
        modelName = snapshot.runtimeLabel,
        toolCalls = snapshotToolCalls(snapshot),
    )
}

internal fun snapshotToolCalls(snapshot: CLIAgentMissionSnapshot): List<AssistantChatToolCall> = snapshot.events.mapNotNull { event ->
    val name =
        event.toolName?.takeIf { it.isNotBlank() }
            ?: event.title?.takeIf {
                event.kind == "tool_call" ||
                    event.kind == "tool_result" ||
                    event.phase == "tool_use" ||
                    event.phase == "tool_result"
            }
            ?: return@mapNotNull null
    AssistantChatToolCall(
        id = "${snapshot.id}-${event.sequence}",
        name = name,
        status =
        event.changedFilePath?.takeIf { it.isNotBlank() }
            ?: event.artifactPath?.takeIf { it.isNotBlank() }
            ?: "done",
    )
}

internal fun finalizeMessage(
    historyStore: AssistantChatHistoryStore,
    threadID: String,
    placeholderID: String,
    text: String,
    isError: Boolean,
    modelName: String? = null,
    toolCalls: List<AssistantChatToolCall> = emptyList(),
) {
    val thread = historyStore.thread(threadID) ?: return
    val updatedMessages =
        thread.messages.map { msg ->
            if (msg.id == placeholderID) {
                val hermesMetadata =
                    if (toolCalls.isNotEmpty()) {
                        (msg.hermes ?: AssistantChatHermesMetadata()).copy(toolCalls = toolCalls)
                    } else {
                        msg.hermes
                    }
                val resolvedText = if (text.isEmpty() && toolCalls.isNotEmpty()) msg.text else text
                msg.copy(
                    text = resolvedText,
                    isError = isError,
                    modelName = modelName ?: msg.modelName,
                    timestampMillis = System.currentTimeMillis(),
                    hermes = hermesMetadata,
                )
            } else {
                msg
            }
        }
    val resolvedPreview =
        updatedMessages
            .firstOrNull { it.id == placeholderID }
            ?.text
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: thread.preview
    val updated =
        thread.copy(
            messages = updatedMessages,
            preview = resolvedPreview.take(80),
            updatedAtMillis = System.currentTimeMillis(),
        )
    historyStore.upsert(updated)
}

internal fun providerFor(runtime: AssistantRuntimeID): AgentProvider = when (runtime) {
    AssistantRuntimeID.CODEX -> AgentProvider.CODEX
    AssistantRuntimeID.CLAUDE -> AgentProvider.CLAUDE_CODE
    AssistantRuntimeID.OPEN_CLAW -> AgentProvider.OPEN_CLAW
    AssistantRuntimeID.DROID -> AgentProvider.FACTORY
    AssistantRuntimeID.FORGE -> AgentProvider.FORGE_DEV
    AssistantRuntimeID.ANTIGRAVITY -> AgentProvider.ANTIGRAVITY
    AssistantRuntimeID.GROK -> AgentProvider.XAI
    AssistantRuntimeID.CURSOR_AGENT -> AgentProvider.CURSOR
    AssistantRuntimeID.HERMES -> AgentProvider.HERMES
    AssistantRuntimeID.PI -> AgentProvider.HERMES
}

internal fun readyTagline(runtime: AssistantRuntimeID): String = when (runtime) {
    AssistantRuntimeID.CODEX -> "Ask Codex to plan, edit, or run code on your paired Mac."
    AssistantRuntimeID.CLAUDE -> "Claude Code is wired to your Mac. Ask for a refactor, a test, or a review."
    AssistantRuntimeID.OPEN_CLAW -> "OpenClaw runs locally on your paired Mac. Long-form tasks welcome."
    AssistantRuntimeID.DROID -> "Droid is wired to your Mac. Ask it to inspect, plan, or work in your repo."
    AssistantRuntimeID.FORGE -> "Forge is wired to your Mac. Ask it for coding help, review, or implementation plans."
    AssistantRuntimeID.ANTIGRAVITY -> "Antigravity is wired to your Mac. Ask it to inspect, plan, or work in your repo."
    AssistantRuntimeID.GROK -> "Grok is wired to your Mac. Ask it to inspect, explain, or implement in your repo."
    AssistantRuntimeID.CURSOR_AGENT -> "Cursor Agent is wired to your Mac. Ask it to work in the current workspace."
    AssistantRuntimeID.HERMES, AssistantRuntimeID.PI -> "Ready when you are."
}

internal fun quickPromptsFor(runtime: AssistantRuntimeID): List<String> = when (runtime) {
    AssistantRuntimeID.CODEX ->
        listOf(
            "Plan a refactor for…",
            "Write a unit test for…",
            "Explain this stack trace",
            "Generate a Bash one-liner",
        )
    AssistantRuntimeID.CLAUDE ->
        listOf(
            "Review my last commit",
            "Draft a PR description",
            "Find the bug in…",
            "Summarize this file",
        )
    AssistantRuntimeID.OPEN_CLAW ->
        listOf(
            "Sweep this repo for TODOs",
            "Migrate this to Compose",
            "Audit my dependencies",
            "Suggest a release plan",
        )
    AssistantRuntimeID.DROID ->
        listOf(
            "Inspect the current repo",
            "Plan the next implementation",
            "Review failing tests",
            "Explain this error",
        )
    AssistantRuntimeID.FORGE ->
        listOf(
            "Review my last change",
            "Draft an implementation plan",
            "Find risky code paths",
            "Summarize this module",
        )
    AssistantRuntimeID.ANTIGRAVITY ->
        listOf(
            "Inspect the current repo",
            "Plan an implementation",
            "Review this change",
            "Explain this error",
        )
    AssistantRuntimeID.GROK ->
        listOf(
            "Explain this error",
            "Review this change",
            "Plan an implementation",
            "Find risky assumptions",
        )
    AssistantRuntimeID.CURSOR_AGENT ->
        listOf(
            "Open this workspace",
            "Review my last change",
            "Plan the next edit",
            "Find failing tests",
        )
    else -> emptyList()
}

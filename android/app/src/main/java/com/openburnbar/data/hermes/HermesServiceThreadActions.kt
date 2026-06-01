package com.openburnbar.data.hermes

import com.openburnbar.data.assistants.AssistantChatHermesMetadata
import com.openburnbar.data.assistants.AssistantChatMessage
import com.openburnbar.data.assistants.AssistantChatThread
import com.openburnbar.data.assistants.AssistantChatTokenUsage
import com.openburnbar.data.assistants.AssistantChatToolCall
import java.util.UUID

private const val THREAD_TITLE_MAX = 64
private const val THREAD_PREVIEW_MAX = 140

/** Thread history load/save for [HermesService]. */
internal class HermesServiceThreadActions(
    private val service: HermesService,
) {
    fun clearMessages() {
        service.messagesInternal.value = emptyList()
        service.currentThreadIDInternal.value = null
        service.currentConversationIDInternal.value = null
    }

    fun startNewThread() {
        clearMessages()
    }

    fun loadThread(id: String) {
        val cleanId = id.removePrefix("hermes:")
        val store = service.historyStoreInternal ?: return
        val thread = store.thread(cleanId) ?: return
        if (thread.runtime != "hermes") return
        service.currentThreadIDInternal.value = thread.id
        service.messagesInternal.value =
            thread.messages.map { stored ->
                val hermes = stored.hermes
                val usage = hermes?.usage
                HermesMessage(
                    id = stored.id,
                    role = stored.role,
                    content = stored.text,
                    modelName = stored.modelName ?: "hermes",
                    tokensPerSecond =
                    usage?.outputTokens?.let { tokens ->
                        val seconds = usage.providerGenerationDurationSeconds
                        if (seconds != null && seconds > 0) tokens.toDouble() / seconds else null
                    },
                    toolCalls =
                    hermes?.toolCalls.orEmpty().map { tc ->
                        ToolCall(id = tc.id, name = tc.name)
                    },
                    isStreaming = false,
                    timestamp = stored.timestampMillis,
                )
            }
    }

    fun deleteThread(id: String) {
        val cleanId = id.removePrefix("hermes:")
        service.historyStoreInternal?.delete(cleanId)
        if (service.currentThreadIDInternal.value == cleanId) startNewThread()
    }

    fun persistCurrentThread() {
        val store = service.historyStoreInternal ?: return
        val threadID = service.currentThreadIDInternal.value ?: return
        val msgs = service.messagesInternal.value
        if (msgs.isEmpty()) return
        val now = System.currentTimeMillis()
        val existing = store.thread(threadID)
        val createdAt = existing?.createdAtMillis ?: msgs.firstOrNull()?.timestamp ?: now
        val storedMessages =
            msgs.mapNotNull { msg ->
                val trimmed = msg.content.trim()
                if (trimmed.isEmpty() && msg.toolCalls.isEmpty()) return@mapNotNull null
                val toolCalls = msg.toolCalls.map { AssistantChatToolCall(id = it.id, name = it.name, status = "done") }
                val usage =
                    if (msg.tokensPerSecond != null) {
                        AssistantChatTokenUsage(source = "providerUsage")
                    } else {
                        null
                    }
                val hermes =
                    if (toolCalls.isNotEmpty() || usage != null) {
                        AssistantChatHermesMetadata(toolCalls = toolCalls, usage = usage)
                    } else {
                        null
                    }
                AssistantChatMessage(
                    id = msg.id.ifEmpty { UUID.randomUUID().toString() },
                    role = msg.role,
                    text = msg.content,
                    timestampMillis = msg.timestamp,
                    modelName = msg.modelName,
                    isError = msg.isError,
                    attachments = emptyList(),
                    hermes = hermes,
                )
            }
        if (storedMessages.isEmpty()) return

        val firstUser = msgs.firstOrNull { it.role == "user" }?.content?.trim().orEmpty()
        val lastNonEmpty = msgs.lastOrNull { it.content.trim().isNotEmpty() }?.content?.trim().orEmpty()
        val thread =
            AssistantChatThread(
                id = threadID,
                runtime = "hermes",
                title = if (firstUser.isNotEmpty()) firstUser.take(THREAD_TITLE_MAX) else "Hermes conversation",
                preview = lastNonEmpty.take(THREAD_PREVIEW_MAX),
                modelName = service.selectedModelIDInternal.value,
                createdAtMillis = createdAt,
                updatedAtMillis = now,
                messages = storedMessages,
            )
        store.upsert(thread)
    }
}

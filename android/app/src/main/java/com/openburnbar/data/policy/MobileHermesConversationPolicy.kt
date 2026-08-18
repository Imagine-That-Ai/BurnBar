package com.openburnbar.data.policy

enum class MobileHermesStreamTerminal(val wire: String) {
    STREAMING("streaming"),
    STOPPED("stopped"),
    CANCELLED("cancelled"),
    ERROR("error"),
    COMPLETED("completed"),
}

enum class MobileHermesAttachmentDisposition(val wire: String) {
    ACCEPTED("accepted"),
    REJECTED("rejected"),
}

enum class MobileHermesConversationDeepLink(val wire: String) {
    LOADED("loaded"),
    MISSING("missing"),
    INVALID("invalid"),
}

/** Hermes/Pi stream, attachment, and assistant-link decisions. Source: iOS cancelStreaming. */
object MobileHermesConversationPolicy {
    fun terminal(event: String): MobileHermesStreamTerminal = when (event) {
        "stop" -> MobileHermesStreamTerminal.STOPPED
        "cancel" -> MobileHermesStreamTerminal.CANCELLED
        "error" -> MobileHermesStreamTerminal.ERROR
        "complete" -> MobileHermesStreamTerminal.COMPLETED
        else -> MobileHermesStreamTerminal.ERROR
    }

    fun keepsPartial(terminal: MobileHermesStreamTerminal): Boolean = when (terminal) {
        MobileHermesStreamTerminal.STOPPED,
        MobileHermesStreamTerminal.CANCELLED,
        MobileHermesStreamTerminal.COMPLETED,
        MobileHermesStreamTerminal.STREAMING,
        -> true
        MobileHermesStreamTerminal.ERROR -> false
    }

    fun marksError(terminal: MobileHermesStreamTerminal): Boolean = terminal == MobileHermesStreamTerminal.ERROR

    fun shouldDropEmptyAssistant(text: String, toolCallCount: Int, isError: Boolean, terminal: MobileHermesStreamTerminal): Boolean = when (terminal) {
        MobileHermesStreamTerminal.STOPPED,
        MobileHermesStreamTerminal.CANCELLED,
        -> text.trim().isEmpty() && toolCallCount == 0 && !isError
        else -> false
    }

    fun shouldApplyChunk(chunkThreadId: String?, activeThreadId: String?, chunkGeneration: Int, activeGeneration: Int): Boolean {
        if (chunkGeneration != activeGeneration) return false
        val chunk = chunkThreadId?.trim().orEmpty()
        val active = activeThreadId?.trim().orEmpty()
        if (chunk.isEmpty() || active.isEmpty()) return false
        return chunk == active
    }

    fun shouldAppendUserMessage(lastRole: String?, lastText: String?, incomingText: String, reason: String): Boolean {
        val incoming = incomingText.trim()
        if (incoming.isEmpty()) return false
        if (reason == "reconnect" &&
            lastRole == "user" &&
            lastText?.trim() == incoming
        ) {
            return false
        }
        return true
    }

    fun shouldRenderToolCalls(toolCallCount: Int, terminal: MobileHermesStreamTerminal): Boolean =
        toolCallCount > 0 && terminal != MobileHermesStreamTerminal.ERROR

    fun attachmentDisposition(id: String, mimeType: String, byteSize: Int, path: String): MobileHermesAttachmentDisposition {
        if (id.trim().isEmpty() || mimeType.trim().isEmpty() || path.trim().isEmpty() || byteSize < 0) {
            return MobileHermesAttachmentDisposition.REJECTED
        }
        return MobileHermesAttachmentDisposition.ACCEPTED
    }

    fun conversationDeepLink(threadId: String, exists: Boolean): MobileHermesConversationDeepLink {
        if (threadId.trim().isEmpty()) return MobileHermesConversationDeepLink.INVALID
        return if (exists) MobileHermesConversationDeepLink.LOADED else MobileHermesConversationDeepLink.MISSING
    }

    fun missingConversationMessage(outcome: MobileHermesConversationDeepLink): String? = when (outcome) {
        MobileHermesConversationDeepLink.LOADED -> null
        MobileHermesConversationDeepLink.MISSING -> "This conversation is no longer on this device."
        MobileHermesConversationDeepLink.INVALID -> "This conversation link is invalid."
    }
}

import Foundation

/// User-visible stream terminal. Cancel/stop are not errors.
public enum MobileHermesStreamTerminal: String, Sendable, Equatable {
    case streaming
    case stopped
    case cancelled
    case error
    case completed
}

public enum MobileHermesAttachmentDisposition: String, Sendable, Equatable {
    case accepted
    case rejected
}

public enum MobileHermesConversationDeepLink: String, Sendable, Equatable {
    case loaded
    case missing
    case invalid
}

/// Hermes/Pi stream, attachment, and assistant-link decisions.
/// Source: iOS `PiService.cancelStreaming` / `HermesService.cancelGeneration`.
public enum MobileHermesConversationPolicy {
    public static func terminal(forEvent event: String) -> MobileHermesStreamTerminal {
        switch event {
        case "stop":
            return .stopped
        case "cancel":
            return .cancelled
        case "error":
            return .error
        case "complete":
            return .completed
        default:
            return .error
        }
    }

    public static func keepsPartial(_ terminal: MobileHermesStreamTerminal) -> Bool {
        switch terminal {
        case .stopped, .cancelled, .completed, .streaming:
            return true
        case .error:
            return false
        }
    }

    public static func marksError(_ terminal: MobileHermesStreamTerminal) -> Bool {
        terminal == .error
    }

    /// Empty assistant placeholders are dropped on stop/cancel so the chat
    /// does not keep a blank bubble. Tool-call turns are kept.
    public static func shouldDropEmptyAssistant(
        text: String,
        toolCallCount: Int,
        isError: Bool,
        terminal: MobileHermesStreamTerminal
    ) -> Bool {
        switch terminal {
        case .stopped, .cancelled:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && toolCallCount == 0
                && !isError
        case .error, .completed, .streaming:
            return false
        }
    }

    /// A late chunk for thread A must not apply to thread B.
    public static func shouldApplyChunk(
        chunkThreadId: String?,
        activeThreadId: String?,
        chunkGeneration: Int,
        activeGeneration: Int
    ) -> Bool {
        guard chunkGeneration == activeGeneration else { return false }
        let chunk = chunkThreadId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let active = activeThreadId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if chunk.isEmpty || active.isEmpty { return false }
        return chunk == active
    }

    /// Reconnect of an in-flight turn must not duplicate the user row.
    public static func shouldAppendUserMessage(
        lastRole: String?,
        lastText: String?,
        incomingText: String,
        reason: String,
        hasAttachments: Bool = false
    ) -> Bool {
        let incoming = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if incoming.isEmpty && !hasAttachments { return false }
        if reason == "reconnect",
           lastRole == "user",
           (lastText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == incoming {
            return false
        }
        return true
    }

    public static func shouldRenderToolCalls(
        toolCallCount: Int,
        terminal: MobileHermesStreamTerminal
    ) -> Bool {
        toolCallCount > 0 && terminal != .error
    }

    public static func attachmentDisposition(
        id: String,
        mimeType: String,
        byteSize: Int,
        path: String
    ) -> MobileHermesAttachmentDisposition {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let mime = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanId.isEmpty || mime.isEmpty || location.isEmpty || byteSize < 0 {
            return .rejected
        }
        return .accepted
    }

    public static func conversationDeepLink(
        threadId: String,
        exists: Bool
    ) -> MobileHermesConversationDeepLink {
        if threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .invalid
        }
        return exists ? .loaded : .missing
    }

    public static func missingConversationMessage(
        _ outcome: MobileHermesConversationDeepLink
    ) -> String? {
        switch outcome {
        case .loaded:
            return nil
        case .missing:
            return "This conversation is no longer on this device."
        case .invalid:
            return "This conversation link is invalid."
        }
    }
}

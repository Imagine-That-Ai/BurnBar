import Foundation
import OpenBurnBarCore

/// Per-surface Hermes conversation state: the visible transcript, the
/// active session id, streaming/error flags, the per-conversation token
/// burn counter, the visible-CLI status strip, and the bridge that
/// persists the running thread into `MobileChatHistoryStore`.
///
/// Deliberately NOT shared across surfaces — each `HermesService` instance
/// owns exactly one store so two chat surfaces never share a transcript
/// (the runtime *catalog* is what's shared, via `HermesRuntimeStore`). The
/// service exposes computed proxies (`messages`, `selectedSessionID`, …)
/// so views, tests, and the rest of the service keep their existing API,
/// and @Observable tracking flows through to this store's stored
/// properties — the same pattern as the runtime catalog proxies on
/// `HermesService`.
///
/// Bodies moved verbatim from `HermesService`. Two coordinator effects are
/// injected at init instead of reaching back into the service:
/// - `activeModelName`: resolves the model name stamped onto persisted
///   threads (`activeModelName ?? selectedModelID` on the owning service).
/// - `cancelActiveStream`: cancels the service's in-flight stream task
///   (`currentTask?.cancel(); currentTask = nil`) when a stored thread is
///   restored over the live transcript.
@Observable
@MainActor
final class HermesConversationStateStore {
    var messages: [HermesChatMessage] = []
    var selectedSessionID: String?
    var currentConversationTokenBurn = 0
    var isStreaming = false
    var lastError: String?
    var visibleCLIStatusText: String?
    var visibleCLIErrorText: String?

    private let history: MobileChatHistoryStore
    private let activeModelName: () -> String?
    private let cancelActiveStream: () -> Void

    init(
        history: MobileChatHistoryStore,
        activeModelName: @escaping () -> String?,
        cancelActiveStream: @escaping () -> Void
    ) {
        self.history = history
        self.activeModelName = activeModelName
        self.cancelActiveStream = cancelActiveStream
    }

    // MARK: - Mobile chat history bridge

    /// Restores a chat thread previously saved by the mobile history store.
    /// Used when the user taps an on-device row in the conversation list.
    func loadMobileThread(id: String) {
        guard let thread = history.thread(id: id),
              thread.runtime == AssistantRuntimeID.hermes.rawValue else { return }
        cancelActiveStream()
        isStreaming = false
        lastError = nil
        selectedSessionID = thread.id
        messages = thread.messages.map { Self.convertFromStore($0) }
    }

    func persistCurrentThread() {
        guard let id = selectedSessionID, !messages.isEmpty else { return }
        let now = Date()
        let createdAt = history.thread(id: id)?.createdAt ?? messages.first?.timestamp ?? now
        let title = Self.derivedTitle(from: messages)
        let preview = Self.derivedPreview(from: messages)
        let storedMessages = messages.compactMap(Self.convertToStore)
        guard !storedMessages.isEmpty else { return }
        let thread = MobileChatThread(
            id: id,
            runtime: AssistantRuntimeID.hermes.rawValue,
            title: title,
            preview: preview,
            modelName: activeModelName(),
            createdAt: createdAt,
            updatedAt: now,
            messages: storedMessages
        )
        history.upsert(thread)
    }

    // MARK: - Store conversion

    static func convertToStore(_ message: HermesChatMessage) -> MobileChatMessage? {
        // Skip streaming-only placeholders that have no content yet AND no
        // attachments — attachment-only sends are intentional and must persist.
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !message.toolCalls.isEmpty || !message.attachments.isEmpty else { return nil }
        // Tool reply messages are ephemeral context — they exist only to
        // bridge a single assistant tool-call turn to its follow-up
        // natural-language turn. Once the conversation is reloaded the
        // user expects to start a new prompt, so persisting tool
        // results would only clutter the visible transcript.
        if message.role == .tool { return nil }
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        case .tool: return nil
        }
        let storedAttachments = message.attachments.map { attachment in
            MobileChatAttachment(
                id: attachment.id,
                kind: attachment.kind.rawValue,
                displayName: attachment.displayName,
                mimeType: attachment.mimeType,
                byteSize: attachment.byteSize,
                workspaceRelativePath: attachment.workspaceRelativePath,
                thumbnailPNG: attachment.thumbnailPNG,
                extractedTextPreview: attachment.extractedTextPreview
            )
        }
        let storedToolCalls = message.toolCalls.map {
            MobileChatToolCall(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                detail: $0.detail
            )
        }
        let usage: MobileChatTokenUsage? = {
            let hasUsageSignal = message.outputTokenCount != nil
                || message.totalTokenCount != nil
                || message.providerGenerationDurationSeconds != nil
                || message.providerTotalDurationSeconds != nil
                || message.responseStartedAt != nil
                || message.firstResponseChunkAt != nil
                || message.responseCompletedAt != nil
            guard hasUsageSignal else { return nil }
            return MobileChatTokenUsage(
                outputTokens: message.outputTokenCount,
                totalTokens: message.totalTokenCount,
                source: message.tokenCountSource?.rawValue,
                providerGenerationDurationSeconds: message.providerGenerationDurationSeconds,
                providerTotalDurationSeconds: message.providerTotalDurationSeconds,
                responseStartedAt: message.responseStartedAt,
                firstResponseChunkAt: message.firstResponseChunkAt,
                responseCompletedAt: message.responseCompletedAt
            )
        }()
        let hasHermesMetadata = message.requestedModelID != nil
            || message.responseModelID != nil
            || !storedToolCalls.isEmpty
            || usage != nil
        let metadata = hasHermesMetadata ? MobileChatHermesMetadata(
            requestedModelID: message.requestedModelID,
            responseModelID: message.responseModelID,
            toolCalls: storedToolCalls,
            usage: usage
        ) : nil
        return MobileChatMessage(
            id: message.id,
            role: role,
            text: message.text,
            timestamp: message.timestamp,
            modelName: message.modelName,
            isError: message.isError,
            attachments: storedAttachments,
            toolCalls: storedToolCalls,
            hermes: metadata
        )
    }

    static func convertFromStore(_ message: MobileChatMessage) -> HermesChatMessage {
        let role: HermesChatRole
        switch message.role {
        case "user": role = .user
        case "system": role = .system
        case "tool": role = .tool
        default: role = .assistant
        }
        let restoredAttachments: [HermesAttachment] = message.attachments.compactMap { stored in
            guard let kind = HermesAttachmentKind(rawValue: stored.kind) else { return nil }
            return HermesAttachment(
                id: stored.id,
                kind: kind,
                displayName: stored.displayName,
                mimeType: stored.mimeType,
                byteSize: stored.byteSize,
                workspaceRelativePath: stored.workspaceRelativePath,
                thumbnailPNG: stored.thumbnailPNG,
                extractedTextPreview: stored.extractedTextPreview
            )
        }
        // Prefer the top-level toolCalls list; fall back to the legacy
        // hermes.toolCalls block for threads written by older builds.
        let storedToolCalls = message.toolCalls.isEmpty
            ? (message.hermes?.toolCalls ?? [])
            : message.toolCalls
        let restoredToolCalls = storedToolCalls.map {
            HermesToolCall(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                arguments: "",
                detail: $0.detail
            )
        }
        let usage = message.hermes?.usage
        return HermesChatMessage(
            id: message.id,
            role: role,
            text: message.text,
            toolCalls: restoredToolCalls,
            attachments: restoredAttachments,
            requestedModelID: message.hermes?.requestedModelID,
            responseModelID: message.hermes?.responseModelID,
            modelName: message.modelName,
            timestamp: message.timestamp,
            isStreaming: false,
            isError: message.isError,
            responseStartedAt: usage?.responseStartedAt,
            firstResponseChunkAt: usage?.firstResponseChunkAt,
            responseCompletedAt: usage?.responseCompletedAt,
            outputTokenCount: usage?.outputTokens,
            totalTokenCount: usage?.totalTokens,
            tokenCountSource: usage?.source.flatMap { HermesTokenCountSource(rawValue: $0) },
            providerGenerationDurationSeconds: usage?.providerGenerationDurationSeconds,
            providerTotalDurationSeconds: usage?.providerTotalDurationSeconds
        )
    }

    static func derivedTitle(from messages: [HermesChatMessage]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            return String(firstUser.prefix(64))
        }
        return "Hermes conversation"
    }

    static func derivedPreview(from messages: [HermesChatMessage]) -> String {
        if let last = messages.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .text.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            // Thread-list rows are plain text — flatten assistant markdown
            // so previews never show raw `**` / `#` markers.
            let plain = HermesAtomParser.plainText(last)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(plain.prefix(140))
        }
        return ""
    }
}

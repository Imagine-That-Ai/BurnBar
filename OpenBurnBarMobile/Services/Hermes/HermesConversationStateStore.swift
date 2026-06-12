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
    /// Raw model id the coordinator would stamp on a new request
    /// (`activeRequestedModelID` on the owning service). Injected so the
    /// gateway/CLI turn constructors record the same honest "what we asked
    /// for" id the streaming path records.
    private let activeRequestedModelID: () -> String?
    private let cancelActiveStream: () -> Void
    /// Live observation of a visible Mac Terminal (CLI) mission feeding
    /// this transcript. Owned here because every callback it fires mutates
    /// conversation state.
    private var visibleCLIObservation: CLIAgentMissionObservation?

    init(
        history: MobileChatHistoryStore,
        activeModelName: @escaping () -> String?,
        activeRequestedModelID: @escaping () -> String? = { nil },
        cancelActiveStream: @escaping () -> Void
    ) {
        self.history = history
        self.activeModelName = activeModelName
        self.activeRequestedModelID = activeRequestedModelID
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

    // MARK: - BurnBar Cloud Gateway turns
    //
    // Bodies moved verbatim from `HermesService` — these are pure
    // per-thread transcript mutations (placeholder lifecycle + history
    // persistence) for the sealed BurnBar Cloud Gateway path. The service
    // keeps thin pass-throughs so views and tests keep their existing API.

    func ensureBurnBarGatewayThreadID() -> String {
        if selectedSessionID == nil {
            selectedSessionID = UUID().uuidString
        }
        return selectedSessionID ?? UUID().uuidString
    }

    func beginBurnBarGatewayTurn(displayText: String, wireText: String) -> String {
        let trimmedDisplay = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWire = wireText.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedSessionID == nil {
            selectedSessionID = UUID().uuidString
        }
        let now = Date()
        let userMessage = HermesChatMessage(
            role: .user,
            text: trimmedDisplay.isEmpty ? trimmedWire : trimmedDisplay,
            requestedModelID: activeRequestedModelID(),
            modelName: activeModelName(),
            timestamp: now
        )
        let placeholder = HermesChatMessage(
            role: .assistant,
            text: "Sent through BurnBar Cloud Gateway. Waiting for Hermes...",
            requestedModelID: activeRequestedModelID(),
            modelName: activeModelName(),
            timestamp: now.addingTimeInterval(0.001),
            isStreaming: true,
            responseStartedAt: now
        )
        messages.append(userMessage)
        messages.append(placeholder)
        isStreaming = true
        lastError = nil
        persistCurrentThread()
        return placeholder.id
    }

    func finishBurnBarGatewayTurn(placeholderID: String, reply: HermesGatewayMessageRecord) {
        // Render the OPENED reply body, not the legacy plaintext `text` field
        // (which is always nil on sealed schema≥2 docs). `chatRenderText` is the
        // single source of truth: it returns the decrypted body, the legacy
        // plaintext, an attachment summary, or — when this device cannot open a
        // reply sealed for another paired device — a calm, jargon-free re-pair
        // state instead of a blank/"no text" bubble.
        let finalText = reply.chatRenderText(emptyFallback: "Hermes replied without text.")
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].text = finalText
            messages[index].attachments = reply.openedAttachments
            messages[index].isStreaming = false
            messages[index].isError = false
            messages[index].responseModelID = activeRequestedModelID()
            messages[index].modelName = activeModelName()
            messages[index].responseCompletedAt = Date()
            messages[index].finalizeResponseMetrics()
        } else {
            messages.append(HermesChatMessage(
                role: .assistant,
                text: finalText,
                attachments: reply.openedAttachments,
                requestedModelID: activeRequestedModelID(),
                responseModelID: activeRequestedModelID(),
                modelName: activeModelName(),
                responseStartedAt: Date(),
                responseCompletedAt: Date()
            ))
        }
        isStreaming = false
        lastError = nil
        persistCurrentThread()
    }

    func recordBurnBarGatewayReply(
        _ reply: HermesGatewayMessageRecord,
        threadID explicitThreadID: String = HermesGatewayMessageResolver.defaultThreadID,
        modelID: String? = nil,
        modelName: String? = nil
    ) {
        let threadID = reply.threadId?.nilIfBlank ?? explicitThreadID
        let finalText = reply.chatRenderText(emptyFallback: "Hermes sent a reply through BurnBar Cloud.")
        let timestamp = Self.gatewayReplyDate(from: reply.createdAt) ?? Date()
        let resolvedModelName = modelName?.nilIfBlank ?? modelID?.nilIfBlank
        let message = HermesChatMessage(
            id: reply.id,
            role: .assistant,
            text: finalText,
            attachments: reply.openedAttachments,
            requestedModelID: modelID?.nilIfBlank,
            responseModelID: modelID?.nilIfBlank,
            modelName: resolvedModelName,
            timestamp: timestamp,
            responseStartedAt: timestamp,
            responseCompletedAt: timestamp
        )
        guard let storedMessage = Self.convertToStore(message) else { return }

        let existing = history.thread(id: threadID)
        var messages = existing?.messages ?? []
        if let index = messages.firstIndex(where: { $0.id == storedMessage.id }) {
            messages[index] = storedMessage
        } else {
            messages.append(storedMessage)
        }
        var thread = MobileChatThread(
            id: threadID,
            runtime: AssistantRuntimeID.hermes.rawValue,
            title: existing?.title.nilIfBlank ?? "Hermes Gateway",
            // Previews are plain-text chrome — keep the stored thread row
            // markdown-free (the message itself keeps `finalText` verbatim).
            preview: String(
                HermesAtomParser.plainText(finalText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(140)
            ),
            modelName: resolvedModelName ?? existing?.modelName,
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: Date(),
            messages: messages
        )
        thread.customTitle = existing?.customTitle
        thread.labelColorHex = existing?.labelColorHex
        thread.isPinned = existing?.isPinned
        thread.priorityOrder = existing?.priorityOrder
        history.upsert(thread)
        if selectedSessionID == threadID {
            loadMobileThread(id: threadID)
        }
    }

    func failBurnBarGatewayTurn(placeholderID: String?, message: String) {
        let now = Date()
        let errorMessage = HermesChatMessage(
            role: .assistant,
            text: message,
            requestedModelID: activeRequestedModelID(),
            modelName: activeModelName(),
            timestamp: now,
            isStreaming: false,
            isError: true,
            responseStartedAt: now,
            responseCompletedAt: now
        )
        if let placeholderID,
           let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index] = errorMessage
        } else {
            messages.append(errorMessage)
        }
        isStreaming = false
        lastError = message
        persistCurrentThread()
    }

    private static func gatewayReplyDate(from raw: String?) -> Date? {
        guard let raw = raw?.nilIfBlank else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - Visible Mac Terminal (CLI) turns
    //
    // Bodies moved verbatim from `HermesService`. The service keeps the
    // send entry point (`sendVisibleCLIMessage`) because relay preference
    // and the cancellable `currentTask` live there; everything that
    // mutates the transcript or the visible-CLI status strip lives here.

    func cancelVisibleCLIObservation() {
        visibleCLIObservation?.cancel()
        visibleCLIObservation = nil
    }

    /// Stages the user turn + streaming assistant placeholder for a
    /// visible-CLI send and returns the placeholder id. Extracted verbatim
    /// from the middle of `HermesService.sendVisibleCLIMessage`.
    func beginVisibleCLITurn(userText trimmed: String) -> String {
        visibleCLIObservation?.cancel()
        visibleCLIObservation = nil
        visibleCLIStatusText = "Opening Hermes Terminal..."
        visibleCLIErrorText = nil

        let now = Date()
        let userMessage = HermesChatMessage(
            role: .user,
            text: trimmed,
            requestedModelID: activeRequestedModelID(),
            modelName: activeModelName(),
            timestamp: now
        )
        let assistantPlaceholder = HermesChatMessage(
            role: .assistant,
            text: "Opening Hermes in a visible Mac Terminal session...",
            requestedModelID: activeRequestedModelID(),
            modelName: activeModelName(),
            timestamp: now.addingTimeInterval(0.001),
            isStreaming: true,
            responseStartedAt: now
        )
        messages.append(userMessage)
        messages.append(assistantPlaceholder)
        isStreaming = true
        lastError = nil
        persistCurrentThread()
        return assistantPlaceholder.id
    }

    /// Dispatches the visible-CLI mission and wires its observation back
    /// into this transcript. Runs inside the service's `currentTask` so
    /// cancellation keeps its existing semantics.
    func dispatchVisibleCLIMission(prompt: String, threadID: String, placeholderID: String) async {
        do {
            let requestID = try await CLIAgentMissionDispatcher.shared.dispatch(
                title: Self.derivedTitle(from: messages),
                prompt: prompt,
                missionKind: "chat",
                requestedRuntime: AssistantRuntimeID.hermes.rawValue,
                depth: "standard",
                approvalMode: "existing_policy",
                commandsAllowed: false,
                fileEditsAllowed: false,
                clientThreadID: threadID,
                sourceSurface: "ios-chat-cli",
                deliveryMode: .fullStream,
                parentHermesThreadID: threadID,
                presentationMode: .macVisibleCLI
            )
            try Task.checkCancellation()
            visibleCLIObservation = try CLIAgentMissionDispatcher.shared.observe(
                requestID: requestID,
                onUpdate: { [weak self] snapshot in
                    self?.applyVisibleCLISnapshot(snapshot, placeholderID: placeholderID)
                },
                onError: { [weak self] message in
                    self?.finishVisibleCLIPlaceholder(
                        placeholderID,
                        text: "Could not watch Hermes Terminal output: \(message)",
                        isError: true
                    )
                }
            )
        } catch {
            guard !Task.isCancelled else { return }
            finishVisibleCLIPlaceholder(
                placeholderID,
                text: "Could not open Hermes in Terminal on your Mac: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    func rejectVisibleCLIAttachmentTurn(text: String, attachments: [HermesAttachment]) {
        let now = Date()
        let displayText = text.isEmpty ? "Sent \(attachments.count) attachment\(attachments.count == 1 ? "" : "s")" : text
        let message = "CLI mode cannot send attachments to a visible Mac Terminal session yet. Remove the attachment or switch back to Smart view for this turn."
        messages.append(HermesChatMessage(
            role: .user,
            text: displayText,
            attachments: attachments,
            requestedModelID: activeRequestedModelID(),
            modelName: activeModelName(),
            timestamp: now
        ))
        messages.append(HermesChatMessage(
            role: .assistant,
            text: message,
            requestedModelID: activeRequestedModelID(),
            modelName: activeModelName(),
            timestamp: now.addingTimeInterval(0.001),
            isError: true,
            responseStartedAt: now,
            responseCompletedAt: now
        ))
        isStreaming = false
        lastError = message
        visibleCLIStatusText = nil
        visibleCLIErrorText = message
        persistCurrentThread()
    }

    static func visibleCLIPrompt(userText: String, context: String?) -> String {
        let trimmedContext = trimmedNilIfEmpty(context)
        guard let trimmedContext else { return userText }
        return """
        \(trimmedContext)

        User message:
        \(userText)
        """
    }

    private func applyVisibleCLISnapshot(_ snapshot: CLIAgentMissionSnapshot, placeholderID: String) {
        let text = Self.visibleCLIResponseText(from: snapshot)
            ?? snapshot.displayLiveSummary
            ?? snapshot.currentStepLabel
        let isError = snapshot.status.lowercased().contains("fail")
            || snapshot.status.lowercased() == "unauthorized"
            || snapshot.events.last?.isError == true
        guard let index = messages.firstIndex(where: { $0.id == placeholderID }) else { return }
        messages[index].text = text
        messages[index].isStreaming = !snapshot.isTerminal
        messages[index].isError = isError
        messages[index].responseModelID = snapshot.selectedModelID
        messages[index].modelName = snapshot.selectedModelID ?? activeModelName()
        if snapshot.isTerminal {
            messages[index].finalizeResponseMetrics()
            isStreaming = false
            visibleCLIObservation?.cancel()
            visibleCLIObservation = nil
            if isError {
                lastError = text
                visibleCLIErrorText = text
                visibleCLIStatusText = nil
            } else {
                visibleCLIErrorText = nil
                visibleCLIStatusText = nil
            }
        } else if isError {
            visibleCLIErrorText = text
            visibleCLIStatusText = nil
        } else {
            visibleCLIErrorText = nil
            visibleCLIStatusText = Self.trimmedNilIfEmpty(snapshot.displayLiveSummary)
                ?? Self.trimmedNilIfEmpty(snapshot.currentStepLabel)
                ?? "Hermes Terminal running..."
        }
        persistCurrentThread()
    }

    private static func visibleCLIResponseText(from snapshot: CLIAgentMissionSnapshot) -> String? {
        if snapshot.isTerminal,
           let error = trimmedNilIfEmpty(snapshot.errorMessage) {
            return error
        }
        let responsePhases: Set<String> = [
            "assistant_response",
            "completed",
            "final_answer"
        ]
        let responseKinds: Set<String> = [
            "llm_response",
            "final_answer"
        ]
        return snapshot.events.reversed().compactMap { event in
            guard responsePhases.contains(event.phase) || responseKinds.contains(event.kind) else {
                return nil
            }
            return trimmedNilIfEmpty(event.fullMessage)
                ?? trimmedNilIfEmpty(event.message)
        }.first
    }

    private static func trimmedNilIfEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func finishVisibleCLIPlaceholder(_ placeholderID: String, text: String, isError: Bool) {
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].text = text
            messages[index].isStreaming = false
            messages[index].isError = isError
            messages[index].finalizeResponseMetrics()
        }
        isStreaming = false
        if isError {
            lastError = text
            visibleCLIErrorText = text
            visibleCLIStatusText = nil
        } else {
            visibleCLIErrorText = nil
            visibleCLIStatusText = nil
        }
        visibleCLIObservation?.cancel()
        visibleCLIObservation = nil
        persistCurrentThread()
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

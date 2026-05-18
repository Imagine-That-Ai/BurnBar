import Foundation
import OpenBurnBarCore

typealias CLIAgentRelayChatDispatcher = @Sendable (
    _ request: CLIAgentRelayChatRequest,
    _ eventSender: @escaping @Sendable (CLIAgentRelayChatEvent) async throws -> Void
) async throws -> Void

actor CLIAgentRelayChunkSequencer {
    private var value = 0

    func next() -> Int {
        defer { value += 1 }
        return value
    }

    func count() -> Int {
        value
    }
}

@MainActor
protocol CLIAgentRelayChatExecuting: AnyObject {
    func streamChat(
        request: CLIAgentRelayChatRequest,
        onEvent: @escaping @Sendable (CLIAgentRelayChatEvent) async throws -> Void
    ) async throws
}

@MainActor
final class ChatSessionControllerCLIAgentRelayChatExecutor: CLIAgentRelayChatExecuting {
    private let chatController: ChatSessionController

    init(chatController: ChatSessionController) {
        self.chatController = chatController
    }

    func streamChat(
        request: CLIAgentRelayChatRequest,
        onEvent: @escaping @Sendable (CLIAgentRelayChatEvent) async throws -> Void
    ) async throws {
        guard !chatController.isStreaming else {
            throw CLIAgentRelayChatExecutorError.busy
        }
        guard let backend = Self.backend(for: request.runtime) else {
            throw CLIAgentRelayChatExecutorError.unsupportedRuntime(request.runtime)
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw CLIAgentRelayChatExecutorError.emptyPrompt
        }

        chatController.setChatBackend(backend)
        if let modelID = request.modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelID.isEmpty {
            chatController.setChatModelSelection(modelID, for: backend)
        }
        chatController.openOrCreateChatThread(id: request.clientThreadID)

        let knownMessageIDs = Set(chatController.messages.map(\.id))
        chatController.inputText = prompt
        await chatController.send()

        var lastSignature = ""
        var emittedAnyAssistantEvent = false

        func latestAssistantMessage() -> ChatMessageRecord? {
            if let streamingID = chatController.activeStreamMessageId,
               let streamingMessage = chatController.messages.first(where: { $0.id == streamingID }) {
                return streamingMessage
            }
            return chatController.messages.last {
                $0.role == .assistant && !knownMessageIDs.contains($0.id)
            } ?? chatController.messages.last(where: { $0.role == .assistant })
        }

        func event(from message: ChatMessageRecord, kind: CLIAgentRelayChatEventKind) -> CLIAgentRelayChatEvent {
            CLIAgentRelayChatEvent(
                kind: kind,
                text: ChatMessageRecord.joinedText(from: message.displayTranscript).nonEmpty ?? message.content,
                modelID: request.modelID?.nonEmpty ?? backend.rawValue,
                transcriptPieces: message.displayTranscript.map(Self.relayPiece(from:)),
                errorMessage: kind == .failed ? chatController.streamError : nil
            )
        }

        func emitIfChanged(kind: CLIAgentRelayChatEventKind) async throws {
            guard let assistant = latestAssistantMessage() else { return }
            let signature = Self.signature(for: assistant, error: chatController.streamError, kind: kind)
            guard kind.isTerminal || signature != lastSignature else { return }
            lastSignature = signature
            emittedAnyAssistantEvent = true
            try await onEvent(event(from: assistant, kind: kind))
        }

        while chatController.isStreaming {
            try Task.checkCancellation()
            try await emitIfChanged(kind: .assistantSnapshot)
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if let streamError = chatController.streamError?.nonEmpty {
            if let assistant = latestAssistantMessage() {
                try await onEvent(event(from: assistant, kind: .failed))
            } else {
                try await onEvent(CLIAgentRelayChatEvent(
                    kind: .failed,
                    text: "Error: \(streamError)",
                    modelID: request.modelID?.nonEmpty ?? backend.rawValue,
                    errorMessage: streamError
                ))
            }
            return
        }

        if let assistant = latestAssistantMessage() {
            try await onEvent(event(from: assistant, kind: .completed))
            return
        }

        if !emittedAnyAssistantEvent {
            throw CLIAgentRelayChatExecutorError.emptyResponse
        }
    }

    static func backend(for runtime: String) -> ChatBackendID? {
        switch runtime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex":
            return .codex
        case "claude", "claudecode", "claude-code":
            return .claude
        default:
            return nil
        }
    }

    private static func relayPiece(from piece: ChatTranscriptPiece) -> CLIAgentRelayTranscriptPiece {
        let kind: CLIAgentRelayTranscriptPieceKind
        switch piece.kind {
        case .text:
            kind = .text
        case .toolUse:
            kind = .toolUse
        case .toolResult:
            kind = .toolResult
        }
        return CLIAgentRelayTranscriptPiece(
            id: piece.id,
            kind: kind,
            value: piece.value,
            detail: piece.detail
        )
    }

    private static func signature(
        for message: ChatMessageRecord,
        error: String?,
        kind: CLIAgentRelayChatEventKind
    ) -> String {
        let pieceSignature = message.displayTranscript
            .map { "\($0.id)|\($0.kind.rawValue)|\($0.value.count)|\($0.detail?.count ?? 0)" }
            .joined(separator: ",")
        return "\(kind.rawValue)|\(message.id)|\(message.content.count)|\(pieceSignature)|\(error ?? "")"
    }
}

private enum CLIAgentRelayChatExecutorError: LocalizedError {
    case busy
    case emptyPrompt
    case emptyResponse
    case unsupportedRuntime(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Codex or Claude is already responding on this Mac. Wait for the current reply to finish, then send again."
        case .emptyPrompt:
            return "Cannot send an empty Codex or Claude message."
        case .emptyResponse:
            return "Codex or Claude finished without returning a visible reply."
        case .unsupportedRuntime(let runtime):
            return "This relay only supports Codex and Claude chat, not '\(runtime)'."
        }
    }
}

private extension CLIAgentRelayChatEventKind {
    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

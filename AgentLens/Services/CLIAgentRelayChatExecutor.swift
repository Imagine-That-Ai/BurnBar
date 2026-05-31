import Foundation
import OpenBurnBarCore

typealias CLIAgentRelayChatDispatcher = @Sendable (
    _ request: CLIAgentRelayChatRequest,
    _ eventSender: @escaping @Sendable (CLIAgentRelayChatEvent) async throws -> Void
) async throws -> Void

typealias CLIRuntimeModelCatalogDispatcher = @Sendable (
    _ request: CLIRuntimeModelCatalogRequest
) async throws -> CLIRuntimeModelCatalogResponse

typealias CLIAgentSessionActionDispatcher = @MainActor @Sendable (
    _ request: CLIAgentSessionActionRequest
) async throws -> CLIAgentSessionActionResponse

@MainActor
struct CLIAgentSessionActionDaemonDispatcher {
    private let daemonManager: OpenBurnBarDaemonManager

    init(daemonManager: OpenBurnBarDaemonManager = .shared) {
        self.daemonManager = daemonManager
    }

    func perform(_ request: CLIAgentSessionActionRequest) async throws -> CLIAgentSessionActionResponse {
        let mode: BurnBarResumeMode
        switch request.action {
        case .packageOnly:
            mode = .open
        case .resume, .handoff:
            mode = .spawn
        }
        let response = try await daemonManager.runResume(
            sessionID: request.sessionID,
            targetHarness: request.targetRuntime,
            targetModel: request.targetModelID,
            mode: mode
        )
        let status: CLIAgentSessionActionStatus
        switch response.kind {
        case "native":
            status = .nativeResume
        case "spawned":
            if response.argv != nil {
                status = .nativeResume
            } else if response.targetArgv != nil {
                status = .handoff
            } else {
                status = .spawned
            }
        case "ported":
            status = request.action == .packageOnly ? .packageOnly : .handoff
        case "error":
            status = .error
        default:
            status = .handoff
        }
        return CLIAgentSessionActionResponse(
            status: status,
            targetRuntime: response.targetHarness,
            argv: response.argv ?? response.targetArgv ?? [],
            briefingPath: response.briefingPath,
            workingDirectory: response.workingDirectory,
            pid: response.pid,
            cleanupAfterSeconds: response.cleanupAfterSeconds,
            note: response.note,
            errorCode: response.errorCode,
            errorRecovery: response.errorRecovery
        )
    }
}

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

struct CLIRuntimeModelCatalogDiscovery: Sendable {
    private let resolver: CLIExecutableResolver

    init(resolver: CLIExecutableResolver = CLIExecutableResolver()) {
        self.resolver = resolver
    }

    func modelCatalog(for request: CLIRuntimeModelCatalogRequest) async throws -> CLIRuntimeModelCatalogResponse {
        guard let runtime = AssistantRuntimeID(rawValue: request.runtime) else {
            throw CLIRuntimeModelCatalogDiscoveryError.unsupportedRuntime(request.runtime)
        }
        let options: [CLIRuntimeModelOption]
        switch runtime {
        case .codex:
            let executable = try await executable(named: "codex")
            if let output = try? await run(executable: executable, arguments: ["debug", "models"], timeoutSeconds: 12),
               let data = output.data(using: .utf8) {
                let discovered = CLIRuntimeModelCatalog.parseCodexDebugModels(data)
                options = discovered.isEmpty ? try Self.defaultProfileRows(for: runtime) : discovered
            } else {
                options = try Self.defaultProfileRows(for: runtime)
            }
        case .claude:
            _ = try await executable(named: "claude")
            options = try Self.defaultProfileRows(for: runtime)
        case .droid:
            let executable = try await executable(named: "droid")
            let output = try await run(executable: executable, arguments: ["exec", "--help"], timeoutSeconds: 12)
            options = CLIRuntimeModelCatalog.parseDroidExecHelp(output)
            if options.isEmpty {
                throw CLIRuntimeModelCatalogDiscoveryError.emptyCatalog(runtime.displayName)
            }
        case .forge:
            let executable = try await executable(named: "forge")
            let output = try await run(executable: executable, arguments: ["agent", "list"], timeoutSeconds: 12)
            options = CLIRuntimeModelCatalog.parseForgeAgentList(output)
            if options.isEmpty {
                throw CLIRuntimeModelCatalogDiscoveryError.emptyCatalog(runtime.displayName)
            }
        case .antigravity:
            _ = try await executable(named: "agy")
            options = [Self.antigravityProfileRow()]
        case .grok:
            let executable = try await executable(named: "grok")
            if let output = try? await run(executable: executable, arguments: ["models"], timeoutSeconds: 12) {
                let discovered = CLIRuntimeModelCatalog.parseGrokModels(output)
                options = discovered.isEmpty ? try Self.defaultProfileRows(for: runtime) : discovered
            } else {
                options = try Self.defaultProfileRows(for: runtime)
            }
        case .cursorAgent:
            _ = try await executable(named: "cursor-agent")
            options = try Self.defaultProfileRows(for: runtime)
        case .hermes, .pi, .openClaw:
            throw CLIRuntimeModelCatalogDiscoveryError.unsupportedRuntime(request.runtime)
        }
        return CLIRuntimeModelCatalogResponse(
            runtime: runtime.rawValue,
            machineName: Host.current().localizedName,
            generatedAtEpochMillis: Int64(Date().timeIntervalSince1970 * 1000),
            options: options
        )
    }

    private static func defaultProfileRows(for runtime: AssistantRuntimeID) throws -> [CLIRuntimeModelOption] {
        guard let option = CLIRuntimeModelCatalog.defaultProfileOption(for: runtime) else {
            throw CLIRuntimeModelCatalogDiscoveryError.unsupportedRuntime(runtime.rawValue)
        }
        return [option]
    }

    private static func antigravityProfileRow() -> CLIRuntimeModelOption {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selectedModel = object["model"] as? String else {
            return CLIRuntimeModelCatalog.antigravityProfileOption(modelName: nil)
        }
        return CLIRuntimeModelCatalog.antigravityProfileOption(modelName: selectedModel)
    }

    private func executable(named name: String) async throws -> String {
        guard let executable = await resolver.resolveExecutable(named: name) else {
            throw CLIRuntimeModelCatalogDiscoveryError.executableMissing(name)
        }
        return executable
    }

    private func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                throw CLIRuntimeModelCatalogDiscoveryError.timeout(URL(fileURLWithPath: executable).lastPathComponent)
            }

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw CLIRuntimeModelCatalogDiscoveryError.processFailed(
                    URL(fileURLWithPath: executable).lastPathComponent,
                    Int(process.terminationStatus),
                    errorOutput.nonEmpty ?? output
                )
            }
            return output
        }.value
    }
}

private enum CLIRuntimeModelCatalogDiscoveryError: LocalizedError {
    case unsupportedRuntime(String)
    case executableMissing(String)
    case emptyCatalog(String)
    case timeout(String)
    case processFailed(String, Int, String?)

    var errorDescription: String? {
        switch self {
        case .unsupportedRuntime(let runtime):
            return "This Mac cannot publish a CLI model catalog for '\(runtime)'."
        case .executableMissing(let name):
            return "\(name) is not installed or is not visible in the OpenBurnBar app PATH on this Mac."
        case .emptyCatalog(let runtime):
            return "\(runtime) did not advertise any models or agents on this Mac."
        case .timeout(let name):
            return "\(name) model catalog discovery timed out on this Mac."
        case .processFailed(let name, let code, let detail):
            let suffix = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { ": \($0)" } ?? "."
            return "\(name) model catalog discovery exited with status \(code)\(suffix)"
        }
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

    nonisolated static func backend(for runtime: String) -> ChatBackendID? {
        switch runtime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex":
            return .codex
        case "claude", "claudecode", "claude-code":
            return .claude
        case "hermes":
            return .hermes
        case "openclaw", "open-claw":
            return .openclaw
        case "pi", "piagent", "pi-agent":
            return .piAgent
        case "droid", "factory", "factory-droid", "factorydroid":
            return .droid
        case "forge", "forge-dev", "forgedev":
            return .forge
        case "antigravity", "agy", "google-antigravity", "googleantigravity":
            return .antigravity
        case "cursor-agent", "cursoragent", "cursor_agent":
            return .cursorAgent
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
            return "A Mac CLI agent is already responding. Wait for the current reply to finish, then send again."
        case .emptyPrompt:
            return "Cannot send an empty CLI agent message."
        case .emptyResponse:
            return "The CLI agent finished without returning a visible reply."
        case .unsupportedRuntime(let runtime):
            return "This relay does not support '\(runtime)' chat."
        }
    }
}

private extension CLIAgentRelayChatEventKind {
    var isTerminal: Bool {
        self == .completed || self == .failed
    }
}

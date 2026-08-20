import Foundation
import OpenBurnBarCore

typealias CLIAgentRelayChatDispatcher = @Sendable (
    _ request: CLIAgentRelayChatRequest,
    _ eventSender: @escaping @Sendable (CLIAgentRelayChatEvent) async throws -> Void
) async throws -> Void

typealias CLIRuntimeModelCatalogDispatcher = @Sendable (
    _ request: CLIRuntimeModelCatalogRequest
) async throws -> CLIRuntimeModelCatalogResponse

typealias CLIAgentSessionActionFreshnessProbe = @MainActor @Sendable () async -> Bool

typealias CLIAgentSessionActionDispatcher = @MainActor @Sendable (
    _ request: CLIAgentSessionActionRequest,
    _ requestStillActive: CLIAgentSessionActionFreshnessProbe?
) async throws -> CLIAgentSessionActionResponse

typealias CLIAgentSessionActionApprovalPresenter = @MainActor @Sendable (
    _ request: HermesRealtimeRelayApprovalRequest
) async -> HermesRealtimeRelayApprovalResponse

typealias CLIAgentSessionActionResumeRunner = @MainActor @Sendable (
    _ sessionID: String,
    _ targetHarness: String?,
    _ targetModel: String?,
    _ mode: BurnBarResumeMode
) async throws -> BurnBarRunResumeResponse

typealias CLIAgentSessionActionHaltHandler = @MainActor @Sendable () async -> Void

typealias CLIAgentSessionActionInterruptRunner = @MainActor @Sendable (_ sessionID: String) async -> Bool

enum CLIAgentSessionInterruptBus {
    private static var handlers: [String: () -> Void] = [:]

    static func register(sessionID: String, handler: @escaping () -> Void) {
        handlers[sessionID] = handler
    }

    static func unregister(sessionID: String) {
        handlers.removeValue(forKey: sessionID)
    }

    static func interrupt(sessionID: String) -> Bool {
        guard let handler = handlers.removeValue(forKey: sessionID) else { return false }
        handler()
        return true
    }
}

private enum CLIAgentSessionActionApprovalDecision {
    case approve
    case reject
    case rejectAndHalt
}

@MainActor
struct CLIAgentSessionActionDaemonDispatcher {
    private let resumeRunner: CLIAgentSessionActionResumeRunner
    private let approvalPresenter: CLIAgentSessionActionApprovalPresenter?
    private let haltHandler: CLIAgentSessionActionHaltHandler?
    private let interruptRunner: CLIAgentSessionActionInterruptRunner

    init(
        daemonManager: OpenBurnBarDaemonManager = .shared,
        approvalPresenter: CLIAgentSessionActionApprovalPresenter? = nil,
        haltHandler: CLIAgentSessionActionHaltHandler? = nil,
        interruptRunner: CLIAgentSessionActionInterruptRunner? = nil
    ) {
        self.init(
            resumeRunner: { sessionID, targetHarness, targetModel, mode in
                try await daemonManager.runResume(
                    sessionID: sessionID,
                    targetHarness: targetHarness,
                    targetModel: targetModel,
                    mode: mode
                )
            },
            approvalPresenter: approvalPresenter,
            haltHandler: haltHandler,
            interruptRunner: interruptRunner
        )
    }

    init(
        resumeRunner: @escaping CLIAgentSessionActionResumeRunner,
        approvalPresenter: CLIAgentSessionActionApprovalPresenter? = nil,
        haltHandler: CLIAgentSessionActionHaltHandler? = nil,
        interruptRunner: CLIAgentSessionActionInterruptRunner? = nil
    ) {
        self.resumeRunner = resumeRunner
        self.approvalPresenter = approvalPresenter
        self.haltHandler = haltHandler
        self.interruptRunner = interruptRunner ?? { sessionID in
            CLIAgentSessionInterruptBus.interrupt(sessionID: sessionID)
        }
    }

    func perform(
        _ request: CLIAgentSessionActionRequest,
        requestStillActive: CLIAgentSessionActionFreshnessProbe? = nil
    ) async throws -> CLIAgentSessionActionResponse {
        let mode: BurnBarResumeMode
        switch request.action {
        case .interrupt:
            let stopped = await interruptRunner(request.sessionID)
            return CLIAgentSessionActionResponse(
                status: stopped ? .interrupted : .error,
                note: stopped
                    ? "Interrupted session \(request.sessionID)."
                    : "No running session \(request.sessionID) to interrupt.",
                errorCode: stopped ? nil : "session_not_running",
                errorRecovery: stopped ? nil : "The session may have already finished."
            )
        case .packageOnly:
            mode = .open
        case .resume, .handoff:
            switch await approvalDecision(for: request) {
            case .approve:
                break
            case .reject:
                return CLIAgentSessionActionResponse(
                    status: .error,
                    note: "Mac approval is required before this session action can run.",
                    errorCode: "mac_approval_required",
                    errorRecovery: "Approve the session action on the Mac, then try again."
                )
            case .rejectAndHalt:
                await haltHandler?()
                return CLIAgentSessionActionResponse(
                    status: .error,
                    note: "Mac approval was rejected and halt was requested.",
                    errorCode: "mac_approval_rejected_and_halted",
                    errorRecovery: "The Mac halt request was applied. Start a new trusted session before retrying."
                )
            }
            if let requestStillActive, await requestStillActive() == false {
                return CLIAgentSessionActionResponse(
                    status: .error,
                    note: "The relay request expired before the approved session action could run.",
                    errorCode: "relay_request_not_active",
                    errorRecovery: "Send a fresh session action request from the phone."
                )
            }
            mode = .spawn
        }
        let response = try await resumeRunner(request.sessionID, request.targetRuntime, request.targetModelID, mode)
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

    private func approvalDecision(for request: CLIAgentSessionActionRequest) async -> CLIAgentSessionActionApprovalDecision {
        guard let approvalPresenter else { return .reject }
        let approval = await approvalPresenter(approvalRequest(for: request))
        switch approval.decision {
        case .approve:
            return .approve
        case .reject:
            return .reject
        case .rejectAndHalt:
            return .rejectAndHalt
        }
    }

    private func approvalRequest(for request: CLIAgentSessionActionRequest) -> HermesRealtimeRelayApprovalRequest {
        let target = request.targetRuntime?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetText = target.flatMap { $0.isEmpty ? nil : " in \($0)" } ?? ""
        let actionTitle: String
        switch request.action {
        case .resume:
            actionTitle = "Resume CLI session"
        case .handoff:
            actionTitle = "Handoff CLI session"
        case .packageOnly:
            actionTitle = "Prepare CLI session package"
        case .interrupt:
            actionTitle = "Interrupt CLI session"
        }
        let summary = "\(actionTitle)\(targetText)"
        return HermesRealtimeRelayApprovalRequest(
            approvalId: UUID().uuidString,
            runId: "cli-session-action-\(request.sessionID)",
            sessionId: request.sessionID,
            toolKind: "cli.session.\(request.action.rawValue)",
            title: actionTitle,
            message: "\(summary) on this Mac.",
            actionSummary: summary,
            requestedAt: Date(),
            trustMode: "manual"
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
    private let gatewayProvider: @MainActor @Sendable () -> RoutingClientGateway

    init(
        resolver: CLIExecutableResolver = CLIExecutableResolver(),
        settingsManager: SettingsManager
    ) {
        self.resolver = resolver
        self.gatewayProvider = {
            RoutingClientGateway(
                host: settingsManager.gatewayHost.isEmpty ? "127.0.0.1" : settingsManager.gatewayHost,
                port: settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317,
                authToken: settingsManager.gatewayAuthToken
            )
        }
    }

    init(
        resolver: CLIExecutableResolver = CLIExecutableResolver(),
        gatewayProvider: @escaping @MainActor @Sendable () -> RoutingClientGateway
    ) {
        self.resolver = resolver
        self.gatewayProvider = gatewayProvider
    }

    func modelCatalog(for request: CLIRuntimeModelCatalogRequest) async throws -> CLIRuntimeModelCatalogResponse {
        guard let runtime = AssistantRuntimeID(rawValue: request.runtime) else {
            throw CLIRuntimeModelCatalogDiscoveryError.unsupportedRuntime(request.runtime)
        }
        let options: [CLIRuntimeModelOption]
        switch runtime {
        case .codex:
            let executable = try await executable(named: "codex")
            // try?-ok(fire-and-forget probe, default fallback)
            if let output = try? await run(executable: executable, arguments: ["debug", "models"], timeoutSeconds: 12),
               let data = output.data(using: .utf8) {
                let discovered = CLIRuntimeModelCatalog.parseCodexDebugModels(data)
                options = discovered.isEmpty ? try Self.defaultProfileRows(for: runtime) : discovered
            } else {
                options = try Self.defaultProfileRows(for: runtime)
            }
        case .claude:
            _ = try await executable(named: "claude")
            let catalogRows = CLIRuntimeModelCatalog.claudeCodeModelCatalogOptions()
            options = catalogRows.isEmpty ? try Self.defaultProfileRows(for: runtime) : catalogRows
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
            let catalogRows = CLIRuntimeModelCatalog.antigravityModelCatalogOptions(
                selectedModelName: Self.antigravitySelectedModelName()
            )
            options = catalogRows.isEmpty ? [Self.antigravityProfileRow()] : catalogRows
        case .grok:
            let executable = try await executable(named: "grok")
            var discovered: [CLIRuntimeModelOption] = []
            if let output = try? await run(executable: executable, arguments: ["models"], timeoutSeconds: 12) { // try?-ok(fire-and-forget probe, skip on fail)
                discovered.append(contentsOf: CLIRuntimeModelCatalog.parseGrokModels(output))
            }
            if let cacheData = try? Data(contentsOf: Self.grokModelsCacheURL()) { // try?-ok(best-effort cache read)
                discovered.append(contentsOf: CLIRuntimeModelCatalog.parseGrokModelsCache(cacheData))
            }
            let deduplicated = Self.deduplicated(discovered)
            options = deduplicated.isEmpty ? try Self.defaultProfileRows(for: runtime) : deduplicated
        case .cursorAgent:
            let executable = try await executable(named: "cursor-agent")
            var discovered: [CLIRuntimeModelOption] = []
            do {
                let output = try await run(executable: executable, arguments: ["models"], timeoutSeconds: 20)
                discovered.append(contentsOf: CLIRuntimeModelCatalog.parseCursorAgentModels(output))
            } catch {
                AppLogger.chat.silentFailure(
                    "cursor_agent_model_catalog_probe",
                    error: error,
                    context: ["command": "models"]
                )
            }
            if discovered.isEmpty {
                do {
                    let output = try await run(
                        executable: executable,
                        arguments: ["--list-models"],
                        timeoutSeconds: 20
                    )
                    discovered.append(contentsOf: CLIRuntimeModelCatalog.parseCursorAgentModels(output))
                } catch {
                    AppLogger.chat.silentFailure(
                        "cursor_agent_model_catalog_probe",
                        error: error,
                        context: ["command": "--list-models"]
                    )
                }
            }
            let deduplicated = Self.deduplicated(discovered)
            options = deduplicated.isEmpty ? try Self.defaultProfileRows(for: runtime) : deduplicated
        case .openClaude:
            _ = try await executable(named: "openclaude")
            options = try Self.defaultProfileRows(for: runtime)
        case .omp:
            _ = try await executable(named: "omp")
            options = try Self.defaultProfileRows(for: runtime)
        case .junie:
            _ = try await executable(named: "junie")
            options = try Self.defaultProfileRows(for: runtime)
        case .fx:
            _ = try await executable(named: "fx")
            options = try Self.defaultProfileRows(for: runtime)
        case .hermes, .pi, .openClaw:
            throw CLIRuntimeModelCatalogDiscoveryError.unsupportedRuntime(request.runtime)
        }
        let mergedOptions = await mergingOpenBurnBarProxyRowsIfNeeded(
            nativeOptions: options,
            runtime: runtime
        )
        return CLIRuntimeModelCatalogResponse(
            runtime: runtime.rawValue,
            machineName: Host.current().localizedName,
            generatedAtEpochMillis: Int64(Date().timeIntervalSince1970 * 1000),
            options: mergedOptions
        )
    }

    private func mergingOpenBurnBarProxyRowsIfNeeded(
        nativeOptions: [CLIRuntimeModelOption],
        runtime: AssistantRuntimeID
    ) async -> [CLIRuntimeModelOption] {
        guard runtime == .codex || runtime == .claude else { return nativeOptions }
        let gateway = await gatewayProvider()
        let wiring = RoutingClientWiring()
        let target: RoutingClientWiringTarget = runtime == .codex ? .codex : .claudeCode
        let advertisedModels = await wiring.advertisedModels(gateway: gateway)
        let proxyRows = advertisedModels
            .filter { $0.isGatewayServedModelCandidate(for: target) }
            .map { model in
                Self.openBurnBarProxyOption(model: model, runtime: runtime)
            }
        return Self.deduplicated(nativeOptions + proxyRows)
    }

    private static func openBurnBarProxyOption(
        model: RoutingClientAdvertisedModel,
        runtime: AssistantRuntimeID
    ) -> CLIRuntimeModelOption {
        let routeModelID = model.id
        let pickerModelID = runtime == .codex
            ? "openburnbar/\(routeModelID)"
            : routeModelID
        let display = OpenBurnBarModelDisplayName.compose(
            modelName: model.displayName.isEmpty ? routeModelID : model.displayName,
            providerName: model.providerName,
            providerID: model.providerID
        )
        return CLIRuntimeModelOption(
            modelID: pickerModelID,
            routeModelID: routeModelID,
            rowID: "openburnbar|\(model.providerID.lowercased())|\(routeModelID.lowercased())|\(runtime.rawValue)",
            displayName: display,
            providerID: model.providerID,
            providerName: "\(model.providerName) via OpenBurnBar API/OAuth",
            tier: inferredTier(modelID: routeModelID, displayName: model.displayName),
            source: .openBurnBarProxy
        )
    }

    private static func defaultProfileRows(for runtime: AssistantRuntimeID) throws -> [CLIRuntimeModelOption] {
        guard let option = CLIRuntimeModelCatalog.defaultProfileOption(for: runtime) else {
            throw CLIRuntimeModelCatalogDiscoveryError.unsupportedRuntime(runtime.rawValue)
        }
        return [option]
    }

    private static func antigravityProfileRow() -> CLIRuntimeModelOption {
        CLIRuntimeModelCatalog.antigravityProfileOption(modelName: antigravitySelectedModelName())
    }

    private static func antigravitySelectedModelName() -> String? {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/settings.json")
        guard let data = try? Data(contentsOf: settingsURL), // try?-ok(optional settings read)
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(optional json parse)
              let selectedModel = object["model"] as? String else {
            return nil
        }
        return selectedModel
    }

    private static func grokModelsCacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/models_cache.json")
    }

    private static func deduplicated(_ options: [CLIRuntimeModelOption]) -> [CLIRuntimeModelOption] {
        var rows: [CLIRuntimeModelOption] = []
        var seen = Set<String>()
        for option in options {
            let key = "\(option.source.rawValue)|\(option.providerID.lowercased())|\(option.modelID.lowercased())"
            guard seen.insert(key).inserted else { continue }
            rows.append(option)
        }
        return rows
    }

    private static func inferredTier(modelID: String, displayName: String) -> String {
        let haystack = "\(modelID) \(displayName)".lowercased()
        if haystack.contains("opus")
            || haystack.contains("pro")
            || haystack.contains("max")
            || haystack.contains("xhigh") {
            return "flagship"
        }
        if haystack.contains("mini")
            || haystack.contains("nano")
            || haystack.contains("flash")
            || haystack.contains("haiku") {
            return "small"
        }
        return "mid"
    }

    private func executable(named name: String) async throws -> String {
        guard let executable = await resolver.resolveExecutable(named: name) else {
            throw CLIRuntimeModelCatalogDiscoveryError.executableMissing(name)
        }
        return executable
    }

    /// Blocking `Process` work runs off the main actor: this is a `nonisolated`
    /// `async` method (the type is `Sendable`), so callers leave the main actor at
    /// the `await` (SE-0338); cancellation propagates from the awaiting task.
    private func run(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async throws -> String {
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
        // Reap the subprocess on every exit path — including the `CancellationError`
        // thrown from `Task.sleep` below if the awaiting task is cancelled. The
        // former detached task was cancellation-immune and reaped by running its
        // orphan to the deadline; the structured version must clean up here.
        defer { if process.isRunning { process.terminate() } }

        // Drain both pipes WHILE the child runs. Reading only after exit
        // deadlocks any CLI that emits more than the ~64KB pipe buffer: it
        // blocks on write, never exits, and burns the whole timeout.
        let stdoutBuffer = PipeDrainBuffer()
        let stderrBuffer = PipeDrainBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw CLIRuntimeModelCatalogDiscoveryError.timeout(URL(fileURLWithPath: executable).lastPathComponent)
        }

        // Collect any tail bytes written after the last readability callback.
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let output = stdoutBuffer.string()
        let errorOutput = stderrBuffer.string()
        guard process.terminationStatus == 0 else {
            throw CLIRuntimeModelCatalogDiscoveryError.processFailed(
                URL(fileURLWithPath: executable).lastPathComponent,
                Int(process.terminationStatus),
                errorOutput.nonEmpty ?? output
            )
        }
        return output
    }
}

/// Lock-boxed accumulation buffer for `readabilityHandler` callbacks, which
/// arrive on a background queue while the discovery task polls for exit.
private final class PipeDrainBuffer: Sendable {
    private let data = Locked(Data())

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        data.withLock { $0.append(chunk) }
    }

    func string() -> String {
        data.withLock { String(data: $0, encoding: .utf8) ?? "" }
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
        guard !chatController.isSendBusy else {
            throw CLIAgentRelayChatExecutorError.busy
        }
        guard let backend = Self.backend(for: request.runtime) else {
            throw CLIAgentRelayChatExecutorError.unsupportedRuntime(request.runtime)
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw CLIAgentRelayChatExecutorError.emptyPrompt
        }

        // Await the backend switch and thread open before reading `messages`
        // or sending. The fire-and-forget variants complete later and replace
        // `activeThreadID`/`messages`, which raced the send and could persist
        // the reply to the wrong thread or lose it entirely.
        await chatController.setChatBackendAsync(backend)
        if let modelID = request.modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelID.isEmpty {
            chatController.setChatModelSelection(modelID, for: backend)
        }
        await chatController.openOrCreateChatThreadAsync(id: request.clientThreadID)

        let knownMessageIDs = Set(chatController.messages.map(\.id))
        // Preserve whatever the Mac user has typed — a phone-relayed send
        // must not destroy the local composer draft.
        let preservedDraft = chatController.inputText
        chatController.inputText = prompt
        await chatController.send()
        if chatController.inputText.isEmpty {
            chatController.inputText = preservedDraft
        }

        var lastSignature = ""
        var emittedAnyAssistantEvent = false

        func latestAssistantMessage() -> ChatMessageRecord? {
            if let streamingID = chatController.activeStreamMessageId,
               let streamingMessage = chatController.messages.first(where: { $0.id == streamingID }) {
                return streamingMessage
            }
            // Only messages created by THIS turn qualify. Falling back to any
            // prior assistant message re-emitted a previous turn's answer as
            // this turn's `.completed` when the stream produced nothing.
            return chatController.messages.last {
                $0.role == .assistant && !knownMessageIDs.contains($0.id)
            }
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
        case "junie", "jetbrains-junie", "jetbrainsjunie":
            return .junie
        case "fx", "vercel-fx", "vercelfx":
            return .fx
        case "omp", "ohmypi", "oh-my-pi", "oh my pi":
            return .omp
        case "grok", "grok-build", "xai", "grok-agent", "grok-cli":
            return .grok
        case "kimi", "kimi-code", "kimi-cli":
            return .kimi
        default:
            return nil
        }
    }

    private static func relayPiece(from piece: ChatTranscriptPiece) -> CLIAgentRelayTranscriptPiece {
        let kind: CLIAgentRelayTranscriptPieceKind
        switch piece.kind {
        case .text:
            kind = .text
        case .reasoning:
            kind = .reasoning
        case .refusal:
            kind = .refusal
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

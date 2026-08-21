import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

@MainActor
final class CLIBridge: ObservableObject {
    enum Backend: Equatable {
        case claudeCode(path: String)
        case codex(path: String)
        case hermes(baseURL: URL)
    }

    private(set) var detectedBackend: Backend?
    private(set) var hermesAvailable: Bool = false
    /// The last Hermes catalog probe was answered with 401/403: the gateway is
    /// up but rejected the bearer key. Distinct from "catalog not readable yet"
    /// (cold start), which self-heals — this state needs the user to fix a key.
    private(set) var hermesCatalogAuthRejected: Bool = false
    private(set) var openClawAvailable: Bool = false
    private(set) var piAgentAvailable: Bool = false
    /// The model name currently loaded in Hermes (fetched from /v1/models).
    private(set) var hermesModelName: String?
    /// Concrete Hermes gateway models grouped by `HermesModelID` in UI.
    private(set) var hermesAdvertisedModels: [HermesAdvertisedModel] = []
    /// Full OpenAI-compatible model rows advertised by the Hermes gateway.
    private(set) var hermesGatewayModels: [OpenAICompatibleAdvertisedModel] = []
    /// The model name currently advertised by the Pi gateway.
    private(set) var piAgentModelName: String?
    /// Full OpenAI-compatible model rows advertised by the OpenClaw gateway.
    private(set) var openClawGatewayModels: [OpenAICompatibleAdvertisedModel] = []
    /// Full OpenAI-compatible model rows advertised by the Pi gateway.
    private(set) var piAgentGatewayModels: [OpenAICompatibleAdvertisedModel] = []

    nonisolated private let resolver = CLIExecutableResolver()
    nonisolated private let streamRuntime = CLIBridgeStreamRuntimeCoordinator()

    /// Whether a CLI binary exists on PATH (used to validate Codex vs Claude selection).
    func isExecutableAvailable(named name: String) async -> Bool {
        await resolveExecutable(named: name) != nil
    }

    func detect() async {
        // Prefer Codex when both are installed so chat remains available if Claude CLI auth/config is broken.
        if let path = await resolveExecutable(named: "codex") {
            detectedBackend = .codex(path: path)
            return
        }
        if let path = await resolveExecutable(named: "claude") {
            detectedBackend = .claudeCode(path: path)
            return
        }
        detectedBackend = nil
    }

    /// Non-blocking probe for Hermes gateway API availability. Does not set `detectedBackend`.
    /// Also fetches the current model name from the models endpoint.
    func probeHermesAvailability(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        bearerToken: String? = nil
    ) async {
        let result = await Self.probeHermes(
            baseURL: baseURL,
            bearerToken: bearerToken
        )
        hermesAvailable = result.available
        hermesCatalogAuthRejected = result.authRejected
        hermesModelName = result.modelName
        hermesAdvertisedModels = result.hermesModels
        hermesGatewayModels = result.models
    }

    /// Probe OpenClaw gateway (OpenAI-compatible `/v1/models`).
    func probeOpenClawAvailability(baseURL: URL, bearerToken: String? = nil) async {
        let result = await OpenAICompatibleModelProbe.probeWithModels(baseURL: baseURL, bearerToken: bearerToken)
        openClawAvailable = result.available
        openClawGatewayModels = result.models
    }

    /// Probe Pi agent gateway (OpenAI-compatible `/v1/models`).
    func probePiAgentAvailability(baseURL: URL, bearerToken: String? = nil) async {
        let result = await OpenAICompatibleModelProbe.probeWithModels(baseURL: baseURL, bearerToken: bearerToken)
        piAgentAvailable = result.available
        piAgentModelName = result.modelName
        piAgentGatewayModels = result.models
    }

    func cancel() {
        Task {
            await cancelAndWait()
        }
    }

    func cancelAndWait() async {
        await streamRuntime.cancelAll()
    }

    #if DEBUG
    func testing_registerRunningProcess(_ process: Process) async -> UInt64 {
        await streamRuntime.registerRunningProcess(process)
    }
    #endif

    /// T-TOOL-03: terminate any in-flight spawned external CLI process without
    /// disturbing the HTTP gateway stream. Called when a desktop-control grant is
    /// revoked mid-run so an agent operating under the just-revoked capabilities
    /// is killed immediately rather than allowed to finish the current command.
    func terminateRunningCLIProcess() {
        Task {
            await streamRuntime.terminateRunningProcess()
        }
    }

    /// T-TOOL-03: builds the mid-run grant poll for a spawned CLI lane. The
    /// returned closure (run periodically by `CLIProcessStreamRunner`) reports
    /// whether the grant is STILL active in the live store — catching both expiry
    /// and explicit revocation — so the process is terminated the moment the
    /// operator pulls the grant. Returns `nil` for ungranted (read-only) runs.
    nonisolated static func spawnedCLIGrantPoll(
        for grant: AgentCapabilityGrant?
    ) -> (@Sendable () async -> Bool)? {
        guard let grant else { return nil }
        let grantID = grant.grantID
        let runtimeID = grant.runtimeID
        let threadID = grant.threadID
        return {
            await MainActor.run {
                AgentCapabilityGrantStore.shared
                    .activeGrant(runtimeID: runtimeID, threadID: threadID)?.grantID == grantID
            }
        }
    }

    func generateTextWithClaude(
        model: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        guard let executable = await resolveExecutable(named: "claude") else {
            throw CLIBridgeError.noCLI
        }

        return try await collectText(
            from: streamClaude(
                executable: executable,
                prompt: CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage),
                model: model
            )
        )
    }

    func generateTextWithCodex(
        model: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        guard let executable = await resolveExecutable(named: "codex") else {
            throw CLIBridgeError.noCLI
        }

        return try await collectText(
            from: streamCodex(
                executable: executable,
                prompt: CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage),
                model: model
            )
        )
    }

    private func collectText(
        from stream: AsyncThrowingStream<CLIChatStreamEvent, Error>
    ) async throws -> String {
        var output = ""
        for try await event in stream {
            guard case .text(let chunk) = event, chunk.isEmpty == false else { continue }
            output += chunk
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw CLIBridgeError.emptyResponse
        }
        return trimmed
    }

    private func streamClaude(
        executable: String,
        prompt: String,
        model: String
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runClaude(
                    executable: executable,
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: nil,
                    continuation: continuation
                )
            }
        }
    }

    private func streamCodex(
        executable: String,
        prompt: String,
        model: String
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runCodex(
                    executable: executable,
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: nil,
                    continuation: continuation
                )
            }
        }
    }

    /// Streams assistant text and tool-use events from the CLI (Claude `stream-json`, Codex JSONL text only).
    func chat(systemPrompt: String, userMessage: String) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                // This `Task` inherits `CLIBridge`'s `@MainActor` isolation, so
                // `detectedBackend` is read directly here; the heavy streaming
                // below hops off the main actor via the nonisolated runner.
                let backend = self.detectedBackend
                guard let backend else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }

                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                let runner = CLIProcessStreamRunner(runtime: self.streamRuntime)

                switch backend {
                case .claudeCode(let path):
                    await runner.runClaude(
                        executable: path,
                        prompt: fullPrompt,
                        model: "",
                        workspaceDirectory: nil,
                        continuation: continuation
                    )
                case .codex(let path):
                    await runner.runCodex(
                        executable: path,
                        prompt: fullPrompt,
                        model: "",
                        workspaceDirectory: nil,
                        continuation: continuation
                    )
                case .hermes:
                    continuation.finish(throwing: CLIBridgeError.hermesUnavailable)
                }
            }
        }
    }

    /// Streams assistant text and tool-use events from Hermes gateway API (OpenAI-compatible SSE).
    func chatHermes(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String? = nil,
        model: String = "hermes",
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil,
        toolBroker: AgentToolBroker? = nil,
        plugins: [[String: any Sendable]]? = nil,
        additionalHeaders: [String: String] = [:]
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        let stream = AsyncThrowingStream<CLIChatStreamEvent, Error> { continuation in
            let streamIDTask = Task { [streamRuntime] in
                await streamRuntime.nextHTTPStreamID()
            }
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let streamID = await streamIDTask.value
                await OpenAICompatibleChatGatewayClient(runtime: self.streamRuntime).runStream(
                    baseURL: baseURL,
                    model: model,
                    systemPrompt: systemPrompt,
                    history: history,
                    bearerToken: bearerToken,
                    unavailableError: .hermesUnavailable,
                    missingModelError: .noSelectedModel("Hermes"),
                    disallowedModelError: .disallowedModel(backend: "Hermes", model: model),
                    httpStreamID: streamID,
                    allowedModels: OpenAICompatibleChatGatewayClient.ModelAllowlist(modelIDs: self.hermesGatewayModels.map(\.id) + ["hermes"]),
                    attachmentBytes: attachmentBytes,
                    capabilities: capabilities,
                    workspaceURL: workspaceURL,
                    toolBroker: toolBroker,
                    plugins: plugins,
                    additionalHeaders: additionalHeaders,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [streamRuntime] _ in
                task.cancel()
                Task {
                    let streamID = await streamIDTask.value
                    await streamRuntime.cancelHTTPStreamTask(streamID: streamID)
                }
            }
            Task { [streamRuntime] in
                let streamID = await streamIDTask.value
                await streamRuntime.installHTTPStreamTask(task, streamID: streamID)
            }
        }
        return stream
    }

    /// OpenClaw gateway — OpenAI-compatible SSE (`/v1/chat/completions`).
    func chatOpenClaw(
        baseURL: URL,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        model: String = "",
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil,
        toolBroker: AgentToolBroker? = nil,
        plugins: [[String: any Sendable]]? = nil,
        additionalHeaders: [String: String] = [:]
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamIDTask = Task { [streamRuntime] in
                await streamRuntime.nextHTTPStreamID()
            }
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let streamID = await streamIDTask.value
                await OpenAICompatibleChatGatewayClient(runtime: self.streamRuntime).runStream(
                    baseURL: baseURL,
                    model: model,
                    systemPrompt: systemPrompt,
                    history: history,
                    bearerToken: bearerToken,
                    unavailableError: .openClawUnavailable,
                    missingModelError: .noSelectedModel("OpenClaw"),
                    disallowedModelError: .disallowedModel(backend: "OpenClaw", model: model),
                    httpStreamID: streamID,
                    allowedModels: OpenAICompatibleChatGatewayClient.ModelAllowlist(modelIDs: self.openClawGatewayModels.map(\.id)),
                    attachmentBytes: attachmentBytes,
                    capabilities: capabilities,
                    workspaceURL: workspaceURL,
                    toolBroker: toolBroker,
                    plugins: plugins,
                    additionalHeaders: additionalHeaders,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [streamRuntime] _ in
                task.cancel()
                Task {
                    let streamID = await streamIDTask.value
                    await streamRuntime.cancelHTTPStreamTask(streamID: streamID)
                }
            }
            Task { [streamRuntime] in
                let streamID = await streamIDTask.value
                await streamRuntime.installHTTPStreamTask(task, streamID: streamID)
            }
        }
    }

    /// Pi agent gateway — OpenAI-compatible SSE (`/v1/chat/completions`).
    /// Reuses `OpenAICompatibleChatGatewayClient` exactly like Hermes/OpenClaw
    /// so streaming, attachments, and usage parsing all stay in lockstep.
    func chatPiAgent(
        baseURL: URL,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        model: String = "pi",
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil,
        toolBroker: AgentToolBroker? = nil,
        plugins: [[String: any Sendable]]? = nil,
        additionalHeaders: [String: String] = [:]
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamIDTask = Task { [streamRuntime] in
                await streamRuntime.nextHTTPStreamID()
            }
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let streamID = await streamIDTask.value
                let selectedPiModel = {
                    let t = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? "pi" : t
                }()
                await OpenAICompatibleChatGatewayClient(runtime: self.streamRuntime).runStream(
                    baseURL: baseURL,
                    model: selectedPiModel,
                    systemPrompt: systemPrompt,
                    history: history,
                    bearerToken: bearerToken,
                    unavailableError: .piAgentUnavailable,
                    missingModelError: .noSelectedModel("Pi"),
                    disallowedModelError: .disallowedModel(backend: "Pi", model: selectedPiModel),
                    httpStreamID: streamID,
                    allowedModels: OpenAICompatibleChatGatewayClient.ModelAllowlist(modelIDs: self.piAgentGatewayModels.map(\.id) + ["pi"]),
                    attachmentBytes: attachmentBytes,
                    capabilities: capabilities,
                    workspaceURL: workspaceURL,
                    toolBroker: toolBroker,
                    plugins: plugins,
                    additionalHeaders: additionalHeaders,
                    continuation: continuation
                )
            }
            continuation.onTermination = { [streamRuntime] _ in
                task.cancel()
                Task {
                    let streamID = await streamIDTask.value
                    await streamRuntime.cancelHTTPStreamTask(streamID: streamID)
                }
            }
            Task { [streamRuntime] in
                let streamID = await streamIDTask.value
                await streamRuntime.installHTTPStreamTask(task, streamID: streamID)
            }
        }
    }

    /// Streams using Codex CLI only (ignores Claude if both are installed).
    func chatCodexStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil,
        profileStore: (any SwitcherProfileStoreAdapter)? = nil,
        fallbackPlanner: (any CLIFallbackPlanning)? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                if let profileStore,
                   let fallbackPlanner,
                   let requestedProfile = Self.activeCodexProfile(from: profileStore) {
                    let stream = CLIProfileStreamFailoverRunner(
                        runtime: self.streamRuntime,
                        profileStore: profileStore,
                        fallbackPlanner: fallbackPlanner
                    ).streamCodex(
                        requestedProfile: requestedProfile,
                        prompt: fullPrompt,
                        model: model,
                        workspaceDirectory: workspaceDirectory,
                        capabilityGrant: capabilityGrant
                    )
                    do {
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                guard let executable = await self.resolveExecutable(named: "codex") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runCodex(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    nonisolated static func activeCodexProfile(
        from profileStore: any SwitcherProfileStoreAdapter
    ) -> SwitcherProfileRecord? {
        let activeProfileIDs = [
            profileStore.fetchActiveProfileID(for: ProviderID.codex),
            profileStore.fetchActiveProfileID()
        ].compactMap { $0 }

        for profileID in activeProfileIDs {
            guard let profile = profileStore.fetchProfile(id: profileID),
                  isUsableCodexProfile(profile) else {
                continue
            }
            return profile
        }

        return profileStore.fetchAllProfiles()
            .first { isUsableCodexProfile($0) }
    }

    private nonisolated static func isCodexProfile(_ profile: SwitcherProfileRecord) -> Bool {
        profile.targetKind == .cli && profile.cliType == .codex
    }

    private nonisolated static func isUsableCodexProfile(_ profile: SwitcherProfileRecord) -> Bool {
        isCodexProfile(profile) && !profile.isDisabled
    }

    /// Streams using Claude Code CLI only.
    func chatClaudeStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "claude") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runClaude(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using the OpenClaude CLI (github.com/Gitlawb/openclaude) — an open
    /// fork of Claude Code. It speaks the same `-p` / `--output-format stream-json`
    /// / `--model` protocol, so it reuses the Claude process runner with the
    /// `openclaude` binary. (Distinct from OpenClaw, which is a gateway provider.)
    func chatOpenClaudeStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "openclaude") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runClaude(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using the Oh My Pi `omp` CLI.
    func chatOMPStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "omp") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runOMP(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    func chatDroidStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "droid") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runDroid(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using Junie CLI only.
    func chatJunieStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                // Junie has no enforceable read-only/no-shell flags: require the
                // full interactive grant, matching the mission-launch planner.
                guard CLIAgentJunieMissionPolicy.chatLaunchPermitted(capabilityGrant) else {
                    continuation.finish(throwing: CLIBridgeError.junieRequiresFullGrant)
                    return
                }
                // A phone-side revoke or downgrade updates the live grant store
                // but not this caller's captured grant value, so re-check the
                // store (same T-TOOL-03 poll the runner uses mid-flight) before
                // spawning: a just-revoked approval must refuse the launch, not
                // rely on the post-launch poll to kill the unsandboxed process.
                if let grantStillActive = Self.spawnedCLIGrantPoll(for: capabilityGrant) {
                    guard await grantStillActive() else {
                        continuation.finish(throwing: CLIBridgeError.junieRequiresFullGrant)
                        return
                    }
                }
                guard let executable = await self.resolveExecutable(named: "junie") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runJunie(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using the Vercel fx CLI (`fx ask --json`).
    ///
    /// fx has enforceable permission flags (`--auto` / default fail-closed
    /// mode), so unlike Junie it does not need a full-grant launch gate; the
    /// argument builder only passes `--auto` under a full desktop grant and
    /// never passes `--yolo`. `resumeSessionID` continues a saved fx session
    /// for multi-turn chat.
    func chatFxStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil,
        resumeSessionID: String? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "fx") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runFx(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    resumeSessionID: resumeSessionID,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using Forge CLI only.
    func chatForgeStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "forge") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runForge(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using Google Antigravity CLI only.
    func chatAntigravityStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "agy") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runAntigravity(
                    executable: executable,
                    prompt: fullPrompt,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    /// Streams using Cursor Agent CLI only.
    func chatCursorAgentStream(
        systemPrompt: String,
        userMessage: String,
        workspaceDirectory: URL? = nil,
        model: String = "",
        capabilityGrant: AgentCapabilityGrant? = nil
    ) -> AsyncThrowingStream<CLIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let executable = await self.resolveExecutable(named: "cursor-agent") else {
                    continuation.finish(throwing: CLIBridgeError.noCLI)
                    return
                }
                let fullPrompt = CLIArgumentBuilder.combinedPrompt(systemPrompt: systemPrompt, userMessage: userMessage)
                await CLIProcessStreamRunner(runtime: self.streamRuntime).runCursorAgent(
                    executable: executable,
                    prompt: fullPrompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    grantStillActive: Self.spawnedCLIGrantPoll(for: capabilityGrant),
                    continuation: continuation
                )
            }
        }
    }

    private func resolveExecutable(named name: String) async -> String? {
        await resolver.resolveExecutable(named: name)
    }

    nonisolated private static func probeHermes(
        baseURL: URL,
        bearerToken: String?
    ) async -> OpenAICompatibleModelProbeResult {
        // Read the live /v1/models catalog (the picker's source of truth) and
        // probe /health concurrently. The catalog can lag a cold-started gateway
        // by a few seconds while it aggregates upstream providers, but /health
        // answers immediately — and the gateway routes the canonical family names
        // ("claude", "codex", "ollama", …) without needing the catalog. So we
        // treat the gateway as available whenever EITHER endpoint answers, rather
        // than dead-ending chat on a transient catalog read.
        async let healthy = OpenAICompatibleModelProbe.healthReachable(
            baseURL: baseURL,
            bearerToken: bearerToken,
            timeout: 6
        )
        let catalog = await OpenAICompatibleModelProbe.probeWithModels(
            baseURL: baseURL,
            bearerToken: bearerToken,
            timeout: 8
        )
        let resolved = Self.resolveHermesAvailability(
            catalog: (catalog.available, catalog.modelName, catalog.hermesModels, catalog.models),
            healthReachable: await healthy
        )
        // Auth rejection rides alongside the availability verdict: a 401/403
        // catalog answer proves the gateway is up (hence still "available" via
        // /health) while pinpointing the key as the thing to fix.
        return OpenAICompatibleModelProbeResult(
            available: resolved.available,
            authRejected: catalog.authRejected,
            modelName: resolved.modelName,
            hermesModels: resolved.hermesModels,
            models: resolved.models
        )
    }

    /// Pure availability decision for the Hermes probe (extracted so the
    /// catalog-vs-health fallback is unit-testable without a live gateway).
    ///
    /// - When the catalog read succeeds, use it verbatim (full model list).
    /// - When the catalog read fails but `/health` answers, report the gateway as
    ///   available with an empty (not-yet-readable) catalog — chat still functions
    ///   because the gateway routes the selected family directly, and the picker
    ///   self-heals on the next probe.
    /// - When neither answers, the gateway is genuinely down.
    nonisolated static func resolveHermesAvailability(
        catalog: (
            available: Bool,
            modelName: String?,
            hermesModels: [HermesAdvertisedModel],
            models: [OpenAICompatibleAdvertisedModel]
        ),
        healthReachable: Bool
    ) -> (
        available: Bool,
        modelName: String?,
        hermesModels: [HermesAdvertisedModel],
        models: [OpenAICompatibleAdvertisedModel]
    ) {
        if catalog.available { return catalog }
        if healthReachable { return (true, nil, [], []) }
        return catalog
    }
}

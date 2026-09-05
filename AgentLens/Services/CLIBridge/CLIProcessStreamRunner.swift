import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct CLIProcessStreamRunner: Sendable {
    let runtime: CLIBridgeStreamRuntimeCoordinator

    func runClaude(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.claudeArguments(prompt: prompt, model: model, capabilityGrant: capabilityGrant),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .claude
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            (ClaudeCodeStreamJSONParser.events(fromLine: line), nil, false)
        }
    }

    func runCodex(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        environmentOverrides: [String: String] = [:],
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = CodexExecJSONLParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.codexArguments(prompt: prompt, model: model, capabilityGrant: capabilityGrant),
                environment: Self.mergedEnvironment(
                    executablePath: executable,
                    overrides: environmentOverrides
                ),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .codex
            ),
            grantStillActive: grantStillActive,
            continuation: continuation,
            // No finalize: the codex exec stream is line-oriented JSONL with
            // no tail buffer to flush, and CodexExecJSONLParser has no
            // finish() — the call the layout sweep pattern-matched in here
            // never compiled (nothing in CI builds this app; the release
            // lane's first-ever full compile caught it).
            parseLine: { line in
                let result = parser.events(fromLine: line)
                return (result.events, result.error, result.error != nil)
            }
        )
    }

    func runDroid(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = GenericCLIJSONOrTextParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.droidArguments(
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .droid
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    func runJunie(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = GenericCLIJSONOrTextParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.junieArguments(
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .junie
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    func runMuse(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        // `museArguments` always emits `--json`, so stdout is the structured
        // event log `MuseExecJSONLParser` understands — same shape as runFx.
        var parser = MuseExecJSONLParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.museArguments(
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .muse
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            let result = parser.events(fromLine: line)
            return (result.events, result.error, result.error != nil)
        }
    }

    func runForge(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = GenericCLIJSONOrTextParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.forgeArguments(
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .forge
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    func runAntigravity(
        executable: String,
        prompt: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = GenericCLIJSONOrTextParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.antigravityArguments(
                    prompt: prompt,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .antigravity
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    func runFx(
        executable: String,
        prompt: String,
        model: String = "",
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        resumeSessionID: String? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = FxAskJSONParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.fxArguments(
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant,
                    resumeSessionID: resumeSessionID
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .fx
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            let result = parser.events(fromLine: line)
            return (result.events, result.error, result.error != nil)
        }
    }

    func runOMP(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = GenericCLIJSONOrTextParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.ompArguments(
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .omp
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    func runCursorAgent(
        executable: String,
        prompt: String,
        model: String = "",
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = GenericCLIJSONOrTextParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.cursorAgentArguments(
                    prompt: prompt,
                    model: model,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.agentProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .cursorAgent
            ),
            grantStillActive: grantStillActive,
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    private func runProcess(
        invocation: CLIProcessInvocation,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation,
        finalize: () -> (events: [CLIChatStreamEvent], error: CLIBridgeError?) = {
            ([], nil)
        },
        parseLine: (String) -> (events: [CLIChatStreamEvent], error: CLIBridgeError?, terminate: Bool)
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let quotaRecorder = CLIBridgeQuotaSignalRecorder()
        let supervisor = makeTerminalSessionSupervisor(
            cliType: invocation.cliType,
            process: process,
            quotaRecorder: quotaRecorder
        )
        let provider = Self.agentProvider(for: invocation.cliType)

        let processToken = await runtime.registerRunningProcess(process, launched: false)
        continuation.onTermination = { [runtime] _ in
            Task {
                await runtime.cancelRunningProcess(token: processToken)
            }
        }

        // T-TOOL-03: mid-run grant poll. When this CLI was spawned under a
        // desktop-control grant, poll its validity and terminate the process the
        // moment the grant is revoked or expires, rather than letting an in-flight
        // agent finish executing under capabilities the operator just pulled.
        let grantPollTask: Task<Void, Never>?
        if let grantStillActive {
            grantPollTask = Task(priority: .utility) { [runtime] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2)) // try?-ok(cancellation-only grant poll sleep)
                    if Task.isCancelled { return }
                    if await grantStillActive() == false {
                        await runtime.cancelRunningProcess(token: processToken)
                        return
                    }
                }
            }
        } else {
            grantPollTask = nil
        }

        do {
            try Task.checkCancellation()
            try process.run()
            if await runtime.markProcessLaunched(token: processToken) == false {
                // A cancel/revocation arrived in the pre-launch window; the
                // coordinator could not terminate an unlaunched Process, so
                // honor the request now that it is running.
                process.terminate()
                process.waitUntilExit()
                grantPollTask?.cancel()
                continuation.finish(throwing: CancellationError())
                return
            }
            if let provider {
                await MainActor.run {
                    PixelClockAgentStatusStore.shared.markRunning(provider: provider)
                } // cov:ignore -- nonfatal-log
            } // cov:ignore -- nonfatal-log
        } catch {
            grantPollTask?.cancel()
            await runtime.clearRunningProcess(token: processToken)
            continuation.finish(throwing: error)
            return
        }

        let stderrReader = AsyncPipeLineReader(pipe: stderrPipe)
        let stdoutReader = AsyncPipeLineReader(pipe: stdoutPipe)

        let stderrTask = Task(priority: .utility) {
            do {
                for try await line in stderrReader.lines() {
                    supervisor.ingest(line, source: .stderr)
                }
            } catch {
                if !Task.isCancelled { // cov:ignore -- nonfatal-log
                    AppLogger.parser.silentFailure( // cov:ignore -- nonfatal-log
                        "cli_stderr_stream_read_failed", // cov:ignore -- nonfatal-log
                        error: error // cov:ignore -- nonfatal-log
                    ) // cov:ignore -- nonfatal-log
                } // cov:ignore -- nonfatal-log
            } // cov:ignore -- nonfatal-log
        }

        var parserError: CLIBridgeError?
        do {
            for try await line in stdoutReader.lines() {
                try Task.checkCancellation()

                supervisor.ingest(line, source: .stdout)
                if quotaRecorder.snapshot() != nil {
                    if process.isRunning {
                        process.terminate()
                    }
                    break
                }

                let parsed = parseLine(line)
                for event in parsed.events {
                    continuation.yield(event)
                }
                if let error = parsed.error {
                    parserError = error
                }
                if parsed.terminate {
                    if process.isRunning {
                        process.terminate()
                    }
                    break
                }
            }
        } catch {
            if !Task.isCancelled { // cov:ignore -- nonfatal-log
                AppLogger.parser.silentFailure( // cov:ignore -- nonfatal-log
                    "cli_stdout_stream_read_failed", // cov:ignore -- nonfatal-log
                    error: error // cov:ignore -- nonfatal-log
                ) // cov:ignore -- nonfatal-log
            } // cov:ignore -- nonfatal-log
        }

        // The quota/terminate break paths SIGTERM the child; a CLI that
        // ignores SIGTERM would otherwise pin this cooperative-pool thread in
        // waitUntilExit forever. Give it a bounded grace period, then SIGKILL.
        if process.isRunning {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000) // try?-ok(bounded exit-grace poll)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        grantPollTask?.cancel()
        stderrTask.cancel()
        await stderrTask.value
        await runtime.clearRunningProcess(token: processToken)

        if quotaRecorder.snapshot() == nil, parserError == nil {
            let final = finalize()
            for event in final.events {
                continuation.yield(event)
            }
            parserError = final.error
        }

        let failed = quotaRecorder.snapshot() != nil
            || parserError != nil
            || (process.terminationStatus != 0 && process.terminationStatus != 15)
        if let provider {
            await MainActor.run {
                PixelClockAgentStatusStore.shared.markFinished(provider: provider, failed: failed)
            }
        }

        if let detail = quotaRecorder.snapshot() {
            continuation.finish(throwing: CLIBridgeError.quotaExhausted(detail))
            return
        }
        if let parserError {
            continuation.finish(throwing: parserError)
            return
        }
        if process.terminationStatus != 0, process.terminationStatus != 15 {
            continuation.finish(throwing: CLIBridgeError.processExit(code: Int(process.terminationStatus)))
            return
        }
        continuation.finish()
    }

    private func makeTerminalSessionSupervisor(
        cliType: SwitcherCLIProfileType,
        process: Process,
        quotaRecorder: CLIBridgeQuotaSignalRecorder
    ) -> CLITerminalSessionSupervisor {
        CLITerminalSessionSupervisor(cliType: cliType) { event in
            guard case .quotaExhausted(let detail, _) = event else { return }
            quotaRecorder.record(detail)
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func agentProvider(for cliType: SwitcherCLIProfileType) -> AgentProvider? {
        switch cliType {
        case .codex:
            return .codex
        case .claude:
            return .claudeCode
        case .opencode:
            return .openCode
        case .droid:
            return .factory
        case .forge:
            return .forgeDev
        case .antigravity:
            return .antigravity
        case .grok:
            return .xAI
        case .cursorAgent:
            return .cursorAgent
        case .omp:
            return .omp
        case .gemini:
            return .geminiCLI
        case .kimi:
            return .kimi
        case .pi:
            return .piAgent
        case .junie:
            return .junie
        case .primeAgent:
            return .primeAgent
        case .fx:
            return .fx
        case .muse:
            return .muse
        case .hermes:
            return .hermes
        case .goose:
            return .goose
        case .windsurf:
            return .windsurf
        case .openClaude:
            return .openClaude
        case .openClaw:
            return .openClaw
        }
    }

    private static func mergedEnvironment(
        executablePath: String,
        overrides: [String: String]
    ) -> [String: String] {
        var environment = CLIExecutableResolver.agentProcessEnvironment(executablePath: executablePath)
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private static func drainPipe(
        _ pipe: Pipe,
        into supervisor: CLITerminalSessionSupervisor,
        source: CLITerminalSessionOutputSource
    ) async {
        let reader = AsyncPipeLineReader(pipe: pipe)
        do {
            for try await line in reader.lines() {
                supervisor.ingest(line, source: source)
            }
        } catch {
            if !Task.isCancelled { // cov:ignore -- nonfatal-log
                AppLogger.parser.silentFailure( // cov:ignore -- nonfatal-log
                    "cli_pipe_drain_failed", // cov:ignore -- nonfatal-log
                    error: error, // cov:ignore -- nonfatal-log
                    context: ["source": source.rawValue] // cov:ignore -- nonfatal-log
                ) // cov:ignore -- nonfatal-log
            } // cov:ignore -- nonfatal-log
        }
    }
}

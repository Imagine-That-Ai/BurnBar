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
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.claudeArguments(prompt: prompt, model: model, capabilityGrant: capabilityGrant),
                environment: CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .claude
            ),
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
            continuation: continuation
        ) { line in
            let result = parser.events(fromLine: line)
            return (result.events, result.error, result.error != nil)
        }
    }

    func runDroid(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
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
                environment: CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .droid
            ),
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    func runForge(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
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
                environment: CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .forge
            ),
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
                environment: CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .antigravity
            ),
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    func runCursorAgent(
        executable: String,
        prompt: String,
        workspaceDirectory: URL? = nil,
        capabilityGrant: AgentCapabilityGrant? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = GenericCLIJSONOrTextParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.cursorAgentArguments(
                    prompt: prompt,
                    workspaceDirectory: workspaceDirectory,
                    capabilityGrant: capabilityGrant
                ),
                environment: CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .cursorAgent
            ),
            continuation: continuation
        ) { line in
            (parser.events(fromLine: line), nil, false)
        }
    }

    private func runProcess(
        invocation: CLIProcessInvocation,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation,
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

        let processToken = await runtime.registerRunningProcess(process)
        continuation.onTermination = { [runtime] _ in
            Task {
                await runtime.cancelRunningProcess(token: processToken)
            }
        }

        do {
            try Task.checkCancellation()
            try process.run()
            if let provider {
                await MainActor.run {
                    PixelClockAgentStatusStore.shared.markRunning(provider: provider)
                } // cov:ignore -- nonfatal-log
            } // cov:ignore -- nonfatal-log
        } catch {
            await runtime.clearRunningProcess(token: processToken)
            continuation.finish(throwing: error)
            return
        }

        let stderrReader = AsyncPipeLineReader(pipe: stderrPipe)
        let stdoutReader = AsyncPipeLineReader(pipe: stdoutPipe)

        let stderrTask = Task.detached(priority: .utility) {
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

        process.waitUntilExit()
        stderrTask.cancel()
        await stderrTask.value
        await runtime.clearRunningProcess(token: processToken)
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
            return .openClaw
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
        }
    }

    private static func mergedEnvironment(
        executablePath: String,
        overrides: [String: String]
    ) -> [String: String] {
        var environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executablePath)
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

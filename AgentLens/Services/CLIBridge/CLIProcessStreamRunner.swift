import Foundation
import OpenBurnBarCore

struct CLIProcessStreamRunner: Sendable {
    let runtime: CLIBridgeStreamRuntimeCoordinator

    func runClaude(
        executable: String,
        prompt: String,
        model: String,
        workspaceDirectory: URL? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.claudeArguments(prompt: prompt, model: model),
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
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        var parser = CodexExecJSONLParser()
        await runProcess(
            invocation: CLIProcessInvocation(
                executable: executable,
                arguments: CLIArgumentBuilder.codexArguments(prompt: prompt, model: model),
                environment: CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable),
                workingDirectory: workspaceDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
                cliType: .codex
            ),
            continuation: continuation
        ) { line in
            let result = parser.events(fromLine: line)
            return (result.events, result.error, result.error != nil)
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
                }
            }
        } catch {
            await runtime.clearRunningProcess(token: processToken)
            continuation.finish(throwing: error)
            return
        }

        let stderrTask = Task.detached(priority: .utility) {
            await Self.drainPipe(stderrPipe, into: supervisor, source: .stderr)
        }

        let readHandle = stdoutPipe.fileHandleForReading
        var parserError: CLIBridgeError?
        while !Task.isCancelled, let line = readHandle.readLine() {
            supervisor.ingest(line + "\n", source: .stdout)
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

        process.waitUntilExit()
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
        }
    }

    private static func drainPipe(
        _ pipe: Pipe,
        into supervisor: CLITerminalSessionSupervisor,
        source: CLITerminalSessionOutputSource
    ) async {
        let readHandle = pipe.fileHandleForReading
        while let line = readHandle.readLine() {
            supervisor.ingest(line + "\n", source: source)
        }
    }
}

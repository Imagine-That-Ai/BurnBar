import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Direct CLI mission launch and hidden process execution.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

extension CLIAgentMissionRequestListener {
    struct DirectCLIMissionResult {
        let status: String
        let output: String
        let errorMessage: String?
        let sessionID: String
    }

    struct DirectCLIStreamEvent: Sendable {
        let phase: String
        let kind: String
        let title: String
        let message: String
        let toolName: String?
        let isError: Bool

        static func assistant(_ message: String, title: String = "Assistant") -> DirectCLIStreamEvent {
            DirectCLIStreamEvent(
                phase: "assistant_response",
                kind: "llm_response",
                title: title,
                message: message,
                toolName: nil,
                isError: false
            )
        }

        static func toolCall(_ message: String, title: String = "Tool call", toolName: String? = nil) -> DirectCLIStreamEvent {
            DirectCLIStreamEvent(
                phase: "tool_use",
                kind: "tool_call",
                title: title,
                message: message,
                toolName: toolName,
                isError: false
            )
        }

        static func toolResult(_ message: String, title: String = "Tool result", toolName: String? = nil, isError: Bool = false) -> DirectCLIStreamEvent {
            DirectCLIStreamEvent(
                phase: "tool_result",
                kind: isError ? "error" : "tool_result",
                title: title,
                message: message,
                toolName: toolName,
                isError: isError
            )
        }
    }

    func runDirectCLIMissionIfNeeded(
        title: String,
        prompt: String,
        backend: CLIAgentMissionBackend,
        data: [String: Any],
        reference: DocumentReference,
        requestID: String,
        cancellationTracker: MissionCancellationTracker
    ) async -> DirectCLIMissionResult? {
        let workingDirectoryURL = workingDirectoryURL(from: data)
        // Hermes Square §6.5 — merge any persona-scope env namespace the
        // phone attached. A missing scope resolves to `.empty` (missions
        // without a scope keep using the plan's env verbatim); a PRESENT but
        // malformed scope is FAIL-CLOSED — refuse the mission rather than
        // dispatch the spawned CLI with no persona sandbox (full shell +
        // unrestricted file edits). See CLIAgentMissionPersonaScopeResolution.
        let personaOverrides: CLIAgentMissionPersonaScopeApplier.RuntimeOverrides
        switch CLIAgentMissionPersonaScopeResolution.resolve(from: data) {
        case .resolved(let overrides):
            personaOverrides = overrides
        case .refused(let message):
            AppLogger.sync.error(
                "mission_persona_scope_rejected",
                metadata: ["requestID": requestID]
            )
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: message,
                sessionID: "persona-scope-rejected-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }
        // Fail closed: Junie has no enforceable read-only/no-shell flags (CLIAgentJunieMissionPolicy).
        if let junieRefusal = CLIAgentJunieMissionPolicy.directExecutionRefusal(backend: backend, grant: CLIAgentMissionRuntimePlanner.capabilityGrant(for: backend, data: data)) { return junieRefusal }
        if CLIAgentMissionRuntimePlanner.presentationMode(from: data) == .macVisibleCLI {
            guard let plan = CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
                title: title,
                prompt: prompt,
                backend: backend,
                data: data
            ) else {
                return DirectCLIMissionResult(
                    status: "failed",
                    output: "",
                    errorMessage: "\(backend.displayName) does not expose a visible Mac CLI launch path yet.",
                    sessionID: "visible-\(backend.rawValue)-\(UUID().uuidString)"
                )
            }
            var env = plan.extraEnvironment
            for (k, v) in personaOverrides.extraEnvironment { env[k] = v }
            return await runVisibleTerminalMission(
                executableName: plan.executableName,
                arguments: plan.arguments,
                backend: backend,
                extraEnvironment: env,
                workingDirectoryURL: workingDirectoryURL,
                reference: reference,
                requestID: requestID,
                cancellationTracker: cancellationTracker
            )
        }

        if let plan = CLIAgentMissionRuntimePlanner.directLaunchPlan(title: title, prompt: prompt, backend: backend, data: data) {
            var env = plan.extraEnvironment
            for (k, v) in personaOverrides.extraEnvironment { env[k] = v }
            return await runDirectCLIMission(
                executableName: plan.executableName,
                arguments: plan.arguments,
                backend: backend,
                extraEnvironment: env,
                workingDirectoryURL: workingDirectoryURL,
                reference: reference,
                requestID: requestID,
                cancellationTracker: cancellationTracker
            )
        }

        if backend.chatBackend != nil { return nil }

        return DirectCLIMissionResult(
            status: "failed",
            output: "",
            errorMessage: "Unsupported mission runtime '\(backend.rawValue)'.",
            sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
        )
    }

    func workingDirectoryURL(from data: [String: Any]) -> URL? {
        guard let rawPath = (data["targetProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return nil }
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
    }

    func runDirectCLIMission(
        executableName: String,
        arguments: [String],
        backend: CLIAgentMissionBackend,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        reference: DocumentReference,
        requestID: String,
        cancellationTracker: MissionCancellationTracker
    ) async -> DirectCLIMissionResult {
        guard let executable = await CLIExecutableResolver().resolveExecutable(named: executableName) else {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: "\(backend.displayName) CLI executable '\(executableName)' was not found on the Mac PATH.",
                sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }

        do {
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "process_started",
                kind: "tool_call",
                title: "Process started",
                message: "Launching \(backend.displayName) CLI process.",
                backend: backend
            )
            let output = try await runProcess(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: 180,
                extraEnvironment: extraEnvironment,
                workingDirectoryURL: workingDirectoryURL,
                cancellationTracker: cancellationTracker,
                eventSink: { [weak self] event in
                    Task { @MainActor [weak self] in
                        await self?.recordEvent(
                            reference: reference,
                            requestID: requestID,
                            phase: event.phase,
                            kind: event.kind,
                            title: event.title,
                            message: event.message,
                            backend: backend,
                            toolName: event.toolName,
                            isError: event.isError
                        )
                    }
                }
            )
            return DirectCLIMissionResult(
                status: "completed",
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                errorMessage: nil,
                sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
            )
        } catch {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: error.localizedDescription,
                sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }
    }

    private nonisolated func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        cancellationTracker: MissionCancellationTracker,
        eventSink: @escaping @Sendable (DirectCLIStreamEvent) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        process.currentDirectoryURL = workingDirectoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        let output = LockedProcessOutput()
        let streamMirror = DirectCLIStreamMirror()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)
            else { return }
            output.appendStdout(text)
            let emittedStructuredEvents = streamMirror.consumeStdout(text, eventSink: eventSink)
            if !emittedStructuredEvents,
               let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                eventSink(.assistant(chunk))
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)
            else { return }
            output.appendStderr(text)
            let emittedStructuredEvents = streamMirror.consumeStderr(text, eventSink: eventSink)
            if !emittedStructuredEvents,
               let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                eventSink(.toolResult(chunk, title: "Process stderr", isError: true))
            }
        }

        if cancellationTracker.isCancelled {
            throw NSError(
                domain: "OpenBurnBar.DirectCLIMission",
                code: 299,
                userInfo: [NSLocalizedDescriptionKey: "Mission was cancelled by the user."]
            )
        }

        try process.run()

        // Safety net for the task-cancellation path: a `CancellationError` thrown
        // from `Task.sleep` below skips the tracker/timeout cleanup, so reap the
        // process and detach the stream handlers on every exit here. (The former
        // detached task was cancellation-immune and reaped via its orphan.)
        // No-op on the normal return path, where the process has already exited
        // and the handlers were already cleared.
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            if cancellationTracker.isCancelled {
                let pid = process.processIdentifier
                let killScript = """
                kill_tree() {
                    local _pid=$1
                    for _child in $(pgrep -P $_pid); do
                        kill_tree $_child
                    done
                    kill -TERM $_pid 2>/dev/null
                }
                kill_tree \(pid)
                """
                let killTask = Process()
                killTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
                killTask.arguments = ["-c", killScript]
                try? killTask.run() // try?-ok(fire-and-forget kill)
                killTask.waitUntilExit()

                process.terminate()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                throw NSError(
                    domain: "OpenBurnBar.DirectCLIMission",
                    code: 299,
                    userInfo: [NSLocalizedDescriptionKey: "Mission was cancelled by the user."]
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            let pid = process.processIdentifier
            let killScript = """
            kill_tree() {
                local _pid=$1
                for _child in $(pgrep -P $_pid); do
                    kill_tree $_child
                done
                kill -TERM $_pid 2>/dev/null
            }
            kill_tree \(pid)
            """
            let killTask = Process()
            killTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
            killTask.arguments = ["-c", killScript]
            try? killTask.run() // try?-ok(fire-and-forget kill)
            killTask.waitUntilExit()

            process.terminate()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw NSError(
                domain: "OpenBurnBar.DirectCLIMission",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "Direct \(URL(fileURLWithPath: executable).lastPathComponent) mission timed out after \(Int(timeoutSeconds)) seconds."]
            )
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let captured = output.snapshot()
        let stdoutText = captured.stdout
        let stderrText = captured.stderr
        let finalOutput = streamMirror.finalOutputSnapshot(fallback: stdoutText.nilIfEmpty ?? stderrText)
        guard process.terminationStatus == 0 else {
            let message = [stdoutText, stderrText]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "OpenBurnBar.DirectCLIMission",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.nilIfEmpty ?? "Direct CLI mission failed with exit \(process.terminationStatus)."]
            )
        }

        return finalOutput
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

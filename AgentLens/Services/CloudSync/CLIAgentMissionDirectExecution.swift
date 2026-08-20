import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarKernel
import OpenBurnBarSignalCore
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
        data: UntypedJSONObject,
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
        if let presentationResult = await runDirectCLIPresentationLaunch(
            presentationRaw: data["presentationMode"] as? String,
            backend: backend,
            workingDirectoryURL: workingDirectoryURL
        ) {
            return presentationResult
        }
        switch CLIAgentMissionRuntimePlanner.presentationMode(from: data) {
        case .macVisibleCLI:
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
        case .macInteractiveCLI:
            // Handled by CLIAgentDirectCLILaunchGate above (injectable launcher).
            break
        case .nativeChat:
            break
        }

        if ACPStdioClient.executableName(for: backend.rawValue) != nil {
            return await runACPStdioMission(
                title: title,
                prompt: prompt,
                backend: backend,
                data: data,
                workingDirectoryURL: workingDirectoryURL,
                reference: reference,
                requestID: requestID,
                cancellationTracker: cancellationTracker
            )
        }

        if let plan = CLIAgentMissionRuntimePlanner.directLaunchPlan(title: title, prompt: prompt, backend: backend, data: data) {
            let banned = CLIArgumentBuilder.forbiddenLaunchFlags(in: plan.arguments)
            if !banned.isEmpty {
                return DirectCLIMissionResult(
                    status: "failed",
                    output: "",
                    errorMessage: "Launch argv contains forbidden flags: \(banned.joined(separator: ", "))",
                    sessionID: "forbidden-\(backend.rawValue)-\(UUID().uuidString)"
                )
            }
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

    func workingDirectoryURL(from data: UntypedJSONObject) -> URL? {
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

    func runACPStdioMission(
        title: String,
        prompt: String,
        backend: CLIAgentMissionBackend,
        data: UntypedJSONObject,
        workingDirectoryURL: URL?,
        reference: DocumentReference,
        requestID: String,
        cancellationTracker: MissionCancellationTracker
    ) async -> DirectCLIMissionResult {
        let hostPrompt = CLIAgentMissionRuntimePlanner.prompt(title: title, prompt: prompt, backend: backend, data: data)
        let executableName = ACPStdioClient.executableName(for: backend.rawValue) ?? backend.rawValue
        let arguments = ACPStdioClient.launchArgv(for: backend.rawValue)
        guard let executable = await CLIExecutableResolver().resolveExecutable(named: executableName) else {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: "\(backend.displayName) ACP executable was not found on PATH.",
                sessionID: "acp-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }
        let sessionID = "acp-\(backend.rawValue)-\(UUID().uuidString)"
        CLIAgentSessionInterruptBus.register(sessionID: sessionID) {
            cancellationTracker.cancel()
        }
        CLIAgentSessionInterruptBus.register(sessionID: requestID) {
            cancellationTracker.cancel()
        }
        defer {
            CLIAgentSessionInterruptBus.unregister(sessionID: sessionID)
            CLIAgentSessionInterruptBus.unregister(sessionID: requestID)
        }
        do {
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "process_started",
                kind: "tool_call",
                title: "ACP started",
                message: "Launching \(backend.displayName) ACP stdio session.",
                backend: backend
            )
            let output = try await ACPStdioClient.runSession(
                executable: executable,
                arguments: arguments,
                prompt: hostPrompt,
                workingDirectory: workingDirectoryURL,
                onPermission: { request in
                    await self.resolveACPPermission(
                        request,
                        data: data,
                        document: reference,
                        requestID: requestID,
                        backend: backend
                    )
                },
                onUpdate: { chunk in
                    Task { @MainActor in
                        await self.recordEvent(
                            reference: reference,
                            requestID: requestID,
                            phase: "assistant_response",
                            kind: "llm_response",
                            title: "Assistant",
                            message: chunk,
                            backend: backend
                        )
                    }
                },
                interruptFlag: { cancellationTracker.isCancelled }
            )
            await publishArtifactIfNeeded(
                data: data,
                workingDirectoryURL: workingDirectoryURL,
                reference: reference,
                requestID: requestID,
                backend: backend
            )
            return DirectCLIMissionResult(
                status: "completed",
                output: output,
                errorMessage: nil,
                sessionID: sessionID
            )
        } catch {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: error.localizedDescription,
                sessionID: sessionID
            )
        }
    }

    func publishArtifactIfNeeded(
        data: UntypedJSONObject,
        workingDirectoryURL: URL?,
        reference: DocumentReference,
        requestID: String,
        backend: CLIAgentMissionBackend
    ) async {
        guard let raw = (data["artifactPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return
        }
        let roots = [
            workingDirectoryURL,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".burnbar/attachments")
        ].compactMap { $0 }
        do {
            let contained = try MacAttachmentLandingService.containedExistingFile(path: raw, roots: roots)
            if let handle = claimedMissions[requestID] {
                _ = try await MacBurnbarAttachmentUploadClient.uploadFile(
                    fileURL: contained,
                    deviceId: handle.deviceId
                )
            }
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "artifact_published",
                kind: "artifact",
                title: "Artifact published",
                message: "Containment-checked artifact is ready for the saver.",
                backend: backend,
                artifactPath: contained.path
            )
        } catch {
            logger.error("artifact containment failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resolveACPPermission(
        _ request: ACPStdioClient.PermissionRequest,
        data _: UntypedJSONObject,
        document: DocumentReference,
        requestID: String,
        backend: CLIAgentMissionBackend
    ) async -> Bool {
        let tool = (request.toolName ?? "").lowercased()
        let isShell = tool.contains("bash") || tool.contains("shell") || tool.contains("command")
        let isEdit = tool.contains("edit") || tool.contains("write") || tool.contains("file")
        guard isShell || isEdit else { return false }
        let approvalID = CLIAgentApprovalRequestID.acpPark()
        let message = "\(backend.displayName) requests \(isShell ? "command" : "file edit") permission for \(request.toolName ?? "tool")."
        do {
            guard let uid = accountManager.currentUID else { return false }
            guard let handle = claimedMissions[requestID] else { return false }
            let sealed = try await sealedStateUpdate(
                uid: uid,
                requestID: requestID,
                payload: [:],
                liveSummary: message,
                approvalTitle: "Approve \(request.toolName ?? "tool")",
                approvalMessage: message
            )
            guard let sealedState = sealed["sealedStatePayload"] as? UntypedJSONObject else { return false }
            try await publishParkedCeiling(
                requestID: requestID,
                deviceId: handle.deviceId,
                commandsAllowed: isShell,
                fileEditsAllowed: isEdit,
                runtime: backend.rawValue,
                approvalMode: "existing_policy",
                prompt: request.toolName ?? "tool"
            )
            try await ComputerUseSecurityCallableClient.updateCliAgentMissionStatus(
                requestId: requestID,
                deviceId: handle.deviceId,
                status: "waiting_for_approval",
                hostWriteNonce: handle.hostWriteNonce,
                sealedStatePayload: sealedState,
                approvalRequestId: approvalID
            )
            await recordEvent(
                reference: document,
                requestID: requestID,
                phase: "approval_requested",
                kind: "approval_request",
                title: "Approval required",
                message: message,
                backend: backend
            )
            var allowed = false
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                let snap = try await document.getDocument()
                let status = (snap.data()?["approvalStatus"] as? String)?.lowercased()
                if status == "approved" {
                    allowed = true
                    break
                }
                if status == "rejected" || status == "canceled" || status == "cancelled" {
                    break
                }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            // Resume running before completed / before a second park.
            try await resumeMissionRunning(requestID: requestID, handle: handle, liveSummary: message)
            return allowed
        } catch {
            logger.error("acp permission park failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    func resumeMissionRunning(
        requestID: String,
        handle: ClaimedMissionHandle,
        liveSummary: String
    ) async throws {
        guard let uid = accountManager.currentUID else { return }
        let sealed = try await sealedStateUpdate(
            uid: uid,
            requestID: requestID,
            payload: [:],
            liveSummary: liveSummary
        )
        guard let sealedState = sealed["sealedStatePayload"] as? UntypedJSONObject else { return }
        try await ComputerUseSecurityCallableClient.updateCliAgentMissionStatus(
            requestId: requestID,
            deviceId: handle.deviceId,
            status: "running",
            hostWriteNonce: handle.hostWriteNonce,
            sealedStatePayload: sealedState
        )
    }

    func publishParkedCeiling(
        requestID: String,
        deviceId: String,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool,
        runtime: String,
        approvalMode: String,
        prompt: String
    ) async throws {
        let grant = MissionApprovalCeiling.grantObject(
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        )
        let canonical = MissionApprovalCeiling.canonical(
            missionID: requestID,
            requestedGrant: grant,
            grantCeiling: grant,
            promptSHA256: MissionApprovalCeiling.promptSHA256(prompt),
            personaDigest: String(repeating: "0", count: 64),
            requestedRuntime: runtime,
            approvalMode: approvalMode,
            issuedAt: ISO8601DateFormatter().string(from: Date())
        )
        let digest = try MissionApprovalCeiling.digest(canonical)
        guard let uid = accountManager.currentUID else {
            throw NSError(domain: "OpenBurnBar.MissionApprovalCeiling", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        let identity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: deviceId)
        let signature = try MissionApprovalCeiling.signCanonical(canonical, identity: identity)
        parkedCeilingByRequest[requestID] = (digest, grant)
        var sendable: [String: any Sendable] = [:]
        for (key, value) in canonical {
            if let sendableValue = value as? any Sendable {
                sendable[key] = sendableValue
            }
        }
        try await ComputerUseSecurityCallableClient.publishMissionApprovalCeiling(
            requestId: requestID,
            deviceId: deviceId,
            canonical: sendable,
            ceilingDigest: digest,
            signature: signature
        )
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
        let interruptSessionID = "direct-\(process.processIdentifier)-\(UUID().uuidString)"
        CLIAgentSessionInterruptBus.register(sessionID: interruptSessionID) {
            if process.isRunning { process.terminate() }
        }
        CLIAgentSessionInterruptBus.register(sessionID: requestID) {
            if process.isRunning { process.terminate() }
        }
        defer {
            CLIAgentSessionInterruptBus.unregister(sessionID: interruptSessionID)
            CLIAgentSessionInterruptBus.unregister(sessionID: requestID)
        }

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

    func runDirectCLIPresentationLaunch(
        presentationRaw: String?,
        backend: CLIAgentMissionBackend,
        workingDirectoryURL: URL?
    ) async -> DirectCLIMissionResult? {
        await CLIAgentDirectCLILaunchGate.run(
            presentationRaw: presentationRaw,
            backend: backend,
            workingDirectoryURL: workingDirectoryURL,
            launcher: interactiveTerminalLauncher
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

protocol InteractiveTerminalLaunching: Sendable {
    func launchInteractive(runtimeId: String, workingDirectory: URL?) async throws
}

struct LiveInteractiveTerminalLauncher: InteractiveTerminalLaunching {
    func launchInteractive(runtimeId: String, workingDirectory: URL?) async throws {
        _ = try await InteractiveTerminalLauncher.launchInteractive(
            runtimeId: runtimeId,
            workingDirectory: workingDirectory
        )
    }
}

enum CLIAgentDirectCLILaunchGate {
    enum Decision: Equatable {
        case failed(String)
        case interactive
        case proceed
    }

    static func decide(presentationRaw: String?) -> Decision {
        let raw = presentationRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty, CLIAgentChatPresentationMode(rawValue: raw) == nil {
            return .failed("unknown or unsupported presentationMode '\(raw)'")
        }
        if CLIAgentChatPresentationMode(rawValue: raw) == .macInteractiveCLI {
            return .interactive
        }
        return .proceed
    }

    static func run(
        presentationRaw: String?,
        backend: CLIAgentMissionBackend,
        workingDirectoryURL: URL?,
        launcher: InteractiveTerminalLaunching
    ) async -> CLIAgentMissionRequestListener.DirectCLIMissionResult? {
        switch decide(presentationRaw: presentationRaw) {
        case .failed(let message):
            return .init(
                status: "failed",
                output: "",
                errorMessage: message,
                sessionID: "presentation-\(backend.rawValue)-\(UUID().uuidString)"
            )
        case .interactive:
            do {
                try await launcher.launchInteractive(
                    runtimeId: backend.rawValue,
                    workingDirectory: workingDirectoryURL
                )
                return .init(
                    status: "running",
                    output: "",
                    errorMessage: nil,
                    sessionID: "interactive-\(backend.rawValue)-\(UUID().uuidString)"
                )
            } catch {
                return .init(
                    status: "failed",
                    output: "",
                    errorMessage: "Interactive terminal launch failed: \(error.localizedDescription)",
                    sessionID: "interactive-\(backend.rawValue)-\(UUID().uuidString)"
                )
            }
        case .proceed:
            return nil
        }
    }
}

enum CLIAgentApprovalRequestID {
    static func preDispatch() -> String { "approval-\(UUID().uuidString)" }
    static func acpPark() -> String { "acp-\(UUID().uuidString)" }
}

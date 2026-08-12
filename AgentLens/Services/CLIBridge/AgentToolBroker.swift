import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

struct AgentToolExecutionPayload {
    let content: String
    let detail: String?
}

final class AgentToolBrokerRevocationRegistry: Sendable {
    typealias Handler = @Sendable () async -> Void

    private struct Registration: Sendable {
        let runtimeID: AssistantRuntimeID
        let threadID: String
        let handler: Handler
    }

    private let registrations = Locked<[UUID: Registration]>([:])

    func register(
        id: UUID,
        runtimeID: AssistantRuntimeID,
        threadID: String,
        handler: @escaping Handler
    ) {
        registrations.withLock {
            $0[id] = Registration(runtimeID: runtimeID, threadID: threadID, handler: handler)
        }
    }

    func unregister(id: UUID) {
        _ = registrations.withLock { $0.removeValue(forKey: id) }
    }

    @discardableResult
    func revoke(runtimeID: AssistantRuntimeID, threadID: String) async -> Int {
        let handlers = registrations.read().values.compactMap { registration in
            registration.runtimeID == runtimeID && registration.threadID == threadID
                ? registration.handler
                : nil
        }
        await withTaskGroup(of: Void.self) { group in
            for handler in handlers {
                group.addTask {
                    await handler()
                }
            }
        }
        return handlers.count
    }
}

let agentToolBrokerRevocationRegistry = AgentToolBrokerRevocationRegistry()

final class AgentToolBroker: Sendable {
    enum DaemonBrowserRevocationOutcome: Equatable, Sendable {
        case statePublished
        case panicHalted
        case failed
    }

    let grant: AgentCapabilityGrant
    let workspaceURL: URL
    #if canImport(AppKit) && !DISTRIBUTION_MAS
    private struct WeakController {
        weak var value: ComputerUseRuntimeController?
    }

    // Set-once-at-init weak link to the @MainActor runtime controller; the lock
    // mediates the (weak) slot so the broker stays plainly Sendable.
    private let computerUseRuntimeControllerBox = OSAllocatedUnfairLock(uncheckedState: WeakController())
    var computerUseRuntimeController: ComputerUseRuntimeController? {
        get { computerUseRuntimeControllerBox.withLockUnchecked { $0.value } }
        set { computerUseRuntimeControllerBox.withLockUnchecked { $0.value = newValue } }
    }
    #endif
    private let grantStillActive: (@Sendable () async -> Bool)?

    /// Human-in-the-loop gate invoked before a **privileged** broker tool
    /// (shell / workspace write / desktop export) runs.
    /// Returns `true` to allow. When `nil`, privileged tools FAIL CLOSED — there
    /// is no silent privileged execution under an active grant (finding A1).
    typealias PrivilegedActionApprover = @Sendable (_ toolName: String, _ summary: String) async -> Bool
    private let privilegedActionApprover: PrivilegedActionApprover?

    /// T-TOOL-02(b) / T-AI-07: fresh local-auth re-authorization for the
    /// unrestricted (YOLO) shell path. Returns `true` when the operator re-proved
    /// presence (Touch ID / device-owner auth). When `nil` the unrestricted shell
    /// FAILS CLOSED at every re-auth checkpoint — an obeyed prompt injection
    /// cannot run unbounded shell because it can never satisfy the gate.
    typealias UnrestrictedShellReauthorizer = @Sendable (_ summary: String) async -> Bool
    private let unrestrictedShellReauthorizer: UnrestrictedShellReauthorizer?

    /// How many unrestricted-shell actions may run between re-auth proofs.
    static let unrestrictedShellReauthInterval = 5

    /// Cadence tracker for the unrestricted-shell re-auth window. Stored in a
    /// `Locked` box so the broker stays plainly `Sendable` (matching the rest of
    /// this broker's lock-mediated mutable state) and the tool loop can dispatch
    /// concurrently without data races.
    private let unrestrictedShellCadenceBox = Locked<AgentReauthCadence>(
        AgentReauthCadence(interval: AgentToolBroker.unrestrictedShellReauthInterval)
    )

    /// Broker tools that perform privileged side effects (shell exec, writes,
    /// exfiltration-capable export). Each requires explicit per-action approval.
    /// Trust mode scopes which tools may be offered; it never replaces the
    /// concrete action gate.
    static let approvalGatedTools: Set<String> = [
        "shell_run", "shell_run_unrestricted", "workspace_write_file", "desktop_export_file"
    ]

    /// F3: forensic audit log for unsandboxed unrestricted-shell execution.
    static let unrestrictedShellAudit = Logger(
        subsystem: "com.openburnbar.AgentLens",
        category: "agent.shell.unrestricted"
    )

    /// Short, non-reversible digest of an executed command for the audit trail.
    /// We log the hash (not the plaintext) so the trail cannot itself leak secrets
    /// embedded in a command line.
    static func commandAuditDigest(_ command: String) -> String {
        let digest = SHA256.hash(data: Data(command.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private let browserSessionIDBox = Locked<String?>(nil)
    private let revocationRequestedBox = Locked(false)
    private let revocationRegistrationID = UUID()

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    init(
        grant: AgentCapabilityGrant,
        workspaceURL: URL,
        computerUseRuntimeController: ComputerUseRuntimeController? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil
    ) {
        self.grant = grant
        self.workspaceURL = Self.canonicalFileURL(workspaceURL)
        self.grantStillActive = grantStillActive
        self.privilegedActionApprover = nil
        self.unrestrictedShellReauthorizer = nil
        self.computerUseRuntimeController = computerUseRuntimeController
        registerForRevocation()
    }

    init(
        grant: AgentCapabilityGrant,
        workspaceURL: URL,
        computerUseRuntimeController: ComputerUseRuntimeController? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        privilegedActionApprover: PrivilegedActionApprover?,
        unrestrictedShellReauthorizer: UnrestrictedShellReauthorizer? = nil
    ) {
        self.grant = grant
        self.workspaceURL = Self.canonicalFileURL(workspaceURL)
        self.grantStillActive = grantStillActive
        self.privilegedActionApprover = privilegedActionApprover
        self.unrestrictedShellReauthorizer = unrestrictedShellReauthorizer
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        self.computerUseRuntimeController = computerUseRuntimeController
        #endif
        registerForRevocation()
    }
    #else
    init(
        grant: AgentCapabilityGrant,
        workspaceURL: URL,
        grantStillActive: (@Sendable () async -> Bool)? = nil
    ) {
        self.grant = grant
        self.workspaceURL = Self.canonicalFileURL(workspaceURL)
        self.grantStillActive = grantStillActive
        self.privilegedActionApprover = nil
        self.unrestrictedShellReauthorizer = nil
        registerForRevocation()
    }

    init(
        grant: AgentCapabilityGrant,
        workspaceURL: URL,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        privilegedActionApprover: PrivilegedActionApprover?,
        unrestrictedShellReauthorizer: UnrestrictedShellReauthorizer? = nil
    ) {
        self.grant = grant
        self.workspaceURL = Self.canonicalFileURL(workspaceURL)
        self.grantStillActive = grantStillActive
        self.privilegedActionApprover = privilegedActionApprover
        self.unrestrictedShellReauthorizer = unrestrictedShellReauthorizer
        registerForRevocation()
    }
    #endif

    deinit {
        agentToolBrokerRevocationRegistry.unregister(id: revocationRegistrationID)
    }

    private func registerForRevocation() {
        agentToolBrokerRevocationRegistry.register(
            id: revocationRegistrationID,
            runtimeID: grant.runtimeID,
            threadID: grant.threadID,
            handler: { [weak self] in
                await self?.revokeDaemonBrowserSessionIfNeeded()
            }
        )
    }

    @discardableResult
    static func revokeDaemonBrowserSessions(
        runtimeID: AssistantRuntimeID,
        threadID: String
    ) async -> Int {
        await agentToolBrokerRevocationRegistry.revoke(
            runtimeID: runtimeID,
            threadID: threadID
        )
    }

    /// T-TOOL-02(b): whether the next unrestricted-shell action needs a fresh
    /// local-auth re-authorization right now (exposed for testing the cadence).
    var unrestrictedShellRequiresReauthNow: Bool {
        unrestrictedShellCadenceBox.read().requiresReauthBeforeNextAction
    }

    var openAITools: [[String: Any]] {
        AgentDesktopToolDefinitions.openAITools(for: grant)
    }

    var isActive: Bool {
        grant.isActive()
    }

    func invokeOpenAITool(
        name: String,
        arguments: String,
        callID: String,
        runID: String
    ) async -> AgentToolExecutionPayload {
        guard !revocationRequestedBox.read() else {
            return denied(name: name, reason: "desktop grant was revoked")
        }
        guard grant.isActive() else {
            await revokeDaemonBrowserSessionIfNeeded()
            return denied(name: name, reason: "desktop grant is not active")
        }
        if let grantStillActive {
            let stillActive = await grantStillActive()
            guard stillActive else {
                await revokeDaemonBrowserSessionIfNeeded()
                return denied(name: name, reason: "desktop grant was revoked")
            }
        }
        guard let definition = AgentDesktopToolDefinitions.tool(named: name),
              grant.supportsAll(definition.requiredCapabilities) else {
            return denied(name: name, reason: "tool is outside the active grant")
        }

        if let toolKind = AgentDesktopToolDefinitions.computerUseToolKind(named: name) {
            return await invokeComputerUseTool(
                toolKind,
                arguments: arguments,
                callID: callID,
                runID: runID
            )
        }

        do {
            let object = try Self.jsonObject(fromArguments: arguments)
            // A1: privileged broker tools require explicit per-action approval.
            // Fail closed when no approver is wired — never execute a privileged
            // tool silently under an ambient or trusted grant.
            if Self.approvalGatedTools.contains(name) {
                let summary = Self.approvalSummary(tool: name, arguments: object)
                guard let approver = privilegedActionApprover else {
                    return denied(name: name, reason: "privileged action requires approval but no approver is available")
                }
                let approved = await approver(name, summary)
                guard approved else {
                    return denied(name: name, reason: "user declined this action")
                }
            }
            switch name {
            case "workspace_read_file":
                return try readWorkspaceFile(arguments: object)
            case "workspace_list_files":
                return try listWorkspaceFiles(arguments: object)
            case "workspace_write_file":
                return try writeWorkspaceFile(arguments: object)
            case "desktop_export_file":
                return try exportDesktopFile(arguments: object)
            case "shell_run":
                return try await runShell(arguments: object)
            case "shell_run_unrestricted":
                return try await runShellUnrestricted(arguments: object)
            default:
                return denied(name: name, reason: "unknown tool")
            }
        } catch {
            return errorPayload(name: name, error: String(describing: error))
        }
    }

    private func invokeComputerUseTool(
        _ toolKind: BurnBarToolKind,
        arguments: String,
        callID: String,
        runID: String
    ) async -> AgentToolExecutionPayload {
        let invocationArguments: BurnBarJSONValue
        do {
            invocationArguments = try Self.burnBarJSONValue(fromArguments: arguments)
        } catch {
            return errorPayload(name: toolKind.rawValue, error: "invalid JSON arguments: \(String(describing: error))")
        }

        let invocation = BurnBarToolInvocation(
            callID: callID.isEmpty ? UUID().uuidString : callID,
            runID: BurnBarRunID(rawValue: runID.isEmpty ? "agent-\(grant.grantID)" : runID),
            tool: toolKind,
            arguments: invocationArguments,
            requestedBy: BurnBarClientID(rawValue: "agent-\(grant.runtimeID.rawValue)"),
            requestedAt: Date()
        )

        if toolKind.isBrowserComputerUse {
            return await invokeDaemonBrowserTool(invocation)
        }

        #if canImport(AppKit) && !DISTRIBUTION_MAS
        guard let controller = computerUseRuntimeController else {
            return denied(name: toolKind.rawValue, reason: "Mac Computer Use runtime is not attached")
        }
        do {
            _ = try await controller.ensureSession(mode: .system, trustMode: grant.trustMode)
            let response = await controller.coordinator.invoke(invocation)
            return Self.payload(name: toolKind.rawValue, response: response)
        } catch {
            return errorPayload(name: toolKind.rawValue, error: String(describing: error))
        }
        #else
        return denied(name: toolKind.rawValue, reason: "Mac system Computer Use is unavailable in this build")
        #endif
    }

    private func invokeDaemonBrowserTool(_ invocation: BurnBarToolInvocation) async -> AgentToolExecutionPayload {
        // cov:ignore-start -- live daemon-browser RPC bridge; revocation decision helpers are covered by CLIBridgeTests and AgentToolBrokerReauthTests.
        guard !revocationRequestedBox.read() else {
            return denied(name: invocation.tool.rawValue, reason: "desktop grant was revoked")
        }
        do {
            #if canImport(AppKit) && !DISTRIBUTION_MAS
            let concurrentSessionActive = await computerUseRuntimeController?.hasActiveSessionForDaemonBridge() ?? false
            #else
            let concurrentSessionActive = false
            #endif
            let sessionID: String
            if let existing = browserSessionIDBox.read() {
                sessionID = existing
            } else {
                let response = try await OpenBurnBarDaemonManager.shared.startComputerUseSession(
                    ComputerUseSessionStartRequest(
                        mode: ComputerUseMode.browser.rawValue,
                        trustMode: grant.trustMode.rawValue,
                        scopeRuleIds: grant.scopeRuleIDs,
                        macHostNodeId: grant.sourceDeviceID,
                        actionCap: ComputerUseBudgetEnvelope.initialNormal.activeActionsPerRun,
                        sessionTimeoutSeconds: 1800,
                        clientID: BurnBarClientID(rawValue: "agent-\(grant.runtimeID.rawValue)"),
                        runID: invocation.runID,
                        localAuthProof: grant.localAuthProof,
                        sourceDeviceId: grant.sourceDeviceID,
                        intentHashHex: grant.localAuthIntentHashHex,
                        localAuthGrantBinding: grant.localAuthGrantBinding
                    ),
                    concurrentSessionActive: concurrentSessionActive
                )
                // Publish atomically: if a concurrent first-call already created a
                // session while we awaited, prefer the stored id and let our
                // just-created session lapse via the daemon's idle-timeout GC. Keeps
                // the cached id deterministic under the rare concurrent-init race.
                sessionID = browserSessionIDBox.withLock { stored in
                    if let stored { return stored }
                    stored = response.sessionId
                    return response.sessionId
                }
            }
            if revocationRequestedBox.read() {
                await revokeDaemonBrowserSessionIfNeeded()
                return denied(name: invocation.tool.rawValue, reason: "desktop grant was revoked")
            }
            let response = try await OpenBurnBarDaemonManager.shared.invokeComputerUse(
                ComputerUseInvokeRequest(
                    sessionId: sessionID,
                    invocation: invocation,
                    localAuthProof: grant.localAuthProof,
                    sourceDeviceId: grant.sourceDeviceID,
                    intentHashHex: grant.localAuthIntentHashHex,
                    localAuthGrantBinding: grant.localAuthGrantBinding
                ),
                concurrentSessionActive: concurrentSessionActive
            )
            return Self.payload(name: invocation.tool.rawValue, response: response)
        } catch {
            return errorPayload(name: invocation.tool.rawValue, error: String(describing: error))
        }
        // cov:ignore-end
    }

    private func revokeDaemonBrowserSessionIfNeeded() async {
        // cov:ignore-start -- live daemon panic-halt/publish path; fallback ordering is covered by AgentToolBroker revokeDaemonBrowserSession tests.
        revocationRequestedBox.withLock { $0 = true }
        guard let sessionID = browserSessionIDBox.read() else { return }
        let outcome = await Self.revokeDaemonBrowserSession(
            sessionID: sessionID,
            publishRevocation: {
                let response = try await OpenBurnBarDaemonManager.shared.publishComputerUseCapabilityState(
                    authorizationRevoked: true
                )
                guard response.accepted else {
                    throw OpenBurnBarDaemonManagerError.rpcError(
                        "OpenBurnBar daemon rejected Computer Use authorization revocation."
                    )
                }
            },
            panicHalt: { sessionID in
                _ = try await OpenBurnBarDaemonManager.shared.panicHaltComputerUse(
                    ComputerUsePanicHaltRequest(
                        sessionId: sessionID,
                        source: ComputerUsePanicSource.revoked.rawValue
                    )
                )
            }
        )
        if outcome == .failed {
            AgentToolBroker.unrestrictedShellAudit.error(
                "computer_use_revocation_halt_failed session=\(sessionID, privacy: .private(mask: .hash))"
            )
            return
        }
        browserSessionIDBox.withLock { $0 = nil }
        // cov:ignore-end
    }

    static func revokeDaemonBrowserSession(
        sessionID: String,
        publishRevocation: @escaping @Sendable () async throws -> Void,
        panicHalt: @escaping @Sendable (String) async throws -> Void
    ) async -> DaemonBrowserRevocationOutcome {
        do {
            try await panicHalt(sessionID)
            return .panicHalted
        } catch {
            do {
                try await publishRevocation()
                return .statePublished
            } catch {
                return .failed
            }
        }
    }

    private func runShell(arguments: [String: Any]) async throws -> AgentToolExecutionPayload {
        let command = try requiredString("command", in: arguments)
        let requestedTimeout = (arguments["timeoutSeconds"] as? Int) ?? 30
        let timeout = max(1, min(requestedTimeout, 60))
        let invocation = try Self.workspaceSandboxedShellInvocation(
            command: command,
            workspaceURL: workspaceURL
        )
        let result = try await Self.runProcess(
            executable: invocation.executable,
            arguments: invocation.arguments,
            workingDirectory: workspaceURL,
            timeoutSeconds: timeout,
            environment: invocation.environment
        )
        return jsonPayload([
            "ok": result.exitCode == 0,
            "exitCode": result.exitCode,
            "stdout": String(result.stdout.prefix(20_000)),
            "stderr": String(result.stderr.prefix(20_000)),
            "timedOut": result.timedOut
        ], detail: command)
    }

    private func needsUnrestrictedShellReauth() -> Bool {
        unrestrictedShellCadenceBox.read().requiresReauthBeforeNextAction
    }

    private func recordUnrestrictedShellReauth() {
        unrestrictedShellCadenceBox.withLock { $0.recordReauth() }
    }

    private func recordUnrestrictedShellAction() {
        unrestrictedShellCadenceBox.withLock { $0.recordAction() }
    }

    private func runShellUnrestricted(arguments: [String: Any]) async throws -> AgentToolExecutionPayload {
        guard grant.trustMode == .trusted, grant.capabilities.contains(.shellUnrestricted) else {
            return denied(name: "shell_run_unrestricted", reason: "unrestricted shell requires YOLO trusted mode")
        }
        let command = try requiredString("command", in: arguments)
        let requestedTimeout = (arguments["timeoutSeconds"] as? Int) ?? 30
        let timeout = max(1, min(requestedTimeout, 120))

        // T-TOOL-02(b) / T-AI-07: per-N-action re-authorization. Even under YOLO,
        // the unrestricted shell may only run `unrestrictedShellReauthInterval`
        // commands before the operator must re-prove presence with a fresh local
        // auth. This bounds an obeyed prompt injection: it cannot run unbounded
        // shell because each re-auth checkpoint requires a human. We fail CLOSED
        // when no re-authorizer is wired or the proof is declined.
        if needsUnrestrictedShellReauth() {
            guard let reauthorizer = unrestrictedShellReauthorizer else {
                return denied(
                    name: "shell_run_unrestricted",
                    reason: "unrestricted shell requires periodic re-authorization but no local-auth is available"
                )
            }
            let summary = "Re-authorize unrestricted shell (YOLO) — next command: \(command.prefix(120))"
            let proven = await reauthorizer(String(summary))
            guard proven else {
                return denied(name: "shell_run_unrestricted", reason: "re-authorization declined")
            }
            recordUnrestrictedShellReauth()
        }
        recordUnrestrictedShellAction()

        // F3: unrestricted shell under YOLO runs unsandboxed at full user privilege.
        // It is the single highest agent-execution risk surface (a prompt injection
        // the model obeys can run arbitrary commands). The per-N-action re-auth gate
        // above bounds the blast radius; we ALSO ALWAYS leave a forensic record: a
        // command hash (never the plaintext, which may contain secrets), grant id,
        // and runtime, for post-incident attribution.
        let auditLine = "shell_run_unrestricted dispatched"
            + " grant=\(self.grant.grantID)"
            + " runtime=\(self.grant.runtimeID.rawValue)"
            + " cmd_sha256=\(Self.commandAuditDigest(command))"
            + " cmd_len=\(command.count)"
        Self.unrestrictedShellAudit.warning("\(auditLine, privacy: .public)")
        let result = try await Self.runProcess(
            executable: "/bin/zsh",
            arguments: ["-f", "-lc", command],
            workingDirectory: workspaceURL,
            timeoutSeconds: timeout
        )
        return jsonPayload([
            "ok": result.exitCode == 0,
            "exitCode": result.exitCode,
            "stdout": String(result.stdout.prefix(20_000)),
            "stderr": String(result.stderr.prefix(20_000)),
            "timedOut": result.timedOut
        ], detail: command)
    }

    private struct ProcessResult {
        let exitCode: Int
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private struct ShellInvocation {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
    }

    private static func workspaceSandboxedShellInvocation(
        command: String,
        workspaceURL: URL
    ) throws -> ShellInvocation {
        let sandboxExecutable = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandboxExecutable) else {
            throw NSError(domain: "AgentToolBroker", code: 5, userInfo: [NSLocalizedDescriptionKey: "Shell sandbox is unavailable"])
        }

        let workspacePath = canonicalFileURL(workspaceURL).path
        let profile = restrictedShellSandboxProfile(workspacePath: workspacePath)
        return ShellInvocation(
            executable: sandboxExecutable,
            arguments: ["-p", profile, "/bin/zsh", "-f", "-lc", command],
            environment: restrictedShellEnvironment(workspacePath: workspacePath)
        )
    }
    static func canonicalFileURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        #if canImport(Darwin)
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
        }
        #endif
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    private static func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        timeoutSeconds: Int,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            // M-040: do NOT inherit the full ambient parent environment. Both
            // broker shells routed here — the restricted sandbox-exec shell
            // (`shell_run`) and the unrestricted YOLO `/bin/zsh -f -lc`
            // (`shell_run_unrestricted`) must never inherit every app/daemon-held
            // secret from the parent process. Restricted sandbox invocations pass a
            // tighter deterministic environment; unrestricted invocations default
            // to the shared allowlisted baseline.
            process.environment = environment ?? AgentChildProcessEnvironment.allowlistedBaseline()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            final class Box: Sendable {
                private struct State {
                    var resumed = false
                    var timedOut = false
                    var stdoutData = Data()
                    var stderrData = Data()
                }

                private let captureLimit = 200_000
                private let state = Locked(State())

                func append(_ data: Data, toStdout: Bool) {
                    guard !data.isEmpty else { return }
                    state.withLock { state in
                        if toStdout {
                            appendBounded(data, to: &state.stdoutData)
                        } else {
                            appendBounded(data, to: &state.stderrData)
                        }
                    }
                }

                private func appendBounded(_ data: Data, to target: inout Data) {
                    guard target.count < captureLimit else { return }
                    let remaining = captureLimit - target.count
                    target.append(data.prefix(remaining))
                }

                func markTimedOutIfStillRunning(_ process: Process) -> Bool {
                    state.withLock { state in
                        let shouldTerminate = !state.resumed && process.isRunning
                        if shouldTerminate {
                            state.timedOut = true
                        }
                        return shouldTerminate
                    }
                }

                /// Atomically marks the process result consumed (returns nil if a
                /// prior caller already resumed) and returns the captured output.
                func completeIfNotYetResumed() -> (timedOut: Bool, stdout: Data, stderr: Data)? {
                    state.withLock { state in
                        guard !state.resumed else { return nil }
                        state.resumed = true
                        return (state.timedOut, state.stdoutData, state.stderrData)
                    }
                }
            }
            let box = Box()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                box.append(handle.availableData, toStdout: true)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                box.append(handle.availableData, toStdout: false)
            }
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                box.append(stdout.fileHandleForReading.readDataToEndOfFile(), toStdout: true)
                box.append(stderr.fileHandleForReading.readDataToEndOfFile(), toStdout: false)
                guard let completion = box.completeIfNotYetResumed() else {
                    return
                }
                continuation.resume(returning: ProcessResult(
                    exitCode: Int(process.terminationStatus),
                    stdout: String(decoding: completion.stdout, as: UTF8.self),
                    stderr: String(decoding: completion.stderr, as: UTF8.self),
                    timedOut: completion.timedOut
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds)) // try?-ok(cancellation only)
                if box.markTimedOutIfStillRunning(process) {
                    process.terminate()
                }
            }
        }
    }
}

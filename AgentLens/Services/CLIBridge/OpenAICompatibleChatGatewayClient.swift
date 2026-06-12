import CryptoKit
import Foundation
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

final class AgentToolBroker: @unchecked Sendable {
    let grant: AgentCapabilityGrant
    let workspaceURL: URL
    #if canImport(AppKit) && !DISTRIBUTION_MAS
    weak var computerUseRuntimeController: ComputerUseRuntimeController?
    #endif
    private let grantStillActive: (@Sendable () async -> Bool)?

    /// Human-in-the-loop gate invoked before a **privileged** broker tool
    /// (shell / workspace write / desktop export) runs in a non-trusted grant.
    /// Returns `true` to allow. When `nil`, privileged tools FAIL CLOSED — there
    /// is no silent privileged execution under an active grant (finding A1).
    typealias PrivilegedActionApprover = @Sendable (_ toolName: String, _ summary: String) async -> Bool
    private let privilegedActionApprover: PrivilegedActionApprover?

    /// Broker tools that perform privileged side effects (shell exec, writes,
    /// exfiltration-capable export). Each requires explicit per-action approval
    /// in every grant mode except `.trusted` (YOLO), which already required a
    /// local-auth proof + Mac approval at grant time and opted into autonomy.
    static let approvalGatedTools: Set<String> = [
        "shell_run", "workspace_write_file", "desktop_export_file"
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

    private var browserSessionID: String?

    private enum WorkspaceAccessMode {
        case read
        case write
    }

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
        self.computerUseRuntimeController = computerUseRuntimeController
    }

    init(
        grant: AgentCapabilityGrant,
        workspaceURL: URL,
        computerUseRuntimeController: ComputerUseRuntimeController? = nil,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        privilegedActionApprover: PrivilegedActionApprover?
    ) {
        self.grant = grant
        self.workspaceURL = Self.canonicalFileURL(workspaceURL)
        self.grantStillActive = grantStillActive
        self.privilegedActionApprover = privilegedActionApprover
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        self.computerUseRuntimeController = computerUseRuntimeController
        #endif
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
    }

    init(
        grant: AgentCapabilityGrant,
        workspaceURL: URL,
        grantStillActive: (@Sendable () async -> Bool)? = nil,
        privilegedActionApprover: PrivilegedActionApprover?
    ) {
        self.grant = grant
        self.workspaceURL = Self.canonicalFileURL(workspaceURL)
        self.grantStillActive = grantStillActive
        self.privilegedActionApprover = privilegedActionApprover
    }
    #endif

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
        guard grant.isActive() else {
            return denied(name: name, reason: "desktop grant is not active")
        }
        if let grantStillActive {
            let stillActive = await grantStillActive()
            guard stillActive else {
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
            // A1: privileged broker tools require explicit per-action approval
            // unless this is a trusted (YOLO) grant. Fail closed when no
            // approver is wired — never execute a privileged tool silently.
            if Self.approvalGatedTools.contains(name), grant.trustMode != .trusted {
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
        do {
            let sessionID: String
            if let browserSessionID {
                sessionID = browserSessionID
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
                        runID: invocation.runID
                    )
                )
                browserSessionID = response.sessionId
                sessionID = response.sessionId
            }
            let response = try await OpenBurnBarDaemonManager.shared.invokeComputerUse(
                ComputerUseInvokeRequest(sessionId: sessionID, invocation: invocation)
            )
            return Self.payload(name: invocation.tool.rawValue, response: response)
        } catch {
            return errorPayload(name: invocation.tool.rawValue, error: String(describing: error))
        }
    }

    private func readWorkspaceFile(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let path = try requiredString("path", in: arguments)
        let url = try workspaceFileURL(path, mode: .read)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data.prefix(200_000), as: UTF8.self)
        return jsonPayload([
            "ok": true,
            "path": path,
            "truncated": data.count > 200_000,
            "content": text
        ], detail: path)
    }

    private func listWorkspaceFiles(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let path = (arguments["path"] as? String) ?? "."
        let limit = max(1, min((arguments["limit"] as? Int) ?? 200, 500))
        let root = try workspaceFileURL(path, mode: .read)
        var rows: [[String: Any]] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: keys)
                rows.append([
                    "path": relativeWorkspacePath(for: fileURL),
                    "isDirectory": values?.isDirectory ?? false,
                    "sizeBytes": values?.fileSize ?? 0
                ])
                if rows.count >= limit { break }
            }
        }
        return jsonPayload(["ok": true, "root": path, "files": rows], detail: "\(rows.count) files")
    }

    private func writeWorkspaceFile(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let path = try requiredString("path", in: arguments)
        guard let content = arguments["content"] as? String else {
            throw NSError(domain: "AgentToolBroker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing required string: content"])
        }
        let append = (arguments["append"] as? Bool) ?? false
        let url = try workspaceFileURL(path, mode: .write)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(content.utf8)
        if append, FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
        return jsonPayload(["ok": true, "path": path, "bytesWritten": data.count], detail: path)
    }

    private func exportDesktopFile(arguments: [String: Any]) throws -> AgentToolExecutionPayload {
        let sourcePath = try requiredString("sourcePath", in: arguments)
        let sourceURL = try workspaceFileURL(sourcePath, mode: .read)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NSError(domain: "AgentToolBroker", code: 6, userInfo: [NSLocalizedDescriptionKey: "Source file does not exist or is a directory"])
        }

        let requestedName = (arguments["targetName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = Self.safeDesktopFilename(requestedName?.nonEmpty ?? sourceURL.lastPathComponent)
        let safeThread = Self.safeDesktopFilename(grant.threadID)
        let dropDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("OpenBurnBar Agent Drops", isDirectory: true)
            .appendingPathComponent(safeThread, isDirectory: true)
        try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
        let destinationURL = dropDirectory.appendingPathComponent(filename, isDirectory: false)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return jsonPayload([
            "ok": true,
            "sourcePath": sourcePath,
            "desktopPath": destinationURL.path,
            "bytesCopied": (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        ], detail: destinationURL.path)
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

    private func runShellUnrestricted(arguments: [String: Any]) async throws -> AgentToolExecutionPayload {
        guard grant.trustMode == .trusted, grant.capabilities.contains(.shellUnrestricted) else {
            return denied(name: "shell_run_unrestricted", reason: "unrestricted shell requires YOLO trusted mode")
        }
        let command = try requiredString("command", in: arguments)
        let requestedTimeout = (arguments["timeoutSeconds"] as? Int) ?? 30
        let timeout = max(1, min(requestedTimeout, 120))
        // F3: unrestricted shell under YOLO runs unsandboxed at full user privilege
        // and skips the per-action approver by design. It is the single highest
        // agent-execution risk surface (a prompt injection the model obeys can run
        // arbitrary commands). We cannot block it without defeating YOLO's purpose,
        // but we ALWAYS leave a forensic record: a command hash (never the plaintext,
        // which may contain secrets), grant id, and runtime. This gives post-incident
        // attribution and is the audit-trail half of the F3 control; a per-N-action
        // re-auth UX is the tracked follow-up.
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

    private func workspaceFileURL(_ relativePath: String, mode: WorkspaceAccessMode) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw NSError(domain: "AgentToolBroker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path must be workspace-relative"])
        }
        let candidate = workspaceURL.appendingPathComponent(trimmed).standardizedFileURL
        guard isInsideWorkspace(candidate) else {
            throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
        }
        switch mode {
        case .read:
            let resolved = Self.canonicalFileURL(candidate)
            guard isInsideWorkspace(resolved) else {
                throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
            }
            return resolved
        case .write:
            if FileManager.default.fileExists(atPath: candidate.path) {
                let resolved = Self.canonicalFileURL(candidate)
                guard isInsideWorkspace(resolved) else {
                    throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
                }
                return resolved
            }

            let nearestAncestor = nearestExistingAncestor(for: candidate.deletingLastPathComponent())
            let resolvedAncestor = Self.canonicalFileURL(nearestAncestor)
            guard isInsideWorkspace(resolvedAncestor) else {
                throw NSError(domain: "AgentToolBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path escapes the chat workspace"])
            }
            return candidate
        }
    }

    private func relativeWorkspacePath(for url: URL) -> String {
        let root = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        guard url.path.hasPrefix(root) else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count))
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let rootPath = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        return url.path == workspaceURL.path || url.path.hasPrefix(rootPath)
    }

    private func nearestExistingAncestor(for url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return workspaceURL
            }
            current = parent
        }
        return current
    }

    private func requiredString(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw NSError(domain: "AgentToolBroker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing required string: \(key)"])
        }
        return value
    }

    /// Human-readable, one-line description of a privileged tool call, shown to
    /// the operator in the approval prompt so consent is informed (not blind).
    static func approvalSummary(tool: String, arguments: [String: Any]) -> String {
        switch tool {
        case "shell_run":
            let command = (arguments["command"] as? String) ?? "(missing command)"
            return "Run shell command: \(command)"
        case "workspace_write_file":
            let path = (arguments["path"] as? String) ?? "(missing path)"
            let append = (arguments["append"] as? Bool) ?? false
            return "\(append ? "Append to" : "Write") workspace file: \(path)"
        case "desktop_export_file":
            let source = (arguments["sourcePath"] as? String) ?? "(missing source)"
            return "Export \(source) to your Desktop"
        default:
            return tool
        }
    }

    private func denied(name: String, reason: String) -> AgentToolExecutionPayload {
        jsonPayload(["ok": false, "tool": name, "status": "denied", "reason": reason], detail: reason)
    }

    private func errorPayload(name: String, error: String) -> AgentToolExecutionPayload {
        jsonPayload(["ok": false, "tool": name, "status": "error", "error": error], detail: error)
    }

    private func jsonPayload(_ object: [String: Any], detail: String?) -> AgentToolExecutionPayload {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return AgentToolExecutionPayload(content: String(decoding: data, as: UTF8.self), detail: detail)
    }

    static func payload(name: String, response: ComputerUseInvokeResponse) -> AgentToolExecutionPayload {
        var object: [String: Any] = [
            "ok": response.status == .executed,
            "tool": name,
            "status": response.status.rawValue,
            "sessionId": response.sessionId
        ]
        if let approvalId = response.approvalId { object["approvalId"] = approvalId }
        if let denyReason = response.denyReason { object["denyReason"] = denyReason }
        if let auditEntryIndex = response.auditEntryIndex { object["auditEntryIndex"] = auditEntryIndex }
        if let auditHeadHashHex = response.auditHeadHashHex { object["auditHeadHashHex"] = auditHeadHashHex }
        if let result = response.result {
            let jsonResult = jsonObject(from: result.output)
            object["result"] = shouldWrapUntrustedComputerUseResult(toolName: name)
                ? wrappedUntrustedComputerUseResult(jsonResult, toolName: name)
                : jsonResult
            object["succeeded"] = result.succeeded
            object["errorMessage"] = result.errorMessage
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let detail = response.denyReason ?? response.status.rawValue
        return AgentToolExecutionPayload(content: String(decoding: data, as: UTF8.self), detail: detail)
    }

    private static func shouldWrapUntrustedComputerUseResult(toolName: String) -> Bool {
        toolName == BurnBarToolKind.browserExtract.rawValue
            || toolName == BurnBarToolKind.macInspectAccessibility.rawValue
    }

    private static func wrappedUntrustedComputerUseResult(_ result: Any, toolName: String) -> [String: Any] {
        [
            "contentFormat": "json",
            "provenance": "computer_use_tool_result:\(toolName)",
            "untrustedContent": LLMSafeContent.wrapUntrusted(
                jsonString(from: result),
                provenance: "computer_use_tool_result:\(toolName)"
            )
        ]
    }

    private static func jsonString(from value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value) {
            do {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            } catch {
                return String(describing: value)
            }
        }
        if value is NSNull {
            return "null"
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }

    private static func jsonObject(from value: BurnBarJSONValue?) -> Any {
        guard let value else { return NSNull() }
        switch value {
        case .string(let string): return string
        case .number(let double): return double
        case .object(let object): return object.mapValues { jsonObject(from: $0) }
        case .array(let array): return array.map { jsonObject(from: $0) }
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }

    private static func jsonObject(fromArguments arguments: String) throws -> [String: Any] {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func burnBarJSONValue(fromArguments arguments: String) throws -> BurnBarJSONValue {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .object([:]) }
        return try jsonValue(from: JSONSerialization.jsonObject(with: Data(trimmed.utf8)))
    }

    private static func jsonValue(from any: Any) throws -> BurnBarJSONValue {
        switch any {
        case let object as [String: Any]:
            var mapped: [String: BurnBarJSONValue] = [:]
            for (key, value) in object {
                mapped[key] = try jsonValue(from: value)
            }
            return .object(mapped)
        case let array as [Any]:
            return .array(try array.map { try jsonValue(from: $0) })
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case _ as NSNull:
            return .null
        default:
            throw NSError(domain: "AgentToolBroker", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value"])
        }
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
            arguments: ["-p", profile, "/bin/zsh", "-f", "-lc", command]
        )
    }

    /// Seatbelt profile for the **restricted** agent shell (`shell_run`).
    ///
    /// A prior version was `(allow default)` with only an out-of-workspace
    /// *write* deny. That left intact the exact two primitives a prompt-injection
    /// payload needs to turn an active shell grant into data exfiltration / RCE:
    /// unrestricted outbound **network** (the exfil channel) and **reads** of
    /// every secret store on disk (`~/.ssh`, Messages, Keychains, browser
    /// profiles, …). This profile removes both while keeping ordinary local dev
    /// tooling working:
    ///   * `(deny network*)` — no outbound/inbound network from the restricted
    ///     shell, so a `curl … | sh` / `… | curl -d @-` exfil cannot reach the
    ///     wire. Network-dependent work belongs in the trusted (`shell_run_
    ///     unrestricted`) path the operator explicitly opts into.
    ///   * writes stay confined to the workspace (unchanged guarantee).
    ///   * reads of well-known credential / private-data stores are denied.
    /// Seatbelt evaluates the first matching operation rule here, so narrow
    /// denies and workspace/device write allows must appear before the catch-all
    /// `(allow default)`.
    static func restrictedShellSandboxProfile(
        workspacePath: String,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let canonicalWorkspacePath = canonicalSandboxPath(workspacePath)
        let canonicalHomePath = canonicalSandboxPath(homePath)
        let ws = escapeSandboxProfileString(canonicalWorkspacePath)
        // High-value secret / private-data stores. Reads are denied even though
        // general reads stay allowed (so dev tooling keeps reading system libs,
        // configs, etc.). Defense-in-depth behind `(deny network*)`.
        let secretSubpaths = [
            "/.ssh", "/.aws", "/.gnupg", "/.config/gh", "/.config/gcloud",
            "/.kube", "/.docker", "/.azure", "/.config/op",
            "/.terraform.d", "/.cloudflared", "/.config/git",
            "/Library/Keychains", "/Library/Messages", "/Library/Mail",
            "/Library/Cookies", "/Library/HTTPStorages", "/Library/Safari",
            "/Library/Application Support/Google/Chrome",
            "/Library/Application Support/Firefox",
            "/Library/Application Support/BraveSoftware",
            "/Library/Application Support/Slack",
            "/Library/Application Support/com.apple.sharedfilelist",
            // F9: deny the restricted agent shell read access to OpenBurnBar's OWN
            // on-disk state (encrypted DB, replay counters, audit chain, queued
            // grants, cloud-vault fallbacks). A prompt-injected `shell_run` must not
            // be able to read the app's secrets just because they're not Keychain
            // items. Dev tooling never needs to read these.
            "/Library/Application Support/com.openburnbar.AgentLens",
            "/.openburnbar",
            "/.config/openburnbar"
        ].map { canonicalHomePath + $0 }
        let secretLiterals = [
            "/.netrc", "/.npmrc", "/.pypirc", "/.git-credentials",
            // F9: common credential files that live at the home root.
            "/.env", "/.envrc",
            "/.cargo/credentials", "/.cargo/credentials.toml",
            "/.gem/credentials", "/.config/configstore/firebase-tools.json"
        ].map { canonicalHomePath + $0 }

        var lines: [String] = [
            "(version 1)",
            "(deny network*)",
            "(allow file-read* (subpath \"\(ws)\"))",
            "(allow file-write* (subpath \"\(ws)\"))"
        ]
        // Re-allow only the null/stdio device nodes so ordinary redirects keep
        // working (`… 2>/dev/null`). Writes otherwise stay strictly confined to
        // the workspace — the anti-persistence guarantee that blocks ~/.ssh,
        // LaunchAgents, and shell rc files. Temp dirs are intentionally NOT
        // re-allowed (that would broaden writes and defeat confinement); tools
        // can use the workspace as scratch.
        for device in ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"] {
            lines.append("(allow file-write* (literal \"\(device)\"))")
        }
        lines.append("(allow file-write* (subpath \"/dev/fd\"))")
        for path in secretSubpaths {
            lines.append("(deny file-read* (subpath \"\(escapeSandboxProfileString(path))\"))")
        }
        for path in secretLiterals {
            lines.append("(deny file-read* (literal \"\(escapeSandboxProfileString(path))\"))")
        }
        lines.append("(deny file-write* (require-not (subpath \"\(ws)\")))")
        lines.append("(allow default)")
        return lines.joined(separator: "\n")
    }

    private static func canonicalSandboxPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(standardized, &buffer) != nil {
            return String(cString: buffer)
        }
        #endif
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    private static func escapeSandboxProfileString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        #if canImport(Darwin)
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
        }
        #endif
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func safeDesktopFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines)
        let components = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
        let joined = components.joined(separator: "-")
        let clipped = String(joined.prefix(96)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.nonEmpty ?? "agent-file"
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        timeoutSeconds: Int
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            final class Box: @unchecked Sendable {
                private let captureLimit = 200_000
                let lock = NSLock()
                var resumed = false
                var timedOut = false
                var stdoutData = Data()
                var stderrData = Data()

                func append(_ data: Data, toStdout: Bool) {
                    guard !data.isEmpty else { return }
                    lock.lock()
                    defer { lock.unlock() }
                    if toStdout {
                        appendBounded(data, to: &stdoutData)
                    } else {
                        appendBounded(data, to: &stderrData)
                    }
                }

                private func appendBounded(_ data: Data, to target: inout Data) {
                    guard target.count < captureLimit else { return }
                    let remaining = captureLimit - target.count
                    target.append(data.prefix(remaining))
                }

                func markTimedOutIfStillRunning(_ process: Process) -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    let shouldTerminate = !resumed && process.isRunning
                    if shouldTerminate {
                        timedOut = true
                    }
                    return shouldTerminate
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
                box.lock.lock()
                guard !box.resumed else {
                    box.lock.unlock()
                    return
                }
                box.resumed = true
                let timedOut = box.timedOut
                let out = box.stdoutData
                let err = box.stderrData
                box.lock.unlock()
                continuation.resume(returning: ProcessResult(
                    exitCode: Int(process.terminationStatus),
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self),
                    timedOut: timedOut
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if box.markTimedOutIfStillRunning(process) {
                    process.terminate()
                }
            }
        }
    }
}

enum OpenAICompatibleModelProbe {
    static func modelsURL(baseURL: URL) -> URL? {
        URL(string: "v1/models", relativeTo: baseURL)?.absoluteURL
    }

    static func modelsRequest(baseURL: URL, bearerToken: String?, timeout: TimeInterval = 2) -> URLRequest? {
        guard let url = modelsURL(baseURL: baseURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func probe(baseURL: URL, bearerToken: String?, timeout: TimeInterval = 2, session: URLSession = .shared) async -> Bool {
        await probeWithModel(baseURL: baseURL, bearerToken: bearerToken, timeout: timeout, session: session).available
    }

    static func probeWithModel(
        baseURL: URL,
        bearerToken: String?,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> (available: Bool, modelName: String?) {
        let result = await probeWithModels(baseURL: baseURL, bearerToken: bearerToken, timeout: timeout, session: session)
        return (result.available, result.modelName)
    }

    static func probeWithModels(
        baseURL: URL,
        bearerToken: String?,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> (available: Bool, modelName: String?, hermesModels: [HermesAdvertisedModel], models: [OpenAICompatibleAdvertisedModel]) {
        guard let request = modelsRequest(baseURL: baseURL, bearerToken: bearerToken, timeout: timeout) else {
            return (false, nil, [], [])
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return (false, nil, [], []) }
            return (
                true,
                OpenAICompatibleModelListParser.modelName(from: data),
                OpenAICompatibleModelListParser.hermesAdvertisedModels(from: data),
                OpenAICompatibleModelListParser.advertisedModels(from: data)
            )
        } catch {
            return (false, nil, [], [])
        }
    }
}

struct OpenAICompatibleChatGatewayClient: Sendable {
    let runtime: CLIBridgeStreamRuntimeCoordinator

    /// Shared SSE path for Hermes gateway API and OpenClaw gateway (OpenAI-compatible).
    func runStream(
        baseURL: URL,
        model: String,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        unavailableError: CLIBridgeError,
        missingModelError: CLIBridgeError,
        httpStreamID: UInt64,
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil,
        toolBroker: AgentToolBroker? = nil,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        defer {
            Task.detached { [runtime] in
                await runtime.clearHTTPStreamTask(streamID: httpStreamID)
            }
        }

        guard let url = URL(string: "v1/chat/completions", relativeTo: baseURL)?.absoluteURL else {
            continuation.finish(throwing: unavailableError)
            return
        }

        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else {
            continuation.finish(throwing: missingModelError)
            return
        }

        let messages = Self.buildMessages(
            systemPrompt: systemPrompt,
            history: history,
            attachmentBytes: attachmentBytes,
            capabilities: capabilities,
            workspaceURL: workspaceURL
        )

        // Phase 4 — AgentLens-plane budget gate. Subscription credentials short-circuit
        // inside BudgetGate so flat-rate plans never get blocked here. Gate runs before
        // the URLRequest leaves the host so a blocked call never reaches the upstream.
        let credential = AgentLensCredentialIdentity.make(
            providerHint: baseURL.host?.lowercased() ?? "agentlens_gateway",
            bearerToken: bearerToken,
            displayLabel: baseURL.host ?? selectedModel
        )
        let estimatedInputChars = messages.reduce(0) { acc, msg in
            acc + (msg["content"] as? String ?? "").count
        }
        let estimatedCost = await MainActor.run {
            BudgetEnforcement.estimateCost(
                model: selectedModel,
                inputCharacters: estimatedInputChars + systemPrompt.count
            )
        }
        let decision = await BudgetEnforcement.shared.evaluate(
            credential: credential,
            estimatedCost: estimatedCost
        )
        switch decision {
        case .block(let rule, let used, let limit, let fallback):
            continuation.finish(throwing: BudgetBlockedError(
                rule: rule,
                used: used,
                limit: limit,
                fallback: fallback,
                resetAt: rule.period.nextReset()
            ))
            return
        case .allow, .warn, .paused:
            break
        }

        if let toolBroker, toolBroker.isActive, !toolBroker.openAITools.isEmpty {
            await Self.runToolEnabledLoop(
                url: url,
                messages: messages,
                model: selectedModel,
                session: URLSession(configuration: .default),
                bearerToken: bearerToken,
                toolBroker: toolBroker,
                continuation: continuation
            )
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var streamedAnyContent = false
        var parser = OpenAICompatibleSSEParser()
        do {
            let body: [String: Any] = [
                "model": selectedModel,
                "stream": true,
                "messages": messages,
                "stream_options": ["include_usage": true]
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let detail = try await Self.errorDetail(
                    statusCode: http.statusCode,
                    lines: bytes.lines
                )
                continuation.finish(throwing: CLIBridgeError.hermesSSEError(detail))
                return
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()

                let result = parser.events(fromLine: line)
                for event in result.events {
                    continuation.yield(event)
                }
                if result.streamedText {
                    streamedAnyContent = true
                }
                if result.done {
                    break
                }
            }
        } catch is CancellationError {
            continuation.finish()
            return
        } catch {
            continuation.finish(throwing: error)
            return
        }

        if !streamedAnyContent {
            do {
                try Task.checkCancellation()
                let content = try await Self.nonStreamingFallback(
                    url: url,
                    messages: messages,
                    model: selectedModel,
                    session: session,
                    bearerToken: bearerToken
                )
                if !content.content.isEmpty {
                    continuation.yield(.text(content.content))
                }
                if let usage = content.usage {
                    continuation.yield(.usage(usage))
                }
            } catch is CancellationError {
                // Stream cancellation is a normal user action.
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }

        continuation.finish()
    }

    struct OpenAIToolCall: Equatable {
        let id: String
        let name: String
        let arguments: String
    }

    static func runToolEnabledLoop(
        url: URL,
        messages originalMessages: [[String: Any]],
        model: String,
        session: URLSession,
        bearerToken: String?,
        toolBroker: AgentToolBroker,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation,
        maxToolCalls: Int = 24
    ) async {
        defer { session.invalidateAndCancel() }
        var messages = originalMessages
        var totalToolCalls = 0

        do {
            while true {
                try Task.checkCancellation()
                var body: [String: Any] = [
                    "model": model,
                    "stream": false,
                    "messages": messages
                ]
                if totalToolCalls < maxToolCalls {
                    body["tools"] = toolBroker.openAITools
                    body["tool_choice"] = "auto"
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.finish(throwing: CLIBridgeError.hermesSSEError(Self.errorDetail(statusCode: http.statusCode, data: data)))
                    return
                }

                let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if let usage = OpenAICompatibleUsageParser.usage(from: obj) {
                    continuation.yield(.usage(usage))
                }

                let toolCalls = extractOpenAIToolCalls(from: obj)
                if toolCalls.isEmpty {
                    if let content = extractAssistantContent(from: obj), !content.isEmpty {
                        continuation.yield(.text(content))
                    }
                    continuation.finish()
                    return
                }

                messages.append(buildOpenAIAssistantMessage(from: obj))

                for call in toolCalls {
                    guard totalToolCalls < maxToolCalls else { break }
                    totalToolCalls += 1
                    let detail = summarizeToolArguments(call.arguments)
                    continuation.yield(.toolUse(name: call.name, detail: detail))
                    let result = await toolBroker.invokeOpenAITool(
                        name: call.name,
                        arguments: call.arguments,
                        callID: call.id,
                        runID: "chat-tools-\(UUID().uuidString)"
                    )
                    continuation.yield(.toolResult(name: call.name, detail: result.detail))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": result.content
                    ])
                }

                if totalToolCalls >= maxToolCalls {
                    messages.append([
                        "role": "system",
                        "content": "The desktop tool-call budget for this response is exhausted. Finish with the information already gathered."
                    ])
                }
            }
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    static func extractOpenAIToolCalls(from obj: [String: Any]) -> [OpenAIToolCall] {
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return toolCalls.compactMap { raw in
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.isEmpty else {
                return nil
            }
            let id = (raw["id"] as? String) ?? "tool-\(UUID().uuidString)"
            let arguments: String
            if let string = function["arguments"] as? String {
                arguments = string
            } else if let object = function["arguments"] {
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
                arguments = String(decoding: data, as: UTF8.self)
            } else {
                arguments = "{}"
            }
            return OpenAIToolCall(id: id, name: name, arguments: arguments)
        }
    }

    static func buildOpenAIAssistantMessage(from obj: [String: Any]) -> [String: Any] {
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return ["role": "assistant", "content": ""]
        }
        var assistant: [String: Any] = [
            "role": "assistant",
            "content": message["content"] ?? NSNull()
        ]
        if let toolCalls = message["tool_calls"] {
            assistant["tool_calls"] = toolCalls
        }
        return assistant
    }

    static func extractAssistantContent(from obj: [String: Any]) -> String? {
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message["content"] as? String
    }

    private static func summarizeToolArguments(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["path", "command", "url", "selector", "text", "key", "value"] {
                if let value = obj[key] as? String, !value.isEmpty {
                    return String(value.prefix(160))
                }
            }
        }
        return String(trimmed.prefix(160))
    }

    static func nonStreamingFallback(
        url: URL,
        messages: [[String: Any]],
        model: String,
        session: URLSession,
        bearerToken: String?
    ) async throws -> (content: String, usage: CLIUsageSnapshot?) {
        let body: [String: Any] = ["model": model, "stream": false, "messages": messages]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CLIBridgeError.hermesSSEError(Self.errorDetail(statusCode: http.statusCode, data: data))
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return ("", OpenAICompatibleUsageParser.usage(from: obj))
        }

        return (content, OpenAICompatibleUsageParser.usage(from: obj))
    }

    private static func errorDetail<Lines: AsyncSequence>(
        statusCode: Int,
        lines: Lines
    ) async throws -> String where Lines.Element == String {
        var chunks: [String] = []
        for try await line in lines {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            chunks.append(trimmed)
            if chunks.joined(separator: "\n").count > 4096 { break }
        }
        let text = chunks.joined(separator: "\n")
        guard !text.isEmpty else { return "HTTP \(statusCode)" }
        if let data = text.data(using: .utf8) {
            return errorDetail(statusCode: statusCode, data: data)
        }
        return "HTTP \(statusCode): \(text)"
    }

    private static func errorDetail(statusCode: Int, data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let parsed = parsedErrorMessage(from: data)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parsed.isEmpty {
            if parsed.localizedCaseInsensitiveContains("HTTP \(statusCode)") {
                return parsed
            }
            return "HTTP \(statusCode): \(parsed)"
        }
        guard !text.isEmpty else { return "HTTP \(statusCode)" }
        return "HTTP \(statusCode): \(text)"
    }

    private static func parsedErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = obj["error"] as? String {
            return error
        }
        if let error = obj["error"] as? [String: Any] {
            return (error["message"] as? String)
                ?? (error["detail"] as? String)
                ?? (error["code"] as? String)
        }
        if let message = obj["message"] as? String {
            return message
        }
        if let detail = obj["detail"] as? String {
            return detail
        }
        if let hermes = obj["hermes"] as? [String: Any],
           let error = hermes["error"] as? String {
            return error
        }
        return nil
    }

    /// Builds the OpenAI-compatible `messages` array. When attachments are
    /// present anywhere in the history, the user-message bodies switch to the
    /// multimodal `content: [parts]` shape. Pure-text histories keep the
    /// legacy `{role, content: String}` form so older relays don't choke on
    /// unknown content types.
    static func buildMessages(
        systemPrompt: String,
        history: [ChatMessageRecord],
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil
    ) -> [[String: Any]] {
        let encoderMessages = history.compactMap { msg -> HermesAttachmentEncoder.Message? in
            let role: HermesAttachmentEncoder.Message.Role
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: return nil
            }
            // Pull this message's worth of attachment bytes from the caller-
            // supplied map (only the latest user message normally provides
            // bytes; persisted history attaches by metadata only).
            var msgBytes: [String: Data] = [:]
            for att in msg.attachments {
                if let data = attachmentBytes[att.id] {
                    msgBytes[att.id] = data
                }
            }
            return HermesAttachmentEncoder.Message(
                role: role,
                text: msg.content,
                attachments: msg.attachments,
                attachmentBytes: msgBytes
            )
        }
        return HermesAttachmentEncoder.encodeMessages(
            systemPrompt: systemPrompt,
            messages: encoderMessages,
            capabilities: capabilities,
            workspaceAbsolutePath: { att in
                guard let workspaceURL else { return att.workspaceRelativePath }
                return workspaceURL.appendingPathComponent(att.workspaceRelativePath).path
            }
        )
    }
}

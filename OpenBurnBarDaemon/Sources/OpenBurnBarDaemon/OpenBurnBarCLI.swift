import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public struct BurnBarCLIRunner {
    public let client: any BurnBarCLIClient
    public let shellExecutor: any BurnBarCLIShellExecuting
    public let shellShimInstaller: any BurnBarCLIShellShimInstalling
    public let remoteUnlockCertificationStore: RemoteUnlockCertificationReportStore
    private let logger = BurnBarDaemonLogger(category: "cli-runner")

    public init(
        client: any BurnBarCLIClient,
        shellExecutor: (any BurnBarCLIShellExecuting)? = nil,
        shellShimInstaller: (any BurnBarCLIShellShimInstalling)? = nil,
        remoteUnlockCertificationStore: RemoteUnlockCertificationReportStore = RemoteUnlockCertificationReportStore()
    ) {
        self.client = client
        self.remoteUnlockCertificationStore = remoteUnlockCertificationStore
        let profileStore: any BurnBarSwitcherProfileStoreProviding
        do {
            let sqliteStore = try BurnBarSwitcherSQLiteProfileStore()
            profileStore = sqliteStore
        } catch {
            logger.silentFailure("sqlite_profile_store_init", error: error)
            profileStore = BurnBarEmptySwitcherProfileStore()
        }
        self.shellExecutor = shellExecutor ?? BurnBarCLIShellExecutor(profileStore: profileStore)
        self.shellShimInstaller = shellShimInstaller ?? BurnBarCLIShellShimInstaller()
    }

    public func run(arguments: [String]) throws -> String {
        let effectiveArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        guard let command = effectiveArguments.first else {
            return Self.usageText
        }

        switch command {
        case "help", "--help", "-h":
            return Self.usageText
        case "health":
            return formatHealth(try client.health())
        case "service":
            return try runServiceCommand(Array(effectiveArguments.dropFirst()))
        case "capabilities":
            return try runCapabilitiesCommand(Array(effectiveArguments.dropFirst()))
        case "diagnostics":
            return try runDiagnosticsCommand(Array(effectiveArguments.dropFirst()))
        case "subscribe":
            return try runSubscribeCommand(Array(effectiveArguments.dropFirst()))
        case "chat":
            return try runChatQueryCommand(Array(effectiveArguments.dropFirst()))
        case "activity":
            return try runActivityQueryCommand(Array(effectiveArguments.dropFirst()))
        case "subscription-resume":
            return try runSubscriptionResumeCommand(Array(effectiveArguments.dropFirst()))
        case "controller", "status":
            return formatControllerSummary(try client.controllerSummary(projectSlug: effectiveArguments.dropFirst().first))
        case "questions":
            return formatQuestions(try client.questions(projectSlug: effectiveArguments.dropFirst().first))
        case "followups":
            return formatFollowups(try client.followups(projectSlug: effectiveArguments.dropFirst().first))
        case "missions":
            return formatMissions(try client.missions(projectSlug: effectiveArguments.dropFirst().first))
        case "mission-approve":
            guard effectiveArguments.count >= 2 else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli mission-approve <missionID> [note]")
            }
            let mission = try client.approveMission(
                id: BurnBarMissionID(rawValue: effectiveArguments[1]),
                note: effectiveArguments.count > 2 ? effectiveArguments.dropFirst(2).joined(separator: " ") : nil
            )
            return "Approved \(mission.title) (\(mission.id.rawValue))."
        case "simulator-runs":
            return formatSimulatorRuns(try client.simulatorRuns(projectSlug: effectiveArguments.dropFirst().first))
        case "simulator-replay":
            guard effectiveArguments.count >= 2 else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli simulator-replay <runID>")
            }
            let run = try client.simulatorReplay(runID: BurnBarSimulatorRunID(rawValue: effectiveArguments[1]))
            return "Replayed \(run.scenarioName) (\(run.id.rawValue)) with \(run.emittedEvents.count) event(s)."
        case "search":
            let args = Array(effectiveArguments.dropFirst())
            let query = positionalArguments(args, optionNames: ["--cwd", "--limit"]).joined(separator: " ")
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli search <query> [--cwd path] [--limit N]")
            }
            return formatCodeSearch(
                try client.codeSearch(
                    query: query,
                    projectPath: optionValue("--cwd", in: args),
                    limit: Int(optionValue("--limit", in: args) ?? "") ?? 20
                )
            )
        case "recall":
            let args = Array(effectiveArguments.dropFirst())
            let query = positionalArguments(args, optionNames: ["--cwd", "--limit"]).joined(separator: " ")
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli recall <query> [--cwd path] [--limit N]")
            }
            return formatMemoryRecall(
                try client.memoryRecall(
                    query: query,
                    projectPath: optionValue("--cwd", in: args),
                    limit: Int(optionValue("--limit", in: args) ?? "") ?? 20
                )
            )
        case "index":
            let args = Array(effectiveArguments.dropFirst())
            let projectPath = optionValue("--cwd", in: args) ?? positionalArguments(args, optionNames: ["--cwd", "--max-files", "--max-file-bytes", "--storage-budget-bytes", "--poll-seconds"]).first
            let maxFiles = Int(optionValue("--max-files", in: args) ?? "") ?? 2_500
            let maxFileBytes = Int(optionValue("--max-file-bytes", in: args) ?? "") ?? 512_000
            let storageBudgetBytes = Int(optionValue("--storage-budget-bytes", in: args) ?? "")
            if args.contains("--watch") {
                return formatCodeWatch(
                    try client.codeWatch(
                        projectPath: projectPath,
                        maxFiles: maxFiles,
                        maxFileBytes: maxFileBytes,
                        storageBudgetBytes: storageBudgetBytes,
                        pollIntervalSeconds: Double(optionValue("--poll-seconds", in: args) ?? "") ?? 2.0
                    )
                )
            }
            return formatCodeIndex(
                try client.codeIndex(
                    projectPath: projectPath,
                    maxFiles: maxFiles,
                    maxFileBytes: maxFileBytes,
                    storageBudgetBytes: storageBudgetBytes
                )
            )
        case "config":
            let args = Array(effectiveArguments.dropFirst())
            return formatProjectMemoryConfig(try client.codeIndexStatus(projectPath: optionValue("--cwd", in: args)))
        case "healthcheck":
            let args = Array(effectiveArguments.dropFirst())
            let health = try client.health()
            let status = try client.codeIndexStatus(projectPath: optionValue("--cwd", in: args))
            return formatProjectMemoryHealthcheck(health: health, status: status)
        case "run":
            return try runRunCommand(Array(effectiveArguments.dropFirst()))
        case "resume":
            let (response, mode) = try runResumeCommand(effectiveArguments)
            return Self.formatRunResumeResponse(response, mode: mode)
        case "remote-unlock-certification":
            return try handleRemoteUnlockCertification(Array(effectiveArguments.dropFirst()))
        case "local-peer":
            return try handleLocalPeerCommand(Array(effectiveArguments.dropFirst()))
        case "devices":
            return try handleDevicesCommand(Array(effectiveArguments.dropFirst()))
        default:
            throw BurnBarCLIError.invalidCommand(command)
        }
    }

    public func invoke(
        arguments: [String],
        invokedExecutablePath: String?
    ) async throws -> BurnBarCLIInvocationResult {
        if let wrappedCLIRequest = wrappedCLIRequest(arguments: arguments, invokedExecutablePath: invokedExecutablePath) {
            let execution = try await shellExecutor.execute(wrappedCLIRequest)
            return BurnBarCLIInvocationResult(output: nil, exitCode: execution.exitCode)
        }

        let effectiveArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        if effectiveArguments.first == "install-shell-shims" {
            guard let invokedExecutablePath else {
                throw BurnBarCLIError.missingExecutablePath
            }
            let result = try shellShimInstaller.installShims(invokedExecutablePath: invokedExecutablePath)
            let pathHint = result.installDirectory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            let output = """
            Installed BurnBar shell shims: \(result.installedCommands.joined(separator: ", "))
            Add this directory to your PATH:
              export PATH="\(pathHint):$PATH"
            """
            return BurnBarCLIInvocationResult(output: output, exitCode: EXIT_SUCCESS)
        }

        if effectiveArguments.first == "service",
           effectiveArguments.dropFirst().first == "restart" {
            return BurnBarCLIInvocationResult(
                output: "service_restart=unsupported foreground_daemon=true",
                exitCode: 69
            )
        }

        if effectiveArguments.first == "resume" {
            let (response, mode) = try runResumeCommand(effectiveArguments)
            return BurnBarCLIInvocationResult(
                output: Self.formatRunResumeResponse(response, mode: mode),
                exitCode: response.kind == "error" ? EXIT_FAILURE : EXIT_SUCCESS
            )
        }

        if effectiveArguments.first == "activity",
           effectiveArguments.dropFirst().first == "replay" {
            guard effectiveArguments.count == 3, !effectiveArguments[2].hasPrefix("--") else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli activity replay <sourceID>")
            }
            let response = try client.runResume(
                sessionID: effectiveArguments[2],
                targetHarness: nil,
                targetModel: nil,
                mode: .print
            )
            return BurnBarCLIInvocationResult(
                output: try Self.jsonString(response),
                exitCode: response.kind == "error" ? EXIT_FAILURE : EXIT_SUCCESS
            )
        }

        if effectiveArguments.first == "claude-handoff" {
            return try runClaudeHandoff(Array(effectiveArguments.dropFirst()))
        }

        if effectiveArguments.first == "provider-bootstrap-claude" {
            return try runProviderBootstrapClaude()
        }

        if effectiveArguments.first == "audit-verify" {
            return try BurnBarCLIAuditVerify.run(arguments: Array(effectiveArguments.dropFirst()))
        }

        if effectiveArguments.first == "computer-use" {
            return try runComputerUseCommand(Array(effectiveArguments.dropFirst()))
        }

        return BurnBarCLIInvocationResult(output: try run(arguments: arguments), exitCode: EXIT_SUCCESS)
    }

    /// Execute the bounded Linux privacy RPC set through this installed,
    /// first-party CLI peer. The request is read from stdin so sensitive
    /// export passphrases never appear in process arguments or shell history.
    public func runPrivacyRPC(input: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: input)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: ["method", "params"]),
              let methodRaw = dictionary["method"] as? String,
              let method = BurnBarRPCMethod(rawValue: methodRaw) else {
            throw BurnBarCLIError.missingArgument("privacy-rpc input must contain a supported method and params object")
        }
        let allowed: Set<BurnBarRPCMethod> = [
            .linuxPrivacyInventory,
            .linuxPrivacyDeletionPreview,
            .linuxPrivacyDeletionExecute,
            .linuxPrivacyExport,
            .linuxPrivacyRetentionStatus,
            .linuxPrivacyRetentionApply
        ]
        guard allowed.contains(method) else {
            throw BurnBarCLIError.invalidCommand("privacy-rpc (methodRaw)")
        }
        let paramsObject = dictionary["params"] ?? [:]
        guard JSONSerialization.isValidJSONObject(paramsObject) else {
            throw BurnBarCLIError.missingArgument("privacy-rpc params must be a JSON object")
        }
        let paramsData = try JSONSerialization.data(withJSONObject: paramsObject)
        let decoder = JSONDecoder()
        do {
            switch method {
            case .linuxPrivacyInventory:
                return try Self.jsonString(client.linuxPrivacyInventory())
            case .linuxPrivacyDeletionPreview:
                return try Self.jsonString(client.linuxPrivacyDeletionPreview(
                    try decoder.decode(BurnBarLinuxPrivacyDeletionPreviewRequest.self, from: paramsData)
                ))
            case .linuxPrivacyDeletionExecute:
                return try Self.jsonString(client.linuxPrivacyDeletionExecute(
                    try decoder.decode(BurnBarLinuxPrivacyDeletionExecuteRequest.self, from: paramsData)
                ))
            case .linuxPrivacyExport:
                return try Self.jsonString(client.linuxPrivacyExport(
                    try decoder.decode(BurnBarLinuxPrivacyExportRequest.self, from: paramsData)
                ))
            case .linuxPrivacyRetentionStatus:
                return try Self.jsonString(client.linuxPrivacyRetentionStatus())
            case .linuxPrivacyRetentionApply:
                return try Self.jsonString(client.linuxPrivacyRetentionApply(
                    try decoder.decode(BurnBarLinuxPrivacyRetentionApplyRequest.self, from: paramsData)
                ))
            default:
                throw BurnBarCLIError.invalidCommand("privacy-rpc (methodRaw)")
            }
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// `search-sql`: stdin JSON `{sql, args, maxRows}` -> stdout JSON result.
    ///
    /// This exists so the local MCP server can read the ENCRYPTED store on a
    /// production install. The daemon admits only first-party signed peers, and
    /// the MCP server is a virtualenv `python` that can never carry that
    /// identity; routing its reads through this signed binary is what makes the
    /// memory tools work against a real database instead of only in dev builds.
    /// The daemon still enforces `sqlite3_stmt_readonly` plus the row/byte/VM
    /// budgets, so this adds a signed courier, never new authority.
    public func runSearchSQL(input: Data) throws -> String {
        let request: BurnBarSearchSQLRequest
        do {
            request = try JSONDecoder().decode(BurnBarSearchSQLRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "search-sql input must be a JSON object with a `sql` string (optional `args`, `maxRows`)"
            )
        }
        do {
            return try Self.jsonString(client.searchSQL(request))
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// `memory-remember`: stdin JSON `BurnBarProjectMemoryRememberRequest` -> stdout JSON result.
    public func runMemoryRemember(input: Data) throws -> String {
        let request: BurnBarProjectMemoryRememberRequest
        do {
            request = try JSONDecoder().decode(BurnBarProjectMemoryRememberRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "memory-remember input must be a JSON object with a `text` string"
            )
        }
        do {
            return try Self.jsonString(client.memoryRemember(request))
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// `memory-model-policy`: no input -> stdout JSON `BurnBarMemoryModelPolicyResponse`
    /// (Memory Pro: what the memory engine may use, plus a scoped gateway token).
    public func runMemoryModelPolicy() throws -> String {
        do {
            return try Self.jsonString(client.memoryModelPolicy())
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// `memory-forget`: stdin JSON `BurnBarProjectMemoryForgetRequest` -> stdout JSON result.
    public func runMemoryForget(input: Data) throws -> String {
        let request: BurnBarProjectMemoryForgetRequest
        do {
            request = try JSONDecoder().decode(BurnBarProjectMemoryForgetRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "memory-forget input must be a JSON object with a `memoryID` string"
            )
        }
        do {
            return try Self.jsonString(client.memoryForget(request))
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    private func runComputerUseCommand(_ arguments: [String]) throws -> BurnBarCLIInvocationResult {
        guard arguments.first == "panic-halt" else {
            return try BurnBarCLIComputerUseLiveSurface.run(arguments: arguments)
        }
        let sessionId = try requiredOption("--session-id", in: arguments)
        let source = optionValue("--source", in: arguments) ?? ComputerUsePanicSource.hotkey.rawValue
        guard ComputerUsePanicSource(rawValue: source) != nil else {
            throw BurnBarCLIError.missingArgument(
                "--source must be one of \(ComputerUsePanicSource.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        let response = try client.panicHalt(
            ComputerUsePanicHaltRequest(sessionId: sessionId, source: source)
        )
        if arguments.contains("--json") {
            return BurnBarCLIInvocationResult(
                output: try Self.jsonString([
                    "sessionId": response.sessionId,
                    "endedAt": Self.formatDate(response.endedAt),
                    "auditHeadHashHex": response.auditHeadHashHex,
                    "source": source
                ]),
                exitCode: EXIT_SUCCESS
            )
        }
        return BurnBarCLIInvocationResult(
            output: [
                "computer_use_panic_halt=accepted",
                "session_id=\(response.sessionId)",
                "source=\(source)",
                "ended_at=\(Self.formatDate(response.endedAt))",
                "audit_head_hash_hex=\(response.auditHeadHashHex)"
            ].joined(separator: "\n"),
            exitCode: EXIT_SUCCESS
        )
    }

    private func runResumeCommand(_ effectiveArguments: [String]) throws -> (BurnBarRunResumeResponse, BurnBarResumeMode) {
        guard effectiveArguments.count >= 2 else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar resume <sessionId> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn]")
        }
        let mode: BurnBarResumeMode = effectiveArguments.contains("--copy")
            ? .copy
            : effectiveArguments.contains("--open") ? .open : effectiveArguments.contains("--spawn") ? .spawn : .print
        let response = try client.runResume(
            sessionID: effectiveArguments[1],
            targetHarness: try Self.resumeOptionValue("--as", in: effectiveArguments),
            targetModel: try Self.resumeOptionValue("--model", in: effectiveArguments),
            mode: mode
        )
        return (response, mode)
    }

    private func runServiceCommand(_ arguments: [String]) throws -> String {
        guard let subcommand = arguments.first else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli service <status|foreground|restart>")
        }
        switch subcommand {
        case "status", "foreground":
            let health = try client.health()
            return [
                "service=\(subcommand == "foreground" ? "foreground" : "running")",
                "daemon_version=\(health.daemonVersion)",
                "protocol=\(health.protocolVersion)",
                "socket=\(health.socketPath ?? "n/a")",
                "gateway=\(health.gatewayEnabled ? "enabled" : "disabled")"
            ].joined(separator: "\n")
        case "restart":
            return "service_restart=unsupported foreground_daemon=true"
        default:
            throw BurnBarCLIError.invalidCommand("service \(subcommand)")
        }
    }

    private func runCapabilitiesCommand(_ arguments: [String]) throws -> String {
        let capabilities = [
            "daemon.health",
            "client.attach",
            "run.create",
            "run.list",
            "run.get",
            "run.poll",
            "run.cancel",
            "run.retry",
            "approval.respond",
            "code.index",
            "code.search",
            "memory.recall"
        ]
        if arguments.contains("--json") {
            return try Self.jsonString([
                "schema": "openburnbar.cli.capabilities.v1",
                "capabilities": capabilities
            ])
        }
        return capabilities.joined(separator: "\n")
    }

    private func runDiagnosticsCommand(_ arguments: [String]) throws -> String {
        let outputDirectory = optionValue("--output", in: arguments)
            ?? FileManager.default.currentDirectoryPath
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let health = try client.health()
        let payload: [String: Any] = [
            "schema": "openburnbar.cli.diagnostics.v1",
            "generatedAt": Self.formatDate(Date()),
            "daemon": [
                "ok": health.ok,
                "version": health.daemonVersion,
                "protocolVersion": health.protocolVersion,
                "socketPath": health.socketPath ?? NSNull(),
                "gatewayEnabled": health.gatewayEnabled,
                "gatewayHost": health.gatewayHost ?? NSNull(),
                "gatewayPort": health.gatewayPort ?? NSNull()
            ],
            "redaction": [
                "socketAuthToken": "redacted"
            ]
        ]
        let diagnosticsURL = outputURL.appendingPathComponent("diagnostics.json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: diagnosticsURL, options: [.atomic])
        return "diagnostics=\(diagnosticsURL.path)"
    }

    private func runSubscribeCommand(_ arguments: [String]) throws -> String {
        guard let topic = arguments.first else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli subscribe <health|run> [runID]")
        }
        let response = try client.startSubscription(BurnBarSubscriptionStartRequest(
            topic: topic,
            runID: topic == "run" && arguments.count > 1 ? arguments[1] : nil,
            requestedSubscriptionID: "cli-\(topic)-\(UUID().uuidString)",
            clientID: "openburnbar-cli"
        ))
        return Self.formatSubscriptionResponse(response)
    }

    private func runChatQueryCommand(_ arguments: [String]) throws -> String {
        guard let operation = arguments.first else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli chat <threads|thread> [options]")
        }
        switch operation {
        case "threads":
            let limit = try positiveIntegerOption("--limit", in: arguments, defaultValue: 40)
            let response = try client.chatThreadList(BurnBarChatThreadListRequest(
                query: optionValue("--query", in: arguments), limit: limit
            ))
            return try Self.jsonString(response)
        case "thread":
            guard arguments.count >= 2, !arguments[1].hasPrefix("--") else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli chat thread <threadID> [--max-messages N] [--before-timestamp ISO8601 --before-message-id ID]")
            }
            let beforeTimestamp = optionValue("--before-timestamp", in: arguments)
            let beforeMessageID = optionValue("--before-message-id", in: arguments)
            guard (beforeTimestamp == nil) == (beforeMessageID == nil) else {
                throw BurnBarCLIError.missingArgument("--before-timestamp and --before-message-id must be supplied together")
            }
            let response = try client.chatThreadGet(BurnBarChatThreadGetRequest(
                threadID: arguments[1],
                maxMessages: try positiveIntegerOption("--max-messages", in: arguments, defaultValue: 200),
                beforeTimestamp: beforeTimestamp,
                beforeMessageID: beforeMessageID
            ))
            return try Self.jsonString(response)
        default:
            throw BurnBarCLIError.invalidCommand("chat \(operation)")
        }
    }

    private func runActivityQueryCommand(_ arguments: [String]) throws -> String {
        guard let operation = arguments.first else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli activity <history|search|replay> [options]")
        }
        switch operation {
        case "history":
            return try Self.jsonString(
                client.activityHistory(limit: try positiveIntegerOption("--limit", in: arguments, defaultValue: 500))
            )
        case "search":
            let query = positionalArguments(Array(arguments.dropFirst()), optionNames: ["--limit"])
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli activity search <query> [--limit N]")
            }
            return try Self.jsonString(
                client.activitySearch(
                    query: query,
                    limit: try positiveIntegerOption("--limit", in: arguments, defaultValue: 50)
                )
            )
        case "replay":
            guard arguments.count == 2, !arguments[1].hasPrefix("--") else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli activity replay <sourceID>")
            }
            return try Self.jsonString(client.runResume(
                sessionID: arguments[1],
                targetHarness: nil,
                targetModel: nil,
                mode: .print
            ))
        default:
            throw BurnBarCLIError.invalidCommand("activity \(operation)")
        }
    }

    private func runSubscriptionResumeCommand(_ arguments: [String]) throws -> String {
        guard let subscriptionID = arguments.first, !subscriptionID.hasPrefix("--") else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli subscription-resume <subscriptionID> --topic <topic> --after-seq <seq>")
        }
        let topic = optionValue("--topic", in: arguments) ?? "health"
        let afterSeq = Int(optionValue("--after-seq", in: arguments) ?? "0") ?? 0
        let response = try client.resumeSubscription(BurnBarSubscriptionResumeRequest(
            subscriptionID: subscriptionID,
            topic: topic,
            afterSeq: afterSeq,
            runID: optionValue("--run-id", in: arguments),
            clientID: "openburnbar-cli"
        ))
        return Self.formatSubscriptionResponse(response)
    }

    private func runRunCommand(_ arguments: [String]) throws -> String {
        guard let subcommand = arguments.first else {
            throw BurnBarCLIError.missingArgument(Self.runUsageText)
        }
        let options = Array(arguments.dropFirst())
        let identifiers = Self.runClientIdentifiers()
        try client.attachRunClient(clientID: identifiers.clientID, sessionID: identifiers.sessionID)

        switch subcommand {
        case "create":
            let prompt = optionValue("--prompt", in: options)
                ?? positionalArguments(
                    options,
                    optionNames: ["--prompt", "--model", "--model-id", "--fail-until-attempt"]
                ).joined(separator: " ")
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli run create --prompt <text> [--model <model>] [--mock-provider] [--requires-approval] [--fail-until-attempt N]")
            }
            var metadata = BurnBarRunCreateMetadata()
            let failUntilAttempt = Int(optionValue("--fail-until-attempt", in: options) ?? "")
            if options.contains("--requires-approval") {
                metadata[.requiresApproval] = .bool(true)
            }
            if let failUntilAttempt {
                metadata[.failUntilAttempt] = .number(Double(failUntilAttempt))
            }
            if options.contains("--mock-provider") {
                metadata[.controllerReview] = .bool(true)
            }
            if options.contains("--mock-provider") {
                metadata["mockProvider"] = .bool(true)
            }
            let response = try client.createRun(
                BurnBarRunCreateRequest(
                    clientID: identifiers.clientID,
                    sessionID: identifiers.sessionID,
                    prompt: prompt,
                    modelID: optionValue("--model", in: options)
                        ?? optionValue("--model-id", in: options)
                        ?? ProcessInfo.processInfo.environment["OPENBURNBAR_RUN_MODEL"]
                        ?? "gpt-5.5",
                    metadata: metadata
                )
            )
            return [
                "run_id=\(response.runID.rawValue)",
                "phase=\(response.phase.rawValue)",
                "client_id=\(identifiers.clientID.rawValue)",
                "session_id=\(identifiers.sessionID.rawValue)"
            ].joined(separator: "\n")
        case "list":
            let response = try client.listRuns(
                BurnBarRunListRequest(
                    clientID: identifiers.clientID,
                    offset: Int(optionValue("--offset", in: options) ?? "") ?? 0,
                    limit: Int(optionValue("--limit", in: options) ?? "") ?? 50
                )
            )
            return formatRunList(response)
        case "get":
            let runID = try Self.requiredPositionalRunID(in: options, usage: "Usage: openburnbar-cli run get <runID>")
            return formatRunDetail(
                try client.getRun(BurnBarRunGetRequest(runID: runID, clientID: identifiers.clientID))
            )
        case "poll":
            let runID = try Self.requiredPositionalRunID(in: options, usage: "Usage: openburnbar-cli run poll <runID> [--json]")
            let response = try client.pollRuns(
                BurnBarRunPollRequest(
                    clientID: identifiers.clientID,
                    sessionID: identifiers.sessionID,
                    runID: runID,
                    limit: Int(optionValue("--limit", in: options) ?? "") ?? 50
                )
            )
            return options.contains("--json") ? try formatRunPollJSON(response) : formatRunPoll(response)
        case "approval":
            guard let approvalIDValue = options.first, !approvalIDValue.hasPrefix("--") else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli run approval <approvalID> --decision approve|reject|cancel [--note text]")
            }
            guard let decisionValue = optionValue("--decision", in: options),
                  let decision = BurnBarApprovalDecision(rawValue: decisionValue) else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli run approval <approvalID> --decision approve|reject|cancel [--note text]")
            }
            let detail = try client.respondToApproval(
                BurnBarApprovalRespondRequest(
                    response: BurnBarApprovalResponse(
                        approvalID: BurnBarApprovalID(rawValue: approvalIDValue),
                        clientID: identifiers.clientID,
                        decision: decision,
                        note: optionValue("--note", in: options),
                        respondedAt: Date()
                    )
                )
            )
            return [
                "approval_id=\(approvalIDValue)",
                "decision=\(decision.rawValue)",
                formatRunDetail(detail)
            ].joined(separator: "\n")
        case "cancel":
            let runID = try Self.requiredPositionalRunID(in: options, usage: "Usage: openburnbar-cli run cancel <runID> [--reason text]")
            return formatRunDetail(
                try client.cancelRun(
                    BurnBarRunCancelRequest(
                        runID: runID,
                        clientID: identifiers.clientID,
                        reason: optionValue("--reason", in: options)
                    )
                )
            )
        case "retry":
            let runID = try Self.requiredPositionalRunID(in: options, usage: "Usage: openburnbar-cli run retry <runID>")
            return formatRunDetail(
                try client.retryRun(BurnBarRunRetryRequest(runID: runID, clientID: identifiers.clientID))
            )
        default:
            throw BurnBarCLIError.invalidCommand("run \(subcommand)")
        }
    }

    private static func runClientIdentifiers() -> (clientID: BurnBarClientID, sessionID: BurnBarSessionID) {
        let environment = ProcessInfo.processInfo.environment
        return (
            BurnBarClientID(rawValue: environment["OPENBURNBAR_RUN_CLIENT_ID"] ?? "openburnbar-cli"),
            BurnBarSessionID(rawValue: environment["OPENBURNBAR_RUN_SESSION_ID"] ?? "openburnbar-cli-session")
        )
    }

    private static func formatSubscriptionResponse(_ response: BurnBarSubscriptionResponse) -> String {
        var lines = [
            "subscription_id=\(response.subscriptionID)",
            "topic=\(response.topic)",
            "seq=\(response.seq)",
            "cursor=\(response.cursor)",
            "first_snapshot=\(response.firstSnapshot)",
            "degraded_fallback=\(response.degradedFallback)",
            "degradation_reason=\(response.degradationReason ?? "none")",
            "backpressure=\(response.backpressure)",
            "disconnect_detected=\(response.disconnectDetected)",
            "recovered_after_restart=\(response.recoveredAfterRestart)",
            "terminal_state_delivered=\(response.terminalStateDelivered)"
        ]
        for event in response.events {
            lines.append("event_seq=\(event.seq) event_kind=\(event.kind) terminal=\(event.terminal)")
        }
        return lines.joined(separator: "\n")
    }

    private static func requiredPositionalRunID(in arguments: [String], usage: String) throws -> BurnBarRunID {
        guard let rawValue = arguments.first(where: { !$0.hasPrefix("--") }) else {
            throw BurnBarCLIError.missingArgument(usage)
        }
        return BurnBarRunID(rawValue: rawValue)
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func jsonString(from object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func jsonString<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Part B1 handoff: dispatches a task into a genuine interactive `claude`
    /// session (no `-p`) in the user's terminal of choice, recording a companion
    /// session so the subscription-window token delta can be reconciled later.
    private func runClaudeHandoff(_ arguments: [String]) throws -> BurnBarCLIInvocationResult {
        guard let subcommand = arguments.first else {
            throw BurnBarCLIError.missingArgument(Self.claudeHandoffUsageText)
        }
        let options = Array(arguments.dropFirst())
        let service = ClaudeInteractiveHandoffService()

        switch subcommand {
        case "dispatch":
            guard let briefing = optionValue("--briefing", in: options)
                ?? optionValue("--prompt", in: options) else {
                throw BurnBarCLIError.missingArgument(Self.claudeHandoffUsageText)
            }
            let terminalRaw = optionValue("--terminal", in: options) ?? "terminal"
            guard let terminal = ClaudeInteractiveHandoffService.TerminalApp(rawValue: terminalRaw.lowercased()) else {
                throw BurnBarCLIError.invalidCommand("claude-handoff --terminal \(terminalRaw)")
            }
            let request = ClaudeInteractiveHandoffService.Request(
                briefing: briefing,
                workingDirectory: optionValue("--cwd", in: options)
                    ?? FileManager.default.currentDirectoryPath,
                model: optionValue("--model", in: options),
                terminal: terminal
            )
            let result = try service.dispatch(request)
            return BurnBarCLIInvocationResult(
                output: """
                Dispatched interactive Claude handoff.
                  session:   \(result.session.id)
                  terminal:  \(result.session.terminal)
                  baseline:  \(result.session.baselineTokens) tokens
                  launcher:  \(result.launcherPath)
                Reconcile usage later with:
                  openburnbar-cli claude-handoff reconcile \(result.session.id)
                """,
                exitCode: EXIT_SUCCESS
            )
        case "reconcile":
            guard let sessionID = options.first, !sessionID.hasPrefix("--") else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli claude-handoff reconcile <sessionID>")
            }
            let result = try service.reconcile(sessionID: sessionID)
            return BurnBarCLIInvocationResult(
                output: """
                Reconciled session \(result.session.id).
                  observed token delta: \(result.tokenDelta)
                  changed sessions:     \(result.changedSessions.isEmpty ? "none" : result.changedSessions.joined(separator: ", "))
                """,
                exitCode: EXIT_SUCCESS
            )
        case "list":
            let sessions = service.listSessions()
            guard !sessions.isEmpty else {
                return BurnBarCLIInvocationResult(output: "No companion handoff sessions.", exitCode: EXIT_SUCCESS)
            }
            let lines = sessions.map { session -> String in
                let delta = session.observedTokenDelta.map { "\($0) tokens" } ?? "unreconciled"
                return "\(session.id) [\(session.terminal)] baseline=\(session.baselineTokens) delta=\(delta)"
            }
            return BurnBarCLIInvocationResult(output: lines.joined(separator: "\n"), exitCode: EXIT_SUCCESS)
        default:
            throw BurnBarCLIError.invalidCommand("claude-handoff \(subcommand)")
        }
    }

    private func runProviderBootstrapClaude() throws -> BurnBarCLIInvocationResult {
        guard let socketClient = client as? BurnBarCLISocketClient else {
            throw BurnBarCLIError.invalidCommand("provider-bootstrap-claude requires the daemon socket client")
        }
        let payload = try Self.claudeCodeOAuthStoragePayload()
        let response = try socketClient.upsertProviderCredentialSlot(
            BurnBarProviderCredentialSlotUpsertRequest(
                providerID: "anthropic",
                slotID: nil,
                label: "Claude Code OAuth",
                apiKey: payload,
                isEnabled: true,
                authMethodID: "anthropic-claude-oauth"
            )
        )
        let slotID = response.slot?.slotID ?? "unknown"
        return BurnBarCLIInvocationResult(
            output: "Imported Claude Code OAuth into Anthropic provider slot \(slotID).",
            exitCode: EXIT_SUCCESS
        )
    }

    private static func claudeCodeOAuthStoragePayload() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = []

        if ProcessInfo.processInfo.environment["BURNBAR_DISABLE_CLAUDE_CODE_KEYCHAIN_FALLBACK"] != "1",
           let keychainPayload = readClaudeCodeKeychainPayload() {
            candidates.append(keychainPayload)
        }

        let fileCandidates = [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".claude/credentials.json")
        ]
        for url in fileCandidates {
            guard let data = try? Data(contentsOf: url),
                  let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            candidates.append(raw)
        }

        for raw in candidates {
            if let payload = try normalizedClaudeOAuthStoragePayload(from: raw) {
                return payload
            }
        }

        throw BurnBarCLIError.missingArgument(
            "No non-expired Claude Code OAuth token was found in the Claude Code Keychain item or ~/.claude/.credentials.json."
        )
    }

    private static func readClaudeCodeKeychainPayload() -> String? {
        #if os(macOS)
        let username = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return nil }
        let securityURL = URL(fileURLWithPath: "/usr/bin/security")
        guard FileManager.default.isExecutableFile(atPath: securityURL.path) else { return nil }

        let process = Process()
        process.executableURL = securityURL
        process.arguments = [
            "find-generic-password",
            "-w",
            "-s", "Claude Code-credentials",
            "-a", username
        ]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let errorSink = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = errorSink
        defer {
            try? errorSink?.close()
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        #else
        return nil
        #endif
    }

    private static func normalizedClaudeOAuthStoragePayload(from raw: String) throws -> String? {
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let accessToken = (oauth["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }
        guard !claudeOAuthPayloadIsExpired(oauth["expiresAt"]) else {
            return nil
        }

        var payload: [String: Any] = ["claudeAiOauth": oauth]
        if let organizationUuid = ((root["organizationUuid"] as? String) ?? (oauth["organizationUuid"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty {
            payload["organizationUuid"] = organizationUuid
        }
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let string = String(data: encoded, encoding: .utf8) else {
            throw BurnBarCLIError.missingArgument("Could not encode Claude OAuth credentials.")
        }
        return string
    }

    private static func claudeOAuthPayloadIsExpired(_ value: Any?) -> Bool {
        guard let milliseconds = expiresAtMilliseconds(value) else { return false }
        let expiresAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        return expiresAt <= Date().addingTimeInterval(60)
    }

    private static func expiresAtMilliseconds(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String {
            if let double = Double(string) {
                return double
            }
            if let date = ThreadSafeISO8601DateFormatter.parse(string) {
                return date.timeIntervalSince1970 * 1_000
            }
        }
        return nil
    }

    private static let claudeHandoffUsageText = """
    Usage:
      openburnbar-cli claude-handoff dispatch --briefing <text> [--cwd <dir>] [--model <model>] [--terminal terminal|iterm|warp]
      openburnbar-cli claude-handoff reconcile <sessionID>
      openburnbar-cli claude-handoff list
    """

    public static let usageText = """
    openburnbar-cli <command> [args]

    Commands:
      health
      service <status|foreground|restart>
      capabilities [--json]
      diagnostics --output <directory>
      subscribe <health|run> [runID]
      subscription-resume <subscriptionID> --topic <topic> --after-seq <seq>
      chat threads [--query text] [--limit N]
      chat thread <threadID> [--max-messages N] [--before-timestamp ISO8601 --before-message-id ID]
      activity history [--limit N]
      activity search <query> [--limit N]
      activity replay <sourceID>
      controller [projectSlug]
      questions [projectSlug]
      followups [projectSlug]
      missions [projectSlug]
      mission-approve <missionID> [note]
      simulator-runs [projectSlug]
      simulator-replay <runID>
      search <query> [--cwd path] [--limit N]
      recall <query> [--cwd path] [--limit N]
      index [path] [--max-files N] [--max-file-bytes N] [--storage-budget-bytes N] [--watch] [--poll-seconds N]
      config [--cwd path]
      healthcheck [--cwd path]
      run <create|list|get|poll|approval|cancel|retry> [args]
      resume <sessionId> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn]
      remote-unlock-certification <status|record-hardware-proof|reset>
      audit-verify <session-directory> [--max-entry-index N] [--skip-opentimestamps]
      computer-use panic-halt --session-id ID|* [--source hotkey|phone_gesture|mac_lock|remote_config|accessibility_revoked|stalled|revoked] [--json]
      computer-use live-surface-proof --panic-url URL --media-url URL [--audit-head HASH] [--json]
      local-peer <browse|advertise-metadata|disabled-state|parse-fixture> [--json] [--timeout SECONDS] [fixture-path]
      devices <discover|parity|pixel-clock|iot> [args...] [--json]
      exec <codex|claude|opencode|droid|forge|agy> [--profile-id <id>] [args...]
      claude-handoff <dispatch|reconcile|list> [args]
      provider-bootstrap-claude
      privacy-rpc (stdin JSON; installed Linux privacy peer)
      install-shell-shims
    """

    private static let runUsageText = """
    Usage:
      openburnbar-cli run create --prompt <text> [--model <model>] [--mock-provider] [--requires-approval] [--fail-until-attempt N]
      openburnbar-cli run list [--limit N] [--offset N]
      openburnbar-cli run get <runID>
      openburnbar-cli run poll <runID> [--json]
      openburnbar-cli run approval <approvalID> --decision approve|reject|cancel [--note text]
      openburnbar-cli run cancel <runID> [--reason text]
      openburnbar-cli run retry <runID>
    """

    public static let helpCommands: Set<String> = ["help", "--help", "-h"]

    public static let directCommandNames: Set<String> = [
        "health",
        "service",
        "capabilities",
        "diagnostics",
        "subscribe",
        "subscription-resume",
        "chat",
        "activity",
        "controller",
        "status",
        "questions",
        "followups",
        "missions",
        "mission-approve",
        "simulator-runs",
        "simulator-replay",
        "search",
        "recall",
        "index",
        "config",
        "healthcheck",
        "run",
        "resume",
        "remote-unlock-certification",
        "audit-verify",
        "computer-use",
        "local-peer",
        "devices",
        "exec",
        "claude-handoff",
        "provider-bootstrap-claude",
        "search-sql",
        "memory-remember",
        "memory-forget",
        "memory-model-policy",
        "privacy-rpc",
        "install-shell-shims"
    ]

    public static let canonicalExecutableNames: Set<String> = [
        "OpenBurnBarCLI",
        "openburnbar-cli",
        "burnbar",
        "openburnbar"
    ]

    public static let shellShimExecutableNames = Set(SwitcherCLIProfileType.allCases.map(\.executableName))

    public static func shouldUseHealthFastPath(
        arguments: [String],
        invokedExecutablePath: String?
    ) -> Bool {
        let effectiveArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        guard effectiveArguments == ["health"],
              let invokedExecutablePath else {
            return false
        }

        let executableName = URL(fileURLWithPath: invokedExecutablePath).lastPathComponent
        return canonicalExecutableNames.contains(executableName)
    }

    public static func startupPreflightResult(
        arguments: [String],
        invokedExecutablePath: String?
    ) -> BurnBarCLIStartupPreflightResult? {
        let effectiveArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        let executableName = invokedExecutablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let executableName, shellShimExecutableNames.contains(executableName) {
            return nil
        }

        guard let command = effectiveArguments.first else {
            return BurnBarCLIStartupPreflightResult(
                output: usageText,
                exitCode: EXIT_SUCCESS,
                writesToStandardError: false
            )
        }

        if helpCommands.contains(command) {
            return BurnBarCLIStartupPreflightResult(
                output: usageText,
                exitCode: EXIT_SUCCESS,
                writesToStandardError: false
            )
        }

        guard let invokedExecutablePath else {
            return nil
        }

        let canonicalName = URL(fileURLWithPath: invokedExecutablePath).lastPathComponent
        guard canonicalExecutableNames.contains(canonicalName),
              directCommandNames.contains(command) == false else {
            return nil
        }

        return BurnBarCLIStartupPreflightResult(
            output: "\(BurnBarCLIError.invalidCommand(command).localizedDescription)\n\n\(usageText)",
            exitCode: EXIT_FAILURE,
            writesToStandardError: true
        )
    }

    private func handleLocalPeerCommand(_ arguments: [String]) throws -> String {
        #if os(Linux)
        let json = arguments.contains("--json")
        let timeout = TimeInterval(Int(optionValue("--timeout", in: arguments) ?? "") ?? 3)
        guard let subcommand = positionalArguments(arguments, optionNames: ["--json", "--timeout"]).first else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli local-peer <browse|advertise-metadata|disabled-state|parse-fixture> [--json] [--timeout SECONDS] [fixture-path]")
        }
        switch subcommand {
        case "browse":
            let peers = try BurnBarLinuxLocalPeerDiscovery.browsePeers(timeoutSeconds: timeout)
            return try BurnBarLinuxLocalPeerDiscovery.formatPeers(peers, json: json)
        case "advertise-metadata":
            let host = ProcessInfo.processInfo.hostName
            let sample = BurnBarLinuxLocalPeerDiscovery.sanitizedTXT(
                daemonVersion: BurnBarDaemonVersion.current,
                protocolVersion: String(BurnBarProtocolVersion.current)
            )
            if json {
                return try Self.jsonString(from: [
                    "service_type": BurnBarLinuxLocalPeerDiscovery.serviceType,
                    "instance": BurnBarLinuxLocalPeerDiscovery.resolveInstanceName(hostName: host, suffix: nil),
                    "txt": sample
                ])
            }
            return sample.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        case "parse-fixture":
            let positional = positionalArguments(arguments, optionNames: ["--json", "--timeout"])
            let fixturePath = positional.dropFirst().first ?? positional.first(where: { $0.hasPrefix("/") || $0.hasPrefix(".") })
            guard let fixturePath else {
                throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli local-peer parse-fixture <fixture-path> [--json]")
            }
            let fixtureURL = URL(fileURLWithPath: fixturePath)
            let raw = try String(contentsOf: fixtureURL, encoding: .utf8)
            let transcript = raw
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .joined(separator: "\n")
            let peers = BurnBarLinuxLocalPeerDiscovery.testing_parseBrowseOutput(transcript)
            return try BurnBarLinuxLocalPeerDiscovery.formatPeers(peers, json: json)
        case "disabled-state":
            let disabled = BurnBarLinuxLocalPeerDiscovery.isDiscoveryDisabled()
            if json {
                return try Self.jsonString(["disabled": disabled])
            }
            return disabled ? "Local peer discovery disabled." : "Local peer discovery enabled."
        default:
            throw BurnBarCLIError.invalidCommand("local-peer \(subcommand)")
        }
        #else
        throw BurnBarCLIError.invalidCommand("local-peer requires Linux")
        #endif
    }

    private func handleDevicesCommand(_ arguments: [String]) throws -> String {
        #if os(Linux)
        let json = arguments.contains("--json")
        let positional = positionalArguments(arguments, optionNames: ["--json"])
        guard let subcommand = positional.first else {
            throw BurnBarCLIError.missingArgument("Usage: openburnbar-cli devices <discover|parity|pixel-clock|iot> [args...] [--json]")
        }
        return try BurnBarLinuxDeviceAdapters.runCLI(
            subcommand: subcommand,
            arguments: Array(positional.dropFirst()),
            json: json
        )
        #else
        throw BurnBarCLIError.invalidCommand("devices requires Linux")
        #endif
    }

    private func formatHealth(_ response: BurnBarHealthResponse) -> String {
        BurnBarCLIHealthFormatter.format(response)
    }

    private func formatControllerSummary(_ summary: BurnBarControllerSummary) -> String {
        [
            "Updated: \(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))",
            "Projects: \(summary.counts.projectCount)",
            "Pending questions: \(summary.counts.pendingQuestionCount)",
            "Open followups: \(summary.counts.openFollowupCount)",
            "Active missions: \(summary.counts.activeMissionCount)",
            "Freshness: \(summary.freshness.rawValue)"
        ].joined(separator: "\n")
    }

    private func formatQuestions(_ questions: [BurnBarPendingQuestionSnapshot]) -> String {
        guard questions.isEmpty == false else { return "No questions." }
        return questions.map { question in
            let stage = question.stageLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? " [\(question.stageLabel!)]"
                : ""
            return "\(question.id.rawValue)\(stage) \(question.title)"
        }.joined(separator: "\n")
    }

    private func formatFollowups(_ followups: [BurnBarFollowupSnapshot]) -> String {
        guard followups.isEmpty == false else { return "No followups." }
        return followups.map { followup in
            "\(followup.id.rawValue) [\(followup.status.rawValue)] \(followup.title)"
        }.joined(separator: "\n")
    }

    private func formatMissions(_ missions: [BurnBarMissionSnapshot]) -> String {
        guard missions.isEmpty == false else { return "No missions." }
        return missions.map { mission in
            "\(mission.id.rawValue) [\(mission.status.rawValue)] \(mission.title)"
        }.joined(separator: "\n")
    }

    private func formatSimulatorRuns(_ runs: [BurnBarSimulatorRunSnapshot]) -> String {
        guard runs.isEmpty == false else { return "No simulator runs." }
        return runs.map { run in
            "\(run.id.rawValue) [\(run.status.rawValue)] \(run.scenarioName)"
        }.joined(separator: "\n")
    }

    private func formatCodeSearch(_ response: BurnBarProjectCodeSearchResponse) -> String {
        guard response.hits.isEmpty == false else {
            return "No code hits for project \(response.projectID)."
        }
        return response.hits.map { hit in
            "\(hit.filePath) \(hit.chunkID)\n\(hit.snippet)"
        }.joined(separator: "\n\n")
    }

    private func formatMemoryRecall(_ response: BurnBarProjectMemoryRecallResponse) -> String {
        guard response.hits.isEmpty == false else {
            return "No memories for project \(response.projectID)."
        }
        return response.hits.map { hit in
            let tags = hit.tags.isEmpty ? "" : " #\(hit.tags.joined(separator: " #"))"
            return "\(hit.memoryID) [\(hit.scope)/\(hit.kind)]\(tags)\n\(hit.snippet)"
        }.joined(separator: "\n\n")
    }

    private func formatCodeIndex(_ response: BurnBarProjectCodeIndexProjectResponse) -> String {
        var lines = [
            "Indexed project \(response.projectID)",
            "root=\(response.projectRoot)",
            "files=\(response.indexedFiles) chunks=\(response.chunkCount) symbols=\(response.symbolCount) rejected=\(response.rejectedFiles.count)",
            "audit_hash=\(response.auditHash)"
        ]
        if let commitSHA = response.commitSHA {
            lines.append("commit=\(commitSHA)")
        }
        if response.rejectedFiles.isEmpty == false {
            lines.append("Rejected files:")
            lines.append(contentsOf: response.rejectedFiles.map { "\($0.filePath): \($0.labels.joined(separator: ", "))" })
        }
        return lines.joined(separator: "\n")
    }

    private func formatCodeWatch(_ response: BurnBarProjectCodeWatchProjectResponse) -> String {
        [
            "Watching project \(response.projectID)",
            "root=\(response.projectRoot)",
            "poll_seconds=\(response.pollIntervalSeconds)",
            "initial_files=\(response.indexedFiles)",
            "signature=\(response.signature)"
        ].joined(separator: "\n")
    }

    private func formatProjectMemoryConfig(_ status: BurnBarProjectCodeIndexStatusResponse) -> String {
        [
            "project_id=\(status.projectID)",
            "project_root=\(status.projectRoot ?? "unindexed")",
            "indexed_at=\(status.indexedAt ?? "never")",
            "artifacts=\(status.artifactCount)",
            "symbols=\(status.symbolCount)",
            "references=\(status.referenceCount)",
            "call_edges=\(status.callEdgeCount)",
            "storage_bytes=\(status.storageByteCount)",
            "storage_budget_bytes=\(status.storageBudgetBytes)",
            "storage_within_budget=\(status.storageWithinBudget)",
            "last_vacuumed_at=\(status.lastVacuumedAt ?? "never")"
        ].joined(separator: "\n")
    }

    private func formatProjectMemoryHealthcheck(
        health: BurnBarHealthResponse,
        status: BurnBarProjectCodeIndexStatusResponse
    ) -> String {
        [
            "liveness=ok daemon=\(health.daemonVersion) protocol=\(health.protocolVersion)",
            "project_id=\(status.projectID)",
            "readiness=\(status.indexedAt == nil ? "unindexed" : "ready")",
            "artifacts=\(status.artifactCount) chunks=\(status.chunkCount) symbols=\(status.symbolCount)",
            "pending_forgets=\(status.pendingForgetCount)",
            "storage=\(status.storageByteCount)/\(status.storageBudgetBytes) within_budget=\(status.storageWithinBudget)",
            "last_vacuumed_at=\(status.lastVacuumedAt ?? "never")"
        ].joined(separator: "\n")
    }

    private func formatRunList(_ response: BurnBarRunListResponse) -> String {
        guard !response.runs.isEmpty else { return "No runs." }
        return response.runs.map { run in
            var fields = [
                "run_id=\(run.runID.rawValue)",
                "phase=\(run.phase.rawValue)",
                "session_id=\(run.sessionID.rawValue)",
                "model=\(run.modelID)"
            ]
            if let approvalID = run.activeApprovalID {
                fields.append("approval_id=\(approvalID.rawValue)")
            }
            if let errorMessage = run.errorMessage {
                fields.append("error=\(errorMessage)")
            }
            return fields.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func formatRunDetail(_ response: BurnBarRunDetailResponse) -> String {
        guard let run = response.run else {
            return "run_id=missing phase=missing"
        }
        var lines = [
            "run_id=\(run.runID.rawValue)",
            "phase=\(run.phase.rawValue)",
            "client_id=\(run.clientID.rawValue)",
            "session_id=\(run.sessionID.rawValue)",
            "model=\(run.modelID)"
        ]
        if let approvalID = run.activeApprovalID {
            lines.append("active_approval_id=\(approvalID.rawValue)")
        }
        if let approval = response.approvalRequest {
            lines.append("approval_id=\(approval.approvalID.rawValue)")
            lines.append("approval_tool=\(approval.tool.rawValue)")
            lines.append("approval_title=\(approval.title)")
        }
        if let pendingToolCall = response.pendingToolCall {
            lines.append("pending_tool_call=\(pendingToolCall.callID)")
        }
        if let errorMessage = run.errorMessage {
            lines.append("error=\(errorMessage)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatRunPoll(_ response: BurnBarRunEventBatch) -> String {
        var lines = response.runs.map { run -> String in
            var fields = [
                "run_id=\(run.runID.rawValue)",
                "phase=\(run.phase.rawValue)",
                "session_id=\(run.sessionID.rawValue)"
            ]
            if let approvalID = run.activeApprovalID {
                fields.append("approval_id=\(approvalID.rawValue)")
            }
            if let errorMessage = run.errorMessage {
                fields.append("error=\(errorMessage)")
            }
            return fields.joined(separator: " ")
        }
        lines.append(contentsOf: response.approvals.map { approval in
            "approval_id=\(approval.approvalID.rawValue) run_id=\(approval.runID.rawValue) tool=\(approval.tool.rawValue) title=\(approval.title)"
        })
        if lines.isEmpty {
            lines.append("No run updates.")
        }
        return lines.joined(separator: "\n")
    }

    private func formatRunPollJSON(_ response: BurnBarRunEventBatch) throws -> String {
        let payload: [String: Any] = [
            "runs": response.runs.map(Self.runJSON),
            "approvals": response.approvals.map(Self.approvalJSON),
            "pendingToolCalls": response.pendingToolCalls.map { ["callID": $0.callID] },
            "arbitration": Self.arbitrationJSON(response.arbitration),
            "emittedAt": Self.formatDate(response.emittedAt)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func runJSON(_ run: BurnBarRunStateSnapshot) -> [String: Any] {
        var payload: [String: Any] = [
            "runID": run.runID.rawValue,
            "clientID": run.clientID.rawValue,
            "sessionID": run.sessionID.rawValue,
            "phase": run.phase.rawValue,
            "modelID": run.modelID,
            "updatedAt": formatDate(run.updatedAt)
        ]
        if let errorMessage = run.errorMessage {
            payload["errorMessage"] = errorMessage
        }
        if let approvalID = run.activeApprovalID {
            payload["activeApprovalID"] = approvalID.rawValue
        }
        return payload
    }

    private static func approvalJSON(_ approval: BurnBarApprovalRequest) -> [String: Any] {
        [
            "approvalID": approval.approvalID.rawValue,
            "runID": approval.runID.rawValue,
            "tool": approval.tool.rawValue,
            "title": approval.title,
            "message": approval.message,
            "requestedAt": formatDate(approval.requestedAt)
        ]
    }

    private static func arbitrationJSON(_ arbitration: BurnBarClientArbitrationSnapshot?) -> [String: Any] {
        guard let arbitration else { return [:] }
        var payload: [String: Any] = [
            "attachedClientIDs": arbitration.attachedClientIDs.map(\.rawValue)
        ]
        if let activeClientID = arbitration.activeClientID {
            payload["activeClientID"] = activeClientID.rawValue
        }
        if let reason = arbitration.reason {
            payload["reason"] = reason
        }
        return payload
    }

    public static func formatRunResumeResponse(_ response: BurnBarRunResumeResponse, mode: BurnBarResumeMode) -> String {
        switch response.kind {
        case "native":
            let command = (response.argv ?? []).joined(separator: " ")
            let cwdLine = response.workingDirectory.map { "# Run from: \($0)\n" } ?? ""
            return "\(cwdLine)\(command)"
        case "ported":
            let prefix = response.note.map { "# note: \($0)\n" } ?? ""
            switch mode {
            case .print:
                return "\(prefix)\(response.briefingMD ?? "")"
            case .copy:
                return ""
            case .open:
                return response.briefingPath ?? ""
            case .spawn:
                return response.briefingPath ?? response.briefingMD ?? ""
            }
        case "error":
            let code = response.errorCode ?? "unknown"
            let recovery = response.errorRecovery ?? ""
            return "error: \(code)\n\(recovery)"
        case "spawned":
            let pid = response.pid.map(String.init) ?? "unknown"
            let target = response.targetHarness ?? "unknown"
            let cleanup = response.cleanupAfterSeconds.map { " cleanup_after_seconds=\($0)" } ?? ""
            return "spawned \(target) pid=\(pid)\(cleanup)"
        default:
            return "error: unknown response kind '\(response.kind)'"
        }
    }

    private func positionalArguments(_ arguments: [String], optionNames: Set<String>) -> [String] {
        var output: [String] = []
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if optionNames.contains(value) {
                index += 2
                continue
            }
            if value.hasPrefix("--") {
                index += 1
                continue
            }
            output.append(value)
            index += 1
        }
        return output
    }

    private static func resumeOptionValue(_ name: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard arguments.indices.contains(index + 1) else {
            throw BurnBarCLIError.missingArgument("\(name) requires a value")
        }
        let value = arguments[index + 1]
        guard !value.hasPrefix("--") else {
            throw BurnBarCLIError.missingArgument("\(name) requires a value")
        }
        return value
    }

    private func handleRemoteUnlockCertification(_ arguments: [String]) throws -> String {
        guard let subcommand = arguments.first else {
            throw BurnBarCLIError.missingArgument(Self.remoteUnlockCertificationUsageText)
        }
        let options = Array(arguments.dropFirst())
        switch subcommand {
        case "status":
            guard let report = try remoteUnlockCertificationStore.load() else {
                return "Remote Unlock certification: missing\nPath: \(remoteUnlockCertificationStore.fileURL.path)"
            }
            return [
                "Remote Unlock certification: present",
                "Report: \(report.reportId)",
                "Backend: \(report.backend.rawValue)",
                "OS build: \(report.currentOSBuild)",
                "Recipient key: \(report.credentialRecipientKeyId)",
                "Generated: \(Self.formatDate(report.generatedAt))",
                "Expires: \(Self.formatDate(report.expiresAt))",
                "Path: \(remoteUnlockCertificationStore.fileURL.path)"
            ].joined(separator: "\n")
        case "record-hardware-proof":
            let keyId = try requiredOption("--key-id", in: options)
            let publicKey = try requiredOption("--public-key-base64", in: options)
            let fileVaultSSHSupported = boolOption("--filevault-ssh-supported", in: options) ?? false
            let viewerDeviceKind = optionValue("--viewer-device-kind", in: options)
            let notes = optionValue("--notes", in: options)
            let outputPath = optionValue("--output", in: options)
            let now = Date()
            let report = RemoteUnlockCertificationReport.certifiedHardware(
                currentOSBuild: RemoteUnlockCertificationReport.currentHostOSBuild(),
                credentialRecipientKeyId: keyId,
                credentialRecipientPublicKeyBase64: publicKey,
                fileVaultSSHSupported: fileVaultSSHSupported,
                generatedAt: now,
                redactedViewerDeviceKind: viewerDeviceKind,
                notes: notes
            )
            let blockers = report.validationBlockers(
                now: now,
                currentOSBuild: RemoteUnlockCertificationReport.currentHostOSBuild(),
                credentialRecipientKeyId: keyId,
                credentialRecipientPublicKeyBase64: publicKey,
                directDownloadBuild: true,
                daemonInstalled: Self.remoteAccessDaemonInstalled,
                systemScreenSharingAvailable: Self.systemScreenSharingAvailable
            )
            guard blockers.isEmpty else {
                throw BurnBarCLIError.missingArgument(
                    "Remote Unlock proof is not installable: \(blockers.joined(separator: ", "))"
                )
            }
            try remoteUnlockCertificationStore.save(report)
            if let outputPath {
                let outputURL = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try RemoteUnlockCertificationReportStore.makeEncoder()
                    .encode(report)
                    .write(to: outputURL, options: [.atomic])
            }
            return "Remote Unlock certification recorded: \(report.reportId)\nPath: \(remoteUnlockCertificationStore.fileURL.path)"
        case "reset":
            try remoteUnlockCertificationStore.remove()
            return "Remote Unlock certification removed.\nPath: \(remoteUnlockCertificationStore.fileURL.path)"
        default:
            throw BurnBarCLIError.invalidCommand("remote-unlock-certification \(subcommand)")
        }
    }

    private static let remoteUnlockCertificationUsageText = """
    Usage:
      openburnbar-cli remote-unlock-certification status
      openburnbar-cli remote-unlock-certification record-hardware-proof --key-id <hpke-key-id> --public-key-base64 <base64> [--viewer-device-kind ios|ipad|android] [--filevault-ssh-supported true|false] [--notes text] [--output path]
      openburnbar-cli remote-unlock-certification reset
    """

    private static var remoteAccessDaemonInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.openburnbar.remote-access-agent.plist")
    }

    private static var systemScreenSharingAvailable: Bool {
        #if canImport(Darwin)
        RemoteUnlockSystemScreenSharingProbe().status().isAvailable
        #else
        false
        #endif
    }

    private static func formatDate(_ date: Date) -> String {
        ThreadSafeISO8601DateFormatter.formatBasic(date)
    }

    private func requiredOption(_ name: String, in arguments: [String]) throws -> String {
        guard let value = optionValue(name, in: arguments),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BurnBarCLIError.missingArgument(Self.remoteUnlockCertificationUsageText)
        }
        return value
    }

    private func optionValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func positiveIntegerOption(_ name: String, in arguments: [String], defaultValue: Int) throws -> Int {
        guard let rawValue = optionValue(name, in: arguments) else { return defaultValue }
        guard let value = Int(rawValue), value > 0 else {
            throw BurnBarCLIError.missingArgument("\(name) must be a positive integer")
        }
        return value
    }

    private func boolOption(_ name: String, in arguments: [String]) -> Bool? {
        guard let value = optionValue(name, in: arguments)?.lowercased() else { return nil }
        switch value {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private func wrappedCLIRequest(
        arguments: [String],
        invokedExecutablePath: String?
    ) -> BurnBarCLIShellLaunchRequest? {
        let effectiveArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments

        if effectiveArguments.first == "exec" {
            guard effectiveArguments.count >= 2,
                  let cliType = SwitcherCLIProfileType(rawValue: effectiveArguments[1]) else {
                return nil
            }
            let parsed = parseShellExecArguments(Array(effectiveArguments.dropFirst(2)))
            return BurnBarCLIShellLaunchRequest(
                cliType: cliType,
                forwardedArguments: parsed.forwardedArguments,
                requestedProfileID: parsed.profileID
            )
        }

        guard let invokedExecutablePath else {
            return nil
        }

        let commandName = URL(fileURLWithPath: invokedExecutablePath).lastPathComponent
        guard let cliType = SwitcherCLIProfileType.allCases.first(where: { $0.executableName == commandName }) else {
            return nil
        }

        let parsed = parseShellExecArguments(effectiveArguments)
        return BurnBarCLIShellLaunchRequest(
            cliType: cliType,
            forwardedArguments: parsed.forwardedArguments,
            requestedProfileID: parsed.profileID
        )
    }

    private func parseShellExecArguments(_ arguments: [String]) -> (profileID: String?, forwardedArguments: [String]) {
        var forwardedArguments: [String] = []
        var profileID: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--profile-id", index + 1 < arguments.count {
                profileID = arguments[index + 1]
                index += 2
                continue
            }
            if argument == "--" {
                forwardedArguments.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            forwardedArguments.append(argument)
            index += 1
        }

        return (profileID, forwardedArguments)
    }
}

private struct BurnBarEmptySwitcherProfileStore: BurnBarSwitcherProfileStoreProviding {
    func fetchProfile(id: String) -> SwitcherProfileRecord? { nil }
    func fetchAllProfiles() -> [SwitcherProfileRecord] { [] }
    func fetchActiveProfileID() -> String? { nil }
    func setActiveProfileID(_ profileID: String?) {}
    func updateProfile(_ profile: SwitcherProfileRecord) {}
}

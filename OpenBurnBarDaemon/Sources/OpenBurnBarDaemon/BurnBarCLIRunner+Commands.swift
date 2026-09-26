import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension BurnBarCLIRunner {
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

    /// `memory-sync-inbox-list`: stdin JSON `BurnBarMemorySyncInboxListRequest`
    /// -> stdout JSON `BurnBarMemorySyncInboxListResponse`.
    ///
    /// Memory Blind Sync, engine side. The app's pull lane opens the member's own
    /// sealed `memory_facts` documents and parks the plaintext; the Python memory
    /// engine holds no keys and no network and reaches those rows only here. It
    /// cannot dial the control socket itself — production admits only first-party
    /// signed peers and a virtualenv `python` can never carry that identity — so
    /// the drain travels through this signed courier, exactly like `search-sql`.
    public func runMemorySyncInboxList(input: Data) throws -> String {
        let request: BurnBarMemorySyncInboxListRequest
        do {
            request = try JSONDecoder().decode(BurnBarMemorySyncInboxListRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "memory-sync-inbox-list input must be a JSON object (optional `projectID`, `limit`)"
            )
        }
        do {
            return try Self.jsonString(client.memorySyncInboxList(request))
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// `memory-sync-inbox-ack`: stdin JSON `BurnBarMemorySyncInboxAckRequest`
    /// -> stdout JSON `BurnBarMemorySyncInboxAckResponse`. Stamps `applied_at` on
    /// the doc ids the engine merged; idempotent, so a partial drain is safe to
    /// retry.
    public func runMemorySyncInboxAck(input: Data) throws -> String {
        let request: BurnBarMemorySyncInboxAckRequest
        do {
            request = try JSONDecoder().decode(BurnBarMemorySyncInboxAckRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "memory-sync-inbox-ack input must be a JSON object with a `docIDs` array of strings"
            )
        }
        do {
            return try Self.jsonString(client.memorySyncInboxAck(request))
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

    // MARK: - Project code memory courier commands
    //
    // Code index *reads* already travelled this binary, because they are served
    // by `search-sql` against the daemon's keyed store. The three code
    // operations that are not plain SELECTs — building an index, enlisting the
    // daemon's watcher, and the repo-map/context `explore` — had no signed
    // command at all, so on a signed install with the first-party peer gate on
    // they fell through to a direct socket connection the daemon refuses with
    // `code=-32001 … peer failed first-party code-signature verification`.
    // These three commands are that missing route. They add a courier, never
    // new authority: the daemon still classifies `index_project` and
    // `watch_project` as `codeWrite` and `explore` as `codeRead`, and still
    // checks them against the CLI peer's attenuated method allowlist.

    /// `code-index-project`: stdin JSON `BurnBarProjectCodeIndexProjectRequest`
    /// -> stdout JSON `BurnBarProjectCodeIndexProjectResponse`.
    public func runCodeIndexProject(input: Data) throws -> String {
        let request: BurnBarProjectCodeIndexProjectRequest
        do {
            request = try JSONDecoder().decode(BurnBarProjectCodeIndexProjectRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "code-index-project input must be a JSON object with `maxFiles` and `maxFileBytes` integers "
                    + "(optional `projectPath`, `storageBudgetBytes`)"
            )
        }
        do {
            return try Self.jsonString(client.codeIndex(
                projectPath: request.projectPath,
                maxFiles: request.maxFiles,
                maxFileBytes: request.maxFileBytes,
                storageBudgetBytes: request.storageBudgetBytes
            ))
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// `code-watch-project`: stdin JSON `BurnBarProjectCodeWatchProjectRequest`
    /// -> stdout JSON `BurnBarProjectCodeWatchProjectResponse`.
    ///
    /// The daemon owns the polling; this call is an ordinary request/response
    /// that registers the watcher and returns, so it is no longer-lived on the
    /// courier than an index is.
    public func runCodeWatchProject(input: Data) throws -> String {
        let request: BurnBarProjectCodeWatchProjectRequest
        do {
            request = try JSONDecoder().decode(BurnBarProjectCodeWatchProjectRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "code-watch-project input must be a JSON object with `maxFiles`, `maxFileBytes` and "
                    + "`pollIntervalSeconds` (optional `projectPath`, `storageBudgetBytes`)"
            )
        }
        do {
            return try Self.jsonString(client.codeWatch(
                projectPath: request.projectPath,
                maxFiles: request.maxFiles,
                maxFileBytes: request.maxFileBytes,
                storageBudgetBytes: request.storageBudgetBytes,
                pollIntervalSeconds: request.pollIntervalSeconds
            ))
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// `code-explore`: stdin JSON `BurnBarProjectCodeExploreRequest`
    /// -> stdout JSON `BurnBarProjectCodeExploreResponse`.
    public func runCodeExplore(input: Data) throws -> String {
        let request: BurnBarProjectCodeExploreRequest
        do {
            request = try JSONDecoder().decode(BurnBarProjectCodeExploreRequest.self, from: input)
        } catch {
            throw BurnBarCLIError.missingArgument(
                "code-explore input must be a JSON object with `limit` and `maxBytes` integers "
                    + "(optional `projectPath`, `query`)"
            )
        }
        do {
            return try Self.jsonString(client.codeExplore(request))
        } catch let error as NSError where error.domain == "OpenBurnBarCLI" {
            throw BurnBarCLIError.privacyRPCError(code: error.code, message: error.localizedDescription)
        }
    }

    /// The project-code-memory subcommands the signed courier carries: one JSON
    /// request on stdin, one JSON response on stdout.
    ///
    /// `@main` owns stdin, stdout and `exit`; everything *decidable* lives here —
    /// which names the courier answers, the byte cap each enforces before a
    /// daemon socket is opened, and which runner method carries which command —
    /// so the dispatch can be asserted in a unit test instead of only by
    /// spawning the binary. The seven pre-existing stdin-JSON commands still
    /// carry their own copy of this shape in `@main`; folding them in is a
    /// separate change.
    public enum ProjectCodeCourierCommand: String, CaseIterable, Sendable {
        case indexProject = "code-index-project"
        case watchProject = "code-watch-project"
        case explore = "code-explore"

        /// The same 256 KiB stdin cap `search-sql` and `memory-remember` enforce.
        public static let maxInputBytes = 256 * 1024

        /// Enforce the cap, then carry the request. The cap is checked before the
        /// runner is asked for anything, so an oversized request is refused by the
        /// courier itself and never reaches the daemon socket.
        public func run(_ runner: BurnBarCLIRunner, input: Data) throws -> String {
            guard input.count <= Self.maxInputBytes else {
                throw BurnBarCLIError.missingArgument(
                    "\(rawValue) request exceeds \(Self.maxInputBytes / 1024) KiB"
                )
            }
            switch self {
            case .indexProject:
                return try runner.runCodeIndexProject(input: input)
            case .watchProject:
                return try runner.runCodeWatchProject(input: input)
            case .explore:
                return try runner.runCodeExplore(input: input)
            }
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

    func runComputerUseCommand(_ arguments: [String]) throws -> BurnBarCLIInvocationResult {
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

    func runResumeCommand(_ effectiveArguments: [String]) throws -> (BurnBarRunResumeResponse, BurnBarResumeMode) {
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

    func runServiceCommand(_ arguments: [String]) throws -> String {
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

    func runCapabilitiesCommand(_ arguments: [String]) throws -> String {
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

    func runDiagnosticsCommand(_ arguments: [String]) throws -> String {
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

    func runSubscribeCommand(_ arguments: [String]) throws -> String {
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

    func runChatQueryCommand(_ arguments: [String]) throws -> String {
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

    func runActivityQueryCommand(_ arguments: [String]) throws -> String {
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

    func runSubscriptionResumeCommand(_ arguments: [String]) throws -> String {
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

    func runRunCommand(_ arguments: [String]) throws -> String {
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

    static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func jsonString(from object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func jsonString<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

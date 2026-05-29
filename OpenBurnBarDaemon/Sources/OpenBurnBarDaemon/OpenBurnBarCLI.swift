import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import Darwin
import Foundation

public protocol BurnBarCLIClient: Sendable {
    func health() throws -> BurnBarHealthResponse
    func controllerSummary(projectSlug: String?) throws -> BurnBarControllerSummary
    func questions(projectSlug: String?) throws -> [BurnBarPendingQuestionSnapshot]
    func followups(projectSlug: String?) throws -> [BurnBarFollowupSnapshot]
    func missions(projectSlug: String?) throws -> [BurnBarMissionSnapshot]
    func approveMission(id: BurnBarMissionID, note: String?) throws -> BurnBarMissionSnapshot
    func simulatorRuns(projectSlug: String?) throws -> [BurnBarSimulatorRunSnapshot]
    func simulatorReplay(runID: BurnBarSimulatorRunID) throws -> BurnBarSimulatorRunSnapshot
    func runResume(
        sessionID: String,
        targetHarness: String?,
        targetModel: String?,
        mode: BurnBarResumeMode
    ) throws -> BurnBarRunResumeResponse
}

public struct BurnBarCLISocketClient: BurnBarCLIClient, Sendable {
    public let socketURL: URL
    public let authToken: String?

    public init(
        socketURL: URL = BurnBarDaemonPaths.defaultSocketURL,
        authToken: String? = nil
    ) {
        self.socketURL = socketURL
        self.authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    public func health() throws -> BurnBarHealthResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .health, authToken: authToken)
        )
        return try unwrap(envelope)
    }

    public func controllerSummary(projectSlug: String?) throws -> BurnBarControllerSummary {
        let response: BurnBarControllerSummaryResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .controllerSummary,
                authToken: authToken,
                params: BurnBarControllerSummaryRequest(projectSlug: projectSlug)
            )
        )
        return response.summary
    }

    public func questions(projectSlug: String?) throws -> [BurnBarPendingQuestionSnapshot] {
        let response: BurnBarQuestionsListResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .questionsList,
                authToken: authToken,
                params: BurnBarQuestionsListRequest(
                    projectSlug: projectSlug,
                    statuses: BurnBarPendingQuestionStatus.allCases,
                    limit: 100
                )
            )
        )
        return response.questions
    }

    public func followups(projectSlug: String?) throws -> [BurnBarFollowupSnapshot] {
        let response: BurnBarFollowupsListResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupsList,
                authToken: authToken,
                params: BurnBarFollowupsListRequest(
                    projectSlug: projectSlug,
                    statuses: BurnBarFollowupStatus.allCases,
                    limit: 100
                )
            )
        )
        return response.followups
    }

    public func missions(projectSlug: String?) throws -> [BurnBarMissionSnapshot] {
        let response: BurnBarMissionListResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .missionsList,
                authToken: authToken,
                params: BurnBarMissionListRequest(
                    projectSlug: projectSlug,
                    statuses: BurnBarMissionStatus.allCases,
                    limit: 100
                )
            )
        )
        return response.missions
    }

    public func approveMission(id: BurnBarMissionID, note: String?) throws -> BurnBarMissionSnapshot {
        let response: BurnBarMissionMutationResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .missionApprove,
                authToken: authToken,
                params: BurnBarMissionApproveRequest(
                    missionID: id,
                    actor: "openburnbar-cli",
                    note: note
                )
            )
        )
        return response.mission
    }

    public func simulatorRuns(projectSlug: String?) throws -> [BurnBarSimulatorRunSnapshot] {
        let response: BurnBarSimulatorListResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .simulatorList,
                authToken: authToken,
                params: BurnBarSimulatorListRequest(projectSlug: projectSlug, limit: 100)
            )
        )
        return response.runs
    }

    public func simulatorReplay(runID: BurnBarSimulatorRunID) throws -> BurnBarSimulatorRunSnapshot {
        let response: BurnBarSimulatorRunResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .simulatorReplay,
                authToken: authToken,
                params: BurnBarSimulatorReplayRequest(runID: runID, includeEvents: true)
            )
        )
        return response.run
    }

    public func runResume(
        sessionID: String,
        targetHarness: String?,
        targetModel: String?,
        mode: BurnBarResumeMode
    ) throws -> BurnBarRunResumeResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runResume,
                authToken: authToken,
                params: BurnBarRunResumeRequest(
                    sessionID: sessionID,
                    targetHarness: targetHarness,
                    targetModel: targetModel,
                    mode: mode
                )
            )
        )
    }

    private func unwrap<Response>(_ envelope: BurnBarRPCResponseEnvelope<Response>) throws -> Response {
        if let error = envelope.error {
            throw NSError(domain: "OpenBurnBarCLI", code: error.code, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
        guard let result = envelope.result else {
            throw NSError(domain: "OpenBurnBarCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenBurnBar daemon returned an empty response."])
        }
        return result
    }

    private func requestResult<Params: Codable & Sendable, Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelopeWithParams<Params>
    ) throws -> Response {
        let envelope: BurnBarRPCResponseEnvelope<Response> = try send(request)
        return try unwrap(envelope)
    }

    private func send<Request: Encodable, Response: Codable & Sendable>(
        _ request: Request
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        configureIOTimeouts(for: fileDescriptor)

        var address = try socketAddress(for: socketURL.path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
        }

        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let wrote = write(fileDescriptor, baseAddress.advanced(by: offset), remaining)
                guard wrote > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                remaining -= wrote
                offset += wrote
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 { break }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func configureIOTimeouts(for fileDescriptor: Int32, seconds: Int = 30) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return address
    }
}

public enum BurnBarCLIError: LocalizedError {
    case invalidCommand(String)
    case missingArgument(String)
    case missingExecutablePath

    public var errorDescription: String? {
        switch self {
        case .invalidCommand(let command):
            return "Unsupported OpenBurnBar CLI command '\(command)'."
        case .missingArgument(let usage):
            return usage
        case .missingExecutablePath:
            return "Could not resolve the currently running OpenBurnBarCLI executable."
        }
    }
}

public struct BurnBarCLIInvocationResult: Equatable, Sendable {
    public let output: String?
    public let exitCode: Int32

    public init(output: String?, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public struct BurnBarCLIStartupPreflightResult: Equatable, Sendable {
    public let output: String
    public let exitCode: Int32
    public let writesToStandardError: Bool

    public init(output: String, exitCode: Int32, writesToStandardError: Bool) {
        self.output = output
        self.exitCode = exitCode
        self.writesToStandardError = writesToStandardError
    }
}

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
        case "resume":
            let (response, mode) = try runResumeCommand(effectiveArguments)
            return Self.formatRunResumeResponse(response, mode: mode)
        case "remote-unlock-certification":
            return try handleRemoteUnlockCertification(Array(effectiveArguments.dropFirst()))
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

        if effectiveArguments.first == "resume" {
            let (response, mode) = try runResumeCommand(effectiveArguments)
            return BurnBarCLIInvocationResult(
                output: Self.formatRunResumeResponse(response, mode: mode),
                exitCode: response.kind == "error" ? EXIT_FAILURE : EXIT_SUCCESS
            )
        }

        if effectiveArguments.first == "claude-meter-experiment" {
            return try await runClaudeMeterExperiment(Array(effectiveArguments.dropFirst()))
        }

        if effectiveArguments.first == "claude-handoff" {
            return try runClaudeHandoff(Array(effectiveArguments.dropFirst()))
        }

        return BurnBarCLIInvocationResult(output: try run(arguments: arguments), exitCode: EXIT_SUCCESS)
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

    /// Part B0 diagnostic: drives one interactive `claude` turn through a PTY
    /// and reports whether it billed the subscription window vs. a metered pool.
    /// Off the routing path entirely; produces evidence for a human to read.
    private func runClaudeMeterExperiment(_ arguments: [String]) async throws -> BurnBarCLIInvocationResult {
        var options = ClaudeInteractiveMeterExperiment.Options()
        var emitJSON = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--prompt":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarCLIError.missingArgument("Usage: claude-meter-experiment --prompt <text>")
                }
                options.prompt = arguments[index]
            case "--model":
                index += 1
                guard index < arguments.count else {
                    throw BurnBarCLIError.missingArgument("Usage: claude-meter-experiment --model <model>")
                }
                options.model = arguments[index]
            case "--json":
                emitJSON = true
            default:
                throw BurnBarCLIError.invalidCommand("claude-meter-experiment \(arguments[index])")
            }
            index += 1
        }

        let report = try await ClaudeInteractiveMeterExperiment(options: options).run()
        if emitJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            return BurnBarCLIInvocationResult(
                output: String(decoding: data, as: UTF8.self),
                exitCode: EXIT_SUCCESS
            )
        }
        return BurnBarCLIInvocationResult(
            output: ClaudeInteractiveMeterExperiment.format(report),
            exitCode: report.verdict == .turnDidNotComplete ? EXIT_FAILURE : EXIT_SUCCESS
        )
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
      controller [projectSlug]
      questions [projectSlug]
      followups [projectSlug]
      missions [projectSlug]
      mission-approve <missionID> [note]
      simulator-runs [projectSlug]
      simulator-replay <runID>
      resume <sessionId> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn]
      remote-unlock-certification <status|record-hardware-proof|reset>
      exec <codex|claude|opencode|droid|forge|agy> [--profile-id <id>] [args...]
      claude-meter-experiment [--prompt <text>] [--model <model>] [--json]
      claude-handoff <dispatch|reconcile|list> [args]
      install-shell-shims
    """

    public static let helpCommands: Set<String> = ["help", "--help", "-h"]

    public static let directCommandNames: Set<String> = [
        "health",
        "controller",
        "status",
        "questions",
        "followups",
        "missions",
        "mission-approve",
        "simulator-runs",
        "simulator-replay",
        "resume",
        "remote-unlock-certification",
        "exec",
        "install-shell-shims"
    ]

    public static let canonicalExecutableNames: Set<String> = [
        "OpenBurnBarCLI",
        "openburnbar-cli",
        "burnbar",
        "openburnbar"
    ]

    public static let shellShimExecutableNames = Set(SwitcherCLIProfileType.allCases.map(\.executableName))

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

    private func formatHealth(_ response: BurnBarHealthResponse) -> String {
        "Daemon \(response.daemonVersion) | protocol \(response.protocolVersion) | socket \(response.socketPath ?? "n/a") | ok=\(response.ok)"
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
        FileManager.default.fileExists(atPath: "/System/Library/CoreServices/RemoteManagement/ARDAgent.app")
            || FileManager.default.fileExists(atPath: "/System/Library/CoreServices/Applications/Screen Sharing.app")
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
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

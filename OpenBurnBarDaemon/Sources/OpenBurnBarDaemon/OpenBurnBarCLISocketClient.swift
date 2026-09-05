import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
    func memoryRemember(_ request: BurnBarProjectMemoryRememberRequest) throws -> BurnBarProjectMemoryRememberResponse
    func memoryForget(_ request: BurnBarProjectMemoryForgetRequest) throws -> BurnBarProjectMemoryForgetResponse
    func memoryRecall(query: String, projectPath: String?, limit: Int) throws -> BurnBarProjectMemoryRecallResponse
    /// Memory Pro policy for the Python memory engine (no parameters).
    func memoryModelPolicy() throws -> BurnBarMemoryModelPolicyResponse
    /// Read-only SQL over the daemon's keyed store, for the signed-CLI courier
    /// the local MCP server routes through on production installs.
    func searchSQL(_ request: BurnBarSearchSQLRequest) throws -> BurnBarSearchSQLResult
    /// Memory Blind Sync: the facts the app pulled down and parked, for the
    /// engine to merge. Same courier route as `searchSQL`/`memoryRemember`.
    func memorySyncInboxList(_ request: BurnBarMemorySyncInboxListRequest) throws -> BurnBarMemorySyncInboxListResponse
    /// Memory Blind Sync: stamps `applied_at` on the doc ids the engine merged.
    func memorySyncInboxAck(_ request: BurnBarMemorySyncInboxAckRequest) throws -> BurnBarMemorySyncInboxAckResponse
    func codeIndex(projectPath: String?, maxFiles: Int, maxFileBytes: Int, storageBudgetBytes: Int?) throws -> BurnBarProjectCodeIndexProjectResponse
    func codeWatch(projectPath: String?, maxFiles: Int, maxFileBytes: Int, storageBudgetBytes: Int?, pollIntervalSeconds: Double) throws -> BurnBarProjectCodeWatchProjectResponse
    func codeSearch(query: String, projectPath: String?, limit: Int) throws -> BurnBarProjectCodeSearchResponse
    func codeIndexStatus(projectPath: String?) throws -> BurnBarProjectCodeIndexStatusResponse
    func attachRunClient(clientID: BurnBarClientID, sessionID: BurnBarSessionID) throws
    func createRun(_ request: BurnBarRunCreateRequest) throws -> BurnBarRunCreateResponse
    func listRuns(_ request: BurnBarRunListRequest) throws -> BurnBarRunListResponse
    func getRun(_ request: BurnBarRunGetRequest) throws -> BurnBarRunDetailResponse
    func pollRuns(_ request: BurnBarRunPollRequest) throws -> BurnBarRunEventBatch
    func cancelRun(_ request: BurnBarRunCancelRequest) throws -> BurnBarRunDetailResponse
    func retryRun(_ request: BurnBarRunRetryRequest) throws -> BurnBarRunDetailResponse
    func respondToApproval(_ request: BurnBarApprovalRespondRequest) throws -> BurnBarRunDetailResponse
    func panicHalt(_ request: ComputerUsePanicHaltRequest) throws -> ComputerUsePanicHaltResponse
    func startSubscription(_ request: BurnBarSubscriptionStartRequest) throws -> BurnBarSubscriptionResponse
    func resumeSubscription(_ request: BurnBarSubscriptionResumeRequest) throws -> BurnBarSubscriptionResponse
    func chatThreadList(_ request: BurnBarChatThreadListRequest) throws -> BurnBarChatThreadListResponse
    func chatThreadGet(_ request: BurnBarChatThreadGetRequest) throws -> BurnBarChatThreadGetResponse
    func activityHistory(limit: Int) throws -> BurnBarActivityHistoryResponse
    func activitySearch(query: String, limit: Int) throws -> BurnBarSearchQueryResult
    func runResume(
        sessionID: String,
        targetHarness: String?,
        targetModel: String?,
        mode: BurnBarResumeMode
    ) throws -> BurnBarRunResumeResponse
    func linuxPrivacyInventory() throws -> BurnBarLinuxPrivacyInventoryResponse
    func linuxPrivacyDeletionPreview(_ request: BurnBarLinuxPrivacyDeletionPreviewRequest) throws -> BurnBarLinuxPrivacyDeletionPreviewResponse
    func linuxPrivacyDeletionExecute(_ request: BurnBarLinuxPrivacyDeletionExecuteRequest) throws -> BurnBarLinuxPrivacyDeletionExecuteResponse
    func linuxPrivacyExport(_ request: BurnBarLinuxPrivacyExportRequest) throws -> BurnBarLinuxPrivacyExportResponse
    func linuxPrivacyRetentionStatus() throws -> BurnBarLinuxPrivacyRetentionStatusResponse
    func linuxPrivacyRetentionApply(_ request: BurnBarLinuxPrivacyRetentionApplyRequest) throws -> BurnBarLinuxPrivacyRetentionApplyResponse
}

public struct BurnBarCLISocketClient: BurnBarCLIClient, Sendable {
    public let socketURL: URL
    public let authToken: String?

    /// Resolve the daemon socket credential using the same precedence as the
    /// launcher and Tauri bridge. Packaged Linux CLI invocations should work
    /// without requiring users to export an implementation detail first.
    public static func resolvedSocketAuthToken(environment: [String: String]) throws -> String? {
        if let direct = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"]
            ?? environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN"],
           let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return trimmed
        }
        if let tokenFile = environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE"]
            ?? environment["BURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE"],
           let trimmed = tokenFile.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return try readTokenFile(trimmed)
        }

        #if os(Linux)
        do {
            return try readTokenFile(OpenBurnBarLinuxPaths.authTokenURL(environment: environment).path)
        } catch BurnBarTokenFileError.fileNotFound {
            // Development launches may intentionally run without a token.
            return nil
        }
        #elseif os(macOS)
        do {
            return try readTokenFile(canonicalMacOSAuthTokenURL(environment: environment).path)
        } catch BurnBarTokenFileError.fileNotFound {
            // Development launches may intentionally run without a token.
            return nil
        }
        #else
        return nil
        #endif
    }

    #if os(macOS)
    /// File name the macOS app writes the daemon socket token into, owner-only,
    /// and then hands the daemon as `--socket-auth-token-file`
    /// (`OpenBurnBarDaemonRuntimePaths.socketAuthTokenFileURL`, written in
    /// `OpenBurnBarDaemonManager+Lifecycle.writeDaemonSocketAuthTokenFile`).
    static let macOSAuthTokenFileName = "daemon-socket-auth-token"

    /// The canonical macOS token file. Mirrors
    /// `OpenBurnBarAppPaths.live(fileManager:).supportDirectory`, but resolves
    /// the support-root override out of the supplied environment so the
    /// resolver stays injectable in tests.
    static func canonicalMacOSAuthTokenURL(environment: [String: String]) -> URL {
        let paths: OpenBurnBarAppPaths
        if let override = environment["OPENBURNBAR_SUPPORT_ROOT"], !override.isEmpty {
            paths = OpenBurnBarAppPaths(applicationSupportRoot: URL(fileURLWithPath: override, isDirectory: true))
        } else {
            paths = OpenBurnBarAppPaths.live()
        }
        return paths.supportDirectory.appendingPathComponent(macOSAuthTokenFileName, isDirectory: false)
    }
    #endif

    public static func resolvedSocketURL(environment: [String: String]) -> URL {
        if let socketPath = environment["OPENBURNBAR_DAEMON_SOCKET_PATH"]
            ?? environment["BURNBAR_DAEMON_SOCKET_PATH"],
           let trimmed = socketPath.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return URL(fileURLWithPath: trimmed, isDirectory: false)
        }
        return BurnBarDaemonPaths.defaultSocketURL
    }

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

    public func memoryRecall(query: String, projectPath: String?, limit: Int) throws -> BurnBarProjectMemoryRecallResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryRecall,
                authToken: authToken,
                params: BurnBarProjectMemoryRecallRequest(query: query, projectPath: projectPath, limit: limit)
            )
        )
    }

    public func memoryRemember(_ request: BurnBarProjectMemoryRememberRequest) throws -> BurnBarProjectMemoryRememberResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryRemember,
                authToken: authToken,
                params: request
            )
        )
    }

    public func memoryModelPolicy() throws -> BurnBarMemoryModelPolicyResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarMemoryModelPolicyResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .memoryModelPolicy, authToken: authToken)
        )
        return try unwrap(envelope)
    }

    public func memoryForget(_ request: BurnBarProjectMemoryForgetRequest) throws -> BurnBarProjectMemoryForgetResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryForget,
                authToken: authToken,
                params: request
            )
        )
    }

    public func codeIndex(projectPath: String?, maxFiles: Int, maxFileBytes: Int, storageBudgetBytes: Int?) throws -> BurnBarProjectCodeIndexProjectResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .codeIndexProject,
                authToken: authToken,
                params: BurnBarProjectCodeIndexProjectRequest(
                    projectPath: projectPath,
                    maxFiles: maxFiles,
                    maxFileBytes: maxFileBytes,
                    storageBudgetBytes: storageBudgetBytes
                )
            )
        )
    }

    public func codeWatch(
        projectPath: String?,
        maxFiles: Int,
        maxFileBytes: Int,
        storageBudgetBytes: Int?,
        pollIntervalSeconds: Double
    ) throws -> BurnBarProjectCodeWatchProjectResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .codeWatchProject,
                authToken: authToken,
                params: BurnBarProjectCodeWatchProjectRequest(
                    projectPath: projectPath,
                    maxFiles: maxFiles,
                    maxFileBytes: maxFileBytes,
                    storageBudgetBytes: storageBudgetBytes,
                    pollIntervalSeconds: pollIntervalSeconds
                )
            )
        )
    }

    public func codeSearch(query: String, projectPath: String?, limit: Int) throws -> BurnBarProjectCodeSearchResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .codeSearch,
                authToken: authToken,
                params: BurnBarProjectCodeSearchRequest(query: query, projectPath: projectPath, limit: limit)
            )
        )
    }

    public func codeIndexStatus(projectPath: String?) throws -> BurnBarProjectCodeIndexStatusResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .codeIndexStatus,
                authToken: authToken,
                params: BurnBarProjectCodeIndexStatusRequest(projectPath: projectPath)
            )
        )
    }

    public func attachRunClient(clientID: BurnBarClientID, sessionID: BurnBarSessionID) throws {
        let _: BurnBarClientAttachResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .clientAttach,
                authToken: authToken,
                params: BurnBarClientAttachRequest(
                    clientID: clientID,
                    sessionID: sessionID,
                    clientName: "openburnbar-cli",
                    supportedProtocolVersions: [BurnBarProtocolVersion.current]
                )
            )
        )
        let _: BurnBarClientArbitrationSnapshot = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .clientClaimControl,
                authToken: authToken,
                params: BurnBarClientClaimControlRequest(
                    clientID: clientID,
                    sessionID: sessionID
                )
            )
        )
    }

    public func createRun(_ request: BurnBarRunCreateRequest) throws -> BurnBarRunCreateResponse {
        try attachRunClient(clientID: request.clientID, sessionID: request.sessionID)
        return try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runCreate,
                authToken: authToken,
                params: request
            )
        )
    }

    public func listRuns(_ request: BurnBarRunListRequest) throws -> BurnBarRunListResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runList,
                authToken: authToken,
                params: request
            )
        )
    }

    public func getRun(_ request: BurnBarRunGetRequest) throws -> BurnBarRunDetailResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runGet,
                authToken: authToken,
                params: request
            )
        )
    }

    public func pollRuns(_ request: BurnBarRunPollRequest) throws -> BurnBarRunEventBatch {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runPoll,
                authToken: authToken,
                params: request
            )
        )
    }

    public func cancelRun(_ request: BurnBarRunCancelRequest) throws -> BurnBarRunDetailResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runCancel,
                authToken: authToken,
                params: request
            )
        )
    }

    public func retryRun(_ request: BurnBarRunRetryRequest) throws -> BurnBarRunDetailResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runRetry,
                authToken: authToken,
                params: request
            )
        )
    }

    public func respondToApproval(_ request: BurnBarApprovalRespondRequest) throws -> BurnBarRunDetailResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .approvalRespond,
                authToken: authToken,
                params: request
            )
        )
    }

    public func panicHalt(_ request: ComputerUsePanicHaltRequest) throws -> ComputerUsePanicHaltResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUsePanicHalt,
                authToken: authToken,
                params: request
            )
        )
    }

    public func startSubscription(_ request: BurnBarSubscriptionStartRequest) throws -> BurnBarSubscriptionResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .subscriptionStart,
                authToken: authToken,
                params: request
            )
        )
    }

    public func resumeSubscription(_ request: BurnBarSubscriptionResumeRequest) throws -> BurnBarSubscriptionResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .subscriptionResume,
                authToken: authToken,
                params: request
            )
        )
    }

    public func chatThreadList(_ request: BurnBarChatThreadListRequest) throws -> BurnBarChatThreadListResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(method: .chatThreadList, authToken: authToken, params: request))
    }

    public func chatThreadGet(_ request: BurnBarChatThreadGetRequest) throws -> BurnBarChatThreadGetResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(method: .chatThreadGet, authToken: authToken, params: request))
    }

    public func activityHistory(limit: Int) throws -> BurnBarActivityHistoryResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .usageHistory,
            authToken: authToken,
            params: BurnBarActivityHistoryRequest(limit: limit)
        ))
    }

    public func activitySearch(query: String, limit: Int) throws -> BurnBarSearchQueryResult {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .searchQuery,
            authToken: authToken,
            params: BurnBarSearchQueryRequest(
                query: query,
                resultLimit: limit,
                skipSemanticSearch: true
            )
        ))
    }

    /// Read-only SQL against the daemon's keyed store, for the SIGNED CLI route.
    /// The MCP server cannot dial the control socket itself: production enforces
    /// the first-party code-signature gate and a virtualenv `python` can never
    /// satisfy it, so the encrypted-store fallback has to travel through a peer
    /// the daemon already admits.
    public func searchSQL(_ request: BurnBarSearchSQLRequest) throws -> BurnBarSearchSQLResult {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .searchSQL,
            authToken: authToken,
            params: request
        ))
    }

    /// Memory Blind Sync drain, over the same signed courier as `searchSQL`. The
    /// Python memory engine cannot dial the control socket itself — production
    /// enforces the first-party code-signature gate a virtualenv `python` can
    /// never satisfy — so the only way it reaches the facts the app pulled down
    /// is through this binary.
    public func memorySyncInboxList(
        _ request: BurnBarMemorySyncInboxListRequest
    ) throws -> BurnBarMemorySyncInboxListResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .memorySyncInboxList,
            authToken: authToken,
            params: request
        ))
    }

    /// The write half of the drain: it stamps `applied_at`, so the daemon
    /// classifies it as `memoryWrite` and an attenuated peer cannot mark a
    /// member's memories merged.
    public func memorySyncInboxAck(
        _ request: BurnBarMemorySyncInboxAckRequest
    ) throws -> BurnBarMemorySyncInboxAckResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .memorySyncInboxAck,
            authToken: authToken,
            params: request
        ))
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

    public func linuxPrivacyInventory() throws -> BurnBarLinuxPrivacyInventoryResponse {
        try requestResult(BurnBarRPCRequestEnvelope(method: .linuxPrivacyInventory, authToken: authToken))
    }

    #if os(Linux)
    /// Narrow RPC used by the packaged input-method process. The request body
    /// stays on stdin and the socket credential remains inside this trusted CLI.
    public func textExpansionEngineExpand(
        _ request: BurnBarTextExpansionEngineExpandRequest
    ) throws -> BurnBarTextExpansionEngineExpandResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .textExpansionEngineExpand,
            authToken: authToken,
            params: request
        ))
    }
    #endif

    public func linuxPrivacyDeletionPreview(_ request: BurnBarLinuxPrivacyDeletionPreviewRequest) throws -> BurnBarLinuxPrivacyDeletionPreviewResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .linuxPrivacyDeletionPreview,
            authToken: authToken,
            params: request
        ))
    }

    public func linuxPrivacyDeletionExecute(_ request: BurnBarLinuxPrivacyDeletionExecuteRequest) throws -> BurnBarLinuxPrivacyDeletionExecuteResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .linuxPrivacyDeletionExecute,
            authToken: authToken,
            params: request
        ))
    }

    public func linuxPrivacyExport(_ request: BurnBarLinuxPrivacyExportRequest) throws -> BurnBarLinuxPrivacyExportResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .linuxPrivacyExport,
            authToken: authToken,
            params: request
        ))
    }

    public func linuxPrivacyRetentionStatus() throws -> BurnBarLinuxPrivacyRetentionStatusResponse {
        try requestResult(BurnBarRPCRequestEnvelope(method: .linuxPrivacyRetentionStatus, authToken: authToken))
    }

    public func linuxPrivacyRetentionApply(_ request: BurnBarLinuxPrivacyRetentionApplyRequest) throws -> BurnBarLinuxPrivacyRetentionApplyResponse {
        try requestResult(BurnBarRPCRequestEnvelopeWithParams(
            method: .linuxPrivacyRetentionApply,
            authToken: authToken,
            params: request
        ))
    }

    public func upsertProviderCredentialSlot(
        _ request: BurnBarProviderCredentialSlotUpsertRequest
    ) throws -> BurnBarProviderCredentialSlotMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerCredentialSlotUpsert,
                authToken: authToken,
                params: request
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

    private func requestResult<Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelope
    ) throws -> Response {
        let envelope: BurnBarRPCResponseEnvelope<Response> = try send(request)
        return try unwrap(envelope)
    }

    private func send<Request: Encodable, Response: Codable & Sendable>(
        _ request: Request
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fileDescriptor = socket(AF_UNIX, socketType, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif
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
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        #endif

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

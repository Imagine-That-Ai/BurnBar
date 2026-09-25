import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarInboxModels
import OpenBurnBarKernel

extension OpenBurnBarDaemonSocketClient {
    static func sendEncoded<Request: Encodable, Response: Codable & Sendable>(
        _ request: Request,
        socketURL: URL
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
            let managerError = mapConnectFailure()
            logDaemonFailure(OpenBurnBarError.fromDaemonManager(managerError))
            throw managerError
        }

        let encoder = JSONEncoder()
        let payload = try encoder.encode(request) + Data([0x0A])
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                guard bytesWritten > 0 else {
                    let code = errno
                    if code == ETIMEDOUT || code == EAGAIN {
                        throw OpenBurnBarDaemonManagerError.rpcTimedOut(seconds: 30)
                    }
                    throw POSIXError(.init(rawValue: code) ?? .EIO)
                }
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        response.reserveCapacity(65_536)
        // 64KB chunks: large responses (controller snapshots, mission
        // lists) used to cost one read() syscall per KB
        // (docs/architecture/macos-performance.md §16).
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                let code = errno
                if code == ETIMEDOUT || code == EAGAIN {
                    throw OpenBurnBarDaemonManagerError.rpcTimedOut(seconds: 30)
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        guard response.isEmpty == false else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        do {
            return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
        } catch is DecodingError {
            throw OpenBurnBarDaemonManagerError.rpcError(
                "The daemon response did not match the expected OpenBurnBar RPC envelope."
            )
        }
    }

    static func configureIOTimeouts(for fileDescriptor: Int32, seconds: Int = 30) {
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

    static func socketAddress(for socketPath: String) throws -> sockaddr_un {
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

    // MARK: - AI Inbox control plane
    //
    // Inbox *reads* go straight to the shared SQLite database (see
    // `ControlPlaneStore+AIInbox`) because the rows are already local and the
    // surface should render even while the daemon restarts. These calls are the
    // exception: configuration and "analyze now" are daemon-owned state, and the
    // daemon must stay the single writer of both — it owns the loop, the
    // credentials, and the egress policy.
    //
    // They live in this extension file next to the transport primitives they
    // call; `send` is internal so the lanes can share it.

    static func inboxConfiguration(at socketURL: URL) throws -> BurnBarInboxConfig {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try send(
            BurnBarRPCRequestEnvelope(method: .inboxConfigGet),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    /// Returns the config the daemon actually stored, which can differ from the
    /// request: every value is re-clamped on write. Callers should render the
    /// response rather than assume their request was accepted verbatim.
    @discardableResult
    static func updateInboxConfiguration(
        _ config: BurnBarInboxConfig,
        at socketURL: URL
    ) throws -> BurnBarInboxConfig {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try send(
            BurnBarRPCRequestEnvelopeWithParams(method: .inboxConfigUpdate, params: config),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    static func runInboxNow(force: Bool, at socketURL: URL) throws -> BurnBarInboxRunNowResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxRunNowResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxRunNow,
                params: BurnBarInboxRunNowRequest(force: force)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    /// Tick telemetry plus today's spend. Read over RPC rather than from SQLite
    /// because the authoritative spend figure lives in the daemon's usage ledger,
    /// which the app's mirror lags behind.
    static func inboxRuns(limit: Int = 20, at socketURL: URL) throws -> BurnBarInboxRunsResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxRunsResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxRunsRecent,
                params: BurnBarInboxRunsRequest(limit: limit)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    // MARK: Founder Lens — threads, plans, memory export

    static func inboxThread(fingerprint: String, at socketURL: URL) throws -> BurnBarInboxThread? {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxThreadGetResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxThreadGet,
                params: BurnBarInboxThreadGetRequest(fingerprint: fingerprint)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.thread
    }

    /// A refusal (budget, egress, disabled) arrives as a result with
    /// `refusalReason` set — render it; it is the answer.
    static func inboxReply(
        fingerprint: String,
        bodyMarkdown: String,
        at socketURL: URL
    ) throws -> BurnBarInboxReplyResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxReplyResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxReply,
                params: BurnBarInboxReplyRequest(fingerprint: fingerprint, bodyMarkdown: bodyMarkdown)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    static func inboxPlans(
        statuses: [BurnBarInboxPlanStatus] = [],
        at socketURL: URL
    ) throws -> [BurnBarInboxPlan] {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlansListResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansList,
                params: BurnBarInboxPlansListRequest(statuses: statuses)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.plans
    }

    static func inboxPlanAccept(
        candidate: BurnBarInboxPlanCandidate,
        pack: String,
        at socketURL: URL
    ) throws -> BurnBarInboxPlanAcceptResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlanAcceptResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansAccept,
                params: BurnBarInboxPlanAcceptRequest(candidate: candidate, pack: pack)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    @discardableResult
    static func inboxPlanUpdateStep(
        stepID: String,
        status: BurnBarInboxPlanStepStatus? = nil,
        missionID: String? = nil,
        followupID: String? = nil,
        at socketURL: URL
    ) throws -> BurnBarInboxPlanStep {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlanUpdateStepResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansUpdateStep,
                params: BurnBarInboxPlanUpdateStepRequest(
                    stepID: stepID,
                    status: status,
                    missionID: missionID,
                    followupID: followupID
                )
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.step
    }

    @discardableResult
    static func inboxPlanGrade(
        stepID: String,
        grade: Int,
        noteMarkdown: String? = nil,
        at socketURL: URL
    ) throws -> BurnBarInboxPlanGradeResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlanGradeResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansGrade,
                params: BurnBarInboxPlanGradeRequest(stepID: stepID, grade: grade, noteMarkdown: noteMarkdown)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    /// Full-set push of approved inbox-scoped snippets (revocation by omission).
    @discardableResult
    static func inboxMemoryExport(
        entries: [BurnBarInboxMemoryExportEntry],
        at socketURL: URL
    ) throws -> Int {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxMemoryExportResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxMemoryExport,
                params: BurnBarInboxMemoryExportRequest(entries: entries)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.stored
    }

    /// Create a Mission Control follow-up (capability `mission_control`).
    /// Used by the Founder Plan promote flow; the daemon evaluates and owns
    /// the nudge schedule from here.
    @discardableResult
    static func followupCreate(
        _ request: BurnBarFollowupCreateRequest,
        at socketURL: URL
    ) throws -> BurnBarFollowupMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupCreate,
                params: request
            ),
            socketURL: socketURL
        )
    }
}

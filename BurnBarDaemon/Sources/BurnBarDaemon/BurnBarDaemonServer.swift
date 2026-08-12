import BurnBarCore
import Darwin
import Foundation

public enum BurnBarDaemonError: Error, LocalizedError {
    case socketPathTooLong(String)
    case unexpectedExistingItem(String)
    case failedToCreateSocket(code: Int32, detail: String)
    case failedToBindSocket(path: String, code: Int32, detail: String)
    case failedToListen(path: String, code: Int32, detail: String)
    case failedToCreateParentDirectory(String)
    case requestTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "BurnBar socket path exceeds sockaddr_un capacity: \(path)"
        case .unexpectedExistingItem(let path):
            return "BurnBar socket path already exists with an unsupported file type: \(path)"
        case .failedToCreateSocket(let code, let detail):
            return "Failed to create BurnBar daemon socket (\(code)): \(detail)"
        case .failedToBindSocket(let path, let code, let detail):
            return "Failed to bind BurnBar daemon socket at \(path) (\(code)): \(detail)"
        case .failedToListen(let path, let code, let detail):
            return "Failed to listen on BurnBar daemon socket at \(path) (\(code)): \(detail)"
        case .failedToCreateParentDirectory(let path):
            return "Failed to create BurnBar daemon socket directory: \(path)"
        case .requestTooLarge(let maxBytes):
            return "BurnBar daemon request exceeded the maximum size of \(maxBytes) bytes."
        }
    }
}

private enum BurnBarRPCErrorCode {
    static let invalidRequest = -32600
    static let invalidParams = -32602
    static let methodNotFound = -32601
    static let internalError = -32603
}

private struct IncomingRequestEnvelope: Decodable {
    let id: String
    let method: String
}

private struct BurnBarEmptyResult: Codable, Sendable {}

public actor BurnBarDaemonServer {
    private static let maxRequestBytes = 64 * 1024

    public let configuration: BurnBarDaemonConfiguration

    private let logger: BurnBarDaemonLogger
    private let configStore: BurnBarConfigStore
    private let usageRecorder: BurnBarUsageRecorder
    private let clientRegistry: BurnBarClientRegistry
    private let runService: BurnBarRunService
    private let indexedSearch: BurnBarIndexedSearchService?
    private var listenerFileDescriptor: Int32?
    private var acceptLoopTask: Task<Void, Never>?

    public init(
        configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(),
        configStore: BurnBarConfigStore? = nil,
        usageRecorder: BurnBarUsageRecorder? = nil,
        clientRegistry: BurnBarClientRegistry? = nil,
        runService: BurnBarRunService? = nil
    ) {
        self.configuration = configuration
        self.logger = logger

        let resolvedConfigStore = configStore ?? BurnBarConfigStore(
            catalog: configuration.catalog,
            logger: BurnBarDaemonLogger(category: "config-store")
        )
        let resolvedUsageRecorder = usageRecorder ?? BurnBarUsageRecorder(
            logger: BurnBarDaemonLogger(category: "usage-recorder")
        )
        let resolvedClientRegistry = clientRegistry ?? BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "client-registry")
        )
        let resolvedRunService = runService ?? BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: resolvedConfigStore,
                logger: BurnBarDaemonLogger(category: "provider-router")
            ),
            usageRecorder: resolvedUsageRecorder,
            clientRegistry: resolvedClientRegistry,
            logger: BurnBarDaemonLogger(category: "run-service")
        )

        self.configStore = resolvedConfigStore
        self.usageRecorder = resolvedUsageRecorder
        self.clientRegistry = resolvedClientRegistry
        self.runService = resolvedRunService

        if let path = configuration.indexDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.isEmpty == false,
           FileManager.default.fileExists(atPath: path) {
            self.indexedSearch = try? BurnBarIndexedSearchService(
                databasePath: path,
                logger: BurnBarDaemonLogger(category: "indexed-search")
            )
        } else {
            self.indexedSearch = nil
        }
    }

    public func start() throws {
        guard listenerFileDescriptor == nil else {
            logger.debug(
                "bootstrap_start_skipped",
                metadata: ["socket_path": configuration.socketPath]
            )
            return
        }

        logger.info(
            "bootstrap_starting",
            metadata: [
                "socket_path": configuration.socketPath,
                "daemon_version": configuration.daemonVersion,
                "protocol_version": "\(BurnBarProtocolVersion.current)"
            ]
        )

        try BurnBarUnixDomainSocket.ensureParentDirectory(for: configuration.socketPath)
        if let removedType = try BurnBarUnixDomainSocket.removeStaleItemIfPresent(at: configuration.socketPath) {
            logger.notice(
                "stale_socket_removed",
                metadata: [
                    "socket_path": configuration.socketPath,
                    "item_type": removedType
                ]
            )
        }

        let fileDescriptor = try BurnBarUnixDomainSocket.makeListeningSocket(at: configuration.socketPath)
        listenerFileDescriptor = fileDescriptor

        acceptLoopTask = Task.detached(priority: .background) { [logger] in
            await Self.runAcceptLoop(
                server: self,
                listenerFileDescriptor: fileDescriptor,
                logger: logger
            )
        }

        logger.notice(
            "bootstrap_ready",
            metadata: ["socket_path": configuration.socketPath]
        )
    }

    public func stop() {
        guard let listenerFileDescriptor else {
            logger.debug(
                "shutdown_skipped",
                metadata: ["socket_path": configuration.socketPath]
            )
            return
        }

        logger.info(
            "shutdown_starting",
            metadata: ["socket_path": configuration.socketPath]
        )

        self.listenerFileDescriptor = nil
        acceptLoopTask?.cancel()
        acceptLoopTask = nil

        shutdown(listenerFileDescriptor, SHUT_RDWR)
        close(listenerFileDescriptor)
        _ = try? BurnBarUnixDomainSocket.removeStaleItemIfPresent(at: configuration.socketPath)

        logger.notice(
            "shutdown_complete",
            metadata: ["socket_path": configuration.socketPath]
        )
    }

    public func healthResponse() -> BurnBarHealthResponse {
        BurnBarHealthResponse(
            ok: true,
            daemonVersion: configuration.daemonVersion,
            protocolVersion: BurnBarProtocolVersion.current,
            socketPath: configuration.socketPath
        )
    }

    private func responseData(for requestData: Data) async -> Data {
        do {
            let decoder = JSONDecoder()
            let incomingRequest = try decoder.decode(IncomingRequestEnvelope.self, from: requestData)

            guard let method = BurnBarRPCMethod(rawValue: incomingRequest.method) else {
                logger.error(
                    "rpc_method_not_found",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method
                    ]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Unsupported BurnBar RPC method '\(incomingRequest.method)'."
                )
            }

            let request = BurnBarRPCRequestEnvelope(id: incomingRequest.id, method: method)

            switch method {
            case .health:
                _ = BurnBarHealthRequest()
                logger.debug(
                    "rpc_request_received",
                    metadata: [
                        "request_id": request.id,
                        "method": method.rawValue
                    ]
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: request.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: healthResponse()
                )
                return encode(response)
            case .catalog:
                _ = BurnBarCatalogRequest()
                logger.debug(
                    "rpc_request_received",
                    metadata: [
                        "request_id": request.id,
                        "method": method.rawValue
                    ]
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: request.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarCatalogResponse(catalog: configuration.catalog)
                )
                return encode(response)
            case .configGet:
                let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
                _ = BurnBarConfigGetRequest()
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarConfigResponse(snapshot: try await configStore.snapshot())
                )
                return encode(response)
            case .configUpdate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarConfigUpdateRequest>.self,
                    from: requestData
                )
                let snapshot = try await configStore.replaceSnapshot(typedRequest.params.snapshot)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarConfigResponse(snapshot: snapshot)
                )
                return encode(response)
            case .usageRecent:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarRecentUsageRequest>.self,
                    from: requestData
                )
                let usage = try await usageRecorder.recentUsage(limit: typedRequest.params.limit)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarRecentUsageResponse(usage: usage)
                )
                return encode(response)
            case .clientAttach:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarClientAttachRequest>.self,
                    from: requestData
                )
                let (attachResponse, arbitration) = await clientRegistry.attach(typedRequest.params)
                logger.notice(
                    "client_arbitration_updated",
                    metadata: [
                        "active_client_id": arbitration.activeClientID?.rawValue ?? "none",
                        "reason": arbitration.reason ?? "none"
                    ]
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: attachResponse
                )
                return encode(response)
            case .clientDetach:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarClientDetachRequest>.self,
                    from: requestData
                )
                let arbitration = try await clientRegistry.detach(typedRequest.params)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: arbitration
                )
                return encode(response)
            case .clientClaimControl:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarClientClaimControlRequest>.self,
                    from: requestData
                )
                let arbitration = try await clientRegistry.claimControl(typedRequest.params)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: arbitration
                )
                return encode(response)
            case .runCreate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarRunCreateRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.createRun(typedRequest.params)
                )
                return encode(response)
            case .runList:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarRunListRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.listRuns(typedRequest.params)
                )
                return encode(response)
            case .runGet:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarRunGetRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.getRun(typedRequest.params)
                )
                return encode(response)
            case .runPoll:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarRunPollRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.pollRuns(typedRequest.params)
                )
                return encode(response)
            case .runCancel:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarRunCancelRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.cancelRun(typedRequest.params)
                )
                return encode(response)
            case .runRetry:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarRunRetryRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.retryRun(typedRequest.params)
                )
                return encode(response)
            case .workspaceExecuteTool:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarToolExecutionRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.executeTool(typedRequest.params)
                )
                return encode(response)
            case .workspaceToolResult:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarToolResultSubmissionRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.submitToolResult(typedRequest.params)
                )
                return encode(response)
            case .approvalRespond:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarApprovalRespondRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.respondToApproval(typedRequest.params)
                )
                return encode(response)
            case .searchQuery:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarSearchQueryRequest>.self,
                    from: requestData
                )
                guard let indexedSearch else {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.internalError,
                        message:
                            "BurnBar indexed search is not available. Ensure BURNBAR_INDEX_DATABASE_PATH points to your BurnBar database and restart the daemon."
                    )
                }
                do {
                    let result = try indexedSearch.search(query: typedRequest.params)
                    let response = BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        protocolVersion: BurnBarProtocolVersion.current,
                        result: result
                    )
                    return encode(response)
                } catch {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.internalError,
                        message: error.localizedDescription
                    )
                }
            case .fleetSnapshot, .fleetOrchestratorGet, .fleetOrchestratorSet, .fleetDirectiveRecord:
                // M0 placeholder: the fleet RPC methods are part of the contract
                // (BurnBarRPCMethod raw values) but have no handlers yet. M1's
                // daemon-fleet-rpc-core replaces these arms with real handlers
                // delegating to BurnBarFleetService. Until then every fleet call
                // returns this documented typed error; the daemon keeps serving.
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: "BurnBar RPC method '\(method.rawValue)' is not yet implemented."
                )
            }
        } catch {
            logger.error(
                "rpc_request_failed",
                metadata: ["error": "\(error)"]
            )
            return encodeErrorResponse(
                id: "invalid-request",
                code: error is DecodingError ? BurnBarRPCErrorCode.invalidParams : BurnBarRPCErrorCode.internalError,
                message: error.localizedDescription
            )
        }
    }

    private func encode<Result: Codable & Sendable>(_ envelope: BurnBarRPCResponseEnvelope<Result>) -> Data {
        do {
            let encoder = JSONEncoder()
            return try encoder.encode(envelope)
        } catch {
            logger.error(
                "rpc_encode_failed",
                metadata: ["error": "\(error)"]
            )
            return encodeErrorResponse(
                id: envelope.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "Failed to encode BurnBar RPC response."
            )
        }
    }

    private func encodeErrorResponse(id: String, code: Int, message: String) -> Data {
        let envelope = BurnBarRPCResponseEnvelope<BurnBarEmptyResult>(
            id: id,
            protocolVersion: BurnBarProtocolVersion.current,
            result: nil,
            error: BurnBarRPCError(code: code, message: message)
        )

        let encoder = JSONEncoder()
        return (try? encoder.encode(envelope)) ?? Data()
    }

    private static func runAcceptLoop(
        server: BurnBarDaemonServer,
        listenerFileDescriptor: Int32,
        logger: BurnBarDaemonLogger
    ) async {
        while !Task.isCancelled {
            let clientFileDescriptor = accept(listenerFileDescriptor, nil, nil)
            if clientFileDescriptor == -1 {
                let code = errno
                if code == EINTR {
                    continue
                }

                if code == EBADF || code == EINVAL || Task.isCancelled {
                    break
                }

                logger.error(
                    "accept_failed",
                    metadata: ["errno": "\(code)"]
                )
                continue
            }

            Task.detached(priority: .utility) { [logger] in
                await Self.handleClientConnection(
                    server: server,
                    clientFileDescriptor: clientFileDescriptor,
                    logger: logger
                )
            }
        }

        logger.debug("accept_loop_stopped")
    }

    private static func handleClientConnection(
        server: BurnBarDaemonServer,
        clientFileDescriptor: Int32,
        logger: BurnBarDaemonLogger
    ) async {
        defer {
            close(clientFileDescriptor)
        }

        BurnBarUnixDomainSocket.configureNoSigPipe(for: clientFileDescriptor)

        do {
            let requestData = try BurnBarUnixDomainSocket.readRequest(
                from: clientFileDescriptor,
                maxBytes: maxRequestBytes
            )
            let responseData = await server.responseData(for: requestData) + Data([0x0A])
            try BurnBarUnixDomainSocket.writeAll(responseData, to: clientFileDescriptor)
            logger.debug(
                "rpc_response_sent",
                metadata: ["bytes": "\(responseData.count)"]
            )
        } catch {
            logger.error(
                "client_request_failed",
                metadata: ["error": "\(error)"]
            )
        }
    }
}

private enum BurnBarUnixDomainSocket {
    static func ensureParentDirectory(for socketPath: String) throws {
        let socketURL = URL(fileURLWithPath: socketPath)
        let directoryURL = socketURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw BurnBarDaemonError.failedToCreateParentDirectory(directoryURL.path)
        }
    }

    static func removeStaleItemIfPresent(at socketPath: String) throws -> String? {
        var fileStatus = stat()
        let result = lstat(socketPath, &fileStatus)
        if result == -1 {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let itemType = fileStatus.st_mode & S_IFMT
        guard itemType == S_IFSOCK || itemType == S_IFREG else {
            throw BurnBarDaemonError.unexpectedExistingItem(socketPath)
        }

        try FileManager.default.removeItem(atPath: socketPath)
        return itemType == S_IFSOCK ? "socket" : "file"
    }

    static func makeListeningSocket(at socketPath: String) throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw BurnBarDaemonError.failedToCreateSocket(
                code: errno,
                detail: String(cString: strerror(errno))
            )
        }

        configureNoSigPipe(for: fileDescriptor)

        do {
            var address = try makeSocketAddress(for: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                    bind(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
                }
            }

            guard bindResult == 0 else {
                let code = errno
                throw BurnBarDaemonError.failedToBindSocket(
                    path: socketPath,
                    code: code,
                    detail: String(cString: strerror(code))
                )
            }

            guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                let code = errno
                throw BurnBarDaemonError.failedToListen(
                    path: socketPath,
                    code: code,
                    detail: String(cString: strerror(code))
                )
            }

            return fileDescriptor
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    static func readRequest(from fileDescriptor: Int32, maxBytes: Int) throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(1024)

        var chunk = [UInt8](repeating: 0, count: 1024)

        while true {
            let bytesRead = read(fileDescriptor, &chunk, chunk.count)
            if bytesRead == 0 {
                break
            }

            if bytesRead < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }

            buffer.append(contentsOf: chunk.prefix(bytesRead))
            if buffer.count > maxBytes {
                throw BurnBarDaemonError.requestTooLarge(maxBytes)
            }

            if buffer.last == 0x0A {
                break
            }
        }

        while buffer.last == 0x0A || buffer.last == 0x0D {
            buffer.removeLast()
        }

        return buffer
    }

    static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var bytesRemaining = rawBuffer.count
            var writeOffset = 0

            while bytesRemaining > 0 {
                let pointer = baseAddress.advanced(by: writeOffset)
                let bytesWritten = write(fileDescriptor, pointer, bytesRemaining)
                if bytesWritten < 0 {
                    let code = errno
                    if code == EINTR {
                        continue
                    }
                    throw POSIXError(.init(rawValue: code) ?? .EIO)
                }

                bytesRemaining -= bytesWritten
                writeOffset += bytesWritten
            }
        }
    }

    static func configureNoSigPipe(for fileDescriptor: Int32) {
        var value: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    private static func makeSocketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maxPathLength else {
            throw BurnBarDaemonError.socketPathTooLong(socketPath)
        }

        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        #endif

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }
}

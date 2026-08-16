import BurnBarCore
import Darwin
import Foundation

public enum BurnBarDaemonError: Error, LocalizedError {
    case socketPathTooLong(String)
    case unexpectedExistingItem(String)
    case failedToCreateSocket(code: Int32, detail: String)
    case failedToBindSocket(path: String, code: Int32, detail: String)
    case failedToListen(path: String, code: Int32, detail: String)
    case failedToSetSocketPermissions(path: String, code: Int32, detail: String)
    case failedToCreateParentDirectory(String)
    /// The request frame exceeded the 64KB payload cap. The second associated
    /// value is the partial frame read so far (used to recover the request id
    /// for the typed oversize error response).
    case requestTooLarge(Int, Data)

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
        case .failedToSetSocketPermissions(let path, let code, let detail):
            return "Failed to set owner-only permissions on BurnBar daemon socket at \(path) (\(code)): \(detail)"
        case .failedToCreateParentDirectory(let path):
            return "Failed to create BurnBar daemon socket directory: \(path)"
        case .requestTooLarge(let maxBytes, _):
            return "BurnBar daemon request exceeded the maximum size of \(maxBytes) bytes."
        }
    }
}

public actor BurnBarDaemonServer {
    private static let maxRequestBytes = 64 * 1024

    /// Documented id used in error envelopes when the request id is absent or
    /// not syntactically recoverable (VAL-RPC-011/016). The daemon never
    /// fabricates a client-supplied id.
    static let noRequestID = BurnBarRPCErrorEnvelope.noRequestID

    private struct IncomingRequestEnvelope: Decodable {
        let id: String
        let method: String
        /// Optional declared protocol version. Absent = v1 (existing clients
        /// predate the field); a declared version outside the supported set is
        /// rejected typed (VAL-RPC-012) — never silently processed under v1.
        let protocolVersion: Int?
    }

    public let configuration: BurnBarDaemonConfiguration

    private let logger: BurnBarDaemonLogger
    private let configStore: BurnBarConfigStore
    private let usageRecorder: BurnBarUsageRecorder
    private let clientRegistry: BurnBarClientRegistry
    private let runService: BurnBarRunService
    private let indexedSearch: BurnBarIndexedSearchService?
    let fleetService: BurnBarFleetService
    private var listenerFileDescriptor: Int32?
    private var acceptLoopTask: Task<Void, Never>?

    public init(
        configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(),
        configStore: BurnBarConfigStore? = nil,
        usageRecorder: BurnBarUsageRecorder? = nil,
        clientRegistry: BurnBarClientRegistry? = nil,
        runService: BurnBarRunService? = nil,
        fleetService: BurnBarFleetService? = nil
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

        if let fleetService {
            self.fleetService = fleetService
        } else {
            self.fleetService = BurnBarFleetServiceFactory.makeDefault(configuration: configuration)
        }
    }

    public func start() async throws {
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

        // Open the fleet persistence layer (fleet.sqlite + well-known file).
        // Corruption is recovered typed (delete + recreate) — the daemon
        // never crashes over a corrupt fleet store. A non-corrupt open
        // failure degrades persistenceHealth (typed storeUnavailable) and is
        // logged; the daemon keeps serving with the degraded health surface.
        if let persister = await fleetService.persister {
            do {
                try persister.open()
            } catch {
                logger.error(
                    "fleet_persistence_open_failed",
                    metadata: ["reason": "\(error)"]
                )
            }
        }

        await fleetService.start()

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

    public func stop() async {
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

        await fleetService.stop()

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
}

// MARK: - RPC dispatch

extension BurnBarDaemonServer {
    private func responseData(for requestData: Data) async -> Data {
        var enteredDispatch = false
        do {
            let decoder = JSONDecoder()
            let incomingRequest = try decoder.decode(IncomingRequestEnvelope.self, from: requestData)

            // Declared protocol version outside the supported set is a typed
            // mismatch (VAL-RPC-012) — never silent v1 processing.
            if let declared = incomingRequest.protocolVersion,
               !BurnBarProtocolVersion.supported.contains(declared) {
                logger.error(
                    "rpc_protocol_version_mismatch",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "declared_version": "\(declared)"
                    ]
                )
                return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.protocolVersionMismatch,
                    message:
                        "BurnBar RPC protocol version \(declared) is not supported. "
                        + "Supported versions: \(BurnBarProtocolVersion.supported).",
                    details:
                        "declared_version=\(declared); supported_versions=\(BurnBarProtocolVersion.supported)"
                )
            }

            guard let method = BurnBarRPCMethod(rawValue: incomingRequest.method) else {
                logger.error(
                    "rpc_method_not_found",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method
                    ]
                )
                return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Unsupported BurnBar RPC method '\(incomingRequest.method)'.",
                    details: "method=\(incomingRequest.method)"
                )
            }

            let request = BurnBarRPCRequestEnvelope(id: incomingRequest.id, method: method)
            enteredDispatch = true
            return try await dispatch(
                method: method,
                request: request,
                requestData: requestData,
                decoder: decoder
            )
        } catch {
            logger.error(
                "rpc_request_failed",
                metadata: ["error": "\(error)"]
            )
            // Typed error envelope for malformed requests (VAL-RPC-003/011):
            // the id is echoed when it is syntactically recoverable, else the
            // documented no-id sentinel is used. Classification:
            // - not valid JSON at all → parse error (-32700);
            // - valid JSON with a wrong envelope shape (missing/wrong-typed
            //   id or method) → invalid request (-32600);
            // - well-formed envelope whose params fail to decode → invalid
            //   params (-32602).
            let recoveredID = BurnBarRPCErrorEnvelope.recoverRequestID(from: requestData)
            let code: Int
            let details: String
            if error is BurnBarRPCRequestShapeDecodingError {
                if (try? JSONDecoder().decode(IncomingRequestEnvelope.self, from: requestData)) != nil {
                    // Well-formed envelope whose params fail to decode.
                    code = BurnBarRPCErrorCode.invalidParams
                    details = "expected_params=object; received=\(Self.describeTopLevelType(requestData))"
                } else if BurnBarRPCErrorEnvelope.isValidJSONObject(requestData) {
                    // Valid JSON with a wrong envelope shape.
                    code = BurnBarRPCErrorCode.invalidRequest
                    details = "expected_envelope={\"id\":string,\"method\":string,\"protocolVersion\"?:int}"
                } else {
                    // Not valid JSON at all.
                    code = BurnBarRPCErrorCode.parseError
                    details = "expected=json_object; received=non_json_bytes"
                }
            } else if enteredDispatch {
                // A handler-side DecodingError (for example, malformed
                // persisted config) is a daemon failure, not client params.
                code = BurnBarRPCErrorCode.internalError
                details = "error=\(error)"
            } else if error is DecodingError {
                // This is the initial envelope decode, before dispatch.
                if BurnBarRPCErrorEnvelope.isValidJSONObject(requestData) {
                    code = BurnBarRPCErrorCode.invalidRequest
                    details = "expected_envelope={\"id\":string,\"method\":string,\"protocolVersion\"?:int}"
                } else {
                    code = BurnBarRPCErrorCode.parseError
                    details = "expected=json_object; received=non_json_bytes"
                }
            } else {
                code = BurnBarRPCErrorCode.internalError
                details = "error=\(error)"
            }
            return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                id: recoveredID,
                code: code,
                message: error.localizedDescription,
                details: details
            )
        }
    }

    /// Describes the top-level JSON type of a request frame's `params` value
    /// for error `details` (e.g. a string `params` vs an object). Never
    /// includes payload content — only the type name.
    private static func describeTopLevelType(_ requestData: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let params = object["params"] else {
            return "absent"
        }
        switch params {
        case is [String: Any]:
            return "object"
        case is [Any]:
            return "array"
        case is String:
            return "string"
        case is Bool:
            return "boolean"
        case is NSNumber:
            return "number"
        default:
            return "null"
        }
    }

    /// Dispatches one decoded request to its method handler. Kept separate
    /// from `responseData(for:)` so the envelope/error handling stays small
    /// and the method switch stays readable.
    private func dispatch(
        method: BurnBarRPCMethod,
        request: BurnBarRPCRequestEnvelope,
        requestData: Data,
        decoder: JSONDecoder
    ) async throws -> Data {
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
            let typedRequest = try decodeRequest(BurnBarRPCRequestEnvelope.self, from: requestData, decoder: decoder)
            _ = BurnBarConfigGetRequest()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarConfigResponse(snapshot: try await configStore.snapshot())
            )
            return encode(response)
        case .configUpdate:
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
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
            let typedRequest = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSearchQueryRequest>.self,
                from: requestData
            )
            guard let indexedSearch else {
                return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message:
                        "BurnBar indexed search is not available. Ensure BURNBAR_INDEX_DATABASE_PATH points to your BurnBar database and restart the daemon.",
                    details: "index_database_path=\(configuration.indexDatabasePath ?? "unset")"
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
                return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription,
                    details: "error=\(error)"
                )
            }
        case .fleetSnapshot:
            return try await handleFleetSnapshot(requestData: requestData, decoder: decoder)
        case .fleetOrchestratorGet:
            // M4 handlers live in BurnBarDaemonServer+FleetControl.swift.
            return try await handleFleetOrchestratorGet(requestData: requestData, decoder: decoder)
        case .fleetOrchestratorSet:
            return try await handleFleetOrchestratorSet(
                requestData: requestData,
                decoder: decoder,
                method: method.rawValue
            )
        case .fleetDirectiveRecord:
            return try await handleFleetDirectiveRecord(
                requestData: requestData,
                decoder: decoder,
                method: method.rawValue
            )
        }
    }

    func encode<Result: Codable & Sendable>(_ envelope: BurnBarRPCResponseEnvelope<Result>) -> Data {
        do {
            let encoder = JSONEncoder()
            return try encoder.encode(envelope)
        } catch {
            logger.error(
                "rpc_encode_failed",
                metadata: ["error": "\(error)"]
            )
            return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                id: envelope.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "Failed to encode BurnBar RPC response.",
                details: "error=\(error)"
            )
        }
    }
}

// MARK: - Connection handling

extension BurnBarDaemonServer {
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
        } catch let error as BurnBarDaemonError {
            // Oversized frames get a typed error response (VAL-RPC-004/016)
            // instead of a silent close: the daemon stays healthy and the
            // next request on a fresh connection succeeds.
            if case .requestTooLarge(let maxBytes, let partialFrame) = error {
                logger.error(
                    "rpc_request_too_large",
                    metadata: ["max_bytes": "\(maxBytes)"]
                )
                let recoveredID = BurnBarRPCErrorEnvelope.recoverRequestID(from: partialFrame)
                // The cap counts raw UTF-8 payload bytes EXCLUDING the trailing
                // newline delimiter (VAL-RPC-004); report the same accounting.
                let payloadBytes = partialFrame.count - (partialFrame.last == 0x0A ? 1 : 0)
                let responseData = BurnBarRPCErrorEnvelope.encodeErrorResponse(
                    id: recoveredID,
                    code: BurnBarRPCErrorCode.frameTooLarge,
                    message: error.localizedDescription,
                    details: "max_bytes=\(maxBytes); received_bytes=\(payloadBytes)"
                ) + Data([0x0A])
                try? BurnBarUnixDomainSocket.writeAll(responseData, to: clientFileDescriptor)
                return
            }
            logger.error(
                "client_request_failed",
                metadata: ["error": "\(error)"]
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
        // AF_UNIX path permissions inherit the process umask at bind time.
        // Narrow it for this short setup window, then restore the caller's
        // setting before returning so daemon startup cannot publish a
        // group/world-readable socket.
        let previousUmask = umask(mode_t(0o077))
        defer { _ = umask(previousUmask) }

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

            // `bind(2)` applies the narrowed umask above. Set the exact
            // documented owner-only mode on the path before listening;
            // macOS does not support fchmod(2) on an AF_UNIX socket
            // descriptor, so chmod(2) is the portable path operation here.
            let permissionResult = socketPath.withCString {
                chmod($0, mode_t(0o600))
            }
            guard permissionResult == 0 else {
                let code = errno
                throw BurnBarDaemonError.failedToSetSocketPermissions(
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
            // The frame-size cap counts raw UTF-8 payload bytes EXCLUDING the
            // newline delimiter (VAL-RPC-004): a payload of exactly 65536
            // bytes plus its newline is at-cap, not oversize.
            if buffer.last == 0x0A {
                if buffer.count - 1 > maxBytes {
                    throw BurnBarDaemonError.requestTooLarge(maxBytes, buffer)
                }
                break
            }
            if buffer.count > maxBytes {
                throw BurnBarDaemonError.requestTooLarge(maxBytes, buffer)
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

// MARK: - Fleet RPC handling

extension BurnBarDaemonServer {
    /// Handles `daemon.fleet.snapshot`. The request carries no parameters;
    /// the plain envelope is decoded so both `{"id":...,"method":"daemon.fleet.snapshot"}`
    /// and a params-bearing form are accepted. Pre-first-tick reads return
    /// the typed not-ready error — never a fabricated snapshot.
    private func handleFleetSnapshot(requestData: Data, decoder: JSONDecoder) async throws -> Data {
        let typedRequest = try decodeRequest(BurnBarRPCRequestEnvelope.self, from: requestData, decoder: decoder)
        let readState = await fleetService.readLatestSnapshot()
        switch readState {
        case .notReady:
            return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message:
                    "BurnBar fleet snapshot is not ready yet: the first probe tick has not completed. Retry shortly.",
                details: "state=not_ready; retry_after=first_tick"
            )
        case .degraded(let reason, _):
            return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "BurnBar fleet snapshot tick degraded: \(reason)",
                details: "state=current_tick_degraded; reason=\(reason)"
            )
        case .ready(let snapshot):
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarFleetSnapshotResponse(snapshot: snapshot)
            )
            return encode(response)
        }
    }
}

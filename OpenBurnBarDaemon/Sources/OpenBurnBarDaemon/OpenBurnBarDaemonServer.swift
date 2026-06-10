import OpenBurnBarCore
import Darwin
import Foundation

public actor BurnBarDaemonServer {
    private static let maxRequestBytes = 64 * 1024

    public let configuration: BurnBarDaemonConfiguration

    let logger: BurnBarDaemonLogger
    let configStore: BurnBarConfigStore
    let usageRecorder: BurnBarUsageRecorder
    let proxyRouteLogStore: BurnBarProxyRouteLogStore
    let clientRegistry: BurnBarClientRegistry
    let runService: BurnBarRunService
    let toolingProxy: BurnBarToolingProxyService
    let computerUseService: ComputerUseService
    let missionControlService: any BurnBarMissionControlServing
    let indexedSearch: BurnBarIndexedSearchService?
    let resumeService: BurnBarResumeService?
    private let gatewayServer: BurnBarHTTPGatewayServer?
    private let rateLimiter: BurnBarRateLimiter?
    private var listenerFileDescriptor: Int32?
    private var acceptLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    public init(
        configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(),
        configStore: BurnBarConfigStore? = nil,
        usageRecorder: BurnBarUsageRecorder? = nil,
        proxyRouteLogStore: BurnBarProxyRouteLogStore? = nil,
        clientRegistry: BurnBarClientRegistry? = nil,
        runService: BurnBarRunService? = nil,
        missionControlService: (any BurnBarMissionControlServing)? = nil,
        rateLimiter: BurnBarRateLimiter? = nil
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
        let resolvedProxyRouteLogStore = proxyRouteLogStore ?? BurnBarProxyRouteLogStore(
            logger: BurnBarDaemonLogger(category: "proxy-route-log")
        )
        let resolvedClientRegistry = clientRegistry ?? BurnBarClientRegistry(
            logger: BurnBarDaemonLogger(category: "client-registry")
        )
        let resolvedRunService = runService ?? BurnBarRunService(
            router: BurnBarProviderRouter(
                configStore: resolvedConfigStore,
                logger: BurnBarDaemonLogger(category: "provider-router"),
                routingEventStore: BurnBarProviderRoutingDecisionEventStore()
            ),
            usageRecorder: resolvedUsageRecorder,
            clientRegistry: resolvedClientRegistry,
            logger: BurnBarDaemonLogger(category: "run-service")
        )

        self.configStore = resolvedConfigStore
        self.usageRecorder = resolvedUsageRecorder
        self.proxyRouteLogStore = resolvedProxyRouteLogStore
        self.clientRegistry = resolvedClientRegistry
        self.runService = resolvedRunService
        self.toolingProxy = BurnBarToolingProxyService(
            connectorPlaneService: resolvedRunService.connectorPlaneService,
            browserToolService: resolvedRunService.browserToolService
        )
        self.computerUseService = ComputerUseService()
        self.rateLimiter = rateLimiter ?? BurnBarRateLimiter(configuration: configuration.socketRateLimit)
        // VAL-DAEMON-011: Wire a concrete execution readiness gate with fail-closed semantics.
        // When gate data is unavailable (no config, no connector plane), the gate returns a failure
        // with an explicit reason code instead of allowing dispatch to proceed (fail-open).
        //
        // Note: The readiness gate is @Sendable and runs on BurnBarMissionControlService actor.
        // We can only call async actor methods from this closure. For sync actor methods like
        // configStore.snapshot(), we rely on the fact that connectorPlaneSnapshot() validates
        // both runtime availability AND provider credentials (since connectors are backed by
        // the same credential system).
        let resolvedToolingProxy = self.toolingProxy
        let executionReadinessGate: BurnBarExecutionReadinessGate = { @Sendable mission, packet in
            // Check 1: Verify connector plane runtime is accessible
            // This also implicitly validates that provider credentials are accessible since
            // the connector plane is backed by the same secret store.
            do {
                let connectorPlane = try await resolvedToolingProxy.connectorPlaneSnapshot()
                // If connector plane has no enabled/healthy connectors, runtime is unavailable
                let hasEnabledConnector = connectorPlane.connectors.contains { $0.isEnabled }
                if !hasEnabledConnector {
                    return BurnBarExecutionReadiness(
                        code: .runtimeUnavailable,
                        detail: "No connector plane runtime is configured. Configure at least one provider in OpenBurnBar Settings before dispatching missions."
                    )
                }
                // Also check that at least one connector has a valid secret (credentials configured)
                let hasConnectorWithCredentials = connectorPlane.connectors.contains { connector in
                    connector.isEnabled && connector.secretConfigured
                }
                if !hasConnectorWithCredentials {
                    return BurnBarExecutionReadiness(
                        code: .missingCredential,
                        detail: "No AI provider credentials are configured. Add provider credentials in OpenBurnBar Settings before dispatching missions."
                    )
                }
            } catch {
                return BurnBarExecutionReadiness(
                    code: .runtimeUnavailable,
                    detail: "Connector plane runtime is unavailable: \(error.localizedDescription)"
                )
            }

            // All checks passed - mission is ready to dispatch
            return nil
        }

        self.missionControlService = missionControlService ?? BurnBarMissionControlService(
            store: BurnBarMissionControlStore(
                logger: BurnBarDaemonLogger(category: "mission-control-store")
            ),
            logger: BurnBarDaemonLogger(category: "mission-control-service"),
            activitySnapshotURL: BurnBarDaemonPaths.defaultControllerActivitySnapshotURL,
            reviewRunLauncher: { prompt, modelID, metadata in
                try await resolvedRunService.createDaemonManagedRun(
                    prompt: prompt,
                    modelID: modelID,
                    metadata: metadata
                )
            },
            runSnapshotLookup: { runID in
                await resolvedRunService.snapshot(for: runID)
            },
            executionReadinessGate: executionReadinessGate
        )

        if let path = configuration.indexDatabasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.isEmpty == false,
           FileManager.default.fileExists(atPath: path) {
            do {
                self.indexedSearch = try BurnBarIndexedSearchService(
                    databasePath: path,
                    logger: BurnBarDaemonLogger(category: "indexed-search")
                )
            } catch {
                logger.warning(
                    "indexed_search_init_failed",
                    metadata: ["path": path, "error": "\(error)"]
                )
                self.indexedSearch = nil
            }
            do {
                self.resumeService = try BurnBarResumeService(
                    databasePath: path,
                    logger: BurnBarDaemonLogger(category: "resume-service")
                )
            } catch {
                logger.warning(
                    "resume_service_init_failed",
                    metadata: ["path": path, "error": "\(error)"]
                )
                self.resumeService = nil
            }
        } else {
            self.indexedSearch = nil
            self.resumeService = nil
        }

        // HTTP gateway — only initialized if enabled.
        if configuration.gateway.isEnabled {
            self.gatewayServer = BurnBarHTTPGatewayServer(
                configuration: configuration.gateway,
                configStore: resolvedConfigStore,
                usageRecorder: resolvedUsageRecorder,
                proxyRouteLogStore: resolvedProxyRouteLogStore,
                logger: BurnBarDaemonLogger(category: "http-gateway")
            )
        } else {
            self.gatewayServer = nil
        }
    }

    public func start() async throws {
        try configuration.validate()

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
        try BurnBarUnixDomainSocket.restrictSocketPermissions(at: configuration.socketPath)
        listenerFileDescriptor = fileDescriptor

        do {
            try await configStore.seedDefaultModelVariantsIfNeeded()
        } catch {
            logger.warning(
                "default_model_variants_seed_failed",
                metadata: ["error": "\(error)"]
            )
        }

        acceptLoopTask = Task.detached(priority: .background) { [logger] in
            await Self.runAcceptLoop(
                server: self,
                listenerFileDescriptor: fileDescriptor,
                logger: logger
            )
        }
        heartbeatTask = BurnBarDaemonHeartbeat.startPeriodicWriter(
            daemonVersion: configuration.daemonVersion
        )
        if configuration.startsMissionControlBackgroundLoops {
            await missionControlService.startBackgroundLoops()
        } else {
            logger.debug(
                "mission_control_background_loops_disabled",
                metadata: ["socket_path": configuration.socketPath]
            )
        }

        logger.notice(
            "bootstrap_ready",
            metadata: ["socket_path": configuration.socketPath]
        )

        // Start HTTP gateway if configured
        if let gatewayServer {
            do {
                try await gatewayServer.start()
            } catch {
                logger.error(
                    "gateway_start_failed",
                    metadata: ["error": "\(error)"]
                )
            }
        }
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
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let acceptTask = acceptLoopTask
        acceptLoopTask = nil
        acceptTask?.cancel()

        shutdown(listenerFileDescriptor, SHUT_RDWR)
        close(listenerFileDescriptor)
        _ = await acceptTask?.result

        do {
            _ = try BurnBarUnixDomainSocket.removeStaleItemIfPresent(at: configuration.socketPath)
        } catch {
            logger.warning(
                "remove_stale_socket_failed",
                metadata: ["socket_path": configuration.socketPath, "error": "\(error)"]
            )
        }
        await missionControlService.stopBackgroundLoops()

        // Stop HTTP gateway
        if let gatewayServer {
            await gatewayServer.stop()
        }

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
            socketPath: configuration.socketPath,
            gatewayEnabled: configuration.gateway.isEnabled,
            gatewayHost: configuration.gateway.isEnabled ? configuration.gateway.host : nil,
            gatewayPort: configuration.gateway.isEnabled ? configuration.gateway.port : nil
        )
    }

    private func responseData(for requestData: Data) async -> Data {
        await responseData(for: requestData, peerPID: nil)
    }

    private func responseData(for requestData: Data, peerPID: pid_t?) async -> Data {
        let rpcStartedAt = ContinuousClock.now
        defer {
            let elapsed = rpcStartedAt.duration(to: ContinuousClock.now)
            let milliseconds = Int(elapsed.components.seconds * 1000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: milliseconds)
        }
        do {
            let decoder = JSONDecoder()
            let incomingRequest = try decoder.decode(IncomingRequestEnvelope.self, from: requestData)
            BurnBarDaemonMetricsCounters.recordRPCRequest()

            if let requiredToken = configuration.socketAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                let providedToken = incomingRequest.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                guard let providedToken, constantTimeTokensEqual(providedToken, requiredToken) else {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_request_unauthorized",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": peerPID.map(String.init) ?? "unknown"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Unauthorized OpenBurnBar RPC request."
                    )
                }
            }

            guard let method = BurnBarRPCMethod(rawValue: incomingRequest.method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
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
                    message: "Unsupported OpenBurnBar RPC method '\(incomingRequest.method)'."
                )
            }

            // Rate limiting check (per peer PID)
            if let rateLimiter {
                let clientKey = peerPID.map(String.init) ?? "unknown"
                let limitResult = await rateLimiter.checkLimit(clientKey: clientKey)
                if case .throttled(let retryAfter) = limitResult {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_rate_limit_exceeded",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": clientKey,
                            "retry_after": "\(retryAfter)"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.rateLimitExceeded,
                        message: "Rate limit exceeded. Retry after \(String(format: "%.1f", retryAfter)) seconds."
                    )
                }
            }

            let request = BurnBarRPCRequestEnvelope(id: incomingRequest.id, method: method, authToken: incomingRequest.authToken)

            switch method {
            case .health, .catalog, .authBootstrap:
                return try await handleLifecycleRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .configGet, .configUpdate,
                 .providerCredentialSlotUpsert, .providerCredentialSlotRemove,
                 .providerModelVariantUpsert, .providerModelVariantRemove,
                 .providerModelAliasUpsert, .providerModelAliasRemove,
                 .providerModelDisplayNameSet, .providerModelDisplayNameClear:
                return try await handleConfigRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .usageRecord, .usageRecent:
                return try await handleUsageRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .proxyRouteLogRecent, .proxyRouteLogClear:
                return try await handleObservabilityRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .connectorPlaneGet, .connectorConfigUpdate, .connectorAction,
                 .browserToolingGet, .browserToolingUpdate, .browserAction:
                return try await handleToolingRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .computerUseSessionStart, .computerUseInvoke,
                 .computerUseApprovalPending, .computerUseApprovalRespond,
                 .computerUsePanicHalt, .computerUseAuditExport:
                return try await handleComputerUseRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .controllerSummary, .controllerProjectsList, .controllerProjectGet,
                 .controllerProjectUpsert, .reviewRunRecord,
                 .questionCreate, .questionGet, .questionsList, .questionAnswer,
                 .followupCreate, .followupsList, .followupDone, .followupSnooze, .followupCalendar,
                 .missionCreate, .missionsList, .missionGet, .missionApprove, .missionCancel,
                 .missionDispatchPacket, .missionRecordResult,
                 .notificationConfigGet, .notificationConfigUpdate, .notificationHealth, .notificationCommand,
                 .simulatorRun, .simulatorList, .simulatorReplay, .projectionRebuild:
                return try await handleMissionControlRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .clientAttach, .clientClaimControl, .clientDetach:
                return try await handleClientRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .runCreate, .runList, .runGet, .runPoll, .runCancel, .runRetry, .runResume,
                 .workspaceExecuteTool, .workspaceToolResult, .approvalRespond:
                return try await handleRunWorkspaceApprovalRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .searchQuery:
                return try await handleSearchRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            }
        } catch {
            BurnBarDaemonMetricsCounters.recordRPCError()
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

    private static func peerPID(for clientFileDescriptor: Int32) -> pid_t? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(clientFileDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        return result == 0 ? pid : nil
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
        BurnBarUnixDomainSocket.configureIOTimeouts(for: clientFileDescriptor)

        let peerPID = Self.peerPID(for: clientFileDescriptor)

        do {
            let requestData = try BurnBarUnixDomainSocket.readRequest(
                from: clientFileDescriptor,
                maxBytes: maxRequestBytes
            )
            let responseData = await server.responseData(
                for: requestData,
                peerPID: peerPID
            ) + Data([0x0A])
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

    static func restrictSocketPermissions(at socketPath: String) throws {
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
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
                guard bytesWritten > 0 else {
                    throw POSIXError(.EIO)
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

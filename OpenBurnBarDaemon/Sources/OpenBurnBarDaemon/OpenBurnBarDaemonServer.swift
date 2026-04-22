import OpenBurnBarCore
import Darwin
import Foundation

public actor BurnBarDaemonServer {
    private static let maxRequestBytes = 64 * 1024

    public let configuration: BurnBarDaemonConfiguration

    private let logger: BurnBarDaemonLogger
    private let configStore: BurnBarConfigStore
    private let usageRecorder: BurnBarUsageRecorder
    private let clientRegistry: BurnBarClientRegistry
    private let runService: BurnBarRunService
    private let missionControlService: any BurnBarMissionControlServing
    private let indexedSearch: BurnBarIndexedSearchService?
    private let gatewayServer: BurnBarHTTPGatewayServer?
    private var listenerFileDescriptor: Int32?
    private var acceptLoopTask: Task<Void, Never>?

    public init(
        configuration: BurnBarDaemonConfiguration = BurnBarDaemonConfiguration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(),
        configStore: BurnBarConfigStore? = nil,
        usageRecorder: BurnBarUsageRecorder? = nil,
        clientRegistry: BurnBarClientRegistry? = nil,
        runService: BurnBarRunService? = nil,
        missionControlService: (any BurnBarMissionControlServing)? = nil
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
        // VAL-DAEMON-011: Wire a concrete execution readiness gate with fail-closed semantics.
        // When gate data is unavailable (no config, no connector plane), the gate returns a failure
        // with an explicit reason code instead of allowing dispatch to proceed (fail-open).
        //
        // Note: The readiness gate is @Sendable and runs on BurnBarMissionControlService actor.
        // We can only call async actor methods from this closure. For sync actor methods like
        // configStore.snapshot(), we rely on the fact that connectorPlaneSnapshot() validates
        // both runtime availability AND provider credentials (since connectors are backed by
        // the same credential system).
        let executionReadinessGate: BurnBarExecutionReadinessGate = { @Sendable mission, packet in
            // Check 1: Verify connector plane runtime is accessible
            // This also implicitly validates that provider credentials are accessible since
            // the connector plane is backed by the same secret store.
            do {
                let connectorPlane = try await resolvedRunService.connectorPlaneSnapshot()
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
        } else {
            self.indexedSearch = nil
        }

        // HTTP gateway (Vibe Proxy style) — only initialized if enabled
        if configuration.gateway.isEnabled {
            self.gatewayServer = BurnBarHTTPGatewayServer(
                configuration: configuration.gateway,
                configStore: resolvedConfigStore,
                logger: BurnBarDaemonLogger(category: "http-gateway")
            )
        } else {
            self.gatewayServer = nil
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

        acceptLoopTask = Task.detached(priority: .background) { [logger] in
            await Self.runAcceptLoop(
                server: self,
                listenerFileDescriptor: fileDescriptor,
                logger: logger
            )
        }
        await missionControlService.startBackgroundLoops()

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
        do {
            let decoder = JSONDecoder()
            let incomingRequest = try decoder.decode(IncomingRequestEnvelope.self, from: requestData)

            if let requiredToken = configuration.socketAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                let providedToken = incomingRequest.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                guard providedToken == requiredToken else {
                    logger.warning(
                        "rpc_request_unauthorized",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method
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

            let request = BurnBarRPCRequestEnvelope(id: incomingRequest.id, method: method, authToken: incomingRequest.authToken)

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
            case .connectorPlaneGet:
                let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarConnectorPlaneResponse(
                        snapshot: try await runService.connectorPlaneSnapshot()
                    )
                )
                return encode(response)
            case .connectorConfigUpdate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarConnectorConfigUpdateRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarConnectorPlaneResponse(
                        snapshot: try await runService.updateConnectorPlane(typedRequest.params)
                    )
                )
                return encode(response)
            case .connectorAction:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarConnectorActionRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.performConnectorAction(typedRequest.params)
                )
                return encode(response)
            case .browserToolingGet:
                let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarBrowserToolingResponse(
                        snapshot: try await runService.browserToolingSnapshot()
                    )
                )
                return encode(response)
            case .browserToolingUpdate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarBrowserToolingUpdateRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarBrowserToolingResponse(
                        snapshot: try await runService.updateBrowserTooling(typedRequest.params)
                    )
                )
                return encode(response)
            case .browserAction:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarBrowserActionRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await runService.performBrowserAction(typedRequest.params)
                )
                return encode(response)
            case .controllerSummary:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerSummaryRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarControllerSummaryResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.controllerSummary(typedRequest.params)
                )
                return encode(response)
            case .controllerProjectsList:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerProjectsListRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarControllerProjectsListResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.controllerProjects(typedRequest.params)
                )
                return encode(response)
            case .controllerProjectGet:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerProjectGetRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarControllerProjectResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.controllerProject(typedRequest.params)
                )
                return encode(response)
            case .controllerProjectUpsert:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerProjectUpsertRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarControllerProjectResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.controllerProjectUpsert(typedRequest.params)
                )
                return encode(response)
            case .reviewRunRecord:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarControllerReviewRunRecordRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarControllerReviewRunRecordResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.reviewRunRecord(typedRequest.params)
                )
                return encode(response)
            case .questionCreate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionCreateRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarQuestionResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.questionCreate(typedRequest.params)
                )
                return encode(response)
            case .questionGet:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionGetRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarQuestionResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.questionGet(typedRequest.params)
                )
                return encode(response)
            case .questionsList:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionsListRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarQuestionsListResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.questionsList(typedRequest.params)
                )
                return encode(response)
            case .questionAnswer:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarQuestionAnswerRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarQuestionAnswerResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.questionAnswer(typedRequest.params)
                )
                return encode(response)
            case .followupCreate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupCreateRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.followupCreate(typedRequest.params)
                )
                return encode(response)
            case .followupsList:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupsListRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarFollowupsListResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.followupsList(typedRequest.params)
                )
                return encode(response)
            case .followupDone:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupDoneRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.followupDone(typedRequest.params)
                )
                return encode(response)
            case .followupSnooze:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupSnoozeRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.followupSnooze(typedRequest.params)
                )
                return encode(response)
            case .followupCalendar:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarFollowupCalendarRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarFollowupMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.followupCalendar(typedRequest.params)
                )
                return encode(response)
            case .missionCreate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionCreateRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.missionCreate(typedRequest.params)
                )
                return encode(response)
            case .missionsList:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionListRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarMissionListResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.missionsList(typedRequest.params)
                )
                return encode(response)
            case .missionGet:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionGetRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarMissionResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.missionGet(typedRequest.params)
                )
                return encode(response)
            case .missionApprove:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionApproveRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.missionApprove(typedRequest.params)
                )
                return encode(response)
            case .missionCancel:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionCancelRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.missionCancel(typedRequest.params)
                )
                return encode(response)
            case .missionDispatchPacket:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionDispatchPacketRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.missionDispatchPacket(typedRequest.params)
                )
                return encode(response)
            case .missionRecordResult:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarMissionRecordResultRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarMissionMutationResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.missionRecordResult(typedRequest.params)
                )
                return encode(response)
            case .notificationConfigGet:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationConfigGetRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarNotificationConfigResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.notificationConfigGet(typedRequest.params)
                )
                return encode(response)
            case .notificationConfigUpdate:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationConfigUpdateRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarNotificationConfigResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.notificationConfigUpdate(typedRequest.params)
                )
                return encode(response)
            case .notificationHealth:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationHealthRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarNotificationHealthResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.notificationHealth(typedRequest.params)
                )
                return encode(response)
            case .notificationCommand:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarNotificationCommandRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarNotificationCommandResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.notificationCommand(typedRequest.params)
                )
                return encode(response)
            case .simulatorRun:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarSimulatorRunRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarSimulatorRunResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.simulatorRun(typedRequest.params)
                )
                return encode(response)
            case .simulatorList:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarSimulatorListRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarSimulatorListResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.simulatorList(typedRequest.params)
                )
                return encode(response)
            case .simulatorReplay:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarSimulatorReplayRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarSimulatorRunResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.simulatorReplay(typedRequest.params)
                )
                return encode(response)
            case .projectionRebuild:
                let typedRequest = try decoder.decode(
                    BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectionRebuildRequest>.self,
                    from: requestData
                )
                let response = BurnBarRPCResponseEnvelope<BurnBarProjectionRebuildResponse>(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: try await missionControlService.projectionRebuild(typedRequest.params)
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
                            "OpenBurnBar indexed search is not available. Ensure OPENBURNBAR_INDEX_DATABASE_PATH points to your OpenBurnBar database and restart the daemon."
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
            case .authBootstrap:
                // Authentication bootstrap is handled via BurnBarDaemonAuthManager
                // Return internal error indicating this endpoint is not handled via socket RPC
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "authBootstrap must be called via direct BurnBarDaemonAuthManager, not via socket RPC"
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
                message: "Failed to encode OpenBurnBar RPC response."
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
        do {
            return try encoder.encode(envelope)
        } catch {
            logger.error(
                "encode_error_response_failed",
                metadata: ["id": id, "code": "\(code)", "message": message, "error": "\(error)"]
            )
            // Return a minimal valid response
            let fallback = ["error": ["code": code, "message": "Internal encoding error"]] as [String: Any]
            do {
                return try JSONSerialization.data(withJSONObject: fallback)
            } catch {
                logger.silentFailure("encode_fallback_error_response", error: error)
                return Data()
            }
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

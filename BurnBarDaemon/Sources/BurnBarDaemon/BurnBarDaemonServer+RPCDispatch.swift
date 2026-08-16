import BurnBarCore
import Foundation

// MARK: - RPC dispatch

extension BurnBarDaemonServer {
    /// Dispatches one decoded request to its method handler. Method families
    /// are delegated to focused helpers so transport/error handling and any
    /// individual service family stay below the lint body-length budget.
    func dispatch(
        method: BurnBarRPCMethod,
        request: BurnBarRPCRequestEnvelope,
        requestData: Data,
        decoder: JSONDecoder
    ) async throws -> Data {
        switch method {
        case .health, .catalog:
            return dispatchHealthOrCatalog(method: method, request: request)
        case .configGet, .configUpdate:
            return try await dispatchConfiguration(
                method: method,
                requestData: requestData,
                decoder: decoder
            )
        case .usageRecent:
            return try await dispatchUsage(requestData: requestData)
        case .clientAttach, .clientDetach, .clientClaimControl:
            return try await dispatchClient(method: method, requestData: requestData)
        case .runCreate, .runList, .runGet, .runPoll, .runCancel, .runRetry:
            return try await dispatchRun(method: method, requestData: requestData)
        case .workspaceExecuteTool, .workspaceToolResult:
            return try await dispatchWorkspace(method: method, requestData: requestData)
        case .approvalRespond:
            return try await dispatchApproval(requestData: requestData)
        case .searchQuery:
            return try dispatchSearch(requestData: requestData, decoder: decoder)
        case .fleetSnapshot, .fleetOrchestratorGet, .fleetOrchestratorSet, .fleetDirectiveRecord:
            return try await dispatchFleet(method: method, requestData: requestData, decoder: decoder)
        }
    }

    private func methodNotFoundResponse(for method: BurnBarRPCMethod) -> Data {
        BurnBarRPCErrorEnvelope.encodeErrorResponse(
            id: BurnBarDaemonServer.noRequestID,
            code: BurnBarRPCErrorCode.methodNotFound,
            message: "Unsupported BurnBar RPC method '\(method.rawValue)'.",
            details: "method=\(method.rawValue)"
        )
    }

    private func encodeResponse<Result: Codable & Sendable>(
        id: String,
        result: Result
    ) -> Data {
        encode(
            BurnBarRPCResponseEnvelope(
                id: id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
        )
    }

    private func dispatchHealthOrCatalog(
        method: BurnBarRPCMethod,
        request: BurnBarRPCRequestEnvelope
    ) -> Data {
        logger.debug(
            "rpc_request_received",
            metadata: [
                "request_id": request.id,
                "method": method.rawValue
            ]
        )

        switch method {
        case .health:
            _ = BurnBarHealthRequest()
            return encode(
                BurnBarRPCResponseEnvelope(
                    id: request.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: healthResponse()
                )
            )
        case .catalog:
            _ = BurnBarCatalogRequest()
            return encodeResponse(
                id: request.id,
                result: BurnBarCatalogResponse(catalog: configuration.catalog)
            )
        default:
            return methodNotFoundResponse(for: method)
        }
    }

    private func dispatchConfiguration(
        method: BurnBarRPCMethod,
        requestData: Data,
        decoder: JSONDecoder
    ) async throws -> Data {
        switch method {
        case .configGet:
            let request = try decodeRequest(BurnBarRPCRequestEnvelope.self, from: requestData, decoder: decoder)
            _ = BurnBarConfigGetRequest()
            return encodeResponse(
                id: request.id,
                result: BurnBarConfigResponse(snapshot: try await configStore.snapshot())
            )
        case .configUpdate:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarConfigUpdateRequest>.self,
                from: requestData
            )
            let snapshot = try await configStore.replaceSnapshot(request.params.snapshot)
            return encodeResponse(
                id: request.id,
                result: BurnBarConfigResponse(snapshot: snapshot)
            )
        default:
            return methodNotFoundResponse(for: method)
        }
    }

    private func dispatchUsage(requestData: Data) async throws -> Data {
        let request = try decodeRequest(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarRecentUsageRequest>.self,
            from: requestData
        )
        let usage = try await usageRecorder.recentUsage(limit: request.params.limit)
        return encodeResponse(
            id: request.id,
            result: BurnBarRecentUsageResponse(usage: usage)
        )
    }

    private func dispatchClient(
        method: BurnBarRPCMethod,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .clientAttach:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarClientAttachRequest>.self,
                from: requestData
            )
            let (attachResponse, arbitration) = await clientRegistry.attach(request.params)
            logger.notice(
                "client_arbitration_updated",
                metadata: [
                    "active_client_id": arbitration.activeClientID?.rawValue ?? "none",
                    "reason": arbitration.reason ?? "none"
                ]
            )
            return encodeResponse(
                id: request.id,
                result: attachResponse
            )
        case .clientDetach:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarClientDetachRequest>.self,
                from: requestData
            )
            let arbitration = try await clientRegistry.detach(request.params)
            return encodeResponse(
                id: request.id,
                result: arbitration
            )
        case .clientClaimControl:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarClientClaimControlRequest>.self,
                from: requestData
            )
            let arbitration = try await clientRegistry.claimControl(request.params)
            return encodeResponse(
                id: request.id,
                result: arbitration
            )
        default:
            return methodNotFoundResponse(for: method)
        }
    }

    private func dispatchRun(
        method: BurnBarRPCMethod,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .runCreate:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRunCreateRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.createRun(request.params)
            )
        case .runList:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRunListRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.listRuns(request.params)
            )
        case .runGet:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRunGetRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.getRun(request.params)
            )
        case .runPoll:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRunPollRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.pollRuns(request.params)
            )
        case .runCancel:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRunCancelRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.cancelRun(request.params)
            )
        case .runRetry:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRunRetryRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.retryRun(request.params)
            )
        default:
            return methodNotFoundResponse(for: method)
        }
    }

    private func dispatchWorkspace(
        method: BurnBarRPCMethod,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .workspaceExecuteTool:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarToolExecutionRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.executeTool(request.params)
            )
        case .workspaceToolResult:
            let request = try decodeRequest(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarToolResultSubmissionRequest>.self,
                from: requestData
            )
            return encodeResponse(
                id: request.id,
                result: try await runService.submitToolResult(request.params)
            )
        default:
            return methodNotFoundResponse(for: method)
        }
    }

    private func dispatchApproval(requestData: Data) async throws -> Data {
        let request = try decodeRequest(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarApprovalRespondRequest>.self,
            from: requestData
        )
        return encodeResponse(
            id: request.id,
            result: try await runService.respondToApproval(request.params)
        )
    }

    private func dispatchSearch(
        requestData: Data,
        decoder: JSONDecoder
    ) throws -> Data {
        let request = try decodeRequest(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarSearchQueryRequest>.self,
            from: requestData,
            decoder: decoder
        )
        guard let indexedSearch else {
            return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                id: request.id,
                code: BurnBarRPCErrorCode.internalError,
                message:
                    "BurnBar indexed search is not available. Ensure BURNBAR_INDEX_DATABASE_PATH points to your BurnBar database and restart the daemon.",
                details: "index_database_path=\(configuration.indexDatabasePath ?? "unset")"
            )
        }
        do {
            let result = try indexedSearch.search(query: request.params)
            return encodeResponse(
                id: request.id,
                result: result
            )
        } catch {
            return BurnBarRPCErrorEnvelope.encodeErrorResponse(
                id: request.id,
                code: BurnBarRPCErrorCode.internalError,
                message: error.localizedDescription,
                details: "error=\(error)"
            )
        }
    }

    private func dispatchFleet(
        method: BurnBarRPCMethod,
        requestData: Data,
        decoder: JSONDecoder
    ) async throws -> Data {
        switch method {
        case .fleetSnapshot:
            return try await handleFleetSnapshot(requestData: requestData, decoder: decoder)
        case .fleetOrchestratorGet:
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
        default:
            return methodNotFoundResponse(for: method)
        }
    }
}

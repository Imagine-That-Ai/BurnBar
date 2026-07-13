import OpenBurnBarEngine
import Foundation

extension BurnBarDaemonServer {
    func handleRunWorkspaceApprovalRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
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
        case .runResume:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRunResumeRequest>.self,
                from: requestData
            )
            guard let resumeService else {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message:
                        "OpenBurnBar resume is not available. Ensure OPENBURNBAR_INDEX_DATABASE_PATH points to your OpenBurnBar database and restart the daemon."
                )
            }
            do {
                let result = try resumeService.runResume(typedRequest.params)
                return encode(BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                ))
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }
        case .subscriptionStart:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSubscriptionStartRequest>.self,
                from: requestData
            )
            return try await encodeSubscriptionResponse(id: typedRequest.id) {
                try await subscriptionService.start(typedRequest.params)
            }
        case .subscriptionResume:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSubscriptionResumeRequest>.self,
                from: requestData
            )
            return try await encodeSubscriptionResponse(id: typedRequest.id) {
                try await subscriptionService.resume(typedRequest.params)
            }
        case .subscriptionStop:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSubscriptionStopRequest>.self,
                from: requestData
            )
            return try await encodeSubscriptionResponse(id: typedRequest.id) {
                try await subscriptionService.stop(typedRequest.params)
            }
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
        default:
            preconditionFailure("Unhandled run/workspace/approval RPC method: \(method.rawValue)")
        }
    }

    private func encodeSubscriptionResponse<Result: Codable & Sendable>(
        id: String,
        operation: () async throws -> Result
    ) async throws -> Data {
        do {
            return encode(BurnBarRPCResponseEnvelope(
                id: id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await operation()
            ))
        } catch let error as BurnBarSubscriptionServiceError {
            return encodeErrorResponse(
                id: id,
                code: BurnBarRPCErrorCode.invalidParams,
                message: error.localizedDescription
            )
        }
    }

}

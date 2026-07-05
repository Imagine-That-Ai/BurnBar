import OpenBurnBarCore
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
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: subscriptionStartResponse(for: typedRequest.params)
            )
            return encode(response)
        case .subscriptionResume:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSubscriptionResumeRequest>.self,
                from: requestData
            )
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: subscriptionResumeResponse(for: typedRequest.params)
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
        default:
            preconditionFailure("Unhandled run/workspace/approval RPC method: \(method.rawValue)")
        }
    }

    private func subscriptionStartResponse(
        for request: BurnBarSubscriptionStartRequest
    ) -> BurnBarSubscriptionResponse {
        let topic = normalizedSubscriptionTopic(request.topic)
        let subscriptionID = request.requestedSubscriptionID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "sub-\(topic)-\(UUID().uuidString)"
        let event = subscriptionEvent(
            seq: 1,
            kind: "\(topic).snapshot",
            topic: topic,
            runID: request.runID,
            extra: [
                "client_id": request.clientID ?? "unknown",
                "phase": "first_snapshot"
            ]
        )
        return BurnBarSubscriptionResponse(
            subscriptionID: subscriptionID,
            topic: topic,
            seq: event.seq,
            cursor: String(event.seq),
            firstSnapshot: true,
            events: [event],
            degradedFallback: true,
            degradationReason: "long_poll_fallback_over_burnbarrpc_envelope",
            backpressure: "coalesce_latest_per_topic",
            disconnectDetected: false,
            recoveredAfterRestart: false,
            terminalStateDelivered: true
        )
    }

    private func subscriptionResumeResponse(
        for request: BurnBarSubscriptionResumeRequest
    ) -> BurnBarSubscriptionResponse {
        let topic = normalizedSubscriptionTopic(request.topic)
        let seq = max(request.afterSeq + 1, 1)
        let event = subscriptionEvent(
            seq: seq,
            kind: "\(topic).resume_snapshot",
            topic: topic,
            runID: request.runID,
            extra: [
                "client_id": request.clientID ?? "unknown",
                "resumed_after_seq": String(request.afterSeq),
                "terminal_state_delivery": "verified"
            ]
        )
        return BurnBarSubscriptionResponse(
            subscriptionID: request.subscriptionID,
            topic: topic,
            seq: event.seq,
            cursor: String(event.seq),
            firstSnapshot: request.afterSeq <= 0,
            events: [event],
            degradedFallback: true,
            degradationReason: "long_poll_fallback_over_burnbarrpc_envelope",
            backpressure: "coalesce_latest_per_topic",
            disconnectDetected: request.afterSeq > 0,
            recoveredAfterRestart: request.afterSeq > 0,
            terminalStateDelivered: true
        )
    }

    private func normalizedSubscriptionTopic(_ topic: String) -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "run":
            return "run"
        default:
            return "health"
        }
    }

    private func subscriptionEvent(
        seq: Int,
        kind: String,
        topic: String,
        runID: String?,
        extra: [String: String]
    ) -> BurnBarSubscriptionEvent {
        var snapshot = extra
        snapshot["topic"] = topic
        snapshot["run_id"] = runID ?? ""
        snapshot["daemon_version"] = configuration.daemonVersion
        snapshot["transport"] = "af_unix_burnbarrpc"
        snapshot["cursor_semantics"] = "monotonic_seq"
        snapshot["backpressure"] = "coalesce_latest_per_topic"
        return BurnBarSubscriptionEvent(
            seq: seq,
            kind: kind,
            snapshot: snapshot,
            terminal: true
        )
    }
}

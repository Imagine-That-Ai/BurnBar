import Foundation
import OpenBurnBarKernel

extension BurnBarDaemonServer {
    func handleWarFlameRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .warFlameRoute:
            return try await handleWarFlameRoute(requestData: requestData, decoder: decoder)
        case .warFlameDistillList:
            return try await handleWarFlameDistillList(requestData: requestData, decoder: decoder)
        case .warFlameDistillSettle:
            return try await handleWarFlameDistillSettle(requestData: requestData, decoder: decoder)
        default:
            preconditionFailure("Unhandled War Room flame RPC method: \(method.rawValue)")
        }
    }

    func handleWarFlameRoute(requestData: Data, decoder: JSONDecoder) async throws -> Data {
        let typedRequest = try decoder.decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarWarFlameRouteParams>.self,
            from: requestData
        )
        let routed = await flameService.route(
            requiredCapabilities: Set(typedRequest.params.requiredCapabilities),
            instruction: typedRequest.params.instruction
        )
        return encode(
            BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarWarFlameRouteResponse(decision: routed.decision, record: routed.record)
            )
        )
    }

    func handleWarFlameDistillList(requestData: Data, decoder: JSONDecoder) async throws -> Data {
        let typedRequest = try decoder.decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarWarFlameDistillListParams>.self,
            from: requestData
        )
        // Clamp deliberately rather than relying on the log's capacity to
        // happen to bound the response.
        let requested = typedRequest.params.limit ?? 50
        let records = await flameService.recentRecords(
            limit: min(requested, DistillLog.defaultCapacity)
        )
        let rate = await flameService.successRate()
        return encode(
            BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarWarFlameDistillListResponse(records: records, successRate: rate)
            )
        )
    }

    func handleWarFlameDistillSettle(requestData: Data, decoder: JSONDecoder) async throws -> Data {
        let typedRequest = try decoder.decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarWarFlameDistillSettleParams>.self,
            from: requestData
        )
        let record = await flameService.settle(
            decisionID: typedRequest.params.decisionID,
            outcome: typedRequest.params.outcome,
            runID: typedRequest.params.runID
        )
        return encode(
            BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarWarFlameDistillSettleResponse(settled: record != nil, record: record)
            )
        )
    }
}

import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleUsageRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
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
        case .usageRecord:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarRecordUsageRequest>.self,
                from: requestData
            )
            let recordResult = try await usageRecorder.record(
                typedRequest.params.event,
                idempotencyKey: typedRequest.params.idempotencyKey
            )
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarRecordUsageResponse(
                    idempotencyKey: recordResult.record.idempotencyKey,
                    inserted: recordResult.inserted,
                    event: recordResult.record.event
                )
            )
            return encode(response)
        default:
            preconditionFailure("Unhandled usage RPC method: \(method.rawValue)")
        }
    }
}

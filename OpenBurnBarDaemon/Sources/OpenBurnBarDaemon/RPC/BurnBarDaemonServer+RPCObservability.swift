import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleObservabilityRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .proxyRouteLogRecent:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProxyRouteLogRecentRequest>.self,
                from: requestData
            )
            let entries = try await proxyRouteLogStore.recent(limit: typedRequest.params.limit)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProxyRouteLogRecentResponse(entries: entries)
            )
            return encode(response)
        case .proxyRouteLogClear:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProxyRouteLogClearRequest>.self,
                from: requestData
            )
            try await proxyRouteLogStore.clear()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProxyRouteLogClearResponse(cleared: true)
            )
            return encode(response)
        default:
            preconditionFailure("Unhandled observability RPC method: \(method.rawValue)")
        }
    }
}

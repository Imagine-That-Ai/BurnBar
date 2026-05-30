import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleToolingRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .connectorPlaneGet:
            let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarConnectorPlaneResponse(
                    snapshot: try await toolingProxy.connectorPlaneSnapshot()
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
                    snapshot: try await toolingProxy.updateConnectorPlane(typedRequest.params)
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
                result: try await toolingProxy.performConnectorAction(typedRequest.params)
            )
            return encode(response)
        case .browserToolingGet:
            let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarBrowserToolingResponse(
                    snapshot: try await toolingProxy.browserToolingSnapshot()
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
                    snapshot: try await toolingProxy.updateBrowserTooling(typedRequest.params)
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
                result: try await toolingProxy.performBrowserAction(typedRequest.params)
            )
            return encode(response)
        default:
            preconditionFailure("Unhandled tooling RPC method: \(method.rawValue)")
        }
    }
}

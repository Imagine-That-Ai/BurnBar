import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleClientRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
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
        default:
            preconditionFailure("Unhandled client RPC method: \(method.rawValue)")
        }
    }
}

import OpenBurnBarEngine
import Foundation

extension BurnBarDaemonServer {
    func handleMembershipRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .membershipStatus:
            let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            let result = await membershipService.status()
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            ))
        case .membershipCheckoutURL:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMembershipCheckoutURLRequest>.self,
                from: requestData
            )
            do {
                let result = try await membershipService.checkoutURL(typedRequest.params)
                return encode(BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                ))
            } catch let error as BurnBarMembershipServiceError {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: error.membershipCode == .unauthenticated ? BurnBarRPCErrorCode.unauthorized : BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }
        case .membershipPortalURL:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMembershipPortalURLRequest>.self,
                from: requestData
            )
            do {
                let result = try await membershipService.portalURL(typedRequest.params)
                return encode(BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                ))
            } catch let error as BurnBarMembershipServiceError {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: error.membershipCode == .unauthenticated ? BurnBarRPCErrorCode.unauthorized : BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }
        case .membershipRestore:
            let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            let result = await membershipService.restore()
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            ))
        default:
            preconditionFailure("Unhandled membership RPC method: \(method.rawValue)")
        }
    }
}

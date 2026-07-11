import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleAccountRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .accountStatus:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            return encode(BurnBarRPCResponseEnvelope(
                id: request.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: await accountService.status()
            ))
        case .linuxAppCheckStatus:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            return encode(BurnBarRPCResponseEnvelope(
                id: request.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: await linuxAppCheckService.redactedStatusResponse()
            ))
        case .accountDeviceAuthStart:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            return await accountResponse(id: request.id, invalidatesAppCheck: true) {
                try await accountService.startDeviceAuthorization()
            }
        case .accountDeviceAuthPoll:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarAccountFlowRequest>.self,
                from: requestData
            )
            return await accountResponse(id: request.id, invalidatesAppCheck: true) {
                try await accountService.pollDeviceAuthorization(flowID: request.params.flowID)
            }
        case .accountDeviceAuthCancel:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarAccountFlowRequest>.self,
                from: requestData
            )
            return await accountResponse(id: request.id, invalidatesAppCheck: true) {
                try await accountService.cancelDeviceAuthorization(flowID: request.params.flowID)
            }
        case .accountSignOut:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            return await accountResponse(id: request.id, invalidatesAppCheck: true) {
                try await accountService.signOut()
            }
        default:
            preconditionFailure("Unhandled account RPC method: \(method.rawValue)")
        }
    }

    private func accountResponse(
        id: String,
        invalidatesAppCheck: Bool = false,
        operation: () async throws -> BurnBarAccountStatusResponse
    ) async -> Data {
        if invalidatesAppCheck {
            await linuxAppCheckService.invalidate()
        }
        do {
            return encode(BurnBarRPCResponseEnvelope(
                id: id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: try await operation()
            ))
        } catch let error as BurnBarAccountAuthError {
            let code: Int
            switch error {
            case .invalidFlow, .invalidResponse:
                code = BurnBarRPCErrorCode.invalidParams
            case .reauthenticationRequired:
                code = BurnBarRPCErrorCode.unauthorized
            case .secretStoreUnavailable, .networkUnavailable:
                code = BurnBarRPCErrorCode.internalError
            }
            return encodeErrorResponse(
                id: id,
                code: code,
                message: error.localizedDescription
            )
        } catch {
            return encodeErrorResponse(
                id: id,
                code: BurnBarRPCErrorCode.internalError,
                message: "The account operation failed."
            )
        }
    }
}

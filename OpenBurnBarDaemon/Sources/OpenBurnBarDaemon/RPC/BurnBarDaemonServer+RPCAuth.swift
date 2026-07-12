import Foundation
import OpenBurnBarCore

extension BurnBarDaemonServer {
    func handleLinuxAuthRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        #if os(Linux)
        switch method {
        case .linuxAuthStatus:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            return encode(BurnBarRPCResponseEnvelope(
                id: request.id,
                result: await linuxCloudAuthStatus()
            ))
        case .linuxAuthBegin:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            do {
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: try await beginLinuxCloudSignIn()
                ))
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: "Linux browser sign-in is unavailable."
                )
            }
        case .linuxAuthCancel:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxAuthCancelRequest>.self,
                from: requestData
            )
            do {
                let status = try await cancelLinuxCloudSignIn(operationID: request.params.operationID)
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: BurnBarLinuxAuthMutationResponse(ok: true, status: status)
                ))
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.invalidRequest,
                    message: "The Linux sign-in operation could not be cancelled."
                )
            }
        case .linuxAuthRotateIdentity:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            do {
                let status = try await rotateLinuxCloudInstallationIdentity()
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: BurnBarLinuxAuthMutationResponse(ok: true, status: status)
                ))
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.invalidRequest,
                    message: "The Linux installation identity could not be rotated."
                )
            }
        case .linuxAuthSignOut:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            do {
                let status = try await signOutLinuxCloud()
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: BurnBarLinuxAuthMutationResponse(ok: true, status: status)
                ))
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: "Linux sign-out did not complete."
                )
            }
        default:
            preconditionFailure("Unhandled Linux auth RPC method: \(method.rawValue)")
        }
        #else
        let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
        return encodeErrorResponse(
            id: request.id,
            code: BurnBarRPCErrorCode.methodNotFound,
            message: "Linux authentication is unavailable on this platform."
        )
        #endif
    }
}

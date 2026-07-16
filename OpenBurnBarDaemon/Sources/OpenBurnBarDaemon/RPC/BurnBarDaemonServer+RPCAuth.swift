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
        case .linuxAccountCloudDataDelete:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxAccountCloudDataDeletionRequest>.self,
                from: requestData
            )
            guard request.params.confirmation == LinuxCloudDataDeletionRequest.confirmationToken else {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.invalidParams,
                    message: "Account erasure confirmation is invalid."
                )
            }
            do {
                let result = try await deleteLinuxAccountCloudData(
                    confirmation: request.params.confirmation
                )
                return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))
            } catch let error as LinuxCloudAuthAuthorityError {
                let mapped = accountCloudDataDeletionRPCError(error)
                return encodeErrorResponse(id: request.id, code: mapped.code, message: mapped.message)
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Account erasure did not complete; retry."
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

#if os(Linux)
private func accountCloudDataDeletionRPCError(
    _ error: LinuxCloudAuthAuthorityError
) -> (code: Int, message: String) {
    switch error {
    case .operationMismatch:
        return (BurnBarRPCErrorCode.invalidParams, "Account erasure confirmation is invalid.")
    case .dataControlInProgress:
        return (BurnBarRPCErrorCode.conflict, "An account erasure request is already in progress.")
    case .trustedDeviceBridgeUnavailable:
        return (BurnBarRPCErrorCode.unavailable, "Account erasure needs a connected trusted-device approval bridge.")
    case .configurationRequired:
        return (BurnBarRPCErrorCode.unavailable, "Account erasure is unavailable until Linux cloud authentication is configured.")
    case .notSignedIn, .reauthorizationRequired:
        return (BurnBarRPCErrorCode.unauthorized, "Sign in again before deleting cloud data.")
    case .secureStoreUnavailable:
        return (BurnBarRPCErrorCode.unavailable, "Unlock Linux secure credential storage, then retry account erasure.")
    case .deviceApprovalRequired, .deviceRejected, .trustedDeviceAuthorizationRejected,
         .dataControlAuthorizationInvalid:
        return (BurnBarRPCErrorCode.unauthorized, "Trusted-device authorization was not approved; retry from an approved device.")
    case .cloudUnavailable, .cloudResponseInvalid, .sessionChanged,
         .authorizationInProgress, .authorizationFailed, .appCheckConfigurationRejected,
         .installationIdentityUnavailable:
        return (BurnBarRPCErrorCode.unavailable, "Account erasure did not complete; retry.")
    }
}
#endif
}

import Foundation
import OpenBurnBarEngine

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
        case .linuxAccountCloudDataExport:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxAccountCloudDataExportRequest>.self,
                from: requestData
            )
            do {
                let result = try await exportLinuxAccountCloudData(
                    domains: request.params.domains,
                    destinationPath: request.params.destinationPath
                )
                return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))
            } catch let error as LinuxCloudAuthAuthorityError {
                let mapped = accountCloudDataExportRPCError(error)
                return encodeErrorResponse(id: request.id, code: mapped.code, message: mapped.message)
            } catch let error as BurnBarLinuxPrivacyService.ServiceError {
                let (code, message): (Int, String) = switch error {
                case .unsafeLocation, .unsafeFile:
                    (BurnBarRPCErrorCode.invalidParams, "Account export destination is unsafe.")
                case .exportTooLarge:
                    (BurnBarRPCErrorCode.invalidParams, "Account export exceeded the daemon size limit.")
                default:
                    (BurnBarRPCErrorCode.unavailable, "Account export could not be written; retry.")
                }
                return encodeErrorResponse(id: request.id, code: code, message: message)
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Account export did not complete; retry."
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
        case .linuxTrustedDeviceList:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            guard let manager = linuxTrustedDeviceManager else {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Trusted-device management is not configured on this Linux installation."
                )
            }
            do {
                let devices = try await manager.listTrustedDevices()
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: BurnBarLinuxTrustedDeviceListResponse(devices: devices)
                ))
            } catch let error as LinuxTrustedDeviceManagementError {
                return encodeTrustedDeviceManagementError(id: request.id, error: error)
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Trusted-device state is unavailable; retry."
                )
            }
        case .linuxTrustedDeviceApprove, .linuxTrustedDeviceRevoke:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxTrustedDeviceMutationRequest>.self,
                from: requestData
            )
            guard let manager = linuxTrustedDeviceManager else {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Trusted-device management is not configured on this Linux installation."
                )
            }
            do {
                let mutation: LinuxTrustedDeviceMutation
                if method == .linuxTrustedDeviceApprove {
                    mutation = try await manager.approveTrustedDevice(deviceID: request.params.deviceID)
                } else {
                    mutation = try await manager.revokeTrustedDevice(deviceID: request.params.deviceID)
                }
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: BurnBarLinuxTrustedDeviceMutationResponse(
                        deviceID: mutation.deviceID,
                        trustState: mutation.trustState,
                        alreadyInState: mutation.alreadyInState
                    )
                ))
            } catch let error as LinuxTrustedDeviceManagementError {
                return encodeTrustedDeviceManagementError(id: request.id, error: error)
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Trusted-device mutation did not complete; retry."
                )
            }
        case .linuxCloudSyncStatus:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            guard let linuxCloudSyncRuntime else {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Linux cloud sync transport is not configured."
                )
            }
            do {
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: try await linuxCloudSyncRuntime.status()
                ))
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Linux cloud sync status is unavailable."
                )
            }
        case .linuxCloudSyncPolicyUpdate:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxCloudSyncPolicyUpdateRequest>.self,
                from: requestData
            )
            guard let linuxCloudSyncRuntime else {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Linux cloud sync transport is not configured."
                )
            }
            do {
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: try await linuxCloudSyncRuntime.updatePolicy(request.params)
                ))
            } catch let error as LinuxCloudReplicaEngine.EngineError where error == .invalidIdentifier {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.invalidParams,
                    message: "Linux cloud sync policy contains an invalid domain."
                )
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Linux cloud sync policy could not be updated."
                )
            }
        case .linuxCloudSyncRun:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxCloudSyncRunRequest>.self,
                from: requestData
            )
            guard let linuxCloudSyncRuntime else {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Linux cloud sync transport is not configured."
                )
            }
            do {
                return encode(BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: try await linuxCloudSyncRuntime.run(force: request.params.force)
                ))
            } catch LinuxCloudReplicaEngine.EngineError.retryNotDue {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.conflict,
                    message: "Linux cloud sync is backing off; retry later."
                )
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Linux cloud sync did not complete."
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

private func accountCloudDataExportRPCError(
    _ error: LinuxCloudAuthAuthorityError
) -> (code: Int, message: String) {
    switch error {
    case .dataControlInProgress:
        return (BurnBarRPCErrorCode.conflict, "An account export request is already in progress.")
    case .trustedDeviceBridgeUnavailable:
        return (BurnBarRPCErrorCode.unavailable, "Account export needs a connected trusted-device approval bridge.")
    case .configurationRequired:
        return (BurnBarRPCErrorCode.unavailable, "Account export is unavailable until Linux cloud authentication is configured.")
    case .notSignedIn, .reauthorizationRequired:
        return (BurnBarRPCErrorCode.unauthorized, "Sign in again before exporting cloud data.")
    case .secureStoreUnavailable:
        return (BurnBarRPCErrorCode.unavailable, "Unlock Linux secure credential storage, then retry account export.")
    case .deviceApprovalRequired, .deviceRejected, .trustedDeviceAuthorizationRejected,
         .dataControlAuthorizationInvalid:
        return (BurnBarRPCErrorCode.unauthorized, "Trusted-device authorization was not approved; retry from an approved device.")
    case .operationMismatch, .authorizationInProgress, .authorizationFailed,
         .appCheckConfigurationRejected, .cloudUnavailable, .cloudResponseInvalid,
         .sessionChanged, .installationIdentityUnavailable:
        return (BurnBarRPCErrorCode.unavailable, "Account export did not complete; retry.")
    }
}

private func encodeTrustedDeviceManagementError(
    id: String,
    error: LinuxTrustedDeviceManagementError
) -> Data {
    let (code, message): (Int, String) = switch error {
    case .invalidDeviceID, .malformedResponse:
        (BurnBarRPCErrorCode.invalidParams, "Trusted-device request was invalid.")
    case .notAuthenticated:
        (BurnBarRPCErrorCode.unauthorized, "Sign in before managing trusted devices.")
    case .unauthorized, .rejected:
        (BurnBarRPCErrorCode.unauthorized, "Trusted-device authorization was not approved.")
    case .unavailable, .transportFailure:
        (BurnBarRPCErrorCode.unavailable, "Trusted-device management is unavailable; retry.")
    }
    return encodeErrorResponse(id: id, code: code, message: message)
}
#endif
}

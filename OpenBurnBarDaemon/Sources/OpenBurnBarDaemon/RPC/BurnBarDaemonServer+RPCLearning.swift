import Foundation
import OpenBurnBarEngine

extension BurnBarDaemonServer {
    func handleLearningRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        let request = try resolveSafariBridgeRPCRequest(
            method: method,
            decoder: decoder,
            requestData: requestData
        )

        do {
            switch method {
            case .learningPropose:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningProposalRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.propose(params)
                )

            case .learningRecall:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningRecallRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: BurnBarSafariLearningRecallResponse(
                        untrustedContext: try await learningCoordinator.recallForPrompt(
                            query: params.query,
                            limit: params.limit
                        )
                    )
                )

            case .learningList:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningListRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.list(params)
                )

            case .learningOptIn:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningOptInRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.optIn(params)
                )

            case .learningUpdate:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningUpdateRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.update(params)
                )

            case .learningApprove:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningMutationRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.approve(params)
                )

            case .learningReject:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningMutationRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.reject(params)
                )

            case .learningForget:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningForgetRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.forget(params)
                )

            case .learningRollback:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningRollbackRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.rollback(params)
                )

            case .learningTimeline:
                let params = try decoder.decode(
                    BurnBarJSONValue.self,
                    from: request.paramsData
                )
                guard case .object(let object) = params, object.isEmpty else {
                    throw BurnBarSafariRPCHandlerError.invalidParams(
                        "Safari learning timeline params must be an empty object."
                    )
                }
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.timeline()
                )

            case .learningOptOut:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariLearningOptOutRequest.self,
                    request: request,
                    decoder: decoder
                )
                return learningRPCSuccess(
                    id: request.id,
                    result: try await learningCoordinator.optOut(params)
                )

            default:
                preconditionFailure("Unhandled learning RPC method: \(method.rawValue)")
            }
        } catch {
            return learningRPCErrorResponse(id: request.id, error: error)
        }
    }

    private func learningRPCSuccess<Result: Codable & Sendable>(
        id: String,
        result: Result
    ) -> Data {
        encode(
            BurnBarRPCResponseEnvelope(
                id: id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
        )
    }

    private func learningRPCErrorResponse(id: String, error: Error) -> Data {
        let code: Int
        switch error {
        case is DecodingError,
             BurnBarSafariRPCHandlerError.invalidParams:
            code = BurnBarRPCErrorCode.invalidParams

        case BurnBarSafariRPCHandlerError.unauthorized:
            code = BurnBarRPCErrorCode.unauthorized

        case BurnBarSafariRPCHandlerError.conflict:
            code = BurnBarRPCErrorCode.conflict

        case BurnBarSafariRPCHandlerError.unavailable:
            code = BurnBarRPCErrorCode.unavailable

        case let learning as SafariLearningCoordinatorError:
            switch learning {
            case .ineligibleTier, .optInRequired, .sourceDenied:
                code = BurnBarRPCErrorCode.unauthorized

            case .duplicateObservation, .versionConflict, .invalidTransition,
                 .storeCapacityExceeded:
                code = BurnBarRPCErrorCode.conflict

            case .invalidConsentVersion, .invalidObservation,
                 .triggerThresholdNotMet, .malformedReviewerOutput,
                 .reviewerRejected, .sensitiveContentRejected,
                 .proposalNotFound, .skillQuarantined, .skillNotFound:
                code = BurnBarRPCErrorCode.invalidParams

            case .reviewerUnavailable, .memoryIntegrationUnavailable,
                 .memoryRecallUnavailable:
                code = BurnBarRPCErrorCode.unavailable

            case .unsafePath, .insecurePermissions, .malformedStore,
                 .storeTooLarge:
                code = BurnBarRPCErrorCode.internalError
            }

        default:
            code = BurnBarRPCErrorCode.internalError
        }

        logger.warning(
            "learning_rpc_rejected",
            metadata: [
                "request_id": id,
                "error": String(describing: error)
            ]
        )
        return encodeErrorResponse(
            id: id,
            code: code,
            message: error.localizedDescription
        )
    }
}

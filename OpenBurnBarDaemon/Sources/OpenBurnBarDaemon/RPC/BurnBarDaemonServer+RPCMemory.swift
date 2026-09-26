import Foundation
import OpenBurnBarEngine

extension BurnBarDaemonServer {
    func handleMemoryRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        if method == .memoryModelPolicy {
            // Independent of the project-memory store: the policy is daemon state.
            return await handleMemoryModelPolicy(decoder: decoder, requestData: requestData)
        }
        guard let projectCodeMemory else {
            return encodeErrorResponse(
                id: "memory-unavailable",
                code: BurnBarRPCErrorCode.internalError,
                message: "Project memory is not available. Configure OPENBURNBAR_INDEX_DATABASE_PATH and restart the daemon."
            )
        }

        switch method {
        case .memoryRemember:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemoryRememberRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.remember(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memoryRecall:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemoryRecallRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.recall(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memoryReviewStatus:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemoryReviewStatusRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.setReviewStatus(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memoryForget:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemoryForgetRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.forget(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memoryAuditTrail:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemoryAuditTrailRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.auditTrail(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memorySyncInboxList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMemorySyncInboxListRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.syncInboxList(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memorySyncInboxAck:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMemorySyncInboxAckRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.syncInboxAck(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memoryAnalytics:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemoryAnalyticsRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.memoryAnalytics(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .memorySnapshotUpsert:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemorySnapshotUpsertRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.snapshotUpsertAppLane(typedRequest.params)))
            } catch {
                return snapshotErrorResponse(id: typedRequest.id, error: error)
            }
        case .memorySnapshotDelete:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemorySnapshotDeleteRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.snapshotDeleteAppLane(typedRequest.params)))
            } catch {
                return snapshotErrorResponse(id: typedRequest.id, error: error)
            }
        case .memorySnapshotDeleteAll:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectMemorySnapshotDeleteAllRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.snapshotDeleteAllAppLane()))
            } catch {
                return snapshotErrorResponse(id: typedRequest.id, error: error)
            }
        case .memoryAuthorityApply:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarMemoryAuthorityApplyRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.memoryAuthorityApplyAppLane(typedRequest.params)))
            } catch {
                return memoryAuthorityErrorResponse(id: typedRequest.id, error: error)
            }
        default:
            preconditionFailure("Unhandled memory RPC method: \(method.rawValue)")
        }
    }

    /// Error mapping for the snapshot app lane only: validation failures are
    /// the caller's fault (`invalidParams`, matching the chat cutover lane),
    /// never an `internalError`. The older memory cases keep their existing
    /// mapping untouched.
    private func snapshotErrorResponse(id: String, error: Error) -> Data {
        if case BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest = error {
            return encodeErrorResponse(id: id, code: BurnBarRPCErrorCode.invalidParams, message: error.localizedDescription)
        }
        return encodeErrorResponse(id: id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
    }

    /// Error mapping for the memory authority app lane: validation failures
    /// are the caller's fault (`invalidParams`); a failed reseal
    /// precondition is a retryable `conflict` the app answers with a fresh
    /// read, never a crash and never a partial apply.
    private func memoryAuthorityErrorResponse(id: String, error: Error) -> Data {
        if case BurnBarProjectCodeMemoryStoreError.memoryAuthorityInvalidRequest = error {
            return encodeErrorResponse(id: id, code: BurnBarRPCErrorCode.invalidParams, message: error.localizedDescription)
        }
        if case BurnBarProjectCodeMemoryStoreError.memoryAuthorityConflict = error {
            return encodeErrorResponse(id: id, code: BurnBarRPCErrorCode.conflict, message: error.localizedDescription)
        }
        return encodeErrorResponse(id: id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
    }
}

extension BurnBarDaemonServer {
    func handleMemoryModelPolicy(decoder: JSONDecoder, requestData: Data) async -> Data {
        let requestID: String
        do {
            requestID = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData).id
        } catch {
            return encodeErrorResponse(id: "memory-model-policy", code: BurnBarRPCErrorCode.invalidRequest, message: error.localizedDescription)
        }
        let snapshot: BurnBarProviderConfigurationSnapshot
        do {
            snapshot = try await configStore.snapshot()
        } catch {
            return encodeErrorResponse(id: requestID, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
        }
        let membership = await membershipService.status().membership
        let gatewayURL: String? = configuration.gateway.isEnabled
            ? "http://\(configuration.gateway.host):\(configuration.gateway.port)"
            : nil
        let response = await BurnBarMemoryModelPolicy.assemble(
            snapshot: snapshot,
            membership: membership,
            catalogSupport: configStore.catalogSupport,
            tokenStore: memoryGatewayTokenStore,
            gatewayURL: gatewayURL,
            now: Date()
        )
        return encode(BurnBarRPCResponseEnvelope(
            id: requestID,
            protocolVersion: BurnBarProtocolVersion.current,
            result: response
        ))
    }
}

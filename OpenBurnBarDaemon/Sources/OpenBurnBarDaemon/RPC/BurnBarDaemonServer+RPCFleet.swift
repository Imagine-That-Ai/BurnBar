import OpenBurnBarKernel
import Foundation

extension BurnBarDaemonServer {
    func handleFleetRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .fleetSnapshot:
            return try await handleFleetSnapshot(requestData: requestData, decoder: decoder)
        case .fleetOrchestratorGet:
            return try await handleFleetOrchestratorGet(requestData: requestData, decoder: decoder)
        case .fleetOrchestratorSet:
            return try await handleFleetOrchestratorSet(
                requestData: requestData,
                decoder: decoder,
                method: method.rawValue
            )
        case .fleetDirectiveRecord:
            return try await handleFleetDirectiveRecord(
                requestData: requestData,
                decoder: decoder,
                method: method.rawValue
            )
        default:
            preconditionFailure("Unhandled fleet RPC method: \(method.rawValue)")
        }
    }

    func handleFleetSnapshot(requestData: Data, decoder: JSONDecoder) async throws -> Data {
        let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
        let readState = await fleetService.readLatestSnapshot()
        switch readState {
        case .notReady:
            return encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message:
                    "BurnBar fleet snapshot is not ready yet: the first probe tick has not completed. Retry shortly."
            )
        case .degraded(let reason, _):
            return encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "BurnBar fleet snapshot tick degraded: \(reason)"
            )
        case .ready(let snapshot):
            return encode(
                BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarFleetSnapshotResponse(snapshot: snapshot)
                )
            )
        }
    }

    func handleFleetOrchestratorGet(requestData: Data, decoder: JSONDecoder) async throws -> Data {
        let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
        if let object = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
           object["params"] != nil {
            _ = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetOrchestratorGetRequest>.self,
                from: requestData
            )
        }
        return encode(
            BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarFleetOrchestratorGetResponse(
                    state: try await fleetService.orchestratorStateChecked()
                )
            )
        )
    }

    func handleFleetOrchestratorSet(
        requestData: Data,
        decoder: JSONDecoder,
        method: String
    ) async throws -> Data {
        let typedRequest = try decoder.decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetOrchestratorSetParams>.self,
            from: requestData
        )
        do {
            let updated = try await fleetService.setOrchestratorState(
                BurnBarOrchestratorState(designation: typedRequest.params.designation)
            )
            return encode(
                BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarFleetOrchestratorSetResponse(state: updated)
                )
            )
        } catch {
            return encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "BurnBar RPC method '\(method)' rejected the payload: \(error.localizedDescription)"
            )
        }
    }

    func handleFleetDirectiveRecord(
        requestData: Data,
        decoder: JSONDecoder,
        method: String
    ) async throws -> Data {
        let typedRequest = try decoder.decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetDirectiveRecordRequest>.self,
            from: requestData
        )
        do {
            let recorded = try await fleetService.recordDirective(typedRequest.params.directive)
            return encode(
                BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: BurnBarFleetDirectiveRecordResponse(directive: recorded)
                )
            )
        } catch {
            return encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "BurnBar RPC method '\(method)' rejected the payload: \(error.localizedDescription)"
            )
        }
    }
}

private struct BurnBarFleetOrchestratorSetParams: Codable, Sendable {
    let designation: BurnBarOrchestratorDesignation

    private struct StateProbe: Codable {
        let designation: BurnBarOrchestratorDesignation
    }

    private enum CodingKeys: String, CodingKey {
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(StateProbe.self, forKey: .state)
        designation = state.designation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(StateProbe(designation: designation), forKey: .state)
    }
}

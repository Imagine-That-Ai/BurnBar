import BurnBarCore
import Foundation

/// M4 daemon-orchestrator-state RPC handlers for `BurnBarDaemonServer`
/// (extension in a dedicated file so the dispatch switch and the server file
/// stay within the lint budgets).
///
/// Handlers:
/// - `daemon.fleet.orchestrator.get` — reads the daemon-owned designation +
///   pendingDirectives count (read-only; VAL-CROSS-009).
/// - `daemon.fleet.orchestrator.set` — validates the designation payload typed
///   and stores it (VAL-RPC-009).
/// - `daemon.fleet.directive.record` — validates the directive payload typed
///   (ORCH-029) and upserts the record keyed by directive_id (idempotent).
extension BurnBarDaemonServer {
    func handleFleetOrchestratorGet(requestData: Data, decoder: JSONDecoder) async throws -> Data {
        // The plain envelope is decoded so both `{"id":...,"method":
        // "daemon.fleet.orchestrator.get"}` and a params-bearing form are
        // accepted; a present-but-wrong-typed params payload is rejected
        // typed (-32602) rather than silently accepted.
        let typedRequest = try decodeRequest(BurnBarRPCRequestEnvelope.self, from: requestData, decoder: decoder)
        try validateOptionalParams(
            requestData: requestData,
            decoder: decoder,
            paramsType: BurnBarFleetOrchestratorGetRequest.self
        )
        let response = BurnBarRPCResponseEnvelope(
            id: typedRequest.id,
            protocolVersion: BurnBarProtocolVersion.current,
            result: BurnBarFleetOrchestratorGetResponse(state: try await fleetService.orchestratorStateChecked())
        )
        return encode(response)
    }

    func handleFleetOrchestratorSet(requestData: Data, decoder: JSONDecoder, method: String) async throws -> Data {
        // The params decode is tolerant of a minimal
        // `{"state":{"designation":{...}}}` payload: the server only consumes
        // `designation` (setAt is daemon-stamped and pendingDirectives is
        // always recomputed live), so a payload without those fields is
        // accepted. A wrong-typed `params` value is still rejected typed
        // (-32602). Invalid designations (unknown kind, agent id outside the
        // declared roster) are rejected typed and the stored state stays
        // unchanged (VAL-RPC-009).
        let typedRequest = try decodeRequest(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetOrchestratorSetParams>.self,
            from: requestData,
            decoder: decoder
        )
        do {
            let updated = try await fleetService.setOrchestratorState(
                BurnBarOrchestratorState(designation: typedRequest.params.designation)
            )
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarFleetOrchestratorSetResponse(state: updated)
            )
            return encode(response)
        } catch {
            return Self.controlValidationError(id: typedRequest.id, error: error, method: method)
        }
    }

    func handleFleetDirectiveRecord(requestData: Data, decoder: JSONDecoder, method: String) async throws -> Data {
        // Validates the directive payload typed (the canonical validation
        // home is the control store — ORCH-029) and upserts the record keyed
        // by directive_id (retries never duplicate).
        let typedRequest = try decodeRequest(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetDirectiveRecordRequest>.self,
            from: requestData,
            decoder: decoder
        )
        do {
            let recorded = try await fleetService.recordDirective(typedRequest.params.directive)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarFleetDirectiveRecordResponse(directive: recorded)
            )
            return encode(response)
        } catch {
            return Self.controlValidationError(id: typedRequest.id, error: error, method: method)
        }
    }

    /// Encodes a typed `-32603` validation error for orchestrator-set and
    /// directive-record rejections. The message names the failing surface and
    /// the reason; `details` carries the method and the typed reason — never
    /// payload content. A rejected mutation leaves the stored state and the
    /// directive history unchanged (VAL-RPC-009 / ORCH-029).
    private static func controlValidationError(id: String, error: Error, method: String) -> Data {
        BurnBarRPCErrorEnvelope.encodeErrorResponse(
            id: id,
            code: BurnBarRPCErrorCode.internalError,
            message: "BurnBar RPC method '\(method)' rejected the payload: \(error.localizedDescription)",
            details: "method=\(method); reason=\(error.localizedDescription)"
        )
    }

    /// Optional-params validation for methods whose params are optional (a
    /// request with NO `params` key is accepted); a request whose `params` is
    /// present but fails to decode as the method's typed params throws, which
    /// the caller maps to the typed invalid-params error (-32602, VAL-RPC-011)
    /// — a wrong-typed params payload is never silently accepted.
    private func validateOptionalParams<Params: Codable & Sendable>(
        requestData: Data,
        decoder: JSONDecoder,
        paramsType: Params.Type
    ) throws {
        guard let object = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              object["params"] != nil else {
            return
        }
        _ = try decodeRequest(
            BurnBarRPCRequestEnvelopeWithParams<Params>.self,
            from: requestData,
            decoder: decoder
        )
    }
}

/// Tolerant params for `daemon.fleet.orchestrator.set`. Only `designation`
/// is consumed: `setAt` is daemon-stamped and `pendingDirectives` is always
/// recomputed live, so a minimal `{"state":{"designation":{...}}}` payload is
/// accepted. A wrong-typed `params` value is still rejected typed (-32602,
/// VAL-RPC-011).
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

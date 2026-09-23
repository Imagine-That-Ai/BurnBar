import Foundation
import OpenBurnBarEngine

extension BurnBarDaemonServer {
    func handleSwitcherRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .switcherActiveProfileApply:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSwitcherActiveProfileApplyRequest>.self,
                from: requestData
            )
            guard let switcherProfileStore else {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.unavailable,
                    message: "Switcher profile store is unavailable. Configure OPENBURNBAR_INDEX_DATABASE_PATH and restart the daemon."
                )
            }
            do {
                let result = try switcherProfileStore.switcherActiveProfileApply(typedRequest.params)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                )
                return encode(response)
            } catch {
                return switcherErrorResponse(id: typedRequest.id, error: error)
            }
        default:
            preconditionFailure("Unhandled switcher RPC method: \(method.rawValue)")
        }
    }

    /// Error mapping for the switcher app lane: validation failures are the
    /// caller's fault (`invalidParams`, matching the other single-writer
    /// lanes), never an `internalError`.
    private func switcherErrorResponse(id: String, error: Error) -> Data {
        if case BurnBarSwitcherSQLiteProfileStore.ActiveProfileLaneError.invalidRequest = error {
            return encodeErrorResponse(id: id, code: BurnBarRPCErrorCode.invalidParams, message: error.localizedDescription)
        }
        return encodeErrorResponse(id: id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
    }
}

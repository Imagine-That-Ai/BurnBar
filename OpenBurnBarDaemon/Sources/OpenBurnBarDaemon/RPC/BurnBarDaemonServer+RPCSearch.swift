import OpenBurnBarEngine
import Foundation

extension BurnBarDaemonServer {
    func handleSearchRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .searchQuery:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSearchQueryRequest>.self,
                from: requestData
            )
            guard let indexedSearch else {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message:
                        "OpenBurnBar indexed search is not available. Ensure OPENBURNBAR_INDEX_DATABASE_PATH points to your OpenBurnBar database and restart the daemon."
                )
            }
            do {
                let result = try indexedSearch.search(query: typedRequest.params)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                )
                return encode(response)
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }
        case .searchSQL:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarSearchSQLRequest>.self,
                from: requestData
            )
            guard let indexedSearch else {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message:
                        "OpenBurnBar indexed search is not available. Ensure OPENBURNBAR_INDEX_DATABASE_PATH points to your OpenBurnBar database and restart the daemon."
                )
            }
            do {
                let result = try indexedSearch.readOnlySQL(typedRequest.params)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                )
                return encode(response)
            } catch {
                // Rejections (write attempts, multi-statement, budget) are caller
                // errors, not daemon faults — surface them as invalid params so
                // socket clients can distinguish "fix your SQL" from "daemon down".
                let code = (error is BurnBarIndexedSearchService.ReadOnlySQLError)
                    ? BurnBarRPCErrorCode.invalidParams
                    : BurnBarRPCErrorCode.internalError
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: code,
                    message: error.localizedDescription
                )
            }
        default:
            preconditionFailure("Unhandled search RPC method: \(method.rawValue)")
        }
    }
}

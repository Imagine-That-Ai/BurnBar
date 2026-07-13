import Foundation
import OpenBurnBarCore

extension BurnBarDaemonServer {
    func handleCodeRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        guard let projectCodeMemory else {
            return encodeErrorResponse(
                id: "code-unavailable",
                code: BurnBarRPCErrorCode.internalError,
                message: "Project code memory is not available. Configure OPENBURNBAR_INDEX_DATABASE_PATH and restart the daemon."
            )
        }

        switch method {
        case .codeIndexProject:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeIndexProjectRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.indexProject(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeWatchProject:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeWatchProjectRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.watchProject(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeSearch:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeSearchRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.searchCode(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeContextPack:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeContextPackRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.contextPack(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeGetSymbol:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeSymbolRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.getSymbol(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeFindReferences:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeSymbolRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.findReferences(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeCallGraph:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeSymbolRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.callGraph(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeDiagnostics:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeDiagnosticsRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.diagnostics(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeIndexStatus:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeIndexStatusRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.indexStatus(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeExplore:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeExploreRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.explore(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeOpsDiagnostics:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeOpsDiagnosticsRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: try projectCodeMemory.opsDiagnostics(typedRequest.params)))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeDatabaseSnapshot:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeDatabaseSnapshotRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    result: try projectCodeMemory.databaseSnapshot(typedRequest.params)
                ))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        case .codeDatabaseRestore:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProjectCodeDatabaseRestoreRequest>.self,
                from: requestData
            )
            do {
                return encode(BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    result: try projectCodeMemory.restoreDatabaseSnapshot(typedRequest.params)
                ))
            } catch {
                return encodeErrorResponse(id: typedRequest.id, code: BurnBarRPCErrorCode.internalError, message: error.localizedDescription)
            }
        default:
            preconditionFailure("Unhandled code RPC method: \(method.rawValue)")
        }
    }
}

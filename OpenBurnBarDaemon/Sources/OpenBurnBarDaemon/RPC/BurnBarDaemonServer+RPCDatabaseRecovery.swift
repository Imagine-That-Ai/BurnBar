import Foundation
import OpenBurnBarCore

extension BurnBarDaemonServer {
    func handleDatabaseRecoveryRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        guard let databaseRecoveryService else {
            return encodeErrorResponse(
                id: "database-recovery-unavailable",
                code: BurnBarRPCErrorCode.internalError,
                message: "Database recovery is unavailable. Configure OPENBURNBAR_INDEX_DATABASE_PATH and restart the daemon."
            )
        }

        switch method {
        case .databaseRecoveryBundleExport:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarDatabaseRecoveryBundleExportRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: request.id,
                        result: try databaseRecoveryService.exportBundle(request: request.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }
        case .databaseRecoveryBundleImport:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarDatabaseRecoveryBundleImportRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: request.id,
                        result: try databaseRecoveryService.importBundle(request: request.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }
        default:
            preconditionFailure("Unhandled database recovery RPC method: \(method.rawValue)")
        }
    }
}

import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleLifecycleRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        request: BurnBarRPCRequestEnvelope,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .health:
            _ = BurnBarHealthRequest()
            logger.debug(
                "rpc_request_received",
                metadata: [
                    "request_id": request.id,
                    "method": method.rawValue
                ]
            )
            let response = BurnBarRPCResponseEnvelope(
                id: request.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: healthResponse()
            )
            return encode(response)
        case .catalog:
            _ = BurnBarCatalogRequest()
            logger.debug(
                "rpc_request_received",
                metadata: [
                    "request_id": request.id,
                    "method": method.rawValue
                ]
            )
            let response = BurnBarRPCResponseEnvelope(
                id: request.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarCatalogResponse(catalog: configuration.catalog)
            )
            return encode(response)
        case .authBootstrap:
            return encodeErrorResponse(
                id: request.id,
                code: BurnBarRPCErrorCode.methodNotFound,
                message: "authBootstrap must be called via direct BurnBarDaemonAuthManager, not via socket RPC"
            )
        default:
            preconditionFailure("Unhandled lifecycle RPC method: \(method.rawValue)")
        }
    }
}

import Foundation
import OpenBurnBarEngine

extension BurnBarDaemonServer {
    func handleMemoryRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
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
        default:
            preconditionFailure("Unhandled memory RPC method: \(method.rawValue)")
        }
    }
}

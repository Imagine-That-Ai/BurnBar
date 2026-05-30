import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import Foundation

extension BurnBarDaemonServer {
    func handleComputerUseRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .computerUseSessionStart:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseSessionStartRequest>.self,
                from: requestData
            )
            let result: ComputerUseSessionStartResponse = try await computerUseService.startSession(typedRequest.params)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
            return encode(response)
        case .computerUseInvoke:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseInvokeRequest>.self,
                from: requestData
            )
            let result: ComputerUseInvokeResponse = try await computerUseService.invoke(typedRequest.params)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
            return encode(response)
        case .computerUseApprovalPending:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseApprovalPendingRequest>.self,
                from: requestData
            )
            let result: ComputerUseApprovalPendingResponse = await computerUseService.pendingApprovals(typedRequest.params)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
            return encode(response)
        case .computerUseApprovalRespond:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseApprovalRespondRequest>.self,
                from: requestData
            )
            let result: ComputerUseApprovalRespondResponse = await computerUseService.respondToApproval(typedRequest.params)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
            return encode(response)
        case .computerUsePanicHalt:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUsePanicHaltRequest>.self,
                from: requestData
            )
            let result: ComputerUsePanicHaltResponse = try await computerUseService.panicHalt(typedRequest.params)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
            return encode(response)
        case .computerUseAuditExport:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseAuditExportRequest>.self,
                from: requestData
            )
            let result: ComputerUseAuditExportResponse = try await computerUseService.exportAudit(typedRequest.params)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
            return encode(response)
        default:
            preconditionFailure("Unhandled computer use RPC method: \(method.rawValue)")
        }
    }
}

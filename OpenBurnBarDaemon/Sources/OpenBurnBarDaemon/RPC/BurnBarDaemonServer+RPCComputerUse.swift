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
            // T-DMN-04: fail closed unless a fresh, op-hash-bound, pinned-key
            // local-auth proof authorizes starting this high-risk session.
            if let denial = enforceLocalAuthProof(
                requestId: typedRequest.id,
                method: method,
                proof: typedRequest.params.localAuthProof,
                sourceDeviceId: typedRequest.params.sourceDeviceId,
                intentHashHex: typedRequest.params.intentHashHex
            ) {
                return denial
            }
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
            // T-DMN-04: fail closed unless a fresh, op-hash-bound, pinned-key
            // local-auth proof authorizes dispatching this high-risk action.
            if let denial = enforceLocalAuthProof(
                requestId: typedRequest.id,
                method: method,
                proof: typedRequest.params.localAuthProof,
                sourceDeviceId: typedRequest.params.sourceDeviceId,
                intentHashHex: typedRequest.params.intentHashHex
            ) {
                return denial
            }
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

    /// T-DMN-04 — gate a high-risk computer-use RPC on an independently-verified
    /// local-auth proof. Returns `nil` when the request may proceed and an encoded
    /// `unauthorized` error response when it must be refused (fail closed).
    ///
    /// When `localAuthProofVerifier` is `nil` (in-process tests, unsigned developer
    /// builds) this is a no-op so existing behavior is preserved. When it is wired
    /// (production), the request MUST carry a proof, a source device, and the op
    /// (intent) hash the daemon is about to honor; the daemon then re-verifies the
    /// proof against the PINNED phone key. Any missing field or verification
    /// failure is refused — so a compromised first-party app cannot forward a
    /// fabricated or retargeted grant.
    func enforceLocalAuthProof(
        requestId: String,
        method: BurnBarRPCMethod,
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof?,
        sourceDeviceId: String?,
        intentHashHex: String?
    ) -> Data? {
        guard let verifier = localAuthProofVerifier else {
            // Proof enforcement is not wired for this daemon instance (dev/test).
            return nil
        }

        guard let proof,
              let sourceDeviceId, sourceDeviceId.isEmpty == false,
              let intentHashHex, intentHashHex.isEmpty == false else {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.warning(
                "computer_use_local_auth_proof_missing",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue,
                    "has_proof": "\(proof != nil)",
                    "has_device": "\(sourceDeviceId?.isEmpty == false)",
                    "has_intent": "\(intentHashHex?.isEmpty == false)"
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' requires a fresh local-authentication proof."
            )
        }

        do {
            _ = try verifier.verify(
                proof: proof,
                expectedDeviceId: sourceDeviceId,
                expectedIntentHashHex: intentHashHex
            )
            logger.notice(
                "computer_use_local_auth_proof_verified",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue,
                    "device_id": sourceDeviceId
                ]
            )
            return nil
        } catch let failure as DaemonLocalAuthProofVerifier.VerificationFailure {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.warning(
                "computer_use_local_auth_proof_rejected",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue,
                    "detail": DaemonLocalAuthProofVerifier.auditToken(for: failure)
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' local-authentication proof was rejected."
            )
        } catch {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.error(
                "computer_use_local_auth_proof_error",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue,
                    "error": "\(error)"
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' local-authentication proof could not be verified."
            )
        }
    }
}

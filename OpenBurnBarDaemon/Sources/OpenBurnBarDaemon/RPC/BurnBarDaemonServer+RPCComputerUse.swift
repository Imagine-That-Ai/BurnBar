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
                intentHashHex: typedRequest.params.intentHashHex,
                grantBinding: typedRequest.params.localAuthGrantBinding
            ) {
                return denial
            }
            let result: ComputerUseSessionStartResponse = try await computerUseService.startSession(typedRequest.params)
            rememberLocalAuthVerifiedSession(
                sessionId: result.sessionId,
                requestedTimeoutSeconds: typedRequest.params.sessionTimeoutSeconds
            )
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
            // T-DMN-04: fail closed unless this session was started with a fresh,
            // op-hash-bound, pinned-key local-auth proof. The proof is single-use;
            // per-action replay would correctly fail, so invokes bind to the
            // daemon session established by the verified start request.
            if let denial = enforceLocalAuthVerifiedSession(
                requestId: typedRequest.id,
                method: method,
                sessionId: typedRequest.params.sessionId
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
        case .phoneControlPinProvision:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<DaemonPhoneControlPinProvisionRequest>.self,
                from: requestData
            )
            do {
                let result = try await provisionPhoneControlPin(typedRequest.params)
                let response = BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                )
                return encode(response)
            } catch let failure as PhoneControlPinProvisionFailure {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: failure.code,
                    message: failure.message
                )
            }
        default:
            preconditionFailure("Unhandled computer use RPC method: \(method.rawValue)")
        }
    }

    private struct PhoneControlPinProvisionFailure: Error {
        let code: Int
        let message: String
    }

    /// T-DMN-04: persist the first-party Mac app's pinned phone-control verifying
    /// key into the daemon-owned pin store. Fail closed on malformed keys or
    /// keychain/backing-store errors.
    private func provisionPhoneControlPin(
        _ request: DaemonPhoneControlPinProvisionRequest
    ) async throws -> DaemonPhoneControlPinProvisionResponse {
        guard let pinStore = phoneControlPinStore else {
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.methodNotFound,
                message: "Phone-control pin provisioning is not enabled for this daemon instance."
            )
        }
        guard let publicKeyData = Data(base64Encoded: request.publicKeyBase64),
              let verifyingKey = try? PhoneControlVerifyingKey(
                kind: request.keyKind,
                publicKeyRepresentation: publicKeyData
              ) else {
            logger.warning(
                "phone_control_pin_provision_malformed",
                metadata: [
                    "device_id": request.deviceId,
                    "key_kind": request.keyKind.rawValue
                ]
            )
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.invalidParams,
                message: "Malformed publicKeyBase64 or keyKind for device \(request.deviceId)."
            )
        }
        switch pinStore.pin(deviceId: request.deviceId, key: verifyingKey) {
        case .pinned:
            logger.notice(
                "phone_control_pin_provisioned",
                metadata: [
                    "device_id": request.deviceId,
                    "key_kind": request.keyKind.rawValue
                ]
            )
            return DaemonPhoneControlPinProvisionResponse(pinned: true, deviceId: request.deviceId)
        case .malformed:
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.invalidParams,
                message: "Malformed device id for phone-control pin provisioning."
            )
        case .absent:
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.internalError,
                message: "Unexpected absent pin result for device \(request.deviceId)."
            )
        case .conflict:
            logger.warning(
                "phone_control_pin_provision_conflict",
                metadata: [
                    "device_id": request.deviceId,
                    "key_kind": request.keyKind.rawValue
                ]
            )
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.unauthorized,
                message: "Phone-control pin already exists for device \(request.deviceId); a trusted-pairing and local-trust reset is required before rotating its key."
            )
        case .storeError(let status):
            logger.error(
                "phone_control_pin_provision_failed",
                metadata: [
                    "device_id": request.deviceId,
                    "status": "\(status)"
                ]
            )
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.internalError,
                message: "Could not persist phone-control pin for device \(request.deviceId)."
            )
        }
    }

    private static var maxLocalAuthVerifiedSessionLifetime: TimeInterval {
        AgentCapabilityGrantRequest.defaultGrantDuration
    }

    func rememberLocalAuthVerifiedSession(
        sessionId: String,
        requestedTimeoutSeconds: Int,
        now: Date = Date()
    ) {
        guard localAuthProofVerifier != nil else { return }
        let requestedLifetime = requestedTimeoutSeconds > 0
            ? TimeInterval(requestedTimeoutSeconds)
            : Self.maxLocalAuthVerifiedSessionLifetime
        let lifetime = min(requestedLifetime, Self.maxLocalAuthVerifiedSessionLifetime)
        localAuthVerifiedComputerUseSessions = localAuthVerifiedComputerUseSessions.filter { $0.value > now }
        localAuthVerifiedComputerUseSessions[sessionId] = now.addingTimeInterval(lifetime)
        logger.notice(
            "computer_use_local_auth_session_authorized",
            metadata: [
                "session_id": sessionId,
                "expires_in_seconds": "\(Int(lifetime))"
            ]
        )
    }

    func enforceLocalAuthVerifiedSession(
        requestId: String,
        method: BurnBarRPCMethod,
        sessionId: String,
        now: Date = Date()
    ) -> Data? {
        guard localAuthProofVerifier != nil else {
            // Proof enforcement is not wired for this daemon instance (dev/test).
            return nil
        }

        localAuthVerifiedComputerUseSessions = localAuthVerifiedComputerUseSessions.filter { $0.value > now }
        if let expiresAt = localAuthVerifiedComputerUseSessions[sessionId], expiresAt > now {
            return nil
        }

        BurnBarDaemonMetricsCounters.recordRPCError()
        logger.warning(
            "computer_use_local_auth_session_missing",
            metadata: [
                "request_id": requestId,
                "method": method.rawValue,
                "session_id": sessionId
            ]
        )
        return encodeErrorResponse(
            id: requestId,
            code: BurnBarRPCErrorCode.unauthorized,
            message: "OpenBurnBar RPC method '\(method.rawValue)' requires a local-auth-verified Computer Use session."
        )
    }

    /// T-DMN-04 — gate a high-risk computer-use RPC on an independently-verified
    /// local-auth proof. Returns `nil` when the request may proceed and an encoded
    /// `unauthorized` error response when it must be refused (fail closed).
    ///
    /// When `localAuthProofVerifier` is `nil` (in-process tests, unsigned developer
    /// builds) this is a no-op so existing behavior is preserved. When it is wired
    /// (production), the request MUST carry a proof, a source device, and the op
    /// grant binding the daemon is about to honor; the daemon derives the expected
    /// intent hash from those fields and re-verifies the proof against the PINNED
    /// phone key. Any missing field or verification failure is refused so callers
    /// cannot forward fabricated or retargeted grants.
    func enforceLocalAuthProof(
        requestId: String,
        method: BurnBarRPCMethod,
        proof: HermesRealtimeRelayAgentGrantLocalAuthProof?,
        sourceDeviceId: String?,
        intentHashHex: String?,
        grantBinding: ComputerUseLocalAuthGrantBinding?
    ) -> Data? {
        guard let verifier = localAuthProofVerifier else {
            // Proof enforcement is not wired for this daemon instance (dev/test).
            return nil
        }

        guard let proof,
              let sourceDeviceId, sourceDeviceId.isEmpty == false,
              let grantBinding else {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.warning(
                "computer_use_local_auth_proof_missing",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue,
                    "has_proof": "\(proof != nil)",
                    "has_device": "\(sourceDeviceId?.isEmpty == false)",
                    "has_binding": "\(grantBinding != nil)"
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' requires a fresh local-authentication proof."
            )
        }

        guard grantBinding.sourceDeviceId == sourceDeviceId,
              grantBinding.localAuthenticationSatisfied else {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.warning(
                "computer_use_local_auth_binding_rejected",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue,
                    "binding_device_matches": "\(grantBinding.sourceDeviceId == sourceDeviceId)",
                    "local_auth_satisfied": "\(grantBinding.localAuthenticationSatisfied)"
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' local-authentication proof was rejected."
            )
        }

        let expectedIntentHashHex: String
        do {
            expectedIntentHashHex = try ComputerUsePhoneControlSigner()
                .canonicalAgentGrantRequestHashHex(binding: grantBinding)
        } catch {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.error(
                "computer_use_local_auth_binding_hash_error",
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

        if let intentHashHex, intentHashHex.isEmpty == false,
           intentHashHex.lowercased() != expectedIntentHashHex.lowercased() {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.warning(
                "computer_use_local_auth_intent_hint_mismatch",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' local-authentication proof was rejected."
            )
        }

        do {
            _ = try verifier.verify(
                proof: proof,
                expectedDeviceId: sourceDeviceId,
                expectedIntentHashHex: expectedIntentHashHex
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

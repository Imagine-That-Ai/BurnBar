import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import Foundation

extension BurnBarDaemonServer {
    func handleComputerUseRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data,
        peerPID: Int32? = nil
    ) async throws -> Data {
        switch method {
        case .computerUseCapabilityStateUpdate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseCapabilityStateUpdateRequest>.self,
                from: requestData
            )
            let result = try await computerUseService.updateCapabilityState(typedRequest.params)
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            ))
        case .computerUseSessionGrantReadiness:
            let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            #if os(Linux)
            let result: ComputerUseSessionGrantReadinessResponse
            if let broker = computerUseSessionGrantBroker {
                if broker.readinessReason != .ready {
                    result = ComputerUseSessionGrantReadinessResponse(
                        available: false,
                        reason: broker.readinessReason
                    )
                } else if computerUseSessionGrantMetadataResolver == nil
                    || computerUseSessionGrantReadinessProvider == nil {
                    result = ComputerUseSessionGrantReadinessResponse(
                        available: false,
                        reason: .pairingUnavailable
                    )
                } else if await computerUseSessionGrantReadinessProvider?() == true {
                    result = ComputerUseSessionGrantReadinessResponse(
                        available: true,
                        reason: .ready
                    )
                } else {
                    result = ComputerUseSessionGrantReadinessResponse(
                        available: false,
                        reason: .pairingUnavailable
                    )
                }
            } else {
                result = ComputerUseSessionGrantReadinessResponse(
                    available: false,
                    reason: .brokerUnavailable
                )
            }
            #else
            let result = ComputerUseSessionGrantReadinessResponse(
                available: false,
                reason: .brokerUnavailable
            )
            #endif
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            ))
        case .computerUseSessionGrantAcquire:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseSessionGrantAcquireRequest>.self,
                from: requestData
            )
            #if os(Linux)
            let sessionRequest = typedRequest.params.sessionRequest
            guard sessionRequest.mode == ComputerUseMode.browser.rawValue,
                  sessionRequest.grantChallengeId == nil,
                  sessionRequest.desktopOwnerAuthorizationRequest?.method == .linuxDesktopOwner,
                  let runID = sessionRequest.runID,
                  let requirement = await runService.computerUseRequirement(for: runID),
                  requirement.clientID == sessionRequest.clientID
                    || requirement.clientID == BurnBarRunService.controllerRuntimeClientID,
                  sessionRequest.runCallID == requirement.invocation.callID,
                  sessionRequest.runGeneration == requirement.generation else {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.invalidParams,
                    message: "Computer Use authority requires an exact owned run waiting for a browser session."
                )
            }
            guard let broker = computerUseSessionGrantBroker,
                  let metadataResolver = computerUseSessionGrantMetadataResolver else {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: "Paired-phone Computer Use authority is unavailable."
                )
            }
            do {
                let metadata = try await metadataResolver(requirement, sessionRequest)
                let status = try await broker.acquire(metadata: metadata, request: sessionRequest)
                let result = ComputerUseSessionGrantStatusResponse(
                    challengeId: status.challengeID,
                    sessionIntentId: status.sessionIntentID,
                    state: Self.brokerState(status.state),
                    issuedAt: status.issuedAt,
                    expiresAt: status.expiresAt
                )
                return encode(BurnBarRPCResponseEnvelope(
                    id: typedRequest.id,
                    protocolVersion: BurnBarProtocolVersion.current,
                    result: result
                ))
            } catch {
                logger.warning(
                    "computer_use_session_grant_acquire_rejected",
                    metadata: ["request_id": typedRequest.id, "error": "\(error)"]
                )
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.unauthorized,
                    message: "Paired-phone Computer Use authority could not be acquired."
                )
            }
            #else
            return encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "The paired-phone Linux authority broker is unavailable on this platform."
            )
            #endif
        case .computerUseSessionGrantStatus:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseSessionGrantStatusRequest>.self,
                from: requestData
            )
            #if os(Linux)
            guard let broker = computerUseSessionGrantBroker,
                  let status = await broker.status(challengeID: typedRequest.params.challengeId) else {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.invalidParams,
                    message: "Computer Use authority challenge is unavailable or no longer retained."
                )
            }
            let result = ComputerUseSessionGrantStatusResponse(
                challengeId: status.challengeID,
                sessionIntentId: status.sessionIntentID,
                state: Self.brokerState(status.state),
                issuedAt: status.issuedAt,
                expiresAt: status.expiresAt
            )
            return encode(BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            ))
            #else
            return encodeErrorResponse(
                id: typedRequest.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "The paired-phone Linux authority broker is unavailable on this platform."
            )
            #endif
        case .computerUseSessionStart:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseSessionStartRequest>.self,
                from: requestData
            )
            var sessionRequest = typedRequest.params
            let boundClientID: BurnBarClientID?
            let runRequirement: BurnBarComputerUseRunRequirement?
            #if os(Linux)
            var deferredStartReservation: ComputerUseSessionGrantBroker.StartReservation?
            #endif
            #if os(Linux)
            if sessionRequest.mode == ComputerUseMode.browser.rawValue {
                guard let runID = sessionRequest.runID,
                      let requirement = await runService.computerUseRequirement(for: runID),
                      requirement.clientID == sessionRequest.clientID
                        || requirement.clientID == BurnBarRunService.controllerRuntimeClientID,
                      sessionRequest.runCallID == requirement.invocation.callID,
                      sessionRequest.runGeneration == requirement.generation else {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.invalidParams,
                        message: "Browser Computer Use requires an owned agent run waiting for a Computer Use session."
                    )
                }
                boundClientID = requirement.clientID
                runRequirement = requirement
            } else {
                boundClientID = nil
                runRequirement = nil
            }
            #else
            // The macOS gold-standard Agent Tool Broker owns its Browser CU
            // lifecycle directly; Linux alone uses the managed-run handshake.
            boundClientID = nil
            runRequirement = nil
            #endif
            // Validate the non-secret run selection first so a stale picker row
            // cannot consume a single-use phone proof. Proof verification stays
            // immediately adjacent to session reservation/start.
            #if os(Linux)
            if sessionRequest.mode == ComputerUseMode.browser.rawValue,
               localAuthProofVerifier != nil {
                guard sessionRequest.desktopOwnerAuthorizationRequest?.method == .linuxDesktopOwner,
                      let peerPID,
                      let runRequirement,
                      let challengeID = sessionRequest.grantChallengeId,
                      let broker = computerUseSessionGrantBroker else {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Browser Computer Use requires fresh paired-phone and Linux desktop-owner authorization."
                    )
                }
                let preparedRequest: ComputerUseSessionStartRequest
                do {
                    preparedRequest = try await broker.prepare(
                        challengeID: challengeID,
                        request: sessionRequest
                    ).request
                } catch {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Browser Computer Use paired-phone authority is not ready or no longer valid."
                    )
                }
                if let denial = enforceLocalAuthProof(
                    requestId: typedRequest.id,
                    method: method,
                    proof: preparedRequest.localAuthProof,
                    sourceDeviceId: preparedRequest.sourceDeviceId,
                    intentHashHex: preparedRequest.intentHashHex,
                    grantBinding: preparedRequest.localAuthGrantBinding,
                    sessionRequest: preparedRequest,
                    consumeProof: false
                ) {
                    return denial
                }
                guard let operationID = preparedRequest.localAuthGrantBinding?.clientIntentId else {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Browser Computer Use authority is incomplete."
                    )
                }
                do {
                    try await linuxComputerUseOwnerAuthorizer(
                        peerPID,
                        operationID,
                        "Authorize Browser Computer Use for run \(runRequirement.runID.rawValue)"
                    )
                } catch {
                    logger.warning(
                        "computer_use_linux_owner_authorization_rejected",
                        metadata: [
                            "request_id": typedRequest.id,
                            "run_id": runRequirement.runID.rawValue,
                            "error": "\(error)"
                        ]
                    )
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Browser Computer Use Linux desktop-owner authorization was not completed."
                    )
                }
                guard await runService.computerUseRequirement(for: runRequirement.runID) == runRequirement else {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.invalidParams,
                        message: "The selected Computer Use run changed during authorization. Choose it again."
                    )
                }
                do {
                    let reservation = try await broker.reserveForStart(
                        challengeID: challengeID,
                        request: sessionRequest
                    )
                    deferredStartReservation = reservation
                    sessionRequest = reservation.request
                } catch {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Browser Computer Use authority expired or changed during desktop-owner authorization."
                    )
                }
            }
            #endif
            #if os(Linux)
            let defersProofConsumptionUntilSessionStart = deferredStartReservation != nil
            #else
            let defersProofConsumptionUntilSessionStart = false
            #endif
            if defersProofConsumptionUntilSessionStart == false,
               let denial = enforceLocalAuthProof(
                requestId: typedRequest.id,
                method: method,
                proof: sessionRequest.localAuthProof,
                sourceDeviceId: sessionRequest.sourceDeviceId,
                intentHashHex: sessionRequest.intentHashHex,
                grantBinding: sessionRequest.localAuthGrantBinding,
                sessionRequest: sessionRequest
            ) {
                return denial
            }
            let result: ComputerUseSessionStartResponse
            do {
                result = try await computerUseService.startSession(
                    sessionRequest,
                    boundClientID: boundClientID,
                    runGeneration: runRequirement?.generation
                )
            } catch {
                #if os(Linux)
                if let reservation = deferredStartReservation,
                   let broker = computerUseSessionGrantBroker {
                    if error is CancellationError || Task.isCancelled {
                        _ = await broker.consumeAfterAmbiguousStart(reservation)
                    } else if await broker.restoreAfterDefiniteStartFailure(reservation) == false {
                        _ = await broker.consumeAfterAmbiguousStart(reservation)
                    }
                }
                #endif
                throw error
            }
            #if os(Linux)
            if let reservation = deferredStartReservation,
               let broker = computerUseSessionGrantBroker {
                do {
                    try await broker.commitStartedSession(reservation)
                } catch {
                    _ = await broker.consumeAfterAmbiguousStart(reservation)
                    _ = try? await computerUseService.panicHalt(ComputerUsePanicHaltRequest(
                        sessionId: result.sessionId,
                        source: ComputerUsePanicSource.revoked.rawValue
                    ))
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Browser Computer Use authority could not be committed after session creation."
                    )
                }
                if let denial = enforceLocalAuthProof(
                    requestId: typedRequest.id,
                    method: method,
                    proof: sessionRequest.localAuthProof,
                    sourceDeviceId: sessionRequest.sourceDeviceId,
                    intentHashHex: sessionRequest.intentHashHex,
                    grantBinding: sessionRequest.localAuthGrantBinding,
                    sessionRequest: sessionRequest
                ) {
                    _ = try? await computerUseService.panicHalt(ComputerUsePanicHaltRequest(
                        sessionId: result.sessionId,
                        source: ComputerUsePanicSource.revoked.rawValue
                    ))
                    return denial
                }
            }
            #endif
            let authorizationExpiry = [
                sessionRequest.localAuthProof?.expiresAt,
                sessionRequest.localAuthGrantBinding?.expiresAt,
                sessionRequest.localAuthGrantBinding.map {
                    $0.requestedAt.addingTimeInterval($0.grantDurationSeconds)
                }
            ].compactMap { $0 }.min()
            await rememberLocalAuthVerifiedSession(
                sessionId: result.sessionId,
                requestedTimeoutSeconds: sessionRequest.sessionTimeoutSeconds,
                absoluteExpiry: authorizationExpiry
            )
            if localAuthProofVerifier != nil, let authorizationExpiry {
                await computerUseService.constrainSessionExpiry(
                    sessionID: ComputerUseSessionID(result.sessionId),
                    expiresAt: authorizationExpiry
                )
            }
            if let runRequirement {
                Task {
                    do {
                        let resumed = try await self.runService.resumeComputerUseRun(
                            runRequirement.runID,
                            expectedCallID: runRequirement.invocation.callID,
                            expectedGeneration: runRequirement.generation
                        )
                        if resumed == false {
                            _ = try? await self.computerUseService.panicHalt(
                                ComputerUsePanicHaltRequest(
                                    sessionId: result.sessionId,
                                    source: ComputerUsePanicSource.revoked.rawValue
                                )
                            )
                        }
                    } catch {
                        _ = try? await self.computerUseService.panicHalt(
                            ComputerUsePanicHaltRequest(
                                sessionId: result.sessionId,
                                source: ComputerUsePanicSource.revoked.rawValue
                            )
                        )
                    }
                }
            }
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
            if let denial = await enforceLocalAuthVerifiedSession(
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
            // Params are optional for this poll: Linux peer probes and some clients
            // omit `params` entirely. Missing params ⇒ empty filter (all pending).
            let requestId: String
            let params: ComputerUseApprovalPendingRequest
            if let typedRequest = try? decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseApprovalPendingRequest>.self,
                from: requestData
            ) {
                requestId = typedRequest.id
                params = typedRequest.params
            } else {
                let bare = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
                requestId = bare.id
                params = ComputerUseApprovalPendingRequest()
            }
            let pending = await computerUseService.pendingApprovals(params)
            let result = ComputerUseApprovalPendingResponse(
                requests: pending.requests,
                runRequirements: await runService.listComputerUseRequirements(),
                sessionActive: pending.sessionActive
            )
            let response = BurnBarRPCResponseEnvelope(
                id: requestId,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
            return encode(response)
        case .computerUseApprovalRespond:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<ComputerUseApprovalRespondRequest>.self,
                from: requestData
            )
            if let verifier = computerUseApprovalAuthorityVerifier {
                let pending = await computerUseService.pendingApprovals(
                    ComputerUseApprovalPendingRequest(sessionId: typedRequest.params.sessionId)
                ).requests.first { request in
                    request.approvalId == typedRequest.params.response.approvalId
                }
                guard let pending else {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Computer Use approval response does not match a pending request in this session."
                    )
                }
                do {
                    try await verifier.verify(
                        response: typedRequest.params.response,
                        pendingRequest: pending,
                        sessionID: typedRequest.params.sessionId
                    )
                } catch {
                    return encodeErrorResponse(
                        id: typedRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Computer Use approval response requires fresh signed authority from the pinned phone."
                    )
                }
            }
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
        let normalizedDeviceId = request.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedDeviceId.isEmpty == false else {
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.invalidParams,
                message: "Phone-control pin provisioning requires a device identity."
            )
        }
        let pinIdentifiers = [normalizedDeviceId, request.peerNodeId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .reduce(into: [String]()) { identifiers, candidate in
                if identifiers.contains(candidate) == false { identifiers.append(candidate) }
            }
        guard pinIdentifiers.isEmpty == false else {
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.invalidParams,
                message: "Phone-control pin provisioning requires a device identity."
            )
        }
        let result = pinStore.pinAliases(deviceIds: pinIdentifiers, key: verifyingKey)
        if case .pinned = result {
            logger.notice(
                "phone_control_pin_provisioned",
                metadata: [
                    "device_id": request.deviceId,
                    "peer_node_id": request.peerNodeId ?? request.deviceId,
                    "key_kind": request.keyKind.rawValue
                ]
            )
            return DaemonPhoneControlPinProvisionResponse(pinned: true, deviceId: request.deviceId)
        }
        switch result {
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
        case .pinned:
            throw PhoneControlPinProvisionFailure(
                code: BurnBarRPCErrorCode.internalError,
                message: "Could not persist every phone-control identity alias."
            )
        }
    }

    private static var maxLocalAuthVerifiedSessionLifetime: TimeInterval {
        AgentCapabilityGrantRequest.defaultGrantDuration
    }

    func rememberLocalAuthVerifiedSession(
        sessionId: String,
        requestedTimeoutSeconds: Int,
        absoluteExpiry: Date? = nil,
        now: Date = Date()
    ) async {
        guard localAuthProofVerifier != nil else { return }
        let typedSessionID = ComputerUseSessionID(sessionId)
        await computerUseAuthorizationRegistry.authorizeVerifiedSession(
            sessionID: typedSessionID,
            requestedTimeoutSeconds: requestedTimeoutSeconds,
            maximumLifetime: Self.maxLocalAuthVerifiedSessionLifetime,
            absoluteExpiry: absoluteExpiry,
            now: now
        )
        if let binding = await computerUseAuthorizationRegistry.binding(sessionID: typedSessionID) {
            await computerUseAuthorizationRegistry.authorize(
                sessionID: typedSessionID,
                runID: binding.runID,
                clientID: binding.clientID,
                requestedTimeoutSeconds: requestedTimeoutSeconds,
                maximumLifetime: Self.maxLocalAuthVerifiedSessionLifetime,
                absoluteExpiry: absoluteExpiry,
                now: now
            )
        }
        let requestedLifetime = requestedTimeoutSeconds > 0
            ? TimeInterval(requestedTimeoutSeconds)
            : Self.maxLocalAuthVerifiedSessionLifetime
        let sessionExpiry = now.addingTimeInterval(
            min(requestedLifetime, Self.maxLocalAuthVerifiedSessionLifetime)
        )
        let expiry = absoluteExpiry.map { min($0, sessionExpiry) } ?? sessionExpiry
        let lifetime = max(0, expiry.timeIntervalSince(now))
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
    ) async -> Data? {
        guard localAuthProofVerifier != nil else {
            // Proof enforcement is not wired for this daemon instance (dev/test).
            return nil
        }

        if await computerUseAuthorizationRegistry.contains(
            sessionID: ComputerUseSessionID(sessionId),
            now: now
        ) {
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
        grantBinding: ComputerUseLocalAuthGrantBinding?,
        sessionRequest: ComputerUseSessionStartRequest,
        consumeProof: Bool = true,
        now: Date = Date()
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

        let requiredCapability: AgentDesktopCapability?
        switch ComputerUseMode(rawValue: sessionRequest.mode) {
        case .browser:
            requiredCapability = .desktopBrowser
        case .system:
            requiredCapability = .desktopSystemInput
        case .agentWatch:
            requiredCapability = .accessibilityInspect
        case nil:
              requiredCapability = nil
        }
        let grantedCapabilities = Set(grantBinding.capabilities)
        guard let requiredCapability,
              grantedCapabilities.contains(requiredCapability.rawValue),
              grantBinding.trustMode == sessionRequest.trustMode,
              grantBinding.grantDurationSeconds.isFinite,
              grantBinding.grantDurationSeconds > 0,
              grantBinding.grantDurationSeconds <= AgentCapabilityGrantRequest.defaultGrantDuration,
              grantBinding.requestedAt <= now.addingTimeInterval(DaemonLocalAuthProofVerifier.maxClockSkew),
              grantBinding.expiresAt > now,
              grantBinding.expiresAt > grantBinding.requestedAt,
              grantBinding.expiresAt <= grantBinding.requestedAt.addingTimeInterval(
                grantBinding.grantDurationSeconds
              ) else {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.warning(
                "computer_use_local_auth_scope_rejected",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue,
                    "mode": sessionRequest.mode,
                    "trust_mode": sessionRequest.trustMode
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' local-authentication grant scope was rejected."
            )
        }

        let expectedIntentHashHex: String
        let expectedSessionIntentID: String
        do {
            let signer = ComputerUsePhoneControlSigner()
            expectedIntentHashHex = try signer.canonicalAgentGrantRequestHashHex(binding: grantBinding)
            expectedSessionIntentID = try signer.canonicalComputerUseSessionIntentID(request: sessionRequest)
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

        #if os(Linux)
        guard grantBinding.clientIntentId == expectedSessionIntentID else {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.warning(
                "computer_use_local_auth_session_intent_rejected",
                metadata: [
                    "request_id": requestId,
                    "method": method.rawValue
                ]
            )
            return encodeErrorResponse(
                id: requestId,
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC method '\(method.rawValue)' local-authentication proof is not bound to the requested session."
            )
        }
        #endif

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
            if consumeProof {
                _ = try verifier.verify(
                    proof: proof,
                    expectedDeviceId: sourceDeviceId,
                    expectedIntentHashHex: expectedIntentHashHex,
                    now: now
                )
            } else {
                _ = try verifier.validate(
                    proof: proof,
                    expectedDeviceId: sourceDeviceId,
                    expectedIntentHashHex: expectedIntentHashHex,
                    now: now
                )
            }
            logger.notice(
                consumeProof
                    ? "computer_use_local_auth_proof_verified"
                    : "computer_use_local_auth_proof_prevalidated",
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

    private static func brokerState(
        _ state: ComputerUseSessionGrantBroker.State
    ) -> ComputerUseSessionGrantBrokerState {
        switch state {
        case .awaitingPhone: .awaitingPhone
        case .ready: .ready
        case .starting: .consumed
        case .expired: .expired
        case .consumed: .consumed
        }
    }
}

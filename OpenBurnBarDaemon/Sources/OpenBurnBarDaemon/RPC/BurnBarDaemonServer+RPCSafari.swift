import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine

struct BurnBarResolvedSafariRPCRequest {
    let id: String
    let method: BurnBarRPCMethod
    let paramsData: Data
}

enum BurnBarSafariRPCHandlerError: Error, LocalizedError {
    case invalidParams(String)
    case unauthorized(String)
    case conflict(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidParams(let message),
             .unauthorized(let message),
             .conflict(let message),
             .unavailable(let message):
            return message
        }
    }
}

extension BurnBarDaemonServer {
    func resolveAuthenticatedSafariExternalizedRequestData(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        request: IncomingRequestEnvelope,
        requestData: Data,
        peerCapabilityProfile: BurnBarPeerCapabilityProfile?
    ) throws -> Data {
        guard request.method == method.rawValue else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "The Safari RPC envelope method does not match the routed method."
            )
        }
        guard let params = request.params,
              case .object(let object) = params,
              object[BurnBarSafariBridgeWire.appGroupPayloadMarkerKey] != nil else {
            return requestData
        }

        let isAuthenticatedSafariPeer =
            peerCapabilityProfile == .safariExtension
            || peerAuthenticator.isEnforced == false
        guard isAuthenticatedSafariPeer,
              BurnBarPeerCapabilityProfile.safariExtension.permits(method) else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "App Group payload references are accepted only from the authenticated Safari extension."
            )
        }
        guard let safariAppGroupPayloadResolver else {
            throw BurnBarSafariRPCHandlerError.unavailable(
                "The Safari App Group payload resolver is unavailable."
            )
        }

        let reference = try BurnBarSafariAppGroupPayloadReference.decodeMarker(
            from: params
        )
        let resolvedData = try safariAppGroupPayloadResolver.resolve(reference)
        let resolvedParams = try decoder.decode(
            BurnBarJSONValue.self,
            from: resolvedData
        )
        return try JSONEncoder().encode(
            BurnBarRPCRequestEnvelopeWithParams(
                id: request.id,
                method: method,
                authToken: request.authToken,
                params: resolvedParams
            )
        )
    }

    func handleSafariRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        let request = try resolveSafariBridgeRPCRequest(
            method: method,
            decoder: decoder,
            requestData: requestData
        )

        do {
            switch method {
            case .safariBootstrap:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariBootstrapRequest.self,
                    request: request,
                    decoder: decoder
                )
                let safariIdentity: (
                    clientID: BurnBarClientID,
                    sessionID: BurnBarSessionID
                )?
                if let sessionID = params.sessionId {
                    safariIdentity = try await requireAttachedSafariSession(
                        sessionID
                    )
                } else {
                    safariIdentity = nil
                }
                return safariRPCSuccess(
                    id: request.id,
                    result: await safariBootstrapResponse(
                        safariIdentity: safariIdentity
                    )
                )

            case .safariUISnapshot:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariUISnapshotRequest.self,
                    request: request,
                    decoder: decoder
                )
                return safariRPCSuccess(
                    id: request.id,
                    result: try await safariUISnapshot(params)
                )

            case .safariApprovalRespond:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariApprovalRespondRequest.self,
                    request: request,
                    decoder: decoder
                )
                return safariRPCSuccess(
                    id: request.id,
                    result: try await respondToSafariApproval(params)
                )

            case .safariTrustUpdate:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariTrustUpdateRequest.self,
                    request: request,
                    decoder: decoder
                )
                _ = try await requireAttachedSafariSession(params.safariSessionId)
                let result = try await safariTrustStore.update(params)
                return safariRPCSuccess(id: request.id, result: result)

            case .safariSessionAttach:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariSessionAttachRequest.self,
                    request: request,
                    decoder: decoder
                )
                let previousSessionID = await computerUseService.safariSessionID(
                    forExtensionInstanceID: params.extensionInstanceId
                )
                let result = try await computerUseService.attachSafariSession(params)
                if let previousSessionID, previousSessionID != result.sessionId {
                    cancelSafariRunResumeTasks(for: previousSessionID)
                    _ = try? await clientRegistry.detach(
                        BurnBarClientDetachRequest(
                            clientID: safariClientID(sessionID: previousSessionID),
                            sessionID: BurnBarSessionID(rawValue: previousSessionID)
                        )
                    )
                }
                let (clientResponse, _) = await clientRegistry.attach(
                    BurnBarClientAttachRequest(
                        clientID: safariClientID(sessionID: result.sessionId),
                        sessionID: BurnBarSessionID(rawValue: result.sessionId),
                        clientName: params.clientName,
                        supportedProtocolVersions: [BurnBarProtocolVersion.current]
                    )
                )
                guard clientResponse.negotiatedProtocolVersion
                        == BurnBarProtocolVersion.current else {
                    _ = await computerUseService.detachSafariSession(
                        BurnBarSafariSessionDetachRequest(
                            sessionId: result.sessionId,
                            reason: "daemon_protocol_negotiation_failed"
                        )
                    )
                    throw BurnBarSafariRPCHandlerError.unavailable(
                        "The Safari extension and daemon could not negotiate the daemon protocol."
                    )
                }
                return safariRPCSuccess(id: request.id, result: result)

            case .safariSessionDetach:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariSessionDetachRequest.self,
                    request: request,
                    decoder: decoder
                )
                let identity = try await requireAttachedSafariSession(params.sessionId)
                cancelSafariRunResumeTasks(for: params.sessionId)
                let result = await computerUseService.detachSafariSession(params)
                _ = try await clientRegistry.detach(
                    BurnBarClientDetachRequest(
                        clientID: identity.clientID,
                        sessionID: identity.sessionID
                    )
                )
                return safariRPCSuccess(id: request.id, result: result)

            case .safariSessionStatus:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariSessionStatusRequest.self,
                    request: request,
                    decoder: decoder
                )
                _ = try await requireAttachedSafariSession(params.sessionId)
                let result = try await computerUseService.safariSessionStatus(
                    sessionID: params.sessionId
                )
                return safariRPCSuccess(id: request.id, result: result)

            case .safariCommandPoll:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariCommandPollRequest.self,
                    request: request,
                    decoder: decoder
                )
                _ = try await requireAttachedSafariSession(params.sessionId)
                let result = try await computerUseService.pollSafariCommand(params)
                try await reconcileSafariComputerUseRequirement(
                    safariSessionID: params.sessionId,
                    explicitRunID: nil
                )
                return safariRPCSuccess(id: request.id, result: result)

            case .safariCommandComplete:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariCommandCompletionRequest.self,
                    request: request,
                    decoder: decoder
                )
                _ = try await requireAttachedSafariSession(params.sessionId)
                let result = try await computerUseService.completeSafariCommand(params)
                return safariRPCSuccess(id: request.id, result: result)

            case .safariPageContext, .safariScreenshot,
                 .safariFullPageScreenshot, .safariClick, .safariType,
                 .safariPressKey, .safariScroll, .safariHover, .safariFocus,
                 .safariSelectOption, .safariNavigate, .safariOpenTab,
                 .safariCloseTab, .safariListTabs, .safariWaitFor,
                 .safariRunJavaScript, .safariExtract:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariToolRequest.self,
                    request: request,
                    decoder: decoder
                )
                let result = try await invokeDirectSafariTool(
                    method: method,
                    requestID: request.id,
                    request: params
                )
                return safariRPCSuccess(id: request.id, result: result)

            case .safariAbort:
                let params = try decodeSafariBridgeRPCParams(
                    BurnBarSafariToolRequest.self,
                    request: request,
                    decoder: decoder
                )
                let result = try await abortSafariRun(params)
                return safariRPCSuccess(id: request.id, result: result)

            default:
                preconditionFailure("Unhandled Safari RPC method: \(method.rawValue)")
            }
        } catch {
            return safariRPCErrorResponse(id: request.id, error: error)
        }
    }

    func resolveSafariBridgeRPCRequest(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) throws -> BurnBarResolvedSafariRPCRequest {
        let request = try decoder.decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarJSONValue>.self,
            from: requestData
        )
        guard request.method == method else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "The Safari RPC envelope method does not match the routed method."
            )
        }

        let paramsData: Data
        if case .object(let object) = request.params,
           object[BurnBarSafariBridgeWire.appGroupPayloadMarkerKey] != nil {
            let reference = try BurnBarSafariAppGroupPayloadReference.decodeMarker(
                from: request.params
            )
            guard let safariAppGroupPayloadResolver else {
                throw BurnBarSafariRPCHandlerError.unavailable(
                    "The Safari App Group payload resolver is unavailable."
                )
            }
            paramsData = try safariAppGroupPayloadResolver.resolve(reference)
        } else {
            paramsData = try JSONEncoder().encode(request.params)
        }

        return BurnBarResolvedSafariRPCRequest(
            id: request.id,
            method: request.method,
            paramsData: paramsData
        )
    }

    func decodeSafariBridgeRPCParams<Params: Decodable>(
        _ type: Params.Type,
        request: BurnBarResolvedSafariRPCRequest,
        decoder: JSONDecoder
    ) throws -> Params {
        try decoder.decode(type, from: request.paramsData)
    }

    private func safariUISnapshot(
        _ request: BurnBarSafariUISnapshotRequest
    ) async throws -> BurnBarSafariUISnapshotResponse {
        let safariIdentity: (clientID: BurnBarClientID, sessionID: BurnBarSessionID)?
        if let safariSessionID = request.safariSessionId {
            safariIdentity = try await requireAttachedSafariSession(safariSessionID)
            try await reconcileSafariComputerUseRequirement(
                safariSessionID: safariSessionID,
                explicitRunID: request.runId
            )
        } else {
            guard request.computerUseSessionId == nil, request.runId == nil else {
                throw BurnBarSafariRPCHandlerError.invalidParams(
                    "Safari UI snapshot run/session filters require a Safari session identifier."
                )
            }
            safariIdentity = nil
        }

        let safariStatus: BurnBarSafariSessionStatusResponse?
        if let safariSessionID = request.safariSessionId {
            safariStatus = try await computerUseService.safariSessionStatus(
                sessionID: safariSessionID
            )
        } else {
            safariStatus = nil
        }

        let runSnapshot: BurnBarRunStateSnapshot?
        if let rawRunID = request.runId {
            let runID = try boundedRunID(rawRunID)
            guard let snapshot = await runService.snapshot(for: runID) else {
                throw BurnBarSafariRPCHandlerError.invalidParams(
                    "The requested Safari run is unavailable."
                )
            }
            guard let safariIdentity,
                  snapshot.clientID == safariIdentity.clientID,
                  snapshot.sessionID == safariIdentity.sessionID else {
                throw BurnBarSafariRPCHandlerError.unauthorized(
                    "The requested run is not owned by this Safari extension session."
                )
            }
            runSnapshot = snapshot
        } else {
            runSnapshot = nil
        }

        let mappedComputerUseSessionID: ComputerUseSessionID?
        if let safariSessionID = request.safariSessionId {
            mappedComputerUseSessionID = await computerUseService
                .computerUseSessionID(forSafariSessionID: safariSessionID)
        } else {
            mappedComputerUseSessionID = nil
        }
        if let requestedComputerUseSessionID = request.computerUseSessionId {
            let requested = try boundedComputerUseSessionID(
                requestedComputerUseSessionID
            )
            guard requested == mappedComputerUseSessionID else {
                throw BurnBarSafariRPCHandlerError.unauthorized(
                    "The requested Computer Use session is not bound to this Safari session."
                )
            }
        }
        let approvals = await computerUseService.pendingApprovals(
            ComputerUseApprovalPendingRequest(
                sessionId: mappedComputerUseSessionID?.rawValue
            )
        )
        let membership = await membershipService.status()

        return BurnBarSafariUISnapshotResponse(
            bootstrap: await safariBootstrapResponse(
                membership: membership,
                safariIdentity: safariIdentity
            ),
            catalog: BurnBarCatalogResponse(catalog: configuration.catalog),
            membership: membership,
            safariSession: safariStatus,
            run: runSnapshot,
            approvals: approvals
        )
    }

    private struct SafariApprovalBinding {
        let identity: (clientID: BurnBarClientID, sessionID: BurnBarSessionID)
        let computerUseSessionID: ComputerUseSessionID
        let runID: BurnBarRunID
    }

    private func respondToSafariApproval(
        _ request: BurnBarSafariApprovalRespondRequest
    ) async throws -> BurnBarSafariApprovalRespondResponse {
        let approvalID = request.approvalId
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard approvalID == request.approvalId,
              approvalID.isEmpty == false,
              approvalID.utf8.count <= 128 else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Safari approval identifiers must be non-empty and at most 128 bytes."
            )
        }

        let binding = try await requireLiveSafariApprovalBinding(
            safariSessionID: request.safariSessionId
        )
        let pending = await computerUseService.pendingApprovals(
            ComputerUseApprovalPendingRequest(
                sessionId: binding.computerUseSessionID.rawValue
            )
        )
        guard pending.sessionActive == true,
              let approval = pending.requests.first(where: {
                  $0.approvalId == approvalID
              }),
              pending.requests.filter({ $0.approvalId == approvalID }).count == 1,
              approval.sessionId == binding.computerUseSessionID.rawValue,
              approval.runId == binding.runID.rawValue,
              BurnBarToolKind(rawValue: approval.toolKind)?.isSafariComputerUse
                == true else {
            throw BurnBarSafariRPCHandlerError.conflict(
                "The Safari approval is stale, already resolved, or belongs to another live session."
            )
        }

        // Revalidate after polling crossed the ComputerUseService actor. A
        // concurrent abort, detach, run replacement, or authorization expiry
        // must win before the response consumes the pending approval.
        let currentBinding = try await requireLiveSafariApprovalBinding(
            safariSessionID: request.safariSessionId
        )
        guard currentBinding.computerUseSessionID
                == binding.computerUseSessionID,
              currentBinding.runID == binding.runID,
              currentBinding.identity.clientID == binding.identity.clientID,
              currentBinding.identity.sessionID == binding.identity.sessionID else {
            throw BurnBarSafariRPCHandlerError.conflict(
                "The Safari approval binding changed before the decision could be applied."
            )
        }

        let decision: HermesRealtimeRelayApprovalResponse.Decision
        let note: String
        switch request.decision {
        case .allowOnce:
            decision = .approve
            note = "Safari extension approved this action once."
        case .allowSession:
            decision = .approve
            note = "Step-mode burst approved by the Safari extension."
        case .block:
            decision = .reject
            note = "Safari extension blocked this action."
        }
        let result = await computerUseService.respondToApproval(
            ComputerUseApprovalRespondRequest(
                sessionId: currentBinding.computerUseSessionID.rawValue,
                response: HermesRealtimeRelayApprovalResponse(
                    approvalId: approvalID,
                    decision: decision,
                    respondedBy: "safari_extension",
                    respondedAt: Date(),
                    note: note
                )
            )
        )
        guard result.accepted else {
            throw BurnBarSafariRPCHandlerError.conflict(
                "The Safari approval was already resolved or cancelled."
            )
        }
        return BurnBarSafariApprovalRespondResponse(
            accepted: true,
            approvalId: approvalID,
            runId: currentBinding.runID.rawValue
        )
    }

    private func requireLiveSafariApprovalBinding(
        safariSessionID: String
    ) async throws -> SafariApprovalBinding {
        let identity = try await requireAttachedSafariSession(safariSessionID)
        guard let computerUseSessionID = await computerUseService
            .computerUseSessionID(forSafariSessionID: safariSessionID),
              let manifest = await computerUseService.computerUseManifest(
                  sessionID: computerUseSessionID
              ),
              manifest.mode == .browser,
              manifest.executionSurface == .safariExtension,
              manifest.executionSurfaceSessionId == safariSessionID,
              manifest.userId == identity.clientID.rawValue,
              let rawRunID = manifest.runId else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "This Safari session has no live Computer Use approval binding."
            )
        }
        let runID = try boundedRunID(rawRunID)
        guard let authorization = await computerUseAuthorizationRegistry.binding(
            sessionID: computerUseSessionID
        ),
              authorization.runID == runID,
              authorization.clientID == identity.clientID,
              authorization.expiresAt.map({ $0 > Date() }) ?? true,
              let run = await runService.snapshot(for: runID),
              run.clientID == identity.clientID,
              run.sessionID == identity.sessionID,
              ![BurnBarRunPhase.completed, .failed, .cancelled]
                .contains(run.phase) else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "The Safari approval is not bound to the exact live run and Computer Use session."
            )
        }
        return SafariApprovalBinding(
            identity: identity,
            computerUseSessionID: computerUseSessionID,
            runID: runID
        )
    }

    private static func validSafariHandoffURL(_ raw: String) -> Bool {
        guard raw.utf8.count <= 16 * 1024,
              let components = URLComponents(string: raw),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }

    private func safariBootstrapResponse(
        membership: BurnBarMembershipStatusResponse? = nil,
        safariIdentity: (
            clientID: BurnBarClientID,
            sessionID: BurnBarSessionID
        )? = nil
    ) async -> BurnBarSafariBootstrapResponse {
        let resolvedMembership: BurnBarMembershipStatusResponse
        if let membership {
            resolvedMembership = membership
        } else {
            resolvedMembership = await membershipService.status()
        }
        let trustKillSwitchEnabled = (try? await safariTrustStore.killSwitchEnabled())
            ?? true
        let gatewayToken = configuration.gateway.authToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayAvailable = configuration.gateway.isEnabled
            && configuration.gateway.validationError == nil
            && configuration.gateway.isLoopback
            && gatewayToken?.isEmpty == false
        #if os(macOS)
        let computerUseAvailable = !trustKillSwitchEnabled
        #else
        let computerUseAvailable = false
        #endif

        return BurnBarSafariBootstrapResponse(
            daemonVersion: configuration.daemonVersion,
            protocolVersion: BurnBarSafariProtocol.currentVersion,
            gatewayBaseURL: gatewayAvailable ? safariGatewayBaseURL() : nil,
            gatewayBearerToken: gatewayAvailable ? gatewayToken : nil,
            gatewayAvailable: gatewayAvailable,
            computerUseAvailable: computerUseAvailable,
            learningAvailable: false,
            learningOptedIn: false,
            tier: resolvedMembership.membership.tier
        )
    }

    private func safariGatewayBaseURL() -> String? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = configuration.gateway.host
        components.port = configuration.gateway.port
        return components.url?.absoluteString
    }

    private static func safariWireTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func requireAttachedSafariSession(
        _ rawSessionID: String
    ) async throws -> (clientID: BurnBarClientID, sessionID: BurnBarSessionID) {
        let sessionID = try boundedSafariSessionID(rawSessionID)
        let clientID = safariClientID(sessionID: sessionID)
        let daemonSessionID = BurnBarSessionID(rawValue: sessionID)
        guard await clientRegistry.sessionID(for: clientID) == daemonSessionID else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "The Safari extension session is detached or has been replaced."
            )
        }
        let status = try await computerUseService.safariSessionStatus(
            sessionID: sessionID
        )
        guard status.attached else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "The Safari extension session lease is no longer active."
            )
        }
        return (clientID, daemonSessionID)
    }

    private func reconcileSafariComputerUseRequirement(
        safariSessionID rawSafariSessionID: String,
        explicitRunID rawRunID: String?
    ) async throws {
        #if !os(macOS)
        throw BurnBarSafariRPCHandlerError.unavailable(
            "Safari Computer Use is available only on macOS."
        )
        #else
        let identity = try await requireAttachedSafariSession(rawSafariSessionID)
        let requirement: BurnBarComputerUseRunRequirement?
        if let rawRunID {
            let runID = try boundedRunID(rawRunID)
            requirement = await runService.computerUseRequirement(for: runID)
        } else {
            let summaries = await runService.listComputerUseRequirements()
                .filter {
                    $0.clientID == identity.clientID
                        && $0.toolKind.isSafariComputerUse
                }
            guard summaries.count <= 1 else {
                throw BurnBarSafariRPCHandlerError.conflict(
                    "More than one Safari run is waiting for Computer Use; refresh the active run before continuing."
                )
            }
            if let summary = summaries.first {
                requirement = await runService.computerUseRequirement(
                    for: summary.runID
                )
            } else {
                requirement = nil
            }
        }
        guard let requirement else { return }
        guard requirement.clientID == identity.clientID,
              requirement.sessionID == identity.sessionID,
              requirement.invocation.runID == requirement.runID,
              requirement.invocation.requestedBy == identity.clientID,
              requirement.invocation.tool.isSafariComputerUse,
              safariSessionID(from: requirement.invocation)
                == rawSafariSessionID else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "The pending Computer Use requirement does not belong to this Safari session."
            )
        }
        guard await clientRegistry.sessionID(for: requirement.clientID)
                == requirement.sessionID else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "The Safari run client attachment changed before Computer Use could start."
            )
        }

        let activePage = try await computerUseService.safariActivePage(
            sessionID: rawSafariSessionID
        )
        let policy = try await safariTrustStore.policy(for: activePage.url)
        let sessionTimeoutSeconds = 30 * 60
        let now = Date()
        let policyExpiry = policy.scopeRules.compactMap(\.expiresAt).min()
            ?? now.addingTimeInterval(TimeInterval(sessionTimeoutSeconds))

        let computerUseSessionID: ComputerUseSessionID
        if let existing = await computerUseService.computerUseSessionID(
            forSafariSessionID: rawSafariSessionID
        ) {
            guard await computerUseService.safariRunBindingSessionID(requirement)
                    == existing else {
                throw BurnBarSafariRPCHandlerError.conflict(
                    "This Safari tab is already bound to a different Computer Use run."
                )
            }
            computerUseSessionID = existing
        } else {
            let started = try await computerUseService.startSession(
                ComputerUseSessionStartRequest(
                    mode: ComputerUseMode.browser.rawValue,
                    trustMode: policy.trustMode.rawValue,
                    scopeRuleIds: policy.scopeRules.map(\.id.rawValue),
                    actionCap: policy.actionCap,
                    sessionTimeoutSeconds: sessionTimeoutSeconds,
                    clientID: requirement.clientID,
                    runID: requirement.runID,
                    runCallID: requirement.invocation.callID,
                    runGeneration: requirement.generation,
                    executionSurface: .safariExtension,
                    executionSurfaceSessionId: rawSafariSessionID
                ),
                boundClientID: requirement.clientID,
                runGeneration: requirement.generation,
                scopeRules: policy.scopeRules
            )
            computerUseSessionID = ComputerUseSessionID(started.sessionId)
            await computerUseAuthorizationRegistry.authorize(
                sessionID: computerUseSessionID,
                runID: requirement.runID,
                clientID: requirement.clientID,
                requestedTimeoutSeconds: sessionTimeoutSeconds,
                maximumLifetime: TimeInterval(sessionTimeoutSeconds),
                absoluteExpiry: policyExpiry,
                now: now
            )
            await computerUseService.constrainSessionExpiry(
                sessionID: computerUseSessionID,
                expiresAt: policyExpiry,
                now: now
            )
            guard await computerUseService.safariRunBindingSessionID(requirement)
                    == computerUseSessionID else {
                await computerUseService.revokeSafariRun(requirement)
                throw BurnBarSafariRPCHandlerError.unauthorized(
                    "Safari Computer Use authorization did not bind to the exact pending run."
                )
            }
        }

        scheduleSafariRunResume(requirement)
        #endif
    }

    private func scheduleSafariRunResume(
        _ requirement: BurnBarComputerUseRunRequirement
    ) {
        let key = safariRunResumeTaskKey(requirement)
        guard safariRunResumeTasks[key] == nil else { return }
        let runService = self.runService
        let computerUseService = self.computerUseService
        safariRunResumeTasks[key] = Task { [weak self] in
            do {
                let resumed = try await runService.resumeComputerUseRun(
                    requirement.runID,
                    expectedCallID: requirement.invocation.callID,
                    expectedGeneration: requirement.generation
                )
                if resumed == false {
                    await computerUseService.revokeSafariRun(requirement)
                }
            } catch {
                await computerUseService.revokeSafariRun(requirement)
            }
            await self?.finishSafariRunResumeTask(key: key)
        }
    }

    private func finishSafariRunResumeTask(key: String) {
        safariRunResumeTasks.removeValue(forKey: key)
    }

    func cancelAllSafariRunResumeTasks() {
        let tasks = safariRunResumeTasks.values
        safariRunResumeTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func cancelSafariRunResumeTasks(for safariSessionID: String) {
        let prefix = "\(safariSessionID)\u{1F}"
        let keys = safariRunResumeTasks.keys.filter { $0.hasPrefix(prefix) }
        for key in keys {
            safariRunResumeTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func safariRunResumeTaskKey(
        _ requirement: BurnBarComputerUseRunRequirement
    ) -> String {
        [
            requirement.sessionID.rawValue,
            requirement.runID.rawValue,
            requirement.invocation.callID,
            String(requirement.generation)
        ].joined(separator: "\u{1F}")
    }

    private func invokeDirectSafariTool(
        method: BurnBarRPCMethod,
        requestID: String,
        request: BurnBarSafariToolRequest
    ) async throws -> BurnBarSafariToolResponse {
        let identity = try await requireAttachedSafariSession(
            request.safariSessionId
        )
        guard let rawRunID = request.runId,
              let rawComputerUseSessionID = request.computerUseSessionId else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Direct Safari tools require exact runId and computerUseSessionId bindings."
            )
        }
        let runID = try boundedRunID(rawRunID)
        let computerUseSessionID = try boundedComputerUseSessionID(
            rawComputerUseSessionID
        )
        let mappedComputerUseSessionID = await computerUseService
            .computerUseSessionID(forSafariSessionID: request.safariSessionId)
        let manifest = await computerUseService.computerUseManifest(
            sessionID: computerUseSessionID
        )
        guard mappedComputerUseSessionID == computerUseSessionID,
              let manifest,
              manifest.mode == .browser,
              manifest.executionSurface == .safariExtension,
              manifest.executionSurfaceSessionId == request.safariSessionId,
              manifest.runId == runID.rawValue,
              manifest.userId == identity.clientID.rawValue,
              let authorization = await computerUseAuthorizationRegistry.binding(
                sessionID: computerUseSessionID
              ),
              authorization.runID == runID,
              authorization.clientID == identity.clientID,
              authorization.expiresAt.map({ $0 > Date() }) ?? true,
              let run = await runService.snapshot(for: runID),
              run.clientID == identity.clientID,
              run.sessionID == identity.sessionID,
              ![BurnBarRunPhase.completed, .failed, .cancelled].contains(run.phase) else {
            throw BurnBarSafariRPCHandlerError.unauthorized(
                "The direct Safari tool request is not bound to the exact live run and Computer Use session."
            )
        }

        let tool = try safariToolKind(for: method)
        let arguments = try mergedSafariToolArguments(request)
        let invocation = BurnBarToolInvocation(
            callID: try safariRPCCallID(requestID),
            runID: runID,
            tool: tool,
            arguments: arguments,
            requestedBy: identity.clientID,
            requestedAt: Date()
        )
        let response = try await computerUseService.invokeForRun(invocation)
        let pageState = try await computerUseService.safariActivePage(
            sessionID: request.safariSessionId
        )
        let succeeded = response.status == .executed
            && response.result?.succeeded == true
        let error: String?
        if succeeded {
            error = nil
        } else {
            switch response.status {
            case .awaitingApproval:
                error = "Safari action is awaiting approval."
            case .denied:
                error = response.denyReason ?? "Safari action was denied."
            case .error:
                error = response.result?.errorMessage
                    ?? response.denyReason
                    ?? "Safari action failed."
            case .executed:
                error = response.result?.errorMessage
                    ?? "Safari action returned an unsuccessful result."
            }
        }
        return BurnBarSafariToolResponse(
            ok: succeeded,
            result: response.result?.output,
            error: error,
            pageState: pageState,
            auditEntryIndex: response.auditEntryIndex,
            auditHeadHashHex: response.auditHeadHashHex
        )
    }

    private func abortSafariRun(
        _ request: BurnBarSafariToolRequest
    ) async throws -> BurnBarSafariToolResponse {
        let identity = try await requireAttachedSafariSession(
            request.safariSessionId
        )
        let pageState = try await computerUseService.safariActivePage(
            sessionID: request.safariSessionId
        )
        let mappedComputerUseSessionID = await computerUseService.computerUseSessionID(
            forSafariSessionID: request.safariSessionId
        )
        let expectedComputerUseSessionID: ComputerUseSessionID?
        if let raw = request.computerUseSessionId {
            expectedComputerUseSessionID = try boundedComputerUseSessionID(raw)
            guard expectedComputerUseSessionID == mappedComputerUseSessionID else {
                throw BurnBarSafariRPCHandlerError.unauthorized(
                    "The abort request names a stale Computer Use session."
                )
            }
        } else {
            expectedComputerUseSessionID = mappedComputerUseSessionID
        }

        let manifestRunID: String?
        if let mappedComputerUseSessionID {
            manifestRunID = await computerUseService.computerUseManifest(
                sessionID: mappedComputerUseSessionID
            )?.runId
        } else {
            manifestRunID = nil
        }
        let runID: BurnBarRunID?
        if let rawRunID = request.runId {
            runID = try boundedRunID(rawRunID)
            if let manifestRunID, manifestRunID != runID?.rawValue {
                throw BurnBarSafariRPCHandlerError.unauthorized(
                    "The abort request names a run that is not bound to this Safari session."
                )
            }
        } else if let manifestRunID {
            runID = BurnBarRunID(rawValue: manifestRunID)
        } else {
            runID = nil
        }

        cancelSafariRunResumeTasks(for: request.safariSessionId)
        let halted = await computerUseService.haltSafariComputerUseSession(
            safariSessionID: request.safariSessionId,
            expectedComputerUseSessionID: expectedComputerUseSessionID,
            expectedRunID: runID,
            source: .revoked
        )
        var cancelled = false
        if let runID {
            cancelled = try await runService.cancelSafariRun(
                runID,
                clientID: identity.clientID,
                sessionID: identity.sessionID,
                reason: "Stopped by the Safari extension."
            )
        }
        guard halted || cancelled || (runID == nil && mappedComputerUseSessionID == nil) else {
            throw BurnBarSafariRPCHandlerError.conflict(
                "The Safari run changed before the stop request could be applied."
            )
        }
        return BurnBarSafariToolResponse(
            ok: true,
            result: .object([
                "haltedComputerUse": .bool(halted),
                "cancelledRun": .bool(cancelled)
            ]),
            pageState: pageState
        )
    }

    private func mergedSafariToolArguments(
        _ request: BurnBarSafariToolRequest
    ) throws -> BurnBarJSONValue {
        guard case .object(var arguments) = request.arguments else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Safari tool arguments must be a JSON object."
            )
        }
        try mergeReservedSafariArgument(
            "safariSessionId",
            value: .string(request.safariSessionId),
            into: &arguments
        )
        if let computerUseSessionId = request.computerUseSessionId {
            try mergeReservedSafariArgument(
                "computerUseSessionId",
                value: .string(computerUseSessionId),
                into: &arguments
            )
        }
        if let runId = request.runId {
            try mergeReservedSafariArgument(
                "runId",
                value: .string(runId),
                into: &arguments
            )
        }
        if let tabId = request.tabId {
            try mergeReservedSafariArgument(
                "tabId",
                value: .number(Double(tabId)),
                into: &arguments
            )
        }
        if let expectedNavigationEpoch = request.expectedNavigationEpoch {
            try mergeReservedSafariArgument(
                "expectedNavigationEpoch",
                value: .number(Double(expectedNavigationEpoch)),
                into: &arguments
            )
        }
        try mergeReservedSafariArgument(
            "timeoutMillis",
            value: .number(Double(request.timeoutMillis)),
            into: &arguments
        )
        return .object(arguments)
    }

    private func mergeReservedSafariArgument(
        _ key: String,
        value: BurnBarJSONValue,
        into arguments: inout [String: BurnBarJSONValue]
    ) throws {
        if let existing = arguments[key], existing != value {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Safari tool argument '\(key)' conflicts with its authenticated envelope value."
            )
        }
        arguments[key] = value
    }

    private func safariToolKind(
        for method: BurnBarRPCMethod
    ) throws -> BurnBarToolKind {
        switch method {
        case .safariPageContext: .safariPageContext
        case .safariScreenshot: .safariScreenshot
        case .safariFullPageScreenshot: .safariFullPageScreenshot
        case .safariClick: .safariClick
        case .safariType: .safariType
        case .safariPressKey: .safariPressKey
        case .safariScroll: .safariScroll
        case .safariHover: .safariHover
        case .safariFocus: .safariFocus
        case .safariSelectOption: .safariSelectOption
        case .safariNavigate: .safariNavigate
        case .safariOpenTab: .safariOpenTab
        case .safariCloseTab: .safariCloseTab
        case .safariListTabs: .safariListTabs
        case .safariWaitFor: .safariWaitFor
        case .safariRunJavaScript: .safariRunJavaScript
        case .safariExtract: .safariExtract
        default:
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "The routed Safari method is not a direct tool."
            )
        }
    }

    private func safariClientID(sessionID: String) -> BurnBarClientID {
        BurnBarClientID(rawValue: "safari-extension:\(sessionID)")
    }

    private func safariSessionID(
        from invocation: BurnBarToolInvocation
    ) -> String? {
        guard case .object(let arguments) = invocation.arguments,
              case .string(let sessionID)? = arguments["safariSessionId"] else {
            return nil
        }
        return sessionID
    }

    private func boundedSafariSessionID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw,
              !trimmed.isEmpty,
              trimmed.utf8.count <= 256 else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Safari session identifiers must be non-empty, exact, and at most 256 bytes."
            )
        }
        return trimmed
    }

    private func boundedRunID(_ raw: String) throws -> BurnBarRunID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw,
              !trimmed.isEmpty,
              trimmed.utf8.count <= 256 else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Safari run identifiers must be non-empty, exact, and at most 256 bytes."
            )
        }
        return BurnBarRunID(rawValue: trimmed)
    }

    private func boundedComputerUseSessionID(
        _ raw: String
    ) throws -> ComputerUseSessionID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw,
              !trimmed.isEmpty,
              trimmed.utf8.count <= 256 else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Computer Use session identifiers must be non-empty, exact, and at most 256 bytes."
            )
        }
        return ComputerUseSessionID(trimmed)
    }

    private func safariRPCCallID(_ requestID: String) throws -> String {
        let trimmed = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let callID = "safari-rpc:\(trimmed)"
        guard trimmed == requestID,
              !trimmed.isEmpty,
              callID.utf8.count <= 256 else {
            throw BurnBarSafariRPCHandlerError.invalidParams(
                "Safari RPC request identifiers must be non-empty and at most 245 bytes."
            )
        }
        return callID
    }

    private func safariRPCSuccess<Result: Codable & Sendable>(
        id: String,
        result: Result
    ) -> Data {
        encode(
            BurnBarRPCResponseEnvelope(
                id: id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: result
            )
        )
    }

    func safariRPCErrorResponse(id: String, error: Error) -> Data {
        let code: Int
        switch error {
        case is DecodingError:
            code = BurnBarRPCErrorCode.invalidParams
        case let handler as BurnBarSafariRPCHandlerError:
            switch handler {
            case .invalidParams:
                code = BurnBarRPCErrorCode.invalidParams
            case .unauthorized:
                code = BurnBarRPCErrorCode.unauthorized
            case .conflict:
                code = BurnBarRPCErrorCode.conflict
            case .unavailable:
                code = BurnBarRPCErrorCode.unavailable
            }
        case let broker as BurnBarSafariSessionBroker.BrokerError:
            switch broker {
            case .queueFull, .commandAlreadyInFlight, .commandMismatch:
                code = BurnBarRPCErrorCode.conflict
            case .unknownSession, .leaseExpired, .commandExpired,
                 .commandCancelled, .commandNotFound:
                code = BurnBarRPCErrorCode.unavailable
            case .inactiveTargetTab, .unownedTargetTab:
                code = BurnBarRPCErrorCode.unauthorized
            case .incompatibleProtocol, .invalidAttachRequest,
                 .staleNavigationEpoch, .payloadTooLarge, .invalidPageState,
                 .invalidOpenTabResult:
                code = BurnBarRPCErrorCode.invalidParams
            }
        case let service as ComputerUseService.ServiceError:
            switch service {
            case .runAlreadyBound:
                code = BurnBarRPCErrorCode.conflict
            case .safariSessionUnavailable, .authorizationExpired,
                 .runNotBound, .capabilityStateUnavailable:
                code = BurnBarRPCErrorCode.unavailable
            case .clientIdentityMismatch, .runIdentityMismatch,
                 .safariSessionMismatch, .capabilityDenied:
                code = BurnBarRPCErrorCode.unauthorized
            default:
                code = BurnBarRPCErrorCode.invalidParams
            }
        case let trust as BurnBarSafariTrustStore.StoreError:
            switch trust {
            case .killSwitchEnabled, .deniedOrigin:
                code = BurnBarRPCErrorCode.unauthorized
            case .malformedStore:
                code = BurnBarRPCErrorCode.internalError
            default:
                code = BurnBarRPCErrorCode.invalidParams
            }
        case is BurnBarClientRegistryError:
            code = BurnBarRPCErrorCode.unauthorized
        case is BurnBarSafariAppGroupPayloadError,
             is BurnBarSafariBridgeFailure:
            code = BurnBarRPCErrorCode.invalidParams
        case let runError as BurnBarRunServiceError:
            switch runError {
            case .runNotFound:
                code = BurnBarRPCErrorCode.invalidParams
            case .approvalAlreadyResolved:
                code = BurnBarRPCErrorCode.conflict
            default:
                code = BurnBarRPCErrorCode.unavailable
            }
        default:
            code = BurnBarRPCErrorCode.internalError
        }
        logger.warning(
            "safari_rpc_rejected",
            metadata: [
                "request_id": id,
                "error": String(describing: error)
            ]
        )
        return encodeErrorResponse(
            id: id,
            code: code,
            message: error.localizedDescription
        )
    }
}

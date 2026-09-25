import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension BurnBarDaemonServer {
    public func healthResponse() -> BurnBarHealthResponse {
        BurnBarHealthResponse(
            ok: true,
            daemonVersion: configuration.daemonVersion,
            protocolVersion: BurnBarProtocolVersion.current,
            socketPath: configuration.socketPath,
            gatewayEnabled: configuration.gateway.isEnabled,
            gatewayHost: configuration.gateway.isEnabled ? configuration.gateway.host : nil,
            gatewayPort: configuration.gateway.isEnabled ? configuration.gateway.port : nil
        )
    }

    private func responseData(for requestData: Data) async -> Data {
        await responseData(for: requestData, peerPID: nil)
    }

    private func responseData(
        for requestData: Data,
        peerPID: pid_t?,
        peerCapabilityProfile: BurnBarPeerCapabilityProfile? = nil
    ) async -> Data {
        let rpcStartedAt = ContinuousClock.now
        defer {
            let elapsed = rpcStartedAt.duration(to: ContinuousClock.now)
            let milliseconds = Int(elapsed.components.seconds * 1000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            BurnBarDaemonMetricsCounters.recordRPCLatency(milliseconds: milliseconds)
        }
        do {
            let decoder = JSONDecoder()
            let incomingRequest = try decoder.decode(IncomingRequestEnvelope.self, from: requestData)
            BurnBarDaemonMetricsCounters.recordRPCRequest()

            if let requiredToken = configuration.socketAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                let providedToken = incomingRequest.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                guard let providedToken, constantTimeTokensEqual(providedToken, requiredToken) else {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_request_unauthorized",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": peerPID.map(String.init) ?? "unknown"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.unauthorized,
                        message: "Unauthorized OpenBurnBar RPC request."
                    )
                }
            }

            guard let method = BurnBarRPCMethod(rawValue: incomingRequest.method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
                logger.error(
                    "rpc_method_not_found",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method
                    ]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Unsupported OpenBurnBar RPC method '\(incomingRequest.method)'."
                )
            }

            // T-DMN-01: per-operation capability attenuation. Refuse — fail closed
            // — any method whose capability group is outside this peer's scoped
            // profile, BEFORE the rate limiter or any handler runs. This bounds
            // what an authenticated-but-compromised first-party peer may do.
            let effectiveCapabilityProfile = peerCapabilityProfile
                .map { capabilityProfile.attenuated(to: $0) }
                ?? capabilityProfile
            guard effectiveCapabilityProfile.permits(method) else {
                BurnBarDaemonMetricsCounters.recordRPCError()
                logger.warning(
                    "rpc_request_capability_denied",
                    metadata: [
                        "request_id": incomingRequest.id,
                        "method": incomingRequest.method,
                        "capability": BurnBarRPCCapability.capability(for: method).rawValue,
                        "peer_pid": peerPID.map(String.init) ?? "unknown"
                    ]
                )
                return encodeErrorResponse(
                    id: incomingRequest.id,
                    code: BurnBarRPCErrorCode.unauthorized,
                    message: "OpenBurnBar RPC method '\(incomingRequest.method)' is outside this peer's capability scope."
                )
            }

            // Rate limiting check (per peer PID)
            if let rateLimiter {
                let clientKey = peerPID.map(String.init) ?? "unknown"
                let limitResult = await rateLimiter.checkLimit(clientKey: clientKey)
                if case .throttled(let retryAfter) = limitResult {
                    BurnBarDaemonMetricsCounters.recordRPCError()
                    logger.warning(
                        "rpc_rate_limit_exceeded",
                        metadata: [
                            "request_id": incomingRequest.id,
                            "method": incomingRequest.method,
                            "peer_pid": clientKey,
                            "retry_after": "\(retryAfter)"
                        ]
                    )
                    return encodeErrorResponse(
                        id: incomingRequest.id,
                        code: BurnBarRPCErrorCode.rateLimitExceeded,
                        message: "Rate limit exceeded. Retry after \(String(format: "%.1f", retryAfter)) seconds."
                    )
                }
            }

            let request = BurnBarRPCRequestEnvelope(id: incomingRequest.id, method: method, authToken: incomingRequest.authToken)

            switch method {
            case .linuxAuthStatus, .linuxAuthBegin, .linuxAuthCancel,
                 .linuxAuthRotateIdentity, .linuxAuthSignOut,
                 .linuxAccountCloudDataExport,
                 .linuxAccountCloudDataDelete, .linuxTrustedDeviceList,
                 .linuxTrustedDeviceApprove, .linuxTrustedDeviceRevoke,
                 .linuxCloudSyncStatus,
                 .linuxCloudSyncPolicyUpdate, .linuxCloudSyncRun:
                return try await handleLinuxAuthRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .health, .catalog, .authBootstrap, .linuxOnboardingSnapshot:
                return try await handleLifecycleRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .configGet, .configUpdate, .linuxOnboardingAction, .linuxOnboardingReset,
                 .textExpansionGet, .textExpansionUpsert, .textExpansionDelete, .textExpansionConsentUpdate,
                 .textExpansionEngineStatus, .textExpansionEngineStart, .textExpansionEngineStop,
                 .textExpansionEngineExpand,
                 .providerCredentialSlotUpsert, .providerCredentialSlotRemove,
                 .providerModelVariantUpsert, .providerModelVariantRemove,
                 .providerModelAliasUpsert, .providerModelAliasRemove,
                 .providerCustomModelUpsert, .providerCustomModelRemove,
                 .providerModelDisplayNameSet, .providerModelDisplayNameClear:
                return try await handleConfigRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
#if os(Linux)
            case .linuxPrivacyInventory, .linuxPrivacyDeletionPreview,
                 .linuxPrivacyDeletionExecute, .linuxPrivacyExport,
                 .linuxPrivacyRetentionStatus, .linuxPrivacyRetentionApply:
                return try await handleLinuxPrivacyRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
#else
            case .linuxPrivacyInventory, .linuxPrivacyDeletionPreview,
                 .linuxPrivacyDeletionExecute, .linuxPrivacyExport,
                 .linuxPrivacyRetentionStatus, .linuxPrivacyRetentionApply:
                return encodeErrorResponse(
                    id: request.id,
                    code: BurnBarRPCErrorCode.methodNotFound,
                    message: "Linux privacy RPCs are unavailable on macOS."
                )
#endif
            case .usageRecord, .usageRecent, .usageProjection, .usageRecount,
                 .usageHistory, .usageInsights:
                return try await handleUsageRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .chatThreadCreate, .chatThreadList, .chatThreadGet, .chatMessageAppend:
                return try await handleChatRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .inboxList, .inboxGet, .inboxRunsRecent,
                 .inboxConfigGet, .inboxConfigUpdate, .inboxRunNow,
                 .inboxThreadGet, .inboxReply,
                 .inboxPlansList, .inboxPlansGet, .inboxPlansAccept,
                 .inboxPlansUpdateStep, .inboxPlansGrade, .inboxMemoryExport:
                return try await handleInboxRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .proxyRouteLogRecent, .proxyRouteLogClear,
                 .quotaSignalsRecent, .quotaSignalsClear,
                 .perfMeasure:
                return try await handleObservabilityRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .membershipStatus, .membershipCheckoutURL, .membershipPortalURL, .membershipRestore:
                return try await handleMembershipRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .connectorPlaneGet, .connectorConfigUpdate, .connectorAction,
                 .browserToolingGet, .browserToolingUpdate, .browserAction:
                return try await handleToolingRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .computerUseCapabilityStateUpdate,
                 .computerUseSessionGrantReadiness, .computerUseSessionGrantAcquire,
                 .computerUseSessionGrantStatus,
                 .computerUseSessionStart, .computerUseInvoke,
                 .computerUseApprovalPending, .computerUseApprovalRespond,
                 .computerUsePanicHalt, .computerUseAuditExport,
                 .phoneControlPinProvision:
                return try await handleComputerUseRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData,
                    peerPID: peerPID
                )
            case .daemonMediaSessionState, .daemonMediaCallAccept,
                 .daemonMediaCallDecline, .daemonMediaCallEnd,
                 .daemonMediaCapabilityGet, .daemonMediaStatus,
                 .daemonMediaFileOfferList, .daemonMediaFileAccept,
                 .daemonMediaFileDecline, .daemonMediaFileSend:
                return try await handleMediaRPC(
                    method: method,
                    decoder: decoder,
                    request: request,
                    requestData: requestData
                )
            case .controllerSummary, .controllerRuntimeSnapshot,
                 .controllerProjectsList, .controllerProjectGet,
                 .controllerProjectUpsert, .controllerProjectDelete,
                 .controllerProjectReassign, .reviewRunRecord,
                 .questionCreate, .questionGet, .questionsList, .questionAnswer,
                 .followupCreate, .followupsList, .followupDone, .followupSnooze, .followupCalendar,
                 .missionCreate, .missionsList, .missionGet, .missionHealth, .missionApprove, .missionCancel,
                 .missionDispatchPacket, .missionRecordResult, .missionAuthorizeRemote,
                 .notificationConfigGet, .notificationConfigUpdate, .notificationHealth, .notificationCommand,
                 .simulatorRun, .simulatorList, .simulatorReplay, .projectionRebuild:
                return try await handleMissionControlRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .clientAttach, .clientClaimControl, .clientDetach:
                return try await handleClientRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .runCreate, .runList, .runGet, .runPoll, .runCancel, .runRetry, .runResume,
             .subscriptionStart, .subscriptionResume, .subscriptionStop,
                 .workspaceExecuteTool, .workspaceToolResult, .approvalRespond:
                return try await handleRunWorkspaceApprovalRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .searchQuery, .searchSQL, .searchVectorSnapshotUpsert, .searchIndexApply:
                return try await handleSearchRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .switcherActiveProfileApply:
                return try await handleSwitcherRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .memoryRemember, .memoryRecall, .memoryReviewStatus, .memoryForget, .memoryAuditTrail, .memoryAnalytics, .memoryModelPolicy,
                 .memorySyncInboxList, .memorySyncInboxAck, .memorySnapshotUpsert, .memorySnapshotDelete,
                 .memorySnapshotDeleteAll, .memoryAuthorityApply:
                return try await handleMemoryRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .codeIndexProject, .codeWatchProject, .codeSearch, .codeContextPack, .codeGetSymbol, .codeFindReferences,
             .codeCallGraph, .codeDiagnostics, .codeIndexStatus, .codeExplore, .codeOpsDiagnostics,
             .codeDatabaseSnapshot, .codeDatabaseRestore:
                return try await handleCodeRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .databaseRecoveryStatus, .databaseRecoveryBundleExport, .databaseRecoveryBundleImport:
                return try await handleDatabaseRecoveryRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .fleetSnapshot, .fleetOrchestratorGet, .fleetOrchestratorSet, .fleetDirectiveRecord:
                return try await handleFleetRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            case .warFlameRoute, .warFlameDistillList, .warFlameDistillSettle:
                return try await handleWarFlameRPC(
                    method: method,
                    decoder: decoder,
                    requestData: requestData
                )
            }
        } catch {
            BurnBarDaemonMetricsCounters.recordRPCError()
            logger.error(
                "rpc_request_failed",
                metadata: ["error": "\(error)"]
            )
            return encodeErrorResponse(
                id: "invalid-request",
                code: error is DecodingError ? BurnBarRPCErrorCode.invalidParams : BurnBarRPCErrorCode.internalError,
                message: error.localizedDescription
            )
        }
    }

    static func runAcceptLoop(
        server: BurnBarDaemonServer,
        listenerFileDescriptor: Int32,
        connectionGate: BurnBarConnectionGate,
        logger: BurnBarDaemonLogger
    ) async {
        while !Task.isCancelled {
            let clientFileDescriptor = accept(listenerFileDescriptor, nil, nil)
            if clientFileDescriptor == -1 {
                let code = errno
                if code == EINTR {
                    continue
                }

                if code == EBADF || code == EINVAL || Task.isCancelled {
                    break
                }

                logger.error(
                    "accept_failed",
                    metadata: ["errno": "\(code)"]
                )
                continue
            }

            // Round-4 perf sweep: back-pressure. If the gate is at capacity,
            // close the connection immediately rather than spawning an
            // unbounded handler. This prevents FD/memory exhaustion under
            // client bursts; the client's retry is cheap over a local socket.
            guard connectionGate.tryAcquire() else {
                close(clientFileDescriptor)
                logger.warning(
                    "connection_limit_reached",
                    metadata: ["max": "\(connectionGate.maxCount)"]
                )
                continue
            }

            Task.detached(priority: .utility) { [logger] in
                await Self.handleClientConnection(
                    server: server,
                    clientFileDescriptor: clientFileDescriptor,
                    connectionGate: connectionGate,
                    logger: logger
                )
            }
        }

        logger.debug("accept_loop_stopped")
    }

    private static func peerPID(for clientFileDescriptor: Int32) -> pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(clientFileDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        return result == 0 ? pid : nil
        #elseif os(Linux)
        var credential = BurnBarLinuxPeerSocketCredentials()
        var credentialSize = socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size)
        let result = withUnsafeMutablePointer(to: &credential) { pointer in
            getsockopt(clientFileDescriptor, SOL_SOCKET, SO_PEERCRED, pointer, &credentialSize)
        }
        guard result == 0,
              credentialSize == socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size) else {
            return nil
        }
        return credential.pid
        #else
        return nil
        #endif
    }

    private static func handleClientConnection(
        server: BurnBarDaemonServer,
        clientFileDescriptor: Int32,
        connectionGate: BurnBarConnectionGate,
        logger: BurnBarDaemonLogger
    ) async {
        defer {
            close(clientFileDescriptor)
            connectionGate.release()
        }

        BurnBarUnixDomainSocket.configureNoSigPipe(for: clientFileDescriptor)
        BurnBarUnixDomainSocket.configureIOTimeouts(for: clientFileDescriptor)

        let peerPID = Self.peerPID(for: clientFileDescriptor)

        // RR-3: authenticate the peer's first-party code signature on the live
        // socket BEFORE reading or honoring any RPC. Fail closed — a mismatched,
        // forged, or swapped peer binary never reaches `responseData`, so the
        // bearer token alone can no longer authorize a non-first-party process.
        let peerAuthenticator = server.peerAuthenticator
        let peerCapabilityProfile: BurnBarPeerCapabilityProfile
        do {
            peerCapabilityProfile = try peerAuthenticator.validatePeer(
                socketFD: clientFileDescriptor,
                peerPID: peerPID
            )
        } catch {
            logger.warning(
                "rpc_peer_rejected",
                metadata: [
                    "error": "\(error)",
                    "peer_pid": peerPID.map(String.init) ?? "unknown"
                ]
            )
            // Fail closed, but do not leave the client staring at Cocoa's
            // empty-body decode string. The envelope is unauthorized; the
            // app can then fall back to fleet-snapshot.json.
            let rejection = await server.encodeErrorResponse(
                id: "peer-rejected",
                code: BurnBarRPCErrorCode.unauthorized,
                message: "OpenBurnBar RPC peer failed first-party code-signature verification."
            ) + Data([0x0A])
            try? BurnBarUnixDomainSocket.writeAll(rejection, to: clientFileDescriptor)
            return
        }

        do {
            let requestData = try BurnBarUnixDomainSocket.readRequest(
                from: clientFileDescriptor,
                maxBytes: maxRequestBytes
            )
            let responseData = await server.responseData(
                for: requestData,
                peerPID: peerPID,
                peerCapabilityProfile: peerCapabilityProfile
            ) + Data([0x0A])
            try BurnBarUnixDomainSocket.writeAll(responseData, to: clientFileDescriptor)
            logger.debug(
                "rpc_response_sent",
                metadata: ["bytes": "\(responseData.count)"]
            )
        } catch {
            logger.error(
                "client_request_failed",
                metadata: ["error": "\(error)"]
            )
        }
    }
}

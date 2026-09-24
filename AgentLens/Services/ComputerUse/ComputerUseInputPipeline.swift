#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarAssistantModels
import OpenBurnBarInsights
import OpenBurnBarKernel
import OpenBurnBarQuota
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

// Input handling, virtual-HID, and E2E approval probe.
// Collaborator type owned by ComputerUseSessionCoordinator (not an extension of it).

@MainActor
@dynamicMemberLookup
final class ComputerUseInputPipeline {
    unowned let session: ComputerUseSessionCoordinator

    init(session: ComputerUseSessionCoordinator) {
        self.session = session
    }

    subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ComputerUseSessionCoordinator, T>) -> T {
        get { session[keyPath: keyPath] }
        set { session[keyPath: keyPath] = newValue }
    }

    subscript<T>(dynamicMember keyPath: KeyPath<ComputerUseSessionCoordinator, T>) -> T {
        session[keyPath: keyPath]
    }

    private struct PreparedControlFrame {
        var frame: HermesRealtimeRelayFrame
        var pendingSealSession: (peerNodeId: String, key: SymmetricKey)?
    }

    private enum ControlSealOpenError: Error {
        case missingSenderPeerNodeId
    }

    func shouldUseVirtualHIDForLockedInput() -> Bool {
        let readiness = MacRemoteUnlockReadinessService.shared
        let snapshot = readiness.snapshot()
        guard snapshot.virtualHIDDriverActive else { return false }
        switch readiness.currentState(sessionId: nil, controlOwnerViewerId: nil).lockState {
        case .unlocked, .unknown:
            return false
        default:
            return true
        }
    }

    func mintVirtualHIDCapabilityDispatch(actionKind: String) async throws -> VirtualHIDCapabilityDispatch {
        let peerNodeId = session.phoneControlAuthorizedPeerNodeProvider?()
        let sessionId = session.activeSessionId?.rawValue ?? session.latestControlConnectionID
        return try await mintRemoteUnlockVirtualHIDCapabilityDispatch(
            actionKind: actionKind,
            sessionId: sessionId,
            peerNodeId: peerNodeId
        )
    }

    /// F10 — control-seal interception, the single chokepoint every control
    /// frame passes before dispatch:
    ///  1. `control.classify` carrying a `controlSealKey` envelope prepares
    ///     the per-connection session (sealKeyV3 open under the Mac relay key,
    ///     sender authenticated against the SAME pinned relay-sender-key source
    ///     the chat opener uses). The prepared session is committed only after
    ///     the normal classify admission checks pass. Establishment failure
    ///     refuses the classify.
    ///  2. Any frame carrying `sealedFrameBase64` is opened (AAD: controller
    ///     peerNodeId + frame type) and the inner payload substituted. A sealed
    ///     frame with no session, or one that fails to open, is dropped with a
    ///     `controlDenied` — never dispatched (fail closed).
    /// Legacy unsealed frames pass through untouched.
    private func unsealedControlFrame(_ frame: HermesRealtimeRelayFrame) async -> PreparedControlFrame? {
        var pendingSealSession: (peerNodeId: String, key: SymmetricKey)?
        if frame.type == .controlClassify,
           let envelope = frame.control?.controlSealKey {
            guard let peerNodeId = frame.control?.authorityPeerNodeId else {
                emitControlSealDenied(detail: "control_seal_missing_peer", frame: frame)
                return nil
            }
            do {
                let key = try await establishControlSealSession(
                    envelope: envelope,
                    uid: frame.uid,
                    connectionId: frame.connectionId,
                    peerNodeId: peerNodeId
                )
                pendingSealSession = (peerNodeId, key)
                session.recordE2EProofEvent([
                    "event": "mac_control_seal_prepared",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId
                ])
            } catch {
                session.recordE2EProofEvent([
                    "event": "mac_control_seal_establish_failed",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId,
                    "error": error.localizedDescription
                ])
                emitControlSealDenied(detail: "control_seal_establish_failed", frame: frame)
                return nil
            }
        }
        guard let control = frame.control, control.sealedFrameBase64 != nil else {
            return PreparedControlFrame(frame: frame, pendingSealSession: pendingSealSession)
        }
        guard let sealSession = pendingSealSession ?? session.controlSealSessions[frame.connectionId] else {
            emitControlSealDenied(detail: "control_seal_no_session", frame: frame)
            return nil
        }
        do {
            let inner = try ControlFrameSealSession.openPayload(
                control,
                key: sealSession.key,
                peerNodeId: sealSession.peerNodeId,
                frameType: frame.type.rawValue
            )
            let unsealed = HermesRealtimeRelayFrame(
                type: frame.type,
                uid: frame.uid,
                connectionId: frame.connectionId,
                requestId: frame.requestId,
                payload: frame.payload,
                media: frame.media,
                control: inner
            )
            return PreparedControlFrame(frame: unsealed, pendingSealSession: pendingSealSession)
        } catch {
            session.recordE2EProofEvent([
                "event": "mac_control_seal_open_failed",
                "connectionId": frame.connectionId,
                "frameType": frame.type.rawValue
            ])
            emitControlSealDenied(detail: "control_seal_open_failed", frame: frame)
            return nil
        }
    }

    func emitControlSealDenied(detail: String, frame: HermesRealtimeRelayFrame) {
        session.emitControlFrame(
            type: .controlDenied,
            payload: HermesRealtimeRelayControlPayload(
                streamClass: frame.control?.streamClass ?? "control.input",
                sessionId: session.activeSessionId?.rawValue,
                denied: HermesRealtimeRelayControlDenied(reason: .signatureFailure, detail: detail)
            )
        )
    }

    func establishControlSealSession(
        envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        uid: String,
        connectionId: String,
        peerNodeId: String
    ) async throws -> SymmetricKey {
        guard let senderPeerNodeId = envelope.senderPeerNodeId else {
            throw ControlSealOpenError.missingSenderPeerNodeId
        }
        let recipientKey = try session.controlSealRecipientPrivateKeyProvider.map { try $0() }
            ?? HermesRelayKeyStore().privateKey()
        // The trust resolver only consults uid + sender identity; the
        // request id/operation exist for the chat lane's AAD and are
        // irrelevant to pinned-key resolution.
        let context = HermesRelayAuthenticatedRequestTrustContext(
            uid: uid,
            connectionID: connectionId,
            requestID: "control-seal-\(envelope.senderCounter)",
            operation: .chatCompletions,
            sender: HermesRelayAuthenticatedSender(
                publicKeyBase64: "",
                deviceID: envelope.senderDeviceId,
                peerNodeID: senderPeerNodeId,
                counter: envelope.senderCounter,
                keyID: envelope.senderKeyId
            )
        )
        let pinnedSenderKey: String
        if let provider = session.controlSealPinnedSenderKeyProvider {
            pinnedSenderKey = try await provider(uid, connectionId, envelope)
        } else {
            pinnedSenderKey = try await FirestoreHermesRelaySenderTrustResolver.shared
                .pinnedRelaySenderPublicKeyBase64(for: context)
        }
        return try ControlFrameSealSession.open(
            envelope: envelope,
            uid: uid,
            connectionID: connectionId,
            peerNodeId: peerNodeId,
            recipientPrivateKey: recipientKey,
            pinnedSenderPublicKeyBase64: pinnedSenderKey
        )
    }

    func handleControlFrame(
        _ rawFrame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        session.latestReplySender = replySender
        session.latestControlUID = rawFrame.uid
        session.latestControlConnectionID = rawFrame.connectionId
        ComputerUseSessionCoordinator.debugTrace("computer_use_control_frame_received type=\(rawFrame.type.rawValue) requestID=\(rawFrame.requestId ?? "") connectionID=\(rawFrame.connectionId)")
        guard let prepared = await unsealedControlFrame(rawFrame) else { return }
        let frame = prepared.frame
        switch frame.type {
        case .controlClassify:
            guard let peerNodeId = frame.control?.authorityPeerNodeId else { return }
            // FAIL-CLOSED reconnect rejection: a revoked peer cannot
            // re-admit itself via a fresh classify, even before the
            // escrow_devices listener has fired.
            if session.phoneValidator.isPeerRevoked(nodeId: peerNodeId) {
                session.recordE2EProofEvent([
                    "event": "mac_control_classify_revoked_peer",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId
                ])
                session.emitControlFrame(
                    type: .controlDenied,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "control.input",
                        sessionId: session.activeSessionId?.rawValue,
                        denied: HermesRealtimeRelayControlDenied(reason: .signatureFailure, detail: "peer_revoked")
                    )
                )
                return
            }
            do {
                let authority = try await session.authorityProvider.fetchAuthorityRegistration(
                    uid: frame.uid,
                    connectionId: frame.connectionId,
                    peerNodeId: peerNodeId
                )
                let registration = await session.registerPhonePeerForControlClassify(
                    nodeId: peerNodeId,
                    publicKey: authority.publicKey,
                    requiredAttestationHashBlake3: authority.requiredAttestationHashBlake3,
                    connectionID: frame.connectionId
                )
                guard registration.admitted else {
                    session.recordE2EProofEvent([
                        "event": "mac_control_classify_refused",
                        "peerNodeId": peerNodeId,
                        "connectionId": frame.connectionId,
                        "detail": registration.denialDetail ?? "controller_registration_refused"
                    ])
                    session.emitControlFrame(
                        type: .controlDenied,
                        payload: HermesRealtimeRelayControlPayload(
                            streamClass: "control.input",
                            sessionId: session.activeSessionId?.rawValue,
                            denied: HermesRealtimeRelayControlDenied(
                                reason: .signatureFailure,
                                detail: registration.denialDetail ?? "controller_registration_refused"
                            )
                        )
                    )
                    return
                }
                if session.activeSessionId == nil {
                    _ = try await session.startSession(request: ComputerUseSessionStartRequest(
                        mode: ComputerUseMode.system.rawValue,
                        trustMode: ComputerUseTrustMode.manual.rawValue,
                        phoneViewerNodeId: peerNodeId,
                        macHostNodeId: session.configuration.macHostNodeId,
                        actionCap: ComputerUseSessionCoordinator.phoneControlActionCap,
                        sessionTimeoutSeconds: 1800,
                        clientID: BurnBarClientID(rawValue: "phone-control-\(peerNodeId)")
                    ))
                }
                if let pendingSealSession = prepared.pendingSealSession {
                    session.controlSealSessions[frame.connectionId] = pendingSealSession
                    session.recordE2EProofEvent([
                        "event": "mac_control_seal_established",
                        "peerNodeId": pendingSealSession.peerNodeId,
                        "connectionId": frame.connectionId
                    ])
                }
                session.recordE2EProofEvent([
                    "event": "mac_control_classified",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId
                ])
                await session.startWatchHUDIfNeeded()
                #if DEBUG
                startE2EApprovalProbeIfRequested()
                #endif
            } catch {
                session.recordE2EProofEvent([
                    "event": "mac_control_classify_failed",
                    "peerNodeId": peerNodeId,
                    "connectionId": frame.connectionId,
                    "error": error.localizedDescription
                ])
                session.emitControlFrame(
                    type: .controlDenied,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "control.input",
                        sessionId: session.activeSessionId?.rawValue,
                        denied: HermesRealtimeRelayControlDenied(reason: .signatureFailure)
                    )
                )
            }
        case .controlInputIntent:
            session.recordE2EProofEvent([
                "event": "mac_control_input_received",
                "kind": frame.control?.inputIntent?.kind.rawValue ?? "unknown",
                "connectionId": frame.connectionId,
                "counter": String(frame.control?.inputIntent?.authority.counter ?? 0)
            ])
            guard let phoneReceiver = session.phoneReceiver else {
                session.recordE2EProofEvent([
                    "event": "mac_control_input_missing_receiver",
                    "connectionId": frame.connectionId
                ])
                return
            }
            await phoneReceiver.ingest(frame)
        case .controlClipboardRequest:
            guard let request = frame.control?.clipboardRequest else { return }
            session.recordE2EProofEvent([
                "event": "mac_control_clipboard_received",
                "action": request.action.rawValue,
                "connectionId": frame.connectionId,
                "counter": String(request.authority.counter)
            ])
            let makeClipboardContext: () async -> RemoteClipboardController.RuntimeContext = { [self] in
                let attestation = await self.session.phoneControlAttestationRequirement()
                return RemoteClipboardController.RuntimeContext(
                    activeSessionId: self.session.activeSessionId,
                    state: self.session.state,
                    configuration: self.session.configuration,
                    auditLogger: self.session.auditLogger,
                    scopeRules: self.session.scopeRulesProvider(),
                    validator: self.session.phoneValidator,
                    isDirectPhoneControl: self.session.activeSessionIsDirectPhoneControl,
                    attestation: attestation,
                    phoneSessionFirstActionConfirmed: self.session.isPhoneFirstActionConfirmed(peerNodeId: request.authority.peerNodeId)
                )
            }
            var result = session.remoteClipboardController.handle(
                request: request,
                context: await makeClipboardContext()
            )
            if result.response.detail == "phone_first_action_approval_required" {
                let approval = await session.requestMacOnlyApproval(
                    toolKind: "remote_clipboard",
                    title: "Approve phone clipboard",
                    message: "A remote device wants to use this Mac's clipboard.",
                    actionSummary: "Approve phone clipboard \(request.action.rawValue)"
                )
                guard approval.decision == .approve else {
                    result = RemoteClipboardController.Result(
                        response: HermesRealtimeRelayClipboardResponse(
                            requestId: request.requestId,
                            action: request.action,
                            status: .denied,
                            detail: ComputerUseDenyReason.userRejected.rawValue
                        ),
                        action: result.action,
                        auditEntry: nil,
                        executed: false,
                        rejected: true,
                        denyReason: .userRejected
                    )
                    applyRemoteClipboardResult(result)
                    session.emitControlFrame(
                        type: .controlClipboardResponse,
                        payload: HermesRealtimeRelayControlPayload(
                            streamClass: "control.clipboard",
                            sessionId: session.activeSessionId?.rawValue,
                            clipboardResponse: result.response
                        )
                    )
                    return
                }
                session.markPhoneFirstActionConfirmed(peerNodeId: request.authority.peerNodeId)
                result = session.remoteClipboardController.handle(
                    request: request,
                    context: await makeClipboardContext()
                )
            }
            applyRemoteClipboardResult(result)
            session.emitControlFrame(
                type: .controlClipboardResponse,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.clipboard",
                    sessionId: session.activeSessionId?.rawValue,
                    clipboardResponse: result.response
                )
            )
        case .controlAgentContextTarget:
            guard let receiver = session.agentContextReceiver else { return }
            await receiver.ingest(frame)
        case .controlApprovalResponse:
            if let response = frame.control?.approvalResponse {
                session.submitApprovalResponse(
                    response,
                    source: .remote(
                        uid: frame.uid,
                        connectionID: frame.connectionId,
                        sessionID: frame.control?.sessionId
                    )
                )
            }
        case .controlAgentGrantRequest:
            guard let wireRequest = frame.control?.agentGrantRequest else { return }
            let receipt: AgentCapabilityGrantReceipt
            do {
                let attestation = await MacAppCheckAttestationReader.attestationRequirement(
                    strictMode: session.configuration.phoneControlAttestationRequired
                )
                _ = try session.phoneValidator.validate(
                    envelope: wireRequest.authority,
                    grantRequest: wireRequest,
                    attestation: attestation,
                    now: Date()
                )
                let request = try AgentCapabilityGrantRequest(wire: wireRequest)
                let requiresMacApproval = AgentDesktopCapability.requiresMacApproval(
                    capabilities: request.capabilities,
                    trustMode: request.trustMode
                )
                if requiresMacApproval {
                    let approval = await session.requestMacOnlyApproval(
                        toolKind: "agent_capability_grant",
                        title: "Approve agent desktop tools",
                        message: "\(request.preset.title) permissions requested for \(request.runtimeID.rawValue).",
                        actionSummary: "Approve \(request.preset.title) agent tools for \(request.runtimeID.rawValue)"
                    )
                    if approval.decision == .approve {
                        receipt = AgentCapabilityGrantStore.shared.apply(request, macApprovalSatisfied: true)
                    } else {
                        receipt = ComputerUseSessionCoordinator.agentGrantReceipt(
                            for: wireRequest,
                            status: .denied,
                            denialReason: .macApprovalRequired,
                            message: "Mac approval was required and was not granted."
                        )
                    }
                } else {
                    receipt = AgentCapabilityGrantStore.shared.apply(request)
                }
            } catch let error as PhoneControlAuthorityValidator.ValidationError {
                receipt = ComputerUseSessionCoordinator.agentGrantReceipt(
                    for: wireRequest,
                    status: .denied,
                    denialReason: ComputerUseSessionCoordinator.agentGrantDenialReason(for: error),
                    message: "Grant signature failed: \(error)"
                )
            } catch let error as AgentCapabilityGrantWireError {
                receipt = ComputerUseSessionCoordinator.agentGrantReceipt(
                    for: wireRequest,
                    status: .denied,
                    denialReason: .malformedRequest,
                    message: "Grant request could not be decoded: \(error)"
                )
            } catch {
                receipt = ComputerUseSessionCoordinator.agentGrantReceipt(
                    for: wireRequest,
                    status: .denied,
                    denialReason: .unknown,
                    message: error.localizedDescription
                )
            }
            session.emitControlFrame(
                type: .controlAgentGrantReceipt,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.agent.grant",
                    sessionId: session.activeSessionId?.rawValue,
                    agentGrantReceipt: receipt.wire()
                )
            )
        case .controlSystemPermissionRequest:
            guard let receiver = session.systemPermissionReceiver else { return }
            await receiver.ingest(frame)
        case .controlSystemPermissionStatus:
            // The Mac is the source of truth for system-permission
            // status frames. We still allow phone-side reflections
            // (e.g. tests) to flow through the retry dispatcher.
            await SystemPermissionRetryDispatcher.shared.observe(statusFrame: frame)
        case .remoteUnlockCredential:
            guard let credential = frame.control?.remoteUnlockCredential else { return }
            let credentialPeerNodeId = credential.authority.peerNodeId
            ComputerUseSessionCoordinator.log.info(
                "remote_unlock_credential_frame_received requestID=\(credential.requestId, privacy: .public) sessionID=\(credential.sessionId, privacy: .public) peerNodeID=\(credentialPeerNodeId, privacy: .public) connectionID=\(frame.connectionId, privacy: .public)"
            )
            ComputerUseSessionCoordinator.debugTrace("remote_unlock_credential_frame_received requestID=\(credential.requestId) sessionID=\(credential.sessionId) peerNodeID=\(credentialPeerNodeId) connectionID=\(frame.connectionId)")
            do {
                let receivedResult = HermesRealtimeRelayRemoteUnlockResult(
                    requestId: credential.requestId,
                    sessionId: credential.sessionId,
                    status: .accepted,
                    detail: "credential_received",
                    completedAt: Date()
                )
                try await session.sendControlFrame(
                    type: .remoteUnlockResult,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "remote_unlock",
                        sessionId: credential.sessionId,
                        remoteUnlockResult: receivedResult
                    )
                )
                ComputerUseSessionCoordinator.log.info(
                    "remote_unlock_credential_received_ack_sent requestID=\(credential.requestId, privacy: .public)"
                )
                ComputerUseSessionCoordinator.debugTrace("remote_unlock_credential_received_ack_sent requestID=\(credential.requestId)")
            } catch {
                ComputerUseSessionCoordinator.log.error(
                    "remote_unlock_credential_received_ack_failed requestID=\(credential.requestId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                ComputerUseSessionCoordinator.debugTrace("remote_unlock_credential_received_ack_failed requestID=\(credential.requestId) error=\(error.localizedDescription)")
            }
            if !session.phoneValidator.hasPeer(nodeId: credentialPeerNodeId) {
                do {
                    let authority = try await session.authorityProvider.fetchAuthorityRegistration(
                        uid: frame.uid,
                        connectionId: frame.connectionId,
                        peerNodeId: credentialPeerNodeId
                    )
                    session.registerPhonePeer(
                        nodeId: credentialPeerNodeId,
                        verifyingKey: authority.publicKey,
                        requiredAttestationHashBlake3: authority.requiredAttestationHashBlake3
                    )
                    session.recordE2EProofEvent([
                        "event": "remote_unlock_peer_registered",
                        "peerNodeId": credentialPeerNodeId,
                        "connectionId": frame.connectionId
                    ])
                } catch {
                    session.recordE2EProofEvent([
                        "event": "remote_unlock_peer_registration_failed",
                        "peerNodeId": credentialPeerNodeId,
                        "connectionId": frame.connectionId,
                        "error": error.localizedDescription
                    ])
                }
            }
            let authorizedPeerNode = await MainActor.run { session.phoneControlAuthorizedPeerNodeProvider?() }
            let result = await session.remoteUnlockCredentialController.handle(
                credential: credential,
                context: RemoteUnlockCredentialController.RuntimeContext(
                    validator: session.phoneValidator,
                    activeSessionId: session.activeSessionId,
                    state: session.state,
                    isDirectPhoneControl: session.activeSessionIsDirectPhoneControl,
                    authorizedPeerNodeId: authorizedPeerNode,
                    attestation: await session.phoneControlAttestationRequirement()
                )
            )
            ComputerUseSessionCoordinator.log.info(
                "remote_unlock_credential_result requestID=\(credential.requestId, privacy: .public) status=\(result.status.rawValue, privacy: .public) detail=\(result.detail ?? "", privacy: .public) lockState=\(result.lockState?.rawValue ?? "", privacy: .public)"
            )
            ComputerUseSessionCoordinator.debugTrace("remote_unlock_credential_result requestID=\(credential.requestId) status=\(result.status.rawValue) detail=\(result.detail ?? "") lockState=\(result.lockState?.rawValue ?? "")")
            do {
                try await session.sendControlFrame(
                    type: result.status == .denied ? .remoteUnlockDenied : .remoteUnlockResult,
                    payload: HermesRealtimeRelayControlPayload(
                        streamClass: "remote_unlock",
                        sessionId: credential.sessionId,
                        remoteUnlockResult: result
                    )
                )
                ComputerUseSessionCoordinator.log.info(
                    "remote_unlock_credential_result_sent requestID=\(credential.requestId, privacy: .public) status=\(result.status.rawValue, privacy: .public)"
                )
                ComputerUseSessionCoordinator.debugTrace("remote_unlock_credential_result_sent requestID=\(credential.requestId) status=\(result.status.rawValue)")
            } catch {
                ComputerUseSessionCoordinator.log.error(
                    "remote_unlock_credential_result_send_failed requestID=\(credential.requestId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                ComputerUseSessionCoordinator.debugTrace("remote_unlock_credential_result_send_failed requestID=\(credential.requestId) error=\(error.localizedDescription)")
            }
            await session.remoteUnlockResultHandler?(result)
        case .remoteUnlockSession,
             .remoteUnlockInput:
            let requestId = frame.requestId
                ?? frame.control?.remoteUnlockSession?.requestId
                ?? frame.control?.remoteUnlockInput?.requestId
                ?? frame.control?.remoteUnlockCredential?.requestId
                ?? UUID().uuidString
            session.emitControlFrame(
                type: .remoteUnlockDenied,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "remote_unlock",
                    sessionId: frame.control?.sessionId,
                    remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult(
                        requestId: requestId,
                        sessionId: frame.control?.sessionId,
                        status: .denied,
                        detail: "remote_unlock_daemon_unavailable",
                        completedAt: Date()
                    )
                )
            )
        case .remoteUnlockState,
             .remoteUnlockResult,
             .remoteUnlockDenied:
            break
        default:
            break
        }
    }

    #if DEBUG
    func startE2EApprovalProbeIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENBURNBAR_E2E_COMPUTER_USE_APPROVAL_PROOF"] == "1" else { return }
        guard !session.didStartE2EApprovalProbe else { return }
        guard let sessionId = session.activeSessionId?.rawValue else { return }
        session.didStartE2EApprovalProbe = true
        Task { @MainActor in
            session.recordE2EProofEvent([
                "event": "mac_approval_probe_started",
                "sessionId": sessionId
            ])
            let response = await session.invoke(BurnBarToolInvocation(
                callID: "e2e-approval-\(UUID().uuidString)",
                runID: BurnBarRunID(rawValue: "e2e-approval-\(sessionId)"),
                tool: .macInputScroll,
                arguments: .object([
                    "displayX": .number(500),
                    "displayY": .number(500),
                    "dragEndX": .number(500),
                    "dragEndY": .number(420)
                ]),
                requestedBy: BurnBarClientID(rawValue: "e2e-approval-agent"),
                requestedAt: Date()
            ))
            var fields: [String: String] = [
                "event": "mac_approval_probe_completed",
                "sessionId": response.sessionId,
                "status": response.status.rawValue
            ]
            if let approvalId = response.approvalId {
                fields["approvalId"] = approvalId
            }
            if let auditEntryIndex = response.auditEntryIndex {
                fields["auditEntryIndex"] = String(auditEntryIndex)
            }
            if let auditHeadHashHex = response.auditHeadHashHex {
                fields["auditHead"] = auditHeadHashHex
            }
            if let denyReason = response.denyReason {
                fields["denyReason"] = denyReason
            }
            session.recordE2EProofEvent(fields)
        }
    }

    #endif
    func handlePhoneAction(_ action: ComputerUseAction, sessionId: ComputerUseSessionID, counter: UInt64) async {
        guard session.activeSessionId == sessionId else { return }
        guard session.configuration.entitlement.allowsPhoneControl else {
            session.emitControlFrame(
                type: .controlDenied,
                payload: HermesRealtimeRelayControlPayload(
                    streamClass: "control.input",
                    sessionId: sessionId.rawValue,
                    denied: HermesRealtimeRelayControlDenied(reason: .entitlement)
                )
            )
            return
        }
        if case .phoneIntent(let intent) = action {
            if intent.kind == .panic {
                session.recordE2EProofEvent([
                    "event": "mac_phone_panic_received",
                    "sessionId": sessionId.rawValue,
                    "counter": String(counter)
                ])
                await session.panicHalt(source: .phoneGesture)
                return
            }
            if intent.kind == .setTrustMode {
                session.applyPhoneTrustModeIntent(intent)
                return
            }
        }
        let invocation = session.invocationFromPhoneAction(action, sessionId: sessionId)
        refocusPhoneKeyboardTargetIfNeeded(for: action)
        session.recordE2EProofEvent([
            "event": "mac_phone_action_dispatching",
            "tool": invocation.tool.rawValue,
            "sessionId": sessionId.rawValue,
            "counter": String(counter)
        ])
        let response = await session.invokeTrustedPhoneControlAction(invocation)
        var fields: [String: String] = [
            "event": "mac_phone_action_dispatched",
            "tool": invocation.tool.rawValue,
            "sessionId": response.sessionId,
            "status": response.status.rawValue,
            "counter": String(counter)
        ]
        if let auditEntryIndex = response.auditEntryIndex {
            fields["auditEntryIndex"] = String(auditEntryIndex)
        }
        if let auditHeadHashHex = response.auditHeadHashHex {
            fields["auditHead"] = auditHeadHashHex
        }
        if let denyReason = response.denyReason {
            fields["denyReason"] = denyReason
            ComputerUseSessionCoordinator.log.warning(
                "mac_phone_action_denied tool=\(invocation.tool.rawValue, privacy: .public) reason=\(denyReason, privacy: .public) status=\(response.status.rawValue, privacy: .public)"
            )
        }
        session.recordE2EProofEvent(fields)
        emitPhoneControlDeniedFrameIfNeeded(response)
    }

    func refocusPhoneKeyboardTargetIfNeeded(for action: ComputerUseAction) {
        guard ComputerUseSessionCoordinator.shouldRetargetPhoneKeyboardAction(action),
              let windowID = session.phoneControlKeyboardTargetWindowProvider?() else { return }
        do {
            if let phoneControlKeyboardTargetFocuser = session.phoneControlKeyboardTargetFocuser {
                try phoneControlKeyboardTargetFocuser(windowID)
            } else {
                try session.inputController.focusWindow(windowID: windowID)
            }
            session.recordE2EProofEvent([
                "event": "mac_phone_keyboard_target_refocused",
                "windowId": String(windowID)
            ])
        } catch {
            session.recordE2EProofEvent([
                "event": "mac_phone_keyboard_target_refocus_failed",
                "windowId": String(windowID),
                "error": String(describing: error)
            ])
            ComputerUseSessionCoordinator.log.warning("mac_phone_keyboard_target_refocus_failed windowID=\(windowID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func emitPhoneControlDeniedFrameIfNeeded(_ response: ComputerUseInvokeResponse) {
        guard response.status != .executed,
              let denyReason = response.denyReason else { return }
        let denied = HermesRealtimeRelayControlDenied(
            reason: session.controlDeniedReason(for: denyReason),
            detail: denyReason
        )
        session.emitControlFrame(
            type: .controlDenied,
            payload: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlInput.rawValue,
                sessionId: response.sessionId,
                denied: denied
            )
        )
    }

    func applyRemoteClipboardResult(_ result: RemoteClipboardController.Result) {
        if var currentState = session.state {
            if result.executed {
                currentState.actionsExecuted += 1
                currentState.lastActionAt = Date()
            } else if result.rejected {
                currentState.actionsRejected += 1
            }
            if let logger = session.auditLogger {
                currentState.auditChainHeadHashHex = logger.headHashHex
            }
            session.state = currentState
        }
        if let denyReason = result.denyReason {
            session.lastDeniedReason = denyReason
        }
        guard let action = result.action else { return }
        let timelineStatus: HermesRealtimeRelayActionLogEntry.Status
        switch result.response.status {
        case .accepted:
            timelineStatus = .completed
        case .denied, .empty, .tooLarge, .unsupported:
            timelineStatus = .rejected
        case .error:
            timelineStatus = .failed
        }
        session.appendTimeline(
            kind: action.auditKind,
            summary: session.remoteClipboardTimelineSummary(for: result.response, action: action),
            status: timelineStatus,
            entryIndex: result.auditEntry?.entryIndex,
            parentEntryBlake3: result.auditEntry?.parentEntryHashHex,
            errorCategory: result.response.status == .error ? "dispatch_error" : nil
        )
        session.emitControlFrame(
            type: .controlActionLogEntry,
            payload: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: session.state?.sessionId.rawValue,
                actionLogEntry: session.actionTimeline.last
            )
        )
    }
}

#endif

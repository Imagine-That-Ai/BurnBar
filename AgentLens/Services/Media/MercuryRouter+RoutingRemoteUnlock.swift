import Foundation
import Combine
import Darwin
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OSLog
import AppKit
import ImageIO

extension MercuryRouter {

    // MARK: - Private

    func installHostAuthGateListeners() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for name in names {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                if let reason = Self.hostAuthGateClosedReason(from: note) {
                    Task { @MainActor [weak self] in
                        await self?.handleHostAuthGateClosed(reason: reason)
                    }
                    return
                }
                guard let reason = Self.hostAuthGateOpenedReason(from: note) else { return }
                Task { @MainActor [weak self] in
                    self?.scheduleRemoteUnlockResumeCheck(reason: reason)
                }
            }
            workspaceAuthGateObservers.append(observer)
        }
    }

    nonisolated static func hostAuthGateClosedReason(from note: Notification) -> String? {
        switch note.name {
        case NSWorkspace.screensDidSleepNotification:
            return "screen_sleep"
        case NSWorkspace.sessionDidResignActiveNotification:
            return "session_resigned_active"
        case NSWorkspace.didActivateApplicationNotification:
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier,
                  bundle == "com.apple.loginwindow" || bundle == "com.apple.SecurityAgent"
            else { return nil }
            return bundle
        default:
            return nil
        }
    }

    nonisolated static func hostAuthGateOpenedReason(from note: Notification) -> String? {
        switch note.name {
        case NSWorkspace.sessionDidBecomeActiveNotification:
            return "session_became_active"
        case NSWorkspace.didWakeNotification:
            return "display_wake"
        case NSWorkspace.didActivateApplicationNotification:
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier,
                  bundle != "com.apple.loginwindow",
                  bundle != "com.apple.SecurityAgent",
                  bundle != "com.apple.SecurityAgentHelper" else {
                return nil
            }
            return "frontmost_app_active"
        default:
            return nil
        }
    }

    func scheduleRemoteUnlockResumeCheck(reason: String) {
        scheduleRemoteUnlockResumePoll(reason: reason, initialDelayNanoseconds: 350_000_000)
    }

    func handleRemoteUnlockCredentialResult(_ result: HermesRealtimeRelayRemoteUnlockResult) {
        guard result.status == .accepted || result.status == .unlocked else { return }
        guard let resultSessionID = result.sessionId,
              activeRemoteUnlockSessionID(in: currentMirrorSessions()) == resultSessionID else {
            return
        }
        let reason = result.status == .unlocked
            ? "remote_unlock_result_unlocked"
            : "remote_unlock_credential_submitted"
        scheduleRemoteUnlockResumePoll(reason: reason, initialDelayNanoseconds: result.status == .unlocked ? 0 : 250_000_000)
    }

    func scheduleRemoteUnlockResumePoll(
        reason: String,
        initialDelayNanoseconds: UInt64,
        maxAttempts: Int = 24
    ) {
        guard shouldKeepMirrorAliveForRemoteUnlock(currentMirrorSessions()) else { return }
        remoteUnlockResumeTask?.cancel()
        remoteUnlockResumeTask = Task { @MainActor [weak self] in
            if initialDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: initialDelayNanoseconds) // try?-ok(sleep cancellation only)
            }
            for attempt in 0..<maxAttempts {
                guard !Task.isCancelled, let self else { return }
                let activeViewers = self.currentMirrorSessions()
                guard self.hasActiveRemoteUnlockViewer(activeViewers) else { return }
                if self.remoteUnlockReadiness.currentLockState() == .unlocked {
                    await self.handleRemoteUnlockHostUnlocked(reason: reason)
                    return
                }
                if attempt < maxAttempts - 1 {
                    try? await Task.sleep(nanoseconds: 350_000_000) // try?-ok(sleep cancellation only)
                }
            }
            Self.log.info("router_remote_unlock_resume_poll_still_locked reason=\(reason, privacy: .public)")
            Self.debugTrace("router_remote_unlock_resume_poll_still_locked reason=\(reason)")
        }
    }

    func handleRemoteUnlockHostUnlocked(reason: String) async {
        let activeViewers = currentMirrorSessions()
        guard hasActiveRemoteUnlockViewer(activeViewers) else { return }
        let remoteUnlockSessionID = activeRemoteUnlockSessionID(in: activeViewers)
        let state = remoteUnlockReadiness.currentState(
            sessionId: remoteUnlockSessionID,
            controlOwnerViewerId: activeControlViewerID
        )
        guard state.capabilities.enabled, state.lockState == .unlocked else { return }

        remoteUnlockReadiness.revokeAllRemoteUnlockSessions(revokePublishedTrust: false)
        Self.log.info("router_remote_unlock_unlocked_resuming_normal_capture reason=\(reason, privacy: .public)")
        Self.debugTrace("router_remote_unlock_unlocked_resuming_normal_capture reason=\(reason)")
        do {
            if case .active(feature: .screenShare) = sessionCoordinator.phase {
                try await sessionCoordinator.switchScreenShareTarget(
                    displayId: activeSelectedDisplayID,
                    windowID: nil
                )
            } else {
                for viewer in activeViewers {
                    try await startNormalCapture(for: viewer)
                }
            }
            lastError = nil
        } catch {
            lastError = "Mirror resumed after unlock, but screen capture restart failed: \(error.localizedDescription)"
            Self.log.error("router_remote_unlock_resume_capture_failed error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("router_remote_unlock_resume_capture_failed error=\(error.localizedDescription)")
        }

        let displays = ScreenCapturePipeline.availableDisplays()
        activeSelectedDisplayID = activeSelectedDisplayID ?? displays.first?.id
        await broadcastMirrorAck(
            decision: .accepted,
            detail: "Mac unlocked; normal mirror resumed.",
            availableDisplays: displays,
            selectedDisplayId: activeSelectedDisplayID,
            remoteUnlockState: state,
            remoteUnlockCapabilities: state.capabilities
        )
    }

    func streamingCapabilities(
        for mirrorRequest: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame,
        controlStreamID: UUID?
    ) -> (
        local: MercuryStreamingCapabilitySnapshot?,
        remote: MercuryStreamingCapabilitySnapshot?
    ) {
        let remoteCapabilities = mirrorRequest.streamingCapabilities
            .map(MercuryStreamingCapabilitySnapshot.init(wire:))
            ?? controlStreamID.flatMap {
                remoteStreamingCapabilitiesByControlStreamID[$0]
            }
            ?? remoteStreamingCapabilitiesByConnectionID[frame.connectionId]
        let localCapabilities = remoteCapabilities.map { _ in localStreamingCapabilityProvider() }
        return (localCapabilities, remoteCapabilities)
    }

    func startNormalCapture(for viewer: ActiveMirrorViewer) async throws {
        guard let mirrorRequest = viewer.frame.media?.mirrorRequest,
              let factory = mirrorSinkFactory else {
            throw MediaSessionError.captureFailed
        }
        if mirrorRequest.mediaSealKey != nil && !viewer.mediaFrameSealEstablished {
            throw MercuryLaneSealingError.refused(reason: .sessionKeyUnavailable)
        }
        let sink = try await factory(mirrorRequest, viewer.frame, viewer.replySender)
        let capabilities = streamingCapabilities(
            for: mirrorRequest,
            frame: viewer.frame,
            controlStreamID: viewer.controlStreamID
        )
        try await startScreenShare(
            viewer.frame.connectionId,
            sink,
            .screenVideo,
            activeSelectedDisplayID,
            viewer.viewerID,
            capabilities.local,
            capabilities.remote,
            .production
        )
    }

    /// F7 — consult `MediaFrameAeadNegotiation` for the requested lane and
    /// return whether this viewer has an established media-frame seal. The Mac
    /// always advertises
    /// `MediaFrameAeadNegotiation.capability` (see `macPresenceCapabilities`),
    /// so `localSupports` is true; the phone only wraps a `mediaSealKey` into
    /// its mirror request once both peers advertise F7, so its presence is the
    /// remote-support signal. Once a remote peer offers a seal, missing key
    /// material is a hard refusal even for screen-video; pre-F7 peers still
    /// omit the wrap and keep legacy screen-share compatibility.
    func resolvedMediaFrameSealEstablished(
        mirrorRequest: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async throws -> Bool {
        let streamClass = MediaStreamClass(rawValue: mirrorRequest.streamClass)
        let remoteSupports = mirrorRequest.mediaSealKey != nil
        let sessionKeyAvailable = await mediaFrameSealEstablished(
            for: mirrorRequest,
            frame: frame
        )
        let decision = MediaFrameAeadNegotiation.resolveSealingDecision(
            streamClass: streamClass,
            localSupports: true,
            remoteSupports: remoteSupports,
            sessionKeyAvailable: sessionKeyAvailable
        )
        switch decision {
        case .seal:
            return true
        case .allowUnsealed:
            return false
        case .refuseLane(let reason):
            Self.log.error("router_lane_refused_sealing streamClass=\(streamClass.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
            Self.debugTrace("router_lane_refused_sealing streamClass=\(streamClass.rawValue) reason=\(reason.rawValue)")
            throw MercuryLaneSealingError.refused(reason: reason)
        }
    }

    func mediaFrameSealEstablished(
        for mirrorRequest: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async -> Bool {
        guard mirrorRequest.mediaSealKey != nil else { return false }
        return await MacMediaSealKeyOpener.frameSealKey(
            for: mirrorRequest,
            frame: frame
        ) != nil
    }

    static func effectiveFocusFollowMode(
        for request: HermesRealtimeRelayMirrorRequest,
        requestedMode: AgentFocusFollowMode?
    ) -> AgentFocusFollowMode {
        guard request.streamClass == MediaStreamClass.controlSurfaceFrame.rawValue else {
            return .off
        }
        return requestedMode ?? .smart
    }

    func handleHostAuthGateClosed(reason: String) async {
        let pendingMirror = pendingRequest
        let pendingPhoneCall = pendingCall
        let activeViewers = currentMirrorSessions()

        let hadWorkToStop = pendingMirror != nil
            || pendingPhoneCall != nil
            || !activeViewers.isEmpty
            || phase != .idle

        guard hadWorkToStop else { return }

        if shouldKeepMirrorAliveForRemoteUnlock(activeViewers) {
            let remoteUnlockSessionID = activeRemoteUnlockSessionID(in: activeViewers)
            let state = remoteUnlockReadiness.currentState(
                sessionId: remoteUnlockSessionID,
                controlOwnerViewerId: activeControlViewerID
            )
            Self.log.info("router_host_auth_gate_remote_unlock_kept_alive reason=\(reason, privacy: .public) state=\(state.lockState.rawValue, privacy: .public)")
            Self.debugTrace("router_host_auth_gate_remote_unlock_kept_alive reason=\(reason) state=\(state.lockState.rawValue)")
            lastError = nil
            await broadcastMirrorAck(
                decision: .accepted,
                detail: "Mac locked; Remote Unlock remains available.",
                availableDisplays: ScreenCapturePipeline.availableDisplays(),
                selectedDisplayId: activeSelectedDisplayID,
                remoteUnlockState: state,
                remoteUnlockCapabilities: state.capabilities
            )
            return
        }

        Self.log.info("router_host_auth_gate_closed reason=\(reason, privacy: .public)")
        Self.debugTrace("router_host_auth_gate_closed reason=\(reason)")
        lastError = "Mirror stopped because the Mac locked or screen capture became unavailable."

        pendingRequest = nil
        pendingCall = nil

        if let pendingMirror {
            await respond(
                requestID: pendingMirror.id,
                decision: .denied,
                detail: "Mac locked or screen capture became unavailable",
                frame: pendingMirror.frame,
                replySender: pendingMirror.replySender
            )
        }

        if let pendingPhoneCall {
            await respondToCall(
                requestID: pendingPhoneCall.id,
                decision: .denied,
                detail: "Mac locked or became unavailable",
                frame: pendingPhoneCall.frame,
                replySender: pendingPhoneCall.replySender
            )
        }

        if !activeViewers.isEmpty {
            await sessionCoordinator.stop(reason: .completedUserCancel)
            for viewer in activeViewers {
                await respond(
                    requestID: viewer.requestID,
                    decision: .denied,
                    detail: "Mac locked or screen capture became unavailable",
                    sessionID: viewer.sessionID,
                    viewerID: viewer.viewerID,
                    viewerRole: viewerRole(for: viewer.viewerID),
                    viewerCount: 0,
                    maxViewers: maxMirrorViewers,
                    controlOwnerViewerID: nil,
                    frame: viewer.frame,
                    replySender: viewer.replySender
                )
            }
        }

        clearAllActiveMirrorViewers()
        phase = .idle
    }

    func activeRemoteUnlockSessionID(in activeViewers: [ActiveMirrorViewer]) -> String? {
        activeViewers.first { viewer in
            guard let sessionID = viewer.remoteUnlockSessionID,
                  let peerNodeID = viewer.controlAuthorityPeerNodeID else {
                return false
            }
            guard Self.peerNodeIDsMatch(peerNodeID, viewer.remotePeerNodeID) else {
                return false
            }
            return remoteUnlockReadiness.isRemoteUnlockSessionActive(
                sessionId: sessionID,
                peerNodeId: peerNodeID,
                viewerDeviceId: viewer.viewerDeviceID,
                now: clock()
            )
        }?.remoteUnlockSessionID
    }

    func shouldKeepMirrorAliveForRemoteUnlock(_ activeViewers: [ActiveMirrorViewer]) -> Bool {
        guard remoteUnlockReadiness.capabilities().enabled else { return false }
        return hasActiveRemoteUnlockViewer(activeViewers)
    }

    /// The session was already capability-validated when the locked mirror was
    /// accepted. Hot resume polling only needs to prove that the same bound,
    /// unexpired viewer remains active; capability freshness is revalidated
    /// once when an unlock is actually observed.
    func hasActiveRemoteUnlockViewer(_ activeViewers: [ActiveMirrorViewer]) -> Bool {
        return activeViewers.contains { viewer in
            guard let sessionID = viewer.remoteUnlockSessionID,
                  let peerNodeID = viewer.controlAuthorityPeerNodeID else {
                return false
            }
            guard Self.peerNodeIDsMatch(peerNodeID, viewer.remotePeerNodeID) else {
                return false
            }
            return remoteUnlockReadiness.isRemoteUnlockSessionActive(
                sessionId: sessionID,
                peerNodeId: peerNodeID,
                viewerDeviceId: viewer.viewerDeviceID,
                now: clock()
            )
        }
    }

    func remoteUnlockSessionForLockedMirror(
        _ request: HermesRealtimeRelayMirrorRequest
    ) -> HermesRealtimeRelayRemoteUnlockSession? {
        guard let session = request.remoteUnlockSession else { return nil }
        let state = remoteUnlockReadiness.currentState(
            sessionId: session.sessionId,
            controlOwnerViewerId: nil
        )
        guard state.lockState != .unlocked,
              state.lockState != .unknown,
              state.capabilities.supportedLockStates.contains(state.lockState) else {
            return nil
        }
        return session
    }

    func remoteUnlockSessionRequiredState(
        for request: HermesRealtimeRelayMirrorRequest
    ) -> HermesRealtimeRelayRemoteUnlockState? {
        guard request.remoteUnlockSession == nil else { return nil }
        let state = remoteUnlockReadiness.currentState(
            sessionId: nil,
            controlOwnerViewerId: nil
        )
        guard state.capabilities.enabled,
              state.lockState != .unlocked,
              state.lockState != .unknown,
              state.capabilities.supportedLockStates.contains(state.lockState) else {
            return nil
        }
        return state
    }

    func remoteUnlockMirrorDenialReason(
        request: HermesRealtimeRelayMirrorRequest,
        session: HermesRealtimeRelayRemoteUnlockSession,
        remotePeerNodeID: String?,
        uid: String,
        connectionID: String,
        consumeCounter: Bool = true
    ) async -> String? {
        guard Self.peerNodeIDsMatch(session.authority.peerNodeId, remotePeerNodeID) else {
            return "remote_unlock_transport_peer_mismatch"
        }
        if let authorityPeerNodeID = request.controlAuthorityPeerNodeId?.canonicalMercuryPeerNodeID,
           authorityPeerNodeID != session.authority.peerNodeId.canonicalMercuryPeerNodeID {
            return "remote_unlock_peer_mismatch"
        }
        if let reason = await remoteUnlockAuthorityDenialReason(
            session: session,
            uid: uid,
            connectionID: connectionID,
            consumeCounter: consumeCounter
        ) {
            return reason
        }
        switch remoteUnlockReadiness.validateRemoteUnlockSession(session, now: clock()) {
        case .allowed:
            return nil
        case .denied(let reason):
            return reason
        }
    }

    private func remoteUnlockAuthorityDenialReason(
        session: HermesRealtimeRelayRemoteUnlockSession,
        uid: String,
        connectionID: String,
        consumeCounter: Bool
    ) async -> String? {
        guard let validator = phoneControlAuthorityValidatorProvider() else {
            return "signature_failure"
        }
        let peerNodeID = session.authority.peerNodeId
        if !validator.hasPeer(nodeId: peerNodeID) {
            guard let phoneControlAuthorityRegistrationProvider else {
                return "signature_failure"
            }
            do {
                let authority = try await phoneControlAuthorityRegistrationProvider(
                    uid,
                    connectionID,
                    peerNodeID
                )
                switch validator.registerPeerDetailed(
                    nodeId: peerNodeID,
                    verifyingKey: authority.publicKey,
                    uid: uid,
                    requiredAttestationHashBlake3: authority.requiredAttestationHashBlake3
                ) {
                case .admitted:
                    break
                case .pendingConfirmation:
                    return "controller_confirmation_required"
                case .refused:
                    return "signature_failure"
                }
            } catch {
                return "signature_failure"
            }
        }
        do {
            _ = try validator.validate(
                envelope: session.authority,
                remoteUnlockSession: session,
                attestation: .requireBoundPeer,
                now: clock(),
                consumeCounter: consumeCounter
            )
            return nil
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            return error.auditDetailToken
        } catch {
            return "signature_failure"
        }
    }

}

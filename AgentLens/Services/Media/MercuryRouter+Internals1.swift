import Foundation
import Combine
import Darwin
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OSLog
import AppKit
import ImageIO

// Mercury routing internals (part 1).
// Extracted from MercuryRouter.swift (god-type decomposition) — same module, same isolation, verbatim.

extension MercuryRouter {

    /// User tapped "Accept" on a phone-originated call invite. This acks
    /// the invitation over the live control stream; media negotiation is
    /// still owned by the dedicated Mercury call transport.
    func acceptCall(_ request: PendingRequest) async {
        await respondToCall(
            requestID: request.id,
            decision: .accepted,
            detail: "Mac accepted the call invite",
            frame: request.frame,
            replySender: request.replySender
        )
        pendingCall = nil
        phase = .idle
    }

    /// User tapped "Decline" on a phone-originated call invite.
    func declineCall(_ request: PendingRequest) async {
        await respondToCall(
            requestID: request.id,
            decision: .denied,
            detail: "Declined by user",
            frame: request.frame,
            replySender: request.replySender
        )
        pendingCall = nil
        startCooldown(seconds: Int(cooldownSeconds))
    }

    /// User tapped "Stop" on the CallHUD during an active mirror.
    func stopMirror() async {
        let viewers = currentMirrorSessions()
        await sessionCoordinator.stop(reason: .completedUserCancel)
        for viewer in viewers {
            await respond(
                requestID: viewer.requestID,
                decision: .denied,
                detail: "Host ended mirror",
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
        pendingRequest = nil
        clearAllActiveMirrorViewers()
        phase = .idle
    }

    func handleHostAuthGateClosedForTesting(reason: String = "test") async {
        await handleHostAuthGateClosed(reason: reason)
    }

    func handleHostAuthGateOpenedForTesting(reason: String = "test") async {
        await handleRemoteUnlockHostUnlocked(reason: reason)
    }

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
                guard self.shouldKeepMirrorAliveForRemoteUnlock(activeViewers) else { return }
                let remoteUnlockSessionID = self.activeRemoteUnlockSessionID(in: activeViewers)
                let state = self.remoteUnlockReadiness.currentState(
                    sessionId: remoteUnlockSessionID,
                    controlOwnerViewerId: self.activeControlViewerID
                )
                if state.lockState == .unlocked {
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
        guard shouldKeepMirrorAliveForRemoteUnlock(activeViewers) else { return }
        let remoteUnlockSessionID = activeRemoteUnlockSessionID(in: activeViewers)
        let state = remoteUnlockReadiness.currentState(
            sessionId: remoteUnlockSessionID,
            controlOwnerViewerId: activeControlViewerID
        )
        guard state.lockState == .unlocked else { return }

        remoteUnlockReadiness.revokeRemoteUnlockSession(sessionId: remoteUnlockSessionID)
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
        let localCapabilities = remoteCapabilities.map { _ in
            MercuryVideoToolboxCapabilityProbe.snapshot(mediaFrameVersions: .v1AndV2)
        }
        return (localCapabilities, remoteCapabilities)
    }

    func startNormalCapture(for viewer: ActiveMirrorViewer) async throws {
        guard let mirrorRequest = viewer.frame.media?.mirrorRequest,
              let factory = mirrorSinkFactory else {
            throw MediaSessionError.captureFailed
        }
        // F7 — refuse the lane (fail CLOSED) when sealing is expected for this
        // stream class but cannot be established. Screen-video / agent-watch
        // keep `sealingExpected == false`, so they still degrade to
        // unsealed-over-QUIC for pre-F7 viewers and are never refused here; only
        // audio, camera/call video, and file lanes refuse a de-negotiated peer
        // rather than leak that lane's bytes in cleartext on a transport
        // fallback.
        try await refuseLaneIfSealingNotEstablished(
            mirrorRequest: mirrorRequest,
            frame: viewer.frame
        )
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

    /// F7 — consult `MediaFrameAeadNegotiation` for the requested lane and throw
    /// when it decides `.refuseLane`. The Mac always advertises
    /// `MediaFrameAeadNegotiation.capability` (see `macPresenceCapabilities`),
    /// so `localSupports` is true; the phone only wraps a `mediaSealKey` into
    /// its mirror request once both peers advertise F7, so its presence is the
    /// remote-support signal; and `sessionKeyAvailable` reflects whether the
    /// Mac can actually open that wrap into a usable session key. For lanes
    /// whose `sealingExpected` is false (screen-video / agent-watch) the
    /// negotiation never refuses, so this is a no-op for them.
    func refuseLaneIfSealingNotEstablished(
        mirrorRequest: HermesRealtimeRelayMirrorRequest,
        frame: HermesRealtimeRelayFrame
    ) async throws {
        let streamClass = MediaStreamClass(rawValue: mirrorRequest.streamClass)
        let remoteSupports = mirrorRequest.mediaSealKey != nil
        let sessionKeyAvailable: Bool
        if remoteSupports {
            sessionKeyAvailable = await MacMediaSealKeyOpener.frameSealKey(
                for: mirrorRequest,
                frame: frame
            ) != nil
        } else {
            sessionKeyAvailable = false
        }
        let decision = MediaFrameAeadNegotiation.resolveSealingDecision(
            streamClass: streamClass,
            localSupports: true,
            remoteSupports: remoteSupports,
            sessionKeyAvailable: sessionKeyAvailable
        )
        guard case .refuseLane(let reason) = decision else { return }
        Self.log.error("router_lane_refused_sealing streamClass=\(streamClass.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
        Self.debugTrace("router_lane_refused_sealing streamClass=\(streamClass.rawValue) reason=\(reason.rawValue)")
        throw MercuryLaneSealingError.refused(reason: reason)
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
        remotePeerNodeID: String?
    ) -> String? {
        guard Self.peerNodeIDsMatch(session.authority.peerNodeId, remotePeerNodeID) else {
            return "remote_unlock_transport_peer_mismatch"
        }
        if let authorityPeerNodeID = request.controlAuthorityPeerNodeId?.canonicalMercuryPeerNodeID,
           authorityPeerNodeID != session.authority.peerNodeId.canonicalMercuryPeerNodeID {
            return "remote_unlock_peer_mismatch"
        }
        switch remoteUnlockReadiness.validateRemoteUnlockSession(session, now: clock()) {
        case .allowed:
            return nil
        case .denied(let reason):
            return reason
        }
    }

    func handleMirrorRequest(
        frame: HermesRealtimeRelayFrame,
        controlStreamID: UUID?,
        remotePeerNodeID: String?,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        guard let req = frame.media?.mirrorRequest else {
            Self.log.error("router_mirror_request_missing_payload requestID=\(frame.requestId ?? "", privacy: .public)")
            Self.debugTrace("router_mirror_request_missing_payload requestID=\(frame.requestId ?? "")")
            return
        }
        Self.log.info("router_mirror_request_received requestID=\(req.requestId, privacy: .public) requester=\(req.requesterDisplayName, privacy: .public)")
        Self.debugTrace("router_mirror_request_received requestID=\(req.requestId) requester=\(req.requesterDisplayName)")

        let remoteUnlockSession = remoteUnlockSessionForLockedMirror(req)
        if let remoteUnlockSession {
            if let reason = remoteUnlockMirrorDenialReason(
                request: req,
                session: remoteUnlockSession,
                remotePeerNodeID: remotePeerNodeID
            ) {
                let state = remoteUnlockReadiness.currentState(
                    sessionId: remoteUnlockSession.sessionId,
                    controlOwnerViewerId: nil
                )
                Self.log.info("router_remote_unlock_request_denied requestID=\(req.requestId, privacy: .public) reason=\(reason, privacy: .public)")
                Self.debugTrace("router_remote_unlock_request_denied requestID=\(req.requestId) reason=\(reason)")
                await respond(
                    requestID: req.requestId,
                    decision: .unsupported,
                    detail: reason,
                    viewerID: req.viewerId,
                    remoteUnlockState: state,
                    remoteUnlockCapabilities: state.capabilities,
                    frame: frame,
                    replySender: replySender
                )
                return
            }
        } else if let state = remoteUnlockSessionRequiredState(for: req) {
            Self.log.info("router_remote_unlock_session_required requestID=\(req.requestId, privacy: .public) state=\(state.lockState.rawValue, privacy: .public)")
            Self.debugTrace("router_remote_unlock_session_required requestID=\(req.requestId) state=\(state.lockState.rawValue)")
            await respond(
                requestID: req.requestId,
                decision: .unsupported,
                detail: Self.remoteUnlockSessionRequiredDetail,
                viewerID: req.viewerId,
                remoteUnlockState: state,
                remoteUnlockCapabilities: state.capabilities,
                frame: frame,
                replySender: replySender
            )
            return
        }

        // Cooldown short-circuit — never bother the user mid-cooldown.
        if case let .cooldown(remaining) = phase {
            Self.log.info("router_mirror_request_cooling_down requestID=\(req.requestId, privacy: .public) remaining=\(remaining, privacy: .public)")
            Self.debugTrace("router_mirror_request_cooling_down requestID=\(req.requestId) remaining=\(remaining)")
            await respond(
                requestID: req.requestId,
                decision: .coolingDown,
                detail: "Cooling down",
                cooldownSecondsRemaining: remaining,
                frame: frame,
                replySender: replySender
            )
            return
        }

        let requestedViewerID = viewerID(for: req, frame: frame, controlStreamID: controlStreamID)

        // Recovery fast-path: if the same viewer/device asks again while the
        // router still has its old sink, replace only that viewer lease.
        if case .streaming = phase,
           let staleViewer = activeMirrorViewers[requestedViewerID] ?? viewer(matchingPeerIdentity: req) {
            Self.log.info("router_mirror_request_restarting_same_peer requestID=\(req.requestId, privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
            Self.debugTrace("router_mirror_request_restarting_same_peer requestID=\(req.requestId) connectionID=\(frame.connectionId)")
            _ = await removeActiveMirrorViewer(viewerID: staleViewer.viewerID)
        }

        if case .streaming = phase,
           activeMirrorViewers.count >= maxMirrorViewers {
            Self.log.info("router_mirror_request_busy_viewer_cap requestID=\(req.requestId, privacy: .public)")
            Self.debugTrace("router_mirror_request_busy_viewer_cap requestID=\(req.requestId)")
            await respond(
                requestID: req.requestId,
                decision: .busy,
                detail: "Mirror viewer limit reached",
                viewerID: requestedViewerID,
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: frame,
                replySender: replySender
            )
            return
        }
        if case .starting = phase {
            Self.log.info("router_mirror_request_busy_starting requestID=\(req.requestId, privacy: .public)")
            Self.debugTrace("router_mirror_request_busy_starting requestID=\(req.requestId)")
            await respond(
                requestID: req.requestId,
                decision: .busy,
                detail: "A mirror is starting",
                viewerID: requestedViewerID,
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: frame,
                replySender: replySender
            )
            return
        }

        if pendingRequest != nil {
            await respond(
                requestID: req.requestId,
                decision: .busy,
                detail: "A mirror request is awaiting approval",
                viewerID: requestedViewerID,
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: frame,
                replySender: replySender
            )
            return
        }

        let pending = PendingRequest(
            id: req.requestId,
            requesterName: req.requesterDisplayName,
            requestedAt: req.requestedAt,
            frame: frame,
            replySender: replySender,
            controlStreamID: controlStreamID,
            remotePeerNodeID: remotePeerNodeID,
            agentTerminalApproved: false
        )

        let hasMirrorAutoAcceptGrant = consentStore.canAutoAccept(
            connectionId: frame.connectionId,
            viewerDeviceId: req.viewerDeviceId,
            controlAuthorityPeerNodeId: req.controlAuthorityPeerNodeId,
            remotePeerNodeId: remotePeerNodeID
        )

        // Consent fast-paths:
        // - normal unlocked mirrors require a per-peer expiring grant;
        // - locked Remote Unlock mirrors can use a signed trusted-device session.
        // Neither path stores or replays the user's Mac password.
        if (hasMirrorAutoAcceptGrant || remoteUnlockSession != nil) && !pending.requestsAgentTerminal {
            Self.log.info("router_mirror_request_auto_accept requestID=\(req.requestId, privacy: .public)")
            Self.debugTrace("router_mirror_request_auto_accept requestID=\(req.requestId)")
            await beginMirror(for: pending)
            return
        }

        // Surface the ringing UI.
        pendingRequest = pending
        phase = .ringing(
            requestID: req.requestId,
            requesterName: req.requesterDisplayName,
            requestedAt: req.requestedAt
        )
        Self.log.info("router_mirror_request_ringing requestID=\(req.requestId, privacy: .public)")
        Self.debugTrace("router_mirror_request_ringing requestID=\(req.requestId)")
    }

    func handleMirrorStop(frame: HermesRealtimeRelayFrame, controlStreamID: UUID?) async {
        guard let stop = frame.media?.mirrorStop else {
            Self.log.error("router_mirror_stop_missing_payload requestID=\(frame.requestId ?? "", privacy: .public)")
            Self.debugTrace("router_mirror_stop_missing_payload requestID=\(frame.requestId ?? "")")
            return
        }
        guard activeMirrorSessionMatches(stop.sessionId),
              let activeViewer = viewer(matchingRequestID: stop.requestId),
              request(activeViewer, matchesClosedConnectionID: frame.connectionId, controlStreamID: controlStreamID) else {
            Self.log.info("router_mirror_stop_ignored requestID=\(stop.requestId, privacy: .public) phase_mismatch=true")
            Self.debugTrace("router_mirror_stop_ignored requestID=\(stop.requestId) phase=\(String(describing: phase))")
            return
        }
        _ = await removeActiveMirrorViewer(
            viewerID: activeViewer.viewerID,
            revokeRemoteUnlockSession: true
        )
        pendingRequest = nil
        await broadcastMirrorAck(
            decision: .accepted,
            detail: "Viewer left",
            availableDisplays: ScreenCapturePipeline.availableDisplays(),
            selectedDisplayId: activeSelectedDisplayID
        )
        Self.log.info("router_mirror_stop_completed requestID=\(stop.requestId, privacy: .public)")
        Self.debugTrace("router_mirror_stop_completed requestID=\(stop.requestId)")
    }
}

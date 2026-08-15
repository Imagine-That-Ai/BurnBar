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
            if let reason = await remoteUnlockMirrorDenialReason(
                request: req,
                session: remoteUnlockSession,
                remotePeerNodeID: remotePeerNodeID,
                uid: frame.uid,
                connectionID: frame.connectionId,
                consumeCounter: false
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
            agentTerminalApproved: false,
            autoAcceptedByMirrorGrant: false
        )

        let hasMirrorAutoAcceptGrant = consentStore.canAutoAccept(
            connectionId: frame.connectionId,
            viewerDeviceId: req.viewerDeviceId,
            controlAuthorityPeerNodeId: req.controlAuthorityPeerNodeId,
            remotePeerNodeId: remotePeerNodeID,
            now: clock()
        )

        // Consent fast-paths:
        // - normal unlocked mirrors require a per-peer expiring grant;
        // - locked Remote Unlock mirrors can use a signed trusted-device session.
        // Neither path stores or replays the user's Mac password.
        if (hasMirrorAutoAcceptGrant || remoteUnlockSession != nil) && !pending.requestsAgentTerminal {
            Self.log.info("router_mirror_request_auto_accept requestID=\(req.requestId, privacy: .public)")
            Self.debugTrace("router_mirror_request_auto_accept requestID=\(req.requestId)")
            await beginMirror(for: hasMirrorAutoAcceptGrant ? pending.markingMirrorGrantAutoAccepted() : pending)
            return
        }

        // Surface the ringing UI.
        pendingRequest = pending
        phase = .ringing(
            requestID: req.requestId,
            requesterName: req.requesterDisplayName,
            requestedAt: req.requestedAt
        )
        schedulePendingMirrorRequestExpiry(for: pending)
        Self.log.info("router_mirror_request_ringing requestID=\(req.requestId, privacy: .public)")
        Self.debugTrace("router_mirror_request_ringing requestID=\(req.requestId)")
    }

    private func schedulePendingMirrorRequestExpiry(for request: PendingRequest) {
        pendingMirrorRequestExpiryTask?.cancel()
        let timeoutNanoseconds = UInt64(pendingMirrorRequestTimeoutSeconds * 1_000_000_000)
        pendingMirrorRequestExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self,
                  self.claimPendingMirrorRequest(request, cancelExpiryTask: false) else {
                return
            }
            if self.activeMirrorViewers.isEmpty {
                self.phase = .idle
            } else {
                self.setStreamingPhaseIfNeeded()
            }
            await self.respond(
                requestID: request.id,
                decision: .denied,
                detail: "Mirror request expired",
                frame: request.frame,
                replySender: request.replySender
            )
            Self.log.info("router_mirror_request_expired requestID=\(request.id, privacy: .public)")
            Self.debugTrace("router_mirror_request_expired requestID=\(request.id)")
        }
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

    func handleMirrorDisplaySelect(
        frame: HermesRealtimeRelayFrame,
        controlStreamID: UUID?,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        guard let selection = frame.media?.mirrorDisplaySelection else { return }
        guard activeMirrorSessionMatches(selection.sessionId),
              let activeViewer = viewer(matchingRequestID: selection.requestId),
              request(activeViewer, matchesClosedConnectionID: frame.connectionId, controlStreamID: controlStreamID) else { return }
        guard activeViewer.viewerID == activeControlViewerID else {
            await respond(
                requestID: selection.requestId,
                decision: .denied,
                detail: "Another viewer owns Mac control",
                availableDisplays: ScreenCapturePipeline.availableDisplays(),
                selectedDisplayId: activeSelectedDisplayID,
                sessionID: activeViewer.sessionID,
                viewerID: activeViewer.viewerID,
                viewerRole: viewerRole(for: activeViewer.viewerID),
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: frame,
                replySender: replySender
            )
            return
        }
        let displays = ScreenCapturePipeline.availableDisplays()
        guard displays.contains(where: { $0.id == selection.displayId }) else {
            await respond(
                requestID: selection.requestId,
                decision: .unsupported,
                detail: "Display is no longer available",
                availableDisplays: displays,
                selectedDisplayId: displays.first?.id,
                sessionID: activeViewer.sessionID,
                viewerID: activeViewer.viewerID,
                viewerRole: viewerRole(for: activeViewer.viewerID),
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: frame,
                replySender: replySender
            )
            return
        }
        do {
            try await sessionCoordinator.switchScreenShareDisplay(displayId: selection.displayId)
            activeSelectedDisplayID = selection.displayId
            await broadcastMirrorAck(
                decision: .accepted,
                detail: "Display switched",
                availableDisplays: displays,
                selectedDisplayId: selection.displayId
            )
        } catch {
            await respond(
                requestID: selection.requestId,
                decision: .unsupported,
                detail: error.localizedDescription,
                availableDisplays: displays,
                selectedDisplayId: displays.first?.id,
                sessionID: activeViewer.sessionID,
                viewerID: activeViewer.viewerID,
                viewerRole: viewerRole(for: activeViewer.viewerID),
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: frame,
                replySender: replySender
            )
        }
    }

    func handleCallInvite(
        frame: HermesRealtimeRelayFrame,
        controlStreamID: UUID?,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        guard let invite = frame.media?.callInvite else {
            Self.log.error("router_call_invite_missing_payload requestID=\(frame.requestId ?? "", privacy: .public)")
            Self.debugTrace("router_call_invite_missing_payload requestID=\(frame.requestId ?? "")")
            return
        }
        Self.log.info("router_call_invite_received requestID=\(invite.requestId, privacy: .public) requester=\(invite.requesterDisplayName, privacy: .public)")
        Self.debugTrace("router_call_invite_received requestID=\(invite.requestId) requester=\(invite.requesterDisplayName)")

        if case .streaming = phase {
            await respondToCall(
                requestID: invite.requestId,
                decision: .busy,
                detail: "Another Mercury session is in progress",
                frame: frame,
                replySender: replySender
            )
            return
        }
        if case .starting = phase {
            await respondToCall(
                requestID: invite.requestId,
                decision: .busy,
                detail: "A Mercury session is starting",
                frame: frame,
                replySender: replySender
            )
            return
        }
        if case let .cooldown(remaining) = phase {
            await respondToCall(
                requestID: invite.requestId,
                decision: .busy,
                detail: "Cooling down for \(remaining)s",
                frame: frame,
                replySender: replySender
            )
            return
        }

        let pending = PendingRequest(
            id: invite.requestId,
            requesterName: invite.requesterDisplayName,
            requestedAt: invite.requestedAt,
            frame: frame,
            replySender: replySender,
            controlStreamID: controlStreamID,
            remotePeerNodeID: nil,
            agentTerminalApproved: false,
            autoAcceptedByMirrorGrant: false
        )
        pendingCall = pending
        phase = .callRinging(
            requestID: invite.requestId,
            requesterName: invite.requesterDisplayName,
            requestedAt: invite.requestedAt
        )
        Self.log.info("router_call_invite_ringing requestID=\(invite.requestId, privacy: .public)")
        Self.debugTrace("router_call_invite_ringing requestID=\(invite.requestId)")
    }

    func beginMirror(for request: PendingRequest) async {
        let wasJoiningExistingSession = !activeMirrorViewers.isEmpty
        if !wasJoiningExistingSession {
            phase = .starting(requestID: request.id)
        }
        pendingMirrorRequestExpiryTask?.cancel()
        pendingMirrorRequestExpiryTask = nil
        pendingRequest = nil
        guard let mirrorRequest = request.frame.media?.mirrorRequest else {
            await respond(
                requestID: request.id,
                decision: .unsupported,
                detail: "Malformed request payload",
                frame: request.frame,
                replySender: request.replySender
            )
            phase = .idle
            return
        }
        let remoteUnlockSession = remoteUnlockSessionForLockedMirror(mirrorRequest)
        if let remoteUnlockSession,
           let reason = await remoteUnlockMirrorDenialReason(
               request: mirrorRequest,
               session: remoteUnlockSession,
               remotePeerNodeID: request.remotePeerNodeID,
               uid: request.frame.uid,
               connectionID: request.frame.connectionId
           ) {
            let state = remoteUnlockReadiness.currentState(
                sessionId: remoteUnlockSession.sessionId,
                controlOwnerViewerId: nil
            )
            await respond(
                requestID: request.id,
                decision: .unsupported,
                detail: reason,
                viewerID: mirrorRequest.viewerId,
                remoteUnlockState: state,
                remoteUnlockCapabilities: state.capabilities,
                frame: request.frame,
                replySender: request.replySender
            )
            if activeMirrorViewers.isEmpty {
                phase = .idle
            } else {
                setStreamingPhaseIfNeeded()
            }
            return
        } else if let state = remoteUnlockSessionRequiredState(for: mirrorRequest) {
            await respond(
                requestID: request.id,
                decision: .unsupported,
                detail: Self.remoteUnlockSessionRequiredDetail,
                viewerID: mirrorRequest.viewerId,
                remoteUnlockState: state,
                remoteUnlockCapabilities: state.capabilities,
                frame: request.frame,
                replySender: request.replySender
            )
            if activeMirrorViewers.isEmpty {
                phase = .idle
            } else {
                setStreamingPhaseIfNeeded()
            }
            return
        }
        let viewerID = viewerID(for: mirrorRequest, frame: request.frame, controlStreamID: request.controlStreamID)
        let controlAuthorityPeerNodeID = mirrorRequest.controlAuthorityPeerNodeId?.nilIfEmptyForMercury
            ?? remoteUnlockSession?.authority.peerNodeId.nilIfEmptyForMercury
        guard activeMirrorViewers[viewerID] == nil else {
            await respond(
                requestID: request.id,
                decision: .busy,
                detail: "This viewer is already connected",
                sessionID: activeMirrorSessionID,
                viewerID: viewerID,
                viewerRole: viewerRole(for: viewerID),
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: request.frame,
                replySender: request.replySender
            )
            setStreamingPhaseIfNeeded()
            return
        }
        guard activeMirrorViewers.count < maxMirrorViewers else {
            await respond(
                requestID: request.id,
                decision: .busy,
                detail: "Mirror viewer limit reached",
                sessionID: activeMirrorSessionID,
                viewerID: viewerID,
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: request.frame,
                replySender: request.replySender
            )
            setStreamingPhaseIfNeeded()
            return
        }
        guard mirrorSinkFactory != nil else {
            Self.log.error("router_mirror_accept_unsupported_missing_sink requestID=\(request.id, privacy: .public)")
            Self.debugTrace("router_mirror_accept_unsupported_missing_sink requestID=\(request.id)")
            await respond(
                requestID: request.id,
                decision: .unsupported,
                detail: "Mac has no mirror transport configured",
                frame: request.frame,
                replySender: request.replySender
            )
            phase = .idle
            return
        }
        let sessionID = activeMirrorSessionID ?? UUID().uuidString
        do {
            let requestedFocusMode = mirrorRequest.focusFollowMode
                .flatMap(AgentFocusFollowMode.init(rawValue:))
            let focusMode = Self.effectiveFocusFollowMode(
                for: mirrorRequest,
                requestedMode: requestedFocusMode
            )
            let mediaFrameSealEstablished = try await resolvedMediaFrameSealEstablished(
                mirrorRequest: mirrorRequest,
                frame: request.frame
            )
            let viewer = ActiveMirrorViewer(
                viewerID: viewerID,
                requestID: request.id,
                sessionID: sessionID,
                requesterName: request.requesterName,
                joinedAt: clock(),
                frame: request.frame,
                replySender: request.replySender,
                controlStreamID: request.controlStreamID,
                viewerDeviceID: mirrorRequest.viewerDeviceId,
                controlAuthorityPeerNodeID: controlAuthorityPeerNodeID,
                remotePeerNodeID: request.remotePeerNodeID,
                remoteUnlockSessionID: remoteUnlockSession?.sessionId,
                agentTerminalApproved: request.agentTerminalApproved,
                mediaFrameSealEstablished: mediaFrameSealEstablished
            )

            addActiveMirrorViewer(viewer)
            if let remoteUnlockSession {
                remoteUnlockReadiness.recordRemoteUnlockSession(remoteUnlockSession, now: clock())
            }
            let displays = ScreenCapturePipeline.availableDisplays()
            activeSelectedDisplayID = activeSelectedDisplayID ?? displays.first?.id
            let remoteUnlockState = remoteUnlockSession.map {
                remoteUnlockReadiness.currentState(
                    sessionId: $0.sessionId,
                    controlOwnerViewerId: activeControlViewerID
                )
            }
            let waitingForRemoteUnlock = remoteUnlockSession != nil && remoteUnlockState?.lockState != .unlocked
            await respond(
                requestID: request.id,
                decision: .accepted,
                detail: nil,
                availableDisplays: displays,
                selectedDisplayId: activeSelectedDisplayID,
                sessionID: sessionID,
                viewerID: viewerID,
                viewerRole: viewerRole(for: viewerID),
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                remoteUnlockState: remoteUnlockState,
                remoteUnlockCapabilities: remoteUnlockState?.capabilities,
                mediaFrameSealEstablished: viewer.mediaFrameSealEstablished ? true : nil,
                frame: request.frame,
                replySender: request.replySender
            )
            // Auto-accepted sessions intentionally do NOT renew the grant:
            // remembered-peer grants live for a fixed TTL from the explicit
            // Accept, so an auto-accepting device must ring again once the
            // original grant expires (no sliding-window renewal).
            if waitingForRemoteUnlock {
                Self.log.info("router_locked_mirror_waiting_for_remote_unlock requestID=\(request.id, privacy: .public)")
                Self.debugTrace("router_locked_mirror_waiting_for_remote_unlock requestID=\(request.id)")
            } else {
                startAcceptedMirrorRuntime(for: viewer, focusMode: focusMode)
            }
            if wasJoiningExistingSession {
                await broadcastMirrorAck(
                    decision: .accepted,
                    detail: "Viewer roster updated",
                    availableDisplays: displays,
                    selectedDisplayId: activeSelectedDisplayID,
                    excludingViewerID: viewerID
                )
            }
            if !waitingForRemoteUnlock {
                await Task.yield()
            }
        } catch {
            lastError = error.localizedDescription
            Self.log.error("router_mirror_start_failed requestID=\(request.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("router_mirror_start_failed requestID=\(request.id) error=\(error.localizedDescription)")
            await respond(
                requestID: request.id,
                decision: .unsupported,
                detail: error.localizedDescription,
                sessionID: activeMirrorSessionID,
                viewerID: viewerID,
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                frame: request.frame,
                replySender: request.replySender
            )
            if activeMirrorViewers.isEmpty {
                phase = .idle
                clearAllActiveMirrorViewers()
            } else {
                setStreamingPhaseIfNeeded()
            }
        }
    }

}

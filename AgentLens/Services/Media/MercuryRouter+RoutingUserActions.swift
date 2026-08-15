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

    /// Claims the exact request currently shown in the approval panel.
    ///
    /// Clearing the request and cancelling its deadline are synchronous on the
    /// main actor, before any reply or mirror startup can suspend. This keeps a
    /// late Accept/Decline from racing an expiry task that already owns the
    /// request.
    @discardableResult
    func claimPendingMirrorRequest(
        _ request: PendingRequest,
        cancelExpiryTask: Bool = true
    ) -> Bool {
        guard let current = pendingRequest,
              current.id == request.id,
              current.frame.connectionId == request.frame.connectionId,
              current.controlStreamID == request.controlStreamID,
              case .ringing(let requestID, _, _) = phase,
              requestID == request.id else {
            return false
        }
        pendingRequest = nil
        if cancelExpiryTask {
            pendingMirrorRequestExpiryTask?.cancel()
        }
        pendingMirrorRequestExpiryTask = nil
        return true
    }

    /// User tapped "Accept" on the incoming-call sheet.
    func acceptMirror(_ request: PendingRequest) async {
        guard claimPendingMirrorRequest(request) else { return }
        await issuePhoneControlEnrollmentGrantIfNeeded(for: request)
        if let mirrorRequest = request.frame.media?.mirrorRequest {
            consentStore.rememberAcceptedPeer(
                connectionId: request.frame.connectionId,
                viewerDeviceId: mirrorRequest.viewerDeviceId,
                controlAuthorityPeerNodeId: mirrorRequest.controlAuthorityPeerNodeId,
                remotePeerNodeId: request.remotePeerNodeID,
                requesterName: request.requesterName
            )
        }
        await beginMirror(for: request)
    }

    func acceptMirrorWithAgentTerminal(_ request: PendingRequest) async {
        guard claimPendingMirrorRequest(request) else { return }
        await issuePhoneControlEnrollmentGrantIfNeeded(for: request)
        if let mirrorRequest = request.frame.media?.mirrorRequest {
            consentStore.rememberAcceptedPeer(
                connectionId: request.frame.connectionId,
                viewerDeviceId: mirrorRequest.viewerDeviceId,
                controlAuthorityPeerNodeId: mirrorRequest.controlAuthorityPeerNodeId,
                remotePeerNodeId: request.remotePeerNodeID,
                requesterName: request.requesterName
            )
        }
        await beginMirror(for: request.approvingAgentTerminal())
    }

    private func issuePhoneControlEnrollmentGrantIfNeeded(for request: PendingRequest) async {
        guard let phoneControlEnrollmentGrantIssuer,
              let mirrorRequest = request.frame.media?.mirrorRequest,
              let controllerDeviceID = mirrorRequest.viewerDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !controllerDeviceID.isEmpty,
              let controllerPeerNodeID = mirrorRequest.controlAuthorityPeerNodeId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !controllerPeerNodeID.isEmpty else {
            return
        }
        do {
            try await phoneControlEnrollmentGrantIssuer(
                request.frame.connectionId,
                controllerDeviceID,
                controllerPeerNodeID
            )
        } catch {
            lastError = "Mirror accepted, but phone control still needs device approval: \(error.localizedDescription)"
            Self.log.error(
                "router_phone_control_enrollment_grant_failed requestID=\(request.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            Self.debugTrace(
                "router_phone_control_enrollment_grant_failed requestID=\(request.id) error=\(error.localizedDescription)"
            )
        }
    }

    /// User tapped "Decline" on the incoming-call sheet.
    func declineMirror(_ request: PendingRequest) async {
        guard claimPendingMirrorRequest(request) else { return }
        await respond(
            requestID: request.id,
            decision: .denied,
            detail: "Declined by user",
            frame: request.frame,
            replySender: request.replySender
        )
        startCooldown(seconds: Int(cooldownSeconds))
    }

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
        pendingMirrorRequestExpiryTask?.cancel()
        pendingMirrorRequestExpiryTask = nil
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

}

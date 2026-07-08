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

    /// User tapped "Accept" on the incoming-call sheet.
    func acceptMirror(_ request: PendingRequest) async {
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

    /// User tapped "Decline" on the incoming-call sheet.
    func declineMirror(_ request: PendingRequest) async {
        await respond(
            requestID: request.id,
            decision: .denied,
            detail: "Declined by user",
            frame: request.frame,
            replySender: request.replySender
        )
        pendingRequest = nil
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

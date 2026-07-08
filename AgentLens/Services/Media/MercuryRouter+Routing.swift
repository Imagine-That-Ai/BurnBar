import Foundation
import Combine
import Darwin
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OSLog
import AppKit
import ImageIO

// MARK: - MercuryRouter routing, mirror, frame, viewer & remote-unlock logic
// Split out of MercuryRouter.swift to satisfy the Swift file-size budget.
extension MercuryRouter {

    func currentMirrorSessions() -> [ActiveMirrorViewer] {
        guard case .streaming = phase else { return [] }
        return activeMirrorViewOrder.compactMap { activeMirrorViewers[$0] }
    }

    var activeMirrorRequestIDForPhase: String? {
        if let activeControlViewerID,
           let requestID = activeMirrorViewers[activeControlViewerID]?.requestID {
            return requestID
        }
        return activeMirrorViewOrder.compactMap { activeMirrorViewers[$0]?.requestID }.first
            ?? activeSessionFrame?.media?.mirrorRequest?.requestId
    }

    func setStreamingPhaseIfNeeded() {
        guard let requestID = activeMirrorRequestIDForPhase else {
            phase = .idle
            return
        }
        switch phase {
        case .streaming(_, let since):
            phase = .streaming(requestID: requestID, since: since)
        default:
            phase = .streaming(requestID: requestID, since: clock())
        }
    }

    func updateLegacyActiveSessionPointer() {
        let viewer = activeControlViewerID.flatMap { activeMirrorViewers[$0] }
            ?? activeMirrorViewOrder.compactMap { activeMirrorViewers[$0] }.first
        activeSessionSender = viewer?.replySender
        activeSessionFrame = viewer?.frame
        activeSessionControlStreamID = viewer?.controlStreamID
    }

    func viewerRole(for viewerID: String) -> String {
        viewerID == activeControlViewerID ? "controller" : "watcher"
    }

    func viewerID(for request: HermesRealtimeRelayMirrorRequest, frame: HermesRealtimeRelayFrame, controlStreamID: UUID?) -> String {
        if let viewerId = request.viewerId, !viewerId.isEmpty { return viewerId }
        if let controlStreamID { return "legacy-\(controlStreamID.uuidString)" }
        return "legacy-\(frame.connectionId)"
    }

    func viewer(matchingRequestID requestID: String) -> ActiveMirrorViewer? {
        activeMirrorViewers.values.first { $0.requestID == requestID }
    }

    func viewer(
        matchingConnectionID connectionID: String,
        controlStreamID: UUID?
    ) -> ActiveMirrorViewer? {
        activeMirrorViewers.values.first { candidate in
            if let candidateControlStreamID = candidate.controlStreamID {
                return candidateControlStreamID == controlStreamID
            }
            return candidate.frame.connectionId == connectionID
        }
    }

    func viewer(matchingPeerIdentity request: HermesRealtimeRelayMirrorRequest) -> ActiveMirrorViewer? {
        if let authorityPeerNodeID = request.controlAuthorityPeerNodeId?.nilIfEmptyForMercury {
            return activeMirrorViewers.values.first {
                $0.controlAuthorityPeerNodeID?.nilIfEmptyForMercury == authorityPeerNodeID
            }
        }
        if let deviceID = request.viewerDeviceId?.nilIfEmptyForMercury {
            return activeMirrorViewers.values.first {
                $0.viewerDeviceID?.nilIfEmptyForMercury == deviceID
            }
        }
        return nil
    }

    func activeMirrorSessionMatches(_ sessionID: String?) -> Bool {
        guard let sessionID else { return true }
        return activeMirrorSessionID == nil || activeMirrorSessionID == sessionID
    }

    func addActiveMirrorViewer(_ viewer: ActiveMirrorViewer) {
        if activeMirrorSessionID == nil {
            activeMirrorSessionID = viewer.sessionID
        }
        activeMirrorViewers[viewer.viewerID] = viewer
        activeMirrorViewOrder.removeAll { $0 == viewer.viewerID }
        activeMirrorViewOrder.append(viewer.viewerID)
        if activeControlViewerID == nil {
            activeControlViewerID = viewer.viewerID
        }
        publishActiveMirrorViewerCount()
        updateLegacyActiveSessionPointer()
        setStreamingPhaseIfNeeded()
    }

    @discardableResult
    func removeActiveMirrorViewer(
        viewerID: String,
        revokeRemoteUnlockSession: Bool = false
    ) async -> ActiveMirrorViewer? {
        mirrorStartupTasks.removeValue(forKey: viewerID)?.cancel()
        mirrorStartupTaskIDs.removeValue(forKey: viewerID)
        guard let viewer = activeMirrorViewers.removeValue(forKey: viewerID) else { return nil }
        activeMirrorViewOrder.removeAll { $0 == viewerID }
        if let terminalSession = viewer.interactiveTerminalSession {
            InteractiveTerminalLauncher.terminate(terminalSession)
        }
        if revokeRemoteUnlockSession {
            remoteUnlockReadiness.revokeRemoteUnlockSession(sessionId: viewer.remoteUnlockSessionID)
        }
        await sessionCoordinator.detachScreenShareViewer(viewerID: viewerID)
        if activeControlViewerID == viewerID {
            activeControlViewerID = activeMirrorViewOrder.first
        }
        if activeMirrorViewers.isEmpty {
            activeMirrorSessionID = nil
            activeSelectedDisplayID = nil
            clearActiveSessionState()
            phase = .idle
        } else {
            updateLegacyActiveSessionPointer()
            setStreamingPhaseIfNeeded()
        }
        publishActiveMirrorViewerCount()
        return viewer
    }

    func clearAllActiveMirrorViewers() {
        mirrorStartupTasks.values.forEach { $0.cancel() }
        mirrorStartupTasks.removeAll()
        mirrorStartupTaskIDs.removeAll()
        activeMirrorSessionID = nil
        remoteUnlockReadiness.revokeAllRemoteUnlockSessions()
        activeMirrorViewers.values
            .compactMap(\.interactiveTerminalSession)
            .forEach(InteractiveTerminalLauncher.terminate)
        activeMirrorViewers.removeAll()
        activeMirrorViewOrder.removeAll()
        activeControlViewerID = nil
        activeSelectedDisplayID = nil
        clearActiveSessionState()
        publishActiveMirrorViewerCount()
    }

    func publishActiveMirrorViewerCount() {
        MacMediaActiveSessionRegistry.shared.setCount(activeMirrorViewers.count, for: .screenShare)
    }

    func broadcastMirrorAck(
        decision: HermesRealtimeRelayMirrorAck.Decision,
        detail: String?,
        availableDisplays: [HermesRealtimeRelayDisplayDescriptor]? = nil,
        selectedDisplayId: String? = nil,
        remoteUnlockState: HermesRealtimeRelayRemoteUnlockState? = nil,
        remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities? = nil,
        excludingViewerID: String? = nil
    ) async {
        for viewer in currentMirrorSessions() {
            if viewer.viewerID == excludingViewerID { continue }
            await respond(
                requestID: viewer.requestID,
                decision: decision,
                detail: detail,
                availableDisplays: availableDisplays,
                selectedDisplayId: selectedDisplayId,
                sessionID: viewer.sessionID,
                viewerID: viewer.viewerID,
                viewerRole: viewerRole(for: viewer.viewerID),
                viewerCount: activeMirrorViewers.count,
                maxViewers: maxMirrorViewers,
                controlOwnerViewerID: activeControlViewerID,
                remoteUnlockState: remoteUnlockState,
                remoteUnlockCapabilities: remoteUnlockCapabilities,
                frame: viewer.frame,
                replySender: viewer.replySender
            )
        }
    }

    /// Emits a Smart Zoom-enriched `focusContext` over the active
    /// mirror session. No-op when no session is streaming.
    func sendFocusContextOnActiveMirror(_ context: HermesRealtimeRelayFocusContext) async {
        for session in currentMirrorSessions() {
            let frame = HermesRealtimeRelayFrame(
                type: .mediaStreamFrame,
                uid: session.frame.uid,
                connectionId: session.frame.connectionId,
                media: HermesRealtimeRelayMediaPayload(
                    streamClass: MediaStreamClass.screenVideo.rawValue,
                    focusContext: context
                )
            )
            try? await session.replySender(frame) // try?-ok(best-effort enrichment send)
        }
    }

}

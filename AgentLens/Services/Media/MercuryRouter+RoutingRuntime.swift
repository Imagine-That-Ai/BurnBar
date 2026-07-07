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

    func startAcceptedMirrorRuntime(
        for viewer: ActiveMirrorViewer,
        focusMode: AgentFocusFollowMode
    ) {
        mirrorStartupTasks.removeValue(forKey: viewer.viewerID)?.cancel()
        let taskID = UUID()
        mirrorStartupTaskIDs[viewer.viewerID] = taskID
        mirrorStartupTasks[viewer.viewerID] = Task { @MainActor [weak self] in
            await self?.runAcceptedMirrorRuntime(for: viewer, focusMode: focusMode, taskID: taskID)
        }
    }

    func runAcceptedMirrorRuntime(
        for viewer: ActiveMirrorViewer,
        focusMode: AgentFocusFollowMode,
        taskID: UUID
    ) async {
        defer {
            if mirrorStartupTaskIDs[viewer.viewerID] == taskID {
                mirrorStartupTasks.removeValue(forKey: viewer.viewerID)
                mirrorStartupTaskIDs.removeValue(forKey: viewer.viewerID)
            }
        }
        guard activeMirrorViewers[viewer.viewerID]?.requestID == viewer.requestID else { return }
        do {
            if let remoteUnlockSessionID = viewer.remoteUnlockSessionID {
                let state = remoteUnlockReadiness.currentState(
                    sessionId: remoteUnlockSessionID,
                    controlOwnerViewerId: activeControlViewerID
                )
                if state.lockState != .unlocked {
                    return
                }
            }

            // Phase 12 — interactive single-window CLI. Launch the agent's CLI
            // in a visible Terminal first so we can pin the capture to just that
            // window (no `controlSurfaceFrame`/focus-follow dependency, so this
            // works in the sandboxed MAS build too).
            let terminalSession = await launchInteractiveTerminalIfRequested(for: viewer)

            try await startNormalCapture(for: viewer)
            guard activeMirrorViewers[viewer.viewerID]?.requestID == viewer.requestID else { return }

            // Pin the mirror to just the launched Terminal window. If the window
            // could not be resolved we leave the full-display capture in place.
            if let windowID = terminalSession?.windowID {
                do {
                    try await sessionCoordinator.switchScreenShareTarget(displayId: nil, windowID: windowID)
                } catch {
                    Self.log.error("router_interactive_terminal_pin_failed requestID=\(viewer.requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

            if activeControlViewerID == viewer.viewerID {
                do {
                    applyFocusFollowMode?(focusMode)
                    if let ensureComputerUseSession {
                        try await ensureComputerUseSession()
                    }
                } catch {
                    lastError = "Mirror is read-only: \(error.localizedDescription)"
                    Self.log.error("router_computer_use_session_failed requestID=\(viewer.requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    Self.debugTrace("router_computer_use_session_failed requestID=\(viewer.requestID) error=\(error.localizedDescription)")
                }
            }
        } catch {
            await failAcceptedMirrorRuntime(for: viewer, error: error)
        }
    }

    /// Phase 12 — when the viewer's request carries an interactive `agentTerminal`
    /// payload, launch that runtime's CLI in a visible Terminal and remember the
    /// session on the viewer so it is terminated on teardown. Returns the
    /// launched session (with its resolved `CGWindowID`) or `nil`.
    func launchInteractiveTerminalIfRequested(
        for viewer: ActiveMirrorViewer
    ) async -> LaunchedAgentTerminalSession? {
        guard let request = viewer.frame.media?.mirrorRequest?.agentTerminal,
              request.interactive,
              viewer.agentTerminalApproved,
              !request.runtimeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        do {
            let workingDirectory = request.workingDirectory
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            let session = try await InteractiveTerminalLauncher.launchInteractive(
                runtimeId: request.runtimeId,
                workingDirectory: workingDirectory,
                modelID: request.modelID
            )
            // The viewer may have disconnected while the Terminal was opening.
            guard activeMirrorViewers[viewer.viewerID]?.requestID == viewer.requestID else {
                InteractiveTerminalLauncher.terminate(session)
                return nil
            }
            activeMirrorViewers[viewer.viewerID]?.interactiveTerminalSession = session
            Self.log.info("router_interactive_terminal_launched runtime=\(request.runtimeId, privacy: .public) hasWindow=\(session.windowID != nil, privacy: .public)")
            return session
        } catch {
            Self.log.error("router_interactive_terminal_launch_failed runtime=\(request.runtimeId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            lastError = "Could not open \(request.runtimeId) in Terminal on your Mac: \(error.localizedDescription)"
            return nil
        }
    }

    func failAcceptedMirrorRuntime(
        for viewer: ActiveMirrorViewer,
        error: Error
    ) async {
        guard activeMirrorViewers[viewer.viewerID]?.requestID == viewer.requestID else { return }
        lastError = error.localizedDescription
        Self.log.error("router_mirror_runtime_failed requestID=\(viewer.requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        Self.debugTrace("router_mirror_runtime_failed requestID=\(viewer.requestID) error=\(error.localizedDescription)")
        _ = await removeActiveMirrorViewer(viewerID: viewer.viewerID)
        await respond(
            requestID: viewer.requestID,
            decision: .unsupported,
            detail: error.localizedDescription,
            sessionID: viewer.sessionID,
            viewerID: viewer.viewerID,
            viewerRole: viewerRole(for: viewer.viewerID),
            viewerCount: activeMirrorViewers.count,
            maxViewers: maxMirrorViewers,
            controlOwnerViewerID: activeControlViewerID,
            frame: viewer.frame,
            replySender: viewer.replySender
        )
    }

    func request(
        _ request: PendingRequest,
        matchesClosedConnectionID connectionID: String,
        controlStreamID: UUID?
    ) -> Bool {
        if let requestControlStreamID = request.controlStreamID {
            return requestControlStreamID == controlStreamID
        }
        return request.frame.connectionId == connectionID
    }

    func request(
        _ viewer: ActiveMirrorViewer,
        matchesClosedConnectionID connectionID: String,
        controlStreamID: UUID?
    ) -> Bool {
        if let requestControlStreamID = viewer.controlStreamID {
            return requestControlStreamID == controlStreamID
        }
        return viewer.frame.connectionId == connectionID
    }

    func activeSessionMatches(connectionID: String, controlStreamID: UUID?) -> Bool {
        guard let activeSessionFrame else { return false }
        if let activeSessionControlStreamID {
            return activeSessionControlStreamID == controlStreamID
        }
        return activeSessionFrame.connectionId == connectionID
    }

    func activeSessionAcceptsExplicitControlFrame(connectionID: String, controlStreamID: UUID?) -> Bool {
        guard let activeSessionFrame else { return false }
        if let activeSessionControlStreamID {
            guard let controlStreamID else { return false }
            return activeSessionControlStreamID == controlStreamID
        }
        if controlStreamID != nil {
            return activeSessionFrame.connectionId == connectionID
        }
        return true
    }

    func isActiveMirrorRequest(_ request: PendingRequest) -> Bool {
        activeSessionMatches(
            connectionID: request.frame.connectionId,
            controlStreamID: request.controlStreamID
        )
            && activeSessionFrame?.media?.mirrorRequest?.requestId == request.id
    }

    func clearActiveSessionState() {
        activeSessionSender = nil
        activeSessionFrame = nil
        activeSessionControlStreamID = nil
    }

    func respond(
        requestID: String,
        decision: HermesRealtimeRelayMirrorAck.Decision,
        detail: String?,
        cooldownSecondsRemaining: Int? = nil,
        availableDisplays: [HermesRealtimeRelayDisplayDescriptor]? = nil,
        selectedDisplayId: String? = nil,
        sessionID: String? = nil,
        viewerID: String? = nil,
        viewerRole: String? = nil,
        viewerCount: Int? = nil,
        maxViewers: Int? = nil,
        controlOwnerViewerID: String? = nil,
        remoteUnlockState: HermesRealtimeRelayRemoteUnlockState? = nil,
        remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities? = nil,
        mediaFrameSealEstablished: Bool? = nil,
        frame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        let capabilities = remoteUnlockCapabilities ?? remoteUnlockReadiness.capabilities()
        let state = remoteUnlockState ?? remoteUnlockReadiness.currentState(
            sessionId: nil,
            controlOwnerViewerId: controlOwnerViewerID
        )
        let ack = HermesRealtimeRelayMirrorAck(
            requestId: requestID,
            decision: decision,
            detail: detail,
            cooldownSecondsRemaining: cooldownSecondsRemaining,
            availableDisplays: availableDisplays,
            selectedDisplayId: selectedDisplayId,
            sessionId: sessionID,
            viewerId: viewerID,
            viewerRole: viewerRole,
            viewerCount: viewerCount,
            maxViewers: maxViewers,
            controlOwnerViewerId: controlOwnerViewerID,
            remoteUnlockState: state,
            remoteUnlockCapabilities: capabilities,
            // F7: advertise the Mac's snapshot in the ack itself so the viewer
            // negotiates codec/wire-version/frame-AEAD without a second probe.
            streamingCapabilities: localStreamingCapabilityProvider().wireValue,
            mediaFrameSealEstablished: decision == .accepted ? mediaFrameSealEstablished : nil
        )
        let outbound = HermesRealtimeRelayFrame(
            type: .mediaMirrorAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorAck: ack)
        )
        do {
            try await replySender(outbound)
            Self.log.info("router_mirror_ack_sent requestID=\(requestID, privacy: .public) decision=\(decision.rawValue, privacy: .public)")
            Self.debugTrace("router_mirror_ack_sent requestID=\(requestID) decision=\(decision.rawValue)")
        } catch {
            Self.log.error("router_mirror_ack_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("router_mirror_ack_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
        }
    }

    func respondToCall(
        requestID: String,
        decision: HermesRealtimeRelayCallAck.Decision,
        detail: String?,
        frame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        let ack = HermesRealtimeRelayCallAck(
            requestId: requestID,
            decision: decision,
            detail: detail
        )
        let outbound = HermesRealtimeRelayFrame(
            type: .mediaCallAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(callAck: ack)
        )
        do {
            try await replySender(outbound)
            Self.log.info("router_call_ack_sent requestID=\(requestID, privacy: .public) decision=\(decision.rawValue, privacy: .public)")
            Self.debugTrace("router_call_ack_sent requestID=\(requestID) decision=\(decision.rawValue)")
        } catch {
            Self.log.error("router_call_ack_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("router_call_ack_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
        }
    }

    func startCooldown(seconds: Int) {
        cooldownTask?.cancel()
        var remaining = seconds
        phase = .cooldown(secondsRemaining: remaining)
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // try?-ok(sleep cancellation only)
                remaining -= 1
                if Task.isCancelled { return }
                if remaining > 0 {
                    self?.phase = .cooldown(secondsRemaining: remaining)
                } else {
                    self?.phase = .idle
                }
            }
        }
    }

    func getBlurredWallpaperBase64() -> String? {
        var wallpaperURL: URL?
        if let screen = NSScreen.main {
            wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen)
        }

        if wallpaperURL == nil {
            let fileManager = FileManager.default
            let desktopPicturesDir = "/Library/Caches/Desktop Pictures"
            if fileManager.fileExists(atPath: desktopPicturesDir) {
                if let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: desktopPicturesDir), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.pathExtension.lowercased() == "png" || fileURL.pathExtension.lowercased() == "jpg" || fileURL.pathExtension.lowercased() == "jpeg" {
                            wallpaperURL = fileURL
                            break
                        }
                    }
                }
            }
        }

        guard let url = wallpaperURL else {
            return nil
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            return nil
        }

        return jpegData.base64EncodedString()
    }
}

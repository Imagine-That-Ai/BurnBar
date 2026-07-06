import SwiftUI
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import FirebaseAuth
@preconcurrency import FirebaseFirestore
import LocalAuthentication
import OSLog
import Security
#if canImport(UIKit)
import UIKit
#endif

// Mirror request/teardown lifecycle, display selection, intent dispatch, call, and file-pick handlers.
// Extracted from MercuryLiveSheet.swift (god-type decomposition) — same module, same isolation, verbatim.

extension MercuryLiveSheet {

    func installAckHandler() {
        controlStreamCoordinator.mirrorAckHandler = { ack in
            await MainActor.run {
                let isRemoteUnlockMirrorRequest = self.remoteUnlockMirrorRequestIDs.remove(ack.requestId) != nil
                self.lastAck = ack
                self.lastAckReceivedAt = Date()
                if let state = ack.remoteUnlockState ?? self.synthesizedRemoteUnlockState(for: ack, isRemoteUnlockMirrorRequest: isRemoteUnlockMirrorRequest) {
                    self.setRemoteUnlockState(state)
                }
                self.refreshSavedCredentialAvailability()
                self.cooldownClock = Date()
                if ack.requestId == self.awaitingRequestID {
                    self.mirrorTimeoutTask?.cancel()
                    self.mirrorTimeoutTask = nil
                    self.awaitingRequestID = nil
                }
                if ack.decision == .unsupported,
                   ack.detail == Self.remoteUnlockSessionRequiredDetail {
                    self.lastAck = nil
                    self.lastError = nil
                    Task {
                        await self.requestMirror(forceRemoteUnlockSession: true)
                    }
                    return
                }
                if ack.requestId == self.activeMirrorRequestID || ack.requestId == self.awaitingRequestID {
                    self.activeMirrorSessionId = ack.sessionId ?? self.activeMirrorSessionId
                    self.activeMirrorViewerId = ack.viewerId ?? self.activeMirrorViewerId
                    self.activeMirrorViewerRole = ack.viewerRole ?? self.activeMirrorViewerRole
                }
                let isActiveDisplaySelectionAck = ack.requestId == self.activeMirrorRequestID
                    && (ack.availableDisplays != nil || ack.selectedDisplayId != nil)

                if ack.decision == .accepted {
                    if isActiveDisplaySelectionAck {
                        self.selectedMirrorDisplayId = ack.selectedDisplayId ?? self.selectedMirrorDisplayId
                        self.activeMirrorSessionId = ack.sessionId ?? self.activeMirrorSessionId
                        self.activeMirrorViewerId = ack.viewerId ?? self.activeMirrorViewerId
                        self.activeMirrorViewerRole = ack.viewerRole ?? self.activeMirrorViewerRole
                        self.lastError = nil
                        self.refreshCooldownTicker(for: ack)
                        return
                    }
                    if self.activeMirrorRequestID != ack.requestId {
                        self.screenShareViewer.resetForNewMirror()
                    }
                    self.activeMirrorRequestID = ack.requestId
                    self.activeMirrorSessionId = ack.sessionId
                    self.activeMirrorViewerId = ack.viewerId
                    self.activeMirrorViewerRole = ack.viewerRole ?? "controller"
                    self.selectedMirrorDisplayId = ack.selectedDisplayId ?? ack.availableDisplays?.first?.id ?? self.selectedMirrorDisplayId
                    self.isShowingMirrorViewer = true
                    if isRemoteUnlockMirrorRequest,
                       self.remoteUnlockState == nil,
                       let state = self.synthesizedRemoteUnlockState(for: ack, isRemoteUnlockMirrorRequest: true) {
                        self.setRemoteUnlockState(state)
                    }
                    Task { await self.startPhoneControlIfPossible(surfaceError: false) }
                } else if ack.requestId == self.activeMirrorRequestID {
                    if isActiveDisplaySelectionAck {
                        self.selectedMirrorDisplayId = ack.selectedDisplayId ?? self.selectedMirrorDisplayId
                        self.lastError = ack.detail ?? "Could not switch displays."
                        self.refreshCooldownTicker(for: ack)
                        return
                    }
                    self.activeMirrorRequestID = nil
                    self.activeMirrorSessionId = nil
                    self.activeMirrorViewerId = nil
                    self.activeMirrorViewerRole = nil
                    self.selectedMirrorDisplayId = nil
                    self.isShowingMirrorViewer = false
                    // Mirror rejected — keep the singleton's Computer
                    // Use bi-stream alive; it is shared with other
                    // surfaces and will be reused on the next mirror.
                }
                self.refreshCooldownTicker(for: ack)
            }
        }
        controlStreamCoordinator.mirrorFrameHandler = { frame in
            await screenShareViewer.ingest(frame: frame)
        }
        controlStreamCoordinator.mirrorFrameV2Handler = { frame in
            await screenShareViewer.ingest(frameV2: frame)
        }
        controlStreamCoordinator.focusContextHandler = { context in
            await MainActor.run {
                screenShareViewer.ingest(focusContext: context)
            }
        }
        controlStreamCoordinator.controlDeniedHandler = { denied in
            await MainActor.run {
                switch denied.reason {
                case .signatureFailure, .counterReplay, .staleTimestamp:
                    // Tear down the stale sender. The most common cause is
                    // the Mac losing the peer registration (restart) or the
                    // authority key doc expiring. Re-publishing the key and
                    // restarting phone control re-establishes a clean
                    // handshake so the next gesture works transparently.
                    self.phoneControlSender = nil
                    self.phoneControlConnectionID = nil
                    self.authorityRefreshTask?.cancel()
                    Self.debugTrace("phone_control_denied_auto_recover reason=\(denied.reason.rawValue) connectionID=\(self.connectionID)")
                    Task {
                        await self.startPhoneControlIfPossible(surfaceError: false)
                    }
                default:
                    self.phoneControlError = self.phoneControlDeniedMessage(for: denied)
                }
            }
        }
        controlStreamCoordinator.callAckHandler = { ack in
            await MainActor.run {
                guard ack.requestId == self.pendingCallRequestID else { return }
                self.callTimeoutTask?.cancel()
                self.callTimeoutTask = nil
                self.pendingCallRequestID = nil
                self.lastCallAck = ack
                self.lastError = nil
                self.personalization.haptics.play()
            }
        }
        controlStreamCoordinator.clipboardResponseHandler = { response in
            await MainActor.run {
                self.handleClipboardResponse(response)
            }
        }
        controlStreamCoordinator.remoteUnlockStateHandler = { state in
            await MainActor.run {
                if state.lockState != .unlocked {
                    self.controlStreamCoordinator.suspendBackgroundTraffic(
                        for: RemoteUnlockPolicy.default.sessionTTLSeconds
                    )
                } else {
                    self.pendingRemoteUnlockCredentialRequestID = nil
                    self.remoteUnlockCredentialAckTimeoutTask?.cancel()
                    self.remoteUnlockCredentialAckTimeoutTask = nil
                    self.remoteUnlockPasswordDraft = ""
                    self.phoneControlError = nil
                    self.remoteUnlockResult = nil
                }
                self.setRemoteUnlockState(state)
                self.refreshSavedCredentialAvailability()
            }
        }
        controlStreamCoordinator.remoteUnlockResultHandler = { result in
            await MainActor.run {
                self.remoteUnlockResult = result
                if result.requestId == self.pendingRemoteUnlockCredentialRequestID ||
                    (self.pendingRemoteUnlockCredentialRequestID != nil && result.sessionId == self.activeMirrorSessionId) {
                    self.pendingRemoteUnlockCredentialRequestID = nil
                    self.remoteUnlockCredentialAckTimeoutTask?.cancel()
                    self.remoteUnlockCredentialAckTimeoutTask = nil
                }
                switch result.status {
                case .unlocked:
                    self.clearRemoteUnlockState()
                    self.phoneControlError = nil
                    self.remoteUnlockDiagnosticMessage = "credential result: unlocked"
                case .denied, .failed, .expired:
                    let detail = result.detail ?? "Remote Unlock was denied."
                    self.phoneControlError = self.remoteUnlockMessage(for: detail)
                    self.remoteUnlockDiagnosticMessage = "credential result: \(detail)"
                    if self.shouldRefreshRemoteUnlockSession(after: detail) {
                        self.phoneControlSender = nil
                        self.phoneControlConnectionID = nil
                        self.clearRemoteUnlockState()
                        self.lastAck = nil
                        Task {
                            await self.refreshRemoteUnlockSessionAfterCredentialRejection()
                        }
                    }
                case .accepted:
                    let detail = result.detail ?? "credential_submitted"
                    self.phoneControlError = self.remoteUnlockMessage(for: detail)
                    self.remoteUnlockDiagnosticMessage = "credential result: \(detail)"
                case .disconnected:
                    break
                }
                if result.status == .unlocked ||
                    (result.status == .accepted && result.detail != "credential_received") {
                    self.remoteUnlockPasswordDraft = ""
                }
            }
        }
        screenShareViewer.longTermReferenceTokenHandler = { token in
            try? await controlStreamCoordinator.sendLongTermReferenceAcknowledgement(
                token: token,
                requestId: activeMirrorRequestID
            )
        }
    }

    func handleSendTapIntent(x: Double, y: Double, mouseButton: Int) {
        let displayId = selectedMirrorDisplayId ?? lastAck?.selectedDisplayId
        Task { await sendPhoneControlIntent(kind: .tap, displayId: displayId, normalizedX: x, normalizedY: y, mouseButton: mouseButton) }
    }

    func handleSendScrollIntent(x1: Double, y1: Double, x2: Double, y2: Double, displayId: String?) {
        Task {
            await sendPhoneControlIntent(
                kind: .scroll,
                displayId: displayId ?? selectedMirrorDisplayId ?? lastAck?.selectedDisplayId,
                normalizedX: x1,
                normalizedY: y1,
                normalizedX2: x2,
                normalizedY2: y2
            )
        }
    }

    func handleSendPointerMoveIntent(dx: Double, dy: Double) {
        Task { await sendPhoneControlIntent(kind: .pointerMove, normalizedX2: dx, normalizedY2: dy) }
    }

    func handleSendPointerClickIntent(mouseButton: Int) {
        Task { await sendPhoneControlIntent(kind: .pointerClick, mouseButton: mouseButton) }
    }

    func handleSendTextIntent(text: String) {
        Task { await sendPhoneControlIntent(kind: .type, text: text) }
    }

    func handleSendShortcutIntent(key: String, modifiers: [String]) {
        Task { await sendPhoneControlIntent(kind: .shortcut, key: key, modifiers: modifiers) }
    }

    func handleSendAgentContextTargetIntent(x: Double, y: Double, instruction: String, runtime: String, clientIntentId: String?) {
        Task {
            await sendPhoneControlContextTarget(
                normalizedX: x,
                normalizedY: y,
                instruction: instruction,
                runtime: runtime,
                threadId: nil
            )
        }
    }

    func handlePasteClipboardToMac() {
        Task { await sendClipboardRequest(action: .pasteToMac) }
    }

    func handleGrabClipboardFromMac() {
        Task { await sendClipboardRequest(action: .grabFromMac) }
    }

    func handleSendRemoteUnlockCredential(password: String) {
        Task { await sendRemoteUnlockCredential(password: password) }
    }

    func handleSaveRemoteUnlockCredential(password: String) {
        Task { await saveRemoteUnlockCredential(password: password) }
    }

    func handleSendSavedRemoteUnlockCredential() {
        Task { await sendSavedRemoteUnlockCredential() }
    }

    func handleDeleteSavedRemoteUnlockCredential() {
        deleteSavedRemoteUnlockCredential()
    }

    func handleTrustControlDevice() {
        Task { await trustThisIPhoneForControl() }
    }

    func handleForceReconnect() {
        Task {
            await controlStreamCoordinator.stop()
            if let uid = uidProvider() {
                controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
            }
        }
    }

    func handleRetryRequest() {
        Task {
            if remoteUnlockState != nil || lastLockedRemoteUnlockState != nil || lastAck?.remoteUnlockState != nil {
                await requestMirror(forceRemoteUnlockSession: true)
            } else {
                await requestMirror()
            }
        }
    }

    func handleClose() {
        isShowingMirrorViewer = false
        Task { await stopActiveMirror(reason: "viewer_closed") }
    }

    func reinstallMirrorSurfaceAfterReturn() {
        installAckHandler()
        guard let uid = uidProvider(), !uid.isEmpty else { return }
        guard activeMirrorRequestID != nil || isShowingMirrorViewer else { return }
        Task {
            do {
                try await controlStreamCoordinator.ensureResponsive(
                    uid: uid,
                    connectionID: connectionID,
                    freshnessInterval: 2.0,
                    probeTimeout: 2.5,
                    restartTimeout: 6.0
                )
                await startPhoneControlIfPossible(surfaceError: false)
            } catch {
                await MainActor.run {
                    phoneControlSender = nil
                    phoneControlConnectionID = nil
                    lastError = "Reconnected to the viewer; tap Retry if frames do not resume. \(error.localizedDescription)"
                }
            }
        }
    }

    func requestMirror(
        forceRemoteUnlockSession: Bool = false,
        retryingAfterControlStreamRefresh: Bool = false
    ) async {
        guard let uid = uidProvider(), !uid.isEmpty else {
            lastError = "Sign in to mirror your Mac."
            return
        }
        guard canRequestMirror else {
            lastError = mercuryStatusMessage ?? "Mercury is not ready yet."
            return
        }
        if controlStreamCoordinator.phase != .live {
            await controlStreamCoordinator.stop()
            controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
        }
        controlStreamCoordinator.suspendBackgroundTraffic(for: 30)
        if !retryingAfterControlStreamRefresh {
            personalization.haptics.play()
        }
        let requestID = UUID().uuidString
        let viewerID = UUID().uuidString
        let remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession?
        let controlAuthorityPeerNodeId: String?
        if forceRemoteUnlockSession {
            guard peer.capabilities.contains(.remoteUnlockHost)
                    || remoteUnlockState?.capabilities.enabled == true
                    || lastAck?.remoteUnlockCapabilities?.enabled == true else {
                lastError = "Remote Unlock is not ready on this Mac."
                return
            }
            do {
                let prepared = try await makeRemoteUnlockSession(uid: uid, requestID: requestID)
                remoteUnlockSession = prepared.session
                controlAuthorityPeerNodeId = prepared.peerNodeId
            } catch {
                lastError = "Remote Unlock needs Face ID, Touch ID, or passcode confirmation."
                awaitingRequestID = nil
                return
            }
            remoteUnlockMirrorRequestIDs.insert(requestID)
        } else {
            remoteUnlockSession = nil
            if let signingIdentity = try? PhoneControlSigningKeyStore.shared.signingIdentity() {
                controlAuthorityPeerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingIdentity)
            } else {
                controlAuthorityPeerNodeId = nil
            }
        }
        awaitingRequestID = requestID
        activeMirrorRequestID = nil
        activeMirrorSessionId = nil
        activeMirrorViewerId = viewerID
        activeMirrorViewerRole = nil
        selectedMirrorDisplayId = nil
        phoneControlError = nil
        lastError = nil
        lastAck = nil
        lastAckReceivedAt = nil
        if forceRemoteUnlockSession {
            remoteUnlockState = remoteUnlockState ?? lastLockedRemoteUnlockState
        } else {
            clearRemoteUnlockState()
        }
        remoteUnlockResult = nil
        screenShareViewer.resetForNewMirror()
        // Don't tear down the app-scope phone control coordinator on
        // every mirror request — it stays warm and is reused for tap /
        // scroll input once the Mac approves the mirror. Also do not
        // gate mirror requests behind a separate heartbeat proof: while
        // macOS is at loginwindow, the mirror request is the handshake
        // that asks the Mac for the Remote Unlock lane, and a preflight
        // heartbeat can wedge before the Mac ever sees that request.
        cooldownTickerTask?.cancel()
        cooldownTickerTask = nil
        // F7: wrap a per-mirror frame key when the flag is on and the Mac
        // advertised media_frame_aead_v1. If that negotiated setup fails,
        // stop before sending instead of downgrading to an unsealed request.
        let mediaSealSession: MediaSealSessionEstablisher.Session?
        do {
            mediaSealSession = try await MediaSealSessionEstablisher.establishIfNegotiated(
                uid: uid,
                connectionID: connectionID,
                viewerId: viewerID,
                macCapabilities: controlStreamCoordinator.latestMacPresenceCapabilities,
                macRelayPublicKeyBase64: HermesService.shared.selectedConnection.relayPublicKey
            )
        } catch {
            controlStreamCoordinator.mediaFrameSealKey = nil
            awaitingRequestID = nil
            activeMirrorViewerId = nil
            lastError = error.localizedDescription
            return
        }
        controlStreamCoordinator.mediaFrameSealKey = mediaSealSession?.key
        let request = HermesRealtimeRelayMirrorRequest(
            requestId: requestID,
            requestedAt: Date(),
            requesterDisplayName: deviceDisplayName(),
            streamClass: MediaStreamClass.screenVideo.rawValue,
            streamingCapabilities: MercuryVideoToolboxCapabilityProbe.snapshot(
                mediaFrameVersions: .v1AndV2
            ).wireValue,
            focusFollowMode: AgentFocusFollowMode.off.rawValue,
            viewerId: viewerID,
            viewerDeviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
            controlAuthorityPeerNodeId: controlAuthorityPeerNodeId,
            remoteUnlockSession: remoteUnlockSession,
            agentTerminal: terminalRuntime.map {
                HermesRealtimeRelayAgentTerminalRequest(runtimeId: $0, interactive: true)
            },
            mediaSealKey: mediaSealSession?.envelope
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: request)
        )
        do {
            Self.log.info("mirror_request_send requestID=\(requestID, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("mirror_request_send requestID=\(requestID) connectionID=\(connectionID)")
            try await controlStreamCoordinator.send(frame: frame)
            Self.log.info("mirror_request_sent requestID=\(requestID, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            Self.debugTrace("mirror_request_sent requestID=\(requestID) connectionID=\(connectionID)")
            startMirrorAckTimeout(
                requestID: requestID,
                forceRemoteUnlockSession: forceRemoteUnlockSession,
                retryingAfterControlStreamRefresh: retryingAfterControlStreamRefresh
            )
        } catch {
            Self.log.error("mirror_request_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mirror_request_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
            if !retryingAfterControlStreamRefresh,
               shouldRetryMirrorRequestAfterRefreshingControlStream(error) {
                Self.log.info("mirror_request_retry_after_control_stream_refresh requestID=\(requestID, privacy: .public) connectionID=\(connectionID, privacy: .public)")
                Self.debugTrace("mirror_request_retry_after_control_stream_refresh requestID=\(requestID) connectionID=\(connectionID)")
                awaitingRequestID = nil
                await controlStreamCoordinator.stop()
                controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await requestMirror(
                    forceRemoteUnlockSession: forceRemoteUnlockSession,
                    retryingAfterControlStreamRefresh: true
                )
                return
            }
            lastError = error.localizedDescription
            awaitingRequestID = nil
        }
    }

    func startMirrorAckTimeout(
        requestID: String,
        forceRemoteUnlockSession: Bool,
        retryingAfterControlStreamRefresh: Bool
    ) {
        mirrorTimeoutTask?.cancel()
        mirrorTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, awaitingRequestID == requestID else { return }
            awaitingRequestID = nil
            if let uid = uidProvider(), !uid.isEmpty {
                await controlStreamCoordinator.stop()
                controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
            }
            guard !retryingAfterControlStreamRefresh else {
                lastError = "No response from the Mac. Mercury reconnected; try Mirror Mac again."
                return
            }
            lastError = "No response from the Mac. Mercury reconnected and retried the mirror request."
            try? await Task.sleep(nanoseconds: 250_000_000)
            await requestMirror(
                forceRemoteUnlockSession: forceRemoteUnlockSession,
                retryingAfterControlStreamRefresh: true
            )
        }
    }

    func stopActiveMirror(reason: String) async {
        guard uidProvider()?.isEmpty == false else {
            activeMirrorRequestID = nil
            activeMirrorSessionId = nil
            activeMirrorViewerId = nil
            activeMirrorViewerRole = nil
            selectedMirrorDisplayId = nil
            isShowingMirrorViewer = false
            // Phone control coordinator is app-scope; do not stop it.
            return
        }
        guard let requestID = activeMirrorRequestID else { return }
        let sessionID = activeMirrorSessionId
        activeMirrorRequestID = nil
        activeMirrorSessionId = nil
        activeMirrorViewerId = nil
        activeMirrorViewerRole = nil
        selectedMirrorDisplayId = nil
        isShowingMirrorViewer = false
        lastAck = nil
        lastAckReceivedAt = nil
        cooldownTickerTask?.cancel()
        cooldownTickerTask = nil
        // Phone control coordinator is app-scope; do not stop it.
        do {
            try await controlStreamCoordinator.sendMirrorStop(
                requestId: requestID,
                sessionId: sessionID,
                reason: reason,
                timeout: 2
            )
        } catch {
            Self.log.error("mirror_stop_send_failed requestID=\(requestID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("mirror_stop_send_failed requestID=\(requestID) error=\(error.localizedDescription)")
        }
    }

    func selectMirrorDisplay(_ displayId: String) {
        let previousDisplayId = selectedMirrorDisplayId
        selectedMirrorDisplayId = displayId
        guard let uid = uidProvider(), !uid.isEmpty,
              let requestID = activeMirrorRequestID,
              activeMirrorViewerRole == "controller" else {
            selectedMirrorDisplayId = previousDisplayId
            lastError = "Another device controls display switching."
            return
        }
        lastError = nil
        let selection = HermesRealtimeRelayMirrorDisplaySelection(
            requestId: requestID,
            sessionId: activeMirrorSessionId,
            displayId: displayId
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorDisplaySelect,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorDisplaySelection: selection)
        )
        Task {
            do {
                try await controlStreamCoordinator.send(frame: frame, timeout: 2)
            } catch {
                await MainActor.run {
                    selectedMirrorDisplayId = previousDisplayId
                    lastError = "Could not switch display: \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshCooldownTicker(for ack: HermesRealtimeRelayMirrorAck) {
        cooldownTickerTask?.cancel()
        guard ack.decision == .coolingDown,
              (ack.cooldownSecondsRemaining ?? 0) > 0 else {
            cooldownTickerTask = nil
            return
        }
        let requestID = ack.requestId
        cooldownTickerTask = Task { @MainActor in
            while !Task.isCancelled {
                cooldownClock = Date()
                guard lastAck?.requestId == requestID,
                      let remaining = cooldownSecondsRemaining(for: ack),
                      remaining > 0 else {
                    if lastAck?.requestId == requestID {
                        lastAck = nil
                    }
                    cooldownTickerTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func cooldownSecondsRemaining(for ack: HermesRealtimeRelayMirrorAck) -> Int? {
        guard let original = ack.cooldownSecondsRemaining else { return nil }
        guard ack.decision == .coolingDown else { return original }
        guard let receivedAt = lastAckReceivedAt else { return original }
        let elapsed = max(0, Int(cooldownClock.timeIntervalSince(receivedAt).rounded(.down)))
        return max(0, original - elapsed)
    }

    func placeCall() async {
        guard peer.canPlaceCall else {
            lastError = "This Mac is not advertising call receive."
            return
        }
        guard controlStreamCoordinator.phase == .live else {
            lastError = callStatusMessage ?? "Mercury is still connecting. Try again after the Mac shows as live."
            return
        }
        let requestID = "call_\(UUID().uuidString)"
        pendingCallRequestID = requestID
        lastCallAck = nil
        lastError = nil
        do {
            try await controlStreamCoordinator.sendCallInvite(
                requestId: requestID,
                requesterDisplayName: deviceDisplayName(),
                callKind: "video",
                timeout: 4
            )
            startCallAckTimeout(requestID: requestID)
        } catch {
            callTimeoutTask?.cancel()
            callTimeoutTask = nil
            pendingCallRequestID = nil
            lastError = error.localizedDescription
        }
    }

    func startCallAckTimeout(requestID: String) {
        callTimeoutTask?.cancel()
        callTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, pendingCallRequestID == requestID else { return }
            callTimeoutTask = nil
            pendingCallRequestID = nil
            lastError = "No response from the Mac. Mercury reconnected; try Call Mac again."
            if let uid = uidProvider(), !uid.isEmpty {
                await controlStreamCoordinator.stop()
                controlStreamCoordinator.start(uid: uid, connectionID: connectionID)
            }
        }
    }

    func handleFilePick(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let err):
            lastError = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard let service = fileTransferService else {
                lastError = unavailableFileTransferMessage
                return
            }
            guard service.canSendFiles else {
                lastError = unavailableFileTransferMessage
                return
            }
            guard let uid = uidProvider(), !uid.isEmpty else {
                lastError = "Sign in to send files."
                return
            }
            sendingFile = true
            defer { sendingFile = false }
            do {
                _ = try await service.sendFile(
                    at: url,
                    uid: uid,
                    connectionID: connectionID,
                    peerDeviceID: connectionID
                )
                lastError = nil
                personalization.haptics.play()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func deviceDisplayName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iPhone"
        #endif
    }
}

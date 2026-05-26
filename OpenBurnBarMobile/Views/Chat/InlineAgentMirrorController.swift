#if canImport(UIKit)
import AVFoundation
import Combine
import FirebaseAuth
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia
import OSLog
import UIKit

/// Drives the inline CLI/mirror view's lifecycle. When the user toggles to
/// CLI view, this controller asks the Mac to start screen sharing over the
/// already-warm `MediaControlStreamCoordinator` so the inline surface stops
/// showing "Waiting for Mac session..." and shows live frames as soon as the
/// Mac accepts.
///
/// Mirrors the `MercuryLiveSheet.requestMirror()` flow but renders inline
/// instead of full-screen, and owns its own `ScreenShareViewerCoordinator`
/// so the chat surface and the full-screen Mercury viewer don't fight over
/// the same display layer.
@MainActor
final class InlineAgentMirrorController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case noRelay(String)
        case connectingStream
        case askingMirror
        case waitingForApproval
        case waitingForFrames
        case live
        case error(String)

        var statusText: String {
            switch self {
            case .idle: return "Tap CLI to start"
            case .noRelay(let message): return message
            case .connectingStream: return "Connecting to Mac\u{2026}"
            case .askingMirror: return "Asking Mac to share screen\u{2026}"
            case .waitingForApproval: return "Tap Accept on your Mac to start\u{2026}"
            case .waitingForFrames: return "Mac accepted \u{2014} loading first frame\u{2026}"
            case .live: return "Live mirror"
            case .error(let message): return message
            }
        }

        var isLive: Bool {
            if case .live = self { return true }
            return false
        }

        var canShowFrames: Bool {
            switch self {
            case .live, .waitingForFrames: return true
            default: return false
            }
        }
    }

    private static let log = Logger(subsystem: "com.openburnbar.mobile", category: "InlineAgentMirror")

    let viewer = ScreenShareViewerCoordinator()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latestFocusContext: ScreenShareSmartZoomContext?

    private var coordinator: MediaControlStreamCoordinator?
    private var activeConnectionID: String?
    private var activeUID: String?
    private var awaitingRequestID: String?
    private var activeMirrorRequestID: String?
    private var activeMirrorSessionId: String?
    private var activeMirrorViewerId: String?
    private var startTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var approvalHintTask: Task<Void, Never>?
    private var handlersInstalled = false
    private var didInstallLongTermReferenceHandler = false
    private weak var hermesService: HermesService?

    /// Total approval window after which we treat the request as dead.
    /// The Mac shows a ringing UI by default and may take a while if the
    /// user is mid-conversation on the phone — give them time to glance at
    /// the Mac and tap Accept.
    private let approvalTimeoutSeconds: TimeInterval = 60
    /// Time after which we switch the status text to remind the user to
    /// approve the request on the Mac.
    private let approvalHintDelaySeconds: TimeInterval = 4

    /// Start the mirror flow. Idempotent — calling while already live is
    /// cheap.
    func start(hermesService: HermesService) {
        self.hermesService = hermesService
        switch phase {
        case .live, .waitingForFrames, .connectingStream, .askingMirror, .waitingForApproval:
            return
        default:
            break
        }

        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            await self?.runStart(using: hermesService)
        }
    }

    /// Stop the live mirror. Safe to call when nothing is live.
    func stop() {
        startTask?.cancel()
        startTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        approvalHintTask?.cancel()
        approvalHintTask = nil

        let coordinator = self.coordinator
        let requestID = activeMirrorRequestID
        let sessionID = activeMirrorSessionId

        clearMirrorState()
        uninstallHandlers()

        Task { @MainActor in
            guard let coordinator, let requestID else { return }
            do {
                try await coordinator.sendMirrorStop(
                    requestId: requestID,
                    sessionId: sessionID,
                    reason: "inline_view_dismissed"
                )
            } catch {
                Self.log.error("inline_mirror_stop_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }

        phase = .idle
    }

    private func runStart(using hermesService: HermesService) async {
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else {
            phase = .noRelay("Sign in with the same OpenBurnBar account on this iPhone/iPad to mirror your Mac.")
            return
        }

        let relay = pickRelay(from: hermesService)
        guard let relay else {
            phase = .noRelay("Open BurnBar on your Mac and enable Hermes Remote Relay to mirror the CLI here.")
            return
        }

        if hermesService.selectedConnection.id != relay.id {
            _ = hermesService.selectConnection(relay, refresh: false)
        }

        activeUID = uid
        activeConnectionID = relay.id
        phase = .connectingStream

        do {
            try await HermesIrohRelayTransport.shared.ensureMediaControlStream(connectionID: relay.id)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        guard let coordinator = HermesIrohRelayTransport.shared.currentMediaControlCoordinator else {
            phase = .error("Mac mirror stream did not start. Try toggling CLI again.")
            return
        }
        self.coordinator = coordinator
        installHandlers(on: coordinator)

        do {
            try await coordinator.ensureResponsive(uid: uid, connectionID: relay.id)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        await sendMirrorRequest(coordinator: coordinator, uid: uid, connectionID: relay.id)
    }

    private func pickRelay(from hermesService: HermesService) -> HermesConnectionRecord? {
        if hermesService.selectedConnection.mode == .relayLink &&
            hermesService.selectedConnection.id != HermesConnectionRecord.localDefault.id {
            return hermesService.selectedConnection
        }
        if let suggested = hermesService.suggestedRelayConnection {
            return suggested
        }
        return hermesService.relayConnections.first
    }

    private func sendMirrorRequest(
        coordinator: MediaControlStreamCoordinator,
        uid: String,
        connectionID: String
    ) async {
        let requestID = UUID().uuidString
        let viewerID = UUID().uuidString
        let signingKey = try? PhoneControlSigningKeyStore.shared.signingKey()
        let controlAuthorityPeerNodeId = signingKey.map {
            PhoneControlSigningKeyStore.shared.peerNodeId(for: $0)
        }

        awaitingRequestID = requestID
        activeMirrorRequestID = nil
        activeMirrorSessionId = nil
        activeMirrorViewerId = viewerID
        phase = .askingMirror

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
            controlAuthorityPeerNodeId: controlAuthorityPeerNodeId
        )

        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: uid,
            connectionId: connectionID,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: request)
        )

        do {
            try await coordinator.send(frame: frame)
            Self.log.info("inline_mirror_request_sent requestID=\(requestID, privacy: .public) connectionID=\(connectionID, privacy: .public)")
            startMirrorAckTimeout(requestID: requestID)
        } catch {
            Self.log.error("inline_mirror_request_send_failed error=\(error.localizedDescription, privacy: .public)")
            phase = .error(error.localizedDescription)
            awaitingRequestID = nil
        }
    }

    private func startMirrorAckTimeout(requestID: String) {
        timeoutTask?.cancel()
        approvalHintTask?.cancel()

        // Fast-path hint — if the Mac auto-accepts, the ack arrives in
        // well under a second. If we still haven't heard back after the
        // hint delay, surface "Tap Accept on your Mac" so the user knows
        // a ring is waiting on the Mac.
        approvalHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.approvalHintDelaySeconds ?? 4) * 1_000_000_000)
            guard let self, !Task.isCancelled,
                  self.awaitingRequestID == requestID else { return }
            if case .askingMirror = self.phase {
                self.phase = .waitingForApproval
            }
        }

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.approvalTimeoutSeconds ?? 60) * 1_000_000_000))
            guard let self, !Task.isCancelled,
                  self.awaitingRequestID == requestID else { return }
            self.awaitingRequestID = nil
            self.phase = .error("No response from the Mac. Make sure BurnBar is running on the Mac, then tap CLI again to retry.")
        }
    }

    private func installHandlers(on coordinator: MediaControlStreamCoordinator) {
        guard !handlersInstalled else { return }
        handlersInstalled = true

        coordinator.mirrorAckHandler = { [weak self] ack in
            await MainActor.run { self?.handleAck(ack) }
        }
        coordinator.mirrorFrameHandler = { [weak self] frame in
            await self?.viewer.ingest(frame: frame)
            await MainActor.run { self?.markLive() }
        }
        coordinator.mirrorFrameV2Handler = { [weak self] frame in
            await self?.viewer.ingest(frameV2: frame)
            await MainActor.run { self?.markLive() }
        }
        coordinator.focusContextHandler = { [weak self] context in
            await MainActor.run {
                self?.viewer.ingest(focusContext: context)
                if let zoomContext = ScreenShareSmartZoomContext.from(context) {
                    self?.latestFocusContext = zoomContext
                }
            }
        }

        if !didInstallLongTermReferenceHandler {
            didInstallLongTermReferenceHandler = true
            viewer.longTermReferenceTokenHandler = { [weak self] token in
                guard let self,
                      let coordinator = self.coordinator else { return }
                try? await coordinator.sendLongTermReferenceAcknowledgement(
                    token: token,
                    requestId: self.activeMirrorRequestID
                )
            }
        }
    }

    private func uninstallHandlers() {
        guard handlersInstalled else { return }
        handlersInstalled = false
        coordinator?.mirrorAckHandler = nil
        coordinator?.mirrorFrameHandler = nil
        coordinator?.mirrorFrameV2Handler = nil
        coordinator?.focusContextHandler = nil
        coordinator = nil
    }

    private func handleAck(_ ack: HermesRealtimeRelayMirrorAck) {
        guard ack.requestId == awaitingRequestID || ack.requestId == activeMirrorRequestID else {
            Self.log.info("inline_mirror_ack_ignored requestID=\(ack.requestId, privacy: .public) decision=\(ack.decision.rawValue, privacy: .public)")
            return
        }
        Self.log.info("inline_mirror_ack_received requestID=\(ack.requestId, privacy: .public) decision=\(ack.decision.rawValue, privacy: .public) sessionID=\(ack.sessionId ?? "-", privacy: .public)")

        if ack.requestId == awaitingRequestID {
            timeoutTask?.cancel()
            timeoutTask = nil
            approvalHintTask?.cancel()
            approvalHintTask = nil
            awaitingRequestID = nil
        }

        switch ack.decision {
        case .accepted:
            activeMirrorRequestID = ack.requestId
            activeMirrorSessionId = ack.sessionId
            // Mac accepted but frames are still in flight. Surface a
            // "loading" state so the user can see progress without
            // staring at "Asking…" forever.
            if case .live = phase { return }
            phase = .waitingForFrames
            startFirstFrameTimeout(sessionID: ack.sessionId)
        default:
            let reason = ack.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .error(reason?.isEmpty == false
                           ? reason!
                           : "Mac declined the mirror request.")
            activeMirrorRequestID = nil
            activeMirrorSessionId = nil
        }
    }

    private func startFirstFrameTimeout(sessionID: String?) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled,
                  self.activeMirrorSessionId == sessionID,
                  case .waitingForFrames = self.phase else { return }
            self.phase = .error("The Mac accepted the mirror request, but no frames arrived within 15 seconds. The screen-share pipeline may have stalled.")
        }
    }

    private func markLive() {
        if case .live = phase { return }
        Self.log.info("inline_mirror_first_frame phase_was=\(String(describing: self.phase), privacy: .public)")
        timeoutTask?.cancel()
        timeoutTask = nil
        approvalHintTask?.cancel()
        approvalHintTask = nil
        phase = .live
    }

    private func clearMirrorState() {
        awaitingRequestID = nil
        activeMirrorRequestID = nil
        activeMirrorSessionId = nil
        activeMirrorViewerId = nil
    }

    private func deviceDisplayName() -> String {
        UIDevice.current.name
    }
}
#endif

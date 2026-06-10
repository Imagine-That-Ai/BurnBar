#if canImport(UIKit)
import AVFoundation
import Combine
import FirebaseAuth
import Foundation
import OpenBurnBarComputerUseCore
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
    /// Runtime id (e.g. `hermes`, `codex`, `claude`) whose CLI the Mac should
    /// launch interactively and pin the mirror to. Set via `start(_:runtime:)`.
    private var agentRuntimeID: String = AssistantRuntimeID.hermes.rawValue

    /// `true` once the phone-control lane is set up and keystrokes can flow to
    /// the live TUI. Drives the keyboard affordance in the focused terminal.
    /// (Direct-download Mac build only; the sandboxed MAS Mac ignores injected
    /// keystrokes because Accessibility is unavailable there.)
    @Published private(set) var controlInputReady: Bool = false
    private var controlSender: PhoneControlSender?
    private var controlSetupTask: Task<Void, Never>?
    private static let emptyControlAuthority = HermesRealtimeRelayAuthorityEnvelope(
        peerNodeId: "",
        counter: 0,
        timestamp: Date(timeIntervalSince1970: 0),
        intentHashBlake3: "",
        signatureEd25519: ""
    )

    /// Total approval window after which we treat the request as dead.
    /// The Mac shows a ringing UI by default and may take a while if the
    /// user is mid-conversation on the phone — give them time to glance at
    /// the Mac and tap Accept.
    private let approvalTimeoutSeconds: TimeInterval = 60
    /// Time after which we switch the status text to remind the user to
    /// approve the request on the Mac.
    private let approvalHintDelaySeconds: TimeInterval = 4

    /// Start the mirror flow. Idempotent — calling while already live is
    /// cheap. `runtime` selects which agent CLI the Mac launches interactively
    /// (and pins the mirror to). Defaults to Hermes for back-compat.
    func start(hermesService: HermesService, runtime: String = AssistantRuntimeID.hermes.rawValue) {
        self.hermesService = hermesService
        self.agentRuntimeID = runtime
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

        phase = .connectingStream

        let transport = HermesIrohRelayTransport.shared
        let preferredRelay = await hermesService.preferredRelayConnection(refreshIfMissing: true)
        guard let relayTarget = InlineAgentMirrorRelayResolver.resolve(
            preferredRelay: preferredRelay,
            activeMediaControlConnectionID: transport.currentMediaControlConnectionID,
            activeMediaControlPhase: transport.currentMediaControlPhase
        ) else {
            phase = .noRelay("Open BurnBar on your Mac and enable Hermes Remote Relay to mirror the CLI here.")
            return
        }

        if let relay = relayTarget.relay,
           hermesService.selectedConnection.id != relay.id {
            _ = hermesService.selectConnection(relay, refresh: false)
        }

        activeUID = uid
        activeConnectionID = relayTarget.connectionID

        do {
            try await transport.ensureMediaControlStream(connectionID: relayTarget.connectionID)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        guard let coordinator = transport.mediaControlCoordinator(for: relayTarget.connectionID) else {
            phase = .error("Mac mirror stream did not start. Try toggling CLI again.")
            return
        }
        self.coordinator = coordinator
        installHandlers(on: coordinator)

        do {
            try await coordinator.ensureResponsive(uid: uid, connectionID: relayTarget.connectionID)
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        await sendMirrorRequest(coordinator: coordinator, uid: uid, connectionID: relayTarget.connectionID)
    }
    private func sendMirrorRequest(
        coordinator: MediaControlStreamCoordinator,
        uid: String,
        connectionID: String
    ) async {
        let requestID = UUID().uuidString
        let viewerID = UUID().uuidString
        let signingIdentity = try? PhoneControlSigningKeyStore.shared.signingIdentity()
        let controlAuthorityPeerNodeId = signingIdentity.map {
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
            focusFollowMode: AgentFocusFollowMode.smart.rawValue,
            viewerId: viewerID,
            viewerDeviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
            controlAuthorityPeerNodeId: controlAuthorityPeerNodeId,
            agentTerminal: HermesRealtimeRelayAgentTerminalRequest(
                runtimeId: agentRuntimeID,
                interactive: true
            )
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
        prepareControlInput()
    }

    // MARK: - Live keystroke input (focused TUI)

    /// Bring up the phone-control lane so keystrokes typed on the phone reach
    /// the live terminal. Mirrors `MercuryLiveSheet.startPhoneControlIfPossible`
    /// but scoped to the inline controller's warm coordinator. Idempotent.
    func prepareControlInput() {
        guard controlSender == nil, controlSetupTask == nil,
              let coordinator,
              let uid = activeUID,
              let connectionID = activeConnectionID else { return }
        controlSetupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.controlSetupTask = nil }
            do {
                await LiveDeviceTrustGateway().registerSelfIfNeeded()
                try await coordinator.ensureResponsive(uid: uid, connectionID: connectionID)
                let signingIdentity = try PhoneControlSigningKeyStore.shared.signingIdentity()
                let peerNodeId = PhoneControlSigningKeyStore.shared.peerNodeId(for: signingIdentity)
                try await PhoneControlAuthorityPublisher.shared.publish(
                    uid: uid,
                    connectionId: connectionID,
                    deviceId: MobileDeviceIdentity.loadOrCreateDeviceId(),
                    peerNodeId: peerNodeId,
                    publicKeyRepresentation: signingIdentity.publicKeyRepresentation,
                    keyKind: signingIdentity.kind
                )
                try await coordinator.send(frame: HermesRealtimeRelayFrame(
                    type: .controlClassify,
                    uid: uid,
                    connectionId: connectionID,
                    control: HermesRealtimeRelayControlPayload(
                        streamClass: MediaStreamClass.controlInput.rawValue,
                        authorityPeerNodeId: peerNodeId
                    )
                ))
                self.controlSender = PhoneControlSender(
                    peerNodeId: peerNodeId,
                    uid: uid,
                    connectionId: connectionID,
                    signingIdentityProvider: { signingIdentity },
                    frameSink: { frame in try await coordinator.send(frame: frame) }
                )
                self.controlInputReady = true
                Self.log.info("inline_mirror_control_ready connectionID=\(connectionID, privacy: .public)")
            } catch {
                self.controlInputReady = false
                Self.log.error("inline_mirror_control_setup_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Send typed text to the live terminal.
    func sendText(_ text: String) {
        guard let sender = controlSender, !text.isEmpty else { return }
        let intent = HermesRealtimeRelayInputIntent(
            kind: .type,
            text: text,
            authority: Self.emptyControlAuthority
        )
        Task { try? await sender.send(intent: intent) }
    }

    /// Send a key / shortcut (e.g. "Return", "Tab", "Escape", arrows, or a
    /// letter with `["control"]` modifiers for Ctrl-C) to the live terminal.
    func sendKey(_ key: String, modifiers: [String] = []) {
        guard let sender = controlSender, !key.isEmpty else { return }
        let intent = HermesRealtimeRelayInputIntent(
            kind: .shortcut,
            key: key,
            modifiers: modifiers.isEmpty ? nil : modifiers,
            authority: Self.emptyControlAuthority
        )
        Task { try? await sender.send(intent: intent) }
    }

    private func teardownControlInput() {
        controlSetupTask?.cancel()
        controlSetupTask = nil
        controlSender = nil
        controlInputReady = false
    }

    private func clearMirrorState() {
        awaitingRequestID = nil
        activeMirrorRequestID = nil
        activeMirrorSessionId = nil
        activeMirrorViewerId = nil
        teardownControlInput()
    }

    private func deviceDisplayName() -> String {
        UIDevice.current.name
    }
}

struct InlineAgentMirrorRelayTarget: Equatable {
    enum Source: Equatable {
        case preferredRelay
        case activeMediaControl
    }

    let connectionID: String
    let relay: HermesConnectionRecord?
    let source: Source
}

enum InlineAgentMirrorRelayResolver {
    static func resolve(
        preferredRelay: HermesConnectionRecord?,
        activeMediaControlConnectionID: String?,
        activeMediaControlPhase: MediaControlStreamCoordinator.Phase
    ) -> InlineAgentMirrorRelayTarget? {
        if let preferredRelay {
            return InlineAgentMirrorRelayTarget(
                connectionID: preferredRelay.id,
                relay: preferredRelay,
                source: .preferredRelay
            )
        }

        guard isUsableActiveMediaControlPhase(activeMediaControlPhase),
              let activeMediaControlConnectionID = activeMediaControlConnectionID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !activeMediaControlConnectionID.isEmpty else {
            return nil
        }

        return InlineAgentMirrorRelayTarget(
            connectionID: activeMediaControlConnectionID,
            relay: nil,
            source: .activeMediaControl
        )
    }

    static func isUsableActiveMediaControlPhase(_ phase: MediaControlStreamCoordinator.Phase) -> Bool {
        switch phase {
        case .live, .dialing, .reconnecting:
            return true
        case .idle, .stopped, .failed:
            return false
        }
    }
}
#endif

import Foundation
import Combine
import Darwin
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OSLog
import AppKit
import ImageIO

/// Mac-side brain for Mercury Phase 8 user-facing entry points. Owns:
///
///   • Inbound `media.mirror.request` triage — cooldown gating,
///     consent fast-path, ringing phase that surfaces
///     `IncomingCallSheet` at the app scene root.
///   • Inbound `media.presence.heartbeat` forwarding to
///     `MercuryPeerSource` so the popover knows when the iPhone is
///     online.
///   • Acceptance — admits the viewer and emits `media.mirror.ack`
///     immediately, then starts the heavier capture/control runtime.
///     The phone must never sit on "Opening mirror" while ScreenCaptureKit
///     warms up.
///   • Cooldown — after decline or stop, holds for a configurable
///     window so the iPhone can't spam the Mac with retries.
///
/// `MercuryRouter` is constructed by `OpenBurnBarRuntimeContext` and
/// attached to `MacFileTransferService.setMercuryDispatcher` so the
/// existing control-stream read loop fans non-blob frames into it.
/// Mac-side brain for Mercury Phase 8 user-facing entry points. Owns:
///
///   • Inbound `media.mirror.request` triage — cooldown gating,
///     consent fast-path, ringing phase that surfaces
///     `IncomingCallSheet` at the app scene root.
///   • Inbound `media.presence.heartbeat` forwarding to
///     `MercuryPeerSource` so the popover knows when the iPhone is
///     online.
///   • Acceptance — admits the viewer and emits `media.mirror.ack`
///     immediately, then starts the heavier capture/control runtime.
///     The phone must never sit on "Opening mirror" while ScreenCaptureKit
///     warms up.
///   • Cooldown — after decline or stop, holds for a configurable
///     window so the iPhone can't spam the Mac with retries.
///
/// `MercuryRouter` is constructed by `OpenBurnBarRuntimeContext` and
/// attached to `MacFileTransferService.setMercuryDispatcher` so the
/// existing control-stream read loop fans non-blob frames into it.
@MainActor
final class MercuryRouter: ObservableObject {
    static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")

    static let remoteUnlockSessionRequiredDetail = "remote_unlock_session_required"

    static func peerNodeIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.canonicalMercuryPeerNodeID,
              let rhs = rhs?.canonicalMercuryPeerNodeID else {
            return false
        }
        return lhs == rhs
    }

    static func debugTrace(_ message: String) {
        #if DEBUG
        NSLog("OpenBurnBarMercury \(message)")
        #endif
    }

    enum Phase: Equatable {
        case idle
        case ringing(requestID: String, requesterName: String, requestedAt: Date)
        case callRinging(requestID: String, requesterName: String, requestedAt: Date)
        case starting(requestID: String)
        case streaming(requestID: String, since: Date)
        case cooldown(secondsRemaining: Int)
    }

    /// Pending request awaiting user action — surfaced by the global
    /// sheet chrome via `.sheet(item: $router.pendingRequest)`.
    struct PendingRequest: Identifiable, Equatable {
        let id: String
        let requesterName: String
        let requestedAt: Date
        /// The original frame, kept for the ack `requestID` correlation
        /// and so we can construct the reply on the right stream.
        let frame: HermesRealtimeRelayFrame
        /// The reply sender that delivered this request. Stored here so
        /// `respond()` can emit the ack on the correct stream even when
        /// interleaved presence heartbeats have arrived since.
        let replySender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)
        /// Per-control-stream lease ID from `MacFileTransferService`. iPhone
        /// and Android can share a Mac pairing `connectionID`; this keeps
        /// ownership tied to the exact stream that requested it.
        let controlStreamID: UUID?
        /// Authenticated iroh NodeId for the remote endpoint that opened the
        /// control stream. Request payload peer IDs are untrusted until they
        /// match this transport identity.
        let remotePeerNodeID: String?
        let agentTerminalApproved: Bool

        var requestsAgentTerminal: Bool {
            guard let terminal = frame.media?.mirrorRequest?.agentTerminal else { return false }
            return terminal.interactive && !terminal.runtimeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var agentTerminalRuntimeName: String? {
            frame.media?.mirrorRequest?.agentTerminal?.runtimeId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmptyForMercury
        }

        func approvingAgentTerminal() -> PendingRequest {
            PendingRequest(
                id: id,
                requesterName: requesterName,
                requestedAt: requestedAt,
                frame: frame,
                replySender: replySender,
                controlStreamID: controlStreamID,
                remotePeerNodeID: remotePeerNodeID,
                agentTerminalApproved: true
            )
        }

        static func == (lhs: PendingRequest, rhs: PendingRequest) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Closure that obtains a `MediaStreamSink` for a freshly-accepted
    /// mirror request. Injected by `OpenBurnBarRuntimeContext` once the
    /// per-GOP iroh dial is available. When `nil`, accept emits an
    /// `unsupported` ack so the iPhone surfaces a clean banner rather
    /// than waiting on a stream that will never carry bytes.
    typealias MirrorSinkFactory = @MainActor (
        _ request: HermesRealtimeRelayMirrorRequest,
        _ frame: HermesRealtimeRelayFrame,
        _ replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async throws -> MediaStreamSink
    typealias ScreenShareStarter = @MainActor (
        _ peerDeviceID: String,
        _ sink: MediaStreamSink,
        _ streamClassOverride: MediaStreamClass?,
        _ displayId: String?,
        _ viewerID: String?,
        _ localStreamingCapabilities: MercuryStreamingCapabilitySnapshot?,
        _ remoteStreamingCapabilities: MercuryStreamingCapabilitySnapshot?,
        _ codecPolicy: MercuryCodecPolicy
    ) async throws -> Void
    typealias ComputerUseSessionEnsurer = @MainActor () async throws -> Void
    typealias FocusFollowModeApplier = @MainActor (AgentFocusFollowMode) -> Void

    @Published var phase: Phase = .idle
    @Published var lastError: String?
    @Published var pendingRequest: PendingRequest?
    @Published var pendingCall: PendingRequest?
    let sessionCoordinator: MediaSessionCoordinator

    let peerSource: MercuryPeerSource

    let consentStore: MercuryConsentStore

    let cooldownSeconds: TimeInterval

    let clock: @Sendable () -> Date

    let startScreenShare: ScreenShareStarter

    let ensureComputerUseSession: ComputerUseSessionEnsurer?

    let applyFocusFollowMode: FocusFollowModeApplier?

    let maxMirrorViewers: Int

    let remoteUnlockReadiness: MacRemoteUnlockReadinessService

    var mirrorSinkFactory: MirrorSinkFactory?

    /// The frame + reply sender from the most recently accepted request.
    /// Used by `stopMirror` so we can emit a `denied` ack when the host
    /// ends the mirror via the CallHUD, even though `pendingRequest` was
    /// cleared on accept.
    var activeSessionSender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)?

    var activeSessionFrame: HermesRealtimeRelayFrame?

    var activeSessionControlStreamID: UUID?

    struct ActiveMirrorViewer {
        let viewerID: String
        let requestID: String
        let sessionID: String
        let requesterName: String
        let joinedAt: Date
        let frame: HermesRealtimeRelayFrame
        let replySender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)
        let controlStreamID: UUID?
        let viewerDeviceID: String?
        let controlAuthorityPeerNodeID: String?
        let remotePeerNodeID: String?
        let remoteUnlockSessionID: String?
        let agentTerminalApproved: Bool
        /// Phase 12 — set when this viewer requested an interactive single-window
        /// CLI; the launched Terminal session is terminated on viewer teardown.
        var interactiveTerminalSession: LaunchedAgentTerminalSession?
    }
    var activeMirrorSessionID: String?

    var activeMirrorViewers: [String: ActiveMirrorViewer] = [:]

    var activeMirrorViewOrder: [String] = []

    var activeControlViewerID: String?

    var activeSelectedDisplayID: String?

    var remoteStreamingCapabilitiesByConnectionID: [String: MercuryStreamingCapabilitySnapshot] = [:]

    var remoteStreamingCapabilitiesByControlStreamID: [UUID: MercuryStreamingCapabilitySnapshot] = [:]

    var cooldownTask: Task<Void, Never>?

    var remoteUnlockResumeTask: Task<Void, Never>?

    var mirrorStartupTasks: [String: Task<Void, Never>] = [:]

    var mirrorStartupTaskIDs: [String: UUID] = [:]

    nonisolated(unsafe) var workspaceAuthGateObservers: [NSObjectProtocol] = []
    init(
        sessionCoordinator: MediaSessionCoordinator,
        peerSource: MercuryPeerSource,
        consentStore: MercuryConsentStore,
        ensureComputerUseSession: ComputerUseSessionEnsurer? = nil,
        applyFocusFollowMode: FocusFollowModeApplier? = nil,
        startScreenShare: ScreenShareStarter? = nil,
        maxMirrorViewers: Int = 3,
        remoteUnlockReadiness: MacRemoteUnlockReadinessService = .shared,
        cooldownSeconds: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.peerSource = peerSource
        self.consentStore = consentStore
        self.ensureComputerUseSession = ensureComputerUseSession
        self.applyFocusFollowMode = applyFocusFollowMode
        self.remoteUnlockReadiness = remoteUnlockReadiness
        if let startScreenShare {
            self.startScreenShare = startScreenShare
        } else {
            self.startScreenShare = { [sessionCoordinator] peerDeviceID, sink, streamClassOverride, displayId, viewerID, localCapabilities, remoteCapabilities, codecPolicy in
                try await sessionCoordinator.startScreenShare(
                    peerDeviceID: peerDeviceID,
                    sink: sink,
                    streamClassOverride: streamClassOverride,
                    displayId: displayId,
                    viewerID: viewerID,
                    localStreamingCapabilities: localCapabilities,
                    remoteStreamingCapabilities: remoteCapabilities,
                    codecPolicy: codecPolicy
                )
            }
        }
        self.maxMirrorViewers = max(1, maxMirrorViewers)
        self.cooldownSeconds = cooldownSeconds
        self.clock = clock
        installHostAuthGateListeners()
    }

    var activeMirrorControlAuthorityPeerNodeID: String? {
        guard let activeControlViewerID else { return nil }
        return activeMirrorViewers[activeControlViewerID]?.controlAuthorityPeerNodeID
    }

    var activeMirrorControlTerminalWindowID: CGWindowID? {
        guard let activeControlViewerID else { return nil }
        return activeMirrorViewers[activeControlViewerID]?.interactiveTerminalSession?.windowID
    }

    deinit {
        remoteUnlockResumeTask?.cancel()
        mirrorStartupTasks.values.forEach { $0.cancel() }
        mirrorStartupTaskIDs.removeAll()
        for observer in workspaceAuthGateObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Inject the sink factory once the iroh per-GOP dial is available.
    func setMirrorSinkFactory(_ factory: @escaping MirrorSinkFactory) {
        self.mirrorSinkFactory = factory
    }

    /// Returns the reply sender + last request frame for the currently
    /// active mirror session, or nil when not streaming. Used by the
    /// Smart Zoom context provider to piggyback `focusContext` on the
    /// existing `media.stream.frame` envelope without duplicating
    /// the stream-class plumbing.
    func currentMirrorSessionSender() -> (
        sender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void,
        frame: HermesRealtimeRelayFrame
    )? {
        guard case .streaming = phase else { return nil }
        if let activeControlViewerID,
           let viewer = activeMirrorViewers[activeControlViewerID] {
            return (viewer.replySender, viewer.frame)
        }
        guard let viewer = activeMirrorViewOrder.compactMap({ activeMirrorViewers[$0] }).first else { return nil }
        return (viewer.replySender, viewer.frame)
    }

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

    /// Called by the media-control stream owner after the registry entry has
    /// been invalidated. A peer disconnect is semantically the same as that
    /// peer ending any in-flight mirror, but it must not unlock an unrelated
    /// live session.
    func handleControlStreamClosed(
        connectionID: String,
        controlStreamID: UUID? = nil,
        removedLastStreamForConnection: Bool = true
    ) async {
        Self.log.info("router_control_stream_closed connectionID=\(connectionID, privacy: .public) controlStreamID=\(controlStreamID?.uuidString ?? "legacy", privacy: .public) removedLast=\(removedLastStreamForConnection, privacy: .public)")
        Self.debugTrace("router_control_stream_closed connectionID=\(connectionID) controlStreamID=\(controlStreamID?.uuidString ?? "legacy") removedLast=\(removedLastStreamForConnection)")
        if let controlStreamID {
            remoteStreamingCapabilitiesByControlStreamID.removeValue(forKey: controlStreamID)
        }
        if removedLastStreamForConnection {
            remoteStreamingCapabilitiesByConnectionID.removeValue(forKey: connectionID)
            peerSource.handleControlStreamClosed(connectionID: connectionID)
        }

        let pendingMirrorClosed = pendingRequest.map {
            request($0, matchesClosedConnectionID: connectionID, controlStreamID: controlStreamID)
        } ?? false
        let pendingCallClosed = pendingCall.map {
            request($0, matchesClosedConnectionID: connectionID, controlStreamID: controlStreamID)
        } ?? false
        if pendingMirrorClosed { pendingRequest = nil }
        if pendingCallClosed { pendingCall = nil }

        let closedViewer = viewer(matchingConnectionID: connectionID, controlStreamID: controlStreamID)
        let activeMirrorClosed = closedViewer != nil
        if let closedViewer {
            _ = await removeActiveMirrorViewer(viewerID: closedViewer.viewerID)
        }

        switch phase {
        case .ringing where pendingMirrorClosed,
             .callRinging where pendingCallClosed,
             .starting where activeMirrorClosed,
             .streaming where activeMirrorClosed && activeMirrorViewers.isEmpty:
            phase = .idle
        default:
            break
        }
    }

    /// Closure entry point handed to `MacFileTransferService` via
    /// `setMercuryDispatcher`. Routes by frame type. Mirror frames
    /// capture the reply sender in the `PendingRequest` so later
    /// accepts/declines send acks on the correct stream.
    func handleFrame(
        _ frame: HermesRealtimeRelayFrame,
        controlStreamID: UUID? = nil,
        remotePeerNodeID: String? = nil,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        Self.log.info("router_handle_frame type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
        switch frame.type {
        case .mediaPresenceHeartbeat:

            if let heartbeat = frame.media?.presence {
                if let streamingCapabilities = heartbeat.streamingCapabilities {
                    let snapshot = MercuryStreamingCapabilitySnapshot(wire: streamingCapabilities)
                    if let controlStreamID {
                        remoteStreamingCapabilitiesByControlStreamID[controlStreamID] = snapshot
                    } else {
                        remoteStreamingCapabilitiesByConnectionID[frame.connectionId] = snapshot
                    }
                }
                peerSource.ingestHeartbeat(
                    heartbeat,
                    connectionID: frame.connectionId
                )

                // Reply with a lightweight presence heartbeat. The control
                // stream uses this as a liveness probe before mirror setup;
                // keep expensive capability probing and wallpaper transfer out
                // of this path so the stream is still alive for the actual
                // mirror request.
                let macCapabilities = macPresenceCapabilities()
                let responseBeat = HermesRealtimeRelayPresenceHeartbeat(
                    sentAt: Date(),
                    deviceDisplayName: Host.current().localizedName ?? "My Mac",
                    capabilities: macCapabilities,
                    peerDeviceId: frame.connectionId,
                    // F7: the Mac previously never advertised streaming
                    // capabilities back to phones, so phone-side negotiators
                    // (codec, wire version, frame AEAD) had no Mac snapshot.
                    // The probe is cached — no per-beat encoder sessions.
                    streamingCapabilities: Self.cachedLocalStreamingCapabilities.wireValue,
                    remoteUnlockCapabilities: remoteUnlockReadiness.capabilities()
                )
                let responseFrame = HermesRealtimeRelayFrame(
                    type: .mediaPresenceHeartbeat,
                    uid: frame.uid,
                    connectionId: frame.connectionId,
                    media: HermesRealtimeRelayMediaPayload(presence: responseBeat)
                )
                do {
                    try await replySender(responseFrame)
                    Self.log.info("router_presence_reply_sent connectionID=\(frame.connectionId, privacy: .public)")
                } catch {
                    Self.log.error("router_presence_reply_failed connectionID=\(frame.connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
            }

        case .mediaMirrorRequest:
            await handleMirrorRequest(
                frame: frame,
                controlStreamID: controlStreamID,
                remotePeerNodeID: remotePeerNodeID,
                replySender: replySender
            )
        case .mediaMirrorStop:
            await handleMirrorStop(frame: frame, controlStreamID: controlStreamID)
        case .mediaMirrorDisplaySelect:
            await handleMirrorDisplaySelect(
                frame: frame,
                controlStreamID: controlStreamID,
                replySender: replySender
            )
        case .mediaMirrorAck:
            // Mac is the producer of acks, not the consumer. Ignore.
            break
        case .mediaCallInvite:
            await handleCallInvite(
                frame: frame,
                controlStreamID: controlStreamID,
                replySender: replySender
            )
        case .mediaCallAck:
            // Mac is the producer of call acks, not the consumer. Ignore.
            break
        case .mediaLongTermReferenceAck:
            if let ack = frame.media?.longTermReferenceAck {
                sessionCoordinator.acknowledgeLongTermReferenceToken(
                    MercuryLTRToken(value: ack.tokenValue)
                )
                Self.log.info("router_ltr_ack_received token=\(ack.tokenValue, privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
            }
        default:
            break
        }
    }

    func macPresenceCapabilities() -> [String] {
        var capabilities = [
            MercuryPeer.Feature.mirrorHost.rawValue,
            MercuryPeer.Feature.fileSend.rawValue,
            MercuryPeer.Feature.fileReceive.rawValue,
            MercuryPeer.Feature.callReceive.rawValue,
            // F7/F10: advertise the app-layer seal capabilities so phones can
            // negotiate them (both-peers-required gates; plain strings, so
            // pre-F7 peers simply ignore them).
            MediaFrameAeadNegotiation.capability,
            ControlFrameSealNegotiation.capability
        ]
        if remoteUnlockReadiness.capabilities().enabled {
            capabilities.append(MercuryPeer.Feature.remoteUnlockHost.rawValue)
        }
        return capabilities
    }

    /// F7: the Mac's streaming capability snapshot, probed once. The VideoToolbox
    /// probe creates real encoder sessions, so the heartbeat reply must not
    /// re-run it per beat.
    static let cachedLocalStreamingCapabilities: MercuryStreamingCapabilitySnapshot =

        MercuryVideoToolboxCapabilityProbe.snapshot(mediaFrameVersions: .v1AndV2)

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

    static func effectiveFocusFollowMode(
        for request: HermesRealtimeRelayMirrorRequest,
        requestedMode: AgentFocusFollowMode?
    ) -> AgentFocusFollowMode {
        guard request.streamClass == MediaStreamClass.controlSurfaceFrame.rawValue else {
            return .off
        }
        return requestedMode ?? .smart
    }

}

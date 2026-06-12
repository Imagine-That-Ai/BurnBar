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
@MainActor
final class MercuryRouter: ObservableObject {
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")
    private static let remoteUnlockSessionRequiredDetail = "remote_unlock_session_required"
    private static func peerNodeIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.canonicalMercuryPeerNodeID,
              let rhs = rhs?.canonicalMercuryPeerNodeID else {
            return false
        }
        return lhs == rhs
    }

    private static func debugTrace(_ message: String) {
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
        fileprivate let frame: HermesRealtimeRelayFrame
        /// The reply sender that delivered this request. Stored here so
        /// `respond()` can emit the ack on the correct stream even when
        /// interleaved presence heartbeats have arrived since.
        fileprivate let replySender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)
        /// Per-control-stream lease ID from `MacFileTransferService`. iPhone
        /// and Android can share a Mac pairing `connectionID`; this keeps
        /// ownership tied to the exact stream that requested it.
        fileprivate let controlStreamID: UUID?
        /// Authenticated iroh NodeId for the remote endpoint that opened the
        /// control stream. Request payload peer IDs are untrusted until they
        /// match this transport identity.
        fileprivate let remotePeerNodeID: String?
        fileprivate let agentTerminalApproved: Bool

        var requestsAgentTerminal: Bool {
            guard let terminal = frame.media?.mirrorRequest?.agentTerminal else { return false }
            return terminal.interactive && !terminal.runtimeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var agentTerminalRuntimeName: String? {
            frame.media?.mirrorRequest?.agentTerminal?.runtimeId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmptyForMercury
        }

        fileprivate func approvingAgentTerminal() -> PendingRequest {
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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var pendingRequest: PendingRequest?
    @Published private(set) var pendingCall: PendingRequest?

    private let sessionCoordinator: MediaSessionCoordinator
    private let peerSource: MercuryPeerSource
    private let consentStore: MercuryConsentStore
    private let cooldownSeconds: TimeInterval
    private let clock: @Sendable () -> Date
    private let startScreenShare: ScreenShareStarter
    private let ensureComputerUseSession: ComputerUseSessionEnsurer?
    private let applyFocusFollowMode: FocusFollowModeApplier?
    private let maxMirrorViewers: Int
    private let remoteUnlockReadiness: MacRemoteUnlockReadinessService

    private var mirrorSinkFactory: MirrorSinkFactory?
    /// The frame + reply sender from the most recently accepted request.
    /// Used by `stopMirror` so we can emit a `denied` ack when the host
    /// ends the mirror via the CallHUD, even though `pendingRequest` was
    /// cleared on accept.
    private var activeSessionSender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)?
    private var activeSessionFrame: HermesRealtimeRelayFrame?
    private var activeSessionControlStreamID: UUID?
    private struct ActiveMirrorViewer {
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
    private var activeMirrorSessionID: String?
    private var activeMirrorViewers: [String: ActiveMirrorViewer] = [:]
    private var activeMirrorViewOrder: [String] = []
    private var activeControlViewerID: String?
    private var activeSelectedDisplayID: String?
    private var remoteStreamingCapabilitiesByConnectionID: [String: MercuryStreamingCapabilitySnapshot] = [:]
    private var remoteStreamingCapabilitiesByControlStreamID: [UUID: MercuryStreamingCapabilitySnapshot] = [:]
    private var cooldownTask: Task<Void, Never>?
    private var remoteUnlockResumeTask: Task<Void, Never>?
    private var mirrorStartupTasks: [String: Task<Void, Never>] = [:]
    private var mirrorStartupTaskIDs: [String: UUID] = [:]
    private nonisolated(unsafe) var workspaceAuthGateObservers: [NSObjectProtocol] = []

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

    private func currentMirrorSessions() -> [ActiveMirrorViewer] {
        guard case .streaming = phase else { return [] }
        return activeMirrorViewOrder.compactMap { activeMirrorViewers[$0] }
    }

    private var activeMirrorRequestIDForPhase: String? {
        if let activeControlViewerID,
           let requestID = activeMirrorViewers[activeControlViewerID]?.requestID {
            return requestID
        }
        return activeMirrorViewOrder.compactMap { activeMirrorViewers[$0]?.requestID }.first
            ?? activeSessionFrame?.media?.mirrorRequest?.requestId
    }

    private func setStreamingPhaseIfNeeded() {
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

    private func updateLegacyActiveSessionPointer() {
        let viewer = activeControlViewerID.flatMap { activeMirrorViewers[$0] }
            ?? activeMirrorViewOrder.compactMap { activeMirrorViewers[$0] }.first
        activeSessionSender = viewer?.replySender
        activeSessionFrame = viewer?.frame
        activeSessionControlStreamID = viewer?.controlStreamID
    }

    private func viewerRole(for viewerID: String) -> String {
        viewerID == activeControlViewerID ? "controller" : "watcher"
    }

    private func viewerID(for request: HermesRealtimeRelayMirrorRequest, frame: HermesRealtimeRelayFrame, controlStreamID: UUID?) -> String {
        if let viewerId = request.viewerId, !viewerId.isEmpty { return viewerId }
        if let controlStreamID { return "legacy-\(controlStreamID.uuidString)" }
        return "legacy-\(frame.connectionId)"
    }

    private func viewer(matchingRequestID requestID: String) -> ActiveMirrorViewer? {
        activeMirrorViewers.values.first { $0.requestID == requestID }
    }

    private func viewer(
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

    private func viewer(matchingPeerIdentity request: HermesRealtimeRelayMirrorRequest) -> ActiveMirrorViewer? {
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

    private func activeMirrorSessionMatches(_ sessionID: String?) -> Bool {
        guard let sessionID else { return true }
        return activeMirrorSessionID == nil || activeMirrorSessionID == sessionID
    }

    private func addActiveMirrorViewer(_ viewer: ActiveMirrorViewer) {
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
    private func removeActiveMirrorViewer(
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

    private func clearAllActiveMirrorViewers() {
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

    private func publishActiveMirrorViewerCount() {
        MacMediaActiveSessionRegistry.shared.setCount(activeMirrorViewers.count, for: .screenShare)
    }

    private func broadcastMirrorAck(
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
            try? await session.replySender(frame)
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

    private func macPresenceCapabilities() -> [String] {
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
    private static let cachedLocalStreamingCapabilities: MercuryStreamingCapabilitySnapshot =
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

    // MARK: - Private

    private func installHostAuthGateListeners() {
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

    private nonisolated static func hostAuthGateClosedReason(from note: Notification) -> String? {
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

    private nonisolated static func hostAuthGateOpenedReason(from note: Notification) -> String? {
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

    private func scheduleRemoteUnlockResumeCheck(reason: String) {
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

    private func scheduleRemoteUnlockResumePoll(
        reason: String,
        initialDelayNanoseconds: UInt64,
        maxAttempts: Int = 24
    ) {
        guard shouldKeepMirrorAliveForRemoteUnlock(currentMirrorSessions()) else { return }
        remoteUnlockResumeTask?.cancel()
        remoteUnlockResumeTask = Task { @MainActor [weak self] in
            if initialDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: initialDelayNanoseconds)
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
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
            Self.log.info("router_remote_unlock_resume_poll_still_locked reason=\(reason, privacy: .public)")
            Self.debugTrace("router_remote_unlock_resume_poll_still_locked reason=\(reason)")
        }
    }

    private func handleRemoteUnlockHostUnlocked(reason: String) async {
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

    private func streamingCapabilities(
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

    private func startNormalCapture(for viewer: ActiveMirrorViewer) async throws {
        guard let mirrorRequest = viewer.frame.media?.mirrorRequest,
              let factory = mirrorSinkFactory else {
            throw MediaSessionError.captureFailed
        }
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

    private static func effectiveFocusFollowMode(
        for request: HermesRealtimeRelayMirrorRequest,
        requestedMode: AgentFocusFollowMode?
    ) -> AgentFocusFollowMode {
        guard request.streamClass == MediaStreamClass.controlSurfaceFrame.rawValue else {
            return .off
        }
        return requestedMode ?? .smart
    }

    private func handleHostAuthGateClosed(reason: String) async {
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

    private func activeRemoteUnlockSessionID(in activeViewers: [ActiveMirrorViewer]) -> String? {
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

    private func shouldKeepMirrorAliveForRemoteUnlock(_ activeViewers: [ActiveMirrorViewer]) -> Bool {
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

    private func remoteUnlockSessionForLockedMirror(
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

    private func remoteUnlockSessionRequiredState(
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

    private func remoteUnlockMirrorDenialReason(
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

    private func handleMirrorRequest(
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

    private func handleMirrorStop(frame: HermesRealtimeRelayFrame, controlStreamID: UUID?) async {
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

    private func handleMirrorDisplaySelect(
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

    private func handleCallInvite(
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
            agentTerminalApproved: false
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

    private func beginMirror(for request: PendingRequest) async {
        let wasJoiningExistingSession = !activeMirrorViewers.isEmpty
        if !wasJoiningExistingSession {
            phase = .starting(requestID: request.id)
        }
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
           let reason = remoteUnlockMirrorDenialReason(
               request: mirrorRequest,
               session: remoteUnlockSession,
               remotePeerNodeID: request.remotePeerNodeID
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
                agentTerminalApproved: request.agentTerminalApproved
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
                frame: request.frame,
                replySender: request.replySender
            )
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

    private func startAcceptedMirrorRuntime(
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

    private func runAcceptedMirrorRuntime(
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
    private func launchInteractiveTerminalIfRequested(
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

    private func failAcceptedMirrorRuntime(
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

    private func request(
        _ request: PendingRequest,
        matchesClosedConnectionID connectionID: String,
        controlStreamID: UUID?
    ) -> Bool {
        if let requestControlStreamID = request.controlStreamID {
            return requestControlStreamID == controlStreamID
        }
        return request.frame.connectionId == connectionID
    }

    private func request(
        _ viewer: ActiveMirrorViewer,
        matchesClosedConnectionID connectionID: String,
        controlStreamID: UUID?
    ) -> Bool {
        if let requestControlStreamID = viewer.controlStreamID {
            return requestControlStreamID == controlStreamID
        }
        return viewer.frame.connectionId == connectionID
    }

    private func activeSessionMatches(connectionID: String, controlStreamID: UUID?) -> Bool {
        guard let activeSessionFrame else { return false }
        if let activeSessionControlStreamID {
            return activeSessionControlStreamID == controlStreamID
        }
        return activeSessionFrame.connectionId == connectionID
    }

    private func activeSessionAcceptsExplicitControlFrame(connectionID: String, controlStreamID: UUID?) -> Bool {
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

    private func isActiveMirrorRequest(_ request: PendingRequest) -> Bool {
        activeSessionMatches(
            connectionID: request.frame.connectionId,
            controlStreamID: request.controlStreamID
        )
            && activeSessionFrame?.media?.mirrorRequest?.requestId == request.id
    }

    private func clearActiveSessionState() {
        activeSessionSender = nil
        activeSessionFrame = nil
        activeSessionControlStreamID = nil
    }

    private func respond(
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
            streamingCapabilities: Self.cachedLocalStreamingCapabilities.wireValue
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

    private func respondToCall(
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

    private func startCooldown(seconds: Int) {
        cooldownTask?.cancel()
        var remaining = seconds
        phase = .cooldown(secondsRemaining: remaining)
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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

    private func getBlurredWallpaperBase64() -> String? {
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

private struct MercuryRemoteAccessAgentClient: Sendable {
    private static let socketPath = "/var/run/openburnbar-remote-access-agent.sock"
    private static let maximumResponseBytes = 16 * 1024
    private static let requestIOTimeoutSeconds: time_t = 3

    func wakeDisplay() async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.send(MercuryRemoteAccessAgentRequest(operation: "wakeDisplay", password: nil))
        }.value
    }

    private static func send(_ request: MercuryRemoteAccessAgentRequest) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MercuryRemoteAccessAgentClientError.socketUnavailable }
        defer { close(fd) }
        configureSocket(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw MercuryRemoteAccessAgentClientError.socketPathTooLong }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw MercuryRemoteAccessAgentClientError.daemonUnavailable }

        var data = try JSONEncoder().encode(request)
        data.append(0x0a)
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw MercuryRemoteAccessAgentClientError.timedOut }
                    throw MercuryRemoteAccessAgentClientError.writeFailed
                }
                written += count
            }
        }
        shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw MercuryRemoteAccessAgentClientError.timedOut }
                throw MercuryRemoteAccessAgentClientError.readFailed
            }
            responseData.append(buffer, count: count)
            if responseData.count > maximumResponseBytes { throw MercuryRemoteAccessAgentClientError.responseTooLarge }
        }
        guard let response = try? JSONDecoder().decode(MercuryRemoteAccessAgentResponse.self, from: responseData),
              response.ok else {
            throw MercuryRemoteAccessAgentClientError.daemonRejected
        }
    }

    private static func configureSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: requestIOTimeoutSeconds, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length)
    }
}

private struct MercuryRemoteAccessAgentRequest: Encodable, Sendable {
    var operation: String
    var password: String?
}

private struct MercuryRemoteAccessAgentResponse: Decodable, Sendable {
    var ok: Bool
}

private enum MercuryRemoteAccessAgentClientError: Error {
    case socketUnavailable
    case socketPathTooLong
    case daemonUnavailable
    case timedOut
    case writeFailed
    case readFailed
    case responseTooLarge
    case daemonRejected
}

private extension String {
    var nilIfEmptyForMercury: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var canonicalMercuryPeerNodeID: String? {
        nilIfEmptyForMercury?.lowercased()
    }
}

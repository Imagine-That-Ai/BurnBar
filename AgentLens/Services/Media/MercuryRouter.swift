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
    internal static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")
    internal static let remoteUnlockSessionRequiredDetail = "remote_unlock_session_required"
    internal static func peerNodeIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.canonicalMercuryPeerNodeID,
              let rhs = rhs?.canonicalMercuryPeerNodeID else {
            return false
        }
        return lhs == rhs
    }

    internal static func debugTrace(_ message: String) {
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
        internal let frame: HermesRealtimeRelayFrame
        /// The reply sender that delivered this request. Stored here so
        /// `respond()` can emit the ack on the correct stream even when
        /// interleaved presence heartbeats have arrived since.
        internal let replySender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)
        /// Per-control-stream lease ID from `MacFileTransferService`. iPhone
        /// and Android can share a Mac pairing `connectionID`; this keeps
        /// ownership tied to the exact stream that requested it.
        internal let controlStreamID: UUID?
        /// Authenticated iroh NodeId for the remote endpoint that opened the
        /// control stream. Request payload peer IDs are untrusted until they
        /// match this transport identity.
        internal let remotePeerNodeID: String?
        internal let agentTerminalApproved: Bool

        var requestsAgentTerminal: Bool {
            guard let terminal = frame.media?.mirrorRequest?.agentTerminal else { return false }
            return terminal.interactive && !terminal.runtimeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var agentTerminalRuntimeName: String? {
            frame.media?.mirrorRequest?.agentTerminal?.runtimeId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmptyForMercury
        }

        internal func approvingAgentTerminal() -> PendingRequest {
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

    @Published internal(set) var phase: Phase = .idle
    @Published internal(set) var lastError: String?
    @Published internal(set) var pendingRequest: PendingRequest?
    @Published internal(set) var pendingCall: PendingRequest?

    internal let sessionCoordinator: MediaSessionCoordinator
    internal let peerSource: MercuryPeerSource
    internal let consentStore: MercuryConsentStore
    internal let cooldownSeconds: TimeInterval
    internal let clock: @Sendable () -> Date
    internal let startScreenShare: ScreenShareStarter
    internal let ensureComputerUseSession: ComputerUseSessionEnsurer?
    internal let applyFocusFollowMode: FocusFollowModeApplier?
    internal let maxMirrorViewers: Int
    internal let remoteUnlockReadiness: MacRemoteUnlockReadinessService

    internal var mirrorSinkFactory: MirrorSinkFactory?
    /// The frame + reply sender from the most recently accepted request.
    /// Used by `stopMirror` so we can emit a `denied` ack when the host
    /// ends the mirror via the CallHUD, even though `pendingRequest` was
    /// cleared on accept.
    internal var activeSessionSender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)?
    internal var activeSessionFrame: HermesRealtimeRelayFrame?
    internal var activeSessionControlStreamID: UUID?
    internal struct ActiveMirrorViewer {
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
    internal var activeMirrorSessionID: String?
    internal var activeMirrorViewers: [String: ActiveMirrorViewer] = [:]
    internal var activeMirrorViewOrder: [String] = []
    internal var activeControlViewerID: String?
    internal var activeSelectedDisplayID: String?
    internal var remoteStreamingCapabilitiesByConnectionID: [String: MercuryStreamingCapabilitySnapshot] = [:]
    internal var remoteStreamingCapabilitiesByControlStreamID: [UUID: MercuryStreamingCapabilitySnapshot] = [:]
    internal var cooldownTask: Task<Void, Never>?
    internal var remoteUnlockResumeTask: Task<Void, Never>?
    internal var mirrorStartupTasks: [String: Task<Void, Never>] = [:]
    internal var mirrorStartupTaskIDs: [String: UUID] = [:]
    internal nonisolated(unsafe) var workspaceAuthGateObservers: [NSObjectProtocol] = []

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
}

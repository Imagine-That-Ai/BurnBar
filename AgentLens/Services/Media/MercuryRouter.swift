import Foundation
import Combine
import OpenBurnBarCore
import OpenBurnBarMedia

/// Mac-side brain for Mercury Phase 8 user-facing entry points. Owns:
///
///   • Inbound `media.mirror.request` triage — cooldown gating,
///     consent fast-path, ringing phase that surfaces
///     `IncomingCallSheet` at the app scene root.
///   • Inbound `media.presence.heartbeat` forwarding to
///     `MercuryPeerSource` so the popover knows when the iPhone is
///     online.
///   • Acceptance — drives `MediaSessionCoordinator.startScreenShare`
///     with a caller-provided sink, then emits the corresponding
///     `media.mirror.ack` via the same control-stream `replySender`
///     that delivered the request.
///   • Cooldown — after decline or stop, holds for a configurable
///     window so the iPhone can't spam the Mac with retries.
///
/// `MercuryRouter` is constructed by `OpenBurnBarRuntimeContext` and
/// attached to `MacFileTransferService.setMercuryDispatcher` so the
/// existing control-stream read loop fans non-blob frames into it.
@MainActor
final class MercuryRouter: ObservableObject {

    enum Phase: Equatable {
        case idle
        case ringing(requestID: String, requesterName: String, requestedAt: Date)
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
        _ frame: HermesRealtimeRelayFrame
    ) async throws -> MediaStreamSink

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var pendingRequest: PendingRequest?

    private let sessionCoordinator: MediaSessionCoordinator
    private let peerSource: MercuryPeerSource
    private let consentStore: MercuryConsentStore
    private let cooldownSeconds: TimeInterval
    private let clock: @Sendable () -> Date

    private var mirrorSinkFactory: MirrorSinkFactory?
    /// The frame + reply sender from the most recently accepted request.
    /// Used by `stopMirror` so we can emit a `denied` ack when the host
    /// ends the mirror via the CallHUD, even though `pendingRequest` was
    /// cleared on accept.
    private var activeSessionSender: (@Sendable (HermesRealtimeRelayFrame) async throws -> Void)?
    private var activeSessionFrame: HermesRealtimeRelayFrame?
    private var cooldownTask: Task<Void, Never>?

    init(
        sessionCoordinator: MediaSessionCoordinator,
        peerSource: MercuryPeerSource,
        consentStore: MercuryConsentStore,
        cooldownSeconds: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.peerSource = peerSource
        self.consentStore = consentStore
        self.cooldownSeconds = cooldownSeconds
        self.clock = clock
    }

    /// Inject the sink factory once the iroh per-GOP dial is available.
    func setMirrorSinkFactory(_ factory: @escaping MirrorSinkFactory) {
        self.mirrorSinkFactory = factory
    }

    /// Closure entry point handed to `MacFileTransferService` via
    /// `setMercuryDispatcher`. Routes by frame type. Mirror frames
    /// capture the reply sender in the `PendingRequest` so later
    /// accepts/declines send acks on the correct stream.
    func handleFrame(
        _ frame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        switch frame.type {
        case .mediaPresenceHeartbeat:
            if let heartbeat = frame.media?.presence {
                peerSource.ingestHeartbeat(
                    heartbeat,
                    connectionID: frame.connectionId
                )
            }
        case .mediaMirrorRequest:
            await handleMirrorRequest(frame: frame, replySender: replySender)
        case .mediaMirrorAck:
            // Mac is the producer of acks, not the consumer. Ignore.
            break
        default:
            break
        }
    }

    /// User tapped "Accept" on the incoming-call sheet.
    func acceptMirror(_ request: PendingRequest) async {
        await beginMirror(for: request)
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

    /// User tapped "Stop" on the CallHUD during an active mirror.
    func stopMirror() async {
        await sessionCoordinator.stop(reason: .completedUserCancel)
        let requestID: String
        switch phase {
        case .streaming(let id, _),
             .starting(let id):
            requestID = id
        default:
            requestID = ""
        }
        if !requestID.isEmpty,
           let sender = activeSessionSender,
           let sessionFrame = activeSessionFrame {
            await respond(
                requestID: requestID,
                decision: .denied,
                detail: "Host ended mirror",
                frame: sessionFrame,
                replySender: sender
            )
        }
        pendingRequest = nil
        activeSessionSender = nil
        activeSessionFrame = nil
        startCooldown(seconds: Int(cooldownSeconds))
    }

    // MARK: - Private

    private func handleMirrorRequest(
        frame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        guard let req = frame.media?.mirrorRequest else { return }

        // Cooldown short-circuit — never bother the user mid-cooldown.
        if case let .cooldown(remaining) = phase {
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

        // Busy short-circuit — one mirror at a time.
        if case .streaming = phase {
            await respond(
                requestID: req.requestId,
                decision: .busy,
                detail: "Another mirror is in progress",
                frame: frame,
                replySender: replySender
            )
            return
        }
        if case .starting = phase {
            await respond(
                requestID: req.requestId,
                decision: .busy,
                detail: "A mirror is starting",
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
            replySender: replySender
        )

        // Consent fast-path: if the user has flipped "Always allow my
        // iPhone to mirror", auto-accept and bypass the ringing UI.
        if consentStore.alwaysAllow {
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
    }

    private func beginMirror(for request: PendingRequest) async {
        phase = .starting(requestID: request.id)
        pendingRequest = nil
        guard let factory = mirrorSinkFactory else {
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
        do {
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
            let sink = try await factory(mirrorRequest, request.frame)
            try await sessionCoordinator.startScreenShare(
                peerDeviceID: request.frame.connectionId,
                sink: sink,
                streamClassOverride: .screenVideo
            )
            await respond(
                requestID: request.id,
                decision: .accepted,
                detail: nil,
                frame: request.frame,
                replySender: request.replySender
            )
            // Remember the session so stopMirror can ack when the
            // host ends the mirror via the CallHUD.
            activeSessionSender = request.replySender
            activeSessionFrame = request.frame
            phase = .streaming(requestID: request.id, since: clock())
        } catch {
            lastError = error.localizedDescription
            await respond(
                requestID: request.id,
                decision: .unsupported,
                detail: error.localizedDescription,
                frame: request.frame,
                replySender: request.replySender
            )
            phase = .idle
        }
    }

    private func respond(
        requestID: String,
        decision: HermesRealtimeRelayMirrorAck.Decision,
        detail: String?,
        cooldownSecondsRemaining: Int? = nil,
        frame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        let ack = HermesRealtimeRelayMirrorAck(
            requestId: requestID,
            decision: decision,
            detail: detail,
            cooldownSecondsRemaining: cooldownSecondsRemaining
        )
        let outbound = HermesRealtimeRelayFrame(
            type: .mediaMirrorAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: requestID,
            media: HermesRealtimeRelayMediaPayload(mirrorAck: ack)
        )
        try? await replySender(outbound)
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
}

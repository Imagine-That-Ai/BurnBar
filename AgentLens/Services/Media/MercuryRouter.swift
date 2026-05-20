import Foundation
import Combine
import OpenBurnBarCore
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
    private static let log = Logger(subsystem: "com.openburnbar.app", category: "Mercury")
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
    @Published private(set) var pendingCall: PendingRequest?

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
        Self.log.info("router_handle_frame type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
        switch frame.type {
        case .mediaPresenceHeartbeat:

            if let heartbeat = frame.media?.presence {
                peerSource.ingestHeartbeat(
                    heartbeat,
                    connectionID: frame.connectionId
                )

                // Reply with our own presence heartbeat containing capabilities and blurred wallpaper base64
                let macCapabilities = [
                    MercuryPeer.Feature.mirrorHost.rawValue,
                    MercuryPeer.Feature.fileSend.rawValue,
                    MercuryPeer.Feature.fileReceive.rawValue,
                    MercuryPeer.Feature.callReceive.rawValue
                ]
                let blurredWallpaper = getBlurredWallpaperBase64()
                let responseBeat = HermesRealtimeRelayPresenceHeartbeat(
                    sentAt: Date(),
                    deviceDisplayName: Host.current().localizedName ?? "My Mac",
                    capabilities: macCapabilities,
                    blurredWallpaperBase64: blurredWallpaper
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
            await handleMirrorRequest(frame: frame, replySender: replySender)
        case .mediaMirrorStop:
            await handleMirrorStop(frame: frame)
        case .mediaMirrorAck:
            // Mac is the producer of acks, not the consumer. Ignore.
            break
        case .mediaCallInvite:
            await handleCallInvite(frame: frame, replySender: replySender)
        case .mediaCallAck:
            // Mac is the producer of call acks, not the consumer. Ignore.
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
        guard let req = frame.media?.mirrorRequest else {
            Self.log.error("router_mirror_request_missing_payload requestID=\(frame.requestId ?? "", privacy: .public)")
            Self.debugTrace("router_mirror_request_missing_payload requestID=\(frame.requestId ?? "")")
            return
        }
        Self.log.info("router_mirror_request_received requestID=\(req.requestId, privacy: .public) requester=\(req.requesterDisplayName, privacy: .public)")
        Self.debugTrace("router_mirror_request_received requestID=\(req.requestId) requester=\(req.requesterDisplayName)")

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

        // Busy short-circuit — one mirror at a time.
        if case .streaming = phase {
            Self.log.info("router_mirror_request_busy_streaming requestID=\(req.requestId, privacy: .public)")
            Self.debugTrace("router_mirror_request_busy_streaming requestID=\(req.requestId)")
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
            Self.log.info("router_mirror_request_busy_starting requestID=\(req.requestId, privacy: .public)")
            Self.debugTrace("router_mirror_request_busy_starting requestID=\(req.requestId)")
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

    private func handleMirrorStop(frame: HermesRealtimeRelayFrame) async {
        guard let stop = frame.media?.mirrorStop else {
            Self.log.error("router_mirror_stop_missing_payload requestID=\(frame.requestId ?? "", privacy: .public)")
            Self.debugTrace("router_mirror_stop_missing_payload requestID=\(frame.requestId ?? "")")
            return
        }
        let activeRequestID: String?
        switch phase {
        case .streaming(let requestID, _),
             .starting(let requestID):
            activeRequestID = requestID
        default:
            activeRequestID = nil
        }
        guard activeRequestID == stop.requestId else {
            Self.log.info("router_mirror_stop_ignored requestID=\(stop.requestId, privacy: .public) phase_mismatch=true")
            Self.debugTrace("router_mirror_stop_ignored requestID=\(stop.requestId) phase=\(String(describing: phase))")
            return
        }
        await sessionCoordinator.stop(reason: .completedUserCancel)
        pendingRequest = nil
        activeSessionSender = nil
        activeSessionFrame = nil
        phase = .idle
        Self.log.info("router_mirror_stop_completed requestID=\(stop.requestId, privacy: .public)")
        Self.debugTrace("router_mirror_stop_completed requestID=\(stop.requestId)")
    }

    private func handleCallInvite(
        frame: HermesRealtimeRelayFrame,
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
            replySender: replySender
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
        phase = .starting(requestID: request.id)
        pendingRequest = nil
        guard let factory = mirrorSinkFactory else {
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
            Self.log.error("router_mirror_start_failed requestID=\(request.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            Self.debugTrace("router_mirror_start_failed requestID=\(request.id) error=\(error.localizedDescription)")
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
        var wallpaperURL: URL? = nil
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

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
import OSLog

/// iOS-side owner of the persistent media control stream. Risk-1 fix for
/// the Mac → iOS push gap: rather than waiting for an active chat
/// response stream to piggyback on, the coordinator dials Mac once when
/// the Hermes session is up and keeps a single bi-stream open dedicated
/// to `media.blob.advertise` / `media.blob.ack` frames in both
/// directions. The stream survives chat-request churn and gives the Mac
/// a reliable "always available" outbound channel.
///
/// Lifecycle:
///   1. `start(uid:connectionID:)` — dial Mac, send `media.classify` as
///      the first frame, spawn the read loop, schedule reconnect on
///      failure.
///   2. `send(frame:)` — outbound advertise/ack from the iOS side.
///   3. `stop()` — close the stream and cancel any pending reconnect.
///
/// Reconnect policy: exponential backoff with a 1 s floor and 30 s
/// ceiling. The control stream is cheap (one bi-stream per connection),
/// so the policy errs on the side of staying available — if iroh
/// transport fails, the cascade still falls back to per-request chat
/// piggyback inside `HermesIrohRelayTransport`.
@MainActor
final class MediaControlStreamCoordinator: ObservableObject {
    private static let log = Logger(subsystem: "com.openburnbar.mobile", category: "Mercury")
    private static func debugTrace(_ message: String) {
        #if DEBUG
        NSLog("OpenBurnBarMercury \(message)")
        #endif
    }

    typealias StreamDialer = @MainActor (
        _ uid: String,
        _ connectionID: String
    ) async throws -> any IrohRelayStream

    enum Phase: Equatable, Sendable {
        case idle
        case dialing
        case live
        case reconnecting(nextAttemptIn: TimeInterval)
        case stopped
        case failed(reason: String)
    }

    enum ControlStreamError: LocalizedError, Equatable {
        case timedOutWaitingForLiveStream
        case timedOutSendingFrame
        case notLive
        case macDidNotRespond

        var errorDescription: String? {
            switch self {
            case .timedOutWaitingForLiveStream:
                return "Mercury is still connecting. Try again after the Mac shows as online."
            case .timedOutSendingFrame:
                return "Mercury connected, but the Mac did not accept the control message in time."
            case .notLive:
                return "Mercury control stream is not live."
            case .macDidNotRespond:
                return "Mercury connected, but the Mac did not answer the control-stream probe."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var consecutiveDialFailures: Int = 0
    /// Most recent failure reason surfaced from a `.failed` transition.
    /// Survives the subsequent `.reconnecting` transitions so the viewer
    /// can show *why* Mercury lost contact. Cleared on `.live`.
    @Published private(set) var lastFailureReason: String?
    /// Wall-clock anchor for the active `.reconnecting` interval so the
    /// viewer can animate a real ticking countdown instead of a static
    /// `nextAttemptIn` value.
    @Published private(set) var reconnectAttemptStartedAt: Date?
    /// Wall-clock anchor for the most recent `.live` transition. Used by
    /// the viewer to show "last seen 12s ago" when the stream drops.
    @Published private(set) var lastLiveAt: Date?
    /// Wall-clock anchor for the most recent frame received from the Mac.
    /// A stream can become half-stale while local sends still return
    /// success; mirror requests require this to be fresh so `.live`
    /// means bidirectional, not merely dialed.
    @Published private(set) var lastInboundAt: Date?
    /// Most recent iOS heartbeat -> Mac reply -> iOS round-trip. The mirror
    /// HUD uses this instead of displaying a permanent zero while frames flow.
    @Published private(set) var lastRoundTripMillis: Int?
    var connectionID: String? { activeConnectionID }
    var sessionId: String? { activeConnectionID }

    private let dialer: StreamDialer
    private let receiver: iOSFileTransferService
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private let heartbeatInitialDelay: TimeInterval
    private let heartbeatInterval: TimeInterval

    private var currentStream: (any IrohRelayStream)?
    private var currentSendGate: IrohRelayStreamSendGate?
    private var supervisorTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingHeartbeatSentAt: Date?
    private var backgroundTrafficSuppressedUntil: Date?
    private var streamReadyContinuations: [UUID: CheckedContinuation<any IrohRelayStream, Error>] = [:]
    private var activeUID: String?
    private var activeConnectionID: String?
    private let mediaPacketCodec = MediaPacketCodec(maxPayloadBytes: MediaFrameV2Codec.defaultMaxPayloadBytes)
    private let mediaFrameV2Codec = MediaFrameV2Codec()
    private var frameChunkAssembler = MediaFrameChunkAssembler()

    /// Mercury Phase 8 — iOS receives ack frames from the Mac in
    /// response to `mediaMirrorRequest` sends. The Hermes Square root
    /// installs a handler that maps `.accepted` → push to
    /// `ScreenShareViewerView`; other decisions → surface a toast.
    var mirrorAckHandler: ((HermesRealtimeRelayMirrorAck) async -> Void)?

    /// Mercury Phase 8 — accepted mirror frames from the Mac. Frames arrive
    /// on the same long-lived `media.control` stream as the approval ack and
    /// are decoded from `media.stream.frame` envelopes.
    var mirrorFrameHandler: ((MediaFrame) async -> Void)?

    /// Negotiated MediaFrame v2 mirror frames. v1 remains the fallback, while
    /// v2 lets the receiver ACK LTR tokens after both sides promote the data
    /// path.
    var mirrorFrameV2Handler: ((MediaFrameV2) async -> Void)?

    /// Mercury Smart Zoom — focus-context updates arrive on
    /// `.mediaStreamFrame` envelopes carrying no encoded video bytes,
    /// just the `media.focusContext` field. Mirror surfaces install
    /// this handler to drive the local Smart Zoom reducer.
    var focusContextHandler: ((HermesRealtimeRelayFocusContext) async -> Void)?

    /// Mercury Phase 8 — Mac → iOS presence updates. The Hermes Square
    /// root installs `MercuryPeerSource.ingestHeartbeat(_:)` here so the
    /// paired-Mac tile and Live sheet reflect the Mac's current name and
    /// capabilities instead of relying only on fallback assumptions.
    var presenceHeartbeatHandler: ((HermesRealtimeRelayPresenceHeartbeat) async -> Void)?

    /// Phone-control denials ride the same Mercury control stream as
    /// mirror acks. Mirror surfaces install this so failed taps/scrolls
    /// produce an actionable status instead of looking like dead tools.
    var controlDeniedHandler: ((HermesRealtimeRelayControlDenied) async -> Void)?

    /// Explicit remote-clipboard responses from the Mac. Mirror surfaces
    /// match request IDs here before reading or writing the phone pasteboard.
    var clipboardResponseHandler: ((HermesRealtimeRelayClipboardResponse) async -> Void)?
    var remoteUnlockStateHandler: ((HermesRealtimeRelayRemoteUnlockState) async -> Void)?
    var remoteUnlockResultHandler: ((HermesRealtimeRelayRemoteUnlockResult) async -> Void)?

    /// Mercury Phase 8 — opt-in display name that piggybacks on the
    /// presence heartbeat so the Mac can render it in the popover.
    /// Defaults to `UIDevice.current.name` at start time but can be
    /// overridden by tests or accessibility paths.
    var heartbeatDeviceNameProvider: @MainActor () -> String = {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ""
        #endif
    }

    init(
        dialer: @escaping StreamDialer,
        receiver: iOSFileTransferService,
        initialBackoff: TimeInterval = 1.0,
        maxBackoff: TimeInterval = 8.0,
        heartbeatInitialDelay: TimeInterval = 5.0,
        heartbeatInterval: TimeInterval = 60.0
    ) {
        self.dialer = dialer
        self.receiver = receiver
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.heartbeatInitialDelay = heartbeatInitialDelay
        self.heartbeatInterval = heartbeatInterval
    }

    func start(uid: String, connectionID: String) {
        guard supervisorTask == nil else { return }
        activeUID = uid
        activeConnectionID = connectionID
        phase = .dialing
        supervisorTask = Task { [weak self] in
            await self?.runSupervisor(uid: uid, connectionID: connectionID)
        }
    }

    func stop() async {
        supervisorTask?.cancel()
        supervisorTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let currentStream {
            await currentStream.close()
        }
        currentStream = nil
        currentSendGate = nil
        for continuation in streamReadyContinuations.values {
            continuation.resume(throwing: CancellationError())
        }
        streamReadyContinuations.removeAll()
        phase = .stopped
        activeUID = nil
        activeConnectionID = nil
        reconnectAttemptStartedAt = nil
        lastFailureReason = nil
        lastInboundAt = nil
        lastRoundTripMillis = nil
        pendingHeartbeatSentAt = nil
        backgroundTrafficSuppressedUntil = nil
    }

    /// Outbound send entry point. Blocks until the stream is live (or
    /// the supervisor gives up) so iOS-initiated sends don't race the
    /// initial dial.
    func send(frame: HermesRealtimeRelayFrame, timeout: TimeInterval = 8) async throws {
        let isBackgroundFrame = frame.type == .mediaPresenceHeartbeat
        if isBackgroundFrame, isBackgroundTrafficSuppressed {
            return
        }
        if activeUID != frame.uid || activeConnectionID != frame.connectionId {
            Self.log.info("control_stream_send_retarget fromConnectionID=\(self.activeConnectionID ?? "", privacy: .public) toConnectionID=\(frame.connectionId, privacy: .public)")
            Self.debugTrace("control_stream_send_retarget fromConnectionID=\(activeConnectionID ?? "") toConnectionID=\(frame.connectionId)")
            await stop()
            start(uid: frame.uid, connectionID: frame.connectionId)
        }
        if !isBackgroundFrame {
            suspendBackgroundTraffic(for: max(timeout, 15.0))
        }
        let stream = try await awaitLiveStream(timeout: timeout)
        Self.log.info("control_stream_send type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
        Self.debugTrace("control_stream_send type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "") connectionID=\(frame.connectionId)")
        do {
            if let currentSendGate {
                try await Self.withTimeout(seconds: timeout) {
                    try await currentSendGate.send(frame)
                }
            } else {
                try await Self.withTimeout(seconds: timeout) {
                    try await stream.send(frame)
                }
            }
        } catch ControlStreamError.timedOutSendingFrame {
            Self.log.error("control_stream_send_timeout type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
            Self.debugTrace("control_stream_send_timeout type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "") connectionID=\(frame.connectionId)")
            await invalidateCurrentStreamAfterTimedOutSend()
            throw ControlStreamError.timedOutSendingFrame
        }
        if !isBackgroundFrame,
           phase == .live,
           let uid = activeUID,
           let connectionID = activeConnectionID,
           heartbeatTask == nil,
           !isBackgroundTrafficSuppressed {
            startHeartbeatIfNeeded(uid: uid, connectionID: connectionID)
        }
    }

    /// Presence is useful status, not a prerequisite for user actions. Keep it
    /// off the shared send lane while a mirror request or Remote Unlock entry is
    /// in flight so a wedged heartbeat cannot reset the visible workflow.
    func suspendBackgroundTraffic(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(max(0, duration))
        if let current = backgroundTrafficSuppressedUntil, current > deadline {
            return
        }
        backgroundTrafficSuppressedUntil = deadline
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func sendLongTermReferenceAcknowledgement(
        token: MercuryLTRToken,
        requestId: String? = nil,
        timeout: TimeInterval = 8
    ) async throws {
        guard let uid = activeUID, let connectionID = activeConnectionID else {
            throw ControlStreamError.notLive
        }
        let ack = HermesRealtimeRelayLongTermReferenceAck(
            requestId: requestId,
            tokenValue: token.value
        )
        try await send(
            frame: HermesRealtimeRelayFrame(
                type: .mediaLongTermReferenceAck,
                uid: uid,
                connectionId: connectionID,
                requestId: requestId,
                media: HermesRealtimeRelayMediaPayload(longTermReferenceAck: ack)
            ),
            timeout: timeout
        )
    }

    func sendMirrorStop(
        requestId: String,
        sessionId: String? = nil,
        reason: String? = nil,
        timeout: TimeInterval = 8
    ) async throws {
        guard let uid = activeUID, let connectionID = activeConnectionID else {
            throw ControlStreamError.notLive
        }
        let stop = HermesRealtimeRelayMirrorStop(
            requestId: requestId,
            sessionId: sessionId,
            stoppedAt: Date(),
            reason: reason
        )
        try await send(
            frame: HermesRealtimeRelayFrame(
                type: .mediaMirrorStop,
                uid: uid,
                connectionId: connectionID,
                requestId: requestId,
                media: HermesRealtimeRelayMediaPayload(mirrorStop: stop)
            ),
            timeout: timeout
        )
    }

    /// Ensure the current control stream is truly bidirectional before a
    /// request that needs an immediate Mac response. Iroh can leave a stream
    /// in a half-stale state where local writes return success but the Mac no
    /// longer receives them; a fresh Mac heartbeat reply is the cheapest
    /// proof that mirror requests and phone-control input will make it through.
    func ensureResponsive(
        uid: String,
        connectionID: String,
        freshnessInterval: TimeInterval = 8,
        probeTimeout: TimeInterval = 2.5,
        restartTimeout: TimeInterval = 6
    ) async throws {
        if activeUID == uid,
           activeConnectionID == connectionID,
           phase == .live,
           let lastInboundAt,
           Date().timeIntervalSince(lastInboundAt) <= freshnessInterval {
            return
        }

        if activeUID == uid,
           activeConnectionID == connectionID,
           phase == .live,
           await probeMac(uid: uid, connectionID: connectionID, timeout: probeTimeout) {
            return
        }

        Self.log.info("control_stream_probe_restart connectionID=\(connectionID, privacy: .public)")
        Self.debugTrace("control_stream_probe_restart connectionID=\(connectionID)")
        await stop()
        start(uid: uid, connectionID: connectionID)
        _ = try await awaitLiveStream(timeout: restartTimeout)
        guard await probeMac(uid: uid, connectionID: connectionID, timeout: probeTimeout) else {
            throw ControlStreamError.macDidNotRespond
        }
    }

    private func awaitLiveStream(timeout: TimeInterval) async throws -> any IrohRelayStream {
        if let currentStream, phase == .live {
            return currentStream
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any IrohRelayStream, Error>) in
                streamReadyContinuations[waiterID] = continuation
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if let continuation = self.streamReadyContinuations.removeValue(forKey: waiterID) {
                        continuation.resume(throwing: ControlStreamError.timedOutWaitingForLiveStream)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                if let continuation = self.streamReadyContinuations.removeValue(forKey: waiterID) {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func resolvePending(with stream: any IrohRelayStream) {
        let waiting = streamReadyContinuations
        streamReadyContinuations.removeAll()
        for continuation in waiting.values {
            continuation.resume(returning: stream)
        }
    }

    private func runSupervisor(uid: String, connectionID: String) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                phase = .dialing
                let stream = try await dialer(uid, connectionID)
                let sendGate = IrohRelayStreamSendGate(stream: stream)
                let classifyFrame = HermesRealtimeRelayFrame(
                    type: .mediaClassify,
                    uid: uid,
                    connectionId: connectionID,
                    media: HermesRealtimeRelayMediaPayload(
                        streamClass: MediaStreamClass.control.rawValue
                    )
                )
                try await sendGate.send(classifyFrame)
                currentStream = stream
                currentSendGate = sendGate
                consecutiveDialFailures = 0
                attempt = 0
                phase = .live
                lastLiveAt = Date()
                lastFailureReason = nil
                reconnectAttemptStartedAt = nil
                Self.log.info("control_stream_live connectionID=\(connectionID, privacy: .public)")
                Self.debugTrace("control_stream_live connectionID=\(connectionID)")
                resolvePending(with: stream)

                // Mercury Phase 8 — spawn the heartbeat task once the
                // stream is live. Cancelled inside `stop()` or when the
                // supervisor loop iterates after a peer-close. The loop
                // itself skips sends while background traffic is suppressed.
                startHeartbeatIfNeeded(uid: uid, connectionID: connectionID)

                // Drive the read loop. When it returns (peer close or
                // error) we'll fall through to the reconnect arm.
                await readLoop(stream: stream, uid: uid, connectionID: connectionID)

                heartbeatTask?.cancel()
                heartbeatTask = nil
                currentStream = nil
                currentSendGate = nil
                if Task.isCancelled { break }
                await stream.close()
                if lastFailureReason == nil {
                    lastFailureReason = "Mac closed the control stream."
                }
                // Peer closed cleanly — quick retry once before the
                // exponential backoff kicks in.
                attempt = max(0, attempt - 1)
            } catch is CancellationError {
                break
            } catch {
                consecutiveDialFailures += 1
                lastFailureReason = error.localizedDescription
                Self.log.error("control_stream_dial_failed connectionID=\(connectionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                Self.debugTrace("control_stream_dial_failed connectionID=\(connectionID) error=\(error.localizedDescription)")
                phase = .failed(reason: error.localizedDescription)
            }

            let backoff = nextBackoff(attempt: attempt)
            attempt += 1
            reconnectAttemptStartedAt = Date()
            phase = .reconnecting(nextAttemptIn: backoff)
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
        phase = .stopped
        reconnectAttemptStartedAt = nil
    }

    private func readLoop(
        stream: any IrohRelayStream,
        uid: String,
        connectionID: String
    ) async {
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = {
            [currentSendGate, stream] outbound in
            if let currentSendGate {
                try await currentSendGate.send(outbound)
            } else {
                try await stream.send(outbound)
            }
        }
        do {
            while let frame = try await stream.receive() {
                guard frame.uid == uid, frame.connectionId == connectionID else { continue }
                lastInboundAt = Date()
                Self.log.info("control_stream_receive type=\(frame.type.rawValue, privacy: .public) requestID=\(frame.requestId ?? "", privacy: .public) connectionID=\(frame.connectionId, privacy: .public)")
                Self.debugTrace("control_stream_receive type=\(frame.type.rawValue) requestID=\(frame.requestId ?? "") connectionID=\(frame.connectionId)")
                switch frame.type {
                case .mediaBlobAdvertise:
                    await receiver.handleAdvertise(frame: frame, ackSender: ackSender)
                case .mediaBlobAck:
                    // Acks for iOS-initiated sends — surface them so the
                    // attachment row can flip from "in flight" to
                    // "delivered". For Phase 1b we only need to log;
                    // Phase 2 wires this into per-row UI state.
                    break
                case .mediaMirrorAck:
                    if let ack = frame.media?.mirrorAck,
                       let handler = mirrorAckHandler {
                        await handler(ack)
                    }
                case .mediaStreamFrame:
                    if let focus = frame.media?.focusContext,
                       let handler = focusContextHandler {
                        await handler(focus)
                    }
                    guard frame.media?.streamClass == MediaStreamClass.screenVideo.rawValue,
                          let encoded = frame.media?.encodedFrameBase64,
                          let chunkData = Data(base64Encoded: encoded),
                          let data = frameChunkAssembler.accept(
                            chunk: frame.media?.frameChunk,
                            bytes: chunkData
                          ) else {
                        continue
                    }
                    do {
                        if MediaFrameV2Codec.isEncodedEnvelope(data),
                           let handler = mirrorFrameV2Handler {
                            let decoded = try mediaFrameV2Codec.decode(data).frame
                            await handler(decoded)
                        } else if let handler = mirrorFrameHandler {
                            let decoded = try mediaPacketCodec.decode(data).frame
                            await handler(decoded)
                        }
                    } catch {
                        continue
                    }
                case .mediaMirrorRequest:
                    // iOS is the requester, not the receiver.
                    continue
                case .mediaPresenceHeartbeat:
                    if let pendingHeartbeatSentAt {
                        lastRoundTripMillis = max(0, Int(Date().timeIntervalSince(pendingHeartbeatSentAt) * 1_000))
                        self.pendingHeartbeatSentAt = nil
                    }
                    if let heartbeat = frame.media?.presence,
                       let handler = presenceHeartbeatHandler {
                        await handler(heartbeat)
                    }
                    continue
                case .controlDenied:
                    if let denied = frame.control?.denied,
                       let handler = controlDeniedHandler {
                        await handler(denied)
                    }
                    continue
                case .controlClipboardResponse:
                    if let response = frame.control?.clipboardResponse,
                       let handler = clipboardResponseHandler {
                        await handler(response)
                    }
                    continue
                case .remoteUnlockState:
                    if let state = frame.control?.remoteUnlockState,
                       let handler = remoteUnlockStateHandler {
                        await handler(state)
                    }
                    continue
                case .remoteUnlockResult, .remoteUnlockDenied:
                    if let result = frame.control?.remoteUnlockResult,
                       let handler = remoteUnlockResultHandler {
                        await handler(result)
                    }
                    continue
                case .mediaClassify:
                    // Re-classification mid-stream — protocol noise.
                    continue
                default:
                    continue
                }
            }
        } catch {
            // Surface as a soft failure; supervisor handles reconnect.
            lastFailureReason = error.localizedDescription
            phase = .reconnecting(nextAttemptIn: initialBackoff)
        }
    }

    private func startHeartbeatIfNeeded(uid: String, connectionID: String) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            while !Task.isCancelled {
                let delay = self.pendingHeartbeatSentAt == nil
                    ? self.heartbeatInitialDelay
                    : self.heartbeatInterval
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard !self.isBackgroundTrafficSuppressed else { continue }
                await self.sendHeartbeat(uid: uid, connectionID: connectionID)
            }
        }
    }

    private var isBackgroundTrafficSuppressed: Bool {
        guard let deadline = backgroundTrafficSuppressedUntil else { return false }
        if deadline > Date() {
            return true
        }
        backgroundTrafficSuppressedUntil = nil
        return false
    }


    @discardableResult
    private func sendHeartbeat(
        uid: String,
        connectionID: String,
        timeout: TimeInterval = 8
    ) async -> Bool {
        guard !isBackgroundTrafficSuppressed else { return false }
        let beat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: heartbeatDeviceNameProvider(),
            capabilities: [
                MercuryPeer.Feature.mirrorViewer.rawValue,
                MercuryPeer.Feature.fileSend.rawValue,
                MercuryPeer.Feature.fileReceive.rawValue,
                MercuryPeer.Feature.callReceive.rawValue
            ],
            streamingCapabilities: MercuryVideoToolboxCapabilityProbe.snapshot(
                mediaFrameVersions: .v1AndV2
            ).wireValue
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(presence: beat)
        )
        let sentAt = Date()
        do {
            try await send(frame: frame, timeout: timeout)
            pendingHeartbeatSentAt = sentAt
            return true
        } catch {
            // The supervisor owns reconnects; heartbeat failure only means no
            // fresh RTT sample for the HUD.
            return false
        }
    }

    private func probeMac(uid: String, connectionID: String, timeout: TimeInterval) async -> Bool {
        let probeStartedAt = Date()
        guard await sendHeartbeat(uid: uid, connectionID: connectionID, timeout: timeout) else {
            return false
        }
        return await waitForInbound(after: probeStartedAt, timeout: timeout)
    }

    private func waitForInbound(after probeStartedAt: Date, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            if let lastInboundAt, lastInboundAt > probeStartedAt {
                return true
            }
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func nextBackoff(attempt: Int) -> TimeInterval {
        let exp = min(maxBackoff, initialBackoff * pow(2.0, Double(attempt)))
        // Decorrelated jitter: between initialBackoff and exp inclusive.
        let jitter = Double.random(in: initialBackoff ... exp)
        return min(maxBackoff, jitter)
    }

    private func invalidateCurrentStreamAfterTimedOutSend() async {
        lastFailureReason = ControlStreamError.timedOutSendingFrame.localizedDescription
        phase = .failed(reason: lastFailureReason ?? "Timed out sending Mercury control frame.")
        currentSendGate = nil
        let stream = currentStream
        currentStream = nil
        if let stream {
            await stream.close()
        }
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let clamped = max(0, seconds)
                try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                throw ControlStreamError.timedOutSendingFrame
            }
            guard let result = try await group.next() else {
                throw ControlStreamError.timedOutSendingFrame
            }
            group.cancelAll()
            return result
        }
    }
}

private actor IrohRelayStreamSendGate {
    private let stream: any IrohRelayStream

    init(stream: any IrohRelayStream) {
        self.stream = stream
    }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        try await stream.send(frame)
    }
}

private struct MediaFrameChunkAssembler {
    private struct Assembly {
        var chunkCount: Int
        var totalBytes: Int
        var chunks: [Data?]
    }

    private let maxAssemblies = 8
    private let maxTotalBytes = MediaFrameV2Codec.defaultMaxPayloadBytes + 4096
    private var assemblies: [String: Assembly] = [:]
    private var insertionOrder: [String] = []

    mutating func accept(
        chunk: HermesRealtimeRelayMediaFrameChunk?,
        bytes: Data
    ) -> Data? {
        guard let chunk else { return bytes }
        guard chunk.chunkCount > 0,
              chunk.chunkIndex >= 0,
              chunk.chunkIndex < chunk.chunkCount,
              chunk.totalBytes > 0,
              chunk.totalBytes <= maxTotalBytes else {
            assemblies.removeValue(forKey: chunk.chunkId)
            insertionOrder.removeAll { $0 == chunk.chunkId }
            return nil
        }

        if assemblies[chunk.chunkId] == nil {
            trimOldestIfNeeded()
            assemblies[chunk.chunkId] = Assembly(
                chunkCount: chunk.chunkCount,
                totalBytes: chunk.totalBytes,
                chunks: Array(repeating: nil, count: chunk.chunkCount)
            )
            insertionOrder.append(chunk.chunkId)
        }

        guard var assembly = assemblies[chunk.chunkId],
              assembly.chunkCount == chunk.chunkCount,
              assembly.totalBytes == chunk.totalBytes else {
            assemblies.removeValue(forKey: chunk.chunkId)
            insertionOrder.removeAll { $0 == chunk.chunkId }
            return nil
        }

        assembly.chunks[chunk.chunkIndex] = bytes
        assemblies[chunk.chunkId] = assembly
        guard assembly.chunks.allSatisfy({ $0 != nil }) else { return nil }

        let complete = assembly.chunks.reduce(into: Data(capacity: assembly.totalBytes)) { result, part in
            result.append(part ?? Data())
        }
        assemblies.removeValue(forKey: chunk.chunkId)
        insertionOrder.removeAll { $0 == chunk.chunkId }
        return complete.count == assembly.totalBytes ? complete : nil
    }

    private mutating func trimOldestIfNeeded() {
        guard assemblies.count >= maxAssemblies, let oldest = insertionOrder.first else { return }
        insertionOrder.removeFirst()
        assemblies.removeValue(forKey: oldest)
    }
}

import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var consecutiveDialFailures: Int = 0

    private let dialer: StreamDialer
    private let receiver: iOSFileTransferService
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval

    private var currentStream: (any IrohRelayStream)?
    private var supervisorTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var streamReadyContinuations: [CheckedContinuation<any IrohRelayStream, Error>] = []
    private var activeUID: String?
    private var activeConnectionID: String?

    /// Mercury Phase 8 — iOS receives ack frames from the Mac in
    /// response to `mediaMirrorRequest` sends. The Hermes Square root
    /// installs a handler that maps `.accepted` → push to
    /// `ScreenShareViewerView`; other decisions → surface a toast.
    var mirrorAckHandler: ((HermesRealtimeRelayMirrorAck) async -> Void)?

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
        maxBackoff: TimeInterval = 30.0
    ) {
        self.dialer = dialer
        self.receiver = receiver
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
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
        for continuation in streamReadyContinuations {
            continuation.resume(throwing: CancellationError())
        }
        streamReadyContinuations.removeAll()
        phase = .stopped
        activeUID = nil
        activeConnectionID = nil
    }

    /// Outbound send entry point. Blocks until the stream is live (or
    /// the supervisor gives up) so iOS-initiated sends don't race the
    /// initial dial.
    func send(frame: HermesRealtimeRelayFrame) async throws {
        let stream = try await awaitLiveStream()
        try await stream.send(frame)
    }

    private func awaitLiveStream() async throws -> any IrohRelayStream {
        if let currentStream, phase == .live {
            return currentStream
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any IrohRelayStream, Error>) in
            streamReadyContinuations.append(continuation)
        }
    }

    private func resolvePending(with stream: any IrohRelayStream) {
        let waiting = streamReadyContinuations
        streamReadyContinuations.removeAll()
        for continuation in waiting {
            continuation.resume(returning: stream)
        }
    }

    private func runSupervisor(uid: String, connectionID: String) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                phase = .dialing
                let stream = try await dialer(uid, connectionID)
                let classifyFrame = HermesRealtimeRelayFrame(
                    type: .mediaClassify,
                    uid: uid,
                    connectionId: connectionID,
                    media: HermesRealtimeRelayMediaPayload(
                        streamClass: MediaStreamClass.control.rawValue
                    )
                )
                try await stream.send(classifyFrame)
                currentStream = stream
                consecutiveDialFailures = 0
                attempt = 0
                phase = .live
                resolvePending(with: stream)

                // Mercury Phase 8 — spawn the heartbeat task once the
                // stream is live. Cancelled inside `stop()` or when the
                // supervisor loop iterates after a peer-close.
                startHeartbeatIfNeeded(uid: uid, connectionID: connectionID)

                // Drive the read loop. When it returns (peer close or
                // error) we'll fall through to the reconnect arm.
                await readLoop(stream: stream, uid: uid, connectionID: connectionID)

                heartbeatTask?.cancel()
                heartbeatTask = nil
                currentStream = nil
                if Task.isCancelled { break }
                // Peer closed cleanly — quick retry once before the
                // exponential backoff kicks in.
                attempt = max(0, attempt - 1)
            } catch is CancellationError {
                break
            } catch {
                consecutiveDialFailures += 1
                phase = .failed(reason: error.localizedDescription)
            }

            let backoff = nextBackoff(attempt: attempt)
            attempt += 1
            phase = .reconnecting(nextAttemptIn: backoff)
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
        phase = .stopped
    }

    private func readLoop(
        stream: any IrohRelayStream,
        uid: String,
        connectionID: String
    ) async {
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = {
            [stream] outbound in
            try await stream.send(outbound)
        }
        do {
            while let frame = try await stream.receive() {
                guard frame.uid == uid, frame.connectionId == connectionID else { continue }
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
                case .mediaMirrorRequest:
                    // iOS is the requester, not the receiver.
                    continue
                case .mediaPresenceHeartbeat:
                    // Outbound-only from iOS.
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
            phase = .reconnecting(nextAttemptIn: initialBackoff)
        }
    }

    private func startHeartbeatIfNeeded(uid: String, connectionID: String) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                guard !Task.isCancelled, let self else { return }
                await self.sendHeartbeat(uid: uid, connectionID: connectionID)
            }
        }
    }

    private func sendHeartbeat(uid: String, connectionID: String) async {
        let beat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: heartbeatDeviceNameProvider(),
            capabilities: [
                MercuryPeer.Feature.mirrorViewer.rawValue,
                MercuryPeer.Feature.fileSend.rawValue,
                MercuryPeer.Feature.fileReceive.rawValue,
                MercuryPeer.Feature.callReceive.rawValue
            ]
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(presence: beat)
        )
        try? await send(frame: frame)
    }

    private func nextBackoff(attempt: Int) -> TimeInterval {
        let exp = min(maxBackoff, initialBackoff * pow(2.0, Double(attempt)))
        // Decorrelated jitter: between initialBackoff and exp inclusive.
        let jitter = Double.random(in: initialBackoff ... exp)
        return min(maxBackoff, jitter)
    }
}

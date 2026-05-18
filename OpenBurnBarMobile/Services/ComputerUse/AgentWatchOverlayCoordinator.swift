#if canImport(UIKit)
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Owns the persistent Computer Use control stream on iOS.
///
/// It mirrors the Mercury media control coordinator: classify a long
/// lived iroh bi-stream, keep reading Mac-originated `control.*` frames,
/// and expose a send path for phone approval/input frames.
@MainActor
final class AgentWatchOverlayCoordinator: ObservableObject {
    typealias StreamDialer = @MainActor (
        _ uid: String,
        _ connectionID: String,
        _ relayPublicKey: Data
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
    @Published private(set) var state: AgentWatchState

    private(set) var receiver: AgentWatchReceiver?
    private(set) var phoneControlSender: PhoneControlSender?

    private let dialer: StreamDialer
    private let signingKeyStore: PhoneControlSigningKeyStore
    private let authorityPublisher: PhoneControlAuthorityPublishing
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private var stream: (any IrohRelayStream)?
    private var supervisorTask: Task<Void, Never>?
    private var activeUID: String?
    private var activeConnectionID: String?
    private var activeRelayPublicKey: Data?

    init(
        state: AgentWatchState = AgentWatchState(),
        dialer: @escaping StreamDialer = { uid, connectionID, relayPublicKey in
            try await HermesIrohRelayTransport.shared.openComputerUseControlStream(
                uid: uid,
                connectionID: connectionID,
                relayPublicKey: relayPublicKey
            )
        },
        signingKeyStore: PhoneControlSigningKeyStore = .shared,
        authorityPublisher: PhoneControlAuthorityPublishing = PhoneControlAuthorityPublisher.shared,
        initialBackoff: TimeInterval = 1,
        maxBackoff: TimeInterval = 30
    ) {
        self.state = state
        self.dialer = dialer
        self.signingKeyStore = signingKeyStore
        self.authorityPublisher = authorityPublisher
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
    }

    func start(
        uid: String,
        connectionID: String,
        relayPublicKey: Data,
        deviceId: String = MobileDeviceIdentity.loadOrCreateDeviceId()
    ) {
        guard supervisorTask == nil else { return }
        activeUID = uid
        activeConnectionID = connectionID
        activeRelayPublicKey = relayPublicKey
        phase = .dialing
        supervisorTask = Task { [weak self] in
            await self?.run(
                uid: uid,
                connectionID: connectionID,
                relayPublicKey: relayPublicKey,
                deviceId: deviceId
            )
        }
    }

    func stop() async {
        supervisorTask?.cancel()
        supervisorTask = nil
        if let stream { await stream.close() }
        stream = nil
        receiver = nil
        phoneControlSender = nil
        phase = .stopped
        state.clear()
    }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        guard let stream else { throw CancellationError() }
        try await stream.send(frame)
    }

    func makeFrameSink() -> PhoneControlSender.FrameSink {
        { [weak self] frame in
            guard let self else { throw CancellationError() }
            try await self.send(frame)
        }
    }

    private func run(
        uid: String,
        connectionID: String,
        relayPublicKey: Data,
        deviceId: String
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                phase = .dialing
                let stream = try await dialer(uid, connectionID, relayPublicKey)
                self.stream = stream
                let signingKey = try signingKeyStore.signingKey()
                let phonePeerNodeId = signingKeyStore.peerNodeId(for: signingKey)
                let sender = PhoneControlSender(
                    peerNodeId: phonePeerNodeId,
                    uid: uid,
                    connectionId: connectionID,
                    signingKeyProvider: { signingKey },
                    frameSink: makeFrameSink()
                )
                self.phoneControlSender = sender
                try await authorityPublisher.publish(
                    uid: uid,
                    connectionId: connectionID,
                    deviceId: deviceId,
                    peerNodeId: phonePeerNodeId,
                    publicKey: signingKey.privateKey.publicKey
                )
                let receiver = AgentWatchReceiver(
                    state: state,
                    uid: uid,
                    connectionId: connectionID,
                    approvalFrameSink: makeFrameSink(),
                    phoneControlSender: sender
                )
                self.receiver = receiver
                try await stream.send(HermesRealtimeRelayFrame(
                    type: .controlClassify,
                    uid: uid,
                    connectionId: connectionID,
                    control: HermesRealtimeRelayControlPayload(
                        streamClass: MediaStreamClass.controlInput.rawValue,
                        authorityPeerNodeId: phonePeerNodeId
                    )
                ))
                phase = .live
                attempt = 0
                await readLoop(stream: stream, receiver: receiver, uid: uid, connectionID: connectionID)
            } catch is CancellationError {
                break
            } catch {
                phase = .failed(reason: error.localizedDescription)
            }

            stream = nil
            receiver = nil
            phoneControlSender = nil
            if Task.isCancelled { break }
            let backoff = nextBackoff(attempt: attempt)
            attempt += 1
            phase = .reconnecting(nextAttemptIn: backoff)
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
        phase = .stopped
    }

    private func readLoop(
        stream: any IrohRelayStream,
        receiver: AgentWatchReceiver,
        uid: String,
        connectionID: String
    ) async {
        do {
            while let frame = try await stream.receive() {
                guard frame.uid == uid, frame.connectionId == connectionID else { continue }
                receiver.ingest(frame)
            }
        } catch {
            phase = .failed(reason: error.localizedDescription)
        }
    }

    private func nextBackoff(attempt: Int) -> TimeInterval {
        let ceiling = min(maxBackoff, initialBackoff * pow(2.0, Double(attempt)))
        return min(maxBackoff, Double.random(in: initialBackoff ... ceiling))
    }
}
#endif

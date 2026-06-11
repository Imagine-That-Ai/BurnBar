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
    private let signingKeyStore: any PhoneControlSigningKeyProviding
    private let authorityPublisher: PhoneControlAuthorityPublishing
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private var stream: (any IrohRelayStream)?
    private var supervisorTask: Task<Void, Never>?
    private var activeUID: String?
    private var activeConnectionID: String?
    private var activeRelayPublicKey: Data?
    #if DEBUG
    private var didRunE2EInputProof = false
    #endif

    init(
        state: AgentWatchState = AgentWatchState(),
        dialer: @escaping StreamDialer = { uid, connectionID, relayPublicKey in
            try await HermesIrohRelayTransport.shared.openComputerUseControlStream(
                uid: uid,
                connectionID: connectionID,
                relayPublicKey: relayPublicKey
            )
        },
        signingKeyStore: any PhoneControlSigningKeyProviding = PhoneControlSigningKeyStore.shared,
        authorityPublisher: PhoneControlAuthorityPublishing = PhoneControlAuthorityPublisher.shared,
        initialBackoff: TimeInterval = 1,
        maxBackoff: TimeInterval = 8
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
                computerUseE2EProofLog("dial_start connection=\(connectionID)")
                let stream = try await dialer(uid, connectionID, relayPublicKey)
                computerUseE2EProofLog("dial_opened connection=\(connectionID)")
                self.stream = stream
                let signingIdentity = try signingKeyStore.signingIdentity()
                let phonePeerNodeId = signingKeyStore.peerNodeId(for: signingIdentity)
                // F10: establish the control-frame seal for this watch stream
                // when the flag is on and the Mac advertised control_seal_v1
                // (capabilities come from the warm media-control stream's view
                // of the same Mac). Both the input sender and the approval
                // sink seal under the same session; failure falls back to the
                // legacy plaintext lane.
                let sealSession = await ControlSealSessionEstablisher.establishIfNegotiated(
                    uid: uid,
                    connectionID: connectionID,
                    controllerPeerNodeId: phonePeerNodeId,
                    macCapabilities: HermesIrohRelayTransport.shared.latestMacPresenceCapabilities(connectionID: connectionID),
                    macRelayPublicKeyBase64: HermesService.shared.selectedConnection.relayPublicKey
                )
                let makeSealedSink: () -> PhoneControlSender.FrameSink = {
                    let base = self.makeFrameSink()
                    guard let sealSession else { return base }
                    return ControlSealSessionEstablisher.sealingFrameSink(base, session: sealSession)
                }
                let sender = PhoneControlSender(
                    peerNodeId: phonePeerNodeId,
                    uid: uid,
                    connectionId: connectionID,
                    signingIdentityProvider: { signingIdentity },
                    frameSink: makeSealedSink()
                )
                self.phoneControlSender = sender
                try await authorityPublisher.publish(
                    uid: uid,
                    connectionId: connectionID,
                    deviceId: deviceId,
                    peerNodeId: phonePeerNodeId,
                    publicKeyRepresentation: signingIdentity.publicKeyRepresentation,
                    keyKind: signingIdentity.kind
                )
                computerUseE2EProofLog("authority_published peer=\(phonePeerNodeId)")
                let receiver = AgentWatchReceiver(
                    state: state,
                    uid: uid,
                    connectionId: connectionID,
                    approvalFrameSink: makeSealedSink(),
                    phoneControlSender: sender
                )
                self.receiver = receiver
                try await stream.send(HermesRealtimeRelayFrame(
                    type: .controlClassify,
                    uid: uid,
                    connectionId: connectionID,
                    control: HermesRealtimeRelayControlPayload(
                        streamClass: MediaStreamClass.controlInput.rawValue,
                        authorityPeerNodeId: phonePeerNodeId,
                        controlSealKey: sealSession?.envelope
                    )
                ))
                phase = .live
                computerUseE2EProofLog("classified_live connection=\(connectionID)")
                attempt = 0
                runE2EInputProofIfNeeded(receiver: receiver)
                await readLoop(stream: stream, receiver: receiver, uid: uid, connectionID: connectionID)
            } catch is CancellationError {
                computerUseE2EProofLog("dial_cancelled connection=\(connectionID)")
                break
            } catch {
                computerUseE2EProofLog("dial_failed connection=\(connectionID) error=\(error.localizedDescription)")
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

    #if DEBUG
    private func runE2EInputProofIfNeeded(receiver: AgentWatchReceiver) {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF"] == "1" else { return }
        guard !didRunE2EInputProof else { return }
        didRunE2EInputProof = true
        Task { @MainActor [weak self, receiver] in
            let started = Date()
            self?.computerUseE2EProofLog("control_stream_live")
            do {
                self?.computerUseE2EProofLog("send_tap_start")
                try await Task.sleep(nanoseconds: 800_000_000)
                try await receiver.tap(normalizedX: 0.18, normalizedY: 0.18)
                self?.computerUseE2EProofLog("sent_tap elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")

                self?.computerUseE2EProofLog("send_scroll_start")
                try await Task.sleep(nanoseconds: 350_000_000)
                try await receiver.scrollDrag(
                    startNormalizedX: 0.50,
                    startNormalizedY: 0.62,
                    endNormalizedX: 0.50,
                    endNormalizedY: 0.38
                )
                self?.computerUseE2EProofLog("sent_scroll elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")

                self?.computerUseE2EProofLog("send_panic_start")
                try await Task.sleep(nanoseconds: 350_000_000)
                try await receiver.panicHalt()
                self?.computerUseE2EProofLog("sent_panic elapsedMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            } catch {
                self?.computerUseE2EProofLog("input_proof_failed error=\(error.localizedDescription)")
            }
        }
    }

    private func computerUseE2EProofLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["OPENBURNBAR_E2E_COMPUTER_USE_PROOF"] == "1" else { return }
        let line = "OpenBurnBarMobile ComputerUseE2E \(message)"
        print(line)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("computer-use-e2e-proof.jsonl")
        let payload: [String: String] = [
            "event": message,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            var text = String(data: data, encoding: .utf8)
        else { return }
        text.append("\n")
        guard let encoded = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: encoded)
            _ = try? handle.close()
        } else {
            try? encoded.write(to: url, options: [.atomic])
        }
    }
    #else
    private func runE2EInputProofIfNeeded(receiver: AgentWatchReceiver) {}

    private func computerUseE2EProofLog(_ message: String) {}
    #endif
}
#endif

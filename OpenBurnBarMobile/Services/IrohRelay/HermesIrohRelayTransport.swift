import Foundation
@preconcurrency import FirebaseAuth
import FirebaseRemoteConfig
import Network
import OpenBurnBarCore
import OpenBurnBarIrohRelay

/// iOS-side iroh transport. Conforms to `HermesRelayTransporting` so it
/// slots into `HermesCompositeRelayTransport` next to the existing
/// `HermesRealtimeRelayTransport` (WSS) and `FirestoreHermesRelayTransport`
/// (fallback). Picks up the Mac's NodeAddr material from the signed
/// `iroh_pairing` Firestore record, verifies the Ed25519 signature, then
/// dials the iroh QUIC stream and serves one frame round-trip per request.
/// Closure injected by the iOS app coordinator so the chat-receive loop
/// can hand a Mercury media frame to `iOSFileTransferService` (or, in
/// later phases, the call/screen-share coordinator). Sendable so it
/// survives MainActor + iroh runtime hops. `ackSender` lets the
/// dispatcher write the corresponding `media.blob.ack` frame back on the
/// same chat stream.
typealias IrohMediaFrameDispatcher = @Sendable (
    _ frame: HermesRealtimeRelayFrame,
    _ ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void
) async -> Void

private enum IrohNetworkAuditSnapshot {
    static func capture(timeout: DispatchTimeInterval = .milliseconds(250)) async -> [String: String] {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.openburnbar.iroh-network-audit")
            var didResume = false

            func finish(with path: NWPath) {
                guard !didResume else { return }
                didResume = true
                let detail = auditDetail(for: path)
                monitor.cancel()
                continuation.resume(returning: detail)
            }

            monitor.pathUpdateHandler = { path in
                finish(with: path)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(with: monitor.currentPath)
            }
        }
    }

    private static func auditDetail(for path: NWPath) -> [String: String] {
        let interfaces = [
            path.usesInterfaceType(.wifi) ? "wifi" : nil,
            path.usesInterfaceType(.cellular) ? "cellular" : nil,
            path.usesInterfaceType(.wiredEthernet) ? "wiredEthernet" : nil,
            path.usesInterfaceType(.loopback) ? "loopback" : nil,
            path.usesInterfaceType(.other) ? "other" : nil
        ].compactMap { $0 }

        return [
            "networkPathStatus": statusLabel(path.status),
            "networkInterfaces": interfaces.isEmpty ? "none" : interfaces.joined(separator: ","),
            "networkIsExpensive": path.isExpensive ? "true" : "false",
            "networkIsConstrained": path.isConstrained ? "true" : "false"
        ]
    }

    private static func statusLabel(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied:
            return "satisfied"
        case .unsatisfied:
            return "unsatisfied"
        case .requiresConnection:
            return "requiresConnection"
        @unknown default:
            return "unknown"
        }
    }
}

@MainActor
final class HermesIrohRelayTransport: HermesRelayTransporting {
    static let shared = HermesIrohRelayTransport()
    /// Set once at app launch by the coordinator that owns
    /// `iOSFileTransferService`. Optional so the chat path keeps working
    /// even if Mercury media is disabled or unavailable on the device.
    var mediaDispatcher: IrohMediaFrameDispatcher?

    /// Hard cap on iroh dial latency. Keeping this independent from the
    /// request `timeout` (which is per-completion and can be 60-120s) means
    /// a slow NAT-traversal failure surfaces fast and the cascade can fall
    /// back to WSS within 5s instead of after the full chat completion
    /// budget.
    static let defaultConnectTimeout: TimeInterval = 5
    /// Endpoint startup can legitimately include one Rust-side home-relay
    /// retry (`10s + retry delay + second bootstrap`). Keep this wider than
    /// the dial timeout so a transient hosted-relay bootstrap miss does not
    /// abort before the retry path can recover.
    static let defaultBootstrapStartupTimeout: TimeInterval = 30

    private let directory: any IrohPairingDirectory
    private let transportFactory: @MainActor () -> any IrohRelayTransport
    private let pairingPublicKeyProvider: any IrohPairingPublicKeyProviding
    private let auditLogger: any IrohTransportAuditLogging
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var endpoint: (any IrohRelayTransport)?
    private var identity: IrohEndpointIdentity?
    /// Mercury Phase 1b — single-shot installer for the persistent media
    /// control stream. AppDelegate calls
    /// `installMediaControlStream(into:)` at boot; the actual coordinator
    /// is constructed and started after the first successful relay
    /// `send(...)` so we have a verified `(uid, connectionID, relayPublicKey)`
    /// triple to dial with. Once installed, the transport keeps the
    /// coordinator alive for the rest of the app's lifetime.
    private weak var mediaControlReceiver: iOSFileTransferService?
    private var mediaControlCoordinator: MediaControlStreamCoordinator?
    /// Outstanding bootstrap promise so concurrent callers reuse the same
    /// `transport.start()` invocation rather than racing to spin up two
    /// endpoints and leaking one of them.
    private var bootstrapTask: Task<any IrohRelayTransport, Error>?
    private let connectTimeout: TimeInterval
    private let now: @Sendable () -> Date

    init(
        directory: any IrohPairingDirectory = FirestoreIrohPairingDirectory.shared,
        pairingPublicKeyProvider: any IrohPairingPublicKeyProviding = FirestoreIrohPairingPublicKeyProvider.shared,
        auditLogger: any IrohTransportAuditLogging = FirestoreIrohAuditLogger.shared,
        transportFactory: @escaping @MainActor () -> any IrohRelayTransport = {
            HermesIrohRelayTransport.defaultTransport()
        },
        connectTimeout: TimeInterval = HermesIrohRelayTransport.defaultConnectTimeout,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.pairingPublicKeyProvider = pairingPublicKeyProvider
        self.auditLogger = auditLogger
        self.transportFactory = transportFactory
        self.connectTimeout = connectTimeout
        self.now = now
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        var fragments: [Int: String] = [:]
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .data:
                fragments[chunk.sequence] = chunk.data ?? chunk.text ?? ""
            case .error:
                throw HermesServiceError.relayFailure(chunk.error, fallback: "Hermes iroh relay failed.")
            case .sse:
                break
            }
        }
        let body = fragments
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        return Data(body.utf8)
    }

    /// Mercury Phase 1b — single-method install. AppDelegate calls
    /// this at boot, immediately after constructing
    /// `iOSFileTransferService`. The transport defers building the
    /// `MediaControlStreamCoordinator` until the first successful
    /// `send(...)` so it has a verified Mac NodeId + relay public key
    /// to dial with — no premature dial against an unauthenticated
    /// peer.
    func installMediaControlStream(into receiver: iOSFileTransferService) {
        self.mediaControlReceiver = receiver
    }

    /// Boot-time entry point used by the coordinator dialer + tests.
    /// Open a fresh bi-stream against the paired Mac, classify it as the
    /// long-lived media control stream, and return the open stream so
    /// the coordinator can drive both the inbound read loop and
    /// outbound sends. Mirrors the auth + verify path of `send(...)`
    /// but skips the chat encrypt/seal envelope.
    func openMediaControlStream(
        uid: String,
        connectionID: String,
        relayPublicKey: Data
    ) async throws -> any IrohRelayStream {
        let publisher = IrohPairingPublisher(directory: directory)
        let verifiedTarget = try await publisher.fetchAndVerify(
            uid: uid,
            connectionId: connectionID,
            publicKey: relayPublicKey,
            now: now()
        )
        let transport = try await transport()
        return try await transport.connect(
            to: verifiedTarget,
            timeout: connectTimeout
        )
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .sse:
                if let data = chunk.data ?? chunk.text, !data.isEmpty {
                    onSSEEvent(data)
                }
            case .error:
                throw HermesServiceError.relayFailure(chunk.error, fallback: "Hermes iroh relay stream failed.")
            case .data:
                break
            }
        }
    }

    private func send(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onChunk: @MainActor (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw HermesServiceError.relayUnavailable("Iroh relay requires a signed-in Firebase user.")
        }
        guard payload.relayEncryption == HermesRelayCrypto.algorithm,
              let relayPublicKey = payload.relayPublicKey,
              !relayPublicKey.isEmpty else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic.")
        }

        let publicKey = try await pairingPublicKeyProvider.fetchPublicKey(uid: uid)
        let networkAuditDetail = await IrohNetworkAuditSnapshot.capture()

        // 1. Fetch + verify the Mac's signed iroh pairing record.
        let publisher = IrohPairingPublisher(directory: directory)
        let verifiedTarget: IrohDialTarget
        do {
            verifiedTarget = try await publisher.fetchAndVerify(
                uid: uid,
                connectionId: payload.connectionID,
                publicKey: publicKey,
                now: now()
            )
            await auditLogger.record(
                event: .pairingVerified,
                uid: uid,
                connectionId: payload.connectionID,
                transport: nil,
                rttMillis: nil,
                detail: networkAuditDetail
            )
        } catch {
            await auditLogger.record(
                event: .pairingRejected,
                uid: uid,
                connectionId: payload.connectionID,
                transport: nil,
                rttMillis: nil,
                detail: ["error": String(error.localizedDescription.prefix(256))]
            )
            throw HermesServiceError.relayUnavailable("Could not verify iroh pairing record: \(error.localizedDescription)")
        }

        // 2. Bring up the iroh endpoint (idempotent, race-safe) and dial.
        // Every await below is explicitly bounded. The Rust transport has
        // its own timeouts, but the physical-device proof also needs the
        // Swift task to return even if an FFI call or config bootstrap parks.
        var stage = "transport_start"
        do {
            await auditLogger.record(
                event: .pairingVerified,
                uid: uid,
                connectionId: payload.connectionID,
                transport: nil,
                rttMillis: nil,
                detail: auditDetail(["stage": stage], networkAuditDetail)
            )
            let transport = try await withIrohOperationTimeout(
                seconds: Self.bootstrapStartupTimeout(connectTimeout: connectTimeout)
            ) {
                try await self.transport()
            }
            stage = "dial_start"
            let localNodeId = identity?.nodeId ?? ""
            await auditLogger.record(
                event: .pairingVerified,
                uid: uid,
                connectionId: payload.connectionID,
                transport: nil,
                rttMillis: nil,
                detail: auditDetail([
                    "stage": stage,
                    "localNodeId": localNodeId,
                    "targetNodeId": verifiedTarget.nodeId,
                    "relayURL": verifiedTarget.relayURL ?? "",
                    "directAddressCount": "\(verifiedTarget.directAddresses.count)"
                ], networkAuditDetail)
            )
            let dialTarget = IrohDialTarget(
                nodeId: verifiedTarget.nodeId,
                relayURL: verifiedTarget.relayURL,
                directAddresses: []
            )
            // The dial uses a tight timeout independent from the request
            // budget: a quick failure here lets `HermesCompositeRelayTransport`
            // cascade to WSS without spending the full chat-completion window
            // waiting for NAT traversal.
            let stream = try await withIrohOperationTimeout(seconds: min(connectTimeout, timeout)) {
                try await transport.connect(
                    to: dialTarget,
                    timeout: min(self.connectTimeout, timeout)
                )
            }
            await auditLogger.record(
                event: .streamOpened,
                uid: uid,
                connectionId: payload.connectionID,
                transport: .irohDirect,
                rttMillis: nil,
                detail: auditDetail(["side": "ios"], networkAuditDetail)
            )
            try await send(
                payload,
                uid: uid,
                publicKey: publicKey,
                relayPublicKey: relayPublicKey,
                verifiedTarget: verifiedTarget,
                stream: stream,
                timeout: timeout,
                networkAuditDetail: networkAuditDetail,
                onChunk: onChunk
            )
        } catch {
            await auditLogger.record(
                event: .streamFailed,
                uid: uid,
                connectionId: payload.connectionID,
                transport: .irohDirect,
                rttMillis: nil,
                detail: [
                    "stage": stage,
                    "error": String(error.localizedDescription.prefix(256))
                ]
            )
            throw error
        }
    }

    private func send(
        _ payload: HermesRelayPayload,
        uid: String,
        publicKey: Data,
        relayPublicKey: String,
        verifiedTarget: IrohDialTarget,
        stream: any IrohRelayStream,
        timeout: TimeInterval,
        networkAuditDetail: [String: String],
        onChunk: @MainActor (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        defer { Task { await stream.close() } }

        // 2a. Mercury Phase 1b — once we know the pairing-public-key
        // triple is good (i.e., the dial above succeeded), kick off
        // the persistent media control stream exactly once. Subsequent
        // sends short-circuit because the coordinator keeps itself
        // alive + reconnects on its own.
        if mediaControlCoordinator == nil, let receiver = mediaControlReceiver {
            startMediaControlCoordinator(
                uid: uid,
                connectionID: payload.connectionID,
                pairingPublicKey: publicKey,
                receiver: receiver
            )
        }

        let requestID = "iroh_\(UUID().uuidString.lowercased())"
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let bodyString = payload.body.flatMap { String(data: $0, encoding: .utf8) }
        let encryptedPayload = HermesRelayEncryptedRequestPayload(
            path: payload.path,
            sessionId: payload.sessionID,
            body: bodyString
        )
        let plaintext = try JSONEncoder().encode(encryptedPayload)
        let requestAAD = HermesRelayCrypto.requestAAD(
            uid: uid,
            connectionID: payload.connectionID,
            requestID: requestID
        )
        let keyAAD = HermesRelayCrypto.keyAAD(
            uid: uid,
            connectionID: payload.connectionID,
            requestID: requestID
        )

        let startFrame = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: uid,
            connectionId: payload.connectionID,
            requestId: requestID,
            payload: HermesRealtimeRelayPayload(
                operation: payload.operation,
                method: payload.method,
                payloadCiphertext: try HermesRelayCrypto.sealToBase64(
                    plaintext: plaintext,
                    keyData: keyData,
                    aad: requestAAD
                ),
                wrappedKey: try HermesRelayCrypto.wrapSymmetricKey(
                    keyData,
                    recipientPublicKeyBase64: relayPublicKey,
                    aad: keyAAD
                ),
                relayEncryption: HermesRelayCrypto.algorithm,
                relayKeyVersion: payload.relayKeyVersion ?? HermesRelayCrypto.keyVersion
            )
        )
        try await stream.send(startFrame)

        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var receivedChunkCount = 0
        var didRecordFirstChunk = false
        while Date() < deadline {
            guard let frame = try await stream.receive() else {
                throw HermesServiceError.relayUnavailable("Iroh stream closed before completion.")
            }
            guard frame.uid == uid,
                  frame.connectionId == payload.connectionID,
                  frame.requestId == requestID else {
                continue
            }
            switch frame.type {
            case .responseChunk:
                guard let chunk = try chunkRecord(from: frame, keyData: keyData, uid: uid, connectionID: payload.connectionID, requestID: requestID) else { continue }
                receivedChunkCount += 1
                if !didRecordFirstChunk {
                    didRecordFirstChunk = true
                    let rtt = Int(Date().timeIntervalSince(started) * 1000)
                    await auditLogger.record(
                        event: .streamOpened,
                        uid: uid,
                        connectionId: payload.connectionID,
                        transport: .irohDirect,
                        rttMillis: rtt,
                        detail: auditDetail([
                            "stage": "ios_first_response_chunk",
                            "requestId": requestID,
                            "sequence": "\(chunk.sequence)",
                            "kind": chunk.kind.rawValue
                        ], networkAuditDetail)
                    )
                }
                try onChunk(chunk)
            case .responseComplete:
                let rtt = Int(Date().timeIntervalSince(started) * 1000)
                await auditLogger.record(
                    event: .streamClosed,
                    uid: uid,
                    connectionId: payload.connectionID,
                    transport: .irohDirect,
                    rttMillis: rtt,
                    detail: auditDetail([
                        "stage": "ios_response_complete",
                        "requestId": requestID,
                        "chunks": "\(receivedChunkCount)"
                    ], networkAuditDetail)
                )
                return
            case .responseError:
                throw HermesServiceError.relayFailure(frame.payload?.error, fallback: "Hermes iroh relay failed.")
            case .ping, .pong, .requestCancel, .requestStart, .hostReady, .hostRegister:
                continue
            case .mediaClassify, .mediaBlobAdvertise, .mediaBlobAck:
                guard let dispatcher = mediaDispatcher else { continue }
                let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = {
                    [stream] outboundFrame in
                    try await stream.send(outboundFrame)
                }
                await dispatcher(frame, ackSender)
                continue
            }
        }
        throw HermesServiceError.relayTimeout
    }

    private func auditDetail(
        _ detail: [String: String],
        _ networkDetail: [String: String]
    ) -> [String: String] {
        detail.merging(networkDetail) { current, _ in current }
    }

    @MainActor
    private func startMediaControlCoordinator(
        uid: String,
        connectionID: String,
        pairingPublicKey: Data,
        receiver: iOSFileTransferService
    ) {
        let dialer: MediaControlStreamCoordinator.StreamDialer = { [weak self] uid, connectionID in
            guard let self else { throw IrohRelayTransportError.shutdown }
            return try await self.openMediaControlStream(
                uid: uid,
                connectionID: connectionID,
                relayPublicKey: pairingPublicKey
            )
        }
        let coordinator = MediaControlStreamCoordinator(
            dialer: dialer,
            receiver: receiver
        )
        coordinator.start(uid: uid, connectionID: connectionID)
        receiver.attachControlStream(coordinator)
        self.mediaControlCoordinator = coordinator
    }

    private func transport() async throws -> any IrohRelayTransport {
        if let endpoint, identity != nil { return endpoint }
        if let bootstrapTask {
            // A concurrent caller is already starting the endpoint —
            // hand them the same outcome so we never spin up twice.
            return try await bootstrapTask.value
        }
        let factory = transportFactory
        let task = Task { @MainActor [factory] () throws -> any IrohRelayTransport in
            await HermesIrohHostedRelayConfig.refreshRemoteConfigIfAvailable()
            let transport = factory()
            #if DEBUG
            if ProcessInfo.processInfo.environment["OPENBURNBAR_ALLOW_IROH_LOOPBACK"] != "1",
               transport is LoopbackIrohRelayTransport {
                assertionFailure(
                    "Hermes iroh mobile resolved LoopbackIrohRelayTransport. Build/link Vendor/OpenBurnBarIroh.xcframework so QA/dev devices use IrohXcframeworkTransport."
                )
            }
            #endif
            let identity = try await transport.start()
            self.endpoint = transport
            self.identity = identity
            return transport
        }
        bootstrapTask = task
        defer { bootstrapTask = nil }
        return try await task.value
    }

    static func bootstrapStartupTimeout(connectTimeout: TimeInterval) -> TimeInterval {
        max(defaultBootstrapStartupTimeout, connectTimeout + 25)
    }

    private func chunkRecord(
        from frame: HermesRealtimeRelayFrame,
        keyData: Data,
        uid: String,
        connectionID: String,
        requestID: String
    ) throws -> HermesRelayChunkRecord? {
        guard let payload = frame.payload,
              let kind = payload.kind,
              let sequence = payload.sequence,
              let ciphertext = payload.ciphertext else {
            return nil
        }
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                sequence: sequence,
                kind: kind.rawValue
            )
        )
        let text = String(data: plaintext, encoding: .utf8)
        return HermesRelayChunkRecord(
            id: String(format: "%08d", sequence),
            requestId: requestID,
            sequence: sequence,
            kind: kind,
            data: text,
            text: text,
            error: nil,
            schemaVersion: 2
        )
    }

    static func defaultTransport() -> any IrohRelayTransport {
        let secretProvider: @Sendable () throws -> IrohSecretKeyMaterial = {
            try IrohRelayKeyStore.shared.secretKeyMaterial()
        }
        if let backend = OpenBurnBarIrohFFIBackendFactory.make() {
            return IrohXcframeworkTransport(
                backend: backend,
                secretProvider: secretProvider,
                relayURLProvider: {
                    HermesIrohHostedRelayConfig.currentURL()
                }
            )
        }
        let rendezvous = LoopbackIrohRelayRendezvous()
        return LoopbackIrohRelayTransport(rendezvous: rendezvous)
    }
}

private enum HermesIrohHostedRelayConfig {
    private static let remoteConfigKey = "hermes_iroh_hosted_relay_url"
    private static let userDefaultsKey = "hermes_iroh_hosted_relay_url"
    private static let environmentKey = "OPENBURNBAR_IROH_HOSTED_RELAY_URL"

    static func refreshRemoteConfigIfAvailable() async {
        guard !hasLocalOverride else { return }
        let remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.setDefaults([remoteConfigKey: "" as NSObject])
        await withCheckedContinuation { continuation in
            let gate = ContinuationGate(continuation)
            remoteConfig.fetchAndActivate { _, _ in
                gate.resume()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                gate.resume()
            }
        }
    }

    static func currentURL() -> String? {
        normalized(ProcessInfo.processInfo.environment[environmentKey])
            ?? normalized(UserDefaults.standard.string(forKey: userDefaultsKey))
            ?? normalized(RemoteConfig.remoteConfig().configValue(forKey: remoteConfigKey).stringValue)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static var hasLocalOverride: Bool {
        normalized(ProcessInfo.processInfo.environment[environmentKey]) != nil
            || normalized(UserDefaults.standard.string(forKey: userDefaultsKey)) != nil
    }

    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private let continuation: CheckedContinuation<Void, Never>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            continuation.resume()
        }
    }
}

private func withIrohOperationTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = IrohTimeoutGate(continuation)
        let operationTask = Task {
            do {
                gate.resume(returning: try await operation())
            } catch {
                gate.resume(throwing: error)
            }
        }
        let timeoutTask = Task {
            let nanos = UInt64(max(0.001, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
            gate.resume(throwing: IrohRelayTransportError.timedOut)
        }
        gate.onResume = {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }
}

private final class IrohTimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<T, Error>
    var onResume: (@Sendable () -> Void)?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        finish {
            continuation.resume(returning: value)
        }
    }

    func resume(throwing error: Error) {
        finish {
            continuation.resume(throwing: error)
        }
    }

    private func finish(_ resumeContinuation: () -> Void) {
        let callback: (@Sendable () -> Void)?
        lock.lock()
        if didResume {
            lock.unlock()
            return
        }
        didResume = true
        callback = onResume
        lock.unlock()
        resumeContinuation()
        callback?()
    }
}

protocol IrohPairingPublicKeyProviding: Sendable {
    func fetchPublicKey(uid: String) async throws -> Data
}

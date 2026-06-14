import FirebaseCore
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore
import Foundation
import FirebaseRemoteConfig
import Network
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import os

private func irohPublicErrorClass(_ error: Error) -> String {
    let nsError = error as NSError
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").inverted
    let domain = nsError.domain.components(separatedBy: allowed).joined(separator: "_")
    return "\(domain)#\(nsError.code)"
}

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
    private final class ContinuationGate: Sendable {
        private let didResume = OSAllocatedUnfairLock<Bool>(uncheckedState: false)

        func finish(
            with path: NWPath,
            monitor: NWPathMonitor,
            continuation: CheckedContinuation<[String: String], Never>
        ) {
            let shouldResume = didResume.withLockUnchecked { resumed -> Bool in
                guard !resumed else { return false }
                resumed = true
                return true
            }
            guard shouldResume else { return }
            let detail = auditDetail(for: path)
            monitor.cancel()
            continuation.resume(returning: detail)
        }
    }

    static func capture(timeout: DispatchTimeInterval = .milliseconds(250)) async -> [String: String] {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.openburnbar.iroh-network-audit")
            let gate = ContinuationGate()

            @Sendable func finish(with path: NWPath) {
                gate.finish(with: path, monitor: monitor, continuation: continuation)
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

    /// Mercury Phase 8 — callback for Mac → iOS presence heartbeats carried
    /// on the persistent media-control stream. Hermes Square installs this
    /// so its paired-Mac peer source can show the Mac's current display name
    /// and capabilities as soon as they arrive.
    var mediaPresenceHeartbeatHandler: ((HermesRealtimeRelayPresenceHeartbeat) async -> Void)? {
        didSet {
            mediaControlCoordinators.values.forEach { coordinator in
                coordinator.presenceHeartbeatHandler = mediaPresenceHeartbeatHandler
            }
        }
    }

    /// Hard cap on iroh dial latency. Keeping this independent from the
    /// request `timeout` (which is per-completion and can be 60-120s) means
    /// a slow NAT-traversal failure surfaces fast and the cascade can fall
    /// back to WSS within 5s instead of after the full chat completion
    /// budget.
    static let defaultConnectTimeout: TimeInterval = 5
    /// Mercury media-control streams are long-lived and user-visible.
    /// Android gives this path a wider dial budget than one-shot chat
    /// requests so home-relay negotiation can settle before the sheet
    /// falls back into reconnect churn.
    static let defaultMediaControlConnectTimeout: TimeInterval = 15
    /// Endpoint startup can legitimately include one Rust-side home-relay
    /// retry (`10s + retry delay + second bootstrap`). Keep this wider than
    /// the dial timeout so a transient hosted-relay bootstrap miss does not
    /// abort before the retry path can recover.
    static let defaultBootstrapStartupTimeout: TimeInterval = 30
    private nonisolated static let minimumControlPlaneRequestTimeout: TimeInterval = 90
    private nonisolated static let responseCompleteGraceTimeout: TimeInterval = 15

    private enum RequestStreamFrameRoute {
        case responseChunk
        case responseComplete
        case responseError
        case ignore
        case mediaDispatcher
    }

    private let directory: any IrohPairingDirectory
    private let transportFactory: @MainActor (_ relayURL: String?) -> any IrohRelayTransport
    private let pairingPublicKeyProvider: any IrohPairingPublicKeyProviding
    private let auditLogger: any IrohTransportAuditLogging
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var endpoint: (any IrohRelayTransport)?
    private var identity: IrohEndpointIdentity?
    private var endpointRelayURL: String?
    /// Mercury Phase 1b — single-shot installer for the persistent media
    /// control stream. AppDelegate calls
    /// `installMediaControlStream(into:)` at boot; the actual coordinator
    /// is constructed and started after the first successful relay
    /// `send(...)` so we have a verified `(uid, connectionID, relayPublicKey)`
    /// triple to dial with. Once installed, the transport keeps the
    /// coordinator alive for the rest of the app's lifetime.
    private var mediaControlReceiver: iOSFileTransferService?
    private var mediaControlCoordinators: [String: MediaControlStreamCoordinator] = [:]

    /// F7/F10 — the Mac capability strings most recently advertised on the
    /// media-control stream for `connectionID` (empty until a heartbeat reply
    /// has arrived). Lets surfaces with their own control streams (agent
    /// watch) negotiate the app-layer seals from the warm media stream's view
    /// of the same Mac.
    func latestMacPresenceCapabilities(connectionID: String) -> [String] {
        mediaControlCoordinators[connectionID]?.latestMacPresenceCapabilities ?? []
    }
    private var lastMediaControlConnectionID: String?
    /// Outstanding bootstrap promise so concurrent callers reuse the same
    /// `transport.start()` invocation rather than racing to spin up two
    /// endpoints and leaking one of them.
    private var bootstrapTask: Task<any IrohRelayTransport, Error>?
    private var bootstrapRelayURL: String?
    private var bootstrapGeneration = 0
    private let connectTimeout: TimeInterval
    private let now: @Sendable () -> Date

    init(
        directory: any IrohPairingDirectory = FirestoreIrohPairingDirectory.shared,
        pairingPublicKeyProvider: any IrohPairingPublicKeyProviding = FirestoreIrohPairingPublicKeyProvider.shared,
        auditLogger: any IrohTransportAuditLogging = FirestoreIrohAuditLogger.shared,
        transportFactory: @escaping @MainActor (_ relayURL: String?) -> any IrohRelayTransport = { relayURL in
            HermesIrohRelayTransport.defaultTransport(relayURL: relayURL)
        },
        connectTimeout: TimeInterval = HermesIrohRelayTransport.defaultConnectTimeout,
        now: @escaping @Sendable () -> Date = { Date() }
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

    #if DEBUG
    var isMediaControlReceiverInstalledForTesting: Bool {
        mediaControlReceiver != nil
    }
    #endif

    /// Start the persistent Mercury media-control stream from an already
    /// selected relay connection. This is used by Hermes Square before any
    /// chat request has happened, so tapping "My Mac" is enough to bring
    /// Mercury online.
    func ensureMediaControlStream(connectionID: String) async throws {
        if let existing = mediaControlCoordinators[connectionID] {
            switch existing.phase {
            case .live, .dialing:
                lastMediaControlConnectionID = connectionID
                return
            case .idle, .stopped, .failed, .reconnecting:
                await existing.stop()
                mediaControlCoordinators[connectionID] = nil
            }
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw HermesServiceError.relayUnavailable("Mercury requires a signed-in Firebase user.")
        }
        guard mediaControlReceiver != nil else {
            throw HermesServiceError.relayUnavailable("Mercury receiver is not installed.")
        }
        let publicKey = try await pairingPublicKeyProvider.fetchPublicKey(uid: uid)
        startMediaControlCoordinatorIfNeeded(
            uid: uid,
            connectionID: connectionID,
            pairingPublicKey: publicKey
        )
    }

    /// Mercury Phase 8 — read-only accessor for the active control-stream
    /// coordinator. Returns `nil` until the lazy boot path in `send(...)`
    /// has constructed and started one. Used by `MercuryPeerSource` to
    /// observe the live/idle phase and by `MercuryLiveSheet` to push
    /// outbound mirror requests onto the same stream.
    var currentMediaControlCoordinator: MediaControlStreamCoordinator? {
        if let lastMediaControlConnectionID,
           let coordinator = mediaControlCoordinators[lastMediaControlConnectionID] {
            return coordinator
        }
        return mediaControlCoordinators.values.first
    }

    var currentMediaControlConnectionID: String? {
        currentMediaControlCoordinator?.connectionID
    }

    func mediaControlCoordinator(for connectionID: String) -> MediaControlStreamCoordinator? {
        mediaControlCoordinators[connectionID]
    }

    /// Mercury Phase 8 — snapshot of the active control-stream phase, or
    /// `.idle` when no coordinator has been built yet. Cheap to poll;
    /// reflects the coordinator's `@Published phase` 1:1.
    var currentMediaControlPhase: MediaControlStreamCoordinator.Phase {
        currentMediaControlCoordinator?.phase ?? .idle
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
        let transport = try await transport(relayURL: verifiedTarget.relayURL)
        return try await transport.connect(
            to: verifiedTarget,
            timeout: Self.defaultMediaControlConnectTimeout
        )
    }

    func openComputerUseControlStream(
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
        let transport = try await transport(relayURL: verifiedTarget.relayURL)
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
        guard payload.relayEncryption == HermesRelayCrypto.relayEncryptionV3,
              payload.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3,
              let relayPublicKey = payload.relayPublicKey,
              !relayPublicKey.isEmpty else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use authenticated relay traffic.")
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
                detail: ["errorClass": irohPublicErrorClass(error)]
            )
            throw HermesServiceError.relayUnavailable("Could not verify iroh pairing record.")
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
                try await self.transport(relayURL: verifiedTarget.relayURL)
            }
            stage = "dial_start"
            let localNodeId = identity?.nodeId ?? ""
            if !localNodeId.isEmpty {
                await persistIrohPeerNodeId(localNodeId, uid: uid)
            }
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
            stage = "request_stream_opened"
            try await send(
                payload,
                uid: uid,
                publicKey: publicKey,
                relayPublicKey: relayPublicKey,
                localNodeId: localNodeId,
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
                    "errorClass": irohPublicErrorClass(error)
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
        localNodeId: String,
        verifiedTarget: IrohDialTarget,
        stream: any IrohRelayStream,
        timeout: TimeInterval,
        networkAuditDetail: [String: String],
        onChunk: @MainActor (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        do {
            try await sendOnOpenStream(
                payload,
                uid: uid,
                publicKey: publicKey,
                relayPublicKey: relayPublicKey,
                localNodeId: localNodeId,
                verifiedTarget: verifiedTarget,
                stream: stream,
                timeout: timeout,
                networkAuditDetail: networkAuditDetail,
                onChunk: onChunk
            )
            await stream.close()
            if payload.operation == .chatCompletions {
                startMediaControlCoordinatorIfNeeded(
                    uid: uid,
                    connectionID: payload.connectionID,
                    pairingPublicKey: publicKey
                )
            }
        } catch {
            await stream.close()
            throw error
        }
    }

    private func sendOnOpenStream(
        _ payload: HermesRelayPayload,
        uid: String,
        publicKey: Data,
        relayPublicKey: String,
        localNodeId: String,
        verifiedTarget: IrohDialTarget,
        stream: any IrohRelayStream,
        timeout: TimeInterval,
        networkAuditDetail: [String: String],
        onChunk: @MainActor (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        let requestID = "iroh_\(UUID().uuidString.lowercased())"
        _ = relayPublicKey
        let sealed = try await MobileHermesAuthenticatedRelayRequestSealer.seal(
            payload: payload,
            uid: uid,
            requestID: requestID,
            senderPeerNodeID: localNodeId
        )
        let keyData = sealed.keyData

        let startFrame = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: uid,
            connectionId: payload.connectionID,
            requestId: requestID,
            payload: sealed.payload
        )
        try await stream.send(startFrame)

        let started = Date()
        let effectiveTimeout = Self.effectiveRequestTimeout(
            operation: payload.operation,
            requestedTimeout: timeout
        )
        var deadline = started.addingTimeInterval(effectiveTimeout)
        var receivedChunkCount = 0
        // F4: detect a relay that drops/withholds a sealed chunk (silent truncation).
        var chunkValidator = ChunkReassemblyValidator()
        var didRecordFirstChunk = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            guard let frame = try await Self.receiveFrame(from: stream, timeout: remaining) else {
                throw HermesServiceError.relayUnavailable("Iroh stream closed before completion.")
            }
            guard frame.uid == uid,
                  frame.connectionId == payload.connectionID,
                  frame.requestId == requestID else {
                continue
            }
            switch Self.requestStreamRoute(for: frame.type) {
            case .responseChunk:
                guard let chunk = try chunkRecord(from: frame, keyData: keyData, uid: uid, connectionID: payload.connectionID, requestID: requestID) else { continue }
                receivedChunkCount += 1
                try chunkValidator.record(sequence: chunk.sequence)
                let graceDeadline = Date().addingTimeInterval(Self.responseCompleteGraceTimeout)
                if deadline < graceDeadline {
                    deadline = graceDeadline
                }
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
                if payload.operation == .chatCompletions,
                   chunk.kind == .sse,
                   Self.isTerminalSSEChunk(chunk.data ?? chunk.text) {
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
                            "chunks": "\(receivedChunkCount)",
                            "completedBy": "terminal_sse"
                        ], networkAuditDetail)
                    )
                    return
                }
            case .responseComplete:
                // F4: refuse a truncated response — a relay that dropped a sealed
                // chunk leaves a gap below the declared `chunkCount`. No-op when the
                // completion does not declare a total (streaming).
                try chunkValidator.validateComplete(declaredChunkCount: frame.payload?.chunkCount ?? 0)
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
                throw HermesServiceError.relayFailure(
                    HermesRealtimeRelayErrorCode.publicMessage(for: frame.payload?.errorCode),
                    fallback: "Hermes iroh relay failed."
                )
            case .ignore:
                continue
            case .mediaDispatcher:
                guard let dispatcher = mediaDispatcher else { continue }
                let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = { [stream] outboundFrame in
                    try await stream.send(outboundFrame)
                }
                await dispatcher(frame, ackSender)
                continue
            }
        }
        throw HermesServiceError.relayTimeout
    }

    private nonisolated static func requestStreamRoute(
        for type: HermesRealtimeRelayFrameType
    ) -> RequestStreamFrameRoute {
        switch type {
        case .responseChunk:
            return .responseChunk
        case .responseComplete:
            return .responseComplete
        case .responseError:
            return .responseError
        case .mediaClassify,
             .mediaBlobAdvertise,
             .mediaBlobAck,
             .signalSessionMessage,
             .mediaMirrorRequest,
             .mediaMirrorAck,
             .mediaMirrorStop,
             .mediaMirrorDisplaySelect,
             .mediaPresenceHeartbeat,
             .mediaLongTermReferenceAck,
             .mediaCallInvite,
             .mediaCallAck,
             .mediaStreamFrame:
            return .mediaDispatcher
        case .ping, .pong, .requestCancel, .requestStart, .hostReady, .hostRegister,
             .controlClassify, .controlActionLogEntry, .controlInputIntent,
             .controlApprovalRequest, .controlApprovalResponse,
             .controlAgentGrantRequest, .controlAgentGrantReceipt,
             .controlClipboardRequest, .controlClipboardResponse,
             .controlAgentContextTarget,
             .controlDenied,
             .controlSystemPermissionRequest,
             .controlSystemPermissionStatus,
             .remoteUnlockSession,
             .remoteUnlockState,
             .remoteUnlockInput,
             .remoteUnlockCredential,
             .remoteUnlockResult,
             .remoteUnlockDenied:
            return .ignore
        }
    }

    #if DEBUG
    nonisolated static func routesRequestStreamFrameToMediaDispatcherForTesting(
        _ type: HermesRealtimeRelayFrameType
    ) -> Bool {
        requestStreamRoute(for: type) == .mediaDispatcher
    }

    nonisolated static func ignoresRequestStreamFrameForTesting(
        _ type: HermesRealtimeRelayFrameType
    ) -> Bool {
        requestStreamRoute(for: type) == .ignore
    }
    #endif

    private nonisolated static func isTerminalSSEChunk(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let dataLines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.lowercased().hasPrefix("data:") else { return trimmed }
                return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let payloads = dataLines.isEmpty ? [raw] : dataLines
        if payloads.contains(where: { $0 == "[DONE]" }) {
            return true
        }
        return payloads.contains { payload in
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]] else {
                return false
            }
            return choices.contains { choice in
                guard let finishReason = choice["finish_reason"] else { return false }
                if finishReason is NSNull { return false }
                if let string = finishReason as? String {
                    return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true
            }
        }
    }

    private nonisolated static func effectiveRequestTimeout(
        operation: HermesRelayOperation,
        requestedTimeout: TimeInterval
    ) -> TimeInterval {
        switch operation {
        case .chatCompletions:
            return requestedTimeout
        case .cliAgentChat:
            return requestedTimeout
        case .cliAgentModelCatalog, .cliAgentSessionAction, .models, .sessions, .sessionDetail, .profiles, .jobs:
            return max(requestedTimeout, minimumControlPlaneRequestTimeout)
        }
    }

    private nonisolated static func receiveFrame(
        from stream: any IrohRelayStream,
        timeout: TimeInterval
    ) async throws -> HermesRealtimeRelayFrame? {
        guard timeout > 0 else {
            throw HermesServiceError.relayTimeout
        }
        return try await withThrowingTaskGroup(of: HermesRealtimeRelayFrame?.self) { group in
            group.addTask {
                try await stream.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds(timeout))
                throw HermesServiceError.relayTimeout
            }
            guard let frame = try await group.next() else {
                throw HermesServiceError.relayTimeout
            }
            group.cancelAll()
            return frame
        }
    }

    private nonisolated static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
        let capped = min(max(timeout, 0.001), 3_600)
        return UInt64(capped * 1_000_000_000)
    }

    private func auditDetail(
        _ detail: [String: String],
        _ networkDetail: [String: String]
    ) -> [String: String] {
        detail.merging(networkDetail) { current, _ in current }
    }

    @MainActor
    private func startMediaControlCoordinatorIfNeeded(
        uid: String,
        connectionID: String,
        pairingPublicKey: Data
    ) {
        if let existing = mediaControlCoordinators[connectionID] {
            existing.start(uid: uid, connectionID: connectionID)
            lastMediaControlConnectionID = connectionID
            return
        }
        guard let receiver = mediaControlReceiver else {
            return
        }
        startMediaControlCoordinator(
            uid: uid,
            connectionID: connectionID,
            pairingPublicKey: pairingPublicKey,
            receiver: receiver
        )
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
        coordinator.presenceHeartbeatHandler = mediaPresenceHeartbeatHandler
        coordinator.start(uid: uid, connectionID: connectionID)
        receiver.attachControlStream(coordinator, connectionID: connectionID)
        mediaControlCoordinators[connectionID] = coordinator
        lastMediaControlConnectionID = connectionID
    }

    private func transport(relayURL: String?) async throws -> any IrohRelayTransport {
        let normalizedRelayURL = Self.normalizedRelayURL(relayURL)
        if let endpoint, identity != nil, endpointRelayURL == normalizedRelayURL {
            return endpoint
        }
        if let bootstrapTask {
            // A concurrent caller is already starting the endpoint —
            // hand them the same outcome when it targets the same home relay.
            if bootstrapRelayURL == normalizedRelayURL {
                return try await bootstrapTask.value
            }
            bootstrapTask.cancel()
            self.bootstrapTask = nil
            self.bootstrapRelayURL = nil
            bootstrapGeneration += 1
        }
        if let endpoint {
            await endpoint.shutdown()
            self.endpoint = nil
            self.identity = nil
            self.endpointRelayURL = nil
        }
        let factory = transportFactory
        bootstrapGeneration += 1
        let generation = bootstrapGeneration
        let task = Task { @MainActor [factory, normalizedRelayURL, generation] () throws -> any IrohRelayTransport in
            await HermesIrohHostedRelayConfig.refreshRemoteConfigIfAvailable()
            let transport = factory(normalizedRelayURL)
            #if DEBUG
            if ProcessInfo.processInfo.environment["OPENBURNBAR_ALLOW_IROH_LOOPBACK"] != "1",
               transport is LoopbackIrohRelayTransport {
                assertionFailure(
                    "Hermes iroh mobile resolved LoopbackIrohRelayTransport. Build/link Vendor/OpenBurnBarIroh.xcframework so QA/dev devices use IrohXcframeworkTransport."
                )
            }
            #endif
            let identity = try await transport.start()
            guard !Task.isCancelled, self.bootstrapGeneration == generation else {
                await transport.shutdown()
                throw CancellationError()
            }
            self.endpoint = transport
            self.identity = identity
            self.endpointRelayURL = normalizedRelayURL
            return transport
        }
        bootstrapTask = task
        bootstrapRelayURL = normalizedRelayURL
        defer {
            if bootstrapRelayURL == normalizedRelayURL {
                bootstrapTask = nil
                bootstrapRelayURL = nil
            }
        }
        return try await task.value
    }

    static func bootstrapStartupTimeout(connectTimeout: TimeInterval) -> TimeInterval {
        max(defaultBootstrapStartupTimeout, connectTimeout + 25)
    }

    static func normalizedRelayURL(_ relayURL: String?) -> String? {
        let normalized = relayURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
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

    static func defaultTransport(relayURL: String? = nil) -> any IrohRelayTransport {
        let secretProvider: @Sendable () throws -> IrohSecretKeyMaterial = {
            try IrohRelayKeyStore.shared.secretKeyMaterial()
        }
        if let backend = OpenBurnBarIrohFFIBackendFactory.make() {
            let normalizedRelayURL = Self.normalizedRelayURL(relayURL)
            return IrohXcframeworkTransport(
                backend: backend,
                secretProvider: secretProvider,
                relayURLProvider: {
                    normalizedRelayURL ?? HermesIrohHostedRelayConfig.currentURL()
                }
            )
        }
        let rendezvous = LoopbackIrohRelayRendezvous()
        return LoopbackIrohRelayTransport(rendezvous: rendezvous)
    }

    private func persistIrohPeerNodeId(_ nodeId: String, uid: String) async {
        guard FirebaseApp.app() != nil else { return }
        let deviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("devices").document(deviceId)
                .setData(
                    [
                        "deviceId": deviceId,
                        "irohPeerNodeId": nodeId,
                        "updated_at_millis": nowMillis
                    ],
                    merge: true
                )
        } catch {
            #if DEBUG
            print("HermesIrohRelayTransport irohPeerNodeId persist failed: \(irohPublicErrorClass(error))")
            #endif
        }
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

    private final class ContinuationGate: Sendable {
        private struct State {
            var didResume = false
            let continuation: CheckedContinuation<Void, Never>
        }

        private let state: OSAllocatedUnfairLock<State>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            state = OSAllocatedUnfairLock(uncheckedState: State(continuation: continuation))
        }

        func resume() {
            let continuation = state.withLockUnchecked { state -> CheckedContinuation<Void, Never>? in
                guard !state.didResume else { return nil }
                state.didResume = true
                return state.continuation
            }
            continuation?.resume()
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

private final class IrohTimeoutGate<T: Sendable>: Sendable {
    private struct State {
        var didResume = false
        let continuation: CheckedContinuation<T, Error>
        var onResume: (@Sendable () -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>

    var onResume: (@Sendable () -> Void)? {
        get { state.withLockUnchecked { $0.onResume } }
        set { state.withLockUnchecked { $0.onResume = newValue } }
    }

    init(_ continuation: CheckedContinuation<T, Error>) {
        state = OSAllocatedUnfairLock(uncheckedState: State(continuation: continuation))
    }

    func resume(returning value: T) {
        finish { $0.resume(returning: value) }
    }

    func resume(throwing error: Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ resumeContinuation: (CheckedContinuation<T, Error>) -> Void) {
        let resolved = state.withLockUnchecked { state -> (CheckedContinuation<T, Error>, (@Sendable () -> Void)?)? in
            guard !state.didResume else { return nil }
            state.didResume = true
            return (state.continuation, state.onResume)
        }
        guard let (continuation, callback) = resolved else { return }
        resumeContinuation(continuation)
        callback?()
    }
}

protocol IrohPairingPublicKeyProviding: Sendable {
    func fetchPublicKey(uid: String) async throws -> Data
}

import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
import FirebaseRemoteConfig
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

/// Mac-side host that serves Hermes Realtime Relay requests over the iroh
/// peer-to-peer transport. Drop-in replacement for
/// `HermesRealtimeRelayHostClient` (WSS-based) — same public surface,
/// `HermesRealtimeRelayHosting` conformance, same `HermesRelayCrypto`
/// envelope. The only difference is the wire: instead of WSS to Cloud Run,
/// frames flow through an iroh-bidirectional stream the iOS client opens
/// after verifying the Mac's signed `iroh_pairing` record.
///
/// Lifecycle on `start(uid:connectionID:)`:
///   1. Bootstrap the iroh endpoint via `IrohXcframeworkTransport`.
///   2. Sign + publish an `IrohPairingRecord` to Firestore (read by iOS).
///   3. Spawn `accept(timeout:)` loop on a Task; each inbound stream is
///      served by `IrohRelayRequestHandler`.
///   4. Periodically refresh the pairing record so iOS's freshness window
///      never expires.
///
/// On `stop()` we revoke the pairing record, cancel the accept loop, and
/// shut down the transport.
@MainActor
final class HermesIrohRelayHostClient: HermesRealtimeRelayHosting {
    private let accountManager: AccountManager
    private let settingsManager: SettingsManager
    private let relayKeyStore: HermesRelayKeyStore
    private let pairingKeyStore: IrohPairingKeyStore
    private let directory: any IrohPairingDirectory
    private let publicKeyPublisher: IrohPairingPublicKeyPublishing
    private let inboundPeerPolicyLoader: @Sendable (String, String) async -> IrohInboundPeerPolicy
    private let transportFactory: @MainActor (HermesIrohRelayHostClient) -> any IrohRelayTransport
    private let urlSession: URLSession
    private let auditLogger: any IrohTransportAuditLogging
    private var transport: (any IrohRelayTransport)?
    private var acceptTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var acceptLoopHealthy = false
    private var heartbeatHealthy = false
    /// Mercury media dispatcher (Phase 1b). Set by the host owner so the
    /// per-stream `IrohRelayRequestHandler` can hand inbound `media.blob.*`
    /// frames to `MacFileTransferService` without this class importing
    /// the media surface.
    var mediaDispatcher: MediaFrameDispatcher?

    /// Mercury media control-stream registrar (Risk-1 fix). Invoked when
    /// iOS opens a stream and classifies it as `media.control`. The
    /// owner registers the stream and drives a long-lived read loop so
    /// Mac can push `media.blob.advertise` frames at any time without
    /// waiting for an active iOS-initiated chat request.
    var mediaControlRegistrar: MediaControlStreamRegistrar?
    /// RR-18 — the same persistent media-control registry the owner builds in
    /// `HermesRelayHostService`. The host hands inbound `media.control` streams
    /// to it via `mediaControlRegistrar`; this reference lets the heartbeat tear
    /// those streams down per-peer the instant a peer leaves the inbound
    /// allowlist, instead of letting a revoked peer keep a live media lane open
    /// until the stream closes on its own.
    var mediaControlStreamRegistry: MediaControlStreamRegistry?
    var cliChatDispatcher: CLIAgentRelayChatDispatcher?
    var cliModelCatalogDispatcher: CLIRuntimeModelCatalogDispatcher?
    var cliSessionActionDispatcher: CLIAgentSessionActionDispatcher?
    /// Phase 12 — Computer Use control plane. Receives `control.input`,
    /// `control.classify`, `control.action.log.entry`, and
    /// `control.approval.{request,response}` frames. Set by
    /// `ComputerUseSessionCoordinator` when a session opens; cleared on
    /// session end.
    var controlDispatcher: ControlFrameDispatcher?
    /// Per-stream serve tasks spawned by `acceptLoop`. Tracked so `stop()`
    /// can cancel them deterministically instead of letting them outlive the
    /// host.
    private var serveTasks: [UUID: Task<Void, Never>] = [:]
    /// RR-18 — per-peer index over the same serve tasks `serveTasks` tracks by
    /// opaque id. The accept loop records each serve task here keyed by its
    /// stream's `remotePeerNodeId`, the heartbeat purges the entries for peers
    /// no longer allowed by the freshly-refreshed `inboundPeerPolicy`, and
    /// `stop()` / `handleAcceptLoopTerminated` route their teardown through it
    /// so the two views can never drift.
    private let serveTaskTeardownRegistry = MediaServeTaskTeardownRegistry()
    private var readyUID: String?
    private var readyConnectionID: String?
    private var publishedIdentity: IrohEndpointIdentity?
    private var inboundPeerPolicy = IrohInboundPeerPolicy(allowedPeerNodeIds: [])
    private let pairingPublishInterval: TimeInterval

    private static func publicErrorClass(_ error: Error) -> String {
        let nsError = error as NSError
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").inverted
        let domain = nsError.domain.components(separatedBy: allowed).joined(separator: "_")
        return "\(domain)#\(nsError.code)"
    }

    init(
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        relayKeyStore: HermesRelayKeyStore = HermesRelayKeyStore(),
        pairingKeyStore: IrohPairingKeyStore = IrohPairingKeyStore(),
        directory: any IrohPairingDirectory = FirestoreIrohPairingDirectory.shared,
        publicKeyPublisher: IrohPairingPublicKeyPublishing = IrohPairingPublicKeyPublisher.shared,
        auditLogger: any IrohTransportAuditLogging = FirestoreIrohAuditLogger.shared,
        inboundPeerPolicyLoader: @escaping @Sendable (String, String) async -> IrohInboundPeerPolicy = { uid, connectionID in
            await FirestoreIrohInboundPeerAllowlist.load(uid: uid, connectionId: connectionID)
        },
        urlSession: URLSession = .shared,
        pairingPublishInterval: TimeInterval = 60,
        transportFactory: @escaping @MainActor (HermesIrohRelayHostClient) -> any IrohRelayTransport = { _ in
            HermesIrohRelayHostClient.defaultTransport()
        }
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.relayKeyStore = relayKeyStore
        self.pairingKeyStore = pairingKeyStore
        self.directory = directory
        self.publicKeyPublisher = publicKeyPublisher
        self.auditLogger = auditLogger
        self.inboundPeerPolicyLoader = inboundPeerPolicyLoader
        self.urlSession = urlSession
        self.pairingPublishInterval = pairingPublishInterval
        self.transportFactory = transportFactory
    }

    var isReady: Bool {
        relayRuntimeHealthy
    }

    /// We never advertise the iroh transport as a publishable WSS URL. iOS
    /// discovers the iroh NodeId through the Firestore pairing record.
    var publishableRelayURLString: String? { nil }

    func setControlDispatcher(_ dispatcher: ControlFrameDispatcher?) {
        controlDispatcher = dispatcher
    }

    @discardableResult
    func start(uid: String, connectionID: String) async -> Bool {
        if transport != nil, readyUID == uid, readyConnectionID == connectionID {
            guard relayRuntimeHealthy else {
                AppLogger.network.info(
                    "hermes_iroh_relay_rebuild_stale_runtime connectionID=\(connectionID)"
                )
                stop()
                return await start(uid: uid, connectionID: connectionID)
            }
            await refreshPairingRecord(uid: uid, connectionID: connectionID)
            return true
        }
        stop()
        #if DEBUG
        let forceIrohTransport = ProcessInfo.processInfo.environment["OPENBURNBAR_ENABLE_IROH_TRANSPORT"] == "1"
        #else
        let forceIrohTransport = false
        #endif
        guard settingsManager.hermesIrohTransportEnabled || forceIrohTransport else { return false }

        await HermesIrohHostedRelayConfig.refreshRemoteConfigIfAvailable()
        let newTransport = transportFactory(self)
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPENBURNBAR_ALLOW_IROH_LOOPBACK"] != "1",
           newTransport is LoopbackIrohRelayTransport {
            assertionFailure(
                "Hermes iroh host resolved LoopbackIrohRelayTransport. Build/link Vendor/OpenBurnBarIroh.xcframework so QA/dev devices use IrohXcframeworkTransport."
            )
        }
        #endif
        var startupStage = "transport_start"
        do {
            let identity = try await newTransport.start()
            transport = newTransport
            publishedIdentity = identity

            startupStage = "pairing_key_load"
            let pairingKeypair = try pairingKeyStore.keypair()
            // Publish the verifier key BEFORE the pairing record so iOS
            // never sees a freshly-published `iroh_pairing/*` doc without
            // the corresponding `iroh_pairing_keys/host` doc to verify it.
            startupStage = "pairing_public_key_publish"
            try await publicKeyPublisher.publish(
                uid: uid,
                deviceId: accountManager.deviceId,
                publicKeyBase64: pairingKeypair.publicKeyBase64
            )
            let publisher = IrohPairingPublisher(directory: directory)
            startupStage = "pairing_record_publish"
            _ = try await publisher.publish(
                uid: uid,
                connectionId: connectionID,
                nodeId: identity.nodeId,
                relayURL: identity.relayURL,
                directAddresses: identity.directAddresses,
                with: pairingKeypair
            )
            await auditLogger.record(
                event: .pairingPublished,
                uid: uid,
                connectionId: connectionID,
                transport: nil,
                rttMillis: nil,
                detail: [
                    "nodeId": identity.nodeId,
                    "relayURL": identity.relayURL ?? "",
                    "directAddressCount": "\(identity.directAddresses.count)"
                ]
            )

            readyUID = uid
            readyConnectionID = connectionID
            inboundPeerPolicy = await inboundPeerPolicyLoader(uid, connectionID)
            acceptLoopHealthy = true
            heartbeatHealthy = true

            acceptTask = Task { [weak self] in
                await self?.acceptLoop(transport: newTransport, uid: uid, connectionID: connectionID)
            }
            heartbeatTask = Task { [weak self, pairingPublishInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(pairingPublishInterval * 1_000_000_000))
                    await self?.refreshPairingRecord(uid: uid, connectionID: connectionID)
                    if let self {
                        self.inboundPeerPolicy = await self.inboundPeerPolicyLoader(uid, connectionID)
                        await self.purgeStreamsForDeallowlistedPeers()
                    }
                }
            }

            AppLogger.network.info(
                "hermes_iroh_relay_started connectionID=\(connectionID) nodeID=\(identity.nodeId) directAddressCount=\(identity.directAddresses.count)"
            )
            return true
        } catch {
            let errorClass = Self.publicErrorClass(error)
            AppLogger.network.error(
                "hermes_iroh_relay_start_failed_public stage=\(startupStage) errorClass=\(errorClass)"
            )
            AppLogger.network.silentFailure("hermes_iroh_relay_start_failed", error: error)
            transport = nil
            return false
        }
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        acceptLoopHealthy = false
        heartbeatHealthy = false
        for task in serveTasks.values {
            task.cancel()
        }
        serveTasks.removeAll()

        let transportToStop = transport
        let uid = readyUID
        let connectionID = readyConnectionID

        transport = nil
        readyUID = nil
        readyConnectionID = nil
        let revokedNodeId = publishedIdentity?.nodeId
        publishedIdentity = nil

        Task { [directory, auditLogger, serveTaskTeardownRegistry] in
            // RR-18 — drain the per-peer teardown index through the same
            // cancel-all path `stop()` already runs over `serveTasks`.
            await serveTaskTeardownRegistry.cancelAll()
            if let transportToStop {
                await transportToStop.shutdown()
            }
            if let uid, let connectionID {
                try? await directory.revoke(uid: uid, connectionId: connectionID)
                await auditLogger.record(
                    event: .streamClosed,
                    uid: uid,
                    connectionId: connectionID,
                    transport: .irohDirect,
                    rttMillis: nil,
                    detail: revokedNodeId.map { ["nodeId": $0] } ?? [:]
                )
            }
        }
    }

    private func acceptLoop(
        transport: any IrohRelayTransport,
        uid: String,
        connectionID: String
    ) async {
        var consecutiveAcceptFailures = 0
        while !Task.isCancelled {
            do {
                let stream = try await transport.accept(timeout: 30)
                if !inboundPeerPolicy.allows(remotePeerNodeId: stream.remotePeerNodeId) {
                    let refreshedPolicy = await inboundPeerPolicyLoader(uid, connectionID)
                    inboundPeerPolicy = refreshedPolicy
                    if !refreshedPolicy.allows(remotePeerNodeId: stream.remotePeerNodeId) {
                        #if DEBUG
                        NSLog("OpenBurnBarMercury host_inbound_peer_rejected connectionID=\(connectionID) remoteNodeId=\(stream.remotePeerNodeId ?? "unknown")")
                        #endif
                        await auditLogger.record(
                            event: .pairingRejected,
                            uid: uid,
                            connectionId: connectionID,
                            transport: .irohDirect,
                            rttMillis: nil,
                            detail: [
                                "reason": "inbound_peer_not_allowlisted",
                                "remoteNodeId": stream.remotePeerNodeId ?? "unknown"
                            ]
                        )
                        await stream.close()
                        continue
                    }
                    #if DEBUG
                    NSLog("OpenBurnBarMercury host_inbound_peer_allowed_after_refresh connectionID=\(connectionID) remoteNodeId=\(stream.remotePeerNodeId ?? "unknown")")
                    #endif
                }
                consecutiveAcceptFailures = 0
                let handler = IrohRelayRequestHandler(
                    relayKeyStore: relayKeyStore,
                    urlSession: urlSession,
                    settingsManager: settingsManager,
                    mediaDispatcher: mediaDispatcher,
                    mediaControlRegistrar: mediaControlRegistrar,
                    controlDispatcher: controlDispatcher,
                    cliChatDispatcher: cliChatDispatcher,
                    cliModelCatalogDispatcher: cliModelCatalogDispatcher,
                    cliSessionActionDispatcher: cliSessionActionDispatcher,
                    auditLogger: auditLogger
                )
                let serveID = UUID()
                let task = Task { [weak self, auditLogger] in
                    let start = Date()
                    await auditLogger.record(
                        event: .streamOpened,
                        uid: uid,
                        connectionId: connectionID,
                        transport: .irohDirect,
                        rttMillis: nil,
                        detail: [:]
                    )
                    do {
                        let disposition = try await handler.serve(
                            stream: stream,
                            uid: uid,
                            connectionID: connectionID
                        )
                        let rtt = Int(Date().timeIntervalSince(start) * 1000)
                        await auditLogger.record(
                            event: .streamClosed,
                            uid: uid,
                            connectionId: connectionID,
                            transport: .irohDirect,
                            rttMillis: rtt,
                            detail: ["disposition": "\(disposition)"]
                        )
                        if disposition == .callerOwnsStream {
                            await stream.close()
                        }
                    } catch {
                        await auditLogger.record(
                            event: .streamFailed,
                            uid: uid,
                            connectionId: connectionID,
                            transport: .irohDirect,
                            rttMillis: nil,
                            detail: ["errorClass": Self.publicErrorClass(error)]
                        )
                        await stream.close()
                    }
                    await self?.releaseServeTask(serveID)
                }
                serveTasks[serveID] = task
                // RR-18 — mirror the task into the per-peer teardown index so a
                // mid-stream de-allowlist can cancel just this peer's tasks.
                let remotePeerNodeId = stream.remotePeerNodeId
                await serveTaskTeardownRegistry.register(
                    serveID: serveID,
                    remotePeerNodeId: remotePeerNodeId,
                    task: task
                )
            } catch IrohRelayTransportError.timedOut {
                consecutiveAcceptFailures = 0
                continue
            } catch IrohRelayTransportError.shutdown {
                await handleAcceptLoopTerminated(
                    transport: transport,
                    uid: uid,
                    connectionID: connectionID,
                    reason: "shutdown",
                    shouldRestart: !Task.isCancelled
                )
                return
            } catch {
                if Self.isRecoverablePeerAcceptError(error) {
                    consecutiveAcceptFailures = 0
                    AppLogger.network.info(
                        "hermes_iroh_relay_accept_peer_closed connectionID=\(connectionID) errorClass=\(Self.publicErrorClass(error))"
                    )
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                consecutiveAcceptFailures += 1
                AppLogger.network.silentFailure("hermes_iroh_relay_accept_failed", error: error)
                let shouldRebuild = Self.shouldRebuildAfterAcceptError(error)
                    || consecutiveAcceptFailures >= 3
                if shouldRebuild {
                    await handleAcceptLoopTerminated(
                        transport: transport,
                        uid: uid,
                        connectionID: connectionID,
                        reason: Self.publicErrorClass(error),
                        shouldRestart: true
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        await handleAcceptLoopTerminated(
            transport: transport,
            uid: uid,
            connectionID: connectionID,
            reason: "cancelled",
            shouldRestart: false
        )
    }

    private func releaseServeTask(_ id: UUID) async {
        serveTasks.removeValue(forKey: id)
        await serveTaskTeardownRegistry.release(serveID: id)
    }

    /// RR-18 — tear down any serve task or persistent media-control stream whose
    /// remote peer is no longer in the freshly-refreshed inbound allowlist.
    /// Called from the heartbeat right after `inboundPeerPolicy` is reloaded, so
    /// a peer that is de-allowlisted or revoked mid-stream loses its live lanes
    /// within one heartbeat instead of keeping them until natural close. The
    /// allow-checker captures the policy by value (it is `Sendable`), so the
    /// actor registries never reach back into `@MainActor` state.
    private func purgeStreamsForDeallowlistedPeers() async {
        let policy = inboundPeerPolicy
        let isAllowed: MediaInboundPeerAllowChecker = { policy.allows(remotePeerNodeId: $0) }
        let cancelledServeIDs = await serveTaskTeardownRegistry.cancelTasks(notAllowedBy: isAllowed)
        for serveID in cancelledServeIDs {
            serveTasks.removeValue(forKey: serveID)
        }
        if let registry = mediaControlStreamRegistry {
            let purgedPeerNodeIds = await registry.purgeStreamsNotAllowed(by: isAllowed)
            if !cancelledServeIDs.isEmpty || !purgedPeerNodeIds.isEmpty {
                AppLogger.network.info(
                    "hermes_iroh_relay_inbound_peer_purged serveTasks=\(cancelledServeIDs.count) controlStreams=\(purgedPeerNodeIds.count)"
                )
            }
        } else if !cancelledServeIDs.isEmpty {
            AppLogger.network.info(
                "hermes_iroh_relay_inbound_peer_purged serveTasks=\(cancelledServeIDs.count) controlStreams=0"
            )
        }
    }

    private func refreshPairingRecord(uid: String, connectionID: String) async {
        guard relayRuntimeHealthy, let identity = publishedIdentity else { return }
        do {
            let pairingKeypair = try pairingKeyStore.keypair()
            try await publicKeyPublisher.publish(
                uid: uid,
                deviceId: accountManager.deviceId,
                publicKeyBase64: pairingKeypair.publicKeyBase64
            )
            let publisher = IrohPairingPublisher(directory: directory)
            _ = try await publisher.publish(
                uid: uid,
                connectionId: connectionID,
                nodeId: identity.nodeId,
                relayURL: identity.relayURL,
                directAddresses: identity.directAddresses,
                with: pairingKeypair
            )
        } catch {
            AppLogger.network.silentFailure("hermes_iroh_relay_pairing_refresh_failed", error: error)
        }
    }

    private var relayRuntimeHealthy: Bool {
        transport != nil
            && readyConnectionID != nil
            && acceptTask != nil
            && heartbeatTask != nil
            && acceptLoopHealthy
            && heartbeatHealthy
    }

    private func isCurrentTransport(_ candidate: any IrohRelayTransport) -> Bool {
        guard let transport else { return false }
        return transport === candidate
    }

    private func handleAcceptLoopTerminated(
        transport failedTransport: any IrohRelayTransport,
        uid: String,
        connectionID: String,
        reason: String,
        shouldRestart: Bool
    ) async {
        guard isCurrentTransport(failedTransport) else { return }

        let transportToStop = transport
        let revokedNodeId = publishedIdentity?.nodeId

        acceptLoopHealthy = false
        heartbeatHealthy = false
        acceptTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for task in serveTasks.values {
            task.cancel()
        }
        serveTasks.removeAll()
        // RR-18 — same cancel-all teardown for the per-peer index.
        await serveTaskTeardownRegistry.cancelAll()
        self.transport = nil
        readyUID = nil
        readyConnectionID = nil
        publishedIdentity = nil

        if let transportToStop {
            await transportToStop.shutdown()
        }
        try? await directory.revoke(uid: uid, connectionId: connectionID)
        await auditLogger.record(
            event: .streamFailed,
            uid: uid,
            connectionId: connectionID,
            transport: .irohDirect,
            rttMillis: nil,
            detail: [
                "reason": reason,
                "nodeId": revokedNodeId ?? ""
            ]
        )

        guard shouldRestart else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            _ = await self?.start(uid: uid, connectionID: connectionID)
        }
    }

    private static func shouldRebuildAfterAcceptError(_ error: Error) -> Bool {
        guard let transportError = error as? IrohRelayTransportError else { return false }
        switch transportError {
        case .endpointNotReady, .shutdown:
            return true
        case .streamRejected(let message), .decodeFailed(let message):
            let lowered = message.lowercased()
            return lowered.contains("closed")
                || lowered.contains("shut down")
                || lowered.contains("not initialized")
                || lowered.contains("runtime")
        case .nodeIdUnreachable, .protocolMismatch, .timedOut:
            return false
        }
    }

    private static func isRecoverablePeerAcceptError(_ error: Error) -> Bool {
        guard let transportError = error as? IrohRelayTransportError else { return false }
        switch transportError {
        case .streamRejected(let message), .decodeFailed(let message):
            let lowered = message.lowercased()
            return lowered.contains("connection lost")
                || lowered.contains("connection reset")
                || lowered.contains("reset by peer")
                || lowered.contains("closed by peer")
                || lowered.contains("application closed")
                || lowered.contains("finished early")
        case .timedOut:
            return true
        case .endpointNotReady, .nodeIdUnreachable, .protocolMismatch, .shutdown:
            return false
        }
    }

    /// Default transport: prefers the xcframework-backed UniFFI backend when
    /// the `OpenBurnBarIrohFFI` module is linked; falls back to the loopback
    /// transport (which only works against same-process Macs) for dev
    /// builds. Real production builds always have the FFI module.
    static func defaultTransport() -> any IrohRelayTransport {
        let secretProvider: @Sendable () throws -> IrohSecretKeyMaterial = {
            // Persist the iroh secret key alongside the existing relay
            // keypair so deleting the app removes both. Real implementation
            // is added by `IrohRelayKeyStore` in this directory.
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
        // Dev fallback: a process-local loopback transport. Note that in
        // this case `iOSTransport.connect(to:)` is never reachable from a
        // real device, so this branch is for local development against an
        // AgentLens / OpenBurnBarMobile pair on the same Mac via the
        // simulator.
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
        guard FirebaseApp.app() != nil else { return }
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
            ?? currentRemoteConfigURL()
    }

    private static func currentRemoteConfigURL() -> String? {
        guard FirebaseApp.app() != nil else { return nil }
        return normalized(RemoteConfig.remoteConfig().configValue(forKey: remoteConfigKey).stringValue)
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

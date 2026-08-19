import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
import FirebaseRemoteConfig
import Foundation
import os
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia

private actor IrohRelayLifecycleGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

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
    private let inboundPeerPolicyLoader: @Sendable (String, String) async -> IrohInboundPeerPolicyLoadResult
    private let transportFactory: @MainActor (HermesIrohRelayHostClient) -> any IrohRelayTransport
    private let urlSession: URLSession
    private let auditLogger: any IrohTransportAuditLogging
    private var transport: (any IrohRelayTransport)?

    /// The live endpoint, for callers that dial their own lanes over it (the
    /// War Wire). `nil` until the host has started, which is the honest answer:
    /// there is no endpoint to dial from yet.
    var activeTransport: (any IrohRelayTransport)? { transport }

    /// The published NodeId for callers that advertise this host as a War Wire
    /// endpoint. Keep this narrower than the full endpoint identity: callers
    /// only need the routable identity, and `nil` is the honest answer before
    /// the host has published one (or after it has stopped).
    var publishedNodeID: String? { publishedIdentity?.nodeId }

    private var acceptTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private struct RuntimeOwner: Sendable, Equatable {
        let epoch: UInt64
        let uid: String
        let connectionID: String
    }
    private let lifecycleGate = IrohRelayLifecycleGate()
    private var runtimeEpoch: UInt64 = 0
    private var desiredRuntimeOwner: RuntimeOwner?
    private var teardownTask: Task<Void, Never>?
    private var authStateListenerHandle: AuthStateDidChangeListenerHandle?
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
    /// War Room Wire handoff. The first `war.hello` frame is classified by
    /// `IrohRelayRequestHandler`; the owner then accepts and owns the stream.
    var warWireAcceptor: WarWireStreamAcceptor?
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
    private var policyLoadRequestEpoch: UInt64 = 0
    private var lastAuthoritativePolicyLoadAt: Date?
    private var missRefreshTask: Task<Void, Never>?
    private var lastAllowlistMissRefreshAt: Date?
    private struct ServeAuthorization: Sendable, Equatable {
        let sourceDeviceId: String
        let remotePeerNodeId: String
        let authorityPeerNodeId: String
        let generation: UInt64
        let registeredAtMillis: Int64
        let expiresAtMillis: Int64
    }
    private var serveAuthorizations: [UUID: ServeAuthorization] = [:]
    private var serveStreams: [UUID: any IrohRelayStream] = [:]
    private var routeExpiryTask: Task<Void, Never>?
    private let pairingPublishInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let missRefreshMinimumPolicyAge: TimeInterval
    private let missRefreshBudgetInterval: TimeInterval
    /// How many times teardown re-attempts a failed pairing-record revoke before
    /// it gives up and logs an error. A swallowed revoke leaves the host's
    /// `iroh_pairing/*` doc live in Firestore advertising a NodeId that is no
    /// longer accepting streams, so we retry instead of single-shotting it.
    private let revokeRetryAttempts: Int
    /// Backoff between revoke re-attempts, in nanoseconds. Injected so tests can
    /// drive the retry loop deterministically without real wall-clock waits.
    private let revokeRetrySleep: @Sendable (UInt64) async -> Void
    // remediation(handshake-before-allowlist DoS amplifier): per-source cooldown
    // over inbound connections that fail the allowlist. The Rust transport
    // (`openburnbar-iroh`, `AcceptSourceRateLimiter`) already drops repeat
    // sources cheaply *before* the QUIC handshake; this Swift-side throttle is
    // the second, defence-in-depth layer that suppresses repeated allowlist
    // rejections from the same NodeId — it stops a non-allowlisted peer that
    // does clear the Rust window from spamming the Firestore audit log on every
    // reconnect. It is purely anti-abuse: it never admits a peer the allowlist
    // would reject, it only collapses duplicate rejections.
    private var rejectedPeerLastSeen: [String: Date] = [:]
    private static let rejectedPeerCooldown: TimeInterval = 5
    private static let rejectedPeerTableCap = 1024
    /// An isolated peer close can surface from `accept` while the endpoint is
    /// still healthy, but an unbounded run of them means the native acceptor is
    /// no longer making forward progress. Rebuild after a small bounded burst
    /// instead of keeping a stale pairing record advertised forever.
    ///
    /// The burst count alone is peer-controlled: the native path reports
    /// `incoming.await` / `accept_bi` failures before Swift ever sees a peer
    /// identity or applies `inboundPeerPolicy`, so any peer that can reach the
    /// advertised endpoint can manufacture these errors by completing ALPN and
    /// closing early. The rebuild therefore additionally requires the absence
    /// of peer-independent endpoint-health evidence (active serve sessions or
    /// a recently completed accept, see
    /// `hasPeerIndependentEndpointHealthEvidence()`), so a hostile burst can
    /// never tear down live chat/media sessions or force NodeId churn while
    /// the acceptor is demonstrably serving traffic.
    private static let recoverablePeerAcceptFailureLimit = 3
    /// How long a completed `accept` counts as proof the native acceptor is
    /// making forward progress. A genuinely stalled endpoint stops producing
    /// successful accepts, so recovery is delayed by at most this window.
    private static let peerAcceptHealthEvidenceWindow: TimeInterval = 30
    /// Set every time `transport.accept` returns a stream (even one that the
    /// allowlist later rejects): a completed accept is acceptor-health
    /// evidence regardless of admission. Cleared on endpoint teardown.
    private var lastAcceptedStreamAt: Date?

    nonisolated static func shouldStopForAuthenticatedUserChange(
        readyUID: String?,
        authenticatedUID: String?
    ) -> Bool {
        guard let readyUID else { return false }
        return authenticatedUID != readyUID
    }

    /// Stable, non-PII code for transport/backend startup failures. Associated
    /// values can contain peer identifiers, paths, or backend diagnostics, so
    /// operational logs must classify the case without rendering its payload.
    private nonisolated static func publicErrorCode(_ error: Error) -> String {
        switch error {
        case let transportError as IrohRelayTransportError:
            switch transportError {
            case .backendUnavailable:
                return "transport_backend_unavailable"
            case .endpointNotReady:
                return "transport_endpoint_not_ready"
            case .nodeIdUnreachable:
                return "transport_node_unreachable"
            case .streamRejected:
                return "transport_stream_rejected"
            case .protocolMismatch:
                return "transport_protocol_mismatch"
            case .decodeFailed:
                return "transport_decode_failed"
            case .timedOut:
                return "transport_timed_out"
            case .shutdown:
                return "transport_shutdown"
            }
        case let backendError as IrohBackendError:
            switch backendError {
            case .notInitialized:
                return "backend_not_initialized"
            case .invalidSecretKey:
                return "backend_invalid_secret_key"
            case .invalidNodeId:
                return "backend_invalid_node_id"
            case .connectFailed:
                return "backend_connect_failed"
            case .streamFailed:
                return "backend_stream_failed"
            case .acceptFailed:
                return "backend_accept_failed"
            case .shutdownFailed:
                return "backend_shutdown_failed"
            case .runtimeFailed:
                return "backend_runtime_failed"
            }
        default:
            return publicErrorClass(error)
        }
    }

    // nonisolated: a pure error-classification helper (no actor state) used from
    // both isolated and nonisolated async retry/accept paths.
    private nonisolated static func publicErrorClass(_ error: Error) -> String {
        let nsError = error as NSError
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").inverted
        let domain = nsError.domain.components(separatedBy: allowed).joined(separator: "_")
        return "\(domain)#\(nsError.code)"
    }

    /// Revoke the host's `iroh_pairing/*` record, retrying with backoff so a
    /// transient Firestore fault can't silently leave a torn-down host still
    /// advertised. Returns once the record is removed (or the directory rejects
    /// the call as unsupported), or after the final attempt fails — in which
    /// case it logs an error so the divergence between directory state and host
    /// liveness is at least observable. `nonisolated static` so the detached
    /// teardown `Task` in `stop()` and the `@MainActor` `handleAcceptLoopTerminated`
    /// can both route through the one code path; everything it captures is
    /// `Sendable`.
    @discardableResult
    nonisolated static func revokePairingRecord(
        directory: any IrohPairingDirectory,
        uid: String,
        connectionID: String,
        attempts: Int,
        sleep: @Sendable (UInt64) async -> Void
    ) async -> Bool {
        let totalAttempts = max(1, attempts)
        var lastError: Error?
        for attempt in 1...totalAttempts {
            do {
                try await directory.revoke(uid: uid, connectionId: connectionID)
                if attempt > 1 {
                    AppLogger.network.info(
                        "hermes_iroh_relay_revoke_recovered attempt=\(attempt)"
                    )
                }
                return true
            } catch IrohPairingDirectoryError.unsupportedOnReader {
                // A read-only directory (e.g. the mobile reader) can never hold a
                // host-published record to revoke. Treat as a benign no-op so we
                // don't burn retries or escalate to an error on a host that was
                // never the writer.
                return true
            } catch {
                lastError = error
                if attempt < totalAttempts {
                    AppLogger.network.silentFailure(
                        "hermes_iroh_relay_revoke_retry",
                        error: error,
                        context: ["attempt": "\(attempt)", "errorClass": publicErrorClass(error)]
                    )
                    // Exponential backoff: 250ms, 500ms, 1s, ... capped at 5s.
                    // Clamp the shift first so a large `attempts` can never trap
                    // on UInt64 overflow before the cap is applied.
                    let shift = UInt64(min(attempt - 1, 32))
                    let backoffNanos = min(UInt64(5_000_000_000), UInt64(250_000_000) << shift)
                    await sleep(backoffNanos)
                }
            }
        }
        if let lastError {
            // Fail-loud: the record may still be live in Firestore. Surface it as
            // an error (not a silent failure) so the stale-advertisement is
            // visible in telemetry instead of being swallowed by a bare `try?`.
            AppLogger.network.error(
                "hermes_iroh_relay_revoke_failed",
                metadata: [
                    "attempts": "\(totalAttempts)",
                    "errorClass": publicErrorClass(lastError)
                ]
            )
        }
        return false
    }

    init(
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        relayKeyStore: HermesRelayKeyStore = HermesRelayKeyStore(),
        pairingKeyStore: IrohPairingKeyStore = IrohPairingKeyStore(),
        directory: (any IrohPairingDirectory)? = nil,
        publicKeyPublisher: IrohPairingPublicKeyPublishing = IrohPairingPublicKeyPublisher.shared,
        auditLogger: any IrohTransportAuditLogging = FirestoreIrohAuditLogger.shared,
        inboundPeerPolicyLoader: @escaping @Sendable (String, String) async -> IrohInboundPeerPolicyLoadResult = { uid, connectionID in
            await CallableIrohControllerRouteDirectory.load(uid: uid, connectionId: connectionID)
        },
        urlSession: URLSession = .shared,
        pairingPublishInterval: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init,
        missRefreshMinimumPolicyAge: TimeInterval = 0.5,
        missRefreshBudgetInterval: TimeInterval = 15,
        revokeRetryAttempts: Int = 3,
        revokeRetrySleep: @escaping @Sendable (UInt64) async -> Void = { nanos in
            try? await Task.sleep(nanoseconds: nanos) // try?-ok(cancellation only; backoff between revoke retries)
        },
        transportFactory: @escaping @MainActor (HermesIrohRelayHostClient) -> any IrohRelayTransport = { _ in
            HermesIrohRelayHostClient.defaultTransport()
        }
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.relayKeyStore = relayKeyStore
        self.pairingKeyStore = pairingKeyStore
        self.directory = directory ?? FirestoreIrohPairingDirectory(
            deviceIDProvider: { [accountManager] in
                await MainActor.run { accountManager.deviceId }
            }
        )
        self.publicKeyPublisher = publicKeyPublisher
        self.auditLogger = auditLogger
        self.inboundPeerPolicyLoader = inboundPeerPolicyLoader
        self.urlSession = urlSession
        self.pairingPublishInterval = pairingPublishInterval
        self.now = now
        self.missRefreshMinimumPolicyAge = max(0, missRefreshMinimumPolicyAge)
        self.missRefreshBudgetInterval = max(1, missRefreshBudgetInterval)
        self.revokeRetryAttempts = max(1, revokeRetryAttempts)
        self.revokeRetrySleep = revokeRetrySleep
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
        if let owner = desiredRuntimeOwner,
           transport != nil,
           readyUID == uid,
           readyConnectionID == connectionID {
            guard relayRuntimeHealthy else {
                AppLogger.network.info(
                    "hermes_iroh_relay_rebuild_stale_runtime connectionID=\(connectionID)"
                )
                stop()
                return await start(uid: uid, connectionID: connectionID)
            }
            return await refreshPairingRecord(uid: uid, connectionID: connectionID, owner: owner)
        }
        stop()
        let pendingTeardown = teardownTask
        runtimeEpoch &+= 1
        let owner = RuntimeOwner(epoch: runtimeEpoch, uid: uid, connectionID: connectionID)
        desiredRuntimeOwner = owner
        #if DEBUG
        let forceIrohTransport = ProcessInfo.processInfo.environment["OPENBURNBAR_ENABLE_IROH_TRANSPORT"] == "1"
        #else
        let forceIrohTransport = false
        #endif
        guard settingsManager.hermesIrohTransportEnabled || forceIrohTransport else {
            desiredRuntimeOwner = nil
            return false
        }

        await pendingTeardown?.value
        guard isCurrentRuntimeOwner(owner) else { return false }
        await lifecycleGate.acquire()
        guard isCurrentRuntimeOwner(owner) else {
            await lifecycleGate.release()
            return false
        }

        var newTransport: (any IrohRelayTransport)?
        var pairingPublicationAttempted = false
        await HermesIrohHostedRelayConfig.refreshRemoteConfigIfAvailable()
        guard isCurrentRuntimeOwner(owner) else {
            await lifecycleGate.release()
            return false
        }
        let prospectiveTransport = transportFactory(self)
        newTransport = prospectiveTransport
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPENBURNBAR_ALLOW_IROH_LOOPBACK"] != "1",
           prospectiveTransport is LoopbackIrohRelayTransport {
            assertionFailure(
                "Hermes iroh host resolved LoopbackIrohRelayTransport. Build/link Vendor/OpenBurnBarIroh.xcframework so QA/dev devices use IrohXcframeworkTransport."
            )
        }
        #endif
        do {
            let identity = try await prospectiveTransport.start()
            guard isCurrentRuntimeOwner(owner) else {
                await prospectiveTransport.shutdown()
                await lifecycleGate.release()
                return false
            }

            let pairingKeypair = try pairingKeyStore.keypair()
            // Publish the verifier key BEFORE the pairing record so iOS
            // never sees a freshly-published `iroh_pairing/*` doc without
            // the corresponding `iroh_pairing_keys/host` doc to verify it.
            try await publicKeyPublisher.publish(
                uid: uid,
                deviceId: accountManager.deviceId,
                publicKeyBase64: pairingKeypair.publicKeyBase64
            )
            guard isCurrentRuntimeOwner(owner) else {
                await prospectiveTransport.shutdown()
                await lifecycleGate.release()
                return false
            }
            let publisher = IrohPairingPublisher(directory: directory)
            pairingPublicationAttempted = true
            _ = try await publisher.publish(
                uid: uid,
                connectionId: connectionID,
                nodeId: identity.nodeId,
                relayURL: identity.relayURL,
                directAddresses: identity.directAddresses,
                with: pairingKeypair
            )
            guard isCurrentRuntimeOwner(owner) else {
                await prospectiveTransport.shutdown()
                await Self.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeRetryAttempts,
                    sleep: revokeRetrySleep
                )
                await lifecycleGate.release()
                return false
            }
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
            guard isCurrentRuntimeOwner(owner) else {
                await prospectiveTransport.shutdown()
                await Self.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeRetryAttempts,
                    sleep: revokeRetrySleep
                )
                await lifecycleGate.release()
                return false
            }

            let initialPolicyResult = await inboundPeerPolicyLoader(uid, connectionID)
            guard isCurrentRuntimeOwner(owner) else {
                await prospectiveTransport.shutdown()
                await Self.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeRetryAttempts,
                    sleep: revokeRetrySleep
                )
                await lifecycleGate.release()
                return false
            }

            transport = prospectiveTransport
            publishedIdentity = identity
            readyUID = uid
            readyConnectionID = connectionID
            policyLoadRequestEpoch &+= 1
            switch initialPolicyResult {
            case .authoritative(let policy):
                inboundPeerPolicy = policy
                lastAuthoritativePolicyLoadAt = now()
            case .transientFailure:
                inboundPeerPolicy = IrohInboundPeerPolicy(routeBindings: [])
                lastAuthoritativePolicyLoadAt = nil
            }
            installAuthStateListener()
            lastAllowlistMissRefreshAt = nil
            acceptLoopHealthy = true
            heartbeatHealthy = true

            acceptTask = Task { [weak self] in
                await self?.acceptLoop(
                    transport: prospectiveTransport,
                    uid: uid,
                    connectionID: connectionID,
                    owner: owner
                )
            }
            heartbeatTask = Task { [weak self, pairingPublishInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(pairingPublishInterval * 1_000_000_000)) // try?-ok(cancellation only)
                    guard let self, self.isCurrentRuntimeOwner(owner) else { return }
                    let refreshed = await self.refreshPairingRecord(
                        uid: uid,
                        connectionID: connectionID,
                        owner: owner
                    )
                    guard refreshed, self.isCurrentRuntimeOwner(owner) else { return }
                    await self.refreshInboundPeerPolicy(uid: uid, connectionID: connectionID)
                }
            }

            AppLogger.network.info(
                "hermes_iroh_relay_started connectionID=\(connectionID) nodeID=\(identity.nodeId) directAddressCount=\(identity.directAddresses.count)"
            )
            await lifecycleGate.release()
            return isCurrentRuntimeOwner(owner) && relayRuntimeHealthy
        } catch {
            // A permanent host-start outage takes down every Mercury surface
            // (mirror, calls, file transfer) while the Mac still publishes
            // `status: online` from its healthy chat gateway, so this log line
            // is the only place the real cause is ever stated.
            //
            // `silentFailure` alone is not enough: it emits errorType/
            // errorDomain/errorCode as *metadata*, and `logMetadata` hashes
            // every metadata value (`privacy: .private(mask: .hash)`). The
            // 2026-07-28 investigation therefore saw the event fire on a loop
            // with all four fields masked, and had to bisect the whole `do`
            // block by hand to localize the throw.
            //
            // Emit the diagnosis in the event string instead, which OSLog
            // renders `.public` — matching `hermes_iroh_relay_accept_peer_closed`
            // below. `publicErrorClass` yields a sanitized `domain#code` token
            // (no user data), and `stage` distinguishes an endpoint-bootstrap
            // failure from a post-publish one, which is exactly the split that
            // was expensive to recover by hand.
            let stage = pairingPublicationAttempted ? "post_pairing_publish" : "endpoint_bootstrap"
            AppLogger.network.error(
                "hermes_iroh_relay_start_failed connectionID=\(connectionID) stage=\(stage) errorClass=\(Self.publicErrorClass(error)) errorCode=\(Self.publicErrorCode(error)) hostedRelayConfigured=\(HermesIrohHostedRelayConfig.currentURL() != nil)"
            )
            // Keep the structured/Sentry breadcrumb too — the line above is for
            // a human reading `log show`, this one keeps crash-reporter parity.
            AppLogger.network.silentFailure(
                "hermes_iroh_relay_start_failed",
                error: error,
                context: ["stage": stage]
            )
            if let newTransport {
                await newTransport.shutdown()
            }
            if pairingPublicationAttempted {
                await Self.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeRetryAttempts,
                    sleep: revokeRetrySleep
                )
            }
            if isCurrentRuntimeOwner(owner) {
                desiredRuntimeOwner = nil
            }
            await lifecycleGate.release()
            return false
        }
    }

    func stop() {
        runtimeEpoch &+= 1
        desiredRuntimeOwner = nil
        if let authStateListenerHandle {
            Auth.auth().removeStateDidChangeListener(authStateListenerHandle)
            self.authStateListenerHandle = nil
        }
        acceptTask?.cancel()
        acceptTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        missRefreshTask?.cancel()
        missRefreshTask = nil
        routeExpiryTask?.cancel()
        routeExpiryTask = nil
        acceptLoopHealthy = false
        heartbeatHealthy = false
        for task in serveTasks.values {
            task.cancel()
        }
        serveTasks.removeAll()
        serveAuthorizations.removeAll()
        let streamsToClose = Array(serveStreams.values)
        serveStreams.removeAll()

        let transportToStop = transport
        let uid = readyUID
        let connectionID = readyConnectionID

        transport = nil
        readyUID = nil
        readyConnectionID = nil
        policyLoadRequestEpoch &+= 1
        inboundPeerPolicy = IrohInboundPeerPolicy(routeBindings: [])
        lastAuthoritativePolicyLoadAt = nil
        lastAllowlistMissRefreshAt = nil
        let revokedNodeId = publishedIdentity?.nodeId
        publishedIdentity = nil

        let revokeAttempts = revokeRetryAttempts
        let revokeSleep = revokeRetrySleep
        let lifecycleGate = lifecycleGate
        let cleanup = Task { [directory, auditLogger, serveTaskTeardownRegistry] in
            await lifecycleGate.acquire()
            // RR-18 — drain the per-peer teardown index through the same
            // cancel-all path `stop()` already runs over `serveTasks`.
            await serveTaskTeardownRegistry.cancelAll()
            for stream in streamsToClose {
                await stream.close()
            }
            if let transportToStop {
                await transportToStop.shutdown()
            }
            if let uid, let connectionID {
                // Fail-closed teardown: a swallowed revoke would leave the host's
                // `iroh_pairing/*` doc live in Firestore, advertising a NodeId
                // that no longer accepts streams. Retry with backoff, log on
                // give-up.
                await HermesIrohRelayHostClient.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeAttempts,
                    sleep: revokeSleep
                )
                await auditLogger.record(
                    event: .streamClosed,
                    uid: uid,
                    connectionId: connectionID,
                    transport: .irohDirect,
                    rttMillis: nil,
                    detail: revokedNodeId.map { ["nodeId": $0] } ?? [:]
                )
            }
            await lifecycleGate.release()
        }
        teardownTask = cleanup
    }

    private func installAuthStateListener() {
        guard authStateListenerHandle == nil, FirebaseApp.app() != nil else { return }
        authStateListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let authenticatedUID = user?.uid
            Task { @MainActor [weak self] in
                guard let self,
                      Self.shouldStopForAuthenticatedUserChange(
                          readyUID: self.readyUID,
                          authenticatedUID: authenticatedUID
                      ) else { return }
                AppLogger.network.info("hermes_iroh_relay_stopping_after_auth_change")
                self.stop()
            }
        }
    }

    private func acceptLoop(
        transport: any IrohRelayTransport,
        uid: String,
        connectionID: String,
        owner: RuntimeOwner
    ) async {
        var consecutiveAcceptFailures = 0
        while !Task.isCancelled, isCurrentRuntimeOwner(owner) {
            do {
                let stream = try await transport.accept(timeout: 30)
                // A completed accept is acceptor progress no matter how
                // admission turns out, so the recoverable-failure streak
                // resets here rather than after the allowlist decision.
                // Otherwise failures from before this accept survive an
                // allowlist rejection and, once the health-evidence window
                // lapses, combine with later peer-close errors to rebuild a
                // healthy endpoint.
                consecutiveAcceptFailures = 0
                lastAcceptedStreamAt = now()
                guard isCurrentRuntimeOwner(owner), isCurrentTransport(transport) else {
                    await stream.close()
                    return
                }
                var admissionMillis = currentTimeMillis
                var admittedBinding = inboundPeerPolicy.binding(
                    for: stream.remotePeerNodeId,
                    atMillis: admissionMillis
                )
                var isAdmitted = inboundPeerPolicy.allows(
                    remotePeerNodeId: stream.remotePeerNodeId,
                    atMillis: admissionMillis
                )
                if !isAdmitted {
                    isAdmitted = await refreshInboundPeerPolicyAfterMiss(
                       uid: uid,
                       connectionID: connectionID,
                       remotePeerNodeId: stream.remotePeerNodeId
                    )
                    admissionMillis = currentTimeMillis
                    admittedBinding = inboundPeerPolicy.binding(
                        for: stream.remotePeerNodeId,
                        atMillis: admissionMillis
                    )
                    isAdmitted = isAdmitted && inboundPeerPolicy.allows(
                        remotePeerNodeId: stream.remotePeerNodeId,
                        atMillis: admissionMillis
                    )
                }
                guard isCurrentRuntimeOwner(owner), isCurrentTransport(transport) else {
                    await stream.close()
                    return
                }
                if !isAdmitted {
                    // remediation(handshake-before-allowlist DoS amplifier): close
                    // the rejected stream immediately, and only emit the audit
                    // record when this source has not been rejected within the
                    // cooldown window — a non-allowlisted peer that keeps dialing
                    // must not be able to flood the audit log. The allowlist
                    // decision itself is unchanged; this throttles the logging /
                    // bookkeeping of repeat rejections, not the rejection.
                    let shouldAudit = registerAllowlistRejection(
                        remotePeerNodeId: stream.remotePeerNodeId
                    )
                    if shouldAudit {
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
                    }
                    await stream.close()
                    continue
                }
                let handler = IrohRelayRequestHandler(
                    relayKeyStore: relayKeyStore,
                    urlSession: urlSession,
                    settingsManager: settingsManager,
                    mediaDispatcher: mediaDispatcher,
                    mediaControlRegistrar: mediaControlRegistrar,
                    warWireAcceptor: warWireAcceptor,
                    controlDispatcher: controlDispatcher,
                    cliChatDispatcher: cliChatDispatcher,
                    cliModelCatalogDispatcher: cliModelCatalogDispatcher,
                    cliSessionActionDispatcher: cliSessionActionDispatcher,
                    auditLogger: auditLogger
                )
                let serveID = UUID()
                let task = Task { [weak self, auditLogger] in
                    let start = Date()
                    var transferredStreamOwnership = false
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
                        transferredStreamOwnership = disposition == .transferredStreamOwnership
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
                    await self?.releaseServeTask(
                        serveID,
                        retainStreamAuthorization: transferredStreamOwnership
                    )
                }
                serveTasks[serveID] = task
                serveStreams[serveID] = stream
                if let admittedBinding {
                    serveAuthorizations[serveID] = ServeAuthorization(
                        sourceDeviceId: admittedBinding.sourceDeviceId,
                        remotePeerNodeId: admittedBinding.transportNodeId,
                        authorityPeerNodeId: admittedBinding.authorityPeerNodeId,
                        generation: admittedBinding.generation,
                        registeredAtMillis: admittedBinding.registeredAtMillis,
                        expiresAtMillis: admittedBinding.expiresAtMillis
                    )
                    scheduleNextRouteExpiry()
                }
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
                    owner: owner,
                    reason: "shutdown",
                    shouldRestart: !Task.isCancelled
                )
                return
            } catch {
                if Self.isRecoverablePeerAcceptError(error) {
                    consecutiveAcceptFailures += 1
                    AppLogger.network.info(
                        "hermes_iroh_relay_accept_peer_closed connectionID=\(connectionID) consecutiveFailures=\(consecutiveAcceptFailures) errorClass=\(Self.publicErrorClass(error))"
                    )
                    if consecutiveAcceptFailures >= Self.recoverablePeerAcceptFailureLimit {
                        // Peer-close accept errors surface before any identity
                        // or allowlist check, so the counter alone is
                        // peer-manufacturable. Only rebuild when there is no
                        // peer-independent evidence that the acceptor is
                        // healthy; otherwise a hostile dial-and-close burst
                        // would cancel every live serve session and churn the
                        // published NodeId.
                        if hasPeerIndependentEndpointHealthEvidence() {
                            AppLogger.network.info(
                                "hermes_iroh_relay_accept_rebuild_suppressed connectionID=\(connectionID) consecutiveFailures=\(consecutiveAcceptFailures)"
                            )
                        } else {
                            await handleAcceptLoopTerminated(
                                transport: transport,
                                uid: uid,
                                connectionID: connectionID,
                                owner: owner,
                                reason: "peer_accept_failure_limit",
                                shouldRestart: true
                            )
                            return
                        }
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000) // try?-ok(cancellation only)
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
                        owner: owner,
                        reason: Self.publicErrorClass(error),
                        shouldRestart: true
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // try?-ok(cancellation only)
            }
        }
        await handleAcceptLoopTerminated(
            transport: transport,
            uid: uid,
            connectionID: connectionID,
            owner: owner,
            reason: "cancelled",
            shouldRestart: false
        )
    }

    private func releaseServeTask(
        _ id: UUID,
        retainStreamAuthorization: Bool
    ) async {
        serveTasks.removeValue(forKey: id)
        if !retainStreamAuthorization {
            serveStreams.removeValue(forKey: id)
            serveAuthorizations.removeValue(forKey: id)
        }
        scheduleNextRouteExpiry()
        await serveTaskTeardownRegistry.release(serveID: id)
    }

    /// remediation(handshake-before-allowlist DoS amplifier): records an
    /// allowlist rejection for `remotePeerNodeId` and reports whether the
    /// caller should emit an audit record. Returns `true` (audit) the first
    /// time a source is rejected and again only once its cooldown has lapsed;
    /// returns `false` for rapid repeat rejections so a non-allowlisted flooder
    /// cannot spam the audit log. The map is bounded so the flood cannot grow
    /// memory without limit. Runs on `@MainActor` like the rest of the accept
    /// bookkeeping, so no extra synchronization is needed.
    private func registerAllowlistRejection(remotePeerNodeId: String?) -> Bool {
        let key = remotePeerNodeId ?? "unknown"
        let now = Date()
        if let previous = rejectedPeerLastSeen[key],
           now.timeIntervalSince(previous) < Self.rejectedPeerCooldown {
            // Refresh so a sustained flood stays suppressed instead of slipping
            // through once the original window lapses mid-burst.
            rejectedPeerLastSeen[key] = now
            return false
        }
        if rejectedPeerLastSeen[key] == nil,
           rejectedPeerLastSeen.count >= Self.rejectedPeerTableCap,
           let oldest = rejectedPeerLastSeen.min(by: { $0.value < $1.value })?.key {
            rejectedPeerLastSeen.removeValue(forKey: oldest)
        }
        rejectedPeerLastSeen[key] = now
        return true
    }

    func refreshInboundPeerPolicyAfterMiss(
        uid: String,
        connectionID: String,
        remotePeerNodeId: String?
    ) async -> Bool {
        if isInboundPeerAllowed(remotePeerNodeId: remotePeerNodeId) {
            return true
        }
        if let missRefreshTask {
            await missRefreshTask.value
            return isInboundPeerAllowed(remotePeerNodeId: remotePeerNodeId)
        }

        let requestTime = now()
        if let lastAuthoritativePolicyLoadAt,
           requestTime.timeIntervalSince(lastAuthoritativePolicyLoadAt) < missRefreshMinimumPolicyAge {
            return false
        }
        if let lastAllowlistMissRefreshAt,
           requestTime.timeIntervalSince(lastAllowlistMissRefreshAt) < missRefreshBudgetInterval {
            return false
        }
        // Charge the budget before the cloud request starts. Failed requests
        // consume the same budget as successful ones so an unauthenticated
        // source cannot turn callable outages into an unbounded retry loop.
        lastAllowlistMissRefreshAt = requestTime
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshInboundPeerPolicy(uid: uid, connectionID: connectionID)
        }
        missRefreshTask = task
        await task.value
        missRefreshTask = nil
        return isInboundPeerAllowed(remotePeerNodeId: remotePeerNodeId)
    }

    /// Starts one directory request and applies it only if no newer request was
    /// launched while it was suspended. Main-actor serialization alone is not
    /// enough here because actor methods are reentrant across `await`: without
    /// the epoch check, a delayed old success can overwrite a newer empty
    /// response that revoked every route.
    @discardableResult
    func refreshInboundPeerPolicy(uid: String, connectionID: String) async -> Bool {
        policyLoadRequestEpoch &+= 1
        let requestEpoch = policyLoadRequestEpoch
        let result = await inboundPeerPolicyLoader(uid, connectionID)
        guard requestEpoch == policyLoadRequestEpoch,
              readyUID == uid,
              readyConnectionID == connectionID else {
            return false
        }

        switch result {
        case .authoritative(let policy):
            let atMillis = currentTimeMillis
            var invalidatedServeIDs: Set<UUID> = []
            var extendedAuthorizations: [UUID: ServeAuthorization] = [:]
            for (serveID, authorization) in serveAuthorizations {
                guard let currentBinding = policy.binding(
                    for: authorization.remotePeerNodeId,
                    atMillis: atMillis
                ), currentBinding.sourceDeviceId == authorization.sourceDeviceId,
                   currentBinding.authorityPeerNodeId == authorization.authorityPeerNodeId,
                   currentBinding.generation == authorization.generation,
                   currentBinding.registeredAtMillis == authorization.registeredAtMillis,
                   currentBinding.expiresAtMillis >= authorization.expiresAtMillis else {
                    invalidatedServeIDs.insert(serveID)
                    continue
                }
                if currentBinding.expiresAtMillis > authorization.expiresAtMillis {
                    extendedAuthorizations[serveID] = ServeAuthorization(
                        sourceDeviceId: authorization.sourceDeviceId,
                        remotePeerNodeId: authorization.remotePeerNodeId,
                        authorityPeerNodeId: authorization.authorityPeerNodeId,
                        generation: authorization.generation,
                        registeredAtMillis: authorization.registeredAtMillis,
                        expiresAtMillis: currentBinding.expiresAtMillis
                    )
                }
            }
            for (serveID, authorization) in extendedAuthorizations {
                serveAuthorizations[serveID] = authorization
            }
            inboundPeerPolicy = policy
            lastAuthoritativePolicyLoadAt = now()
            let invalidatedPeers = await closeServeTasks(ids: invalidatedServeIDs)
            await purgeStreamsForDeallowlistedPeers(additionallyDisallowedPeerNodeIds: invalidatedPeers)
            scheduleNextRouteExpiry()
            return true
        case .transientFailure:
            // Retain only the last server-verified policy. Its signed route
            // expiries remain authoritative locally and are enforced even when
            // the callable is unavailable.
            await enforceInboundPeerExpiry(atMillis: currentTimeMillis)
            return false
        }
    }

    func isInboundPeerAllowed(remotePeerNodeId: String?, atMillis: Int64? = nil) -> Bool {
        inboundPeerPolicy.allows(
            remotePeerNodeId: remotePeerNodeId,
            atMillis: atMillis ?? currentTimeMillis
        )
    }

    var activeAuthorizedStreamCount: Int {
        serveAuthorizations.count
    }

    /// Exact local expiry enforcement for already-established privileged
    /// streams. The timer calls this at the earliest active lease expiry; the
    /// internal surface also makes clock-driven tests deterministic.
    func enforceInboundPeerExpiry(atMillis: Int64) async {
        let expiredServeIDs = Set(serveAuthorizations.compactMap { serveID, authorization in
            authorization.expiresAtMillis <= atMillis ? serveID : nil
        })
        let expiredPeers = await closeServeTasks(ids: expiredServeIDs)
        if !expiredPeers.isEmpty {
            await purgeMediaControlStreams(disallowing: expiredPeers)
        }
        scheduleNextRouteExpiry()
    }

    private var currentTimeMillis: Int64 {
        Int64(now().timeIntervalSince1970 * 1_000)
    }

    private func scheduleNextRouteExpiry() {
        routeExpiryTask?.cancel()
        routeExpiryTask = nil
        guard let expiresAtMillis = serveAuthorizations.values.map(\.expiresAtMillis).min() else {
            return
        }
        let delayMillis = max(0, expiresAtMillis - currentTimeMillis)
        routeExpiryTask = Task<Void, Never> { @MainActor [weak self] in
            if delayMillis > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delayMillis) * 1_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.enforceInboundPeerExpiry(atMillis: expiresAtMillis)
        }
    }

    private func closeServeTasks(ids: Set<UUID>) async -> Set<String> {
        var peerNodeIds = Set<String>()
        for serveID in ids {
            if let authorization = serveAuthorizations.removeValue(forKey: serveID) {
                peerNodeIds.insert(authorization.remotePeerNodeId)
            }
            serveTasks.removeValue(forKey: serveID)?.cancel()
            if let stream = serveStreams.removeValue(forKey: serveID) {
                await stream.close()
            }
            await serveTaskTeardownRegistry.release(serveID: serveID)
        }
        return peerNodeIds
    }

    private func purgeMediaControlStreams(disallowing peerNodeIds: Set<String>) async {
        guard let registry = mediaControlStreamRegistry else { return }
        let isAllowed: MediaInboundPeerAllowChecker = { remotePeerNodeId in
            guard let remotePeerNodeId,
                  let canonical = IrohNodeIdNormalization.canonicalTransportNodeId(remotePeerNodeId) else {
                return false
            }
            return !peerNodeIds.contains(canonical)
        }
        _ = await registry.purgeStreamsNotAllowed(by: isAllowed)
    }

    /// RR-18 — tear down any serve task or persistent media-control stream whose
    /// remote peer is no longer in the freshly-refreshed inbound allowlist.
    /// Called from the heartbeat right after `inboundPeerPolicy` is reloaded, so
    /// a peer that is de-allowlisted or revoked mid-stream loses its live lanes
    /// within one heartbeat instead of keeping them until natural close. The
    /// allow-checker captures the policy by value (it is `Sendable`), so the
    /// actor registries never reach back into `@MainActor` state.
    private func purgeStreamsForDeallowlistedPeers(
        additionallyDisallowedPeerNodeIds: Set<String> = []
    ) async {
        let policy = inboundPeerPolicy
        let atMillis = currentTimeMillis
        let isAllowed: MediaInboundPeerAllowChecker = { remotePeerNodeId in
            guard let remotePeerNodeId,
                  let canonical = IrohNodeIdNormalization.canonicalTransportNodeId(remotePeerNodeId),
                  !additionallyDisallowedPeerNodeIds.contains(canonical) else {
                return false
            }
            return policy.allows(remotePeerNodeId: canonical, atMillis: atMillis)
        }
        let cancelledServeIDs = await serveTaskTeardownRegistry.cancelTasks(notAllowedBy: isAllowed)
        for serveID in cancelledServeIDs {
            serveTasks.removeValue(forKey: serveID)
            serveAuthorizations.removeValue(forKey: serveID)
            if let stream = serveStreams.removeValue(forKey: serveID) {
                await stream.close()
            }
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
        scheduleNextRouteExpiry()
    }

    private func refreshPairingRecord(
        uid: String,
        connectionID: String,
        owner: RuntimeOwner
    ) async -> Bool {
        guard isCurrentRuntimeOwner(owner),
              owner.uid == uid,
              owner.connectionID == connectionID,
              relayRuntimeHealthy,
              let identity = publishedIdentity else { return false }
        await lifecycleGate.acquire()
        guard isCurrentRuntimeOwner(owner),
              relayRuntimeHealthy,
              publishedIdentity == identity else {
            await lifecycleGate.release()
            return false
        }

        var pairingPublicationAttempted = false
        do {
            let pairingKeypair = try pairingKeyStore.keypair()
            try await publicKeyPublisher.publish(
                uid: uid,
                deviceId: accountManager.deviceId,
                publicKeyBase64: pairingKeypair.publicKeyBase64
            )
            guard isCurrentRuntimeOwner(owner),
                  relayRuntimeHealthy,
                  publishedIdentity == identity else {
                await Self.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeRetryAttempts,
                    sleep: revokeRetrySleep
                )
                await lifecycleGate.release()
                return false
            }
            let publisher = IrohPairingPublisher(directory: directory)
            pairingPublicationAttempted = true
            _ = try await publisher.publish(
                uid: uid,
                connectionId: connectionID,
                nodeId: identity.nodeId,
                relayURL: identity.relayURL,
                directAddresses: identity.directAddresses,
                with: pairingKeypair
            )
            guard isCurrentRuntimeOwner(owner),
                  relayRuntimeHealthy,
                  publishedIdentity == identity else {
                await Self.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeRetryAttempts,
                    sleep: revokeRetrySleep
                )
                await lifecycleGate.release()
                return false
            }
        } catch {
            if pairingPublicationAttempted {
                await Self.revokePairingRecord(
                    directory: directory,
                    uid: uid,
                    connectionID: connectionID,
                    attempts: revokeRetryAttempts,
                    sleep: revokeRetrySleep
                )
            }
            AppLogger.network.silentFailure("hermes_iroh_relay_pairing_refresh_failed", error: error)
            let mustFailClosed = pairingPublicationAttempted && isCurrentRuntimeOwner(owner)
            await lifecycleGate.release()
            if mustFailClosed {
                stop()
                return false
            }
            return isCurrentRuntimeOwner(owner) && relayRuntimeHealthy
        }
        await lifecycleGate.release()
        return isCurrentRuntimeOwner(owner) && relayRuntimeHealthy
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

    private func isCurrentRuntimeOwner(_ owner: RuntimeOwner) -> Bool {
        desiredRuntimeOwner == owner
    }

    private func handleAcceptLoopTerminated(
        transport failedTransport: any IrohRelayTransport,
        uid: String,
        connectionID: String,
        owner: RuntimeOwner,
        reason: String,
        shouldRestart: Bool
    ) async {
        await lifecycleGate.acquire()
        guard isCurrentRuntimeOwner(owner), isCurrentTransport(failedTransport) else {
            await lifecycleGate.release()
            return
        }

        let transportToStop = transport
        let revokedNodeId = publishedIdentity?.nodeId

        acceptLoopHealthy = false
        heartbeatHealthy = false
        acceptTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        missRefreshTask?.cancel()
        missRefreshTask = nil
        routeExpiryTask?.cancel()
        routeExpiryTask = nil
        for task in serveTasks.values {
            task.cancel()
        }
        serveTasks.removeAll()
        serveAuthorizations.removeAll()
        let streamsToClose = Array(serveStreams.values)
        serveStreams.removeAll()
        // RR-18 — same cancel-all teardown for the per-peer index.
        await serveTaskTeardownRegistry.cancelAll()
        for stream in streamsToClose {
            await stream.close()
        }
        self.transport = nil
        readyUID = nil
        readyConnectionID = nil
        policyLoadRequestEpoch &+= 1
        inboundPeerPolicy = IrohInboundPeerPolicy(routeBindings: [])
        lastAuthoritativePolicyLoadAt = nil
        lastAllowlistMissRefreshAt = nil
        publishedIdentity = nil
        lastAcceptedStreamAt = nil

        if let transportToStop {
            await transportToStop.shutdown()
        }
        // Fail-closed teardown after an accept-loop failure: revoke with retry so
        // a transient directory fault cannot leave the host advertising a NodeId
        // whose accept loop has already torn down. If `shouldRestart` is true the
        // recovery `start()` below re-publishes a fresh record; if it is false
        // (cancelled / not recoverable) this is the only revoke, and swallowing
        // it would strand a live pairing doc for a host that is gone.
        await Self.revokePairingRecord(
            directory: directory,
            uid: uid,
            connectionID: connectionID,
            attempts: revokeRetryAttempts,
            sleep: revokeRetrySleep
        )
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

        guard shouldRestart, isCurrentRuntimeOwner(owner) else {
            desiredRuntimeOwner = nil
            await lifecycleGate.release()
            return
        }
        await lifecycleGate.release()
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000) // try?-ok(cancellation only)
            guard !Task.isCancelled,
                  let self,
                  self.isCurrentRuntimeOwner(owner) else { return }
            _ = await self.start(uid: uid, connectionID: connectionID)
        }
    }

    static func shouldRebuildAfterAcceptError(_ error: Error) -> Bool {
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
        case .backendUnavailable, .nodeIdUnreachable, .protocolMismatch, .timedOut:
            return false
        }
    }

    /// Endpoint-health evidence a remote peer cannot manufacture. Active serve
    /// sessions only exist for allowlisted peers that completed admission, and
    /// `lastAcceptedStreamAt` is only set when the native acceptor hands Swift
    /// a fully accepted stream; an attacker that completes ALPN and closes
    /// before opening a bidirectional stream produces neither. While either
    /// signal is present, a run of pre-identity peer-close accept errors is
    /// peer behavior, not a stalled endpoint, and must not tear the host down.
    ///
    /// `serveStreams` counts alongside `serveTasks`: long-lived `media.control`
    /// streams transfer ownership out of their serve task
    /// (`transferredStreamOwnership`), after which `releaseServeTask` drops the
    /// task but deliberately retains the live stream. An active mirror or call
    /// therefore holds evidence only in `serveStreams`; ignoring it would let
    /// any reachable peer manufacture pre-identity close errors that tear down
    /// the retained stream mid-session. Retained entries are bounded: route
    /// expiry, de-allowlist purges, and `stop()` all remove them.
    private func hasPeerIndependentEndpointHealthEvidence() -> Bool {
        Self.hasPeerIndependentEndpointHealthEvidence(
            activeServeTaskCount: serveTasks.count,
            retainedServeStreamCount: serveStreams.count,
            lastAcceptedStreamAt: lastAcceptedStreamAt,
            now: now()
        )
    }

    static func hasPeerIndependentEndpointHealthEvidence(
        activeServeTaskCount: Int,
        retainedServeStreamCount: Int,
        lastAcceptedStreamAt: Date?,
        now: Date
    ) -> Bool {
        if activeServeTaskCount > 0 || retainedServeStreamCount > 0 { return true }
        if let lastAcceptedStreamAt,
           now.timeIntervalSince(lastAcceptedStreamAt) < Self.peerAcceptHealthEvidenceWindow {
            return true
        }
        return false
    }

    static func isRecoverablePeerAcceptError(_ error: Error) -> Bool {
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
        case .backendUnavailable, .endpointNotReady, .nodeIdUnreachable, .protocolMismatch, .shutdown:
            return false
        }
    }

    /// Default transport: prefers the xcframework-backed UniFFI backend when
    /// the `OpenBurnBarIrohFFI` module is linked. A build without that optional
    /// module fails fast so callers do not advertise a process-local loopback
    /// peer to physical devices.
    static func defaultTransport(
        backendFactory: @Sendable () -> IrohEndpointBackend? = {
            OpenBurnBarIrohFFIBackendFactory.make()
        }
    ) -> any IrohRelayTransport {
        let secretProvider: @Sendable () throws -> IrohSecretKeyMaterial = {
            // Persist the iroh secret key alongside the existing relay
            // keypair so deleting the app removes both. Real implementation
            // is added by `IrohRelayKeyStore` in this directory.
            try IrohRelayKeyStore.shared.secretKeyMaterial()
        }
        if let backend = backendFactory() {
            return IrohXcframeworkTransport(
                backend: backend,
                secretProvider: secretProvider,
                relayURLProvider: {
                    HermesIrohHostedRelayConfig.currentURL()
                }
            )
        }
        // No native iroh module in this build. Every Mercury surface (mirror,
        // calls, file transfer) is dead for the life of the process — but the
        // Mac still publishes `status: online` from its healthy chat gateway,
        // so nothing downstream looks broken. That is exactly how a build
        // shipped on 2026-07-28 with `canImport(OpenBurnBarIrohFFI)` false:
        // it degraded silently and the only symptom was a Mercury tile that
        // never appeared, eight days later.
        //
        // Say so once, loudly, at the point of degradation. `assertionFailure`
        // stops a dev/QA build immediately; release builds get an error-level
        // log that names the cause instead of the downstream `backendUnavailable`
        // throw, which reads like a runtime fault rather than a packaging one.
        AppLogger.network.error(
            "hermes_iroh_native_backend_missing detail=OpenBurnBarIrohFFI_not_linked_Mercury_disabled_check_Vendor_OpenBurnBarIroh.xcframework"
        )
        // The unit suite exercises this exact path with an injected nil
        // factory (HermesIrohRelayHostClientMattersTests) to pin the graceful
        // `.backendUnavailable` contract, so the trap must not fire under
        // XCTest — only in a real dev/QA app launch.
        if !OpenBurnBarRuntime.isRunningTests {
            assertionFailure(
                "Hermes iroh host has no native backend: OpenBurnBarIrohFFI is not linked. Mercury mirror/calls/file-transfer are disabled for this whole process. Build/link Vendor/OpenBurnBarIroh.xcframework."
            )
        }
        return UnavailableIrohRelayTransport()
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

    private final class ContinuationGate: Sendable {
        // `CheckedContinuation` is not `Sendable`, so the once-only flag and the
        // continuation share a single unfair-lock-protected `State`. Resuming
        // inside the lock keeps the resume-exactly-once guarantee the prior
        // `NSLock` version provided.
        private struct State {
            var didResume = false
            let continuation: CheckedContinuation<Void, Never>
        }

        private let state: OSAllocatedUnfairLock<State>

        init(_ continuation: CheckedContinuation<Void, Never>) {
            state = OSAllocatedUnfairLock(uncheckedState: State(continuation: continuation))
        }

        func resume() {
            state.withLockUnchecked { state in
                guard !state.didResume else { return }
                state.didResume = true
                state.continuation.resume()
            }
        }
    }
}

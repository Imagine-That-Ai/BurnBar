import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay

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
    private let transportFactory: @MainActor (HermesIrohRelayHostClient) -> any IrohRelayTransport
    private let urlSession: URLSession
    private let auditLogger: any IrohTransportAuditLogging
    private var transport: (any IrohRelayTransport)?
    private var acceptTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var readyUID: String?
    private var readyConnectionID: String?
    private var publishedNodeId: String?
    private let pairingPublishInterval: TimeInterval

    init(
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        relayKeyStore: HermesRelayKeyStore = HermesRelayKeyStore(),
        pairingKeyStore: IrohPairingKeyStore = IrohPairingKeyStore(),
        directory: any IrohPairingDirectory = FirestoreIrohPairingDirectory.shared,
        auditLogger: any IrohTransportAuditLogging = FirestoreIrohAuditLogger.shared,
        urlSession: URLSession = .shared,
        pairingPublishInterval: TimeInterval = 15 * 60,
        transportFactory: @escaping @MainActor (HermesIrohRelayHostClient) -> any IrohRelayTransport = { _ in
            HermesIrohRelayHostClient.defaultTransport()
        }
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.relayKeyStore = relayKeyStore
        self.pairingKeyStore = pairingKeyStore
        self.directory = directory
        self.auditLogger = auditLogger
        self.urlSession = urlSession
        self.pairingPublishInterval = pairingPublishInterval
        self.transportFactory = transportFactory
    }

    var isReady: Bool {
        transport != nil && readyConnectionID != nil
    }

    /// We never advertise the iroh transport as a publishable WSS URL. iOS
    /// discovers the iroh NodeId through the Firestore pairing record.
    var publishableRelayURLString: String? { nil }

    @discardableResult
    func start(uid: String, connectionID: String) async -> Bool {
        if transport != nil, readyUID == uid, readyConnectionID == connectionID {
            return true
        }
        stop()
        guard settingsManager.hermesIrohTransportEnabled else { return false }

        let newTransport = transportFactory(self)
        do {
            let identity = try await newTransport.start()
            transport = newTransport
            publishedNodeId = identity.nodeId

            let pairingKeypair = try pairingKeyStore.keypair()
            let publisher = IrohPairingPublisher(directory: directory)
            _ = try await publisher.publish(
                uid: uid,
                connectionId: connectionID,
                nodeId: identity.nodeId,
                with: pairingKeypair
            )
            await auditLogger.record(
                event: .pairingPublished,
                uid: uid,
                connectionId: connectionID,
                transport: nil,
                rttMillis: nil,
                detail: ["nodeId": identity.nodeId]
            )

            readyUID = uid
            readyConnectionID = connectionID

            acceptTask = Task { [weak self] in
                await self?.acceptLoop(transport: newTransport, uid: uid, connectionID: connectionID)
            }
            heartbeatTask = Task { [weak self, pairingPublishInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(pairingPublishInterval * 1_000_000_000))
                    await self?.refreshPairingRecord(uid: uid, connectionID: connectionID)
                }
            }
            return true
        } catch {
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

        let transportToStop = transport
        let uid = readyUID
        let connectionID = readyConnectionID

        transport = nil
        readyUID = nil
        readyConnectionID = nil
        let revokedNodeId = publishedNodeId
        publishedNodeId = nil

        Task { [directory, auditLogger] in
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
        while !Task.isCancelled {
            do {
                let stream = try await transport.accept(timeout: 30)
                let handler = IrohRelayRequestHandler(
                    relayKeyStore: relayKeyStore,
                    urlSession: urlSession,
                    settingsManager: settingsManager
                )
                Task { [auditLogger] in
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
                        try await handler.serve(
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
                            detail: [:]
                        )
                    } catch {
                        await auditLogger.record(
                            event: .streamFailed,
                            uid: uid,
                            connectionId: connectionID,
                            transport: .irohDirect,
                            rttMillis: nil,
                            detail: ["error": String(error.localizedDescription.prefix(256))]
                        )
                    }
                    await stream.close()
                }
            } catch IrohRelayTransportError.timedOut {
                continue
            } catch IrohRelayTransportError.shutdown {
                return
            } catch {
                AppLogger.network.silentFailure("hermes_iroh_relay_accept_failed", error: error)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refreshPairingRecord(uid: String, connectionID: String) async {
        guard let nodeId = publishedNodeId else { return }
        do {
            let pairingKeypair = try pairingKeyStore.keypair()
            let publisher = IrohPairingPublisher(directory: directory)
            _ = try await publisher.publish(
                uid: uid,
                connectionId: connectionID,
                nodeId: nodeId,
                with: pairingKeypair
            )
        } catch {
            AppLogger.network.silentFailure("hermes_iroh_relay_pairing_refresh_failed", error: error)
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
            return IrohXcframeworkTransport(backend: backend, secretProvider: secretProvider)
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

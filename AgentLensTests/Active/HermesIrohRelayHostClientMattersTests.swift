import XCTest
import OpenBurnBarCore
import OpenBurnBarIrohRelay
@testable import OpenBurnBar

/// Focused security and lifecycle coverage for `HermesIrohRelayHostClient`:
///
/// - stale directory responses cannot undo a newer authoritative revoke;
/// - transient callable failures retain only unexpired verified routes;
/// - established serve and transferred media-control streams close at route
///   expiry or generation replacement;
/// - unauthenticated misses share one bounded discovery refresh;
/// - `stop()` and `handleAcceptLoopTerminated` each previously
///   tore down the host and called `try? await directory.revoke(...)`. A
///   swallowed revoke leaves the host's `iroh_pairing/*` doc live in Firestore,
///   advertising a NodeId that no longer accepts streams — a fail-OPEN: a peer
///   keeps dialing a torn-down host, and the directory diverges from liveness.
///
/// The fix routes both call sites through `revokePairingRecord(...)`, which
/// retries with backoff (so a transient fault still converges to a clean
/// revoke) and logs loudly if every attempt fails (so the divergence is at
/// least observable instead of silently swallowed).
///
/// The tests use injected loaders, clocks, transports, and sleep seams so the
/// concurrency and expiry contracts remain deterministic.
final class HermesIrohRelayHostClientMattersTests: XCTestCase {
    private let uid = "uid-revoke"
    private let connectionID = "connection-revoke"

    func test_authChangeStopsOnlyAnActiveHostOwnedByAnotherUser() {
        XCTAssertFalse(HermesIrohRelayHostClient.shouldStopForAuthenticatedUserChange(
            readyUID: nil,
            authenticatedUID: "uid-a"
        ))
        XCTAssertFalse(HermesIrohRelayHostClient.shouldStopForAuthenticatedUserChange(
            readyUID: "uid-a",
            authenticatedUID: "uid-a"
        ))
        XCTAssertTrue(HermesIrohRelayHostClient.shouldStopForAuthenticatedUserChange(
            readyUID: "uid-a",
            authenticatedUID: "uid-b"
        ))
        XCTAssertTrue(HermesIrohRelayHostClient.shouldStopForAuthenticatedUserChange(
            readyUID: "uid-a",
            authenticatedUID: nil
        ))
    }

    @MainActor
    func test_allowlistMissRefreshesOnceAndAdmitsNewServerRoute() async throws {
        let nodeId = String(repeating: "a", count: 64)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1_000)
        let binding = try XCTUnwrap(IrohControllerRouteBinding(
            sourceDeviceId: "ios-device-1",
            transportNodeId: nodeId,
            authorityPeerNodeId: "ios-authority-1",
            generation: 1,
            registeredAtMillis: nowMillis - 1_000,
            expiresAtMillis: nowMillis + 60_000
        ))
        let loader = SequencedInboundPolicyLoader(policies: [
            IrohInboundPeerPolicy(routeBindings: []),
            IrohInboundPeerPolicy(routeBindings: [binding])
        ])
        let client = makeClient(
            directory: InMemoryIrohPairingDirectory(),
            inboundPeerPolicyLoader: { uid, connectionID in
                .authoritative(await loader.load(uid: uid, connectionID: connectionID))
            },
            missRefreshMinimumPolicyAge: 0
        )

        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)
        let admittedAfterRefresh = await client.refreshInboundPeerPolicyAfterMiss(
            uid: uid,
            connectionID: connectionID,
            remotePeerNodeId: nodeId
        )
        XCTAssertTrue(admittedAfterRefresh)
        let secondMissAdmitted = await client.refreshInboundPeerPolicyAfterMiss(
            uid: uid,
            connectionID: connectionID,
            remotePeerNodeId: String(repeating: "b", count: 64)
        )
        XCTAssertFalse(secondMissAdmitted)
        let loadCallCount = await loader.callCount
        XCTAssertEqual(loadCallCount, 2)
        client.stop()
    }

    @MainActor
    func test_delayedOlderSuccessCannotOverwriteNewerAuthoritativeRevoke() async throws {
        let nodeId = String(repeating: "a", count: 64)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1_000)
        let allowed = IrohInboundPeerPolicy(routeBindings: [try makeBinding(
            nodeId: nodeId,
            generation: 1,
            registeredAtMillis: nowMillis - 1_000,
            expiresAtMillis: nowMillis + 60_000
        )])
        let loader = ControlledInboundPolicyLoader(immediate: [
            0: .authoritative(allowed),
            2: .authoritative(IrohInboundPeerPolicy(routeBindings: []))
        ])
        let client = makeClient(
            directory: InMemoryIrohPairingDirectory(),
            inboundPeerPolicyLoader: { uid, connectionID in
                await loader.load(uid: uid, connectionID: connectionID)
            }
        )
        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)

        async let delayedOld = client.refreshInboundPeerPolicy(uid: uid, connectionID: connectionID)
        try await waitUntil { await loader.callCount == 2 }
        async let newerRevoke = client.refreshInboundPeerPolicy(uid: uid, connectionID: connectionID)
        let didApplyRevoke = await newerRevoke
        XCTAssertTrue(didApplyRevoke)
        await loader.resolve(callIndex: 1, with: .authoritative(allowed))
        let didApplyDelayedOld = await delayedOld
        XCTAssertFalse(didApplyDelayedOld, "Superseded response must not be applied")
        XCTAssertFalse(client.isInboundPeerAllowed(remotePeerNodeId: nodeId))
        client.stop()
    }

    @MainActor
    func test_transientFailureRetainsVerifiedPolicyOnlyUntilSignedExpiry() async throws {
        let clock = LockedHostTestClock(date: Date(timeIntervalSince1970: 10))
        let nodeId = String(repeating: "b", count: 64)
        let policy = IrohInboundPeerPolicy(routeBindings: [try makeBinding(
            nodeId: nodeId,
            generation: 4,
            registeredAtMillis: 9_000,
            expiresAtMillis: 11_000
        )])
        let loader = ControlledInboundPolicyLoader(immediate: [
            0: .authoritative(policy),
            1: .transientFailure
        ])
        let client = makeClient(
            directory: InMemoryIrohPairingDirectory(),
            inboundPeerPolicyLoader: { uid, connectionID in
                await loader.load(uid: uid, connectionID: connectionID)
            },
            now: { clock.now }
        )
        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)

        clock.set(Date(timeIntervalSince1970: 10.5))
        let didApplyTransientFailure = await client.refreshInboundPeerPolicy(uid: uid, connectionID: connectionID)
        XCTAssertFalse(didApplyTransientFailure)
        XCTAssertTrue(client.isInboundPeerAllowed(remotePeerNodeId: nodeId, atMillis: 10_999))
        XCTAssertFalse(client.isInboundPeerAllowed(remotePeerNodeId: nodeId, atMillis: 11_000))
        client.stop()
    }

    @MainActor
    func test_establishedStreamClosesAtExactRouteExpiry() async throws {
        let nodeId = String(repeating: "c", count: 64)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1_000)
        let stream = BlockingHostTestStream(
            remotePeerNodeId: nodeId,
            frames: [
                HermesRealtimeRelayFrame(
                    type: .mediaClassify,
                    uid: uid,
                    connectionId: connectionID,
                    media: HermesRealtimeRelayMediaPayload(streamClass: "media.control")
                )
            ]
        )
        let transport = SingleInboundStreamTransport(stream: stream)
        let registrar = HostMediaControlRegistrarRecorder()
        let policy = IrohInboundPeerPolicy(routeBindings: [try makeBinding(
            nodeId: nodeId,
            generation: 7,
            registeredAtMillis: nowMillis - 1_000,
            expiresAtMillis: nowMillis + 60_000
        )])
        let client = makeClient(
            directory: InMemoryIrohPairingDirectory(),
            inboundPeerPolicyLoader: { _, _ in .authoritative(policy) },
            transportFactory: { _ in transport }
        )
        client.mediaControlRegistrar = { stream, uid, connectionID in
            await registrar.record(stream: stream, uid: uid, connectionID: connectionID)
        }
        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)
        try await waitUntil { await registrar.registrationCount == 1 }
        try await waitUntil { client.activeAuthorizedStreamCount == 1 }

        await client.enforceInboundPeerExpiry(atMillis: nowMillis + 60_000)
        try await waitUntil { await stream.isClosed }
        client.stop()
    }

    @MainActor
    func test_generationReplacementClosesStreamAuthorizedByOldGeneration() async throws {
        let nodeId = String(repeating: "d", count: 64)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1_000)
        let oldPolicy = IrohInboundPeerPolicy(routeBindings: [try makeBinding(
            nodeId: nodeId,
            generation: 1,
            registeredAtMillis: nowMillis - 1_000,
            expiresAtMillis: nowMillis + 60_000
        )])
        let replacementPolicy = IrohInboundPeerPolicy(routeBindings: [try makeBinding(
            nodeId: nodeId,
            generation: 2,
            registeredAtMillis: nowMillis,
            expiresAtMillis: nowMillis + 120_000
        )])
        let loader = ControlledInboundPolicyLoader(immediate: [
            0: .authoritative(oldPolicy),
            1: .authoritative(replacementPolicy)
        ])
        let stream = BlockingHostTestStream(remotePeerNodeId: nodeId)
        let transport = SingleInboundStreamTransport(stream: stream)
        let client = makeClient(
            directory: InMemoryIrohPairingDirectory(),
            inboundPeerPolicyLoader: { uid, connectionID in
                await loader.load(uid: uid, connectionID: connectionID)
            },
            transportFactory: { _ in transport }
        )
        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)
        try await waitUntil { client.activeAuthorizedStreamCount == 1 }

        let didApplyReplacement = await client.refreshInboundPeerPolicy(uid: uid, connectionID: connectionID)
        XCTAssertTrue(didApplyReplacement)
        try await waitUntil { await stream.isClosed }
        XCTAssertTrue(client.isInboundPeerAllowed(remotePeerNodeId: nodeId))
        client.stop()
    }

    @MainActor
    func test_missRefreshCoalescesConcurrentCallersAndChargesRateBudget() async throws {
        let clock = LockedHostTestClock(date: Date(timeIntervalSince1970: 20))
        let nodeId = String(repeating: "e", count: 64)
        let policy = IrohInboundPeerPolicy(routeBindings: [try makeBinding(
            nodeId: nodeId,
            generation: 1,
            registeredAtMillis: 19_000,
            expiresAtMillis: 80_000
        )])
        let loader = ControlledInboundPolicyLoader(immediate: [
            0: .authoritative(IrohInboundPeerPolicy(routeBindings: []))
        ])
        let client = makeClient(
            directory: InMemoryIrohPairingDirectory(),
            inboundPeerPolicyLoader: { uid, connectionID in
                await loader.load(uid: uid, connectionID: connectionID)
            },
            now: { clock.now },
            missRefreshMinimumPolicyAge: 0,
            missRefreshBudgetInterval: 30
        )
        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)

        async let first = client.refreshInboundPeerPolicyAfterMiss(
            uid: uid,
            connectionID: connectionID,
            remotePeerNodeId: nodeId
        )
        async let second = client.refreshInboundPeerPolicyAfterMiss(
            uid: uid,
            connectionID: connectionID,
            remotePeerNodeId: nodeId
        )
        try await waitUntil { await loader.callCount == 2 }
        await loader.resolve(callIndex: 1, with: .authoritative(policy))
        let firstAdmitted = await first
        let secondAdmitted = await second
        XCTAssertTrue(firstAdmitted)
        XCTAssertTrue(secondAdmitted)
        let callsAfterCoalescing = await loader.callCount
        XCTAssertEqual(callsAfterCoalescing, 2, "Concurrent misses must share one callable load")

        let rejectedWithinBudget = await client.refreshInboundPeerPolicyAfterMiss(
            uid: uid,
            connectionID: connectionID,
            remotePeerNodeId: String(repeating: "f", count: 64)
        )
        XCTAssertFalse(rejectedWithinBudget)
        let callsAfterBudgetedMiss = await loader.callCount
        XCTAssertEqual(callsAfterBudgetedMiss, 2, "Miss budget must suppress repeated cloud loads")
        client.stop()
    }

    // MARK: - revokePairingRecord retry contract

    /// A transient directory fault must NOT strand a live pairing record: the
    /// revoke is retried and, once it succeeds, the record is gone. The previous
    /// bare `try?` would have given up after the first throw, leaving the host
    /// advertised.
    func test_revoke_retriesUntilSuccess_recordIsRemoved() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: 2)
        try await directory.publish(makeRecord(), for: uid)

        let collector = SleepCollector()
        let removed = await HermesIrohRelayHostClient.revokePairingRecord(
            directory: directory,
            uid: uid,
            connectionID: connectionID,
            attempts: 3,
            sleep: { await collector.record($0) }
        )

        XCTAssertTrue(removed)
        let revokeAttempts = await directory.revokeAttemptCount
        XCTAssertEqual(revokeAttempts, 3, "Two failures then a success = three attempts")
        let stored = try await directory.fetch(uid: uid, connectionId: connectionID)
        XCTAssertNil(stored, "A recovered revoke must leave NO live pairing record")
        // Backoff slept exactly once per failed attempt (two failures here).
        let slept = await collector.intervals
        XCTAssertEqual(slept.count, 2)
    }

    /// When every attempt fails the record may genuinely still be live, so the
    /// helper must report failure (fail-loud) rather than pretend success. It
    /// must also stop after exactly `attempts` tries — no unbounded loop — and
    /// it must NOT sleep after the final attempt.
    func test_revoke_givesUpAfterAttempts_reportsFailure_noTrailingSleep() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: .max)
        try await directory.publish(makeRecord(), for: uid)

        let collector = SleepCollector()
        let removed = await HermesIrohRelayHostClient.revokePairingRecord(
            directory: directory,
            uid: uid,
            connectionID: connectionID,
            attempts: 3,
            sleep: { await collector.record($0) }
        )

        XCTAssertFalse(removed, "Persistent failure must be reported, never masked as success")
        let revokeAttempts = await directory.revokeAttemptCount
        XCTAssertEqual(revokeAttempts, 3, "Exactly `attempts` tries, then give up")
        // N attempts => N-1 backoff sleeps (no sleep after the terminal attempt).
        let slept = await collector.intervals
        XCTAssertEqual(slept.count, 2)
    }

    /// `attempts` is clamped to at least one — a misconfigured zero/negative
    /// must still try once rather than silently skip the revoke entirely.
    func test_revoke_attemptsClampedToAtLeastOne() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: .max)
        try await directory.publish(makeRecord(), for: uid)

        _ = await HermesIrohRelayHostClient.revokePairingRecord(
            directory: directory,
            uid: uid,
            connectionID: connectionID,
            attempts: 0,
            sleep: { _ in }
        )

        let revokeAttempts = await directory.revokeAttemptCount
        XCTAssertEqual(revokeAttempts, 1)
    }

    /// A read-only directory legitimately has nothing to revoke. That benign
    /// `unsupportedOnReader` case must short-circuit as success without burning
    /// retries or escalating to an error.
    func test_revoke_unsupportedOnReader_isBenignNoRetry() async throws {
        let directory = ReaderOnlyDirectory()

        let removed = await HermesIrohRelayHostClient.revokePairingRecord(
            directory: directory,
            uid: uid,
            connectionID: connectionID,
            attempts: 3,
            sleep: { _ in XCTFail("unsupportedOnReader must not trigger a backoff sleep") }
        )

        XCTAssertTrue(removed)
        let revokeAttempts = await directory.revokeAttemptCount
        XCTAssertEqual(revokeAttempts, 1, "Reader rejection is terminal — no retry")
    }

    // MARK: - End-to-end teardown contract

    /// `stop()` must revoke the published pairing record. With a directory that
    /// faults once then succeeds, the retry path inside the detached teardown
    /// Task must still drive the record to removal — proving the L270 site no
    /// longer fails open.
    @MainActor
    func test_stop_revokesPairingRecord_evenThroughTransientFault() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: 1)
        let client = makeClient(directory: directory)

        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)
        let published = try await directory.fetch(uid: uid, connectionId: connectionID)
        XCTAssertNotNil(published, "start() must publish a pairing record")

        client.stop()

        try await waitUntil(timeout: 3) {
            let record = try await directory.fetch(uid: self.uid, connectionId: self.connectionID)
            return record == nil
        }
        let revokeAttempts = await directory.revokeAttemptCount
        XCTAssertGreaterThanOrEqual(revokeAttempts, 2, "One fault then a successful retry")
    }

    /// When the accept loop self-terminates (transport `.shutdown`) while the
    /// transport is still current, `handleAcceptLoopTerminated` runs the L519
    /// revoke before the recovery `start()` re-publishes. Driven through a
    /// one-fault directory, the revoke must still go through the retry helper
    /// (so a transient fault doesn't strand the OLD record) and the host must
    /// re-publish a fresh record on the restart.
    @MainActor
    func test_acceptLoopTermination_revokesThroughRetry_thenRepublishes() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: 1)
        // First transport throws `.shutdown` on accept → handleAcceptLoopTerminated
        // (L519) with shouldRestart == true. Second transport parks → the restart
        // brings the host back up and re-publishes under a new node id.
        let failing = StubIrohRelayTransport(nodeId: "node-first", acceptBehavior: .shutdownImmediately)
        let parking = StubIrohRelayTransport(nodeId: "node-second", acceptBehavior: .park)
        var transports: [StubIrohRelayTransport] = [failing, parking]
        let client = makeClient(
            directory: directory,
            transportFactory: { _ in transports.removeFirst() }
        )

        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)

        // The accept-loop termination revokes (one fault + a successful retry),
        // then the recovery start() re-publishes under the second node id.
        try await waitUntil(timeout: 4) {
            let record = try await directory.fetch(uid: self.uid, connectionId: self.connectionID)
            return record?.nodeId == "node-second"
        }
        let revokeAttempts = await directory.revokeAttemptCount
        XCTAssertGreaterThanOrEqual(
            revokeAttempts,
            2,
            "L519 revoke retried through the transient fault rather than swallowing it"
        )

        client.stop()
    }

    // MARK: - Helpers

    @MainActor
    private func makeClient(
        directory: any IrohPairingDirectory,
        inboundPeerPolicyLoader: @escaping @Sendable (String, String) async -> IrohInboundPeerPolicyLoadResult = { _, _ in
            .authoritative(IrohInboundPeerPolicy(allowedPeerNodeIds: []))
        },
        now: @escaping @Sendable () -> Date = Date.init,
        missRefreshMinimumPolicyAge: TimeInterval = 0.5,
        missRefreshBudgetInterval: TimeInterval = 15,
        transportFactory: (@MainActor (HermesIrohRelayHostClient) -> any IrohRelayTransport)? = nil
    ) -> HermesIrohRelayHostClient {
        let suiteName = "hermes.iroh.host.matters.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        settings.hermesIrohTransportEnabled = true

        return HermesIrohRelayHostClient(
            settingsManager: settings,
            pairingKeyStore: IrohPairingKeyStore(
                service: "ai.openburnbar.tests.iroh-pairing.\(UUID().uuidString)",
                account: "host"
            ),
            directory: directory,
            publicKeyPublisher: NoopIrohPairingPublicKeyPublisher(),
            auditLogger: NoopIrohTransportAuditLogger(),
            inboundPeerPolicyLoader: inboundPeerPolicyLoader,
            pairingPublishInterval: 3_600,
            now: now,
            missRefreshMinimumPolicyAge: missRefreshMinimumPolicyAge,
            missRefreshBudgetInterval: missRefreshBudgetInterval,
            revokeRetryAttempts: 3,
            // Collapse backoff so retries run instantly under test.
            revokeRetrySleep: { _ in },
            transportFactory: transportFactory ?? { _ in StubIrohRelayTransport(nodeId: "node-default") }
        )
    }

    private func makeBinding(
        nodeId: String,
        generation: UInt64,
        registeredAtMillis: Int64,
        expiresAtMillis: Int64
    ) throws -> IrohControllerRouteBinding {
        try XCTUnwrap(IrohControllerRouteBinding(
            sourceDeviceId: "ios-device-1",
            transportNodeId: nodeId,
            authorityPeerNodeId: "ios-authority-1",
            generation: generation,
            registeredAtMillis: registeredAtMillis,
            expiresAtMillis: expiresAtMillis
        ))
    }

    /// The directory fakes never inspect the signature, so a plainly-constructed
    /// record is enough to assert presence/removal across the revoke path.
    private func makeRecord() -> IrohPairingRecord {
        IrohPairingRecord(
            uid: uid,
            connectionId: connectionID,
            nodeId: "node-record",
            relayURL: "https://relay.example/",
            directAddresses: ["127.0.0.1:1234"],
            publishedAtMillis: Int64(Date().timeIntervalSince1970 * 1000),
            signature: "test-signature"
        )
    }
}

private actor SequencedInboundPolicyLoader {
    private var policies: [IrohInboundPeerPolicy]
    private(set) var callCount = 0

    init(policies: [IrohInboundPeerPolicy]) {
        self.policies = policies
    }

    func load(uid _: String, connectionID _: String) -> IrohInboundPeerPolicy {
        callCount += 1
        guard !policies.isEmpty else {
            return IrohInboundPeerPolicy(routeBindings: [])
        }
        return policies.removeFirst()
    }
}

private actor ControlledInboundPolicyLoader {
    private var immediate: [Int: IrohInboundPeerPolicyLoadResult]
    private var continuations: [Int: CheckedContinuation<IrohInboundPeerPolicyLoadResult, Never>] = [:]
    private(set) var callCount = 0

    init(immediate: [Int: IrohInboundPeerPolicyLoadResult]) {
        self.immediate = immediate
    }

    func load(uid _: String, connectionID _: String) async -> IrohInboundPeerPolicyLoadResult {
        let callIndex = callCount
        callCount += 1
        if let result = immediate.removeValue(forKey: callIndex) {
            return result
        }
        return await withCheckedContinuation { continuation in
            continuations[callIndex] = continuation
        }
    }

    func resolve(callIndex: Int, with result: IrohInboundPeerPolicyLoadResult) {
        continuations.removeValue(forKey: callIndex)?.resume(returning: result)
    }
}

private final class LockedHostTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func set(_ date: Date) {
        lock.withLock { self.date = date }
    }
}

// MARK: - Test doubles

private actor BlockingHostTestStream: IrohRelayStream {
    nonisolated let remotePeerNodeId: String?
    private var frames: [HermesRealtimeRelayFrame]
    private var closed = false

    init(remotePeerNodeId: String, frames: [HermesRealtimeRelayFrame] = []) {
        self.remotePeerNodeId = remotePeerNodeId
        self.frames = frames
    }

    var isClosed: Bool { closed }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {}

    func receive() async throws -> HermesRealtimeRelayFrame? {
        if !frames.isEmpty {
            return frames.removeFirst()
        }
        while !closed, !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func close() async {
        closed = true
    }
}

private actor HostMediaControlRegistrarRecorder {
    private(set) var registrationCount = 0

    func record(stream _: any IrohRelayStream, uid _: String, connectionID _: String) {
        registrationCount += 1
    }
}

private actor SingleInboundStreamTransport: IrohRelayTransport {
    nonisolated let identity = IrohEndpointIdentity(
        nodeId: "host-node",
        rawPublicKey: Data(repeating: 0xAC, count: 32),
        relayURL: "https://relay.example/",
        directAddresses: []
    )
    private let stream: BlockingHostTestStream
    private var delivered = false
    private(set) var acceptCount = 0
    private var stopped = false

    init(stream: BlockingHostTestStream) {
        self.stream = stream
    }

    func start() async throws -> IrohEndpointIdentity { identity }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohRelayTransportError.endpointNotReady
    }

    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        acceptCount += 1
        if !delivered {
            delivered = true
            return stream
        }
        while !stopped, !Task.isCancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw IrohRelayTransportError.shutdown
    }

    func shutdown() async {
        stopped = true
    }
}

/// Directory that fails `revoke` a configurable number of times before letting
/// it succeed, counting every attempt. Backed by an in-memory store so the
/// "record is gone" assertion is real.
private actor FlakyRevokeDirectory: IrohPairingDirectory {
    private var store: [String: IrohPairingRecord] = [:]
    private var remainingFailures: Int
    private(set) var revokeAttemptCount = 0

    init(failuresBeforeSuccess: Int) {
        self.remainingFailures = failuresBeforeSuccess
    }

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        store[key(uid: uid, connectionId: record.connectionId)] = record
    }

    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        store[key(uid: uid, connectionId: connectionId)]
    }

    func revoke(uid: String, connectionId: String) async throws {
        revokeAttemptCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw RevokeFault.transient
        }
        store.removeValue(forKey: key(uid: uid, connectionId: connectionId))
    }

    private func key(uid: String, connectionId: String) -> String {
        "\(uid)::\(connectionId)"
    }

    enum RevokeFault: Error { case transient }
}

/// Directory that always rejects writes/revokes as unsupported — models the
/// iOS read-only reader being wired into a host path by mistake.
private actor ReaderOnlyDirectory: IrohPairingDirectory {
    private(set) var revokeAttemptCount = 0

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        throw IrohPairingDirectoryError.unsupportedOnReader
    }

    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        nil
    }

    func revoke(uid: String, connectionId: String) async throws {
        revokeAttemptCount += 1
        throw IrohPairingDirectoryError.unsupportedOnReader
    }
}

/// Records the backoff intervals the helper requests so tests can assert the
/// retry cadence without real waits.
private actor SleepCollector {
    private(set) var intervals: [UInt64] = []

    func record(_ nanos: UInt64) {
        intervals.append(nanos)
    }
}

/// Minimal transport. `park` keeps `accept` blocked until cancellation (clean
/// bring-up); `shutdownImmediately` throws `.shutdown` on the first `accept` so
/// the host runs `handleAcceptLoopTerminated` (the L519 revoke site) while the
/// transport is still current.
private final class StubIrohRelayTransport: IrohRelayTransport, @unchecked Sendable {
    enum AcceptBehavior: Sendable {
        case park
        case shutdownImmediately
    }

    private let identity: IrohEndpointIdentity
    private let acceptBehavior: AcceptBehavior

    init(nodeId: String, acceptBehavior: AcceptBehavior = .park) {
        self.identity = IrohEndpointIdentity(
            nodeId: nodeId,
            rawPublicKey: Data(repeating: 0xAB, count: 32),
            relayURL: "https://relay.example/",
            directAddresses: ["127.0.0.1:1234"]
        )
        self.acceptBehavior = acceptBehavior
    }

    func start() async throws -> IrohEndpointIdentity { identity }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohRelayTransportError.endpointNotReady
    }

    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        switch acceptBehavior {
        case .shutdownImmediately:
            throw IrohRelayTransportError.shutdown
        case .park:
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw IrohRelayTransportError.shutdown
        }
    }

    func shutdown() async {}
}

private actor NoopIrohPairingPublicKeyPublisher: IrohPairingPublicKeyPublishing {
    func publish(uid: String, deviceId: String, publicKeyBase64: String) async throws {}
}

private actor NoopIrohTransportAuditLogger: IrohTransportAuditLogging {
    func record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: [String: String]
    ) async {}
}

private func waitUntil(
    timeout: TimeInterval = 2,
    pollInterval: UInt64 = 50_000_000,
    condition: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
    XCTFail("Timed out waiting for condition")
}

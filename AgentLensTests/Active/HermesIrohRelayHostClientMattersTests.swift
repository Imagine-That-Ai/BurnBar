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

    @MainActor
    func test_defaultTransportWithoutNativeBackendDoesNotPublishLoopback() async {
        let transport = HermesIrohRelayHostClient.defaultTransport(
            backendFactory: { nil }
        )

        XCTAssertFalse(transport is LoopbackIrohRelayTransport)
        do {
            _ = try await transport.start()
            XCTFail("A signed Mac without the native iroh module must fail fast.")
        } catch let error as IrohRelayTransportError {
            XCTAssertEqual(error, .backendUnavailable)
        } catch {
            XCTFail("Unexpected missing-backend error: \(error)")
        }
    }

    @MainActor
    func test_backendUnavailableIsTerminalForHostAcceptLoop() {
        XCTAssertFalse(
            HermesIrohRelayHostClient.shouldRebuildAfterAcceptError(
                IrohRelayTransportError.backendUnavailable
            )
        )
        XCTAssertFalse(
            HermesIrohRelayHostClient.isRecoverablePeerAcceptError(
                IrohRelayTransportError.backendUnavailable
            )
        )
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

    /// Native iroh can report an individual peer closing as `connection lost`
    /// from `accept`. One or two such failures are recoverable, but treating an
    /// unlimited sequence as healthy wedges the host forever: the stale NodeId
    /// remains published while no new stream can be accepted. A bounded burst
    /// must therefore rebuild the endpoint and publish the replacement NodeId.
    @MainActor
    func test_repeatedRecoverablePeerAcceptFailures_rebuildEndpoint() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: 0)
        let failing = StubIrohRelayTransport(
            nodeId: "node-peer-closed",
            acceptBehavior: .connectionLostRepeatedly
        )
        let parking = StubIrohRelayTransport(nodeId: "node-recovered", acceptBehavior: .park)
        var transports: [StubIrohRelayTransport] = [failing, parking]
        let client = makeClient(
            directory: directory,
            transportFactory: { _ in transports.removeFirst() }
        )

        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)

        try await waitUntil(timeout: 4) {
            let record = try await directory.fetch(uid: self.uid, connectionId: self.connectionID)
            return record?.nodeId == "node-recovered"
        }
        XCTAssertGreaterThanOrEqual(
            failing.acceptCallCount,
            3,
            "The host should tolerate a bounded burst before rebuilding"
        )

        client.stop()
    }

    /// The native path reports peer-close accept failures before Swift obtains
    /// a peer identity or applies the inbound allowlist, so any peer that can
    /// reach the advertised endpoint can manufacture an arbitrary run of them
    /// by completing ALPN and closing early. When the host holds
    /// peer-independent acceptor-health evidence (here: a recently completed
    /// `accept`), such a burst must NOT tear the endpoint down; otherwise an
    /// unauthenticated or revoked peer could repeatedly cancel live chat/media
    /// sessions and churn the published NodeId.
    @MainActor
    func test_peerAcceptFailureBurst_withHealthEvidence_doesNotRebuild() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: 0)
        let transport = StubIrohRelayTransport(
            nodeId: "node-healthy",
            acceptBehavior: .acceptOneThenConnectionLost
        )
        // A decoy replacement transport: a rebuild would consume it and
        // republish under "node-rebuilt", so it staying queued (and the
        // directory keeping "node-healthy") proves suppression.
        let decoy = StubIrohRelayTransport(nodeId: "node-rebuilt", acceptBehavior: .park)
        var transports: [StubIrohRelayTransport] = [transport, decoy]
        let client = makeClient(
            directory: directory,
            transportFactory: { _ in transports.removeFirst() }
        )

        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)

        // Let the hostile burst run well past the rebuild threshold.
        try await waitUntil(timeout: 4) {
            transport.acceptCallCount >= 6
        }
        let record = try await directory.fetch(uid: uid, connectionId: connectionID)
        XCTAssertEqual(
            record?.nodeId,
            "node-healthy",
            "A peer-manufactured accept-failure burst must not revoke or rotate the published NodeId"
        )
        XCTAssertEqual(
            transports.count,
            1,
            "The original transport must stay current; a rebuild would have consumed the decoy replacement"
        )

        client.stop()
    }

    /// A completed accept must clear the recoverable-failure streak even when
    /// the allowlist then rejects the stream. Otherwise failures accumulated
    /// before a successful accept survive the rejection branch and, once the
    /// 30-second health-evidence window lapses, later peer-close errors reach
    /// the limit and rebuild an endpoint whose acceptor made intervening
    /// progress.
    @MainActor
    func test_completedAcceptResetsFailureStreak_evenWhenStreamIsRejected() async throws {
        let directory = FlakyRevokeDirectory(failuresBeforeSuccess: 0)
        // 2 failures, then a completed accept (rejected by the empty
        // allowlist), then 2 more failures: once the accept resets the streak,
        // no run of 3 consecutive failures exists, so the endpoint must never
        // rebuild.
        let transport = StubIrohRelayTransport(
            nodeId: "node-streak-reset",
            acceptBehavior: .failuresThenAcceptThenFailures(before: 2, after: 2)
        )
        let decoy = StubIrohRelayTransport(nodeId: "node-rebuilt", acceptBehavior: .park)
        var transports: [StubIrohRelayTransport] = [transport, decoy]
        let clock = MutableTestClock()
        let client = makeClient(
            directory: directory,
            now: { clock.now },
            transportFactory: { _ in transports.removeFirst() }
        )

        let started = await client.start(uid: uid, connectionID: connectionID)
        XCTAssertTrue(started)

        // Once the accept has landed, expire the health-evidence window so the
        // post-accept failures cannot hide behind `lastAcceptedStreamAt`; only
        // the streak reset can keep the endpoint alive.
        try await waitUntil(timeout: 4) { transport.acceptCallCount >= 3 }
        clock.advance(by: 31)

        try await waitUntil(timeout: 4) { transport.acceptCallCount >= 6 }
        let record = try await directory.fetch(uid: uid, connectionId: connectionID)
        XCTAssertEqual(
            record?.nodeId,
            "node-streak-reset",
            "Failures from before a completed accept must not combine with later ones to rotate the NodeId"
        )
        XCTAssertEqual(
            transports.count,
            1,
            "A rebuild would have consumed the decoy replacement transport"
        )

        client.stop()
    }

    /// Transferred `media.control` streams keep the host's endpoint-health
    /// evidence alive: their serve task is released while the live stream is
    /// retained, so an active mirror or call must count even when `serveTasks`
    /// is empty and the last accept is older than the evidence window.
    func test_healthEvidence_countsRetainedTransferredStreams() {
        let now = Date()
        let staleAccept = now.addingTimeInterval(-60)
        XCTAssertTrue(
            HermesIrohRelayHostClient.hasPeerIndependentEndpointHealthEvidence(
                activeServeTaskCount: 0,
                retainedServeStreamCount: 1,
                lastAcceptedStreamAt: staleAccept,
                now: now
            ),
            "A retained transferred media.control stream is an active session and must suppress rebuild"
        )
        XCTAssertFalse(
            HermesIrohRelayHostClient.hasPeerIndependentEndpointHealthEvidence(
                activeServeTaskCount: 0,
                retainedServeStreamCount: 0,
                lastAcceptedStreamAt: staleAccept,
                now: now
            ),
            "No tasks, no retained streams, and a stale accept leave the endpoint free to rebuild"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func makeClient(
        directory: any IrohPairingDirectory,
        publicKeyPublisher: IrohPairingPublicKeyPublishing = NoopIrohPairingPublicKeyPublisher(),
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
            publicKeyPublisher: publicKeyPublisher,
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

/// Injectable wall clock so tests can expire the acceptor health-evidence
/// window deterministically instead of sleeping through it.
private final class MutableTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

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

private actor ApplyThenThrowPairingDirectory: IrohPairingDirectory {
    private var store: [String: IrohPairingRecord] = [:]
    private let failOnPublishCallIndex: Int
    private var publishCallCount = 0
    private(set) var revokeAttemptCount = 0

    init(failOnPublishCallIndex: Int) {
        self.failOnPublishCallIndex = failOnPublishCallIndex
    }

    func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        let callIndex = publishCallCount
        publishCallCount += 1
        store[key(uid: uid, connectionId: record.connectionId)] = record
        if callIndex == failOnPublishCallIndex {
            throw PublishFault.appliedThenFailed
        }
    }

    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        store[key(uid: uid, connectionId: connectionId)]
    }

    func revoke(uid: String, connectionId: String) async throws {
        revokeAttemptCount += 1
        store.removeValue(forKey: key(uid: uid, connectionId: connectionId))
    }

    private func key(uid: String, connectionId: String) -> String {
        "\(uid)::\(connectionId)"
    }

    enum PublishFault: Error { case appliedThenFailed }
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
        case connectionLostRepeatedly
        /// First `accept` hands back a real stream (acceptor-health evidence),
        /// every later `accept` fails like a peer that completed ALPN and
        /// closed before opening a bidirectional stream.
        case acceptOneThenConnectionLost
        /// Scripted streak-reset sequence: `before` peer-close failures, then
        /// one completed accept (an unadmitted stream the empty allowlist
        /// rejects), then `after` more peer-close failures, then park.
        case failuresThenAcceptThenFailures(before: Int, after: Int)
    }

    private let identity: IrohEndpointIdentity
    private let acceptBehavior: AcceptBehavior
    private let lock = NSLock()
    private var _acceptCallCount = 0

    var acceptCallCount: Int {
        lock.withLock { _acceptCallCount }
    }

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
        let callIndex = lock.withLock { () -> Int in
            _acceptCallCount += 1
            return _acceptCallCount
        }
        switch acceptBehavior {
        case .shutdownImmediately:
            throw IrohRelayTransportError.shutdown
        case .connectionLostRepeatedly:
            throw IrohRelayTransportError.streamRejected("connection lost")
        case .acceptOneThenConnectionLost:
            if callIndex == 1 {
                return BlockingHostTestStream(remotePeerNodeId: "unadmitted-peer")
            }
            throw IrohRelayTransportError.streamRejected("connection lost")
        case .failuresThenAcceptThenFailures(let before, let after):
            if callIndex == before + 1 {
                return BlockingHostTestStream(remotePeerNodeId: "unadmitted-peer")
            }
            if callIndex <= before + 1 + after {
                throw IrohRelayTransportError.streamRejected("connection lost")
            }
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
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

private actor ControlledStartIrohRelayTransport: IrohRelayTransport {
    private let identity: IrohEndpointIdentity
    private var startContinuation: CheckedContinuation<IrohEndpointIdentity, Never>?
    private(set) var hasEnteredStart = false
    private(set) var shutdownCount = 0

    init(nodeId: String) {
        identity = IrohEndpointIdentity(
            nodeId: nodeId,
            rawPublicKey: Data(repeating: 0xCD, count: 32),
            relayURL: "https://relay.example/",
            directAddresses: ["127.0.0.1:4321"]
        )
    }

    func start() async throws -> IrohEndpointIdentity {
        hasEnteredStart = true
        return await withCheckedContinuation { startContinuation = $0 }
    }

    func releaseStart() {
        startContinuation?.resume(returning: identity)
        startContinuation = nil
    }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohRelayTransportError.endpointNotReady
    }

    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohRelayTransportError.shutdown
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor NoopIrohPairingPublicKeyPublisher: IrohPairingPublicKeyPublishing {
    func publish(uid: String, deviceId: String, publicKeyBase64: String) async throws {}
}

private actor ControlledIrohPairingPublicKeyPublisher: IrohPairingPublicKeyPublishing {
    private let suspendOnCallIndex: Int
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(suspendOnCallIndex: Int) {
        self.suspendOnCallIndex = suspendOnCallIndex
    }

    func publish(uid _: String, deviceId _: String, publicKeyBase64 _: String) async throws {
        let callIndex = callCount
        callCount += 1
        guard callIndex == suspendOnCallIndex else { return }
        await withCheckedContinuation { suspendedContinuation = $0 }
    }

    func releaseSuspendedPublish() {
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }
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

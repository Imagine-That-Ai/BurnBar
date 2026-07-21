import Foundation
import GRDB
import OpenBurnBarDaemon
import OpenBurnBarEngine
import XCTest

final class LinuxCloudReplicaEngineTests: XCTestCase {
    private let uid = "user-123"
    private let key = Data(repeating: 0x2a, count: 32)

    func testStagesCiphertextOnlyAndRequiresSeparateRemoteAccessConsent() async throws {
        let database = try DatabaseQueue()
        let gateway = ReplicaGateway()
        let engine = try LinuxCloudReplicaEngine(
            database: database,
            gateway: gateway,
            deviceID: "linux-a",
            nowMillis: { 1_000 }
        )
        try await engine.setConsentPolicy(
            .init(enabledDomains: [.conversations]),
            uid: uid
        )

        _ = try await engine.stageUpdate(
            uid: uid,
            domain: .conversations,
            recordID: "thread-1",
            plaintext: Data("private transcript".utf8),
            vaultKey: key
        )
        let cycle = try await engine.syncOnce(uid: uid, vaultKey: key)
        XCTAssertEqual(cycle.pushedCount, 1)

        let pushed = await gateway.allPushed()
        let encoded = try JSONEncoder().encode(pushed)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private transcript"))
        XCTAssertFalse(pushed[0].mutationID.isEmpty)
        do {
            _ = try await engine.readForRemoteAccess(
                uid: uid,
                domain: .conversations,
                recordID: "thread-1",
                vaultKey: key
            )
            XCTFail("remote reads must be independently consented")
        } catch let error as LinuxCloudReplicaEngine.EngineError {
            XCTAssertEqual(error, .remoteAccessDisabled)
        }

        try await engine.setConsentPolicy(
            .init(enabledDomains: [.conversations], remoteAccessEnabled: true),
            uid: uid
        )
        let restored = try await engine.readForRemoteAccess(
            uid: uid,
            domain: .conversations,
            recordID: "thread-1",
            vaultKey: key
        )
        XCTAssertEqual(restored, Data("private transcript".utf8))
    }

    func testFailedPushRetainsStableIdempotencyKeyAcrossRetryAndRestart() async throws {
        let database = try DatabaseQueue()
        let gateway = ReplicaGateway(pushFailures: 1)
        let first = try LinuxCloudReplicaEngine(
            database: database,
            gateway: gateway,
            deviceID: "linux-a",
            nowMillis: { 10_000 }
        )
        try await first.setConsentPolicy(.init(enabledDomains: [.usage]), uid: uid)
        _ = try await first.stageUpdate(
            uid: uid,
            domain: .usage,
            recordID: "event-1",
            plaintext: Data("{\"tokens\":12}".utf8),
            vaultKey: key
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await first.syncOnce(uid: self.uid, vaultKey: self.key)
        }
        let pendingBeforeRestart = try await first.status(uid: uid).pendingMutationCount
        XCTAssertEqual(pendingBeforeRestart, 1)

        let restarted = try LinuxCloudReplicaEngine(
            database: database,
            gateway: gateway,
            deviceID: "linux-a",
            nowMillis: { 20_000 }
        )
        _ = try await restarted.syncOnce(uid: uid, vaultKey: key, force: true)
        let attempts = await gateway.pushAttempts()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].map(\.mutationID), attempts[1].map(\.mutationID))
        let pendingAfterRetry = try await restarted.status(uid: uid).pendingMutationCount
        XCTAssertEqual(pendingAfterRetry, 0)
    }

    func testInvalidRemoteEnvelopeDoesNotAdvanceCursorOrMutateReplica() async throws {
        let database = try DatabaseQueue()
        let invalidEnvelope = CloudVaultSealedText(
            algorithm: CloudVaultCrypto.aesGCMAlgorithm,
            keyVersion: 1,
            nonce: "invalid",
            ciphertext: "invalid",
            tag: "invalid"
        )
        let gateway = ReplicaGateway(pages: [
            .init(
                replicas: [
                    .init(
                        domain: .sessionLogs,
                        recordID: "log-1",
                        revision: 1,
                        modifiedAtMillis: 1,
                        sourceDeviceID: "linux-b",
                        tombstone: false,
                        sealedPayload: invalidEnvelope
                    )
                ],
                nextCursor: "cursor-unsafe"
            )
        ])
        let engine = try LinuxCloudReplicaEngine(
            database: database,
            gateway: gateway,
            deviceID: "linux-a",
            nowMillis: { 5_000 }
        )
        try await engine.setConsentPolicy(
            .init(enabledDomains: [.sessionLogs], remoteAccessEnabled: true),
            uid: uid
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await engine.syncOnce(uid: self.uid, vaultKey: self.key)
        }
        let status = try await engine.status(uid: uid)
        XCTAssertNil(status.pullCursor)
        XCTAssertEqual(status.consecutiveFailures, 0, "validation failures are deterministic, not transport backoff")
        let absentReplica = try await engine.readForRemoteAccess(
            uid: uid,
            domain: .sessionLogs,
            recordID: "log-1",
            vaultKey: key
        )
        XCTAssertNil(absentReplica)
    }

    func testEqualRevisionConcurrentEditsConvergeByTimestampThenDeviceID() async throws {
        let clock: @Sendable () -> Int64 = { 7_000 }
        let gatewayA = ReplicaGateway()
        let gatewayB = ReplicaGateway()
        let engineA = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(), gateway: gatewayA, deviceID: "device-a", nowMillis: clock
        )
        let engineB = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(), gateway: gatewayB, deviceID: "device-b", nowMillis: clock
        )
        let policy = LinuxCloudReplicaEngine.ConsentPolicy(
            enabledDomains: [.roamingProfile], remoteAccessEnabled: true
        )
        try await engineA.setConsentPolicy(policy, uid: uid)
        try await engineB.setConsentPolicy(policy, uid: uid)
        let a = try await engineA.stageUpdate(
            uid: uid, domain: .roamingProfile, recordID: "current",
            plaintext: Data("profile-a".utf8), vaultKey: key
        )
        let b = try await engineB.stageUpdate(
            uid: uid, domain: .roamingProfile, recordID: "current",
            plaintext: Data("profile-b".utf8), vaultKey: key
        )

        _ = try await engineA.syncOnce(uid: uid, vaultKey: key)
        _ = try await engineB.syncOnce(uid: uid, vaultKey: key)
        await gatewayA.enqueue(.init(replicas: [b], nextCursor: "2"))
        await gatewayB.enqueue(.init(replicas: [a], nextCursor: "2"))
        _ = try await engineA.syncOnce(uid: uid, vaultKey: key)
        _ = try await engineB.syncOnce(uid: uid, vaultKey: key)

        let expected = Data("profile-b".utf8)
        let restoredA = try await engineA.readForRemoteAccess(
            uid: uid, domain: .roamingProfile, recordID: "current", vaultKey: key
        )
        let restoredB = try await engineB.readForRemoteAccess(
            uid: uid, domain: .roamingProfile, recordID: "current", vaultKey: key
        )
        XCTAssertEqual(restoredA, expected)
        XCTAssertEqual(restoredB, expected)
    }

    func testTransportFailurePersistsCappedBackoffAndSuccessClearsIt() async throws {
        final class Clock: @unchecked Sendable {
            var value: Int64 = 1_000
        }
        let clock = Clock()
        let gateway = ReplicaGateway(pullFailures: 1)
        let engine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(),
            gateway: gateway,
            deviceID: "linux-a",
            backoff: .init(baseDelayMillis: 100, maximumDelayMillis: 400),
            nowMillis: { clock.value }
        )
        try await engine.setConsentPolicy(.init(enabledDomains: [.usage]), uid: uid)
        await XCTAssertThrowsErrorAsync {
            _ = try await engine.syncOnce(uid: self.uid, vaultKey: self.key)
        }
        var status = try await engine.status(uid: uid)
        XCTAssertEqual(status.phase, .backoff)
        XCTAssertEqual(status.retryAtMillis, 1_100)

        clock.value = 1_100
        _ = try await engine.syncOnce(uid: uid, vaultKey: key)
        status = try await engine.status(uid: uid)
        XCTAssertEqual(status.phase, .ready)
        XCTAssertEqual(status.consecutiveFailures, 0)
        XCTAssertNil(status.retryAtMillis)
    }

    func testRuntimeOwnsIdentityKeyAndExposesOnlyRedactedLifecycle() async throws {
        let gateway = ReplicaGateway()
        let engine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(),
            gateway: gateway,
            deviceID: "linux-a",
            nowMillis: { 4_000 }
        )
        let runtime = LinuxCloudSyncRuntime(
            engine: engine,
            identityProvider: { self.uid },
            vaultKeyProvider: { self.key }
        )

        let policyStatus = try await runtime.updatePolicy(.init(
            enabledDomains: ["usage", "conversations"],
            remoteAccessEnabled: true
        ))
        XCTAssertEqual(policyStatus.enabledDomains, ["conversations", "usage"])
        XCTAssertTrue(policyStatus.remoteAccessEnabled)
        XCTAssertTrue(policyStatus.vaultKeyAvailable)

        do {
            _ = try await runtime.updatePolicy(.init(
                enabledDomains: ["future_domain"],
                remoteAccessEnabled: false
            ))
            XCTFail("unknown domains must fail closed")
        } catch let error as LinuxCloudReplicaEngine.EngineError {
            XCTAssertEqual(error, .invalidIdentifier)
        }

        _ = try await engine.stageUpdate(
            uid: uid,
            domain: .usage,
            recordID: "event-2",
            plaintext: Data("secret-usage".utf8),
            vaultKey: key
        )
        let result = try await runtime.run(force: false)
        XCTAssertEqual(result.pushedCount, 1)
        XCTAssertEqual(result.status.pendingMutationCount, 0)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains(uid))
        XCTAssertFalse(json.contains(key.base64EncodedString()))
        XCTAssertFalse(json.contains("secret-usage"))
    }

    func testStatusAndPolicyRemainAvailableWhileVaultKeyIsLocked() async throws {
        let engine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(),
            gateway: ReplicaGateway(),
            deviceID: "linux-a"
        )
        let runtime = LinuxCloudSyncRuntime(
            engine: engine,
            identityProvider: { self.uid },
            vaultKeyProvider: { throw LockedVaultKeyError() }
        )

        let updated = try await runtime.updatePolicy(.init(
            enabledDomains: ["usage"],
            remoteAccessEnabled: false
        ))
        XCTAssertEqual(updated.phase, "locked")
        XCTAssertFalse(updated.vaultKeyAvailable)
        XCTAssertEqual(updated.enabledDomains, ["usage"])

        let status = try await runtime.status()
        XCTAssertEqual(status.phase, "locked")
        XCTAssertEqual(status.enabledDomains, ["usage"])
    }

    func testEngineRejectsUnknownDirectAndPersistedPolicyDomains() async throws {
        let database = try DatabaseQueue()
        let engine = try LinuxCloudReplicaEngine(
            database: database,
            gateway: ReplicaGateway(),
            deviceID: "linux-a"
        )
        let future = try XCTUnwrap(LinuxCloudReplicaEngine.Domain(rawValue: "future_domain"))
        do {
            try await engine.setConsentPolicy(.init(enabledDomains: [future]), uid: uid)
            XCTFail("direct callers must not bypass the supported-domain allowlist")
        } catch let error as LinuxCloudReplicaEngine.EngineError {
            XCTAssertEqual(error, .invalidIdentifier)
        }

        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO linux_cloud_sync_policy (uid, enabled_domains, remote_access_enabled)
                    VALUES (?, ?, 0)
                    """,
                arguments: [self.uid, Data("[\"future_domain\"]".utf8)]
            )
        }
        do {
            _ = try await engine.consentPolicy(uid: uid)
            XCTFail("persisted policy rows must be revalidated")
        } catch let error as LinuxCloudReplicaEngine.EngineError {
            XCTAssertEqual(error, .invalidIdentifier)
        }
    }

    func testChangingDomainConsentInvalidatesPriorPullCursor() async throws {
        let gateway = ReplicaGateway(pages: [.init(replicas: [], nextCursor: "usage-cursor")])
        let engine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(), gateway: gateway, deviceID: "linux-a"
        )
        try await engine.setConsentPolicy(.init(enabledDomains: [.usage]), uid: uid)
        _ = try await engine.syncOnce(uid: uid, vaultKey: key)
        let before = try await engine.status(uid: uid)
        XCTAssertEqual(before.pullCursor, "usage-cursor")

        try await engine.setConsentPolicy(
            .init(enabledDomains: [.usage, .conversations]),
            uid: uid
        )
        let after = try await engine.status(uid: uid)
        XCTAssertNil(after.pullCursor)
        XCTAssertEqual(after.consecutiveFailures, 0)
        XCTAssertNil(after.retryAtMillis)
    }

    func testPushReconcilesStaleLocalMutationToAuthoritativeRemoteWinner() async throws {
        let gateway = ReplicaGateway()
        let engine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(), gateway: gateway, deviceID: "linux-a", nowMillis: { 1_000 }
        )
        try await engine.setConsentPolicy(
            .init(enabledDomains: [.roamingProfile], remoteAccessEnabled: true), uid: uid
        )
        let local = try await engine.stageUpdate(
            uid: uid, domain: .roamingProfile, recordID: "current",
            plaintext: Data("stale-local".utf8), vaultKey: key
        )
        let remotePayload = try CloudVaultCrypto.sealText(
            "newer-remote",
            keyData: key,
            aadContext: try CloudVaultAADContext(
                uid: uid,
                collection: LinuxCloudReplicaEngine.Domain.roamingProfile.rawValue,
                docID: "current",
                field: "sealedPayload",
                purpose: "linux-cloud-replica"
            )
        )
        let remote = LinuxCloudReplicaEngine.RemoteReplica(
            domain: .roamingProfile,
            recordID: "current",
            revision: local.revision + 1,
            modifiedAtMillis: 2_000,
            sourceDeviceID: "linux-b",
            tombstone: false,
            sealedPayload: remotePayload
        )
        await gateway.setAuthoritativeReplicas([remote])

        let result = try await engine.syncOnce(uid: uid, vaultKey: key)
        let status = try await engine.status(uid: uid)
        let restored = try await engine.readForRemoteAccess(
            uid: uid, domain: .roamingProfile, recordID: "current", vaultKey: key
        )

        XCTAssertEqual(result.pushedCount, 1)
        XCTAssertEqual(status.pendingMutationCount, 0)
        XCTAssertEqual(restored, Data("newer-remote".utf8))
    }

    func testIncompleteOrRegressivePushResultRetainsDurableOutbox() async throws {
        let gateway = ReplicaGateway(pushResultMode: .omitAcknowledgement)
        let engine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(), gateway: gateway, deviceID: "linux-a", nowMillis: { 1_000 }
        )
        try await engine.setConsentPolicy(.init(enabledDomains: [.usage]), uid: uid)
        _ = try await engine.stageUpdate(
            uid: uid, domain: .usage, recordID: "event-1",
            plaintext: Data("local".utf8), vaultKey: key
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await engine.syncOnce(uid: self.uid, vaultKey: self.key)
        }
        let incompleteStatus = try await engine.status(uid: uid)
        XCTAssertEqual(incompleteStatus.pendingMutationCount, 1)

        let regressiveGateway = ReplicaGateway(pushResultMode: .oldestReplica)
        let regressiveEngine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(), gateway: regressiveGateway, deviceID: "linux-a", nowMillis: { 2_000 }
        )
        try await regressiveEngine.setConsentPolicy(.init(enabledDomains: [.usage]), uid: uid)
        _ = try await regressiveEngine.stageUpdate(
            uid: uid, domain: .usage, recordID: "event-2",
            plaintext: Data("older".utf8), vaultKey: key
        )
        _ = try await regressiveEngine.stageUpdate(
            uid: uid, domain: .usage, recordID: "event-2",
            plaintext: Data("newer".utf8), vaultKey: key
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await regressiveEngine.syncOnce(uid: self.uid, vaultKey: self.key)
        }
        let regressiveStatus = try await regressiveEngine.status(uid: uid)
        XCTAssertEqual(regressiveStatus.pendingMutationCount, 2)
    }

    func testStatusCountsOnlyMutationsEligibleUnderCurrentConsent() async throws {
        let gateway = ReplicaGateway()
        let engine = try LinuxCloudReplicaEngine(
            database: try DatabaseQueue(), gateway: gateway, deviceID: "linux-a"
        )
        try await engine.setConsentPolicy(.init(enabledDomains: [.usage]), uid: uid)
        _ = try await engine.stageUpdate(
            uid: uid, domain: .usage, recordID: "event-1",
            plaintext: Data("local".utf8), vaultKey: key
        )
        let enabledBefore = try await engine.status(uid: uid)
        XCTAssertEqual(enabledBefore.pendingMutationCount, 1)

        try await engine.setConsentPolicy(.init(enabledDomains: []), uid: uid)
        let disabled = try await engine.status(uid: uid)
        XCTAssertEqual(disabled.phase, .disabled)
        XCTAssertEqual(disabled.pendingMutationCount, 0)

        try await engine.setConsentPolicy(.init(enabledDomains: [.usage]), uid: uid)
        let enabledAfter = try await engine.status(uid: uid)
        let cycle = try await engine.syncOnce(uid: uid, vaultKey: key)
        XCTAssertEqual(enabledAfter.pendingMutationCount, 1)
        XCTAssertEqual(cycle.pushedCount, 1)
    }

    func testRuntimeFactoryOwnsDatabaseAndPreservesDaemonOnlyProviders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cloud-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = ReplicaGateway()
        let runtime = try LinuxCloudSyncRuntimeFactory.make(
            databasePath: root.appendingPathComponent("openburnbar.sqlite").path,
            deviceID: "linux-factory",
            gateway: gateway,
            identityProvider: { "factory-user" },
            vaultKeyProvider: { Data(repeating: 0x2a, count: 32) },
            backgroundIntervalMillis: 10
        )

        let initial = try await runtime.status()
        XCTAssertEqual(initial.phase, "disabled")
        XCTAssertTrue(initial.vaultKeyAvailable)

        let configured = try await runtime.updatePolicy(
            .init(
                enabledDomains: [LinuxCloudReplicaEngine.Domain.usage.rawValue],
                remoteAccessEnabled: false
            )
        )
        XCTAssertEqual(configured.enabledDomains, [LinuxCloudReplicaEngine.Domain.usage.rawValue])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("openburnbar.sqlite").path))

        let initiallyRunning = await runtime.backgroundLoopIsRunning
        XCTAssertFalse(initiallyRunning)
        await runtime.startBackgroundLoop()
        let runningAfterStart = await runtime.backgroundLoopIsRunning
        XCTAssertTrue(runningAfterStart)
        await runtime.startBackgroundLoop()
        await runtime.stopBackgroundLoop()
        let runningAfterStop = await runtime.backgroundLoopIsRunning
        XCTAssertFalse(runningAfterStop)
    }

    #if os(Linux)
    func testProductionFactoryFailsClosedWhenCanonicalDatabasePathIsNotConfigured() async throws {
        let configuration = BurnBarDaemonConfiguration(indexDatabasePath: nil)
        let authority = LinuxDaemonCloudCredentialAuthority.production(environment: [:])
        let runtime = LinuxCloudSyncRuntimeFactory.makeProduction(
            configuration: configuration,
            credentialAuthority: authority,
            environment: [:]
        )
        XCTAssertNil(runtime)
    }
    #endif
}

private struct LockedVaultKeyError: Error {}

private actor ReplicaGateway: LinuxCloudReplicaEngine.Gateway {
    enum Failure: Error { case unavailable }
    enum PushResultMode { case valid, omitAcknowledgement, oldestReplica }

    private var pages: [LinuxCloudReplicaEngine.PullPage]
    private var remainingPushFailures: Int
    private var remainingPullFailures: Int
    private var attempts: [[LinuxCloudReplicaEngine.OutboundMutation]] = []
    private var authoritativeReplicas: [LinuxCloudReplicaEngine.RemoteReplica]?
    private let pushResultMode: PushResultMode

    init(
        pages: [LinuxCloudReplicaEngine.PullPage] = [],
        pushFailures: Int = 0,
        pullFailures: Int = 0,
        pushResultMode: PushResultMode = .valid
    ) {
        self.pages = pages
        remainingPushFailures = pushFailures
        remainingPullFailures = pullFailures
        self.pushResultMode = pushResultMode
    }

    func push(
        uid: String,
        mutations: [LinuxCloudReplicaEngine.OutboundMutation]
    ) async throws -> LinuxCloudReplicaEngine.PushResult {
        attempts.append(mutations)
        if remainingPushFailures > 0 {
            remainingPushFailures -= 1
            throw Failure.unavailable
        }
        let acknowledgements = pushResultMode == .omitAcknowledgement ? [] : mutations.map(\.mutationID)
        let authoritative: [LinuxCloudReplicaEngine.RemoteReplica]
        if let authoritativeReplicas {
            authoritative = authoritativeReplicas
        } else if pushResultMode == .oldestReplica, let oldest = mutations.first?.replica {
            authoritative = [oldest]
        } else {
            authoritative = Self.finalReplicas(from: mutations)
        }
        return .init(
            acknowledgedMutationIDs: acknowledgements,
            authoritativeReplicas: authoritative
        )
    }

    func pull(
        uid: String,
        domains: Set<LinuxCloudReplicaEngine.Domain>,
        after cursor: String?
    ) async throws -> LinuxCloudReplicaEngine.PullPage {
        if remainingPullFailures > 0 {
            remainingPullFailures -= 1
            throw Failure.unavailable
        }
        return pages.isEmpty ? .init(replicas: [], nextCursor: cursor) : pages.removeFirst()
    }

    func enqueue(_ page: LinuxCloudReplicaEngine.PullPage) {
        pages.append(page)
    }

    func setAuthoritativeReplicas(_ replicas: [LinuxCloudReplicaEngine.RemoteReplica]) {
        authoritativeReplicas = replicas
    }

    func allPushed() -> [LinuxCloudReplicaEngine.OutboundMutation] {
        attempts.flatMap { $0 }
    }

    func pushAttempts() -> [[LinuxCloudReplicaEngine.OutboundMutation]] { attempts }

    private static func finalReplicas(
        from mutations: [LinuxCloudReplicaEngine.OutboundMutation]
    ) -> [LinuxCloudReplicaEngine.RemoteReplica] {
        var replicas: [String: LinuxCloudReplicaEngine.RemoteReplica] = [:]
        for mutation in mutations {
            let replica = mutation.replica
            replicas["\(replica.domain.rawValue)\u{0}\(replica.recordID)"] = replica
        }
        return Array(replicas.values)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        return
    }
}

import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Service + RPC integration for the persistence layer: the fleet service
/// persists every completed tick into fleet.sqlite and fleet-snapshot.json,
/// records fixed-row transitions, and surfaces `persistenceHealth` in the
/// served snapshot while RPC keeps serving.
final class BurnBarFleetPersistenceServiceTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-persist-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    /// A probe whose claude-code row status can be flipped between builds.
    private final class FlipProbe: BurnBarFleetProbe, @unchecked Sendable {
        let agentID: BurnBarFleetAgentID
        let rootPath: String
        var claudeStatus: BurnBarFleetAgentStatus
        var claudeConfidence: BurnBarFleetConfidence

        init(
            agentID: BurnBarFleetAgentID,
            rootPath: String,
            claudeStatus: BurnBarFleetAgentStatus,
            claudeConfidence: BurnBarFleetConfidence
        ) {
            self.agentID = agentID
            self.rootPath = rootPath
            self.claudeStatus = claudeStatus
            self.claudeConfidence = claudeConfidence
        }

        func probe(now: Date) async -> BurnBarFleetProbeResult {
            let isClaude = agentID == .claudeCode
            let status = isClaude ? claudeStatus : .unknown
            let confidence = isClaude ? claudeConfidence : .unsupported
            let agent = BurnBarFleetAgent(
                id: agentID,
                displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                status: status,
                confidence: confidence,
                projectName: isClaude ? "/Users/test/RepoA" : nil
            )
            return BurnBarFleetProbeResult(
                agent: agent,
                health: BurnBarFleetProbeHealth(
                    agent: agentID,
                    state: .ok,
                    rootPath: rootPath,
                    checkedAt: now
                )
            )
        }
    }

    private func makeProbes(
        claudeStatus: BurnBarFleetAgentStatus,
        claudeConfidence: BurnBarFleetConfidence
    ) -> (probes: [BurnBarFleetAgentID: any BurnBarFleetProbe], flip: FlipProbe) {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        var flip: FlipProbe?
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = fixtureRoot
                .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: agentID), isDirectory: true)
                .path
            if agentID == .claudeCode {
                let probe = FlipProbe(
                    agentID: agentID,
                    rootPath: rootPath,
                    claudeStatus: claudeStatus,
                    claudeConfidence: claudeConfidence
                )
                probes[agentID] = probe
                flip = probe
            } else {
                probes[agentID] = FlipProbe(
                    agentID: agentID,
                    rootPath: rootPath,
                    claudeStatus: .unknown,
                    claudeConfidence: .unsupported
                )
            }
        }
        return (probes, flip!)
    }

    private func makePersister() throws -> BurnBarFleetPersister {
        // The store lives in a subdirectory so a read-only fixture root only
        // blocks the file writer (VAL-FLEET-021 injection), never the store.
        let storeDir = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        let store = BurnBarFleetStore(
            databasePath: storeDir.appendingPathComponent("fleet.sqlite").path,
            eventRetentionSeconds: 3600,
            snapshotRetentionCount: 5
        )
        _ = try store.open()
        let writer = BurnBarFleetFileWriter(
            fileURL: fixtureRoot.appendingPathComponent("fleet-snapshot.json")
        )
        return BurnBarFleetPersister(store: store, fileWriter: writer)
    }

    // MARK: - Service persists every tick + records transitions

    func testService_persistsEveryTick_recordsTransitions() async throws {
        let (probes, flip) = makeProbes(claudeStatus: .running, claudeConfidence: .exactProcess)
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes)
        let service = BurnBarFleetService(builder: builder, persister: try makePersister())

        let first = try await service.buildOnce()
        XCTAssertEqual(first.persistenceHealth, .ok)
        XCTAssertEqual(first.cadenceSeconds, 1)

        // Flip the fixture: running -> idle on the next build.
        flip.claudeStatus = .idle
        let second = try await service.buildOnce()

        // The store holds the latest snapshot and the transition event.
        let servicePersisterOptional = await service.persister
        let servicePersister = try XCTUnwrap(servicePersisterOptional)
        let store = servicePersister.store
        // Verbatim persistence: the stored payload decodes to the exact wire
        // form of the served snapshot (cadenceSeconds never re-stamped).
        let storedPayload = try XCTUnwrap(store.latestSnapshotPayload())
        let stored = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: Data(storedPayload.utf8))
        let servedWire = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: JSONEncoder().encode(second)
        )
        XCTAssertEqual(stored, servedWire)
        XCTAssertEqual(stored.cadenceSeconds, 1)
        XCTAssertEqual(stored.agents.first { $0.id == .claudeCode }?.status, .idle)

        let events = try store.events(for: .claudeCode)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, "status_changed")
        XCTAssertEqual(events.first?.fromStatus, "running")
        XCTAssertEqual(events.first?.toStatus, "idle")

        // The well-known file exists and matches the served snapshot's wire
        // form (dates are ms-truncated on the wire; compare decoded-to-decoded).
        let fileData = try Data(contentsOf: fixtureRoot.appendingPathComponent("fleet-snapshot.json"))
        let fileSnapshot = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: fileData)
        XCTAssertEqual(fileSnapshot, servedWire)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixtureRoot.appendingPathComponent("fleet-snapshot.json.tmp").path
            )
        )
    }

    // MARK: - Writer failure: RPC keeps serving, health degraded

    func testService_writerFailure_servedSnapshotDegraded_rpcKeepsServing() async throws {
        let (probes, _) = makeProbes(claudeStatus: .running, claudeConfidence: .exactProcess)
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes)
        let persister = try makePersister()
        let service = BurnBarFleetService(builder: builder, persister: persister)

        // First build succeeds: last-good file established.
        let good = try await service.buildOnce()
        XCTAssertEqual(good.persistenceHealth, .ok)
        let lastGoodData = try Data(contentsOf: fixtureRoot.appendingPathComponent("fleet-snapshot.json"))

        // Make the writer fail while the destination stays intact: a
        // read-only parent directory blocks the tmp write (EACCES) without
        // touching the last-good file.
        let fileURL = fixtureRoot.appendingPathComponent("fleet-snapshot.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixtureRoot.path)

        // The next build still completes and serves a fresh snapshot with
        // typed degraded persistenceHealth.
        let degraded = try await service.buildOnce()
        guard case .degraded(let reason) = degraded.persistenceHealth else {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRoot.path)
            return XCTFail("writer failure must degrade persistenceHealth, got \(degraded.persistenceHealth)")
        }
        XCTAssertTrue(reason.contains("fleet-snapshot.json write failed"), "unexpected reason: \(reason)")
        let servicePersisterOptional = await service.persister
        let servicePersister = try XCTUnwrap(servicePersisterOptional)
        XCTAssertEqual(servicePersister.persistenceHealth(), degraded.persistenceHealth)

        // The last-good file stays byte-identical and no .tmp litter remains.
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            lastGoodData,
            "last-good file must stay byte-identical while the writer is degraded"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixtureRoot.appendingPathComponent("fleet-snapshot.json.tmp").path
            ),
            "no .tmp litter after a failed write"
        )

        // The store still persists the latest snapshot (RPC truth is fresh).
        // Parity rule: the store row carries the SAME payload the RPC/file
        // serve for this generation — including the degraded
        // persistenceHealth. RPC, file, and sqlite never contradict each
        // other for the same generation.
        let storedPayload = try XCTUnwrap(servicePersister.store.latestSnapshotPayload())
        let stored = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: Data(storedPayload.utf8))
        let degradedWire = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: JSONEncoder().encode(degraded)
        )
        XCTAssertEqual(stored.persistenceHealth, degraded.persistenceHealth, "store row carries the served degraded health")
        XCTAssertEqual(stored, degradedWire, "store row is the exact served payload for this generation")
        XCTAssertEqual(stored.generatedAt, degradedWire.generatedAt)
        XCTAssertEqual(stored.cadenceSeconds, degraded.cadenceSeconds)
        XCTAssertEqual(stored.agents.first { $0.id == .claudeCode }?.status, .running)

        // Recovery: restore permissions; the next persist clears health and
        // the file is replaced atomically.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRoot.path)
        let recovered = try await service.buildOnce()
        XCTAssertEqual(recovered.persistenceHealth, .ok)
        let fileSnapshot = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        let recoveredWire = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: JSONEncoder().encode(recovered)
        )
        XCTAssertEqual(fileSnapshot, recoveredWire)
        _ = lastGoodData
    }

    // MARK: - RPC: daemon serves persistenceHealth + file == RPC payload

    func testRPC_snapshotServesPersistenceHealth_fileMatchesPayload() async throws {
        // Socket under /tmp: the temp fixture dir path can exceed the
        // sockaddr_un limit.
        let socketPath = "/tmp/burnbar-fleet-persist-rpc-\(UUID().uuidString).sock"
        let (probes, _) = makeProbes(claudeStatus: .running, claudeConfidence: .exactProcess)
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes)
        let service = BurnBarFleetService(builder: builder, persister: try makePersister())

        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath),
            fleetService: service
        )
        try await server.start()
        defer { Task { await server.stop() } }

        // Wait for the server's first completed tick so the RPC and
        // well-known file observe the same persisted generation. This also
        // keeps the CPU delta sample from racing the initial direct build.
        let snapshot = try await waitForSnapshot(socketPath: socketPath, timeout: 10)
        XCTAssertEqual(snapshot.persistenceHealth, .ok)
        XCTAssertEqual(snapshot.cadenceSeconds, 1)

        // File payload is field-for-field identical to the RPC payload.
        let fileData = try Data(contentsOf: fixtureRoot.appendingPathComponent("fleet-snapshot.json"))
        let fileSnapshot = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: fileData)
        XCTAssertEqual(fileSnapshot, snapshot)
    }

    // MARK: - Corruption window observable via RPC (VAL-HARD-012/013)

    func testRPC_corruptionRebuild_degradedOnFirstRecoverySnapshot_clearsOnNextPersist() async throws {
        let socketPath = "/tmp/burnbar-fleet-persist-rebuild-\(UUID().uuidString).sock"
        let (probes, _) = makeProbes(claudeStatus: .idle, claudeConfidence: .exactProcess)
        // A 5s cadence gives a wide, deterministic window between the first
        // published recovery snapshot and the next tick.
        let builder = BurnBarFleetSnapshotBuilder(cadenceSeconds: 5, probes: probes)

        // A corrupt store: plant garbage at the store path before the
        // persister opens it.
        let storeDir = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storePath = storeDir.appendingPathComponent("fleet.sqlite").path
        try Data("this is not a sqlite database".utf8).write(to: URL(fileURLWithPath: storePath))

        let store = BurnBarFleetStore(
            databasePath: storePath,
            eventRetentionSeconds: 3600,
            snapshotRetentionCount: 5
        )
        let writer = BurnBarFleetFileWriter(
            fileURL: fixtureRoot.appendingPathComponent("fleet-snapshot.json")
        )
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)
        let service = BurnBarFleetService(builder: builder, persister: persister)

        // The server opens the persister on start (corruption recovered
        // typed) and the ticker's first tick publishes the recovery snapshot.
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(socketPath: socketPath),
            fleetService: service
        )
        try await server.start()
        defer { Task { await server.stop() } }

        // Poll RPC until the first ready snapshot: it is the FIRST published
        // snapshot after the delete+recreate and must carry the degraded
        // rebuild health.
        let first = try await waitForSnapshot(socketPath: socketPath, timeout: 10)
        guard case .degraded(let reason) = first.persistenceHealth else {
            return XCTFail("first recovery snapshot must stay degraded, got \(first.persistenceHealth)")
        }
        XCTAssertTrue(reason.contains("rebuilt"), "unexpected reason: \(reason)")

        // The file and the store row carry the same degraded health for this
        // generation (parity rule).
        let fileSnapshot = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("fleet-snapshot.json"))
        )
        XCTAssertEqual(fileSnapshot.persistenceHealth, first.persistenceHealth, "file carries the degraded health")
        let stored = try XCTUnwrap(persister.store.latestSnapshot())
        XCTAssertEqual(stored.persistenceHealth, first.persistenceHealth, "store row carries the degraded health")

        // The next successful persist after that publication clears the
        // rebuild window: wait for the next tick (generatedAt advances).
        let second = try await waitForSnapshotAfter(
            socketPath: socketPath,
            after: first.generatedAt,
            timeout: 15
        )
        XCTAssertEqual(second.persistenceHealth, .ok, "rebuild degradation clears on the next successful persist")
    }

    // MARK: - Store deletion while the daemon remains running (VAL-HARD-018)

    func testRPC_storeDeletedWhileRunning_rebuildsTyped_andClearsDesignation() async throws {
        let socketPath = "/tmp/burnbar-fleet-persist-delete-live-\(UUID().uuidString).sock"
        let (probes, _) = makeProbes(claudeStatus: .idle, claudeConfidence: .exactProcess)
        let storeDir = fixtureRoot.appendingPathComponent("live-store", isDirectory: true)
        let storePath = storeDir.appendingPathComponent("fleet.sqlite").path
        let filePath = fixtureRoot.appendingPathComponent("fleet-snapshot.json").path
        let configuration = BurnBarDaemonConfiguration(
            socketPath: socketPath,
            fleetStorePath: storePath,
            fleetSnapshotFilePath: filePath
        )
        let store = BurnBarFleetStore(databasePath: storePath)
        let writer = BurnBarFleetFileWriter(fileURL: URL(fileURLWithPath: filePath))
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)
        let controlStore = BurnBarFleetControlStore(store: store)
        let service = BurnBarFleetService(
            builder: BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes),
            persister: persister,
            controlStore: controlStore
        )
        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let before = try await waitForSnapshot(socketPath: socketPath, timeout: 10)
        XCTAssertEqual(before.orchestrator.designation, .none)

        let designated = try await service.setOrchestratorState(
            BurnBarOrchestratorState(designation: .burnBarManaged)
        )
        XCTAssertEqual(designated.designation, .burnBarManaged)
        let designatedState = try await service.orchestratorStateChecked()
        XCTAssertEqual(designatedState.designation, .burnBarManaged)

        // Unlink only the configured database while the daemon's SQLite
        // connection is still open. The next tick must notice the path
        // identity change rather than writing the deleted inode.
        try FileManager.default.removeItem(atPath: storePath)

        let recovery = try await waitForSnapshot(
            socketPath: socketPath,
            timeout: 10,
            matching: { snapshot in
                if case .degraded(let reason) = snapshot.persistenceHealth {
                    return reason.contains("rebuilt")
                }
                return false
            }
        )
        guard case .degraded(let reason) = recovery.persistenceHealth else {
            return XCTFail("store deletion must expose typed degraded health")
        }
        XCTAssertTrue(reason.contains("orchestration history discarded"))
        XCTAssertEqual(recovery.orchestrator.designation, .none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storePath))

        let recovered = try await waitForSnapshotAfter(
            socketPath: socketPath,
            after: recovery.generatedAt,
            timeout: 10
        )
        XCTAssertEqual(recovered.persistenceHealth, .ok)
        XCTAssertEqual(recovered.orchestrator.designation, .none)
    }

    // MARK: - Read-only support directory (VAL-HARD-021)

    func testRPC_readOnlySupportDirectory_servesSnapshotWithPersistenceDegraded() async throws {
        let socketPath = "/tmp/burnbar-fleet-persist-readonly-\(UUID().uuidString).sock"
        let supportDirectory = fixtureRoot.appendingPathComponent("readonly-support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let configuration = BurnBarDaemonConfiguration(
            socketPath: socketPath,
            fleetStorePath: supportDirectory.appendingPathComponent("fleet.sqlite").path,
            fleetSnapshotFilePath: supportDirectory.appendingPathComponent("fleet-snapshot.json").path
        )
        let (probes, _) = makeProbes(claudeStatus: .idle, claudeConfidence: .exactProcess)
        let service = BurnBarFleetService(
            builder: BurnBarFleetSnapshotBuilder(cadenceSeconds: 1, probes: probes),
            persister: BurnBarFleetPersister(
                store: BurnBarFleetStore(databasePath: configuration.fleetStorePath),
                fileWriter: BurnBarFleetFileWriter(
                    fileURL: URL(fileURLWithPath: configuration.fleetSnapshotFilePath)
                )
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: supportDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: supportDirectory.path
            )
        }

        let server = BurnBarDaemonServer(configuration: configuration, fleetService: service)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let snapshot = try await waitForSnapshot(socketPath: socketPath, timeout: 10)
        guard case .degraded(let reason) = snapshot.persistenceHealth else {
            return XCTFail("read-only support dir must expose typed persistence degradation")
        }
        XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(snapshot.agents.count, BurnBarFleetAgentID.declaredRoster.count)
        XCTAssertFalse(
            snapshot.probeHealth.contains {
                if case .degraded(let probeReason) = $0.state {
                    return probeReason.localizedCaseInsensitiveContains("fleet.sqlite")
                        || probeReason.localizedCaseInsensitiveContains("fleet-snapshot.json")
                }
                return false
            },
            "persistence failures belong only in persistenceHealth"
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
        let recovered = try await waitForSnapshot(
            socketPath: socketPath,
            timeout: 10,
            matching: { $0.persistenceHealth == .ok }
        )
        XCTAssertEqual(recovered.persistenceHealth, .ok)
    }

    /// Polls `daemon.fleet.snapshot` until a ready snapshot is served.
    private func waitForSnapshot(
        socketPath: String,
        timeout: TimeInterval,
        matching: ((BurnBarFleetSnapshot) -> Bool)? = nil
    ) async throws -> BurnBarFleetSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = try? self.snapshotViaRPC(socketPath: socketPath),
               matching?(snapshot) ?? true {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BurnBarFleetTestTimeoutError.deadlineExceeded(
            operation: "persistence snapshot readiness poll",
            timeout: timeout
        )
    }

    /// Polls `daemon.fleet.snapshot` until a snapshot with a `generatedAt`
    /// strictly after `after` is served.
    private func waitForSnapshotAfter(
        socketPath: String,
        after: Date,
        timeout: TimeInterval
    ) async throws -> BurnBarFleetSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = try? self.snapshotViaRPC(socketPath: socketPath),
               snapshot.generatedAt > after {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BurnBarFleetTestTimeoutError.deadlineExceeded(
            operation: "persistence newer snapshot poll after \(after)",
            timeout: timeout
        )
    }

    /// One `daemon.fleet.snapshot` RPC round-trip returning the served
    /// snapshot (nil when the not-ready error is still returned).
    private func snapshotViaRPC(socketPath: String) throws -> BurnBarFleetSnapshot? {
        let response: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "poll",
                method: .fleetSnapshot,
                params: BurnBarFleetSnapshotRequest()
            ),
            socketPath: socketPath
        )
        return response.result?.snapshot
    }

    // MARK: - Socket helper (mirrors BurnBarFleetServerRPCTests)

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        try sendFleetEnvelope(envelope, socketPath: socketPath)
    }
}

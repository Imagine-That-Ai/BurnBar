import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Recovery/parity regression tests for the persistence layer (scrutiny
/// round 1, daemon-fleet-persistence):
/// - the corruption-rebuild degradation stays visible on the FIRST published
///   snapshot after a delete+recreate (RPC + file + store row) and clears
///   only on the next successful persist after that publication;
/// - a failed persist never advances the transition baseline, so a later
///   running-to-idle transition is never lost across a failure.
final class BurnBarFleetPersistenceRecoveryTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-persist-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var storeURL: URL {
        fixtureRoot.appendingPathComponent("fleet.sqlite")
    }

    private var snapshotFileURL: URL {
        fixtureRoot.appendingPathComponent("fleet-snapshot.json")
    }

    private func makeStore(
        eventRetentionSeconds: TimeInterval = BurnBarFleetPersistenceConstants.defaultEventRetentionSeconds
    ) throws -> BurnBarFleetStore {
        let store = BurnBarFleetStore(
            databasePath: storeURL.path,
            eventRetentionSeconds: eventRetentionSeconds,
            snapshotRetentionCount: 5
        )
        _ = try store.open()
        return store
    }

    /// A minimal but valid snapshot with the full ten-row roster.
    private func makeSnapshot(
        generatedAt: Date,
        cadenceSeconds: Int = 15,
        claudeStatus: BurnBarFleetAgentStatus = .unknown,
        claudeConfidence: BurnBarFleetConfidence = .unsupported,
        persistenceHealth: BurnBarFleetPersistenceHealth = .ok
    ) throws -> BurnBarFleetSnapshot {
        var agents: [BurnBarFleetAgent] = []
        var probeHealth: [BurnBarFleetProbeHealth] = []
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let isClaude = agentID == .claudeCode
            let status = isClaude ? claudeStatus : .unknown
            let confidence = isClaude ? claudeConfidence : .unsupported
            agents.append(
                BurnBarFleetAgent(
                    id: agentID,
                    displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
                    status: status,
                    confidence: confidence,
                    projectName: isClaude ? "/Users/test/RepoA" : nil
                )
            )
            probeHealth.append(
                BurnBarFleetProbeHealth(
                    agent: agentID,
                    state: .ok,
                    rootPath: "/fixture/\(BurnBarFleetRootResolver.rootDirectoryName(for: agentID))",
                    checkedAt: generatedAt
                )
            )
        }
        let runningCount = agents.filter { $0.status == .running }.count
        var countsByAgent: [String: Int] = [:]
        for agent in agents {
            countsByAgent[agent.id.wireValue] = agent.status == .running ? 1 : 0
        }
        return try BurnBarFleetSnapshot(
            schemaVersion: BurnBarFleetSnapshot.currentSchemaVersion,
            generatedAt: generatedAt,
            cadenceSeconds: cadenceSeconds,
            machine: BurnBarMachineStatus(
                memoryTotalBytes: 1_000_000,
                thermal: .unavailable(reason: "no thermal API"),
                power: .unavailable(reason: "no power API")
            ),
            agents: agents,
            repos: BurnBarFleetSnapshotBuilder.deriveRepoGroups(from: agents),
            runningCount: runningCount,
            countsByAgent: countsByAgent,
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: probeHealth,
            persistenceHealth: persistenceHealth
        ).validateConsistency()
    }

    // MARK: - Corruption rebuild window (VAL-HARD-012/013)

    func testStore_rebuildWindow_visibleOnFirstPublishedSnapshot_clearsOnNextPersist() async throws {
        // Plant garbage at the store path.
        try Data("this is not a sqlite database".utf8).write(to: storeURL)

        let store = BurnBarFleetStore(databasePath: storeURL.path)
        let health = try store.open()
        guard case .degraded = health else {
            return XCTFail("corrupt store must degrade typed, got \(health)")
        }

        let writer = BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)
        let now = Date()

        // First persist publishes the recovery snapshot: the degraded rebuild
        // health must be visible on the served snapshot AND in the file AND
        // in the store row (parity rule) — it must NOT clear on this persist.
        let first = persister.persist(
            snapshot: try makeSnapshot(generatedAt: now, claudeStatus: .idle, claudeConfidence: .exactProcess)
        )
        guard case .degraded(let firstReason) = first.persistenceHealth else {
            return XCTFail("first recovery snapshot must stay degraded, got \(first.persistenceHealth)")
        }
        XCTAssertTrue(firstReason.contains("rebuilt"), "unexpected reason: \(firstReason)")

        let fileSnapshot = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: Data(contentsOf: snapshotFileURL)
        )
        XCTAssertEqual(fileSnapshot.persistenceHealth, first.persistenceHealth, "file carries the degraded health")
        let stored = try XCTUnwrap(store.latestSnapshot())
        XCTAssertEqual(stored.persistenceHealth, first.persistenceHealth, "store row carries the degraded health")

        // The next successful persist after that publication clears the
        // rebuild window.
        let second = persister.persist(
            snapshot: try makeSnapshot(
                generatedAt: now.addingTimeInterval(15),
                claudeStatus: .idle,
                claudeConfidence: .exactProcess
            )
        )
        XCTAssertEqual(second.persistenceHealth, .ok, "rebuild degradation clears on the next successful persist")
        let storedAfter = try XCTUnwrap(store.latestSnapshot())
        XCTAssertEqual(storedAfter.persistenceHealth, .ok)
    }

    // MARK: - Failed persist never advances the transition baseline

    func testPersister_failedPersist_doesNotAdvanceBaseline_noEventLost() async throws {
        let store = try makeStore()
        let writer = BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)
        let now = Date()

        // Baseline: running.
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: now, claudeStatus: .running, claudeConfidence: .exactProcess)
        )
        XCTAssertEqual(try store.events(for: .claudeCode).count, 0)

        // The store becomes unavailable (closed): the next persist fails and
        // the baseline must NOT advance to the unpersisted idle snapshot.
        store.close()
        let failed = persister.persist(
            snapshot: try makeSnapshot(
                generatedAt: now.addingTimeInterval(15),
                claudeStatus: .idle,
                claudeConfidence: .exactProcess
            )
        )
        guard case .degraded(let reason) = failed.persistenceHealth else {
            return XCTFail("failed persist must degrade typed, got \(failed.persistenceHealth)")
        }
        XCTAssertTrue(reason.contains("fleet.sqlite snapshot write failed"), "unexpected reason: \(reason)")
        XCTAssertEqual(
            persister.lastPersisted?.agents.first { $0.id == .claudeCode }?.status,
            .running,
            "the baseline stays at the last successfully persisted snapshot"
        )

        // Reopen the store and persist idle again: the running -> idle event
        // is recorded — it was never lost across the failure.
        _ = try store.open()
        _ = persister.persist(
            snapshot: try makeSnapshot(
                generatedAt: now.addingTimeInterval(30),
                claudeStatus: .idle,
                claudeConfidence: .exactProcess
            )
        )

        let events = try store.events(for: .claudeCode)
        XCTAssertEqual(events.count, 1, "the running->idle transition is recorded after recovery")
        XCTAssertEqual(events.first?.kind, "status_changed")
        XCTAssertEqual(events.first?.fromStatus, "running")
        XCTAssertEqual(events.first?.toStatus, "idle")
    }
}

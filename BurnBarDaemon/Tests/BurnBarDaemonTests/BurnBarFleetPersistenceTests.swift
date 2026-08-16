import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import GRDB
import XCTest

/// Persistence-layer tests: fleet.sqlite store (snapshots + fixed-row
/// transition events + retention seam + rebuild), atomic well-known-file
/// writer, and the persister's `persistenceHealth` surfacing.
final class BurnBarFleetPersistenceTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-persistence-\(UUID().uuidString)", isDirectory: true)
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

    /// A minimal but valid snapshot with the full ten-row roster. Uses a
    /// fixed millisecond-precision date so ISO-8601 round-trips are exact.
    private func makeSnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_752_000_000),
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

    // MARK: - VAL-FLEET-011: store persists latest snapshot + fixed-row events

    func testStore_persistsLatestSnapshotVerbatim() async throws {
        let store = try makeStore()
        let snapshot = try makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_752_000_000), cadenceSeconds: 7)

        _ = try store.persistLatestSnapshot(snapshot)

        let stored = try XCTUnwrap(store.latestSnapshot())
        XCTAssertEqual(stored, snapshot, "stored snapshot must equal the persisted snapshot field-for-field")
        XCTAssertEqual(stored.cadenceSeconds, 7, "cadenceSeconds must be persisted verbatim, never re-stamped")
        XCTAssertEqual(stored.generatedAt, snapshot.generatedAt)
        XCTAssertEqual(stored.agents.count, 10)
    }

    func testStore_boundsSQLitePageCacheForRSSStability() async throws {
        let store = try makeStore()

        let configuredCacheKiB = try await store.queue!.read { db in
            try Int.fetchOne(db, sql: "PRAGMA cache_size")
        }

        XCTAssertEqual(
            configuredCacheKiB,
            -BurnBarFleetPersistenceConstants.sqlitePageCacheKiB,
            "fleet persistence must bound SQLite's page cache so retained snapshots do not look like an RSS leak"
        )
    }

    func testStore_recordsStatusChangedEventWithExactFromTo() async throws {
        let store = try makeStore()
        let persister = BurnBarFleetPersister(
            store: store,
            fileWriter: BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        )
        // Timestamps are relative to real now so the events stay inside the
        // retention window (pruning runs in the same transaction as the
        // insert — an event older than the cutoff is pruned immediately).
        let now = Date()
        let t0 = now
        let t1 = now.addingTimeInterval(15)

        // First persist: no prior state, no events.
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t0, claudeStatus: .running, claudeConfidence: .exactProcess)
        )
        XCTAssertEqual(try store.events(for: .claudeCode).count, 0, "first persist records no transitions")

        // Second persist: running -> idle is a status change.
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t1, claudeStatus: .idle, claudeConfidence: .exactProcess)
        )

        let events = try store.events(for: .claudeCode)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, "status_changed")
        XCTAssertEqual(event.fromStatus, "running")
        XCTAssertEqual(event.toStatus, "idle")
        // The event timestamp round-trips through the REAL column; compare
        // with sub-millisecond tolerance.
        XCTAssertEqual(event.at.timeIntervalSince1970, t1.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(event.detail?.contains("status: running -> idle") == true)
    }

    func testStore_recordsConfidenceChangedEventWithExactFromTo() async throws {
        let store = try makeStore()
        let persister = BurnBarFleetPersister(
            store: store,
            fileWriter: BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        )
        let now = Date()
        let t0 = now
        let t1 = now.addingTimeInterval(15)

        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t0, claudeStatus: .running, claudeConfidence: .exactProcess)
        )
        // running -> stale with confidence downgrade: both events recorded.
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t1, claudeStatus: .stale, claudeConfidence: .activeSessionFile)
        )

        let events = try store.events(for: .claudeCode)
        XCTAssertEqual(events.count, 2)
        let statusEvent = try XCTUnwrap(events.first { $0.kind == "status_changed" })
        XCTAssertEqual(statusEvent.fromStatus, "running")
        XCTAssertEqual(statusEvent.toStatus, "stale")
        let confidenceEvent = try XCTUnwrap(events.first { $0.kind == "confidence_changed" })
        XCTAssertEqual(confidenceEvent.fromStatus, "exactProcess")
        XCTAssertEqual(confidenceEvent.toStatus, "activeSessionFile")
        XCTAssertTrue(confidenceEvent.detail?.contains("confidence: exactProcess -> activeSessionFile") == true)
    }

    func testStore_noEventsWhenNothingChanges() async throws {
        let store = try makeStore()
        let persister = BurnBarFleetPersister(
            store: store,
            fileWriter: BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        )
        let t0 = Date(timeIntervalSince1970: 1_752_000_000)

        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t0, claudeStatus: .idle, claudeConfidence: .exactProcess)
        )
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t0.addingTimeInterval(15), claudeStatus: .idle, claudeConfidence: .exactProcess)
        )

        XCTAssertEqual(try store.events(for: .claudeCode).count, 0)
    }

    func testStore_fixedRosterRowsNeverDisappear() async throws {
        let store = try makeStore()
        let snapshot = try makeSnapshot()
        _ = try store.persistLatestSnapshot(snapshot)

        // The stored snapshot keeps all ten rows; no appeared/disappeared
        // events exist for the fixed-roster model.
        let stored = try XCTUnwrap(store.latestSnapshot())
        XCTAssertEqual(stored.agents.count, 10)
        XCTAssertEqual(Set(stored.agents.map(\.id)), Set(BurnBarFleetAgentID.declaredRoster))
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let events = try store.events(for: agentID)
            XCTAssertFalse(events.contains { $0.kind == "appeared" || $0.kind == "disappeared" })
        }
    }

    // MARK: - VAL-FLEET-020: retention seam

    func testStore_retentionPrunesOnlyOlderEvents() async throws {
        // 60-second retention window. Timestamps are relative to real now so
        // the pruning cutoff (now - retention) lands between the events.
        let store = try makeStore(eventRetentionSeconds: 60)
        let persister = BurnBarFleetPersister(
            store: store,
            fileWriter: BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        )
        let now = Date()
        let t0 = now.addingTimeInterval(-120) // running (baseline, no event)
        let t1 = now.addingTimeInterval(-30) // idle (inside the window)
        let t2 = now.addingTimeInterval(-5) // stale (inside the window)

        // running -> idle at t1: the t0 baseline records nothing; the t1
        // event (30s old) is inside the 60s window and survives.
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t0, claudeStatus: .running, claudeConfidence: .exactProcess)
        )
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t1, claudeStatus: .idle, claudeConfidence: .exactProcess)
        )
        XCTAssertEqual(try store.events(for: .claudeCode).count, 1)

        // idle -> stale at t2: both events are inside the window at this
        // persist (pruning runs in the same transaction as the insert).
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t2, claudeStatus: .stale, claudeConfidence: .exactProcess)
        )
        XCTAssertEqual(try store.events(for: .claudeCode).count, 2)

        // Boundary via the retention seam: advance the clock past the t1
        // event (t1 + 61s > t1 + 60s window) — only the older event is
        // pruned; the t2 event survives.
        _ = try store.pruneEvents(olderThan: 60, now: t1.addingTimeInterval(61))

        let events = try store.events(for: .claudeCode)
        XCTAssertEqual(events.count, 1, "only the event inside the retention window survives")
        let surviving = try XCTUnwrap(events.first)
        XCTAssertEqual(surviving.kind, "status_changed")
        XCTAssertEqual(surviving.fromStatus, "idle")
        XCTAssertEqual(surviving.toStatus, "stale")
    }

    func testStore_eventOlderThanCutoffAtInsert_prunedImmediately() async throws {
        // Atomic insert+prune: an event whose timestamp is already beyond the
        // wall-clock retention cutoff is pruned in the SAME transaction that
        // inserts it — it never survives even one persist (the reviewer's
        // prune-before-insert ordering bug is fixed).
        let store = try makeStore(eventRetentionSeconds: 60)
        let persister = BurnBarFleetPersister(
            store: store,
            fileWriter: BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        )
        let now = Date()
        let t0 = now.addingTimeInterval(-120) // running (baseline)
        let t1 = now.addingTimeInterval(-90) // idle (older than the 60s window)

        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t0, claudeStatus: .running, claudeConfidence: .exactProcess)
        )
        _ = persister.persist(
            snapshot: try makeSnapshot(generatedAt: t1, claudeStatus: .idle, claudeConfidence: .exactProcess)
        )

        XCTAssertEqual(
            try store.events(for: .claudeCode).count,
            0,
            "an event older than the retention cutoff at insert time is pruned immediately"
        )
    }

    func testStore_retentionOverrideSeamParsesEnvironment() {
        let resolved = BurnBarDaemonConfiguration.resolveEventRetentionSeconds(
            environment: ["BURNBAR_FLEET_EVENT_RETENTION_SECONDS": "30"]
        )
        XCTAssertEqual(resolved, 30)
        let invalid = BurnBarDaemonConfiguration.resolveEventRetentionSeconds(
            environment: ["BURNBAR_FLEET_EVENT_RETENTION_SECONDS": "not-a-number"]
        )
        XCTAssertEqual(invalid, BurnBarFleetPersistenceConstants.defaultEventRetentionSeconds)
        let absent = BurnBarDaemonConfiguration.resolveEventRetentionSeconds(environment: [:])
        XCTAssertEqual(absent, BurnBarFleetPersistenceConstants.defaultEventRetentionSeconds)
    }

    // MARK: - VAL-FLEET-012: atomic file-writer hygiene

    func testFileWriter_writesValidJSON_noTmpLitter() async throws {
        let writer = BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        let snapshot = try makeSnapshot(cadenceSeconds: 3)

        try writer.write(snapshot: snapshot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotFileURL.path))
        let data = try Data(contentsOf: snapshotFileURL)
        let decoded = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot, "file payload must equal the written snapshot field-for-field")
        XCTAssertEqual(decoded.cadenceSeconds, 3)

        // No .tmp litter after a completed write.
        let tmpPath = fixtureRoot.appendingPathComponent("fleet-snapshot.json.tmp").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpPath), "no .tmp file may remain after a write")
    }

    func testFileWriter_atomicReplace_neverPartial() async throws {
        let writer = BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        let first = try makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_752_000_000))
        let second = try makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_752_000_100))

        try writer.write(snapshot: first)
        try writer.write(snapshot: second)

        // The destination is always a complete file: the second write replaced
        // the first atomically.
        let data = try Data(contentsOf: snapshotFileURL)
        let decoded = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)
        XCTAssertEqual(decoded.generatedAt, second.generatedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporaryURL.path))
    }

    // MARK: - VAL-FLEET-021: writer failure -> persistenceHealth degraded, RPC keeps serving

    func testPersister_writerFailure_degradesHealth_lastGoodFileByteIdentical() async throws {
        // The store lives in a subdirectory so the read-only injection below
        // only blocks the file writer, not the SQLite store.
        let storeDir = fixtureRoot.appendingPathComponent("store", isDirectory: true)
        let store = BurnBarFleetStore(
            databasePath: storeDir.appendingPathComponent("fleet.sqlite").path,
            eventRetentionSeconds: 3600,
            snapshotRetentionCount: 5
        )
        _ = try store.open()
        let writer = BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)

        // First persist succeeds: last-good file established.
        let goodSnapshot = try makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_752_000_000))
        let servedGood = persister.persist(snapshot: goodSnapshot)
        XCTAssertEqual(servedGood.persistenceHealth, .ok)
        let lastGoodData = try Data(contentsOf: snapshotFileURL)

        // Make the writer fail while the destination stays intact: a
        // read-only parent directory blocks the tmp write (EACCES) without
        // touching the last-good file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixtureRoot.path)

        let failingSnapshot = try makeSnapshot(generatedAt: Date(timeIntervalSince1970: 1_752_000_100))
        let servedFailing = persister.persist(snapshot: failingSnapshot)

        // Typed degradation with a non-empty writer reason.
        guard case .degraded(let reason) = servedFailing.persistenceHealth else {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRoot.path)
            return XCTFail("writer failure must degrade persistenceHealth, got \(servedFailing.persistenceHealth)")
        }
        XCTAssertTrue(reason.contains("fleet-snapshot.json write failed"), "unexpected reason: \(reason)")
        XCTAssertEqual(persister.persistenceHealth(), servedFailing.persistenceHealth)

        // The last-good file stays byte-identical and no .tmp litter remains.
        XCTAssertEqual(try Data(contentsOf: snapshotFileURL), lastGoodData, "last-good file must stay byte-identical")
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporaryURL.path), "no .tmp litter after failure")

        // The store still persists the latest snapshot (RPC truth is fresh).
        XCTAssertEqual(try store.latestSnapshot()?.generatedAt, failingSnapshot.generatedAt)

        // Recovery: restore permissions; the next persist clears health and
        // the file is replaced atomically.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRoot.path)
        let recovered = persister.persist(snapshot: failingSnapshot)
        XCTAssertEqual(recovered.persistenceHealth, .ok)
        let fileSnapshot = try JSONDecoder().decode(
            BurnBarFleetSnapshot.self,
            from: Data(contentsOf: snapshotFileURL)
        )
        XCTAssertEqual(fileSnapshot, recovered)
    }

    // MARK: - Store rebuild (VAL-HARD-012/013)

    func testStore_corruptDatabase_rebuildsTyped_neverCrashes() async throws {
        // Plant garbage at the store path.
        try Data("this is not a sqlite database".utf8).write(to: storeURL)

        let store = BurnBarFleetStore(databasePath: storeURL.path)
        let health = try store.open()

        guard case .degraded(let reason) = health else {
            return XCTFail("corrupt store must degrade typed, got \(health)")
        }
        XCTAssertTrue(reason.contains("rebuilt"), "unexpected reason: \(reason)")

        // The rebuilt store works: schema tables exist and persistence succeeds.
        let snapshot = try makeSnapshot()
        _ = try store.persistLatestSnapshot(snapshot)
        XCTAssertEqual(try store.latestSnapshot(), snapshot)
        XCTAssertEqual(try store.orchestratorStateRowCount(), 0)
        XCTAssertEqual(try store.directiveRowCount(), 0)
    }

    func testStore_schemaOnlyTables_exist() async throws {
        let store = try makeStore()
        _ = try store.persistLatestSnapshot(try makeSnapshot())

        // Read-only schema inspection through GRDB.
        let queue = try DatabaseQueue(path: storeURL.path)
        let tables = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                .compactMap { $0["name"] as String }
        }
        for expected in ["fleet_snapshots", "fleet_events", "orchestrator_state", "fleet_directives"] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected); got \(tables)")
        }
    }

    // MARK: - Persister integration: verbatim payload + file == served snapshot

    func testPersister_servedSnapshotMatchesFilePayload() async throws {
        let store = try makeStore()
        let writer = BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)

        let snapshot = try makeSnapshot(cadenceSeconds: 5)
        let served = persister.persist(snapshot: snapshot)

        // The served snapshot (what RPC returns) and the file payload are
        // field-for-field identical (VAL-API-004).
        let fileData = try Data(contentsOf: snapshotFileURL)
        let fileSnapshot = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: fileData)
        XCTAssertEqual(fileSnapshot, served)
        XCTAssertEqual(fileSnapshot.cadenceSeconds, 5)
        XCTAssertEqual(fileSnapshot.persistenceHealth, .ok)
    }

    func testPersister_transitionBaseline_survivesRestart() async throws {
        let store = try makeStore()
        let writer = BurnBarFleetFileWriter(fileURL: snapshotFileURL)
        let persister = BurnBarFleetPersister(store: store, fileWriter: writer)

        // Timestamps relative to real now so the transition event stays
        // inside the default 24h retention window.
        let now = Date()
        let t0 = now
        _ = persister.persist(snapshot: try makeSnapshot(generatedAt: t0, claudeStatus: .running, claudeConfidence: .exactProcess))
        XCTAssertEqual(try store.events(for: .claudeCode).count, 0)

        // Simulate a daemon restart: a new persister loads the baseline from
        // the store, so the next persist records the transition.
        let restarted = BurnBarFleetPersister(store: store, fileWriter: writer)
        restarted.loadLastPersistedSnapshot()
        _ = restarted.persist(snapshot: try makeSnapshot(
            generatedAt: t0.addingTimeInterval(15),
            claudeStatus: .idle,
            claudeConfidence: .exactProcess
        ))

        let events = try store.events(for: .claudeCode)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, "status_changed")
        XCTAssertEqual(events.first?.fromStatus, "running")
        XCTAssertEqual(events.first?.toStatus, "idle")
    }
}

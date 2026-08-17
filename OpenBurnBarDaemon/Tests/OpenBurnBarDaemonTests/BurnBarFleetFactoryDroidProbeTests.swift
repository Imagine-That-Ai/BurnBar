import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarFleetFactoryDroidProbeTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-factory-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private func makeProbe(freshnessSeconds: TimeInterval = 300) -> BurnBarFleetFactoryDroidProbe {
        BurnBarFleetFactoryDroidProbe(agentID: .factoryDroid, rootPath: fixtureRoot.path, freshnessSeconds: freshnessSeconds)
    }

    private func writeLedger(_ invocations: [[String: Any]]) throws {
        try writeJSONFixture(["invocations": invocations], to: fixtureRoot.appendingPathComponent("task-invocations.json").path)
    }

    private func writeBackgroundProcesses(_ processes: [[String: Any]]) throws {
        try writeJSONFixture(["processes": processes], to: fixtureRoot.appendingPathComponent("background-processes.json").path)
    }

    private func makeInvocation(
        status: String,
        updatedAt: Date,
        cwd: String = "/Users/test/RepoA"
    ) -> [String: Any] {
        [
            "taskInvocationId": UUID().uuidString,
            "status": status,
            "cwd": cwd,
            "createdAt": Int(updatedAt.timeIntervalSince1970 * 1000),
            "updatedAt": Int(updatedAt.timeIntervalSince1970 * 1000)
        ]
    }

    // MARK: - VAL-FLEET-014: happy path — non-terminal fresh invocation

    func testNonTerminalFreshInvocation_runningActiveSessionFile() async throws {
        let now = Date()
        try writeLedger([
            makeInvocation(status: "running", updatedAt: now.addingTimeInterval(-30), cwd: "/Users/test/RepoA")
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoA")
        XCTAssertNil(result.agent.process, "factory-droid never carries a process block (no pid registry)")
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertTrue(
            result.agent.signals.contains { $0.kind == "task-ledger" },
            "task-ledger evidence must be present"
        )
        XCTAssertTrue(
            result.agent.signals.contains { $0.kind == "root-presence" },
            "installed-root evidence must be present"
        )
    }

    func testTerminalInvocationFresh_notRunning() async throws {
        let now = Date()
        try writeLedger([
            makeInvocation(status: "completed", updatedAt: now.addingTimeInterval(-30), cwd: "/Users/test/RepoA")
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
    }

    // MARK: - VAL-FLEET-014: stale signals → non-running

    func testStaleInvocation_staleRow() async throws {
        let now = Date()
        try writeLedger([
            makeInvocation(status: "running", updatedAt: now.addingTimeInterval(-600), cwd: "/Users/test/RepoA")
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
    }

    // MARK: - VAL-FLEET-014: artifacts exclusion

    func testArtifactsSentinel_neverInfluencesRow() async throws {
        let now = Date()
        // Plant a fresh sentinel file under artifacts/ — the probe must never
        // read it, and its freshness must not influence the row.
        let artifactsDir = fixtureRoot.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        let sentinelPath = artifactsDir.appendingPathComponent("sentinel.txt").path
        try "ARTIFACTS-SENTINEL-\(UUID().uuidString)".write(toFile: sentinelPath, atomically: true, encoding: .utf8)
        try setFileMtime(now.addingTimeInterval(-1), at: sentinelPath)

        // No other signals: the row must be non-running despite the fresh
        // artifacts content.
        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertFalse(
            result.agent.signals.contains { $0.path.contains("artifacts") },
            "artifacts paths must never appear in signal evidence"
        )
        XCTAssertEqual(
            result.agent.note?.contains("ARTIFACTS-SENTINEL"),
            false,
            "artifacts content must never leak into the row"
        )
    }

    func testArtifactsSentinel_doesNotMaskStaleLedger() async throws {
        let now = Date()
        try writeLedger([
            makeInvocation(status: "running", updatedAt: now.addingTimeInterval(-600), cwd: "/Users/test/RepoA")
        ])
        let artifactsDir = fixtureRoot.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        let sentinelPath = artifactsDir.appendingPathComponent("sentinel.txt").path
        try "ARTIFACTS-SENTINEL-\(UUID().uuidString)".write(toFile: sentinelPath, atomically: true, encoding: .utf8)
        try setFileMtime(now.addingTimeInterval(-1), at: sentinelPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertFalse(result.agent.signals.contains { $0.path.contains("artifacts") })
    }

    func testSymlinkedSessionDescendantIntoArtifacts_isRejectedAndNeverTraversed() async throws {
        let now = Date()
        let artifactsDirectory = fixtureRoot
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("escaped-session", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
        try writeJSONFixture(
            ["invocations": [[
                "status": "running",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000),
                "cwd": "/Users/secret/artifacts"
            ]]],
            to: artifactsDirectory.appendingPathComponent("task-invocations.json").path
        )

        let sessionsDirectory = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: sessionsDirectory.appendingPathComponent("escaped-artifact-session").path,
            withDestinationPath: "../artifacts/escaped-session"
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertFalse(result.agent.signals.contains { $0.path.contains("artifacts") })
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("symlink"), "unexpected reason: \(reason)")
        } else {
            XCTFail("symlink descendant must produce typed degraded health, got \(result.health.state)")
        }
    }

    // MARK: - VAL-FLEET-022: alternate signals

    func testBackgroundProcessLiveEntry_running() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoB")
        XCTAssertTrue(
            result.agent.signals.contains { $0.kind == "process-list" },
            "process-list evidence must be present"
        )
        XCTAssertTrue(
            result.agent.signals.contains { $0.kind == "root-presence" },
            "installed-root evidence must be present"
        )
    }

    func testBackgroundProcessDeadEntry_notRunning() async throws {
        let now = Date()
        try writeBackgroundProcesses([
            [
                "pid": 999_999,
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
    }

    func testSessionDirectoryFreshMtime_running() async throws {
        let now = Date()
        let sessionDir = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("-Users-test-RepoC", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try setFileMtime(now.addingTimeInterval(-60), at: sessionDir.path)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoC", "session-dir slug must decode to the repo path")
        XCTAssertTrue(
            result.agent.signals.contains { $0.kind == "session-directory" },
            "session-directory evidence must be present"
        )
        XCTAssertTrue(
            result.agent.signals.contains { $0.kind == "root-presence" },
            "installed-root evidence must be present"
        )
    }

    func testSessionDirectoryStaleMtime_notRunning() async throws {
        let now = Date()
        let sessionDir = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("-Users-test-RepoC", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try setFileMtime(now.addingTimeInterval(-600), at: sessionDir.path)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
    }

    func testMissionDirectoryFreshMtime_running() async throws {
        let now = Date()
        let missionDir = fixtureRoot.appendingPathComponent("missions", isDirectory: true)
            .appendingPathComponent("mission-1", isDirectory: true)
        try FileManager.default.createDirectory(at: missionDir, withIntermediateDirectories: true)
        try setFileMtime(now.addingTimeInterval(-60), at: missionDir.path)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
    }

    // MARK: - VAL-FLEET-022: stale transition

    func testSessionDirectoryMtimeMovedOutsideWindow_flipsNonRunning() async throws {
        let now = Date()
        let sessionDir = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("-Users-test-RepoC", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try setFileMtime(now.addingTimeInterval(-60), at: sessionDir.path)

        let fresh = await makeProbe().probe(now: now)
        XCTAssertEqual(fresh.agent.status, .running)

        try setFileMtime(now.addingTimeInterval(-600), at: sessionDir.path)
        let stale = await makeProbe().probe(now: now)
        XCTAssertNotEqual(stale.agent.status, .running)
        XCTAssertEqual(stale.agent.status, .stale)
    }

    // MARK: - VAL-FLEET-024: malformed shape isolation

    func testMalformedInvocation_missingStatus_typedNeverRunning() async throws {
        let now = Date()
        try writeLedger([
            [
                "taskInvocationId": "t1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed shape must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedInvocation_mistypedUpdatedAt_typedNeverRunning() async throws {
        let now = Date()
        try writeLedger([
            [
                "taskInvocationId": "t1",
                "status": "running",
                "cwd": "/Users/test/RepoA",
                "updatedAt": "not-a-number"
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("malformed shape must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedLedger_siblingAlternateSignalStillDrivesRow() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // Malformed ledger (missing status) + live background entry.
        try writeLedger([
            [
                "taskInvocationId": "t1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeProbe().probe(now: now)

        // The alternate path drives the row; the malformed ledger only
        // degrades the health state.
        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoB")
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed ledger must surface a typed degraded health, got \(result.health.state)")
        }
    }

    func testMalformedBackgroundEntry_missingPid_typedNeverRunning() async throws {
        let now = Date()
        try writeBackgroundProcesses([
            [
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("malformed shape must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - Absent root / no signals

    func testRootMissing_failedHealth() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path
        let result = await BurnBarFleetFactoryDroidProbe(agentID: .factoryDroid, rootPath: missingRoot).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
    }

    func testRootPresentNoSignals_idle() async throws {
        let now = Date()
        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Slug decode

    func testSlugDecode_variants() {
        XCTAssertEqual(BurnBarFleetFactoryDroidProbe.slugDecode("-Users-albertonunez-Developer-AgentLens"), "/Users/albertonunez/Developer/AgentLens")
        XCTAssertEqual(BurnBarFleetFactoryDroidProbe.slugDecode("-Users-test"), "/Users/test")
        XCTAssertEqual(BurnBarFleetFactoryDroidProbe.slugDecode("plain-name"), "plain-name")
        XCTAssertNil(BurnBarFleetFactoryDroidProbe.slugDecode("-"))
    }
}

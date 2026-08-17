import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarFleetClaudeCodeProbeTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-claude-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var sessionsDirectory: URL {
        fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    private func makeProbe(freshnessSeconds: TimeInterval = 120) -> BurnBarFleetClaudeCodeProbe {
        BurnBarFleetClaudeCodeProbe(agentID: .claudeCode, rootPath: fixtureRoot.path, freshnessSeconds: freshnessSeconds)
    }

    private func writeSession(
        pid: Int,
        updatedAt: Date,
        startedAt: Date? = nil,
        cwd: String = "/Users/test/RepoA",
        fileName: String? = nil
    ) throws -> String {
        let name = fileName ?? "\(pid).json"
        let path = sessionsDirectory.appendingPathComponent(name).path
        // When no startedAt is given, use the process's real start time so
        // the pid-reuse guard (file startedAt vs process start) passes for
        // genuinely live pids.
        let resolvedStartedAt: Date?
        if let startedAt {
            resolvedStartedAt = startedAt
        } else if let realStart = BurnBarFleetProcessLiveness.processStartTime(pid: pid) {
            resolvedStartedAt = Date(timeIntervalSince1970: realStart)
        } else {
            resolvedStartedAt = nil
        }
        var object: [String: Any] = [
            "pid": pid,
            "sessionId": "session-\(pid)",
            "cwd": cwd,
            "status": "shell",
            "updatedAt": Int(updatedAt.timeIntervalSince1970 * 1000)
        ]
        if let resolvedStartedAt {
            object["startedAt"] = Int(resolvedStartedAt.timeIntervalSince1970 * 1000)
        }
        try writeJSONFixture(object, to: path)
        return path
    }

    // MARK: - VAL-FLEET-001: live pid → running + exactProcess

    func testLivePidFreshUpdatedAt_runningExactProcess() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // Whole-millisecond timestamps: epoch-ms round-trips exactly.
        let updatedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 10)
        let path = try writeSession(pid: Int(live.pid), updatedAt: updatedAt)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoA")
        // Epoch-ms round-trip: sub-millisecond precision is truncated.
        XCTAssertEqual(
            result.agent.lastActivityAt?.timeIntervalSince1970 ?? 0,
            updatedAt.timeIntervalSince1970,
            accuracy: 0.01
        )
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.map(\.path), [path])
        XCTAssertEqual(result.agent.signals.first?.kind, "session-registry")
    }

    // MARK: - VAL-FLEET-002: dead pid never running

    func testDeadPid_neverRunning_confidenceDowngraded() async throws {
        let now = Date()
        let updatedAt = now.addingTimeInterval(-10)
        // 999999 is not a live pid on this machine.
        let path = try writeSession(pid: 999_999, updatedAt: updatedAt, startedAt: now.addingTimeInterval(-60))

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertLessThan(result.agent.confidence, .exactProcess)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.agent.signals.map(\.path), [path])
        XCTAssertEqual(result.health.state, .ok)
    }

    func testDeadPid_freshFile_activeSessionFileConfidence() async throws {
        let now = Date()
        let updatedAt = now.addingTimeInterval(-10)
        _ = try writeSession(pid: 999_999, updatedAt: updatedAt, startedAt: now.addingTimeInterval(-60))

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
    }

    // MARK: - VAL-FLEET-003: stale file downgrades freshness

    func testLivePidStaleUpdatedAt_staleLogHeartbeat() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let updatedAt = now.addingTimeInterval(-300) // beyond the 120 s window
        _ = try writeSession(pid: Int(live.pid), updatedAt: updatedAt)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertNil(result.agent.process)
        XCTAssertNotEqual(result.agent.status, .running)
    }

    // MARK: - VAL-FLEET-017: multi-session — one live session drives the row

    func testMultiSession_liveSessionDrivesRow_deadSessionNeverMasks() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let liveUpdatedAt = now.addingTimeInterval(-5)
        let deadUpdatedAt = now.addingTimeInterval(-1)
        let livePath = try writeSession(
            pid: Int(live.pid),
            updatedAt: liveUpdatedAt,
            fileName: "\(live.pid).json"
        )
        let deadPath = try writeSession(
            pid: 999_999,
            updatedAt: deadUpdatedAt,
            startedAt: now.addingTimeInterval(-120),
            fileName: "999999.json"
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(Set(result.agent.signals.map(\.path)), Set([livePath, deadPath]),
                       "signals[] must reflect both evidence sources")
        XCTAssertGreaterThanOrEqual(result.threads.count, 1)
        XCTAssertEqual(result.threads.filter { $0.status == .running }.count, 1)
        XCTAssertTrue(result.threads.contains { $0.id == "session-\(live.pid)" })
    }

    func testMultiSession_threeLiveSessions_emitsThreeRunningThreads() async throws {
        let first = try LiveSleepProcess()
        let second = try LiveSleepProcess()
        let third = try LiveSleepProcess()
        liveProcess = first
        defer {
            second.terminate()
            third.terminate()
        }
        let now = Date()
        _ = try writeSession(pid: Int(first.pid), updatedAt: now.addingTimeInterval(-4), cwd: "/tmp/a")
        _ = try writeSession(pid: Int(second.pid), updatedAt: now.addingTimeInterval(-6), cwd: "/tmp/b")
        _ = try writeSession(pid: Int(third.pid), updatedAt: now.addingTimeInterval(-8), cwd: "/tmp/c")

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.threads.filter { $0.status == .running }.count, 3)
        XCTAssertEqual(Set(result.threads.map(\.id)).count, 3)
    }

    func testMultiSession_killLiveProcess_flipsRowNonRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        _ = try writeSession(pid: Int(live.pid), updatedAt: now.addingTimeInterval(-5))
        _ = try writeSession(pid: 999_999, updatedAt: now.addingTimeInterval(-1), startedAt: now.addingTimeInterval(-120))

        let before = await makeProbe().probe(now: now)
        XCTAssertEqual(before.agent.status, .running)

        live.terminate()
        liveProcess = nil

        let after = await makeProbe().probe(now: now)
        XCTAssertNotEqual(after.agent.status, .running)
        XCTAssertNil(after.agent.process)
    }

    // MARK: - VAL-FLEET-024: malformed shape isolation

    func testMalformedSession_missingPid_typedUnknownNeverRunning() async throws {
        let now = Date()
        let path = sessionsDirectory.appendingPathComponent("1.json").path
        try writeJSONFixture(
            ["sessionId": "s1", "cwd": "/Users/test/RepoA", "updatedAt": Int(now.timeIntervalSince1970 * 1000)],
            to: path
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed shape must be typed degraded, got \(result.health.state)")
        }
        XCTAssertEqual(result.agent.signals.map(\.path), [path])
    }

    func testMalformedSession_missingUpdatedAt_typedUnknownNeverRunning() async throws {
        let now = Date()
        let path = sessionsDirectory.appendingPathComponent("1.json").path
        try writeJSONFixture(
            ["pid": 999_999, "sessionId": "s1", "cwd": "/Users/test/RepoA"],
            to: path
        )

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

    func testMalformedSession_mistypedPid_typedUnknownNeverRunning() async throws {
        let now = Date()
        let path = sessionsDirectory.appendingPathComponent("1.json").path
        try writeJSONFixture(
            [
                "pid": "not-a-number",
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            to: path
        )

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

    func testMalformedSession_siblingWellFormedUnaffected() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // One malformed file (missing pid) + one live well-formed file.
        let malformedPath = sessionsDirectory.appendingPathComponent("1.json").path
        try writeJSONFixture(
            ["sessionId": "s1", "cwd": "/Users/test/RepoA", "updatedAt": Int(now.timeIntervalSince1970 * 1000)],
            to: malformedPath
        )
        let livePath = try writeSession(
            pid: Int(live.pid),
            updatedAt: now.addingTimeInterval(-5),
            fileName: "\(live.pid).json"
        )

        let result = await makeProbe().probe(now: now)

        // The live sibling drives the row; the malformed file only degrades
        // the health state, never the row's liveness.
        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(Set(result.agent.signals.map(\.path)), Set([malformedPath, livePath]))
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed sibling must surface a typed degraded health, got \(result.health.state)")
        }
    }

    // MARK: - VAL-HARD-007: pid-reuse / startedAt guard

    func testPidReuse_startedAtMismatch_neverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // The file claims the process started an hour ago, but the live
        // process started just now: pid-reuse guard treats it as dead.
        let startedAt = now.addingTimeInterval(-3600)
        _ = try writeSession(pid: Int(live.pid), updatedAt: now.addingTimeInterval(-5), startedAt: startedAt)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertNil(result.agent.process)
        XCTAssertLessThan(result.agent.confidence, .exactProcess)
    }

    // MARK: - Absent root / no sessions

    func testRootMissing_failedHealthUnknownRow() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing-root", isDirectory: true).path
        let result = await BurnBarFleetClaudeCodeProbe(agentID: .claudeCode, rootPath: missingRoot).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
        XCTAssertEqual(result.health.rootPath, missingRoot)
    }

    func testNoSessionsDirectory_okHealthUnknownRow() async throws {
        // Root exists but sessions/ is absent: installed-inactive, not failed.
        let now = Date()
        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertEqual(result.health.state, .ok)
    }

    func testEmptySessionsDirectory_okHealthUnknownRow() async throws {
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let now = Date()
        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertEqual(result.health.state, .ok)
    }
}

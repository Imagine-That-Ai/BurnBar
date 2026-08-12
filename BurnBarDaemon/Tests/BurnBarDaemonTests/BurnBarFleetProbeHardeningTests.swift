import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Regression tests for probe-hardening-repair-a (scrutiny round 1,
/// daemon-agent-probes-a). Kept in a dedicated file so the original probe
/// test classes stay under the lint type-body budget.
///
/// Covers: strict integer/timestamp decoding (reviewer issue 1), Claude
/// malformed-sibling isolation on the stale-live branch (issue 2), Factory
/// installed-but-inactive evidence + empty-registry semantics (issue 3),
/// Factory background-entry PID-reuse guard (issue 4), and the Factory status
/// vocabulary (issue 5).
final class BurnBarFleetProbeHardeningTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-probe-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    // MARK: - Claude: malformed sibling + stale-live session (issue 2)

    func testClaudeMalformedSibling_staleLiveSession_surfacesDegradedHealth() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let sessions = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        // A live-pid session whose updatedAt is beyond the freshness window
        // (stale branch) PLUS a malformed sibling (missing pid). The stale
        // branch must surface the malformed sibling as a typed degraded
        // probeHealth reason — a stale/logHeartbeat row with probeHealth ok
        // while a malformed sibling exists violates malformed-signal
        // isolation.
        let stalePath = sessions.appendingPathComponent("\(live.pid).json").path
        try writeJSONFixture(
            [
                "pid": Int(live.pid),
                "sessionId": "s-live",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.addingTimeInterval(-300).timeIntervalSince1970 * 1000)
            ],
            to: stalePath
        )
        let malformedPath = sessions.appendingPathComponent("1.json").path
        try writeJSONFixture(
            ["sessionId": "s-bad", "cwd": "/Users/test/RepoB", "updatedAt": Int(now.timeIntervalSince1970 * 1000)],
            to: malformedPath
        )

        let probe = BurnBarFleetClaudeCodeProbe(agentID: .claudeCode, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(Set(result.agent.signals.map(\.path)), Set([stalePath, malformedPath]))
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed sibling must degrade the stale row's health, got \(result.health.state)")
        }
    }

    func testClaudeMalformedSibling_fractionalPid_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let sessions = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        // A fractional pid (livePid + 0.5) must be rejected by the strict
        // integer helper and degrade typed — never truncated to the live pid.
        let path = sessions.appendingPathComponent("fractional.json").path
        try writeJSONFixture(
            [
                "pid": Double(live.pid) + 0.5,
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            to: path
        )

        let probe = BurnBarFleetClaudeCodeProbe(agentID: .claudeCode, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("fractional pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testClaudeMalformedSibling_booleanPid_typedDegradedNeverRunning() async throws {
        let now = Date()
        let sessions = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        // JSON true must never coerce to pid 1 via intValue.
        let path = sessions.appendingPathComponent("bool.json").path
        try writeJSONFixture(
            [
                "pid": true,
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            to: path
        )

        let probe = BurnBarFleetClaudeCodeProbe(agentID: .claudeCode, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("boolean pid must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - Factory: installed-but-inactive evidence + empty registry (issue 3)

    private func makeFactoryProbe() -> BurnBarFleetFactoryDroidProbe {
        BurnBarFleetFactoryDroidProbe(agentID: .factoryDroid, rootPath: fixtureRoot.path)
    }

    private func writeLedger(_ invocations: [[String: Any]]) throws {
        try writeJSONFixture(
            ["invocations": invocations],
            to: fixtureRoot.appendingPathComponent("task-invocations.json").path
        )
    }

    private func writeBackgroundProcesses(_ processes: [[String: Any]]) throws {
        try writeJSONFixture(
            ["processes": processes],
            to: fixtureRoot.appendingPathComponent("background-processes.json").path
        )
    }

    private func makeInvocation(status: String, updatedAt: Date, cwd: String = "/Users/test/RepoA") -> [String: Any] {
        [
            "taskInvocationId": UUID().uuidString,
            "status": status,
            "cwd": cwd,
            "createdAt": Int(updatedAt.timeIntervalSince1970 * 1000),
            "updatedAt": Int(updatedAt.timeIntervalSince1970 * 1000)
        ]
    }

    func testFactoryRootPresentNoSignals_idleCarriesRootPresenceEvidence() async throws {
        let now = Date()
        let result = await makeFactoryProbe().probe(now: now)

        // Every determined (non-unknown) row needs at least one evidence
        // path: the declared root itself is the evidence for the
        // installed-but-inactive state (VAL-FLEET-016).
        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertFalse(result.agent.signals.isEmpty, "idle row must carry signal evidence")
        XCTAssertTrue(
            result.agent.signals.contains { $0.kind == "root-presence" && $0.path == fixtureRoot.path },
            "root-presence evidence must name the declared root"
        )
    }

    func testFactoryEmptyLedgerAndEmptyRegistry_idleNotStale() async throws {
        let now = Date()
        // Both registries present but empty: the documented
        // installed-but-inactive state — idle, never stale.
        try writeLedger([])
        try writeBackgroundProcesses([])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertTrue(result.agent.signals.contains { $0.kind == "task-ledger" })
        XCTAssertTrue(result.agent.signals.contains { $0.kind == "process-list" })
        XCTAssertTrue(result.agent.signals.contains { $0.kind == "root-presence" })
    }

    func testFactoryEmptyBackgroundRegistryOnly_idleNotStale() async throws {
        let now = Date()
        // The real-world shape: background-processes.json present with
        // {"processes": []} and no other signals.
        try writeBackgroundProcesses([])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Factory: background-entry PID-reuse guard (issue 4)

    func testFactoryBackgroundEntry_pidReuse_startTimeMismatch_neverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // The entry claims the process started an hour ago, but the live
        // process started just now: the recorded process-start identity
        // check treats the pid as reused and the entry as dead.
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        // The entry's recorded startTime is beyond the freshness window, so
        // the honest outcome is stale (never running, never live-looking).
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.health.state, .ok)
    }

    func testFactoryBackgroundEntry_livePidWithRecordedStartTime_running() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // Recorded startTime matches the process's real start time: the
        // pid-reuse guard passes and the entry is live.
        let realStart = BurnBarFleetProcessLiveness.processStartTime(pid: Int(live.pid)) ?? now.timeIntervalSince1970
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(realStart * 1000)
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoB")
    }

    // MARK: - Factory: status vocabulary (issue 5)

    func testFactoryUnknownStatusString_bogus_typedMalformedNeverRunning() async throws {
        let now = Date()
        try writeLedger([
            makeInvocation(status: "bogus", updatedAt: now.addingTimeInterval(-30), cwd: "/Users/test/RepoA")
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
            XCTAssertTrue(reason.contains("bogus"), "reason must name the unknown status: \(reason)")
        } else {
            XCTFail("unknown status must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryDocumentedNonTerminalStatuses_driveRunning() async throws {
        let now = Date()
        for status in ["running", "queued", "pending", "in_progress", "active", "working"] {
            try writeLedger([
                makeInvocation(status: status, updatedAt: now.addingTimeInterval(-30), cwd: "/Users/test/RepoA")
            ])
            let result = await makeFactoryProbe().probe(now: now)
            XCTAssertEqual(
                result.agent.status, .running,
                "documented non-terminal status '\(status)' must drive running"
            )
            XCTAssertEqual(result.health.state, .ok)
        }
    }

    func testFactoryDocumentedTerminalStatuses_neverRunning() async throws {
        let now = Date()
        for status in ["completed", "failed", "cancelled"] {
            try writeLedger([
                makeInvocation(status: status, updatedAt: now.addingTimeInterval(-30), cwd: "/Users/test/RepoA")
            ])
            let result = await makeFactoryProbe().probe(now: now)
            XCTAssertNotEqual(
                result.agent.status, .running,
                "terminal status '\(status)' must never drive running"
            )
            XCTAssertEqual(result.agent.status, .idle)
            XCTAssertEqual(result.health.state, .ok)
        }
    }

    // MARK: - Factory: strict integer decoding (issue 1)

    func testFactoryBackgroundEntry_booleanPid_typedMalformedNeverRunning() async throws {
        let now = Date()
        try writeBackgroundProcesses([
            [
                "pid": true,
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("boolean pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryBackgroundEntry_fractionalPid_typedMalformedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // livePid + 0.5 must never truncate to the live pid.
        try writeBackgroundProcesses([
            [
                "pid": Double(live.pid) + 0.5,
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("fractional pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryInvocation_fractionalUpdatedAt_typedMalformedNeverRunning() async throws {
        let now = Date()
        try writeLedger([
            [
                "taskInvocationId": "t1",
                "status": "running",
                "cwd": "/Users/test/RepoA",
                "updatedAt": now.timeIntervalSince1970 * 1000 + 0.5
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("fractional updatedAt must be typed degraded, got \(result.health.state)")
        }
    }
}

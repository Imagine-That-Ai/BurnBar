import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Cross-probe pid-range regression tests for the probe-hardening-repair-a
/// follow-up (scrutiny round 2, reviewer report probe-hardening-repair-a.json,
/// issue 2). Kept in a dedicated file so the test classes stay under the lint
/// type-body budget (precedent: BurnBarFleetProbeHardeningBTestSupport.swift).
///
/// Integral JSON pid values outside the positive macOS pid_t range (zero,
/// negative, larger than Int32.max) are rejected BEFORE any pid_t/liveness
/// conversion at every JSON-number→pid_t site in the Fleet probe layer:
/// claude-code, grok-cli, grok-bot (daemon + supervisor), and hermes
/// (gateway.pid + heartbeat). No trap, typed non-running/degraded output.
/// The Factory Droid site is covered in BurnBarFleetProbeHardeningCTests.
final class BurnBarFleetProbeHardeningCTests2: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-probe-hardening-c2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    // MARK: - claude-code: pid range + invalid startedAt

    private func makeClaudeProbe() -> BurnBarFleetClaudeCodeProbe {
        BurnBarFleetClaudeCodeProbe(agentID: .claudeCode, rootPath: fixtureRoot.path)
    }

    private func writeClaudeSession(_ object: [String: Any], fileName: String) throws {
        let sessions = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
        try writeJSONFixture(object, to: sessions.appendingPathComponent(fileName).path)
    }

    func testClaudeSession_pidZero_typedDegradedNeverRunning() async throws {
        let now = Date()
        try writeClaudeSession(
            [
                "pid": 0,
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            fileName: "0.json"
        )

        let result = await makeClaudeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("positive"), "reason must name the malformed pid: \(reason)")
        } else {
            XCTFail("pid 0 must be typed degraded, got \(result.health.state)")
        }
    }

    func testClaudeSession_pidNegative_typedDegradedNeverRunning() async throws {
        let now = Date()
        try writeClaudeSession(
            [
                "pid": -1,
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            fileName: "neg.json"
        )

        let result = await makeClaudeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("negative pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testClaudeSession_pidHuge_typedDegradedNeverRunning() async throws {
        let now = Date()
        try writeClaudeSession(
            [
                "pid": 3_000_000_000,
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            fileName: "huge.json"
        )

        let result = await makeClaudeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid_t"), "reason must name the pid_t range: \(reason)")
        } else {
            XCTFail("huge pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testClaudeSession_invalidStartedAt_livePid_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // A live pid with a boolean startedAt: the malformed process-start
        // record must degrade the session typed — it is never converted to
        // nil and treated like an absent record (which would skip the
        // pid-reuse guard and let the live pid pass liveness).
        try writeClaudeSession(
            [
                "pid": Int(live.pid),
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "startedAt": true,
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            fileName: "\(live.pid).json"
        )

        let result = await makeClaudeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("startedAt"), "reason must name the malformed startedAt: \(reason)")
        } else {
            XCTFail("invalid startedAt must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - grok-cli: pid range

    private func makeGrokCLIProbe() -> BurnBarFleetGrokCLIProbe {
        BurnBarFleetGrokCLIProbe(agentID: .grokCLI, rootPath: fixtureRoot.path)
    }

    private func writeGrokCLIRegistry(_ entries: [[String: Any]]) throws {
        try writeJSONFixture(
            entries,
            to: fixtureRoot.appendingPathComponent("active_sessions.json").path
        )
    }

    func testGrokCLIEntry_pidZero_typedDegradedNeverRunning() async throws {
        try writeGrokCLIRegistry([
            ["session_id": "s1", "pid": 0, "cwd": "/Users/test/RepoA", "opened_at": "2026-08-12T01:01:05Z"]
        ])

        let result = await makeGrokCLIProbe().probe(now: Date())

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("positive"), "reason must name the malformed pid: \(reason)")
        } else {
            XCTFail("pid 0 must be typed degraded, got \(result.health.state)")
        }
    }

    func testGrokCLIEntry_pidHuge_typedDegradedNeverRunning() async throws {
        try writeGrokCLIRegistry([
            ["session_id": "s1", "pid": 3_000_000_000, "cwd": "/Users/test/RepoA", "opened_at": "2026-08-12T01:01:05Z"]
        ])

        let result = await makeGrokCLIProbe().probe(now: Date())

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid_t"), "reason must name the pid_t range: \(reason)")
        } else {
            XCTFail("huge pid must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - grok-bot: pid range + invalid startedAt

    private func makeGrokBotProbe() -> BurnBarFleetGrokBotProbe {
        BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: fixtureRoot.path)
    }

    private func writeGrokBotDaemon(_ object: [String: Any]) throws {
        try writeJSONFixture(
            object,
            to: fixtureRoot.appendingPathComponent("local-exec-daemon.json").path
        )
    }

    private func writeGrokBotSupervisor(_ object: [String: Any]) throws {
        try writeJSONFixture(
            object,
            to: fixtureRoot.appendingPathComponent("local-exec-supervisor.json").path
        )
    }

    func testGrokBotDaemon_pidHuge_typedDegradedNeverRunning() async throws {
        let now = Date()
        try writeGrokBotDaemon([
            "pid": 3_000_000_000,
            "startedAt": Int(now.timeIntervalSince1970 * 1000),
            "inflightCount": 2
        ])

        let result = await makeGrokBotProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid_t"), "reason must name the pid_t range: \(reason)")
        } else {
            XCTFail("huge pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testGrokBotDaemon_invalidStartedAt_livePid_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        // A live daemon pid with a boolean startedAt: malformed process-start
        // record — typed degraded, never running (the invalid record is not
        // treated like an absent one).
        try writeGrokBotDaemon([
            "pid": Int(live.pid),
            "startedAt": true,
            "inflightCount": 2
        ])

        let result = await makeGrokBotProbe().probe(now: Date())

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("startedAt"), "reason must name the malformed startedAt: \(reason)")
        } else {
            XCTFail("invalid startedAt must be typed degraded, got \(result.health.state)")
        }
    }

    func testGrokBotSupervisor_pidHuge_idleWithTypedDegradedHealth() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let realStart = BurnBarFleetProcessLiveness.processStartTime(pid: Int(live.pid)) ?? now.timeIntervalSince1970
        try writeGrokBotDaemon([
            "pid": Int(live.pid),
            "startedAt": Int(realStart * 1000),
            "inflightCount": 0
        ])
        // Supervisor pid beyond Int32.max: must not trap; the corroboration
        // signal degrades typed while the daemon stays idle.
        try writeGrokBotSupervisor([
            "pid": 3_000_000_000,
            "at": Int(now.timeIntervalSince1970 * 1000)
        ])

        let result = await makeGrokBotProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid_t"), "reason must name the pid_t range: \(reason)")
        } else {
            XCTFail("huge supervisor pid must be typed degraded, got \(result.health.state)")
        }
    }
}

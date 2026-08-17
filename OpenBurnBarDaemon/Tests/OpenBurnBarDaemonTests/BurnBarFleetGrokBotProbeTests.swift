import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Grok Bot probe tests: daemon/supervisor JSON signals.
///
/// Covers VAL-FLEET-004 (inflight 0 = idle, not running), VAL-FLEET-023
/// (stale/absent supervisor signal never yields running from stale evidence),
/// and VAL-FLEET-024 (malformed shape isolation).
final class BurnBarFleetGrokBotProbeTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-grokbot-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var daemonPath: String {
        fixtureRoot.appendingPathComponent("local-exec-daemon.json").path
    }

    private var supervisorPath: String {
        fixtureRoot.appendingPathComponent("local-exec-supervisor.json").path
    }

    private func makeProbe() -> BurnBarFleetGrokBotProbe {
        BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: fixtureRoot.path)
    }

    private func writeDaemon(pid: Int, inflightCount: Int, startedAt: Date? = nil) throws {
        var object: [String: Any] = [
            "pid": pid,
            "inflightCount": inflightCount
        ]
        if let startedAt {
            object["startedAt"] = Int(startedAt.timeIntervalSince1970 * 1000)
        }
        try writeJSONFixture(object, to: daemonPath)
    }

    private func writeSupervisor(pid: Int, at: Date) throws {
        try writeJSONFixture(
            ["pid": pid, "at": Int(at.timeIntervalSince1970 * 1000)],
            to: supervisorPath
        )
    }

    // MARK: - VAL-FLEET-004: inflight 0 = idle, not running

    func testLiveDaemonInflightZero_idleNotRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeDaemon(pid: Int(live.pid), inflightCount: 0, startedAt: now)
        try writeSupervisor(pid: Int(live.pid), at: now)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.count, 2)
    }

    func testLiveDaemonInflightZero_supervisorStale_stillIdleNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeDaemon(pid: Int(live.pid), inflightCount: 0, startedAt: now)
        // Supervisor signal far beyond the freshness window.
        try writeSupervisor(pid: Int(live.pid), at: now.addingTimeInterval(-3600))

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
    }

    // MARK: - VAL-FLEET-004: inflight > 0 flips to running

    func testLiveDaemonInflightGreaterThanZero_running() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeDaemon(pid: Int(live.pid), inflightCount: 2, startedAt: now)
        try writeSupervisor(pid: Int(live.pid), at: now)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - VAL-FLEET-023: stale/absent supervisor never yields running

    func testLiveDaemonInflightZero_supervisorAbsent_idleNotRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeDaemon(pid: Int(live.pid), inflightCount: 0, startedAt: now)
        // No supervisor file at all.

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.signals.count, 1)
    }

    func testLiveDaemonInflightZero_supervisorStale_neverRunningFromStaleEvidence() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeDaemon(pid: Int(live.pid), inflightCount: 0, startedAt: now)
        try writeSupervisor(pid: Int(live.pid), at: now.addingTimeInterval(-600))

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
    }

    func testDeadDaemonPid_neverRunning() async throws {
        let now = Date()
        try writeDaemon(pid: 999_999, inflightCount: 3, startedAt: now)
        try writeSupervisor(pid: 999_999, at: now)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - VAL-FLEET-024: malformed shape isolation

    func testMalformedDaemon_missingInflightCount_typedUnknownNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeJSONFixture(["pid": Int(live.pid)], to: daemonPath)
        try writeSupervisor(pid: Int(live.pid), at: now)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("inflightCount"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed daemon signal must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedDaemon_mistypedPid_typedUnknownNeverRunning() async throws {
        let now = Date()
        try writeJSONFixture(["pid": "not-a-number", "inflightCount": 1], to: daemonPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("malformed daemon signal must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedSupervisor_degradesHealthButLiveDaemonStillIdle() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeDaemon(pid: Int(live.pid), inflightCount: 0, startedAt: now)
        try writeJSONFixture(["pid": "not-a-number"], to: supervisorPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("supervisor"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed supervisor must be typed degraded, got \(result.health.state)")
        }
    }

    func testNotJSONObject_typedUnknownNeverRunning() async throws {
        let now = Date()
        try writeJSONFixture(["not": "an object"], to: daemonPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("non-object daemon signal must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - Root states

    func testRootMissing_failedHealth() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path
        let result = await BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: missingRoot).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
    }

    func testRootPresentNoSignals_unknownUnsupported() async throws {
        let now = Date()
        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Secrets: connection file is never read

    func testConnectionFile_neverReadOrListed() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeDaemon(pid: Int(live.pid), inflightCount: 1, startedAt: now)
        // Plant a secret-bearing connection file (structural keys only).
        try writeJSONFixture(
            ["token": "SECRET-TOKEN-VALUE-\(UUID().uuidString)"],
            to: fixtureRoot.appendingPathComponent("local-exec-daemon-connection.json").path
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        // The connection file must never appear in signals or notes.
        for signal in result.agent.signals {
            XCTAssertFalse(signal.path.contains("connection"), "connection file must never be read: \(signal.path)")
        }
        XCTAssertFalse(result.agent.note?.contains("connection") ?? false)
    }
}

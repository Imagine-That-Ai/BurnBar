import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Regression tests for probe-hardening-repair-b (scrutiny round 1,
/// daemon-agent-probes-b). Kept in a dedicated file so the original probe
/// test classes stay under the lint type-body budget.
///
/// Covers: Grok Bot pid-reuse guard + typed stale/absent-supervisor
/// degradation (reviewer issues 1-2), Hermes pid-reuse/heartbeat identity +
/// typed stale/missing-heartbeat degradation + malformed active_agents
/// (issues 3-5), and Cursor worker-id value validation (issue 6). Fixture
/// helpers live in `BurnBarFleetProbeHardeningBTestSupport.swift`.
final class BurnBarFleetProbeHardeningBTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-probe-hardening-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    // MARK: - Grok Bot: pid-reuse guard (issue 1)

    func testGrokBotDaemon_pidReuse_startedAtMismatch_neverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // The daemon file claims the process started an hour ago, but the
        // live process started just now: the process-start identity check
        // treats the pid as reused and the daemon as dead — never running,
        // never exactProcess (VAL-HARD-007).
        try hardeningBWriteGrokBotDaemon(
            root: fixtureRoot,
            pid: Int(live.pid),
            startedAtMilliseconds: Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000),
            inflightCount: 2
        )
        try hardeningBWriteGrokBotSupervisor(
            root: fixtureRoot,
            pid: Int(live.pid),
            atMilliseconds: Int(now.timeIntervalSince1970 * 1000)
        )

        let probe = BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
    }

    func testGrokBotDaemon_pidReuse_matchingStartedAt_running() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // Recorded startedAt matches the real process start: the guard
        // passes and inflight > 0 drives running/exactProcess.
        try hardeningBWriteGrokBotDaemon(
            root: fixtureRoot,
            pid: Int(live.pid),
            startedAtMilliseconds: Int(hardeningBRealStartTime(live.pid) * 1000),
            inflightCount: 2
        )
        try hardeningBWriteGrokBotSupervisor(
            root: fixtureRoot,
            pid: Int(live.pid),
            atMilliseconds: Int(now.timeIntervalSince1970 * 1000)
        )

        let probe = BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
    }

    // MARK: - Grok Bot: typed stale/absent supervisor degradation (issue 2)

    func testGrokBotInflightZero_staleSupervisor_idleWithTypedDegradedHealth() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try hardeningBWriteGrokBotDaemon(
            root: fixtureRoot,
            pid: Int(live.pid),
            startedAtMilliseconds: Int(hardeningBRealStartTime(live.pid) * 1000),
            inflightCount: 0
        )
        // Supervisor signal far beyond the freshness window.
        try hardeningBWriteGrokBotSupervisor(
            root: fixtureRoot,
            pid: Int(live.pid),
            atMilliseconds: Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        )

        let probe = BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        // VAL-FLEET-023: the stale supervisor must surface as a typed
        // degraded probeHealth reason, never a silently healthy idle row.
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("stale"), "unexpected reason: \(reason)")
        } else {
            XCTFail("stale supervisor must be typed degraded, got \(result.health.state)")
        }
    }

    func testGrokBotInflightZero_absentSupervisor_idleWithTypedDegradedHealth() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try hardeningBWriteGrokBotDaemon(
            root: fixtureRoot,
            pid: Int(live.pid),
            startedAtMilliseconds: Int(hardeningBRealStartTime(live.pid) * 1000),
            inflightCount: 0
        )
        // No supervisor file at all.

        let probe = BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("absent"), "unexpected reason: \(reason)")
        } else {
            XCTFail("absent supervisor must be typed degraded, got \(result.health.state)")
        }
    }

    func testGrokBotInflightZero_freshSupervisor_idleWithOkHealth() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try hardeningBWriteGrokBotDaemon(
            root: fixtureRoot,
            pid: Int(live.pid),
            startedAtMilliseconds: Int(hardeningBRealStartTime(live.pid) * 1000),
            inflightCount: 0
        )
        try hardeningBWriteGrokBotSupervisor(
            root: fixtureRoot,
            pid: Int(live.pid),
            atMilliseconds: Int(now.timeIntervalSince1970 * 1000)
        )

        let probe = BurnBarFleetGrokBotProbe(agentID: .grokBot, rootPath: fixtureRoot.path)
        let result = await probe.probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Hermes: pid-reuse guard + heartbeat identity (issue 3)

    private func makeHermesProbe() -> BurnBarFleetHermesProbe {
        BurnBarFleetHermesProbe(agentID: .hermes, rootPath: fixtureRoot.path)
    }

    func testHermesGateway_pidReuse_startTimeMismatch_neverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // Both records claim the process started an hour ago; the live
        // process started just now — reused pid, never running/exactProcess.
        try hardeningBWriteHermesGatewayPid(
            root: fixtureRoot,
            pid: Int(live.pid),
            startTime: now.addingTimeInterval(-3600).timeIntervalSince1970
        )
        try hardeningBWriteHermesHeartbeat(
            root: fixtureRoot,
            pid: Int(live.pid),
            updatedAt: now,
            startTime: now.addingTimeInterval(-3600).timeIntervalSince1970
        )
        try hardeningBWriteHermesGatewayState(root: fixtureRoot, activeAgents: 2)
        try hardeningBWriteHermesProcesses(root: fixtureRoot)

        let result = await makeHermesProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
    }

    func testHermesGateway_matchingStartTimes_running() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let start = hardeningBRealStartTime(live.pid)
        try hardeningBWriteHermesGatewayPid(root: fixtureRoot, pid: Int(live.pid), startTime: start)
        try hardeningBWriteHermesHeartbeat(root: fixtureRoot, pid: Int(live.pid), updatedAt: now, startTime: start)
        try hardeningBWriteHermesGatewayState(root: fixtureRoot, activeAgents: 2)
        try hardeningBWriteHermesProcesses(root: fixtureRoot)

        let result = await makeHermesProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.health.state, .ok)
    }

    func testHermesHeartbeat_pidMismatch_neverRunningTypedDegraded() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let start = hardeningBRealStartTime(live.pid)
        try hardeningBWriteHermesGatewayPid(root: fixtureRoot, pid: Int(live.pid), startTime: start)
        // A fresh heartbeat written by a DIFFERENT live process: it is not
        // evidence for the gateway — never running, typed degraded.
        let other = try LiveSleepProcess()
        defer { other.terminate() }
        try hardeningBWriteHermesHeartbeat(
            root: fixtureRoot,
            pid: Int(other.pid),
            updatedAt: now,
            startTime: hardeningBRealStartTime(other.pid)
        )
        try hardeningBWriteHermesGatewayState(root: fixtureRoot, activeAgents: 2)
        try hardeningBWriteHermesProcesses(root: fixtureRoot)

        let result = await makeHermesProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid"), "unexpected reason: \(reason)")
        } else {
            XCTFail("mismatched heartbeat pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testHermesHeartbeat_absentStartTime_guardFallsBackToGatewayPidRecord() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let start = hardeningBRealStartTime(live.pid)
        // Heartbeat without a start_time: the guard falls back to the
        // gateway.pid record, which matches — running stays valid.
        try hardeningBWriteHermesGatewayPid(root: fixtureRoot, pid: Int(live.pid), startTime: start)
        try writeJSONFixture(
            ["pid": Int(live.pid), "updated_at": ISO8601DateFormatter().string(from: now), "monotonic": 0],
            to: fixtureRoot.appendingPathComponent("state/gateway.heartbeat").path
        )
        try hardeningBWriteHermesGatewayState(root: fixtureRoot, activeAgents: 2)
        try hardeningBWriteHermesProcesses(root: fixtureRoot)

        let result = await makeHermesProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
    }

    // MARK: - Hermes: malformed active_agents (issue 5)

    func testHermesGatewayState_booleanActiveAgents_typedUnknownNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let start = hardeningBRealStartTime(live.pid)
        try hardeningBWriteHermesGatewayPid(root: fixtureRoot, pid: Int(live.pid), startTime: start)
        try hardeningBWriteHermesHeartbeat(root: fixtureRoot, pid: Int(live.pid), updatedAt: now, startTime: start)
        // JSON true must never coerce to active_agents 1 via intValue.
        try writeJSONFixture(
            ["pid": Int(live.pid), "gateway_state": "running", "active_agents": true],
            to: fixtureRoot.appendingPathComponent("gateway_state.json").path
        )
        try hardeningBWriteHermesProcesses(root: fixtureRoot)

        let result = await makeHermesProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("active_agents"), "unexpected reason: \(reason)")
        } else {
            XCTFail("boolean active_agents must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - Cursor: worker-id value validation (issue 6)

    private func makeCursorProbe() -> BurnBarFleetCursorProbe {
        BurnBarFleetCursorProbe(agentID: .cursor, rootPath: fixtureRoot.path)
    }

    func testCursorNullWorkerID_freshTracking_typedDegradedNeverRunning() async throws {
        let now = Date()
        // A null worker-id value with otherwise-fresh tracking: malformed
        // primary signal — typed unknown/degraded, never
        // running/activeSessionFile with healthy probeHealth (VAL-FLEET-024).
        try hardeningBWriteCursorState(root: fixtureRoot, workerIDs: ["AgentLens @ albertonunez": NSNull()])
        try hardeningBWriteCursorTracking(root: fixtureRoot, mtime: now.addingTimeInterval(-10))

        let result = await makeCursorProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("worker id"), "unexpected reason: \(reason)")
        } else {
            XCTFail("null worker id must be typed degraded, got \(result.health.state)")
        }
    }

    func testCursorNonStringOrEmptyWorkerID_freshTracking_typedDegradedNeverRunning() async throws {
        let now = Date()
        for malformedValue: Any in [42, ""] {
            try hardeningBWriteCursorState(root: fixtureRoot, workerIDs: ["AgentLens @ albertonunez": malformedValue])
            try hardeningBWriteCursorTracking(root: fixtureRoot, mtime: now.addingTimeInterval(-10))

            let result = await makeCursorProbe().probe(now: now)

            XCTAssertNotEqual(result.agent.status, .running)
            XCTAssertEqual(result.agent.status, .unknown)
            XCTAssertEqual(result.agent.confidence, .unsupported)
            if case .degraded = result.health.state {
                // typed degraded
            } else {
                XCTFail("malformed worker id must be typed degraded, got \(result.health.state)")
            }
        }
    }

    func testCursorMixedValidAndInvalidWorkerIDs_typedDegradedNeverRunning() async throws {
        let now = Date()
        // One valid value plus one null: any malformed value degrades the
        // whole primary signal — never a running row from the valid entry.
        try hardeningBWriteCursorState(root: fixtureRoot, workerIDs: [
            "AgentLens @ albertonunez": "worker-1",
            "Other @ host": NSNull()
        ])
        try hardeningBWriteCursorTracking(root: fixtureRoot, mtime: now.addingTimeInterval(-10))

        let result = await makeCursorProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("mixed valid/invalid worker ids must be typed degraded, got \(result.health.state)")
        }
    }

    func testCursorValidStringWorkerIDs_freshTracking_running() async throws {
        let now = Date()
        try hardeningBWriteCursorState(root: fixtureRoot, workerIDs: ["AgentLens @ albertonunez": "worker-1"])
        try hardeningBWriteCursorTracking(root: fixtureRoot, mtime: now.addingTimeInterval(-10))

        let result = await makeCursorProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.projectName, "AgentLens")
        XCTAssertEqual(result.health.state, .ok)
    }
}

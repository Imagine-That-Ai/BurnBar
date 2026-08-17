import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Hermes probe tests: gateway.pid + state/gateway.heartbeat +
/// gateway_state.json + processes.json.
///
/// Covers VAL-FLEET-005 (zero active agents = idle), VAL-FLEET-023
/// (stale/missing heartbeat never yields running), and VAL-FLEET-024
/// (malformed shape isolation).
final class BurnBarFleetHermesProbeTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-hermes-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var gatewayPidPath: String {
        fixtureRoot.appendingPathComponent("gateway.pid").path
    }

    private var heartbeatPath: String {
        fixtureRoot.appendingPathComponent("state/gateway.heartbeat").path
    }

    private var gatewayStatePath: String {
        fixtureRoot.appendingPathComponent("gateway_state.json").path
    }

    private var processesPath: String {
        fixtureRoot.appendingPathComponent("processes.json").path
    }

    private func makeProbe() -> BurnBarFleetHermesProbe {
        BurnBarFleetHermesProbe(agentID: .hermes, rootPath: fixtureRoot.path)
    }

    private func writeGatewayPid(pid: Int) throws {
        // The recorded start_time must match the real process start so the
        // pid-reuse guard passes for live fixture pids (the guard compares
        // the current process start against the recorded start).
        let startTime = BurnBarFleetProcessLiveness.processStartTime(pid: pid) ?? 1_750_000_000
        try writeJSONFixture(
            ["pid": pid, "kind": "hermes-gateway", "start_time": Int(startTime)],
            to: gatewayPidPath
        )
    }

    private func writeHeartbeat(pid: Int, updatedAt: Date) throws {
        // The real heartbeat writes a fractional epoch-seconds start_time;
        // matching it keeps the heartbeat identity + pid-reuse guard green
        // for live fixture pids.
        let startTime = BurnBarFleetProcessLiveness.processStartTime(pid: pid) ?? 1_750_000_000
        try writeJSONFixture(
            [
                "pid": pid,
                "updated_at": ISO8601DateFormatter().string(from: updatedAt),
                "monotonic": 0,
                "start_time": startTime
            ],
            to: heartbeatPath
        )
    }

    private func writeGatewayState(activeAgents: Int) throws {
        try writeJSONFixture(
            ["pid": 1, "gateway_state": "running", "active_agents": activeAgents],
            to: gatewayStatePath
        )
    }

    private func writeProcesses(_ entries: [[String: Any]]) throws {
        try writeJSONFixture(entries, to: processesPath)
    }

    // MARK: - VAL-FLEET-005: zero active agents = idle

    func testLiveGatewayZeroActiveAgents_idleNotRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        try writeHeartbeat(pid: Int(live.pid), updatedAt: now)
        try writeGatewayState(activeAgents: 0)
        try writeProcesses([])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.count, 4)
    }

    // MARK: - VAL-FLEET-005: active_agents > 0 flips to running

    func testLiveGatewayActiveAgentsGreaterThanZero_running() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        try writeHeartbeat(pid: Int(live.pid), updatedAt: now)
        try writeGatewayState(activeAgents: 2)
        try writeProcesses([])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.health.state, .ok)
    }

    func testLiveGatewayNonEmptyProcesses_runningEvenWithZeroActiveAgents() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        try writeHeartbeat(pid: Int(live.pid), updatedAt: now)
        try writeGatewayState(activeAgents: 0)
        try writeProcesses([["cwd": "/Users/test/RepoA"]])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoA")
    }

    func testFreshHeartbeatAndProcessesWithoutGatewayState_preservesActiveWorkWithTypedHealth() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        try writeHeartbeat(pid: Int(live.pid), updatedAt: now)
        // gateway_state.json is intentionally absent. The non-empty process
        // registry is still authoritative active-work evidence.
        try writeProcesses([["cwd": "/Users/test/PartialHermesRepo"]])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.agent.projectName, "/Users/test/PartialHermesRepo")
        XCTAssertEqual(
            result.agent.note?.contains("gateway_state.json is absent"),
            true,
            "missing gateway state must remain visible as a typed caveat"
        )
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("gateway_state.json is absent"), "unexpected reason: \(reason)")
        } else {
            XCTFail("partial Hermes active-work evidence must remain typed degraded")
        }
    }

    // MARK: - VAL-FLEET-023: stale heartbeat never yields running

    func testLivePidActiveAgentsStaleHeartbeat_nonRunningTypedReason() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        // Heartbeat far beyond the 120 s window.
        try writeHeartbeat(pid: Int(live.pid), updatedAt: now.addingTimeInterval(-3600))
        try writeGatewayState(activeAgents: 3)
        try writeProcesses([])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.agent.note?.contains("stale"), true, "stale heartbeat must carry a typed note")
        // VAL-FLEET-023: the stale heartbeat must surface as a typed
        // degraded probeHealth reason, not only the agent note.
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("stale"), "unexpected reason: \(reason)")
        } else {
            XCTFail("stale heartbeat must be typed degraded, got \(result.health.state)")
        }
    }

    func testLivePidActiveAgentsMissingHeartbeat_nonRunningTypedReason() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        // No heartbeat file at all.
        try writeGatewayState(activeAgents: 3)
        try writeProcesses([])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.agent.note?.contains("stale"), true, "missing heartbeat must carry a typed note")
        // VAL-FLEET-023: the missing heartbeat must surface as a typed
        // degraded probeHealth reason, not only the agent note.
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing heartbeat must be typed degraded, got \(result.health.state)")
        }
    }

    func testDeadGatewayPid_neverRunning() async throws {
        let now = Date()
        try writeGatewayPid(pid: 999_999)
        try writeHeartbeat(pid: 999_999, updatedAt: now)
        try writeGatewayState(activeAgents: 2)
        try writeProcesses([])

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
    }

    // MARK: - VAL-FLEET-024: malformed shape isolation

    func testMalformedGatewayPid_missingPid_typedUnknownNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeJSONFixture(["kind": "hermes-gateway"], to: gatewayPidPath)
        try writeHeartbeat(pid: Int(live.pid), updatedAt: now)
        try writeGatewayState(activeAgents: 2)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed gateway.pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedHeartbeat_missingUpdatedAt_typedUnknownNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        try writeJSONFixture(["pid": Int(live.pid), "monotonic": 0], to: heartbeatPath)
        try writeGatewayState(activeAgents: 2)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("updated_at"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed heartbeat must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedGatewayState_missingActiveAgents_typedUnknownNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeGatewayPid(pid: Int(live.pid))
        try writeHeartbeat(pid: Int(live.pid), updatedAt: now)
        try writeJSONFixture(["pid": Int(live.pid), "gateway_state": "running"], to: gatewayStatePath)

        let result = await makeProbe().probe(now: now)

        // A missing active_agents key is malformed-shape: the row is typed
        // unknown/degraded — NEVER defaulted to zero, which would fabricate
        // an idle/exactProcess row (VAL-FLEET-024).
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("active_agents"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed gateway_state must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - Root states

    func testRootMissing_failedHealth() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path
        let result = await BurnBarFleetHermesProbe(agentID: .hermes, rootPath: missingRoot).probe(now: now)

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
}

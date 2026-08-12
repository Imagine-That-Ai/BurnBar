import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Hermes pid-range regression tests for the probe-hardening-repair-a
/// follow-up (scrutiny round 2, reviewer report probe-hardening-repair-a.json,
/// issue 2). Kept in a dedicated file so the test classes stay under the lint
/// type-body budget (precedent: BurnBarFleetProbeHardeningBTestSupport.swift).
///
/// Integral JSON pid values outside the positive macOS pid_t range (zero,
/// negative, larger than Int32.max) are rejected BEFORE any pid_t/liveness
/// conversion at the hermes gateway.pid and heartbeat sites — no trap, typed
/// non-running/degraded output. A PRESENT-but-invalid `start_time` degrades
/// typed and is never treated like an absent record.
final class BurnBarFleetProbeHardeningCTests3: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-probe-hardening-c3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private func makeHermesProbe() -> BurnBarFleetHermesProbe {
        BurnBarFleetHermesProbe(agentID: .hermes, rootPath: fixtureRoot.path)
    }

    private func writeHermesGatewayPid(_ object: [String: Any]) throws {
        try writeJSONFixture(object, to: fixtureRoot.appendingPathComponent("gateway.pid").path)
    }

    private func writeHermesHeartbeat(_ object: [String: Any]) throws {
        try writeJSONFixture(
            object,
            to: fixtureRoot.appendingPathComponent("state/gateway.heartbeat").path
        )
    }

    private func writeHermesGatewayState(activeAgents: Int) throws {
        try writeJSONFixture(
            ["pid": 1, "gateway_state": "running", "active_agents": activeAgents],
            to: fixtureRoot.appendingPathComponent("gateway_state.json").path
        )
    }

    private func writeHermesProcesses() throws {
        try writeJSONFixture([], to: fixtureRoot.appendingPathComponent("processes.json").path)
    }

    func testHermesGatewayPid_pidHuge_typedDegradedNeverRunning() async throws {
        let now = Date()
        try writeHermesGatewayPid(["pid": 3_000_000_000, "kind": "hermes-gateway", "start_time": 1_750_000_000])
        try writeHermesHeartbeat([
            "pid": 3_000_000_000,
            "updated_at": ISO8601DateFormatter().string(from: now),
            "start_time": 1_750_000_000
        ])
        try writeHermesGatewayState(activeAgents: 2)
        try writeHermesProcesses()

        let result = await makeHermesProbe().probe(now: now)

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

    func testHermesHeartbeat_pidHuge_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let realStart = BurnBarFleetProcessLiveness.processStartTime(pid: Int(live.pid)) ?? now.timeIntervalSince1970
        try writeHermesGatewayPid(["pid": Int(live.pid), "kind": "hermes-gateway", "start_time": Int(realStart)])
        // Heartbeat pid beyond Int32.max: the heartbeat signal is malformed
        // and must not trap; the row is non-running with typed degradation.
        try writeHermesHeartbeat([
            "pid": 3_000_000_000,
            "updated_at": ISO8601DateFormatter().string(from: now),
            "start_time": realStart
        ])
        try writeHermesGatewayState(activeAgents: 2)
        try writeHermesProcesses()

        let result = await makeHermesProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid_t"), "reason must name the pid_t range: \(reason)")
        } else {
            XCTFail("huge heartbeat pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testHermesGatewayPid_invalidStartTime_livePid_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // A live gateway pid with a boolean start_time: malformed
        // process-start record — typed degraded, never running.
        try writeHermesGatewayPid(["pid": Int(live.pid), "kind": "hermes-gateway", "start_time": true])
        try writeHermesHeartbeat([
            "pid": Int(live.pid),
            "updated_at": ISO8601DateFormatter().string(from: now),
            "start_time": true
        ])
        try writeHermesGatewayState(activeAgents: 2)
        try writeHermesProcesses()

        let result = await makeHermesProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("start_time"), "reason must name the malformed start_time: \(reason)")
        } else {
            XCTFail("invalid start_time must be typed degraded, got \(result.health.state)")
        }
    }
}

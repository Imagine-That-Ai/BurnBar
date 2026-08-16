import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Regression coverage for M6 degradation semantics that are easier to pin
/// below the socket boundary: unreadable roots, missing Hermes corroboration,
/// and PID-reuse identity mismatches across pid-bearing probes.
final class BurnBarFleetDegradationUnitTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-degradation-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let liveProcess {
            liveProcess.terminate()
            self.liveProcess = nil
        }
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testUnreadableDeclaredRoots_areTypedPerProbe() async throws {
        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": fixtureRoot.path],
            homeDirectory: URL(fileURLWithPath: "/Users/m6-degradation")
        )
        let probes = BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        let now = Date()

        for agentID in BurnBarFleetAgentID.declaredRoster {
            let root = URL(
                fileURLWithPath: resolver.rootPath(for: agentID),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        }
        defer {
            for agentID in BurnBarFleetAgentID.declaredRoster {
                let root = URL(fileURLWithPath: resolver.rootPath(for: agentID), isDirectory: true)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            }
        }

        for agentID in BurnBarFleetAgentID.declaredRoster {
            let probe = try XCTUnwrap(probes[agentID])
            let probeResult = await probe.probe(now: now)
            XCTAssertEqual(probeResult.agent.status, .unknown, "\(agentID) must not become installed-idle")
            XCTAssertEqual(probeResult.agent.confidence, .unsupported)
            XCTAssertTrue(probeResult.agent.signals.isEmpty)
            guard case .degraded(let reason) = probeResult.health.state else {
                return XCTFail("\(agentID) unreadable root must be degraded: \(probeResult.health.state)")
            }
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("permission"), "\(agentID): \(reason)")
        }
    }

    func testHermesMissingProcesses_isTypedAndDoesNotFabricateRepo() async throws {
        let process = try LiveSleepProcess()
        liveProcess = process
        let now = Date()
        let pid = Int(process.pid)
        let startTime = BurnBarFleetProcessLiveness.processStartTime(pid: pid) ?? now.timeIntervalSince1970

        try writeJSON(
            ["pid": pid, "start_time": startTime],
            at: "hermes/gateway.pid"
        )
        try writeJSON(
            [
                "pid": pid,
                "updated_at": ISO8601DateFormatter().string(from: now),
                "start_time": startTime
            ],
            at: "hermes/state/gateway.heartbeat"
        )
        try writeJSON(["active_agents": 0], at: "hermes/gateway_state.json")
        // processes.json intentionally remains absent.

        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": fixtureRoot.path],
            homeDirectory: URL(fileURLWithPath: "/Users/m6-degradation")
        )
        let probe = try XCTUnwrap(
            BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)[.hermes]
        )
        let result = await probe.probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertNil(result.agent.projectName)
        XCTAssertTrue(result.agent.note?.contains("processes.json is absent") == true)
        guard case .degraded(let reason) = result.health.state else {
            return XCTFail("missing secondary signal must be degraded: \(result.health.state)")
        }
        XCTAssertTrue(reason.contains("processes.json is absent"))
    }

    func testPidReuseGuard_rejectsStartedAtMismatchAcrossAgents() async throws {
        let process = try LiveSleepProcess()
        liveProcess = process
        let now = Date()
        let pid = Int(process.pid)
        let oldStart = now.addingTimeInterval(-3_600)
        let oldStartMilliseconds = Int(oldStart.timeIntervalSince1970 * 1_000)
        let oldStartSeconds = oldStart.timeIntervalSince1970

        try writeJSON(
            [
                "pid": pid,
                "cwd": "/fixture",
                "startedAt": oldStartMilliseconds,
                "updatedAt": Int(now.timeIntervalSince1970 * 1_000)
            ],
            at: "claude/sessions/\(pid).json"
        )
        try writeJSON(
            ["pid": pid, "startedAt": oldStartMilliseconds, "inflightCount": 1],
            at: "grokbot/local-exec-daemon.json"
        )
        try writeJSON(
            ["pid": pid, "at": oldStartMilliseconds],
            at: "grokbot/local-exec-supervisor.json"
        )
        try writeJSON(
            ["pid": pid, "start_time": oldStartSeconds],
            at: "hermes/gateway.pid"
        )
        try writeJSON(
            [
                "pid": pid,
                "updated_at": ISO8601DateFormatter().string(from: now),
                "start_time": oldStartSeconds
            ],
            at: "hermes/state/gateway.heartbeat"
        )
        try writeJSON(["active_agents": 1], at: "hermes/gateway_state.json")
        try writeJSON([], at: "hermes/processes.json")
        try writeJSON(
            [
                "processes": [
                    ["pid": pid, "startTime": oldStartMilliseconds, "cwd": "/fixture"]
                ]
            ],
            at: "factory/background-processes.json"
        )

        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": fixtureRoot.path],
            homeDirectory: URL(fileURLWithPath: "/Users/m6-degradation")
        )
        let probes = BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        let guardedIDs: [BurnBarFleetAgentID] = [.claudeCode, .grokBot, .hermes, .factoryDroid]

        for agentID in guardedIDs {
            let probe = try XCTUnwrap(probes[agentID])
            let result = await probe.probe(now: now)
            XCTAssertNotEqual(result.agent.status, .running, "\(agentID) resurrected a reused pid")
            XCTAssertNotEqual(
                result.agent.confidence,
                .exactProcess,
                "\(agentID) claimed exactProcess for a reused pid"
            )
            XCTAssertNil(result.agent.process, "\(agentID) exposed a reused process")
        }
    }

    private func writeJSON(_ object: Any, at relativePath: String) throws {
        try writeJSONFixture(
            object,
            to: fixtureRoot.appendingPathComponent(relativePath).path
        )
    }
}

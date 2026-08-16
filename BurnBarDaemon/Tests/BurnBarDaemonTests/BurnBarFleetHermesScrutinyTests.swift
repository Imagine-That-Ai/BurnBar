@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

final class BurnBarFleetHermesScrutinyTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-hermes-scrutiny-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testMalformedProcessesEntry_surfacesTypedHealthWithoutDroppingValidEntry() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let startTime = BurnBarFleetProcessLiveness.processStartTime(pid: Int(live.pid)) ?? 1_750_000_000
        let stateDirectory = fixtureRoot.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try writeJSONFixture(
            ["pid": Int(live.pid), "start_time": Int(startTime)],
            to: fixtureRoot.appendingPathComponent("gateway.pid").path
        )
        try writeJSONFixture(
            [
                "pid": Int(live.pid),
                "updated_at": ISO8601DateFormatter().string(from: now),
                "start_time": startTime
            ],
            to: stateDirectory.appendingPathComponent("gateway.heartbeat").path
        )
        try writeJSONFixture(
            ["active_agents": 0],
            to: fixtureRoot.appendingPathComponent("gateway_state.json").path
        )
        try writeJSONFixture(
            [["cwd": "/Users/test/RepoA"], "malformed-entry"],
            to: fixtureRoot.appendingPathComponent("processes.json").path
        )

        let result = await BurnBarFleetHermesProbe(rootPath: fixtureRoot.path).probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoA")
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("processes.json entry 1"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed process entries must surface typed degraded health")
        }
    }

    func testHeartbeatFreshness_exactBoundaryIsStale() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        let startTime = BurnBarFleetProcessLiveness.processStartTime(pid: Int(live.pid)) ?? 1_750_000_000
        let stateDirectory = fixtureRoot.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try writeJSONFixture(
            ["pid": Int(live.pid), "start_time": Int(startTime)],
            to: fixtureRoot.appendingPathComponent("gateway.pid").path
        )
        try writeJSONFixture(
            [
                "pid": Int(live.pid),
                "updated_at": ISO8601DateFormatter().string(
                    from: now.addingTimeInterval(-BurnBarFleetProbeConstants.hermesHeartbeatFreshnessSeconds)
                ),
                "start_time": startTime
            ],
            to: stateDirectory.appendingPathComponent("gateway.heartbeat").path
        )
        try writeJSONFixture(
            ["active_agents": 1],
            to: fixtureRoot.appendingPathComponent("gateway_state.json").path
        )
        try writeJSONFixture([], to: fixtureRoot.appendingPathComponent("processes.json").path)

        let result = await BurnBarFleetHermesProbe(rootPath: fixtureRoot.path).probe(now: now)

        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertNotEqual(result.agent.status, .running)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("stale"), "unexpected reason: \(reason)")
        } else {
            XCTFail("the strict freshness boundary must degrade stale evidence")
        }
    }

    func testReadJSONBounded_slowDrainUsesSingleMonotonicDeadline() throws {
        let fifoURL = fixtureRoot.appendingPathComponent("slow.json")
        XCTAssertEqual(mkfifo(fifoURL.path, 0o600), 0, "mkfifo failed with errno \(errno)")
        let writerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let descriptor = open(fifoURL.path, O_WRONLY)
            if descriptor >= 0 {
                let bytes = Array("{\"partial\":".utf8)
                _ = bytes.withUnsafeBytes { pointer in
                    write(descriptor, pointer.baseAddress, bytes.count)
                }
                Thread.sleep(forTimeInterval: 0.35)
                close(descriptor)
            }
            writerFinished.signal()
        }

        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(
            try BurnBarFleetProbeJSON.readJSONBounded(at: fifoURL.path, timeoutSeconds: 0.2)
        ) { error in
            XCTAssertEqual(error as? BurnBarFleetProbeReadError, .timedOut)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
        XCTAssertLessThan(elapsed, 500, "slow drain exceeded the whole-file budget: \(elapsed)ms")
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 1), .success)
    }

    func testHermesProbe_fifoSignalUsesOneWholeProbeBudget() async throws {
        let fifoURL = fixtureRoot.appendingPathComponent("gateway.pid")
        XCTAssertEqual(mkfifo(fifoURL.path, 0o600), 0, "mkfifo failed with errno \(errno)")

        let started = DispatchTime.now().uptimeNanoseconds
        let result = await BurnBarFleetHermesProbe(
            rootPath: fixtureRoot.path,
            readTimeoutSeconds: 0.2
        ).probe(now: Date())
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0

        XCTAssertLessThan(elapsed, 500, "Hermes probe exceeded its whole budget: \(elapsed)ms")
        XCTAssertNotEqual(result.health.state, .ok)
    }
}

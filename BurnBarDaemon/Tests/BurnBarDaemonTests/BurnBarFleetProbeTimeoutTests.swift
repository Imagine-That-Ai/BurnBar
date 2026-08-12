import BurnBarCore
@testable import BurnBarDaemon
import Darwin
import Foundation
import XCTest

/// Per-probe timeout seam tests (VAL-FLEET-019): a blocking signal path
/// (FIFO) is bounded by the per-probe timeout, degrades typed, and never
/// stalls the tick.
final class BurnBarFleetProbeTimeoutTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-probe-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    /// Creates a FIFO at `path` (a blocking signal path).
    private func makeFIFO(at path: String) throws {
        let result = mkfifo(path, 0o600)
        XCTAssertEqual(result, 0, "mkfifo failed with errno \(errno)")
    }

    // MARK: - VAL-FLEET-019: bounded read on a FIFO degrades typed

    func testFIFOAsDaemonSignal_timesOutTyped_neverRunning() async throws {
        let fifoPath = fixtureRoot.appendingPathComponent("local-exec-daemon.json").path
        try makeFIFO(at: fifoPath)

        let probe = BurnBarFleetGrokBotProbe(
            agentID: .grokBot,
            rootPath: fixtureRoot.path,
            readTimeoutSeconds: 0.5
        )
        let now = Date()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = await probe.probe(now: now)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        // The probe must return within a small multiple of the timeout.
        XCTAssertLessThan(elapsed, 3.0, "probe must be bounded by the per-probe timeout")
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("timed out"), "unexpected reason: \(reason)")
        } else {
            XCTFail("FIFO signal must be typed degraded with a timeout reason, got \(result.health.state)")
        }
    }

    func testFIFOAsHermesHeartbeat_timesOutTyped() async throws {
        let stateDir = fixtureRoot.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let fifoPath = stateDir.appendingPathComponent("gateway.heartbeat").path
        try makeFIFO(at: fifoPath)

        let probe = BurnBarFleetHermesProbe(
            agentID: .hermes,
            rootPath: fixtureRoot.path,
            readTimeoutSeconds: 0.5
        )
        let now = Date()
        let result = await probe.probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("timed out"), "unexpected reason: \(reason)")
        } else {
            XCTFail("FIFO heartbeat must be typed degraded with a timeout reason, got \(result.health.state)")
        }
    }

    func testFIFOAsClaudeSessionFile_timesOutTyped() async throws {
        // The timeout seam covers every JSON-backed probe, including the
        // probes-a set: a FIFO as a claude session file must degrade typed
        // and never stall the probe.
        let sessionsDir = fixtureRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fifoPath = sessionsDir.appendingPathComponent("1.json").path
        try makeFIFO(at: fifoPath)

        let probe = BurnBarFleetClaudeCodeProbe(
            agentID: .claudeCode,
            rootPath: fixtureRoot.path,
            readTimeoutSeconds: 0.5
        )
        let now = Date()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = await probe.probe(now: now)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        XCTAssertLessThan(elapsed, 3.0, "probe must be bounded by the per-probe timeout")
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("timed out"), "unexpected reason: \(reason)")
        } else {
            XCTFail("FIFO session file must be typed degraded with a timeout reason, got \(result.health.state)")
        }
    }

    // MARK: - VAL-FLEET-019: the tick continues on cadence with a FIFO present

    func testTickerContinuesWithFIFOPresent() async throws {
        // Grok-bot root with a FIFO daemon signal; all other roots empty.
        let rootsDir = fixtureRoot.appendingPathComponent("roots", isDirectory: true)
        try FileManager.default.createDirectory(at: rootsDir, withIntermediateDirectories: true)
        let grokbotDir = rootsDir.appendingPathComponent("grokbot", isDirectory: true)
        try FileManager.default.createDirectory(at: grokbotDir, withIntermediateDirectories: true)
        try makeFIFO(at: grokbotDir.appendingPathComponent("local-exec-daemon.json").path)

        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": rootsDir.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 1,
            probes: BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        )
        let service = BurnBarFleetService(builder: builder)
        await service.start()

        // Collect generatedAt over several ticks: the FIFO must not freeze
        // the ticker. Each tick costs the FIFO probe's 2 s timeout plus the
        // 1 s cadence, so the window must span several generations.
        var generations: [Date] = []
        let deadline = DispatchTime.now().uptimeNanoseconds + 11_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if case .ready(let snapshot) = await service.readLatestSnapshot() {
                if generations.last != snapshot.generatedAt {
                    generations.append(snapshot.generatedAt)
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await service.stop()

        XCTAssertGreaterThanOrEqual(generations.count, 3, "ticker must keep advancing with a FIFO present, got \(generations.count) generations")

        // The grok-bot row degrades typed; the roster stays complete.
        if case .ready(let snapshot) = await service.readLatestSnapshot() {
            XCTAssertEqual(snapshot.agents.count, 10)
            let grokbot = try XCTUnwrap(snapshot.agents.first { $0.id == .grokBot })
            XCTAssertNotEqual(grokbot.status, .running)
            let health = try XCTUnwrap(snapshot.probeHealth.first { $0.agent == .grokBot })
            if case .degraded(let reason) = health.state {
                XCTAssertTrue(reason.contains("timed out"), "unexpected reason: \(reason)")
            } else {
                XCTFail("FIFO grok-bot must be typed degraded, got \(health.state)")
            }
        } else {
            XCTFail("snapshot must be ready after ticks")
        }
    }

    // MARK: - Bounded reader unit behavior

    func testReadJSONBounded_regularFileParses() throws {
        let path = fixtureRoot.appendingPathComponent("regular.json").path
        try writeJSONFixture(["pid": 1], to: path)

        let parsed = try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: 1.0)
        let dictionary = try XCTUnwrap(parsed as? [String: Any])
        XCTAssertEqual(dictionary["pid"] as? Int, 1)
    }

    func testReadJSONBounded_missingFile_throwsUnreadable() {
        let path = fixtureRoot.appendingPathComponent("missing.json").path
        XCTAssertThrowsError(try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: 0.5)) { error in
            guard case BurnBarFleetProbeReadError.unreadable = error else {
                return XCTFail("missing file must throw unreadable, got \(error)")
            }
        }
    }

    func testReadJSONBounded_invalidJSON_throws() throws {
        let path = fixtureRoot.appendingPathComponent("invalid.json").path
        try "{not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BurnBarFleetProbeJSON.readJSONBounded(at: path, timeoutSeconds: 1.0))
    }

    func testReadFailureReason_mapsTyped() {
        XCTAssertTrue(
            BurnBarFleetProbeJSON.readFailureReason(BurnBarFleetProbeReadError.timedOut).contains("timed out")
        )
        XCTAssertTrue(
            BurnBarFleetProbeJSON.readFailureReason(BurnBarFleetProbeReadError.unreadable(2)).contains("not readable")
        )
        XCTAssertTrue(
            BurnBarFleetProbeJSON.readFailureReason(
                DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
            ).contains("not valid JSON")
        )
    }
}

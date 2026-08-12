import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Regression tests for the probe-hardening-repair-a follow-up (scrutiny
/// round 2, reviewer report probe-hardening-repair-a.json). Kept in a
/// dedicated file so the original probe test classes stay under the lint
/// type-body budget (precedent: BurnBarFleetProbeHardeningBTests.swift).
///
/// Covers the two blocking edge cases for the Factory Droid probe:
/// 1. A PRESENT-but-invalid background-entry `startTime` (boolean,
///    fractional, non-numeric) must degrade the entry typed — it is never
///    silently converted to nil and treated like an ABSENT record (which
///    would skip the pid-reuse guard and let a live pid pass liveness).
///    An absent `startTime` keeps the documented fallback behavior.
/// 2. Integral JSON pid values outside the positive macOS pid_t range
///    (zero, negative, larger than Int32.max) are rejected BEFORE any
///    pid_t/liveness conversion — no trap, typed non-running/degraded
///    output. The same range guard is applied at every JSON-number→pid_t
///    site in the Fleet probe layer (claude-code, grok-cli, grok-bot,
///    hermes); those cross-probe cases live in
///    BurnBarFleetProbeHardeningCTests2.swift.
final class BurnBarFleetProbeHardeningCTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-probe-hardening-c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private func writeBackgroundProcesses(_ processes: [[String: Any]]) throws {
        try writeJSONFixture(
            ["processes": processes],
            to: fixtureRoot.appendingPathComponent("background-processes.json").path
        )
    }

    private func makeFactoryProbe() -> BurnBarFleetFactoryDroidProbe {
        BurnBarFleetFactoryDroidProbe(agentID: .factoryDroid, rootPath: fixtureRoot.path)
    }

    // MARK: - Issue 1: PRESENT-but-invalid Factory startTime degrades typed

    func testFactoryBackgroundEntry_booleanStartTime_livePid_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // A live pid with startTime: true. The malformed startTime must
        // degrade the entry typed — it is never converted to nil and
        // treated like an absent record (which would skip the pid-reuse
        // guard and let the live pid pass liveness as healthy running).
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": true
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("startTime"), "reason must name the malformed startTime: \(reason)")
            XCTAssertTrue(reason.contains("boolean"), "reason must name the malformed value: \(reason)")
        } else {
            XCTFail("invalid startTime must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryBackgroundEntry_fractionalStartTime_livePid_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": 1_750_000_000.5
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("startTime"), "reason must name the malformed startTime: \(reason)")
            XCTAssertTrue(reason.contains("fractional"), "reason must name the malformed value: \(reason)")
        } else {
            XCTFail("invalid startTime must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryBackgroundEntry_stringStartTime_livePid_typedDegradedNeverRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": "not-a-number"
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("startTime"), "reason must name the malformed startTime: \(reason)")
        } else {
            XCTFail("invalid startTime must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryBackgroundEntry_absentStartTime_livePid_keepsFallbackRunning() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        // No startTime key at all: the documented fallback behavior is
        // preserved — the pid-reuse guard is skipped and kill -0 decides,
        // so a live pid still drives running.
        try writeBackgroundProcesses([
            [
                "pid": Int(live.pid),
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB"
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoB")
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Issue 2: out-of-range pids never trap, never report running

    func testFactoryBackgroundEntry_pidZero_typedDegradedNeverRunning() async throws {
        let now = Date()
        try writeBackgroundProcesses([
            [
                "pid": 0,
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("positive"), "reason must name the malformed pid: \(reason)")
        } else {
            XCTFail("pid 0 must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryBackgroundEntry_pidNegative_typedDegradedNeverRunning() async throws {
        let now = Date()
        try writeBackgroundProcesses([
            [
                "pid": -1,
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("positive"), "reason must name the malformed pid: \(reason)")
        } else {
            XCTFail("negative pid must be typed degraded, got \(result.health.state)")
        }
    }

    func testFactoryBackgroundEntry_pidHuge_typedDegradedNeverRunning() async throws {
        let now = Date()
        // 3000000000 is integral but beyond Int32.max: the strict pid helper
        // must reject it BEFORE any pid_t conversion (which would trap).
        try writeBackgroundProcesses([
            [
                "pid": 3_000_000_000,
                "command": "sleep 300",
                "cwd": "/Users/test/RepoB",
                "startTime": Int(now.timeIntervalSince1970 * 1000)
            ]
        ])

        let result = await makeFactoryProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("pid_t"), "reason must name the pid_t range: \(reason)")
        } else {
            XCTFail("huge pid must be typed degraded, got \(result.health.state)")
        }
    }
}

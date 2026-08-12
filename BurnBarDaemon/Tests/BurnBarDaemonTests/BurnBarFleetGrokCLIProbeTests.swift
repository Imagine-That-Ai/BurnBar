import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarFleetGrokCLIProbeTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-grokcli-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var registryPath: String {
        fixtureRoot.appendingPathComponent("active_sessions.json").path
    }

    private func makeProbe(fileFreshnessSeconds: TimeInterval = 300) -> BurnBarFleetGrokCLIProbe {
        BurnBarFleetGrokCLIProbe(agentID: .grokCLI, rootPath: fixtureRoot.path, fileFreshnessSeconds: fileFreshnessSeconds)
    }

    private func writeRegistry(_ entries: [[String: Any]]) throws {
        try writeJSONFixture(entries, to: registryPath)
    }

    // MARK: - VAL-FLEET-013 rung (i): live pid → running + exactProcess

    func testLivePid_runningExactProcess() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeRegistry([
            [
                "session_id": "019ff37c-0001",
                "pid": Int(live.pid),
                "cwd": "/Users/test/RepoA",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoA")
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.map(\.path), [registryPath])
        XCTAssertEqual(result.agent.signals.first?.kind, "session-registry")
    }

    // MARK: - VAL-FLEET-013 rung (ii): pid dead but file fresh → activeSessionFile

    func testDeadPidFreshFile_activeSessionFile_neverRunning() async throws {
        let now = Date()
        try writeRegistry([
            [
                "session_id": "019ff37c-0002",
                "pid": 999_999,
                "cwd": "/Users/test/RepoA",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])
        try setFileMtime(now.addingTimeInterval(-10), at: registryPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.health.state, .ok)
    }

    func testDeadPidStaleFile_staleActiveSessionFile() async throws {
        let now = Date()
        try writeRegistry([
            [
                "session_id": "019ff37c-0003",
                "pid": 999_999,
                "cwd": "/Users/test/RepoA",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])
        try setFileMtime(now.addingTimeInterval(-600), at: registryPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.agent.status, .stale)
    }

    // MARK: - VAL-FLEET-013 rung (iii): empty/absent file → idle/unknown

    func testEmptyRegistry_idle() async throws {
        let now = Date()
        try writeRegistry([])
        try setFileMtime(now.addingTimeInterval(-10), at: registryPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.health.state, .ok)
    }

    func testAbsentRegistry_idle() async throws {
        let now = Date()
        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.map(\.path), [registryPath])
    }

    func testRootMissing_failedHealth() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path
        let result = await BurnBarFleetGrokCLIProbe(agentID: .grokCLI, rootPath: missingRoot).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
    }

    // MARK: - Multi-session: one live entry drives the row

    func testMultiEntry_liveEntryDrivesRow_deadEntryNeverMasks() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeRegistry([
            [
                "session_id": "dead-entry",
                "pid": 999_999,
                "cwd": "/Users/test/DeadRepo",
                "opened_at": "2026-08-12T01:01:05Z"
            ],
            [
                "session_id": "live-entry",
                "pid": Int(live.pid),
                "cwd": "/Users/test/LiveRepo",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        XCTAssertEqual(result.agent.projectName, "/Users/test/LiveRepo")
        XCTAssertEqual(result.agent.signals.count, 2)
    }

    // MARK: - VAL-FLEET-024: malformed shape isolation

    func testMalformedEntry_missingPid_typedNeverRunning() async throws {
        let now = Date()
        try writeRegistry([
            [
                "session_id": "019ff37c-0004",
                "cwd": "/Users/test/RepoA",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])
        try setFileMtime(now.addingTimeInterval(-10), at: registryPath)

        let result = await makeProbe().probe(now: now)

        // Fresh file + malformed entry: the file-freshness rung applies
        // (non-running, activeSessionFile) with a typed degraded health.
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed shape must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedEntry_mistypedPid_typedNeverRunning() async throws {
        let now = Date()
        try writeRegistry([
            [
                "session_id": "019ff37c-0005",
                "pid": "not-a-number",
                "cwd": "/Users/test/RepoA",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])
        try setFileMtime(now.addingTimeInterval(-10), at: registryPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("malformed shape must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedEntry_staleFile_typedUnknown() async throws {
        let now = Date()
        try writeRegistry([
            [
                "session_id": "019ff37c-0006",
                "cwd": "/Users/test/RepoA",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])
        try setFileMtime(now.addingTimeInterval(-600), at: registryPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("malformed shape must be typed degraded, got \(result.health.state)")
        }
    }

    func testMalformedEntry_siblingLiveEntryUnaffected() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()
        try writeRegistry([
            [
                "session_id": "malformed-entry",
                "cwd": "/Users/test/RepoA",
                "opened_at": "2026-08-12T01:01:05Z"
            ],
            [
                "session_id": "live-entry",
                "pid": Int(live.pid),
                "cwd": "/Users/test/LiveRepo",
                "opened_at": "2026-08-12T01:01:05Z"
            ]
        ])

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .exactProcess)
        XCTAssertEqual(result.agent.process?.pid, Int(live.pid))
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed sibling must surface a typed degraded health, got \(result.health.state)")
        }
    }

    func testNotJSONArray_typedUnknownNeverRunning() async throws {
        let now = Date()
        try writeJSONFixture(["not": "an array"], to: registryPath)
        try setFileMtime(now.addingTimeInterval(-10), at: registryPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("not a JSON array"), "unexpected reason: \(reason)")
        } else {
            XCTFail("non-array registry must be typed degraded, got \(result.health.state)")
        }
    }
}

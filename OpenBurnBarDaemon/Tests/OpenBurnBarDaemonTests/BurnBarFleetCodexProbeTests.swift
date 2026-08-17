import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Codex probe tests: thread-writer-locks mtimes + corroboration mtimes.
///
/// Covers VAL-FLEET-006 (logHeartbeat confidence, never exactProcess) and
/// the fresh/stale mtime rules pinned in BURNBAR_FLEET_SIGNALS.md.
final class BurnBarFleetCodexProbeTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-codex-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var locksDirectory: URL {
        fixtureRoot.appendingPathComponent("thread-writer-locks", isDirectory: true)
    }

    private func makeProbe(lockFreshnessSeconds: TimeInterval = 300) -> BurnBarFleetCodexProbe {
        BurnBarFleetCodexProbe(agentID: .codex, rootPath: fixtureRoot.path, lockFreshnessSeconds: lockFreshnessSeconds)
    }

    private func writeLock(named name: String, mtime: Date) throws {
        let directory = locksDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name).path
        try Data().write(to: URL(fileURLWithPath: path))
        try setFileMtime(mtime, at: path)
    }

    // MARK: - VAL-FLEET-006: fresh lock → running + logHeartbeat

    func testFreshLock_runningLogHeartbeat_neverExactProcess() async throws {
        let now = Date()
        try writeLock(named: "thread-1.lock", mtime: now.addingTimeInterval(-10))

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertNil(result.agent.process, "codex has no pid registry; process must be absent")
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.map(\.kind), ["lock-file"])
        XCTAssertEqual(result.agent.lastActivityAt?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(-10).timeIntervalSince1970,
                       accuracy: 1.0)
    }

    // MARK: - VAL-FLEET-006: stale lock → non-running, confidence stays logHeartbeat

    func testStaleLock_nonRunningLogHeartbeat() async throws {
        let now = Date()
        try writeLock(named: "thread-1.lock", mtime: now.addingTimeInterval(-3600))

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - No locks at all

    func testNoLocks_idleLogHeartbeat() async throws {
        let now = Date()
        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertEqual(result.health.state, .ok)
    }

    func testRootMissing_failedHealth() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path
        let result = await BurnBarFleetCodexProbe(agentID: .codex, rootPath: missingRoot).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
    }

    // MARK: - Corroboration mtimes

    func testStaleLockFreshCorroboration_idleNotRunning() async throws {
        let now = Date()
        try writeLock(named: "thread-1.lock", mtime: now.addingTimeInterval(-3600))
        let walPath = fixtureRoot.appendingPathComponent("state_5.sqlite-wal").path
        try Data().write(to: URL(fileURLWithPath: walPath))
        try setFileMtime(now.addingTimeInterval(-10), at: walPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertEqual(result.agent.signals.map(\.kind).sorted(), ["lock-file", "log-mtime"])
    }

    func testFreshLockWinsOverStaleCorroboration() async throws {
        let now = Date()
        try writeLock(named: "thread-1.lock", mtime: now.addingTimeInterval(-10))
        let walPath = fixtureRoot.appendingPathComponent("state_5.sqlite-wal").path
        try Data().write(to: URL(fileURLWithPath: walPath))
        try setFileMtime(now.addingTimeInterval(-3600), at: walPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
    }

    // MARK: - Non-lock files in the locks directory are ignored

    func testNonLockFilesIgnored() async throws {
        let now = Date()
        let directory = locksDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let strayPath = directory.appendingPathComponent("notes.txt").path
        try "stray".write(toFile: strayPath, atomically: true, encoding: .utf8)
        try setFileMtime(now.addingTimeInterval(-10), at: strayPath)

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertTrue(result.agent.signals.isEmpty, "non-lock files must not appear as signals")
    }
}

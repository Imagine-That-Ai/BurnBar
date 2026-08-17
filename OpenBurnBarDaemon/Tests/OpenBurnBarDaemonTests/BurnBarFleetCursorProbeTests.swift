import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Cursor probe tests (partial confidence): agent-cli-state.json worker ids
/// + ai-tracking/ mtime.
///
/// Covers VAL-CONTRACT-017 (worker-id + mtime rule, partial activeSessionFile
/// confidence, never exactProcess) and the fresh/stale degradation.
final class BurnBarFleetCursorProbeTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-cursor-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var statePath: String {
        fixtureRoot.appendingPathComponent("agent-cli-state.json").path
    }

    private var trackingPath: String {
        fixtureRoot.appendingPathComponent("ai-tracking", isDirectory: true).path
    }

    private func makeProbe(trackingFreshnessSeconds: TimeInterval = 300) -> BurnBarFleetCursorProbe {
        BurnBarFleetCursorProbe(
            agentID: .cursor,
            rootPath: fixtureRoot.path,
            trackingFreshnessSeconds: trackingFreshnessSeconds
        )
    }

    private func writeState(workerIDs: [String: String]) throws {
        try writeJSONFixture(["workerIdsByDisplayName": workerIDs], to: statePath)
    }

    private func writeTracking(mtime: Date) throws {
        try FileManager.default.createDirectory(
            atPath: trackingPath,
            withIntermediateDirectories: true
        )
        try setFileMtime(mtime, at: trackingPath)
    }

    // MARK: - VAL-CONTRACT-017: worker ids + fresh tracking → running, partial confidence

    func testWorkerIDsFreshTracking_runningActiveSessionFile_neverExactProcess() async throws {
        let now = Date()
        try writeState(workerIDs: ["AgentLens @ albertonunez": "worker-1"])
        try writeTracking(mtime: now.addingTimeInterval(-10))

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process, "cursor has no pids; process must be absent")
        XCTAssertEqual(result.agent.projectName, "AgentLens")
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.map(\.kind).sorted(), ["log-mtime", "session-registry"])
    }

    // MARK: - VAL-CONTRACT-017: stale tracking degrades honestly

    func testWorkerIDsStaleTracking_staleActiveSessionFile() async throws {
        let now = Date()
        try writeState(workerIDs: ["AgentLens @ albertonunez": "worker-1"])
        try writeTracking(mtime: now.addingTimeInterval(-3600))

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Absent worker ids → idle

    func testNoWorkerIDs_idleNotRunning() async throws {
        let now = Date()
        try writeState(workerIDs: [:])
        try writeTracking(mtime: now.addingTimeInterval(-10))

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.health.state, .ok)
    }

    func testStateFileAbsent_idleNotRunning() async throws {
        let now = Date()
        try writeTracking(mtime: now.addingTimeInterval(-10))

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Malformed shape isolation

    func testMalformedState_missingWorkerIds_typedUnknownNeverRunning() async throws {
        let now = Date()
        try writeJSONFixture(["someOtherKey": 1], to: statePath)
        try writeTracking(mtime: now.addingTimeInterval(-10))

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("workerIdsByDisplayName"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed state must be typed degraded, got \(result.health.state)")
        }
    }

    func testStateNotJSONObject_typedUnknownNeverRunning() async throws {
        let now = Date()
        try writeJSONFixture(["not": "an object"], to: statePath)

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .degraded = result.health.state {
            // typed degraded
        } else {
            XCTFail("non-object state must be typed degraded, got \(result.health.state)")
        }
    }

    // MARK: - Root states

    func testRootMissing_failedHealth() async throws {
        let now = Date()
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true).path
        let result = await BurnBarFleetCursorProbe(agentID: .cursor, rootPath: missingRoot).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
    }

    func testRootPresentNoSignals_idleActiveSessionFile() async throws {
        let now = Date()
        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .activeSessionFile)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - Display-name decode

    func testProjectNameFromDisplayName() {
        XCTAssertEqual(BurnBarFleetCursorProbe.projectName(fromDisplayName: "AgentLens @ albertonunez"), "AgentLens")
        XCTAssertEqual(BurnBarFleetCursorProbe.projectName(fromDisplayName: "plain-name"), "plain-name")
        XCTAssertNil(BurnBarFleetCursorProbe.projectName(fromDisplayName: " @ host"))
    }
}

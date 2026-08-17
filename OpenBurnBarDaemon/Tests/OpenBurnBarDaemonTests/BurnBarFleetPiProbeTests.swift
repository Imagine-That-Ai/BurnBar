import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Pi probe tests: `agent/sessions/<project-dir>/*.jsonl` transcript mtimes.
///
/// Covers VAL-FLEET-006 (logHeartbeat confidence, never exactProcess), the
/// fresh/stale mtime rules, and the `--`-encoded project-dir decode.
final class BurnBarFleetPiProbeTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-pi-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var sessionsDirectory: URL {
        fixtureRoot.appendingPathComponent("agent/sessions", isDirectory: true)
    }

    private func makeProbe(transcriptFreshnessSeconds: TimeInterval = 300) -> BurnBarFleetPiProbe {
        BurnBarFleetPiProbe(
            agentID: .pi,
            rootPath: fixtureRoot.path,
            transcriptFreshnessSeconds: transcriptFreshnessSeconds
        )
    }

    private func writeTranscript(projectDir: String, name: String, mtime: Date) throws {
        let projectURL = sessionsDirectory.appendingPathComponent(projectDir, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let path = projectURL.appendingPathComponent(name).path
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
        try setFileMtime(mtime, at: path)
    }

    // MARK: - VAL-FLEET-006: fresh transcript → running + logHeartbeat

    func testFreshTranscript_runningLogHeartbeat_neverExactProcess() async throws {
        let now = Date()
        try writeTranscript(
            projectDir: "--Users--test--RepoA",
            name: "2026-08-12T00-58-36-546Z_abc.jsonl",
            mtime: now.addingTimeInterval(-10)
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertNil(result.agent.process, "pi has no pid registry; process must be absent")
        XCTAssertEqual(result.agent.projectName, "/Users/test/RepoA")
        XCTAssertEqual(result.health.state, .ok)
        XCTAssertEqual(result.agent.signals.map(\.kind), ["log-mtime"])
        XCTAssertEqual(result.threads.filter { $0.status == .running }.count, 1)
    }

    func testTwoFreshTranscripts_emitTwoRunningThreads() async throws {
        let now = Date()
        try writeTranscript(
            projectDir: "--Users--test--RepoA",
            name: "one.jsonl",
            mtime: now.addingTimeInterval(-10)
        )
        try writeTranscript(
            projectDir: "--Users--test--RepoB",
            name: "two.jsonl",
            mtime: now.addingTimeInterval(-20)
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.threads.filter { $0.status == .running }.count, 2)
        XCTAssertEqual(Set(result.threads.map(\.id)), Set(["one", "two"]))
    }

    // MARK: - VAL-FLEET-006: stale transcript → non-running, confidence stays logHeartbeat

    func testStaleTranscript_nonRunningLogHeartbeat() async throws {
        let now = Date()
        try writeTranscript(
            projectDir: "--Users--test--RepoA",
            name: "2026-08-12T00-58-36-546Z_abc.jsonl",
            mtime: now.addingTimeInterval(-3600)
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.status, .stale)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertNil(result.agent.process)
        XCTAssertEqual(result.health.state, .ok)
    }

    // MARK: - No transcripts at all

    func testNoTranscripts_idleLogHeartbeat() async throws {
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
        let result = await BurnBarFleetPiProbe(agentID: .pi, rootPath: missingRoot).probe(now: now)

        XCTAssertEqual(result.agent.status, .unknown)
        XCTAssertEqual(result.agent.confidence, .unsupported)
        if case .failed(let reason) = result.health.state {
            XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
        } else {
            XCTFail("missing root must be typed failed, got \(result.health.state)")
        }
    }

    // MARK: - Config files are never a live signal

    func testConfigFilesOnly_idleNotRunning() async throws {
        let now = Date()
        let agentDir = fixtureRoot.appendingPathComponent("agent", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        for name in ["models.json", "settings.json", "trust.json"] {
            let path = agentDir.appendingPathComponent(name).path
            try "{}".write(toFile: path, atomically: true, encoding: .utf8)
            try setFileMtime(now.addingTimeInterval(-10), at: path)
        }

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .idle)
        XCTAssertNotEqual(result.agent.status, .running)
        XCTAssertTrue(result.agent.signals.isEmpty, "config files must never be live signals")
    }

    // MARK: - Project-dir decode (VAL-PROV-011 rule: split only on `--`)

    func testProjectNameDecode_singleHyphensPreserved() async throws {
        let now = Date()
        try writeTranscript(
            projectDir: "--Users--test--my-cool-proj",
            name: "2026-08-12T00-58-36-546Z_abc.jsonl",
            mtime: now.addingTimeInterval(-10)
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.projectName, "/Users/test/my-cool-proj")
    }

    func testProjectNameDecode_deepPath() async throws {
        let now = Date()
        try writeTranscript(
            projectDir: "--Users--albertonunez--Developer--AgentLens",
            name: "2026-08-12T00-58-36-546Z_abc.jsonl",
            mtime: now.addingTimeInterval(-10)
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.projectName, "/Users/albertonunez/Developer/AgentLens")
    }

    func testProjectNameDecode_plainSlugReturnedAsIs() async throws {
        let now = Date()
        try writeTranscript(
            projectDir: "plain-project",
            name: "2026-08-12T00-58-36-546Z_abc.jsonl",
            mtime: now.addingTimeInterval(-10)
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.projectName, "plain-project")
    }

    // MARK: - Newest transcript drives the row

    func testNewestTranscriptDrivesRow() async throws {
        let now = Date()
        try writeTranscript(
            projectDir: "--Users--test--OldRepo",
            name: "old.jsonl",
            mtime: now.addingTimeInterval(-3600)
        )
        try writeTranscript(
            projectDir: "--Users--test--NewRepo",
            name: "new.jsonl",
            mtime: now.addingTimeInterval(-10)
        )

        let result = await makeProbe().probe(now: now)

        XCTAssertEqual(result.agent.status, .running)
        XCTAssertEqual(result.agent.confidence, .logHeartbeat)
        XCTAssertEqual(result.agent.projectName, "/Users/test/NewRepo")
        XCTAssertEqual(result.agent.signals.count, 2)
    }
}

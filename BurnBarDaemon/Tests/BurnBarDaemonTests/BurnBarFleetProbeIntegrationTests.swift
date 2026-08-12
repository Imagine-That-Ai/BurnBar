import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Integration tests: the snapshot builder running the real file/pid-based
/// probes against a fixture root tree. Covers sibling isolation, the
/// declared-roots-only evidence rule, and the fixed-roster merge.
final class BurnBarFleetProbeIntegrationTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-probe-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private func makeBuilder() -> BurnBarFleetSnapshotBuilder {
        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": fixtureRoot.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        return BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 15,
            probes: BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        )
    }

    private func writeJSON(_ object: Any, to relativePath: String) throws {
        try writeJSONFixture(object, to: fixtureRoot.appendingPathComponent(relativePath).path)
    }

    // MARK: - Mixed fixture: one running, one idle, one unknown

    func testMixedFixture_runningIdleUnknownRows() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()

        // claude: live pid + fresh updatedAt → running/exactProcess.
        let claudeDir = fixtureRoot.appendingPathComponent("claude/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try writeJSON(
            [
                "pid": Int(live.pid),
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            to: "claude/sessions/\(live.pid).json"
        )

        // grok-cli: empty registry → idle.
        try writeJSON([], to: "grok/active_sessions.json")

        // factory-droid: root present, no signal files → idle.
        try FileManager.default.createDirectory(
            at: fixtureRoot.appendingPathComponent("factory", isDirectory: true),
            withIntermediateDirectories: true
        )

        let snapshot = try await makeBuilder().build(now: now)

        let claude = try XCTUnwrap(snapshot.agents.first { $0.id == .claudeCode })
        XCTAssertEqual(claude.status, .running)
        XCTAssertEqual(claude.confidence, .exactProcess)
        XCTAssertEqual(claude.process?.pid, Int(live.pid))

        let grok = try XCTUnwrap(snapshot.agents.first { $0.id == .grokCLI })
        XCTAssertEqual(grok.status, .idle)
        XCTAssertNotEqual(grok.status, .running)

        let factory = try XCTUnwrap(snapshot.agents.first { $0.id == .factoryDroid })
        XCTAssertNotEqual(factory.status, .running)

        // Fixed roster intact.
        XCTAssertEqual(snapshot.agents.count, 10)
        XCTAssertEqual(snapshot.probeHealth.count, 10)
        XCTAssertEqual(snapshot.runningCount, 1)
        XCTAssertEqual(snapshot.countsByAgent["claude-code"], 1)
    }

    // MARK: - VAL-FLEET-016: signal evidence paths stay inside declared roots

    func testSignalEvidencePaths_insideDeclaredRoots() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()

        let claudeDir = fixtureRoot.appendingPathComponent("claude/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try writeJSON(
            [
                "pid": Int(live.pid),
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            to: "claude/sessions/\(live.pid).json"
        )
        try writeJSON(
            [
                [
                    "session_id": "g1",
                    "pid": Int(live.pid),
                    "cwd": "/Users/test/RepoB",
                    "opened_at": "2026-08-12T01:01:05Z"
                ]
            ],
            to: "grok/active_sessions.json"
        )
        try writeJSON(
            ["invocations": [
                [
                    "taskInvocationId": "t1",
                    "status": "running",
                    "cwd": "/Users/test/RepoC",
                    "updatedAt": Int(now.timeIntervalSince1970 * 1000)
                ]
            ]],
            to: "factory/task-invocations.json"
        )

        let snapshot = try await makeBuilder().build(now: now)

        let declaredRoots: [BurnBarFleetAgentID: String] = [
            .claudeCode: fixtureRoot.appendingPathComponent("claude").path,
            .grokCLI: fixtureRoot.appendingPathComponent("grok").path,
            .factoryDroid: fixtureRoot.appendingPathComponent("factory").path
        ]

        for agent in snapshot.agents {
            guard let root = declaredRoots[agent.id] else { continue }
            if agent.status == .running || agent.status == .idle {
                XCTAssertFalse(agent.signals.isEmpty, "determined rows must carry signal evidence: \(agent.id)")
            }
            for signal in agent.signals {
                XCTAssertTrue(
                    signal.path.hasPrefix(root + "/") || signal.path == root,
                    "signal path \(signal.path) is outside declared root \(root) for \(agent.id)"
                )
            }
        }
    }

    // MARK: - VAL-FLEET-024: malformed signal isolation across agents

    func testMalformedSignal_degradesOnlyItsRow_siblingsUnchanged() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()

        // Baseline: claude running, grok-cli running.
        let claudeDir = fixtureRoot.appendingPathComponent("claude/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try writeJSON(
            [
                "pid": Int(live.pid),
                "sessionId": "s1",
                "cwd": "/Users/test/RepoA",
                "updatedAt": Int(now.timeIntervalSince1970 * 1000)
            ],
            to: "claude/sessions/\(live.pid).json"
        )
        try writeJSON(
            [
                [
                    "session_id": "g1",
                    "pid": Int(live.pid),
                    "cwd": "/Users/test/RepoB",
                    "opened_at": "2026-08-12T01:01:05Z"
                ]
            ],
            to: "grok/active_sessions.json"
        )

        let baseline = try await makeBuilder().build(now: now)
        let baselineClaude = try XCTUnwrap(baseline.agents.first { $0.id == .claudeCode })
        let baselineGrok = try XCTUnwrap(baseline.agents.first { $0.id == .grokCLI })
        XCTAssertEqual(baselineClaude.status, .running)
        XCTAssertEqual(baselineGrok.status, .running)

        // Corrupt grok-cli's registry: missing pid in the entry.
        try writeJSON(
            [
                [
                    "session_id": "g1",
                    "cwd": "/Users/test/RepoB",
                    "opened_at": "2026-08-12T01:01:05Z"
                ]
            ],
            to: "grok/active_sessions.json"
        )

        let corrupted = try await makeBuilder().build(now: now)

        // grok-cli degrades typed; claude row unchanged.
        let corruptedGrok = try XCTUnwrap(corrupted.agents.first { $0.id == .grokCLI })
        XCTAssertNotEqual(corruptedGrok.status, .running)
        XCTAssertEqual(corruptedGrok.confidence, .activeSessionFile)
        let grokHealth = try XCTUnwrap(corrupted.probeHealth.first { $0.agent == .grokCLI })
        if case .degraded(let reason) = grokHealth.state {
            XCTAssertTrue(reason.contains("malformed"), "unexpected reason: \(reason)")
        } else {
            XCTFail("malformed grok registry must be typed degraded, got \(grokHealth.state)")
        }

        let corruptedClaude = try XCTUnwrap(corrupted.agents.first { $0.id == .claudeCode })
        XCTAssertEqual(corruptedClaude.status, baselineClaude.status)
        XCTAssertEqual(corruptedClaude.confidence, baselineClaude.confidence)
        XCTAssertEqual(corruptedClaude.process?.pid, baselineClaude.process?.pid)
    }

    // MARK: - VAL-FLEET-014: artifacts sentinel absent from the full snapshot

    func testArtifactsSentinel_absentFromSnapshotPayload() async throws {
        let now = Date()
        let artifactsDir = fixtureRoot.appendingPathComponent("factory/artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        let sentinel = "ARTIFACTS-SENTINEL-\(UUID().uuidString)"
        try sentinel.write(
            toFile: artifactsDir.appendingPathComponent("sentinel.txt").path,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try await makeBuilder().build(now: now)

        let encoder = JSONEncoder()
        let payload = String(data: try encoder.encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(payload.contains(sentinel), "artifacts sentinel must never appear in the snapshot payload")
        XCTAssertFalse(payload.contains("artifacts"), "artifacts paths must never appear in the snapshot payload")

        let factory = try XCTUnwrap(snapshot.agents.first { $0.id == .factoryDroid })
        XCTAssertNotEqual(factory.status, .running, "fresh artifacts content must not drive factory-droid running")
    }
}

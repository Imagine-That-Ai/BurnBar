import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// Seven-agent detection lifecycle matrix (VAL-FLEET-026).
///
/// For each of `claude-code`, `factory-droid`, `codex`, `hermes`, `grok-bot`,
/// `grok-cli`, and `pi`, the probe is exercised through every applicable
/// phase: declared root absent; root installed with no active signal;
/// canonical running signal; canonical idle/infrastructure-only signal where
/// defined; exited signal (previously live pid dead or active signal
/// removed); signal older than the agent's documented freshness constant; and
/// malformed primary signal. Every phase must produce exactly one provider
/// row and one health entry with the documented status/confidence; exited,
/// stale, and malformed phases never report running; malformed input degrades
/// only its provider.
///
/// Fixture builders and phase expectations live in
/// `BurnBarFleetLifecycleFixtures` (separate file to keep this class under
/// the lint type-body budget).
final class BurnBarFleetLifecycleMatrixTests: XCTestCase {
    private var fixtureRoot: URL!
    private var liveProcess: LiveSleepProcess?

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-lifecycle-matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        liveProcess?.terminate()
        liveProcess = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    /// One probe for one agent against a fresh per-phase fixture root.
    private func makeProbe(for agentID: BurnBarFleetAgentID, root: URL) -> any BurnBarFleetProbe {
        switch agentID {
        case .claudeCode:
            return BurnBarFleetClaudeCodeProbe(agentID: agentID, rootPath: root.path)
        case .factoryDroid:
            return BurnBarFleetFactoryDroidProbe(agentID: agentID, rootPath: root.path)
        case .codex:
            return BurnBarFleetCodexProbe(agentID: agentID, rootPath: root.path)
        case .hermes:
            return BurnBarFleetHermesProbe(agentID: agentID, rootPath: root.path)
        case .grokBot:
            return BurnBarFleetGrokBotProbe(agentID: agentID, rootPath: root.path)
        case .grokCLI:
            return BurnBarFleetGrokCLIProbe(agentID: agentID, rootPath: root.path)
        case .pi:
            return BurnBarFleetPiProbe(agentID: agentID, rootPath: root.path)
        default:
            XCTFail("unexpected agent in matrix: \(agentID)")
            return BurnBarFleetUnsupportedProbe(agentID: agentID, rootPath: root.path, note: "unexpected")
        }
    }

    /// A fresh per-phase root directory. The "absent" phase uses a path that
    /// is never created so the declared root genuinely does not exist.
    private func phaseRoot(_ name: String, create: Bool = true) throws -> URL {
        let root = fixtureRoot.appendingPathComponent(name, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// Runs one phase and returns the row + health.
    private func runPhase(
        agentID: BurnBarFleetAgentID,
        root: URL,
        now: Date
    ) async throws -> (agent: BurnBarFleetAgent, health: BurnBarFleetProbeHealth) {
        let result = await makeProbe(for: agentID, root: root).probe(now: now)
        return (result.agent, result.health)
    }

    /// Builds the fixture for one (agent, phase) via the shared builders.
    private func buildFixture(
        agentID: BurnBarFleetAgentID,
        root: URL,
        phase: String,
        now: Date,
        livePid: Int32?
    ) throws {
        switch agentID {
        case .claudeCode:
            try BurnBarFleetLifecycleFixtures.buildClaudeFixture(root: root, phase: phase, now: now, livePid: livePid)
        case .factoryDroid:
            try BurnBarFleetLifecycleFixtures.buildFactoryFixture(root: root, phase: phase, now: now)
        case .codex:
            try BurnBarFleetLifecycleFixtures.buildCodexFixture(root: root, phase: phase, now: now)
        case .hermes:
            try BurnBarFleetLifecycleFixtures.buildHermesFixture(root: root, phase: phase, now: now, livePid: livePid)
        case .grokBot:
            try BurnBarFleetLifecycleFixtures.buildGrokBotFixture(root: root, phase: phase, now: now, livePid: livePid)
        case .grokCLI:
            try BurnBarFleetLifecycleFixtures.buildGrokCLIFixture(root: root, phase: phase, now: now, livePid: livePid)
        case .pi:
            try BurnBarFleetLifecycleFixtures.buildPiFixture(root: root, phase: phase, now: now)
        default:
            break
        }
    }

    // MARK: - The matrix

    func testSevenAgentLifecycleMatrix() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()

        for agentID in BurnBarFleetLifecycleFixtures.agents {
            for phase in BurnBarFleetLifecycleFixtures.phases {
                // The "absent" phase must not create the root directory.
                let root = try phaseRoot("\(agentID.wireValue)-\(phase)", create: phase != "absent")

                // Fixture builders must not run for the absent phase: some
                // builders create subdirectories, which would materialize the
                // root and defeat the phase.
                if phase != "absent" {
                    try buildFixture(agentID: agentID, root: root, phase: phase, now: now, livePid: live.pid)
                }

                let (agent, health) = try await runPhase(agentID: agentID, root: root, now: now)

                // Exactly one row and one health entry per phase.
                XCTAssertEqual(agent.id, agentID, "\(agentID) \(phase): row identity")
                XCTAssertEqual(health.agent, agentID, "\(agentID) \(phase): health identity")
                XCTAssertEqual(health.rootPath, root.path, "\(agentID) \(phase): health root path")

                if phase == "absent" {
                    XCTAssertEqual(agent.status, .unknown, "\(agentID) absent: status")
                    XCTAssertEqual(agent.confidence, .unsupported, "\(agentID) absent: confidence")
                    if case .failed(let reason) = health.state {
                        XCTAssertTrue(reason.contains("Declared root missing"), "\(agentID) absent: \(reason)")
                    } else {
                        XCTFail("\(agentID) absent: health must be typed failed, got \(health.state)")
                    }
                    continue
                }

                if phase == "installed" {
                    // Root installed with no active signal: typed non-running.
                    XCTAssertNotEqual(agent.status, .running, "\(agentID) installed: never running")
                    continue
                }

                guard let expectation = BurnBarFleetLifecycleFixtures.expected(agentID, phase) else {
                    XCTFail("\(agentID) \(phase): missing expectation")
                    continue
                }

                XCTAssertEqual(
                    agent.status, expectation.status,
                    "\(agentID) \(phase): expected \(expectation.status.rawValue), got \(agent.status.rawValue)"
                )
                XCTAssertEqual(
                    agent.confidence, expectation.confidence,
                    "\(agentID) \(phase): expected \(expectation.confidence.rawValue), got \(agent.confidence.rawValue)"
                )

                // Exited/stale phases never report running. The malformed
                // phase is non-applicable for mtime-based probes (codex, pi):
                // their signal content is never read, so a malformed body
                // cannot degrade the row — the mtime rule still applies.
                if ["exited", "stale"].contains(phase) {
                    XCTAssertNotEqual(agent.status, .running, "\(agentID) \(phase): never running")
                }

                // Malformed phases degrade typed (degraded health) except
                // where the phase is documented non-applicable.
                if phase == "malformed", agentID != .codex, agentID != .pi {
                    if case .degraded = health.state {
                        // typed degraded
                    } else {
                        XCTFail("\(agentID) malformed: health must be typed degraded, got \(health.state)")
                    }
                }
            }
        }
    }

    // MARK: - Sibling isolation: one provider's malformed signal never changes another's row

    func testMalformedSignal_degradesOnlyItsProvider_siblingsUnchanged() async throws {
        let live = try LiveSleepProcess()
        liveProcess = live
        let now = Date()

        // Build a full fixture tree: all seven target agents running.
        let rootsDir = fixtureRoot.appendingPathComponent("matrix-roots", isDirectory: true)
        try FileManager.default.createDirectory(at: rootsDir, withIntermediateDirectories: true)

        for agentID in BurnBarFleetLifecycleFixtures.agents {
            let root = rootsDir.appendingPathComponent(
                BurnBarFleetRootResolver.rootDirectoryName(for: agentID),
                isDirectory: true
            )
            try buildFixture(agentID: agentID, root: root, phase: "running", now: now, livePid: live.pid)
        }

        let resolver = BurnBarFleetRootResolver(
            environment: ["BURNBAR_FLEET_ROOTS_DIR": rootsDir.path],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        let builder = BurnBarFleetSnapshotBuilder(
            cadenceSeconds: 15,
            probes: BurnBarFleetProbeFactory.makeDefaultProbes(rootResolver: resolver)
        )

        let baseline = try await builder.build(now: now)
        XCTAssertEqual(baseline.runningCount, 7, "all seven target agents running in baseline")

        // Corrupt grok-bot's daemon signal (missing inflightCount).
        let grokbotRoot = rootsDir.appendingPathComponent("grokbot", isDirectory: true)
        try writeJSONFixture(["pid": Int(live.pid)], to: grokbotRoot.appendingPathComponent("local-exec-daemon.json").path)

        let corrupted = try await builder.build(now: now)

        let corruptedGrokBot = try XCTUnwrap(corrupted.agents.first { $0.id == .grokBot })
        XCTAssertNotEqual(corruptedGrokBot.status, .running)
        XCTAssertEqual(corruptedGrokBot.status, .unknown)
        XCTAssertEqual(corruptedGrokBot.confidence, .unsupported)
        let grokBotHealth = try XCTUnwrap(corrupted.probeHealth.first { $0.agent == .grokBot })
        if case .degraded = grokBotHealth.state {
            // typed degraded
        } else {
            XCTFail("malformed grok-bot must be typed degraded, got \(grokBotHealth.state)")
        }

        // All siblings unchanged.
        for agentID in [BurnBarFleetAgentID.claudeCode, .factoryDroid, .codex, .hermes, .grokCLI, .pi] {
            let before = try XCTUnwrap(baseline.agents.first { $0.id == agentID })
            let after = try XCTUnwrap(corrupted.agents.first { $0.id == agentID })
            XCTAssertEqual(after.status, before.status, "\(agentID) status must be unchanged")
            XCTAssertEqual(after.confidence, before.confidence, "\(agentID) confidence must be unchanged")
            XCTAssertEqual(after.process?.pid, before.process?.pid, "\(agentID) process must be unchanged")
        }
        XCTAssertEqual(corrupted.runningCount, 6)
    }
}

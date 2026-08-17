import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Stub probe for builder tests: returns a fixed agent row and health state.
private struct StubProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID
    let rootPath: String
    let agent: BurnBarFleetAgent
    let healthState: BurnBarFleetProbeHealthState
    var threads: [BurnBarFleetThread] = []

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        BurnBarFleetProbeResult(
            agent: agent,
            health: BurnBarFleetProbeHealth(
                agent: agentID,
                state: healthState,
                rootPath: rootPath,
                checkedAt: now
            ),
            threads: threads
        )
    }
}

/// Stub probe that blocks briefly, used to hold the first tick open so the
/// pre-first-tick typed state is observable.
private struct SlowProbe: BurnBarFleetProbe {
    let agentID: BurnBarFleetAgentID
    let rootPath: String
    let delayNanoseconds: UInt64

    func probe(now: Date) async -> BurnBarFleetProbeResult {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        let agent = BurnBarFleetAgent(
            id: agentID,
            displayName: BurnBarFleetSnapshotBuilder.displayName(for: agentID),
            status: .unknown,
            confidence: .unsupported
        )
        return BurnBarFleetProbeResult(
            agent: agent,
            health: BurnBarFleetProbeHealth(
                agent: agentID,
                state: .ok,
                rootPath: rootPath,
                checkedAt: now
            )
        )
    }
}

final class BurnBarFleetSnapshotBuilderTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private func makeRootPresenceProbes(
        rootsDirectory: URL,
        createRoots: Bool
    ) -> [BurnBarFleetAgentID: any BurnBarFleetProbe] {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        for agentID in BurnBarFleetAgentID.declaredRoster {
            let rootPath = rootsDirectory
                .appendingPathComponent(BurnBarFleetRootResolver.rootDirectoryName(for: agentID), isDirectory: true)
                .path
            if createRoots {
                try? FileManager.default.createDirectory(
                    atPath: rootPath,
                    withIntermediateDirectories: true
                )
            }
            probes[agentID] = BurnBarFleetRootPresenceProbe(agentID: agentID, rootPath: rootPath)
        }
        return probes
    }

    private func makeBuilder(
        cadenceSeconds: Int = 15,
        probes: [BurnBarFleetAgentID: any BurnBarFleetProbe]? = nil
    ) -> BurnBarFleetSnapshotBuilder {
        BurnBarFleetSnapshotBuilder(
            cadenceSeconds: cadenceSeconds,
            probes: probes ?? makeRootPresenceProbes(rootsDirectory: fixtureRoot, createRoots: false)
        )
    }

    // MARK: - VAL-FLEET-007 / VAL-FLEET-015: empty roots, fixed roster

    func testEmptyRoots_allTenRowsUnknownUnsupported_neverRunning() async throws {
        let snapshot = try await makeBuilder().build()

        XCTAssertEqual(snapshot.agents.count, 10)
        XCTAssertEqual(snapshot.probeHealth.count, 10)
        XCTAssertEqual(snapshot.runningCount, 0)
        for agent in snapshot.agents {
            XCTAssertNotEqual(agent.status, .running, "empty roots must never report running: \(agent.id)")
            XCTAssertEqual(agent.confidence, .unsupported)
        }
        for health in snapshot.probeHealth {
            if case .failed(let reason) = health.state {
                XCTAssertTrue(reason.contains("Declared root missing"), "unexpected reason: \(reason)")
            } else {
                XCTFail("empty-root health must be typed failed, got \(health.state)")
            }
            XCTAssertFalse(health.rootPath.isEmpty, "probeHealth must name the root path")
        }
    }

    func testRoster_exactlyOneAgentAndHealthEntryPerDeclaredID() async throws {
        let snapshot = try await makeBuilder().build()

        let agentIDs = snapshot.agents.map(\.id)
        let healthIDs = snapshot.probeHealth.map(\.agent)
        let declared = BurnBarFleetAgentID.declaredRoster

        XCTAssertEqual(Set(agentIDs), Set(declared), "agents[] must cover exactly the declared roster")
        XCTAssertEqual(Set(healthIDs), Set(declared), "probeHealth[] must cover exactly the declared roster")
        XCTAssertEqual(agentIDs.count, declared.count, "no duplicate agent rows")
        XCTAssertEqual(healthIDs.count, declared.count, "no duplicate probe-health rows")
    }

    func testUnsupportedAgents_presentAsTypedNonRunningRows() async throws {
        let snapshot = try await makeBuilder().build()

        for id in [BurnBarFleetAgentID.kimi, .geminiCLI] {
            let row = try XCTUnwrap(snapshot.agents.first { $0.id == id })
            XCTAssertNotEqual(row.status, .running)
            XCTAssertEqual(row.confidence, .unsupported)
            let health = try XCTUnwrap(snapshot.probeHealth.first { $0.agent == id })
            XCTAssertEqual(health.agent, id)
        }
    }

    // MARK: - VAL-FLEET-009: runningCount / countsByAgent consistency

    func testRunningCountAndCountsByAgent_consistentWithRows() async throws {
        let now = Date()
        let runningAgent = BurnBarFleetAgent(
            id: .claudeCode,
            displayName: "Claude Code",
            status: .running,
            confidence: .exactProcess,
            projectName: "/Users/test/RepoA",
            signals: [BurnBarFleetSignalSource(kind: "session-registry", path: "/fixture/claude/sessions/1.json")]
        )
        let idleAgent = BurnBarFleetAgent(
            id: .grokBot,
            displayName: "Grok Bot",
            status: .idle,
            confidence: .exactProcess,
            projectName: "/Users/test/RepoB"
        )
        let unknownAgent = BurnBarFleetAgent(
            id: .kimi,
            displayName: "Kimi",
            status: .unknown,
            confidence: .unsupported
        )

        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        probes[.claudeCode] = StubProbe(
            agentID: .claudeCode,
            rootPath: "/fixture/claude",
            agent: runningAgent,
            healthState: .ok
        )
        probes[.grokBot] = StubProbe(
            agentID: .grokBot,
            rootPath: "/fixture/grokbot",
            agent: idleAgent,
            healthState: .ok
        )
        probes[.kimi] = StubProbe(
            agentID: .kimi,
            rootPath: "/fixture/kimi",
            agent: unknownAgent,
            healthState: .ok
        )

        let snapshot = try await makeBuilder(probes: probes).build(now: now)

        XCTAssertEqual(snapshot.runningCount, 1)
        let expectedCounts: [String: Int] = [
            "claude-code": 1,
            "grok-bot": 0,
            "kimi": 0
        ]
        for (id, count) in expectedCounts {
            XCTAssertEqual(snapshot.countsByAgent[id], count, "countsByAgent mismatch for \(id)")
        }
        XCTAssertEqual(snapshot.countsByAgent.values.reduce(0, +), snapshot.runningCount)
        for agent in snapshot.agents {
            let expected = agent.status == .running ? 1 : 0
            XCTAssertEqual(snapshot.countsByAgent[agent.id.wireValue], expected)
        }
    }

    func testCountsByAgent_usesRunningThreadCount() async throws {
        let runningAgent = BurnBarFleetAgent(
            id: .claudeCode,
            displayName: "Claude Code",
            status: .running,
            confidence: .exactProcess
        )
        let threads = (1...3).map { index in
            BurnBarFleetThread(
                id: "sess-\(index)",
                agentID: .claudeCode,
                status: .running,
                confidence: .exactProcess
            )
        }
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        probes[.claudeCode] = StubProbe(
            agentID: .claudeCode,
            rootPath: "/fixture/claude",
            agent: runningAgent,
            healthState: .ok,
            threads: threads
        )
        let snapshot = try await makeBuilder(probes: probes).build()
        XCTAssertEqual(snapshot.threads.count, 3)
        XCTAssertEqual(snapshot.countsByAgent["claude-code"], 3)
        XCTAssertEqual(snapshot.runningCount, 3)
        XCTAssertEqual(snapshot.threads(for: .codex).count, 0)
    }

    // MARK: - Repo grouping

    func testRepoGroups_derivedFromProjectNames() async throws {
        let now = Date()
        let agentA = BurnBarFleetAgent(
            id: .claudeCode,
            displayName: "Claude Code",
            status: .running,
            confidence: .exactProcess,
            projectName: "/Users/test/RepoA"
        )
        let agentB = BurnBarFleetAgent(
            id: .grokCLI,
            displayName: "Grok CLI",
            status: .running,
            confidence: .exactProcess,
            projectName: "/Users/test/RepoA"
        )
        let agentC = BurnBarFleetAgent(
            id: .pi,
            displayName: "Pi",
            status: .idle,
            confidence: .logHeartbeat,
            projectName: "/Users/test/RepoB"
        )
        let agentD = BurnBarFleetAgent(
            id: .kimi,
            displayName: "Kimi",
            status: .unknown,
            confidence: .unsupported,
            projectName: nil
        )

        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        probes[.claudeCode] = StubProbe(agentID: .claudeCode, rootPath: "/f", agent: agentA, healthState: .ok)
        probes[.grokCLI] = StubProbe(agentID: .grokCLI, rootPath: "/f", agent: agentB, healthState: .ok)
        probes[.pi] = StubProbe(agentID: .pi, rootPath: "/f", agent: agentC, healthState: .ok)
        probes[.kimi] = StubProbe(agentID: .kimi, rootPath: "/f", agent: agentD, healthState: .ok)

        let snapshot = try await makeBuilder(probes: probes).build(now: now)

        let repoA = try XCTUnwrap(snapshot.repos.first { $0.projectName == "/Users/test/RepoA" })
        XCTAssertEqual(repoA.agents, [.claudeCode, .grokCLI])
        let repoB = try XCTUnwrap(snapshot.repos.first { $0.projectName == "/Users/test/RepoB" })
        XCTAssertEqual(repoB.agents, [.pi])
        XCTAssertFalse(snapshot.repos.contains { $0.projectName.isEmpty })
    }

    // MARK: - VAL-FLEET-008: machine status block

    func testMachineStatus_numericFieldsAndHonestSensors() async throws {
        let snapshot = try await makeBuilder().build()

        let machine = snapshot.machine
        XCTAssertNotNil(machine.cpuPercent, "cpuPercent must be populated")
        XCTAssertNotNil(machine.memoryUsedBytes, "memoryUsedBytes must be populated")
        XCTAssertGreaterThan(machine.memoryTotalBytes, 0, "memoryTotalBytes must be populated")
        XCTAssertEqual(machine.loadAverage?.count, 3, "loadAverage must be a 3-element array")
        XCTAssertNotNil(machine.diskFreeBytes, "diskFreeBytes must be populated")

        if case .unavailable(let reason) = machine.thermal {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            XCTFail("thermal must be typed unavailable on this machine, got \(machine.thermal)")
        }
        if case .unavailable(let reason) = machine.power {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            XCTFail("power must be typed unavailable on this machine, got \(machine.power)")
        }
    }

    // MARK: - VAL-FLEET-025: cadence reflected

    func testCadenceSeconds_reflectedInSnapshot() async throws {
        let snapshot = try await makeBuilder(cadenceSeconds: 7).build()
        XCTAssertEqual(snapshot.cadenceSeconds, 7)
    }

    // MARK: - Missing probe degradation

    func testMissingProbe_typedFailedHealthAndUnknownRow() async throws {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        probes[.claudeCode] = StubProbe(
            agentID: .claudeCode,
            rootPath: "/fixture/claude",
            agent: BurnBarFleetAgent(
                id: .claudeCode,
                displayName: "Claude Code",
                status: .running,
                confidence: .exactProcess
            ),
            healthState: .ok
        )
        // No probe for .hermes — the builder must still emit its roster row.

        let snapshot = try await makeBuilder(probes: probes).build()

        XCTAssertEqual(snapshot.agents.count, 10)
        let hermesRow = try XCTUnwrap(snapshot.agents.first { $0.id == .hermes })
        XCTAssertEqual(hermesRow.status, .unknown)
        XCTAssertEqual(hermesRow.confidence, .unsupported)
        let hermesHealth = try XCTUnwrap(snapshot.probeHealth.first { $0.agent == .hermes })
        if case .failed(let reason) = hermesHealth.state {
            XCTAssertTrue(reason.contains("No probe registered"))
        } else {
            XCTFail("missing probe must be typed failed, got \(hermesHealth.state)")
        }
        // Sibling rows unaffected.
        let claudeRow = try XCTUnwrap(snapshot.agents.first { $0.id == .claudeCode })
        XCTAssertEqual(claudeRow.status, .running)
    }

    // MARK: - Consistency guard (VAL-CONTRACT-016 encode-side)

    func testConsistencyGuard_runningUnsupportedThrows() async {
        var probes: [BurnBarFleetAgentID: any BurnBarFleetProbe] = [:]
        probes[.claudeCode] = StubProbe(
            agentID: .claudeCode,
            rootPath: "/fixture/claude",
            agent: BurnBarFleetAgent(
                id: .claudeCode,
                displayName: "Claude Code",
                status: .running,
                confidence: .unsupported
            ),
            healthState: .ok
        )
        let builder = makeBuilder(probes: probes)
        do {
            _ = try await builder.build()
            XCTFail("running + unsupported must throw inconsistentStatusConfidence")
        } catch let error as BurnBarFleetContractError {
            guard case .inconsistentStatusConfidence = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Root resolver override seam

    func testRootResolver_baseOverrideAndPerProbeOverride() {
        let environment: [String: String] = [
            "BURNBAR_FLEET_ROOTS_DIR": "/tmp/fleet-roots",
            "BURNBAR_FLEET_ROOT_CLAUDE_CODE": "/tmp/custom-claude"
        ]
        let resolver = BurnBarFleetRootResolver(
            environment: environment,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )

        XCTAssertEqual(resolver.rootPath(for: .claudeCode), "/tmp/custom-claude")
        XCTAssertEqual(resolver.rootPath(for: .hermes), "/tmp/fleet-roots/hermes")
        XCTAssertEqual(resolver.rootPath(for: .kimi), "/tmp/fleet-roots/kimi")
    }

    func testRootResolver_defaultsToHomeRoots() {
        let resolver = BurnBarFleetRootResolver(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        XCTAssertEqual(resolver.rootPath(for: .claudeCode), "/Users/test/.claude")
        XCTAssertEqual(resolver.rootPath(for: .grokBot), "/Users/test/.grokbot")
        XCTAssertEqual(resolver.rootPath(for: .geminiCLI), "/Users/test/.gemini")
    }

    // MARK: - Cadence configuration seam

    func testFleetConfiguration_cadenceOverrideSeam() {
        let overridden = BurnBarFleetConfiguration(
            environment: ["BURNBAR_FLEET_CADENCE_SECONDS": "2"]
        )
        XCTAssertEqual(overridden.cadenceSeconds, 2)

        let invalid = BurnBarFleetConfiguration(
            environment: ["BURNBAR_FLEET_CADENCE_SECONDS": "not-a-number"]
        )
        XCTAssertEqual(invalid.cadenceSeconds, BurnBarFleetConfiguration.defaultCadenceSeconds)

        let tooSmall = BurnBarFleetConfiguration(
            environment: ["BURNBAR_FLEET_CADENCE_SECONDS": "0"]
        )
        XCTAssertEqual(tooSmall.cadenceSeconds, BurnBarFleetConfiguration.defaultCadenceSeconds)

        let absent = BurnBarFleetConfiguration(environment: [:])
        XCTAssertEqual(absent.cadenceSeconds, BurnBarFleetConfiguration.defaultCadenceSeconds)
    }

    // MARK: - Service: typed pre-first-tick behavior (VAL-FLEET-018)

    func testService_preFirstTickNotReady_neverFabricatedSnapshot() async {
        let service = BurnBarFleetService(
            builder: makeBuilder()
        )
        // No start(): no tick has completed.
        if case .ready = await service.readLatestSnapshot() {
            XCTFail("pre-first-tick read must be typed notReady, never a fabricated snapshot")
        }
    }

    func testService_readyAfterFirstBuild() async throws {
        let service = BurnBarFleetService(
            builder: makeBuilder()
        )
        let snapshot = try await service.buildOnce()
        guard case .ready(let read) = await service.readLatestSnapshot() else {
            XCTFail("after first build the read must be ready")
            return
        }
        XCTAssertEqual(read, snapshot)
        XCTAssertEqual(read.agents.count, 10)
    }

    func testService_ticker_advancesGeneratedAt() async throws {
        let service = BurnBarFleetService(
            builder: makeBuilder(cadenceSeconds: 1)
        )
        await service.start()

        let first = try await waitForReady(service, timeoutNanoseconds: 5_000_000_000)
        let second = try await waitForReady(service, timeoutNanoseconds: 5_000_000_000, after: first)

        XCTAssertGreaterThan(second.generatedAt, first.generatedAt, "ticker must re-probe and advance generatedAt")
        XCTAssertEqual(second.cadenceSeconds, 1)

        await service.stop()
    }

    func testService_stop_keepsLastSnapshot() async throws {
        let service = BurnBarFleetService(
            builder: makeBuilder(cadenceSeconds: 1)
        )
        await service.start()
        _ = try await waitForReady(service, timeoutNanoseconds: 5_000_000_000)
        await service.stop()

        guard case .ready(let snapshot) = await service.readLatestSnapshot() else {
            XCTFail("after stop the last completed snapshot must keep serving")
            return
        }
        XCTAssertEqual(snapshot.agents.count, 10)
    }

    // MARK: - Helpers

    private func waitForReady(
        _ service: BurnBarFleetService,
        timeoutNanoseconds: UInt64,
        after previous: BurnBarFleetSnapshot? = nil
    ) async throws -> BurnBarFleetSnapshot {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if case .ready(let snapshot) = await service.readLatestSnapshot() {
                if let previous, snapshot.generatedAt <= previous.generatedAt {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                return snapshot
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BurnBarFleetTestError.timeoutWaitingForSnapshot
    }
}

private enum BurnBarFleetTestError: Error {
    case timeoutWaitingForSnapshot
}

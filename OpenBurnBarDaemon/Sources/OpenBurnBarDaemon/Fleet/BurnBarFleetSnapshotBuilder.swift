import OpenBurnBarKernel
import Foundation

/// Validation failures raised when a probe violates the fixed ten-ID roster.
/// The ticker records these failures as a typed current-tick degradation
/// instead of silently serving an older generation.
public enum BurnBarFleetSnapshotBuilderError: Error, Equatable, LocalizedError, Sendable {
    case probeRegisteredOutsideRoster(BurnBarFleetAgentID)
    case probeReturnedUnexpectedAgent(expected: BurnBarFleetAgentID, actual: BurnBarFleetAgentID)
    case probeReturnedUnexpectedHealth(expected: BurnBarFleetAgentID, actual: BurnBarFleetAgentID)

    public var errorDescription: String? {
        switch self {
        case .probeRegisteredOutsideRoster(let agent):
            return "Probe registered outside the fixed fleet roster: \(agent.wireValue)."
        case .probeReturnedUnexpectedAgent(let expected, let actual):
            return "Probe for \(expected.wireValue) returned agent identity \(actual.wireValue)."
        case .probeReturnedUnexpectedHealth(let expected, let actual):
            return "Probe for \(expected.wireValue) returned health identity \(actual.wireValue)."
        }
    }
}

/// Builds a complete `BurnBarFleetSnapshot` from per-agent probe results.
///
/// The roster is fixed: exactly the ten declared `BurnBarFleetAgentID`s. Every
/// tick the builder runs every roster probe and merges the results into
/// exactly one `agents[]` row and one `probeHealth[]` entry per declared ID —
/// unsupported agents (kimi, gemini-cli) are always present as typed
/// non-running rows. Bounded `threads[]` are concatenated from every probe.
/// `countsByAgent` is that CLI's **running thread count** (0 when the CLI
/// has no threads). `runningCount` is the sum of those counts. `repos`
/// groups thread (then agent) project names.
public struct BurnBarFleetSnapshotBuilder: Sendable {
    public let cadenceSeconds: Int
    public let probes: [BurnBarFleetAgentID: any BurnBarFleetProbe]
    public let machineStatusProbe: BurnBarFleetMachineStatusProbe
    private let buildTimingHook: BurnBarFleetBuildTimingHook?

    public init(
        cadenceSeconds: Int,
        probes: [BurnBarFleetAgentID: any BurnBarFleetProbe],
        machineStatusProbe: BurnBarFleetMachineStatusProbe = BurnBarFleetMachineStatusProbe()
    ) {
        self.cadenceSeconds = cadenceSeconds
        self.probes = probes
        self.machineStatusProbe = machineStatusProbe
        self.buildTimingHook = nil
    }

    /// Internal test seam for direct build measurements. Keeping this
    /// initializer internal prevents runtime clients from installing a
    /// callback or confusing RPC serving latency with builder latency.
    init(
        cadenceSeconds: Int,
        probes: [BurnBarFleetAgentID: any BurnBarFleetProbe],
        machineStatusProbe: BurnBarFleetMachineStatusProbe = BurnBarFleetMachineStatusProbe(),
        buildTimingHook: BurnBarFleetBuildTimingHook?
    ) {
        self.cadenceSeconds = cadenceSeconds
        self.probes = probes
        self.machineStatusProbe = machineStatusProbe
        self.buildTimingHook = buildTimingHook
    }

    /// Builds a snapshot at `now`. Every declared roster id yields exactly one
    /// agent row and one probe-health entry; a missing probe degrades to a
    /// typed `unknown`/`unsupported` row with a `failed` health reason rather
    /// than omitting the roster row. `orchestrator` and `persistenceHealth`
    /// are per-build inputs so the fleet service can reflect live state.
    public func build(
        now: Date = Date(),
        orchestrator: BurnBarOrchestratorState = BurnBarOrchestratorState(designation: .none),
        persistenceHealth: BurnBarFleetPersistenceHealth = .ok,
        recentDirectives: [BurnBarFleetDirective] = []
    ) async throws -> BurnBarFleetSnapshot {
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        defer {
            buildTimingHook?(
                BurnBarFleetBuildTiming(
                    startedAtNanoseconds: startedAtNanoseconds,
                    endedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
            )
        }
        return try await buildSnapshot(
            now: now,
            orchestrator: orchestrator,
            persistenceHealth: persistenceHealth,
            recentDirectives: recentDirectives
        )
    }

    private func buildSnapshot(
        now: Date,
        orchestrator: BurnBarOrchestratorState,
        persistenceHealth: BurnBarFleetPersistenceHealth,
        recentDirectives: [BurnBarFleetDirective]
    ) async throws -> BurnBarFleetSnapshot {
        if let extraProbe = probes.keys.first(where: { !BurnBarFleetAgentID.declaredRoster.contains($0) }) {
            throw BurnBarFleetSnapshotBuilderError.probeRegisteredOutsideRoster(extraProbe)
        }

        var agents: [BurnBarFleetAgent] = []
        var probeHealth: [BurnBarFleetProbeHealth] = []
        var threads: [BurnBarFleetThread] = []

        for agentID in BurnBarFleetAgentID.declaredRoster {
            guard let probe = probes[agentID] else {
                agents.append(
                    BurnBarFleetAgent(
                        id: agentID,
                        displayName: Self.displayName(for: agentID),
                        status: .unknown,
                        confidence: .unsupported,
                        note: "No probe registered for this roster agent."
                    )
                )
                probeHealth.append(
                    BurnBarFleetProbeHealth(
                        agent: agentID,
                        state: .failed(reason: "No probe registered for this roster agent."),
                        rootPath: "",
                        checkedAt: now
                    )
                )
                continue
            }

            let result = await probe.probe(now: now)
            guard result.agent.id == agentID else {
                throw BurnBarFleetSnapshotBuilderError.probeReturnedUnexpectedAgent(
                    expected: agentID,
                    actual: result.agent.id
                )
            }
            guard result.health.agent == agentID else {
                throw BurnBarFleetSnapshotBuilderError.probeReturnedUnexpectedHealth(
                    expected: agentID,
                    actual: result.health.agent
                )
            }
            agents.append(result.agent)
            probeHealth.append(result.health)
            threads.append(contentsOf: result.threads.filter { $0.agentID == agentID })
        }

        var countsByAgent: [String: Int] = [:]
        for agent in agents {
            let runningThreads = threads.filter { $0.agentID == agent.id && $0.status == .running }.count
            if runningThreads > 0 {
                countsByAgent[agent.id.wireValue] = runningThreads
            } else if agent.status == .running {
                // Roll-up is running but this CLI has no enumerated thread
                // identities (honest 1, never a silent 0).
                countsByAgent[agent.id.wireValue] = 1
            } else {
                countsByAgent[agent.id.wireValue] = 0
            }
        }
        let runningCount = countsByAgent.values.reduce(0, +)

        let snapshot = BurnBarFleetSnapshot(
            schemaVersion: BurnBarFleetSnapshot.currentSchemaVersion,
            generatedAt: now,
            cadenceSeconds: cadenceSeconds,
            machine: machineStatusProbe.read(),
            agents: agents,
            repos: Self.deriveRepoGroups(from: agents, threads: threads),
            runningCount: runningCount,
            countsByAgent: countsByAgent,
            orchestrator: orchestrator,
            probeHealth: probeHealth,
            persistenceHealth: persistenceHealth,
            threads: threads,
            recentDirectives: recentDirectives
        )

        // Encode-side guard: running rows never carry unsupported/estimated
        // confidence and unknown rows never carry exactProcess.
        return try snapshot.validateConsistency()
    }

    /// Groups agent rows by derived `projectName` (nil project names are
    /// omitted from the grouping). Order is stable: first-appearance order.
    public static func deriveRepoGroups(
        from agents: [BurnBarFleetAgent],
        threads: [BurnBarFleetThread] = []
    ) -> [BurnBarFleetRepoGroup] {
        var groups: [String: [BurnBarFleetAgentID]] = [:]
        var order: [String] = []

        func append(projectName: String?, agentID: BurnBarFleetAgentID) {
            guard let projectName, !projectName.isEmpty else { return }
            if groups[projectName] == nil {
                order.append(projectName)
            }
            if groups[projectName]?.contains(agentID) != true {
                groups[projectName, default: []].append(agentID)
            }
        }

        for thread in threads {
            append(projectName: thread.projectName, agentID: thread.agentID)
        }
        for agent in agents {
            append(projectName: agent.projectName, agentID: agent.id)
        }

        return order.map { BurnBarFleetRepoGroup(projectName: $0, agents: groups[$0] ?? []) }
    }

    /// Stable display name for each roster agent.
    public static func displayName(for agentID: BurnBarFleetAgentID) -> String {
        switch agentID {
        case .claudeCode:
            return "Claude Code"
        case .factoryDroid:
            return "Factory Droid"
        case .codex:
            return "Codex"
        case .hermes:
            return "Hermes"
        case .grokBot:
            return "Grok Bot"
        case .grokCLI:
            return "Grok CLI"
        case .pi:
            return "Pi"
        case .cursor:
            return "Cursor"
        case .kimi:
            return "Kimi"
        case .geminiCLI:
            return "Gemini CLI"
        case .unknown(let raw):
            return raw
        }
    }
}

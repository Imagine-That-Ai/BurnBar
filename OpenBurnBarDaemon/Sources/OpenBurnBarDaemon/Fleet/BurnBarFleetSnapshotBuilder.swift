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
/// non-running rows. `runningCount` and `countsByAgent` are derived from the
/// merged rows, never stored independently. `repos` groups rows by derived
/// `projectName`.
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
        persistenceHealth: BurnBarFleetPersistenceHealth = .ok
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
            persistenceHealth: persistenceHealth
        )
    }

    private func buildSnapshot(
        now: Date,
        orchestrator: BurnBarOrchestratorState,
        persistenceHealth: BurnBarFleetPersistenceHealth
    ) async throws -> BurnBarFleetSnapshot {
        if let extraProbe = probes.keys.first(where: { !BurnBarFleetAgentID.declaredRoster.contains($0) }) {
            throw BurnBarFleetSnapshotBuilderError.probeRegisteredOutsideRoster(extraProbe)
        }

        var agents: [BurnBarFleetAgent] = []
        var probeHealth: [BurnBarFleetProbeHealth] = []

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
        }

        let runningCount = agents.filter { $0.status == .running }.count
        var countsByAgent: [String: Int] = [:]
        for agent in agents {
            countsByAgent[agent.id.wireValue] = agent.status == .running ? 1 : 0
        }

        let snapshot = BurnBarFleetSnapshot(
            schemaVersion: BurnBarFleetSnapshot.currentSchemaVersion,
            generatedAt: now,
            cadenceSeconds: cadenceSeconds,
            machine: machineStatusProbe.read(),
            agents: agents,
            repos: Self.deriveRepoGroups(from: agents),
            runningCount: runningCount,
            countsByAgent: countsByAgent,
            orchestrator: orchestrator,
            probeHealth: probeHealth,
            persistenceHealth: persistenceHealth
        )

        // Encode-side guard: running rows never carry unsupported/estimated
        // confidence and unknown rows never carry exactProcess.
        return try snapshot.validateConsistency()
    }

    /// Groups agent rows by derived `projectName` (nil project names are
    /// omitted from the grouping). Order is stable: first-appearance order.
    public static func deriveRepoGroups(from agents: [BurnBarFleetAgent]) -> [BurnBarFleetRepoGroup] {
        var groups: [String: [BurnBarFleetAgentID]] = [:]
        var order: [String] = []

        for agent in agents {
            guard let projectName = agent.projectName, !projectName.isEmpty else { continue }
            if groups[projectName] == nil {
                order.append(projectName)
            }
            groups[projectName, default: []].append(agent.id)
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

import BurnBarCore
import Foundation

// MARK: - Fleet Test Fixtures

/// Shared fixture builders for the M3 fleet dashboard tests. All snapshots are
/// synthetic (never real agent data) and satisfy the schema-level
/// status/confidence consistency rule.
enum FleetTestFixtures {
    static func makeAgent(
        id: BurnBarFleetAgentID = .claudeCode,
        status: BurnBarFleetAgentStatus = .running,
        confidence: BurnBarFleetConfidence = .exactProcess,
        currentTask: String? = nil,
        projectName: String? = nil,
        model: String? = nil,
        lastActivityAt: Date? = nil,
        process: BurnBarFleetProcessInfo? = nil,
        signals: [BurnBarFleetSignalSource] = [],
        note: String? = nil
    ) -> BurnBarFleetAgent {
        BurnBarFleetAgent(
            id: id,
            displayName: id.wireValue,
            status: status,
            confidence: confidence,
            currentTask: currentTask,
            projectName: projectName,
            model: model,
            lastActivityAt: lastActivityAt,
            process: process,
            signals: signals,
            note: note
        )
    }

    static func makeMachine(
        thermal: BurnBarSensorState = .unavailable(reason: "pmset thermlog empty"),
        power: BurnBarSensorState = .unavailable(reason: "no cheap power API")
    ) -> BurnBarMachineStatus {
        BurnBarMachineStatus(
            cpuPercent: 12.5,
            memoryUsedBytes: 8_000_000_000,
            memoryTotalBytes: 48_000_000_000,
            loadAverage: [1.2, 1.0, 0.8],
            diskFreeBytes: 500_000_000_000,
            thermal: thermal,
            power: power
        )
    }

    /// A heterogeneous snapshot: claude-code running/exactProcess with a
    /// process block, grok-bot idle/exactProcess, kimi unknown/unsupported.
    static func makeSnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_752_000_000),
        cadenceSeconds: Int = 15,
        runningCount: Int = 1
    ) -> BurnBarFleetSnapshot {
        let agents = makeHeterogeneousAgents(generatedAt: generatedAt)
        return BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            cadenceSeconds: cadenceSeconds,
            machine: makeMachine(),
            agents: agents,
            repos: [
                BurnBarFleetRepoGroup(
                    projectName: "/Users/albertonunez/Developer/AgentLens",
                    agents: [.claudeCode]
                )
            ],
            runningCount: runningCount,
            countsByAgent: ["claude-code": runningCount, "grok-bot": 0, "kimi": 0],
            orchestrator: BurnBarOrchestratorState(
                designation: .burnBarManaged,
                setAt: generatedAt,
                pendingDirectives: 0
            ),
            probeHealth: makeProbeHealth(generatedAt: generatedAt),
            persistenceHealth: .ok
        )
    }

    private static func makeHeterogeneousAgents(generatedAt: Date) -> [BurnBarFleetAgent] {
        [
            makeAgent(
                id: .claudeCode,
                currentTask: "Refactor probe layer",
                projectName: "/Users/albertonunez/Developer/AgentLens",
                model: "claude-sonnet-4-5",
                lastActivityAt: generatedAt,
                process: BurnBarFleetProcessInfo(
                    pid: 19_457,
                    cpuPercent: 3.2,
                    memoryBytes: 1_024_000_000,
                    startedAt: generatedAt
                ),
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "session-registry",
                        path: "/Users/albertonunez/.claude/sessions/19457.json",
                        detail: "updatedAt fresh"
                    )
                ]
            ),
            makeAgent(
                id: .grokBot,
                status: .idle,
                confidence: .exactProcess,
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "process-list",
                        path: "/Users/albertonunez/.grokbot/local-exec-daemon.json",
                        detail: "inflightCount 0"
                    )
                ]
            ),
            makeAgent(
                id: .kimi,
                status: .unknown,
                confidence: .unsupported,
                note: "no live signal defined"
            )
        ]
    }

    private static func makeProbeHealth(generatedAt: Date) -> [BurnBarFleetProbeHealth] {
        [
            BurnBarFleetProbeHealth(
                agent: .claudeCode,
                state: .ok,
                rootPath: "/Users/albertonunez/.claude",
                checkedAt: generatedAt
            ),
            BurnBarFleetProbeHealth(
                agent: .grokBot,
                state: .ok,
                rootPath: "/Users/albertonunez/.grokbot",
                checkedAt: generatedAt
            ),
            BurnBarFleetProbeHealth(
                agent: .kimi,
                state: .degraded(reason: "root stale since Jul 19"),
                rootPath: "/Users/albertonunez/.kimi",
                checkedAt: generatedAt
            )
        ]
    }

    /// A healthy zero-running snapshot with all ten declared rows present and
    /// non-running (the honest empty-fleet fixture, VAL-DASH-007/CROSS-010).
    static func makeEmptySnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_752_000_000),
        cadenceSeconds: Int = 15
    ) -> BurnBarFleetSnapshot {
        let agents = BurnBarFleetAgentID.declaredRoster.map { id in
            makeAgent(
                id: id,
                status: .unknown,
                confidence: .unsupported,
                note: "no live signal"
            )
        }
        return BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            cadenceSeconds: cadenceSeconds,
            machine: makeMachine(),
            agents: agents,
            repos: [],
            runningCount: 0,
            countsByAgent: [:],
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: BurnBarFleetAgentID.declaredRoster.map { id in
                BurnBarFleetProbeHealth(
                    agent: id,
                    state: .ok,
                    rootPath: "/fixtures/\(id.wireValue)",
                    checkedAt: generatedAt
                )
            },
            persistenceHealth: .ok
        )
    }
}

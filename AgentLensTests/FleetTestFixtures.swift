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

    /// A machine status with every optional metric absent (VAL-DASH-030):
    /// each optional field degrades per-field to an explicit unavailable
    /// state — never 0, NaN, or a current-looking value.
    static func makeMachineAllOptionalAbsent(
        thermal: BurnBarSensorState = .unavailable(reason: "pmset thermlog empty"),
        power: BurnBarSensorState = .unavailable(reason: "no cheap power API")
    ) -> BurnBarMachineStatus {
        BurnBarMachineStatus(
            cpuPercent: nil,
            memoryUsedBytes: nil,
            memoryTotalBytes: 48_000_000_000,
            loadAverage: nil,
            diskFreeBytes: nil,
            thermal: thermal,
            power: power
        )
    }

    /// A machine status with edge-case values for the formatting tests
    /// (VAL-DASH-022): disk free below 1 GB, three load values, and
    /// memory used/total with consistent units.
    static func makeMachineEdgeCase() -> BurnBarMachineStatus {
        BurnBarMachineStatus(
            cpuPercent: 0.0,
            memoryUsedBytes: 400_000_000,
            memoryTotalBytes: 800_000_000,
            loadAverage: [0.0, 0.5, 1.0],
            diskFreeBytes: 500_000_000,
            thermal: .unavailable(reason: "pmset thermlog empty"),
            power: .unavailable(reason: "no cheap power API")
        )
    }

    /// A machine status with available thermal/power sensor values
    /// (VAL-CONTRACT-014 complement: the panel renders available sensors
    /// with units, never as unavailable).
    static func makeMachineSensorsAvailable() -> BurnBarMachineStatus {
        BurnBarMachineStatus(
            cpuPercent: 12.5,
            memoryUsedBytes: 8_000_000_000,
            memoryTotalBytes: 48_000_000_000,
            loadAverage: [1.2, 1.0, 0.8],
            diskFreeBytes: 500_000_000_000,
            thermal: .available(value: 68.4),
            power: .available(value: 12.3)
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

    /// A multi-repo snapshot for the per-repo grouping/collapse tests
    /// (VAL-DASH-010/019): two repos with agents, optional ungrouped agents
    /// (nil projectName), and an optional extra agent joining repo A on a
    /// later poll.
    static func makeMultiRepoSnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_752_000_000),
        cadenceSeconds: Int = 15,
        includeUngrouped: Bool = false,
        extraRepoAgent: BurnBarFleetAgentID? = nil
    ) -> BurnBarFleetSnapshot {
        let repoA = "/Users/albertonunez/Developer/AgentLens"
        let repoB = "/Users/albertonunez/Developer/BurnBar"

        var agents = makeMultiRepoBaseAgents(repoA: repoA, repoB: repoB)
        if let extra = extraRepoAgent {
            agents.append(
                makeAgent(
                    id: extra,
                    status: .running,
                    confidence: .logHeartbeat,
                    projectName: repoA,
                    signals: [
                        BurnBarFleetSignalSource(
                            kind: "log-mtime",
                            path: "/fixtures/\(extra.wireValue)/log.jsonl"
                        )
                    ]
                )
            )
        }
        if includeUngrouped {
            agents.append(
                makeAgent(
                    id: .grokBot,
                    status: .idle,
                    confidence: .exactProcess,
                    signals: [
                        BurnBarFleetSignalSource(
                            kind: "process-list",
                            path: "/fixtures/grokbot/local-exec-daemon.json"
                        )
                    ]
                )
            )
            agents.append(
                makeAgent(
                    id: .kimi,
                    status: .unknown,
                    confidence: .unsupported,
                    note: "no live signal"
                )
            )
        }

        var repoAAgents: [BurnBarFleetAgentID] = [.claudeCode, .codex]
        if let extra = extraRepoAgent {
            repoAAgents.append(extra)
        }
        let repos = [
            BurnBarFleetRepoGroup(projectName: repoA, agents: repoAAgents),
            BurnBarFleetRepoGroup(projectName: repoB, agents: [.hermes])
        ]

        let runningCount = agents.filter { $0.status == .running }.count
        var countsByAgent: [String: Int] = [:]
        for agent in agents where agent.status == .running {
            countsByAgent[agent.id.wireValue] = 1
        }

        return BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            cadenceSeconds: cadenceSeconds,
            machine: makeMachine(),
            agents: agents,
            repos: repos,
            runningCount: runningCount,
            countsByAgent: countsByAgent,
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: agents.map { agent in
                BurnBarFleetProbeHealth(
                    agent: agent.id,
                    state: .ok,
                    rootPath: "/fixtures/\(agent.id.wireValue)",
                    checkedAt: generatedAt
                )
            },
            persistenceHealth: .ok
        )
    }

    /// The three base agents of the multi-repo fixture: claude-code running
    /// with a process block in repo A, codex running in repo A, hermes idle
    /// in repo B.
    private static func makeMultiRepoBaseAgents(
        repoA: String,
        repoB: String
    ) -> [BurnBarFleetAgent] {
        [
            makeAgent(
                id: .claudeCode,
                status: .running,
                confidence: .exactProcess,
                projectName: repoA,
                process: BurnBarFleetProcessInfo(
                    pid: 19_457,
                    cpuPercent: 3.2,
                    memoryBytes: 1_024_000_000
                ),
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "session-registry",
                        path: "/fixtures/claude/sessions/19457.json"
                    )
                ]
            ),
            makeAgent(
                id: .codex,
                status: .running,
                confidence: .logHeartbeat,
                projectName: repoA,
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "lock-file",
                        path: "/fixtures/codex/thread-writer-locks/1.lock"
                    )
                ]
            ),
            makeAgent(
                id: .hermes,
                status: .idle,
                confidence: .exactProcess,
                projectName: repoB,
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "heartbeat-file",
                        path: "/fixtures/hermes/state/gateway.heartbeat"
                    )
                ]
            )
        ]
    }

    /// Adversarial layout fixture (VAL-DASH-020): 20+ agent rows, a
    /// 120-character projectName, and a CJK/emoji repo name. Long names must
    /// ellipsize without overlap; the running-count header and confidence
    /// badges must stay reachable at top and scrolled positions.
    ///
    /// The fixed ten-row roster appears exactly once each; the extra rows use
    /// forward-compatible `.unknown(String)` ids (which decode losslessly and
    /// are not part of the declared roster), so the fixture never duplicates
    /// a declared id.
    static func makeAdversarialLayoutSnapshot(
        generatedAt: Date = Date(timeIntervalSince1970: 1_752_000_000),
        cadenceSeconds: Int = 15
    ) -> BurnBarFleetSnapshot {
        let longRepo = String(
            repeating: "very-long-project-name-",
            count: 6
        ) // 24 chars × 6 = 144 chars, over the 120-char requirement
        let cjkRepo = "仓库-リポジトリ-저장소-🚀-emoji-проект"

        let extraIDs: [BurnBarFleetAgentID] = [
            .unknown("aider"), .unknown("goose"), .unknown("continue"),
            .unknown("zai"), .unknown("minimax"), .unknown("augment"),
            .unknown("cline"), .unknown("kilo-code"), .unknown("roo-code"),
            .unknown("forge-dev"), .unknown("copilot"), .unknown("gemini-cli-2")
        ]

        var agents: [BurnBarFleetAgent] = []
        var repos: [BurnBarFleetRepoGroup] = []
        var countsByAgent: [String: Int] = [:]

        // 12 agents in the long-name repo: the first 10 are the declared
        // roster (running, exactProcess with process blocks so the
        // resource-consumers list is populated), plus 2 unknown ids.
        let longRepoIDs = BurnBarFleetAgentID.declaredRoster + extraIDs.prefix(2)
        let longRepoAgents = makeLongRepoAgents(
            ids: Array(longRepoIDs),
            projectName: longRepo,
            generatedAt: generatedAt
        )
        agents.append(contentsOf: longRepoAgents.agents)
        repos.append(BurnBarFleetRepoGroup(projectName: longRepo, agents: longRepoAgents.ids))
        for id in longRepoAgents.ids {
            countsByAgent[id.wireValue] = 1
        }

        // 6 agents in the CJK/emoji repo (mixed statuses, unknown ids).
        let cjkIDs = Array(extraIDs.dropFirst(2).prefix(6))
        let cjkAgents = makeCJKRepoAgents(
            ids: cjkIDs,
            projectName: cjkRepo,
            generatedAt: generatedAt
        )
        agents.append(contentsOf: cjkAgents.agents)
        repos.append(BurnBarFleetRepoGroup(projectName: cjkRepo, agents: cjkAgents.ids))
        for (index, id) in cjkIDs.enumerated() where index % 2 == 0 {
            countsByAgent[id.wireValue] = 1
        }

        // 4 ungrouped agents (nil projectName) — must appear under the
        // explicit "No repo" bucket, never dropped (VAL-DASH-010).
        for id in extraIDs.dropFirst(8) {
            agents.append(
                makeAgent(
                    id: id,
                    status: .unknown,
                    confidence: .unsupported,
                    note: "no live signal"
                )
            )
        }

        let runningCount = agents.filter { $0.status == .running }.count
        return BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            cadenceSeconds: cadenceSeconds,
            machine: makeMachineAllOptionalAbsent(),
            agents: agents,
            repos: repos,
            runningCount: runningCount,
            countsByAgent: countsByAgent,
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: agents.map { agent in
                BurnBarFleetProbeHealth(
                    agent: agent.id,
                    state: .ok,
                    rootPath: "/fixtures/\(agent.id.wireValue)",
                    checkedAt: generatedAt
                )
            },
            persistenceHealth: .ok
        )
    }

    /// The 12 running/exactProcess agents of the long-name repo (declared
    /// roster + 2 unknown ids), each with a process block so the
    /// resource-consumers list is populated.
    private static func makeLongRepoAgents(
        ids: [BurnBarFleetAgentID],
        projectName: String,
        generatedAt: Date
    ) -> (ids: [BurnBarFleetAgentID], agents: [BurnBarFleetAgent]) {
        var agents: [BurnBarFleetAgent] = []
        for (index, id) in ids.enumerated() {
            agents.append(
                makeAgent(
                    id: id,
                    status: .running,
                    confidence: .exactProcess,
                    currentTask: "Refactor the probe layer and harden the snapshot builder "
                        + "against malformed signal shapes",
                    projectName: projectName,
                    model: "claude-sonnet-4-5",
                    lastActivityAt: generatedAt,
                    process: BurnBarFleetProcessInfo(
                        pid: 10_000 + index,
                        cpuPercent: Double(index + 1) * 1.5,
                        memoryBytes: 500_000_000 + index * 100_000_000
                    ),
                    signals: [
                        BurnBarFleetSignalSource(
                            kind: "session-registry",
                            path: "/fixtures/claude/sessions/\(10_000 + index).json"
                        )
                    ]
                )
            )
        }
        return (ids, agents)
    }

    /// The 6 mixed-status agents of the CJK/emoji repo (unknown ids):
    /// even indexes running/exactProcess with process blocks, odd indexes
    /// idle/activeSessionFile without.
    private static func makeCJKRepoAgents(
        ids: [BurnBarFleetAgentID],
        projectName: String,
        generatedAt: Date
    ) -> (ids: [BurnBarFleetAgentID], agents: [BurnBarFleetAgent]) {
        var agents: [BurnBarFleetAgent] = []
        for (index, id) in ids.enumerated() {
            let status: BurnBarFleetAgentStatus = index % 2 == 0 ? .running : .idle
            let confidence: BurnBarFleetConfidence = index % 2 == 0 ? .exactProcess : .activeSessionFile
            agents.append(
                makeAgent(
                    id: id,
                    status: status,
                    confidence: confidence,
                    currentTask: "ローカライズと国際化のテスト",
                    projectName: projectName,
                    model: "grok-4",
                    lastActivityAt: generatedAt,
                    process: index % 2 == 0
                        ? BurnBarFleetProcessInfo(
                            pid: 20_000 + index,
                            cpuPercent: Double(index) * 0.8,
                            memoryBytes: 300_000_000 + index * 50_000_000
                        )
                        : nil,
                    signals: [
                        BurnBarFleetSignalSource(
                            kind: "heartbeat-file",
                            path: "/fixtures/hermes/state/gateway.heartbeat"
                        )
                    ]
                )
            )
        }
        return (ids, agents)
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

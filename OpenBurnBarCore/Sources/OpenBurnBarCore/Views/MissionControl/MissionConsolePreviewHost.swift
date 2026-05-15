import Foundation
import Observation
import SwiftUI

#if DEBUG

// MARK: - Preview-only Mock Host
//
// Implements `MissionConsoleHost` with rich, varied mock data so the console
// previews like a real running system. Not shipped — wrapped in `#if DEBUG`.

@MainActor
@Observable
public final class MissionConsolePreviewHost: MissionConsoleHost {
    public var snapshot: MissionConsoleSnapshot
    public var lastDispatchedMissionID: String?
    public var isDispatching: Bool = false
    public var inlineError: String?

    public init(snapshot: MissionConsoleSnapshot = .preview) {
        self.snapshot = snapshot
    }

    public func dispatch(_ request: MissionConsoleDispatchRequest) async -> MissionConsoleDispatchOutcome {
        isDispatching = true
        try? await Task.sleep(nanoseconds: 600_000_000)
        let newID = "mock-\(UUID().uuidString.prefix(6))"
        let newTile = MissionConsoleActiveTile(
            id: newID,
            title: request.title.isEmpty ? "Mock dispatch" : request.title,
            runtimeID: request.runtimeID,
            runtimeDisplayLabel: snapshot.runtimes.first(where: { $0.id == request.runtimeID })?.displayName ?? "Auto",
            phase: .queued,
            phaseDetail: "Queued",
            currentToolName: nil,
            lastEventSnippet: "Mission queued from the preview host.",
            startedAt: Date(),
            burnSoFarUSD: 0,
            progressFraction: 0.02,
            approvalPending: false
        )
        snapshot = MissionConsoleSnapshot(
            health: snapshot.health,
            runtimes: snapshot.runtimes,
            activeTiles: [newTile] + snapshot.activeTiles,
            recentTicker: [
                MissionConsoleTickerEntry(
                    id: UUID().uuidString,
                    timestamp: Date(),
                    kind: .status,
                    phase: "queued",
                    title: "Queued",
                    message: "Mission queued from preview host.",
                    missionID: newID,
                    runtimeID: request.runtimeID
                )
            ] + snapshot.recentTicker,
            approvalAsks: snapshot.approvalAsks,
            knownProjects: snapshot.knownProjects,
            recentProjects: snapshot.recentProjects,
            burnHistorySpark: snapshot.burnHistorySpark
        )
        lastDispatchedMissionID = newID
        isDispatching = false
        return .dispatched(missionID: newID)
    }

    public func respond(to ask: MissionConsoleApprovalAsk, approve: Bool) async {
        snapshot = MissionConsoleSnapshot(
            health: snapshot.health,
            runtimes: snapshot.runtimes,
            activeTiles: snapshot.activeTiles,
            recentTicker: snapshot.recentTicker,
            approvalAsks: snapshot.approvalAsks.filter { $0.id != ask.id },
            knownProjects: snapshot.knownProjects,
            recentProjects: snapshot.recentProjects,
            burnHistorySpark: snapshot.burnHistorySpark
        )
        _ = approve
    }

    public func clearInlineError() {
        inlineError = nil
    }

    public func refresh() async {
        // no-op for preview
    }
}

public extension MissionConsoleSnapshot {
    static let preview: MissionConsoleSnapshot = {
        let now = Date()
        let runtimes: [MissionConsoleRuntime] = [
            MissionConsoleRuntime(
                id: "claude",
                displayName: "Claude Code",
                callSign: "CLD",
                provider: .claudeCode,
                availability: .online,
                recentMedianBurnUSD: 0.62,
                recentSampleSize: 9,
                tagline: nil,
                pricingFactor: 1.1
            ),
            MissionConsoleRuntime(
                id: "codex",
                displayName: "Codex CLI",
                callSign: "CDX",
                provider: .codex,
                availability: .online,
                recentMedianBurnUSD: 0.41,
                recentSampleSize: 14,
                tagline: nil,
                pricingFactor: 0.9
            ),
            MissionConsoleRuntime(
                id: "hermes",
                displayName: "Hermes Relay",
                callSign: "HRM",
                provider: .hermes,
                availability: .online,
                recentMedianBurnUSD: 0.12,
                recentSampleSize: 21,
                tagline: nil,
                pricingFactor: 0.4
            ),
            MissionConsoleRuntime(
                id: "pi",
                displayName: "Pi Agent",
                callSign: "PI",
                provider: .piAgent,
                availability: .online,
                recentMedianBurnUSD: 0.05,
                recentSampleSize: 7,
                tagline: nil,
                pricingFactor: 0.25
            ),
            MissionConsoleRuntime(
                id: "openclaw",
                displayName: "OpenClaw",
                callSign: "OCL",
                provider: .openClaw,
                availability: .offline,
                recentMedianBurnUSD: 0.30,
                recentSampleSize: 3,
                tagline: "Currently asleep.",
                pricingFactor: 0.85
            )
        ]
        let activeTiles: [MissionConsoleActiveTile] = [
            MissionConsoleActiveTile(
                id: "m-001",
                title: "Wire intelligence brief fallback when Hermes is unreachable",
                runtimeID: "claude",
                runtimeDisplayLabel: "Claude Code",
                phase: .tooling,
                phaseDetail: "Running 'rg' against ./OpenBurnBarCore",
                currentToolName: "Grep",
                lastEventSnippet: "Searching for InsightProviderGatewayRegistry…",
                startedAt: now.addingTimeInterval(-184),
                burnSoFarUSD: 0.37,
                progressFraction: 0.62,
                approvalPending: false
            ),
            MissionConsoleActiveTile(
                id: "m-002",
                title: "Refactor AuroraButtonStyle to honor reduce-motion",
                runtimeID: "codex",
                runtimeDisplayLabel: "Codex CLI",
                phase: .awaitingApproval,
                phaseDetail: "Approval required for file edits",
                currentToolName: "Edit",
                lastEventSnippet: "Proposed change to AuroraButtonStyle.swift:41",
                startedAt: now.addingTimeInterval(-446),
                burnSoFarUSD: 0.18,
                progressFraction: 0.41,
                approvalPending: true
            ),
            MissionConsoleActiveTile(
                id: "m-003",
                title: "Polish landing-report queue dashboard",
                runtimeID: "hermes",
                runtimeDisplayLabel: "Hermes Relay",
                phase: .streaming,
                phaseDetail: "LLM streaming",
                currentToolName: nil,
                lastEventSnippet: "Writing the situation summary…",
                startedAt: now.addingTimeInterval(-72),
                burnSoFarUSD: 0.04,
                progressFraction: 0.20,
                approvalPending: false
            )
        ]
        let ticker: [MissionConsoleTickerEntry] = [
            MissionConsoleTickerEntry(
                id: "t-008",
                timestamp: now.addingTimeInterval(-4),
                kind: .toolResult,
                phase: "tool_result",
                title: "Edit succeeded",
                message: "Edit applied to AuroraButtonStyle.swift",
                toolName: "Edit",
                pathDetail: "OpenBurnBarMobile/Views/Aurora/AuroraButtonStyle.swift",
                missionID: "m-002",
                runtimeID: "codex"
            ),
            MissionConsoleTickerEntry(
                id: "t-007",
                timestamp: now.addingTimeInterval(-19),
                kind: .toolCall,
                phase: "tool_use",
                title: "Edit invoked",
                message: "Edit AuroraButtonStyle.swift around line 41",
                toolName: "Edit",
                pathDetail: nil,
                missionID: "m-002",
                runtimeID: "codex"
            ),
            MissionConsoleTickerEntry(
                id: "t-006",
                timestamp: now.addingTimeInterval(-43),
                kind: .approval,
                phase: "approval_request",
                title: "Approval requested",
                message: "Awaiting human approval before applying file edit.",
                toolName: nil,
                pathDetail: nil,
                missionID: "m-002",
                runtimeID: "codex"
            ),
            MissionConsoleTickerEntry(
                id: "t-005",
                timestamp: now.addingTimeInterval(-71),
                kind: .llmResponse,
                phase: "streaming",
                title: "Assistant chunk",
                message: "I'll start by tracing the call path through InsightProviderGatewayRegistry…",
                toolName: nil,
                pathDetail: nil,
                missionID: "m-001",
                runtimeID: "claude"
            ),
            MissionConsoleTickerEntry(
                id: "t-004",
                timestamp: now.addingTimeInterval(-118),
                kind: .toolCall,
                phase: "tool_use",
                title: "Grep invoked",
                message: "rg \"InsightProviderGatewayRegistry\" --type swift",
                toolName: "Grep",
                pathDetail: nil,
                missionID: "m-001",
                runtimeID: "claude"
            ),
            MissionConsoleTickerEntry(
                id: "t-003",
                timestamp: now.addingTimeInterval(-167),
                kind: .changedFile,
                phase: "tool_result",
                title: "File changed",
                message: "Edits committed to module under test",
                toolName: "Edit",
                pathDetail: "AgentLens/Theme/DesignSystem.swift",
                missionID: "m-001",
                runtimeID: "claude"
            ),
            MissionConsoleTickerEntry(
                id: "t-002",
                timestamp: now.addingTimeInterval(-184),
                kind: .status,
                phase: "running",
                title: "Started",
                message: "Claude Code started — workspace pinned to BurnBar.",
                toolName: nil,
                pathDetail: nil,
                missionID: "m-001",
                runtimeID: "claude"
            ),
            MissionConsoleTickerEntry(
                id: "t-001",
                timestamp: now.addingTimeInterval(-202),
                kind: .status,
                phase: "queued",
                title: "Queued",
                message: "Mission queued. Awaiting an available runtime slot.",
                toolName: nil,
                pathDetail: nil,
                missionID: "m-001",
                runtimeID: "claude"
            )
        ]
        let approvalAsks: [MissionConsoleApprovalAsk] = [
            MissionConsoleApprovalAsk(
                id: "a-001",
                missionID: "m-002",
                title: "Approve file edit to AuroraButtonStyle.swift?",
                message: "Codex wants to rewrite the press-feedback handler so it honors the system reduce-motion setting. The change touches 14 lines.",
                runtimeID: "codex",
                runtimeDisplayLabel: "Codex CLI",
                requestedAt: now.addingTimeInterval(-43)
            )
        ]
        return MissionConsoleSnapshot(
            health: MissionConsoleSystemHealth(
                daemonState: .live,
                lastRefresh: now.addingTimeInterval(-12),
                openMissions: 3,
                queuedMissions: 1,
                blockedMissions: 0,
                burnTodayUSD: 4.27,
                burnPerHourUSD: 0.83,
                onlineRuntimes: 4,
                totalRuntimes: 5
            ),
            runtimes: runtimes,
            activeTiles: activeTiles,
            recentTicker: ticker,
            approvalAsks: approvalAsks,
            knownProjects: [
                "~/Documents/Windsurf/BurnBar",
                "~/Projects/Pretext",
                "~/Projects/LaHormigaDormida",
                "~/Projects/Hermes"
            ],
            recentProjects: [
                "~/Documents/Windsurf/BurnBar",
                "~/Projects/Pretext"
            ],
            burnHistorySpark: [0.2, 0.4, 0.3, 0.8, 1.1, 0.9, 1.4, 0.83]
        )
    }()

    static let emptyPreview: MissionConsoleSnapshot = MissionConsoleSnapshot(
        health: .empty,
        runtimes: [
            MissionConsoleRuntime(
                id: "claude", displayName: "Claude Code", callSign: "CLD",
                provider: .claudeCode, availability: .online,
                recentMedianBurnUSD: nil, recentSampleSize: 0, tagline: nil, pricingFactor: 1.0
            )
        ],
        activeTiles: [],
        recentTicker: [],
        approvalAsks: [],
        knownProjects: ["~/Projects/Foo"],
        recentProjects: []
    )
}

struct MissionControlConsoleView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MissionControlConsoleView(host: MissionConsolePreviewHost())
                .frame(width: 960, height: 720)
                .previewDisplayName("Live · regular width")

            MissionControlConsoleView(host: MissionConsolePreviewHost(snapshot: .emptyPreview))
                .frame(width: 960, height: 720)
                .previewDisplayName("Empty · regular width")

            MissionControlConsoleView(host: MissionConsolePreviewHost())
                .frame(width: 414, height: 896)
                .previewDisplayName("Live · compact width")
        }
    }
}

#endif

import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Unit coverage for the non-visual contracts the Editorial Observatory
/// relies on: citation→prompt mapping, pin wiring, and store mutation
/// behavior. Snapshot/visual coverage lives in
/// `IntelligenceBriefSnapshotTests`.
final class IntelligenceBriefWiringTests: XCTestCase {

    // MARK: - Citation prompts

    func test_citationPrompt_sessionRoutesToOpenAndSummarize() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .session(id: "sess-7af2", provider: "anthropic"), label: "sess #7af2")
        )
        XCTAssertTrue(prompt.contains("sess-7af2"), "Session prompt must include session id")
        XCTAssertTrue(prompt.contains("anthropic"), "Session prompt must include provider key")
        XCTAssertTrue(prompt.lowercased().contains("summarize"), "Session prompt should ask for a summary")
    }

    func test_citationPrompt_modelRoutesToDrillDown() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .model(id: "claude-sonnet-4-6"), label: "Sonnet 4.6")
        )
        XCTAssertTrue(prompt.contains("Sonnet 4.6"))
        XCTAssertTrue(prompt.contains("claude-sonnet-4-6"))
    }

    func test_citationPrompt_agentBreaksDownUsage() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .agent(provider: "factory-droid"), label: "Factory Droid")
        )
        XCTAssertTrue(prompt.contains("Factory Droid"))
        XCTAssertTrue(prompt.contains("factory-droid"))
    }

    func test_citationPrompt_projectShowsEverything() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .project(name: "OpenBurnBar"), label: "OpenBurnBar")
        )
        XCTAssertTrue(prompt.contains("OpenBurnBar"))
    }

    func test_citationPrompt_dayZoomsIn() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .day(date: "2026-05-09"), label: "May 9")
        )
        XCTAssertTrue(prompt.contains("2026-05-09"))
        XCTAssertTrue(prompt.contains("May 9"))
    }

    func test_citationPrompt_anomalyInvestigates() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .anomaly(id: "spike-may-09"), label: "May 9 spike")
        )
        XCTAssertTrue(prompt.contains("spike-may-09"))
        XCTAssertTrue(prompt.lowercased().contains("investigate"))
    }

    func test_citationPrompt_queryRerunsAndExplains() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .query(text: "weekly cost rollup"), label: "weekly cost rollup")
        )
        XCTAssertTrue(prompt.lowercased().contains("re-run"))
    }

    func test_citationPrompt_quotaDetailsHeadroom() {
        let prompt = IntelligenceBriefCitationPrompt.prompt(
            for: InsightCitation(kind: .quota(provider: "anthropic", bucket: "messages-5h"), label: "Anthropic 5h")
        )
        XCTAssertTrue(prompt.contains("anthropic"))
        XCTAssertTrue(prompt.contains("messages-5h"))
        XCTAssertTrue(prompt.lowercased().contains("headroom"))
    }

    func test_citationPrompt_isNonEmptyForEveryKind() {
        // Defensive: any new `InsightCitation.Kind` variant added in
        // future must map to a non-empty prompt — otherwise tapping the
        // chip silently does nothing.
        let kinds: [InsightCitation.Kind] = [
            .session(id: "s", provider: "p"),
            .model(id: "m"),
            .agent(provider: "a"),
            .project(name: "p"),
            .day(date: "d"),
            .anomaly(id: "x"),
            .query(text: "q"),
            .quota(provider: "p", bucket: "b"),
            .benchmark(source: "artificial_analysis", modelID: "gpt-5.5", taskCategory: "coding")
        ]
        for kind in kinds {
            let prompt = IntelligenceBriefCitationPrompt.prompt(
                for: InsightCitation(kind: kind, label: "Label")
            )
            XCTAssertFalse(prompt.isEmpty, "Empty prompt for citation kind \(kind)")
            XCTAssertGreaterThan(prompt.count, 12, "Prompt for \(kind) too short to be useful: '\(prompt)'")
        }
    }

    // MARK: - Mission launch wiring

    func test_missionLaunchContractPassesSelectedRuntimeAndKind() throws {
        var captured: (kind: String, runtime: String, prompt: String, options: InsightMissionLaunchOptions)?
        let action = try XCTUnwrap(
            InsightMissionLaunchAction.defaultActions.first { $0.kind == .creative }
        )
        let runtime = InsightMissionRuntimeTarget.piAgent
        let options = InsightMissionLaunchOptions(
            requestedRuntime: runtime.firestoreValue,
            targetProject: "~/Developer/OpenBurnBar",
            depth: "deep",
            approvalMode: "risky_only",
            commandsAllowed: true,
            fileEditsAllowed: false
        )

        let dispatch: (InsightFollowUpQuestion, String, String, InsightMissionLaunchOptions) -> Void = { question, kind, runtime, options in
            captured = (kind, runtime, question.question, options)
        }
        dispatch(action.followUpQuestion, action.kind.firestoreValue, runtime.firestoreValue, options)

        XCTAssertEqual(captured?.kind, "creative")
        XCTAssertEqual(captured?.runtime, "piAgent")
        XCTAssertTrue(captured?.prompt.contains("creative/accretive mission") == true)
        XCTAssertEqual(captured?.options.targetProject, "~/Developer/OpenBurnBar")
        XCTAssertEqual(captured?.options.depth, "deep")
        XCTAssertEqual(captured?.options.approvalMode, "risky_only")
        XCTAssertEqual(captured?.options.commandsAllowed, true)
        XCTAssertEqual(captured?.options.fileEditsAllowed, false)
    }

    func test_missionLaunchContractIncludesAllMobileRemoteControlRuntimes() {
        XCTAssertEqual(
            InsightMissionRuntimeTarget.allCases.map(\.firestoreValue),
            ["auto", "codex", "claude", "hermes", "openclaw", "piAgent", "opencode", "ollama"]
        )
        XCTAssertEqual(
            InsightMissionLaunchAction.defaultActions.map { $0.kind.firestoreValue },
            [
                "creative",
                "diligence",
                "debt",
                "accretive",
                "security",
                "ui_improvement",
                "modernization",
                "provider_routing",
                "cost_efficiency",
                "project_focus",
                "custom"
            ]
        )
    }

    func test_recommendedMissionCandidateLaunchQuestionCarriesDispatchContext() {
        let candidate = InsightMissionCandidate(
            title: "Fix router fallback churn",
            summary: "Provider routing is changing too often during routine sessions.",
            projectID: "burnbar",
            projectDisplayName: "~/Documents/Windsurf/BurnBar",
            lens: .routing,
            priority: .high,
            confidence: .high,
            expectedImpact: "Stable favorite routing",
            effort: .medium,
            acceptanceCriteria: [
                "Codex remains sticky for routine edits",
                "Fallback only happens on quota exhaustion"
            ],
            evidence: [
                InsightCitation(kind: .project(name: "BurnBar"), label: "BurnBar routing digest")
            ]
        )

        XCTAssertEqual(candidate.launchMissionKind, "provider_routing")
        XCTAssertEqual(candidate.launchQuestion.rationale, "Launches a recommended mission candidate with its brief context.")
        XCTAssertTrue(candidate.launchQuestion.question.contains("Launch this recommended provider_routing mission"))
        XCTAssertTrue(candidate.launchQuestion.question.contains("Fix router fallback churn"))
        XCTAssertTrue(candidate.launchQuestion.question.contains("~/Documents/Windsurf/BurnBar"))
        XCTAssertTrue(candidate.launchQuestion.question.contains("- Codex remains sticky for routine edits"))
        XCTAssertTrue(candidate.launchQuestion.question.contains("BurnBar routing digest"))
    }

    func test_cliAgentMissionRequestPayloadIncludesLaunchOptionsWithoutMutableParentEvents() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-14T10:00:00Z"))
        let payload = CLIAgentMissionRequestPayloadFactory.build(
            id: "mission-123",
            title: "  Run cost mission  ",
            prompt: "  Inspect provider routing cost  ",
            missionKind: "cost_efficiency",
            requestedRuntime: "opencode",
            targetProject: "  ~/Developer/OpenBurnBar  ",
            depth: "deep",
            approvalMode: "risky_only",
            commandsAllowed: true,
            fileEditsAllowed: false,
            now: now
        )

        XCTAssertEqual(payload["id"] as? String, "mission-123")
        XCTAssertEqual(payload["title"] as? String, "Run cost mission")
        XCTAssertEqual(payload["prompt"] as? String, "Inspect provider routing cost")
        XCTAssertEqual(payload["missionKind"] as? String, "cost_efficiency")
        XCTAssertEqual(payload["requestedRuntime"] as? String, "opencode")
        XCTAssertEqual(payload["targetProject"] as? String, "~/Developer/OpenBurnBar")
        XCTAssertEqual(payload["depth"] as? String, "deep")
        XCTAssertEqual(payload["approvalMode"] as? String, "risky_only")
        XCTAssertEqual(payload["commandsAllowed"] as? Bool, true)
        XCTAssertEqual(payload["fileEditsAllowed"] as? Bool, false)
        XCTAssertEqual(payload["source"] as? String, "ios-insights")
        XCTAssertEqual(payload["status"] as? String, "pending")
        XCTAssertEqual(payload["schemaVersion"] as? Int, 2)
        XCTAssertNil(payload["events"])
    }

    func test_cliAgentMissionInitialQueuedEventTargetsDurableSubcollection() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-14T10:00:00Z"))
        let event = CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(now: now)

        XCTAssertEqual(event["sequence"] as? Int, 1)
        XCTAssertEqual(event["timestamp"] as? String, "2026-05-14T10:00:00Z")
        XCTAssertEqual(event["phase"] as? String, "queued")
        XCTAssertEqual(event["kind"] as? String, "status")
        XCTAssertEqual(event["source"] as? String, "ios")
        XCTAssertEqual(event["isError"] as? Bool, false)
    }

    func test_cliAgentMissionSnapshotDecodesLiveFeedAndTerminalResult() throws {
        let snapshot = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "mission-1", data: [
            "id": "mission-1",
            "title": "Run a debt mission",
            "status": "completed",
            "requestedRuntime": "auto",
            "selectedRuntime": "codex",
            "selectedRuntimeName": "Codex",
            "liveSummary": "Codex is summarizing the result.",
            "resultPreview": "Found three high-leverage refactors.",
            "sessionId": "thread-123",
            "events": [
                [
                    "timestamp": "2026-05-14T10:00:00Z",
                    "phase": "queued",
                    "message": "Mission queued from this device.",
                    "source": "ios"
                ],
                [
                    "timestamp": "2026-05-14T10:00:02Z",
                    "phase": "running",
                    "message": "Codex is inspecting the repo.",
                    "runtime": "codex",
                    "source": "mac"
                ],
                [
                    "timestamp": "2026-05-14T10:00:10Z",
                    "phase": "completed",
                    "message": "Found three high-leverage refactors.",
                    "runtime": "codex",
                    "source": "mac"
                ]
            ]
        ]))

        XCTAssertEqual(snapshot.runtimeLabel, "Codex")
        XCTAssertEqual(snapshot.events.map(\.phase), ["queued", "running", "completed"])
        XCTAssertEqual(snapshot.resultPreview, "Found three high-leverage refactors.")
        XCTAssertEqual(snapshot.sessionID, "thread-123")
        XCTAssertTrue(snapshot.isTerminal)
    }

    func test_cliAgentMissionSnapshotShowsMacOfflineForStaleQueuedMission() throws {
        let staleCreatedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180))
        let snapshot = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "mission-stale", data: [
            "id": "mission-stale",
            "title": "Run a modernization mission",
            "status": "pending",
            "requestedRuntime": "codex",
            "createdAt": staleCreatedAt,
            "events": []
        ]))

        XCTAssertEqual(snapshot.displayStatus, "mac_offline")
        XCTAssertTrue(snapshot.displayLiveSummary?.contains("No signed-in Mac") == true)
    }

    func test_cliAgentMissionSnapshotDecodesPendingApprovalPrompt() throws {
        let snapshot = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "mission-approval", data: [
            "id": "mission-approval",
            "title": "Run a risky mission",
            "status": "waiting_for_approval",
            "requestedRuntime": "codex",
            "approvalRequestId": "approval-1",
            "approvalStatus": "pending",
            "approvalTitle": "Approve Run a risky mission",
            "approvalMessage": "Codex is waiting for approval before commands and file edits.",
            "events": []
        ]))

        XCTAssertTrue(snapshot.isWaitingForApproval)
        XCTAssertEqual(snapshot.approvalRequestId, "approval-1")
        XCTAssertEqual(snapshot.approvalTitle, "Approve Run a risky mission")
        XCTAssertEqual(snapshot.approvalMessage, "Codex is waiting for approval before commands and file edits.")
    }

    func test_cliAgentMissionSnapshotShowsEveryRequiredMissionState() throws {
        let terminalStatuses = ["completed", "failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed"]
        let nonTerminalStatuses = ["queued", "accepted", "starting", "running", "waiting_for_approval"]

        for status in terminalStatuses {
            let snapshot = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "mission-\(status)", data: [
                "id": "mission-\(status)",
                "title": "Mission \(status)",
                "status": status,
                "requestedRuntime": "codex",
                "events": []
            ]))
            XCTAssertEqual(snapshot.displayStatus, status)
            XCTAssertTrue(snapshot.isTerminal, "\(status) should be terminal")
        }

        for status in nonTerminalStatuses {
            let snapshot = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "mission-\(status)", data: [
                "id": "mission-\(status)",
                "title": "Mission \(status)",
                "status": status,
                "requestedRuntime": "codex",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "approvalStatus": status == "waiting_for_approval" ? "pending" : "none",
                "events": []
            ]))
            XCTAssertEqual(snapshot.displayStatus, status)
            XCTAssertFalse(snapshot.isTerminal, "\(status) should not be terminal")
        }
    }

    func test_cliAgentMissionSnapshotUsesDurableEventOverrideForResumeAfterBackground() throws {
        let parentEvents: [[String: Any]] = [
            [
                "sequence": 99,
                "timestamp": "2026-05-14T10:00:99Z",
                "kind": "status",
                "phase": "stale_parent_preview",
                "message": "Old parent array event.",
                "source": "mac"
            ]
        ]
        let durableEvents = [
            try XCTUnwrap(CLIAgentMissionEvent(data: [
                "sequence": 3,
                "timestamp": "2026-05-14T10:00:03Z",
                "kind": "tool_result",
                "phase": "process_output",
                "title": "Process",
                "message": "Tests passed.",
                "runtime": "codex",
                "source": "mac",
                "isError": false
            ])),
            try XCTUnwrap(CLIAgentMissionEvent(data: [
                "sequence": 2,
                "timestamp": "2026-05-14T10:00:02Z",
                "kind": "tool_call",
                "phase": "tool_use",
                "title": "Shell",
                "message": "swift test",
                "runtime": "codex",
                "toolName": "exec_command",
                "source": "mac",
                "isError": false
            ]))
        ]

        let snapshot = try XCTUnwrap(CLIAgentMissionSnapshot(
            documentID: "mission-resume",
            data: [
                "id": "mission-resume",
                "title": "Resume mission",
                "status": "running",
                "requestedRuntime": "codex",
                "events": parentEvents
            ],
            eventOverride: durableEvents
        ))

        XCTAssertEqual(snapshot.events.map(\.sequence), [2, 3])
        XCTAssertEqual(snapshot.events.map(\.kind), ["tool_call", "tool_result"])
        XCTAssertEqual(snapshot.events.first?.toolName, "exec_command")
        XCTAssertFalse(snapshot.events.contains { $0.phase == "stale_parent_preview" })
    }

    func test_cliAgentMissionSnapshotDerivesOperatorConsoleStatus() throws {
        let snapshot = try XCTUnwrap(CLIAgentMissionSnapshot(documentID: "mission-console", data: [
            "id": "mission-console",
            "title": "Operator console mission",
            "status": "running",
            "requestedRuntime": "codex",
            "events": [
                [
                    "sequence": 1,
                    "timestamp": "2026-05-14T10:00:00Z",
                    "kind": "status",
                    "phase": "starting",
                    "title": "Starting",
                    "message": "Starting Codex.",
                    "source": "mac",
                    "isError": false
                ],
                [
                    "sequence": 2,
                    "timestamp": "2026-05-14T10:00:01Z",
                    "kind": "tool_call",
                    "phase": "tool_use",
                    "title": "Shell",
                    "message": "Running tests.",
                    "runtime": "codex",
                    "toolName": "exec_command",
                    "source": "mac",
                    "isError": false
                ],
                [
                    "sequence": 3,
                    "timestamp": "2026-05-14T10:00:02Z",
                    "kind": "changed_file",
                    "phase": "changed_file",
                    "title": "Changed file",
                    "message": "OpenBurnBarMobile/Views/Insights/InsightsRootView.swift",
                    "runtime": "codex",
                    "changedFilePath": "OpenBurnBarMobile/Views/Insights/InsightsRootView.swift",
                    "source": "mac",
                    "isError": false
                ]
            ]
        ]))

        XCTAssertEqual(snapshot.currentStepLabel, "Changed file")
        XCTAssertEqual(snapshot.activeToolName, "exec_command")
        XCTAssertEqual(snapshot.latestArtifactLabel, "OpenBurnBarMobile/Views/Insights/InsightsRootView.swift")
    }
}

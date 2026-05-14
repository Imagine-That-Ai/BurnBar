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
        var captured: (kind: String, runtime: String, prompt: String)?
        let action = try XCTUnwrap(
            InsightMissionLaunchAction.defaultActions.first { $0.kind == .creative }
        )
        let runtime = InsightMissionRuntimeTarget.piAgent

        let dispatch: (InsightFollowUpQuestion, String, String) -> Void = { question, kind, runtime in
            captured = (kind, runtime, question.question)
        }
        dispatch(action.followUpQuestion, action.kind.firestoreValue, runtime.firestoreValue)

        XCTAssertEqual(captured?.kind, "creative")
        XCTAssertEqual(captured?.runtime, "piAgent")
        XCTAssertTrue(captured?.prompt.contains("creative/accretive mission") == true)
    }

    func test_missionLaunchContractIncludesAllMobileRemoteControlRuntimes() {
        XCTAssertEqual(
            InsightMissionRuntimeTarget.allCases.map(\.firestoreValue),
            ["auto", "codex", "claude", "hermes", "openclaw", "piAgent"]
        )
        XCTAssertEqual(
            InsightMissionLaunchAction.defaultActions.map { $0.kind.firestoreValue },
            ["creative", "diligence", "debt"]
        )
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
}

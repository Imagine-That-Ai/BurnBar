import XCTest
@testable import OpenBurnBar
import OpenBurnBarCore

final class BugReportingTests: XCTestCase {
    func testSystemDiagnosticsCollectorCapturesValidSnapshot() {
        let snapshot = SystemDiagnosticsCollector.capture(
            isDaemonConnected: true,
            activeProviders: ["claude", "codex"]
        )

        XCTAssertFalse(snapshot.osVersion.isEmpty)
        XCTAssertFalse(snapshot.macModel.isEmpty)
        XCTAssertFalse(snapshot.appVersion.isEmpty)
        XCTAssertGreaterThan(snapshot.physicalMemoryGB, 0)
        XCTAssertTrue(snapshot.isDaemonConnected)
        XCTAssertEqual(snapshot.activeProviders, ["claude", "codex"])

        let dict = snapshot.asDictionary
        XCTAssertEqual(dict["osVersion"] as? String, snapshot.osVersion)
        XCTAssertEqual(dict["macModel"] as? String, snapshot.macModel)
        XCTAssertEqual(dict["isDaemonConnected"] as? Bool, true)
    }

    func testBugInvestigationMissionRuntimeResolution() {
        let backend = CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: "auto",
            missionKind: "bug_investigation",
            enabledBackends: [.claude, .codex]
        )

        XCTAssertEqual(backend.rawValue, "claude")
    }

    func testBugInvestigationPromptFormatting() {
        let data: [String: Any] = [
            "source": "macos-bug-report",
            "targetProject": "BurnBar",
            "missionKind": "bug_investigation",
            "commandsAllowed": true,
            "fileEditsAllowed": true,
        ]

        let prompt = CLIAgentMissionRuntimePlanner.prompt(
            title: "[Bug BB-42] Fix menu bar crash",
            prompt: "Please investigate the crash logs and write a unit test.",
            backend: CLIAgentMissionBackend(chatBackend: .claude),
            data: data
        )

        XCTAssertTrue(prompt.contains("investigating a bug report filed into Linear"))
        XCTAssertTrue(prompt.contains("[Bug BB-42] Fix menu bar crash"))
        XCTAssertTrue(prompt.contains("Target project: BurnBar"))
        XCTAssertTrue(prompt.contains("Commands allowed: yes"))
        XCTAssertTrue(prompt.contains("File edits allowed: yes"))
    }

    @MainActor
    func testAppCommandRouterHandlesBugReportAndHelpSupportUrls() {
        let router = AppCommandRouter()
        var bugReportOpened = false
        var helpSupportOpened = false

        router.openBugReport = { bugReportOpened = true }
        router.openHelpSupport = { helpSupportOpened = true }

        let bugUrl = URL(string: "openburnbar://bug-report")!
        let handledBug = router.handle(bugUrl)
        XCTAssertTrue(handledBug)
        XCTAssertTrue(bugReportOpened)

        let supportUrl = URL(string: "openburnbar://support")!
        let handledSupport = router.handle(supportUrl)
        XCTAssertTrue(handledSupport)
        XCTAssertTrue(helpSupportOpened)
    }
}

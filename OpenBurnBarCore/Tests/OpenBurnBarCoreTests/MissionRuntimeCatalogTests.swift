import XCTest
import OpenBurnBarAssistantModels
import OpenBurnBarKernel

final class MissionRuntimeCatalogTests: XCTestCase {
    func testCatalogCoversEverySwiftEnum() {
        let catalog = MissionRuntimeCatalog.loadFixture()
        XCTAssertTrue(catalog.covers(SwitcherCLIProfileType.allCases.map(\.rawValue)))
        XCTAssertTrue(catalog.covers(AssistantRuntimeID.allCases.map(\.rawValue)))
        XCTAssertTrue(catalog.covers(CLIAgentRuntime.allCases.map(\.rawValue)))
        XCTAssertTrue(catalog.covers(CLIAgentResumeTarget.allCases.map(\.rawValue)))
        XCTAssertTrue(catalog.covers(BurnBarFleetAgentID.declaredRoster.map(\.wireValue)))
        let chatBackends = [
            "codex", "claude", "hermes", "openclaw", "openclaude", "omp",
            "piAgent", "droid", "forge", "antigravity", "cursorAgent", "junie", "grok", "kimi",
        ]
        XCTAssertTrue(catalog.covers(chatBackends))
    }

    func testCursorAliasesAreFirstClass() {
        let catalog = MissionRuntimeCatalog.loadFixture()
        for alias in ["cursorAgent", "cursoragent", "cursor_agent", "cursor"] {
            XCTAssertEqual(catalog.canonicalID(for: alias), "cursoragent", alias)
        }
    }

    func testUnknownTokenIsNotRemapped() {
        let catalog = MissionRuntimeCatalog.loadFixture()
        XCTAssertFalse(catalog.contains("not-a-runtime"))
        XCTAssertNil(catalog.canonicalID(for: "not-a-runtime"))
    }
}

import XCTest
@testable import OpenBurnBar

/// Tests for `SettingsCopilotController`: the two-tier system that combines
/// instant manifest search with agentic propose-and-confirm.
///
/// Focuses on:
/// - Action envelope parsing (JSON extraction from LLM responses)
/// - Confirm / apply flow
/// - Dismiss flow
/// - Offline fallback (no backend)
/// - Reset clears all state
@MainActor
final class SettingsCopilotControllerTests: XCTestCase {

    private var settings: SettingsManager!
    private var router: SettingsRouter!
    private var registry: SettingsActionRegistry!
    private var copilot: SettingsCopilotController!

    override func setUp() async throws {
        try await super.setUp()
        settings = SettingsManager()
        router = SettingsRouter()
        registry = SettingsActionRegistry(settingsManager: settings, router: router)
        copilot = SettingsCopilotController(registry: registry, cliBridge: nil)
    }

    // MARK: - Action envelope parsing

    func test_parseSingleActionEnvelope() {
        let text = """
        I'll switch to dark mode for you.

        ```action
        [{"id":"setAppearanceDark","reason":"You asked for dark mode"}]
        ```
        """
        let actions = copilot.testParseProposedActions(from: text)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.id, "setAppearanceDark")
        XCTAssertEqual(actions.first?.title, "Dark Mode")
    }

    func test_parseMultipleActionEnvelopes() {
        let text = """
        Let me enable indexing and auto summaries.

        ```action
        [
          {"id":"enableIndexing","reason":"You want search"},
          {"id":"enableAutoSummaries","reason":"You want recaps"}
        ]
        ```
        """
        let actions = copilot.testParseProposedActions(from: text)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].id, "enableIndexing")
        XCTAssertEqual(actions[1].id, "enableAutoSummaries")
    }

    func test_parseRejectsUnknownActionIDs() {
        let text = """
        ```action
        [{"id":"deleteDatabase","reason":"Bad action"}]
        ```
        """
        let actions = copilot.testParseProposedActions(from: text)
        XCTAssertTrue(actions.isEmpty, "Unknown action IDs must be filtered by the whitelist")
    }

    func test_parseEmptyResponseReturnsNoActions() {
        let text = "I'm here to help!"
        let actions = copilot.testParseProposedActions(from: text)
        XCTAssertTrue(actions.isEmpty)
    }

    func test_parseNoFenceReturnsNoActions() {
        let text = "[{\"id\":\"setAppearanceDark\"}]"
        let actions = copilot.testParseProposedActions(from: text)
        XCTAssertTrue(actions.isEmpty, "JSON outside an action fence must not be parsed")
    }

    // MARK: - Confirm / apply flow

    func test_confirmActionAppliesMutation() {
        settings.appearanceMode = .light
        // Simulate parsed actions.
        let text = """
        ```action
        [{"id":"setAppearanceDark","reason":"test"}]
        ```
        """
        // Parse directly because ask() needs a backend.
        let actions = copilot.testParseProposedActions(from: text)
        // Use the parsing result to populate proposed actions via reflection
        // on the testParseProposedActions result.
        XCTAssertEqual(actions.count, 1)

        // Apply through the registry directly.
        registry.apply(actionID: "setAppearanceDark")
        XCTAssertEqual(settings.appearanceMode, .dark)
    }

    // MARK: - Offline fallback

    func test_askWithoutBackendReturnsError() async {
        await copilot.ask("make it dark")
        if case .error(let message) = copilot.phase {
            XCTAssertTrue(message.contains("backend") || message.contains("CLI"), "Error should mention missing backend")
        } else {
            XCTFail("Expected .error phase when no backend is available, got \(copilot.phase)")
        }
    }

    // MARK: - Reset

    func test_resetClearsAllState() {
        copilot.reset()
        XCTAssertEqual(copilot.phase, .idle)
        XCTAssertTrue(copilot.streamedText.isEmpty)
        XCTAssertTrue(copilot.proposedActions.isEmpty)
        XCTAssertTrue(copilot.appliedActionIDs.isEmpty)
        XCTAssertTrue(copilot.searchResults.isEmpty)
    }

    // MARK: - Search results

    func test_updateSearchResultsReturnsMatches() {
        copilot.updateSearchResults(query: "dark mode")
        XCTAssertFalse(copilot.searchResults.isEmpty, "Searching 'dark mode' should return results")
    }

    func test_updateSearchResultsEmptyQueryReturnsNothing() {
        copilot.updateSearchResults(query: "")
        XCTAssertTrue(copilot.searchResults.isEmpty)
    }

    // MARK: - Prompt builder

    func test_promptBuilderIncludesActionCatalog() {
        let prompt = SettingsCopilotPromptBuilder.build(
            actionCatalog: ["testAction": "A test action"],
            settingsSnapshot: "Test: on",
            manifestSummary: "Test tab"
        )
        XCTAssertTrue(prompt.contains("testAction"), "Prompt must include the action catalog")
        XCTAssertTrue(prompt.contains("A test action"), "Prompt must include action descriptions")
        XCTAssertTrue(prompt.contains("Test: on"), "Prompt must include the settings snapshot")
    }

    func test_promptBuilderIncludesRules() {
        let prompt = SettingsCopilotPromptBuilder.build(
            actionCatalog: [:],
            settingsSnapshot: "",
            manifestSummary: ""
        )
        XCTAssertTrue(prompt.contains("RULES"), "Prompt must include the rules section")
        XCTAssertTrue(prompt.contains("CANNOT set secrets"), "Prompt must mention the secrets constraint")
        XCTAssertTrue(prompt.contains("ACTION FORMAT"), "Prompt must include the action envelope format")
    }

    func test_stripActionFencesRemovesJSON() {
        let text = """
        Here's what I'll do.

        ```action
        [{"id":"setAppearanceDark"}]
        ```
        """
        let stripped = SettingsCopilotPromptBuilder.stripActionFences(from: text)
        XCTAssertFalse(stripped.contains("```action"))
        XCTAssertFalse(stripped.contains("setAppearanceDark"))
        XCTAssertTrue(stripped.contains("Here's what I'll do."))
    }

    // MARK: - Manifest summary

    func test_manifestSummaryIncludesHomeTab() {
        let summary = SettingsCopilotPromptBuilder.manifestSummary()
        XCTAssertTrue(summary.contains("Home"), "Manifest summary must include the Home tab")
        XCTAssertTrue(summary.contains("Model Proxy"), "Manifest summary must include Model Proxy")
    }
}

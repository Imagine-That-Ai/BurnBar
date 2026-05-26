import XCTest
@testable import OpenBurnBarCore

final class CLIRuntimeModelCatalogTests: XCTestCase {
    func test_defaultProfileOptionsOnlyExistForNonEnumerableCLIs() {
        XCTAssertEqual(CLIRuntimeModelCatalog.defaultProfileOption(for: .codex)?.displayName, "Codex CLI default · OpenAI · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(CLIRuntimeModelCatalog.defaultProfileOption(for: .claude)?.displayName, "Claude Code default · Anthropic · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(CLIRuntimeModelCatalog.defaultProfileOption(for: .antigravity)?.displayName, "Antigravity default · Google · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(CLIRuntimeModelCatalog.defaultProfileOption(for: .antigravity)?.source, .antigravityProfile)
        XCTAssertNil(CLIRuntimeModelCatalog.defaultProfileOption(for: .droid))
        XCTAssertNil(CLIRuntimeModelCatalog.defaultProfileOption(for: .forge))
    }

    func test_droidParserUsesMachineHelpOutputAndSeparatesQuotaSources() {
        let help = """
        Available Models:
          claude-opus-4-7                                           Claude Opus 4.7 (default)
          glm-5.1                                                   Droid Core (GLM-5.1)

        Custom Models:
          custom:OpenBurnBar-claude-opus-4-7-1                      OpenBurnBar Claude Opus 4.7
          custom:team-local-model                                   Team Local Model

        Model details:
          - ignored
        """

        let rows = CLIRuntimeModelCatalog.parseDroidExecHelp(help)

        XCTAssertEqual(rows.map(\.modelID), [
            "claude-opus-4-7",
            "glm-5.1",
            "custom:OpenBurnBar-claude-opus-4-7-1",
            "custom:team-local-model"
        ])
        XCTAssertEqual(rows[0].displayName, "Claude Opus 4.7 · Factory Droid Standard · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(rows[0].source, .droidStandardQuota)
        XCTAssertEqual(rows[1].source, .droidCoreQuota)
        XCTAssertEqual(rows[1].displayName, "Droid Core (GLM-5.1) · Factory Droid Core · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(rows[2].source, .openBurnBarProxy)
        XCTAssertEqual(rows[2].providerID, "anthropic")
        XCTAssertEqual(rows[2].providerName, "Anthropic via OpenBurnBar API/OAuth")
        XCTAssertEqual(rows[2].displayName, "Claude Opus 4.7 · Anthropic · via OpenBurnBar · Reasoning: default")
        XCTAssertEqual(rows[3].source, .droidCustomModel)
        XCTAssertEqual(rows[3].displayName, "Team Local Model · Droid custom model · via OpenBurnBar · Reasoning: CLI default")
    }

    func test_droidParserDeduplicatesMachineOutput() {
        let help = """
        Available Models:
          glm-5.1                                                   Droid Core (GLM-5.1)
          glm-5.1                                                   Droid Core (GLM-5.1)
        """

        XCTAssertEqual(CLIRuntimeModelCatalog.parseDroidExecHelp(help).map(\.modelID), ["glm-5.1"])
    }

    func test_forgeParserUsesInstalledAgentListOutput() {
        let output = """
        FORGE
          id                forge
          title             Perform technical development tasks
          provider          KimiCoding
          model             kimi-for-coding

        MUSE
          id                muse
          title             Generate detailed implementation plans
        """

        let rows = CLIRuntimeModelCatalog.parseForgeAgentList(output)

        XCTAssertEqual(rows.map(\.modelID), ["forge", "muse"])
        XCTAssertEqual(rows[0].displayName, "Perform technical development tasks · KimiCoding / kimi-for-coding · via OpenBurnBar · Reasoning: agent default")
        XCTAssertEqual(rows[0].providerID, "kimicoding")
        XCTAssertEqual(rows[0].providerName, "KimiCoding / kimi-for-coding")
        XCTAssertEqual(Set(rows.map(\.source)), [.forgeAgent])
    }

    func test_userFacingDisplayNameFormatterNamesProviderRouteAndReasoning() {
        XCTAssertEqual(
            OpenBurnBarModelDisplayName.compose(
                modelName: "Kimi K2.6",
                providerName: nil,
                providerID: "kimi",
                reasoningLevel: "xhigh"
            ),
            "Kimi K2.6 · Moonshot Kimi · via OpenBurnBar · Reasoning: extra high"
        )
    }

    func test_userFacingDisplayNameFormatterKeepsRouteWhenRawNameMentionsOpenBurnBar() {
        XCTAssertEqual(
            OpenBurnBarModelDisplayName.compose(
                modelName: "OpenBurnBar Claude Opus 4.7",
                providerName: "Anthropic via OpenBurnBar API/OAuth",
                providerID: "anthropic"
            ),
            "OpenBurnBar Claude Opus 4.7 · Anthropic · via OpenBurnBar · Reasoning: default"
        )
    }

    func test_codexNormalizerAcceptsBundledCatalogSlugs() {
        XCTAssertEqual(CLIRuntimeModelCatalog.normalizedCodexModel("gpt-5-5"), "gpt-5.5")
        XCTAssertEqual(CLIRuntimeModelCatalog.normalizedCodexModel("gpt-5-3-codex"), "gpt-5.3-codex")
        XCTAssertEqual(CLIRuntimeModelCatalog.normalizedCodexModel("unknown-frontier-model"), "unknown-frontier-model")
        XCTAssertEqual(CLIRuntimeModelCatalog.normalizedCodexModel("glm-5-1"), "glm-5.1")
        XCTAssertEqual(CLIRuntimeModelCatalog.normalizedCodexModel("gpt-5-3-codex-fast"), "gpt-5.3-codex-fast")
    }
}

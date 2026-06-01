import XCTest
@testable import OpenBurnBarCore

final class CLIRuntimeModelCatalogTests: XCTestCase {
    func test_defaultProfileOptionsRemainFallbackRows() {
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

    func test_codexDebugModelsParserUsesLiveCatalogRows() throws {
        let json = """
        {
          "models": [
            {"slug": "gpt-5-5", "display_name": "GPT-5.5", "visibility": "list", "default_reasoning_level": "medium"},
            {"slug": "gpt-5-3-codex-spark", "display_name": "GPT-5.3-Codex-Spark", "visibility": "list", "default_reasoning_level": "high"},
            {"slug": "codex-auto-review", "display_name": "Codex Auto Review", "visibility": "hide"}
          ]
        }
        """.data(using: .utf8)!

        let rows = CLIRuntimeModelCatalog.parseCodexDebugModels(json)

        XCTAssertEqual(rows.map(\.modelID), ["gpt-5.5", "gpt-5.3-codex-spark"])
        XCTAssertEqual(rows.map(\.source), [.codexModelCatalog, .codexModelCatalog])
        XCTAssertEqual(rows[0].displayName, "GPT-5.5 · OpenAI · via OpenBurnBar · Reasoning: medium")
        XCTAssertEqual(rows[1].displayName, "GPT-5.3-Codex-Spark · OpenAI · via OpenBurnBar · Reasoning: high")
    }

    func test_grokModelsParserUsesAvailableModelsSection() {
        let output = """
        You are logged in with grok.com.

        Default model: grok-build

        Available models:
          * grok-build (default)
          * grok-build-next
        """

        let rows = CLIRuntimeModelCatalog.parseGrokModels(output)

        XCTAssertEqual(rows.map(\.modelID), ["grok-build", "grok-build-next"])
        XCTAssertEqual(rows.map(\.source), [.grokModelCatalog, .grokModelCatalog])
        XCTAssertEqual(rows[0].displayName, "grok-build · xAI · via OpenBurnBar · Reasoning: CLI default")
    }

    func test_grokModelsCacheParserUsesLocalCatalogAndFiltersHiddenRows() {
        let json = """
        {
          "models": {
            "grok-build": {
              "info": {
                "model": "grok-build",
                "name": "Grok Build",
                "hidden": false,
                "supported_in_api": true
              }
            },
            "grok-hidden": {
              "info": {
                "model": "grok-hidden",
                "name": "Grok Hidden",
                "hidden": true,
                "supported_in_api": true
              }
            }
          }
        }
        """.data(using: .utf8)!

        let rows = CLIRuntimeModelCatalog.parseGrokModelsCache(json)

        XCTAssertEqual(rows.map(\.modelID), ["grok-build"])
        XCTAssertEqual(rows.first?.source, .grokModelCatalog)
        XCTAssertEqual(rows.first?.displayName, "Grok Build · xAI · via OpenBurnBar · Reasoning: CLI default")
    }

    func test_ollamaTagsParserSeparatesLocalAndCloudModels() {
        let json = Data("""
        {
          "models": [
            {"name": "qwen2.5:3b", "model": "qwen2.5:3b", "details": {"parameter_size": "3.1B"}},
            {"name": "llama3.2:latest", "model": "llama3.2:latest", "details": {"parameter_size": "3.2B"}},
            {"name": "gpt-oss:120b-cloud", "model": "gpt-oss:120b-cloud", "details": {}},
            {"name": "qwen2.5:3b", "model": "qwen2.5:3b", "details": {"parameter_size": "3.1B"}}
          ]
        }
        """.utf8)

        let rows = CLIRuntimeModelCatalog.parseOllamaTags(json)

        // Duplicate qwen2.5:3b is collapsed; three distinct models remain.
        XCTAssertEqual(rows.map(\.modelID), ["qwen2.5:3b", "llama3.2:latest", "gpt-oss:120b-cloud"])
        XCTAssertEqual(rows[0].source, .ollamaLocalCatalog)
        XCTAssertEqual(rows[0].providerID, "ollama-local")
        XCTAssertEqual(rows[0].displayName, "qwen2.5:3b (3.1B) · Ollama (Local) · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(rows[1].source, .ollamaLocalCatalog)
        XCTAssertEqual(rows[2].source, .ollamaCloudCatalog)
        XCTAssertEqual(rows[2].providerID, "ollama")
        XCTAssertEqual(rows[2].providerName, "Ollama Cloud")
        XCTAssertEqual(rows[2].displayName, "gpt-oss:120b-cloud · Ollama Cloud · via OpenBurnBar · Reasoning: CLI default")
    }

    func test_ollamaTagsParserReturnsEmptyForInvalidPayload() {
        XCTAssertTrue(CLIRuntimeModelCatalog.parseOllamaTags(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(CLIRuntimeModelCatalog.parseOllamaTags(Data(#"{"models": []}"#.utf8)).isEmpty)
    }

    func test_claudeCodeModelCatalogOptionsEnumerateBundledAnthropicModels() {
        let rows = CLIRuntimeModelCatalog.claudeCodeModelCatalogOptions()

        XCTAssertGreaterThan(rows.count, 4)
        XCTAssertTrue(rows.contains { $0.modelID == "claude-opus-4-8" })
        XCTAssertTrue(rows.contains { $0.modelID == "claude-sonnet-4-6" })
        XCTAssertFalse(rows.contains { $0.modelID == "claude-default-family" })
        XCTAssertEqual(Set(rows.map(\.source)), [.claudeModelCatalog])
    }

    func test_antigravityModelCatalogOptionsEnumerateBundledGoogleModelsAndAppendCustomProfile() {
        let rows = CLIRuntimeModelCatalog.antigravityModelCatalogOptions(
            selectedModelName: "gemini-api://localhost/models/team-model"
        )

        XCTAssertGreaterThan(rows.count, 4)
        XCTAssertTrue(rows.contains { $0.modelID == "gemini-3.1-pro-preview" })
        XCTAssertTrue(rows.contains { $0.modelID == "gemini-2.5-pro" })
        XCTAssertFalse(rows.contains { $0.modelID == "gemini-default-family" })
        XCTAssertTrue(rows.contains { $0.modelID == "gemini-api://localhost/models/team-model" && $0.source == .antigravityProfile })
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.source == .antigravityModelCatalog })
    }

    func test_antigravityProfileOptionReflectsSelectedModel() {
        let row = CLIRuntimeModelCatalog.antigravityProfileOption(modelName: "Claude Sonnet 4.6 (Thinking)")

        XCTAssertEqual(row.modelID, "Claude Sonnet 4.6 (Thinking)")
        XCTAssertEqual(row.source, .antigravityProfile)
        XCTAssertEqual(row.displayName, "Claude Sonnet 4.6 (Thinking) · Google · via OpenBurnBar · Reasoning: CLI default")
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

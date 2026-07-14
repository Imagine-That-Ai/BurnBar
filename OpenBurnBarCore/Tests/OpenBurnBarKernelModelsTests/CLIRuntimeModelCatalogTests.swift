import XCTest
@testable import OpenBurnBarKernelModels

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

    func test_droidParserRecognizesOpenBurnBarGLMCloudCustomModelAsOllamaCloud() {
        let help = """
        Custom Models:
          custom:OpenBurnBar-glm-5.2-cloud-7                         OBB GLM 5.2 Ollama Cloud
        """

        let rows = CLIRuntimeModelCatalog.parseDroidExecHelp(help)

        XCTAssertEqual(rows.map(\.modelID), ["custom:OpenBurnBar-glm-5.2-cloud-7"])
        XCTAssertEqual(rows.first?.source, .openBurnBarProxy)
        XCTAssertEqual(rows.first?.providerID, "ollama")
        XCTAssertEqual(rows.first?.providerName, "Ollama Cloud via OpenBurnBar API/OAuth")
        XCTAssertEqual(rows.first?.displayName, "GLM 5.2 Ollama Cloud · via OpenBurnBar · Reasoning: default")
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

    func test_codexNativeRowsCanSitBesideOpenBurnBarProxyRows() {
        let native = CLIRuntimeModelCatalog.parseCodexDebugModels(
            Data("""
            {
              "models": [
                {"slug": "gpt-5-5", "display_name": "GPT-5.5", "visibility": "list"}
              ]
            }
            """.utf8)
        )
        let proxy = CLIRuntimeModelOption(
            modelID: "openburnbar/glm-5.2",
            routeModelID: "glm-5.2",
            rowID: "openburnbar|zai|glm-5.2|codex",
            displayName: "GLM-5.2 · Z.AI · via OpenBurnBar · Reasoning: default",
            providerID: "zai",
            providerName: "Z.AI",
            source: .openBurnBarProxy
        )

        let merged = native + [proxy]

        XCTAssertTrue(merged.contains { $0.modelID == "gpt-5.5" && $0.source == .codexModelCatalog })
        XCTAssertTrue(merged.contains { $0.modelID == "openburnbar/glm-5.2" && $0.routeModelID == "glm-5.2" })
        XCTAssertEqual(Set(merged.map(\.id)).count, 2)
    }

    func test_claudeNativeRowsCanSitBesideOpenBurnBarProxyRows() {
        let native = CLIRuntimeModelCatalog.claudeCodeModelCatalogOptions()
        let proxy = CLIRuntimeModelOption(
            modelID: "glm-5.2",
            routeModelID: "glm-5.2",
            rowID: "openburnbar|zai|glm-5.2|claude",
            displayName: "GLM-5.2 · Z.AI · via OpenBurnBar · Reasoning: default",
            providerID: "zai",
            providerName: "Z.AI",
            source: .openBurnBarProxy
        )

        let merged = native + [proxy]

        XCTAssertTrue(merged.contains { $0.modelID == "claude-opus-4-8" && $0.source == .claudeModelCatalog })
        XCTAssertTrue(merged.contains { $0.modelID == "glm-5.2" && $0.source == .openBurnBarProxy })
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    func test_modelOptionIdentityKeepsSameVisibleModelDistinctAcrossSourcePaths() {
        let native = CLIRuntimeModelOption(
            modelID: "gpt-5.5",
            displayName: "GPT-5.5 · OpenAI · via OpenBurnBar · Reasoning: default",
            providerID: "openai",
            providerName: "OpenAI",
            source: .codexModelCatalog
        )
        let routed = CLIRuntimeModelOption(
            modelID: "gpt-5.5",
            routeModelID: "gpt-5.5",
            rowID: "openburnbar|openai|gpt-5.5|codex",
            displayName: "GPT-5.5 · OpenAI via OpenBurnBar · via OpenBurnBar · Reasoning: default",
            providerID: "openai",
            providerName: "OpenAI via OpenBurnBar",
            source: .openBurnBarProxy
        )

        XCTAssertNotEqual(native.id, routed.id)
        XCTAssertEqual(Set([native, routed]).count, 2)
    }

    func test_identicalProxyRowsCollapseByStableRowID() {
        let first = CLIRuntimeModelOption(
            modelID: "openburnbar/glm-5.2",
            routeModelID: "glm-5.2",
            rowID: "openburnbar|zai|glm-5.2|codex",
            displayName: "GLM-5.2 · Z.AI · via OpenBurnBar · Reasoning: default",
            providerID: "zai",
            providerName: "Z.AI",
            source: .openBurnBarProxy
        )
        let duplicate = CLIRuntimeModelOption(
            modelID: "openburnbar/glm-5.2",
            routeModelID: "glm-5.2",
            rowID: "openburnbar|zai|glm-5.2|codex",
            displayName: "GLM-5.2 · Z.AI · via OpenBurnBar · Reasoning: default",
            providerID: "zai",
            providerName: "Z.AI",
            source: .openBurnBarProxy
        )

        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertEqual(Set([first, duplicate]).count, 1)
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

    func test_cursorAgentModelsParserUsesAvailableModelsSection() {
        let output = """
        Available models

        auto - Auto (default)
        composer-2.5 - Composer 2.5 (current)
        claude-opus-4-8-high - Opus 4.8 1M
        gpt-5.4-high - GPT-5.4 1M High
        grok-4.5-xhigh - Cursor Grok 4.5

        Tip: use --model <id> (or /model <id> in interactive mode) to switch.
        """

        let rows = CLIRuntimeModelCatalog.parseCursorAgentModels(output)

        XCTAssertEqual(rows.map(\.modelID), [
            "auto",
            "composer-2.5",
            "claude-opus-4-8-high",
            "gpt-5.4-high",
            "grok-4.5-xhigh"
        ])
        XCTAssertEqual(Set(rows.map(\.source)), [.cursorAgentModelCatalog])
        XCTAssertEqual(rows[0].providerID, "cursor")
        XCTAssertEqual(rows[1].providerID, "cursor")
        XCTAssertEqual(rows[2].providerID, "anthropic")
        XCTAssertEqual(rows[3].providerID, "openai")
        XCTAssertEqual(rows[4].providerID, "xai")
        XCTAssertEqual(rows[0].displayName, "Auto · Cursor · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(rows[1].displayName, "Composer 2.5 · Cursor · via OpenBurnBar · Reasoning: CLI default")
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
            {"name": "glm-5.2-cloud", "model": "glm-5.2-cloud", "details": {}},
            {"name": "glm-5.2:cloud", "model": "glm-5.2:cloud", "details": {}},
            {"name": "qwen2.5:3b", "model": "qwen2.5:3b", "details": {"parameter_size": "3.1B"}}
          ]
        }
        """.utf8)

        let rows = CLIRuntimeModelCatalog.parseOllamaTags(json)

        // Duplicate qwen2.5:3b and equivalent GLM cloud suffixes are collapsed.
        XCTAssertEqual(rows.map(\.modelID), ["qwen2.5:3b", "llama3.2:latest", "gpt-oss:120b:cloud", "glm-5.2:cloud"])
        XCTAssertEqual(rows[0].source, .ollamaLocalCatalog)
        XCTAssertEqual(rows[0].providerID, "ollama-local")
        XCTAssertEqual(rows[0].displayName, "qwen2.5:3b (3.1B) · Ollama (Local) · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(rows[1].source, .ollamaLocalCatalog)
        XCTAssertEqual(rows[2].source, .ollamaCloudCatalog)
        XCTAssertEqual(rows[2].providerID, "ollama")
        XCTAssertEqual(rows[2].providerName, "Ollama Cloud")
        XCTAssertEqual(rows[2].displayName, "gpt-oss:120b:cloud · Ollama Cloud · via OpenBurnBar · Reasoning: CLI default")
        XCTAssertEqual(rows[3].source, .ollamaCloudCatalog)
        XCTAssertEqual(rows[3].displayName, "glm-5.2:cloud · Ollama Cloud · via OpenBurnBar · Reasoning: CLI default")
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

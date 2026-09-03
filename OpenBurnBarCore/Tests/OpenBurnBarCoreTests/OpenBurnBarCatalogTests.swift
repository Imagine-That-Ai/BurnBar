import XCTest
@testable import OpenBurnBarCore

final class BurnBarCatalogTests: XCTestCase {
    func test_bundledCatalog_decodesAndValidates() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog

        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertNoThrow(try catalog.validate())
        XCTAssertEqual(catalog.provider(id: "zai")?.baseURL, "https://api.z.ai/api/coding/paas/v4")
        XCTAssertEqual(catalog.suggestedModels(forProviderID: "zai").map(\.id), ["glm-5-turbo", "glm-5"])
    }

    func test_bundledCatalog_includesTheMemoryProProviders() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertNoThrow(try catalog.validate())
        XCTAssertEqual(catalog.provider(id: "openrouter")?.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(catalog.provider(id: "vercel-ai-gateway")?.baseURL, "https://ai-gateway.vercel.sh/v1")
        for providerID in ["openrouter", "vercel-ai-gateway"] {
            XCTAssertEqual(
                catalog.suggestedModels(forProviderID: providerID).map { $0.aliases.first ?? $0.id },
                ["anthropic/claude-opus-5", "anthropic/claude-haiku-4-5", "openai/gpt-5.5", "openai/text-embedding-3-small"],
                providerID
            )
            XCTAssertTrue(catalog.provider(id: providerID)?.capabilities.contains(.routing) ?? false, providerID)
        }
    }

    func test_catalogModelMissingPricingUsesFallbackPricing() throws {
        let data = """
        {
          "id": "opencode-oauth",
          "displayName": "OpenCode OAuth",
          "visibility": "public"
        }
        """.data(using: .utf8)!

        let model = try JSONDecoder().decode(BurnBarCatalogModel.self, from: data)

        XCTAssertEqual(model.pricing, .defaultFallback)
    }

    func test_catalogPricingLookup_usesMatcherRules() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog

        let sonnet = try XCTUnwrap(catalog.pricing(forModelName: "claude-3-5-sonnet-20241022"))
        let factorySonnext = try XCTUnwrap(catalog.pricing(forModelName: "Sonnext-4.6-9"))
        let gpt56Sol = try XCTUnwrap(catalog.pricing(forModelName: "gpt-5.6-sol"))
        let gpt56Terra = try XCTUnwrap(catalog.pricing(forModelName: "gpt-5.6-terra"))
        let gpt56Luna = try XCTUnwrap(catalog.pricing(forModelName: "gpt-5.6-luna"))
        let gpt55 = try XCTUnwrap(catalog.pricing(forModelName: "gpt-5.5"))
        let gpt55Pro = try XCTUnwrap(catalog.pricing(forModelName: "gpt-5.5-pro"))
        let factoryGLM5 = try XCTUnwrap(catalog.pricing(forModelName: "glm-5", providerID: "factory"))
        let directGLM5 = try XCTUnwrap(catalog.pricing(forModelName: "glm-5", providerID: "zai"))
        let minimax = try XCTUnwrap(catalog.pricing(forModelName: "MiniMax-M3-pro"))
        let codex = try XCTUnwrap(catalog.pricing(forModelName: "codex-pro"))

        XCTAssertEqual(sonnet.inputPerMToken, 3, accuracy: 0.001)
        XCTAssertEqual(sonnet.outputPerMToken, 15, accuracy: 0.001)
        XCTAssertEqual(sonnet.cacheCreationPerMToken ?? 0, 3.75, accuracy: 0.001)
        XCTAssertEqual(factorySonnext.inputPerMToken, 3, accuracy: 0.001)
        XCTAssertEqual(factorySonnext.outputPerMToken, 15, accuracy: 0.001)
        XCTAssertEqual(factorySonnext.cacheReadPerMToken, 0.3, accuracy: 0.001)
        XCTAssertEqual(gpt56Sol.inputPerMToken, 5, accuracy: 0.001)
        XCTAssertEqual(gpt56Sol.outputPerMToken, 30, accuracy: 0.001)
        XCTAssertEqual(gpt56Sol.cacheCreationPerMToken ?? 0, 6.25, accuracy: 0.001)
        XCTAssertEqual(gpt56Sol.cacheReadPerMToken, 0.5, accuracy: 0.001)
        XCTAssertEqual(gpt56Terra.inputPerMToken, 2.5, accuracy: 0.001)
        XCTAssertEqual(gpt56Terra.outputPerMToken, 15, accuracy: 0.001)
        XCTAssertEqual(gpt56Terra.cacheCreationPerMToken ?? 0, 3.125, accuracy: 0.001)
        XCTAssertEqual(gpt56Terra.cacheReadPerMToken, 0.25, accuracy: 0.001)
        // Repriced to OpenAI's post-July-2026 rates (the launch prices were
        // 1/6/1.25/0.1). Luna is the AI Inbox's verifier model, so an out-of-date
        // pin here would misreport that feature's spend.
        XCTAssertEqual(gpt56Luna.inputPerMToken, 0.2, accuracy: 0.001)
        XCTAssertEqual(gpt56Luna.outputPerMToken, 1.2, accuracy: 0.001)
        XCTAssertEqual(gpt56Luna.cacheCreationPerMToken ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(gpt56Luna.cacheReadPerMToken, 0.02, accuracy: 0.001)
        XCTAssertEqual(gpt55.inputPerMToken, 5, accuracy: 0.001)
        XCTAssertEqual(gpt55.outputPerMToken, 30, accuracy: 0.001)
        XCTAssertEqual(gpt55.cacheReadPerMToken, 0.5, accuracy: 0.001)
        XCTAssertEqual(gpt55Pro.inputPerMToken, 30, accuracy: 0.001)
        XCTAssertEqual(gpt55Pro.outputPerMToken, 180, accuracy: 0.001)
        XCTAssertEqual(gpt55Pro.cacheReadPerMToken, 30, accuracy: 0.001)
        XCTAssertEqual(factoryGLM5.inputPerMToken, 0, accuracy: 0.001)
        XCTAssertEqual(factoryGLM5.outputPerMToken, 0, accuracy: 0.001)
        XCTAssertEqual(factoryGLM5.cacheReadPerMToken, 0, accuracy: 0.001)
        XCTAssertEqual(directGLM5.inputPerMToken, 0.07, accuracy: 0.001)
        XCTAssertEqual(directGLM5.outputPerMToken, 0.07, accuracy: 0.001)
        XCTAssertEqual(directGLM5.cacheReadPerMToken, 0.02, accuracy: 0.001)
        XCTAssertEqual(minimax.inputPerMToken, 0.69, accuracy: 0.001)
        XCTAssertEqual(codex.outputPerMToken, 12, accuracy: 0.001)
    }

    func test_catalogSupportsConnectorModelsAndRejectsUnknownOnes() {
        let catalog = BurnBarCatalogLoader.bundledCatalog

        XCTAssertTrue(catalog.supportsModel(named: "glm-5-plus", providerID: "zai"))
        XCTAssertTrue(catalog.supportsModel(named: "MiniMax-M3-pro", providerID: "minimax"))
        XCTAssertFalse(catalog.supportsModel(named: "pony-alpha-2", providerID: "zai"))
    }

    func test_capabilityClassID_prefersExplicitClassID() {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://alpha.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "alpha-pro",
                            displayName: "Alpha Pro",
                            visibility: .public,
                            aliases: ["alpha-pro-latest"],
                            pricing: BurnBarModelPricing(inputPerMToken: 10, outputPerMToken: 20, cacheReadPerMToken: 1),
                            capabilityClassID: "openai:alpha:pro"
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            catalog.capabilityClassID(forModelName: "alpha-pro-latest", providerID: "alpha"),
            "openai:alpha:pro"
        )
    }

    func test_capabilityClassID_fallsBackToModelIDWhenClassMissing() {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://alpha.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "alpha-base",
                            displayName: "Alpha Base",
                            visibility: .public,
                            aliases: ["alpha-base-latest"],
                            pricing: BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 2, cacheReadPerMToken: 0.1)
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            catalog.capabilityClassID(forModelName: "alpha-base-latest", providerID: "alpha"),
            "alpha-base"
        )
    }

    func test_canonicalModelID_usesDirectIDsAndExactFamilyAliasesOnly() {
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "openai",
                    displayName: "OpenAI",
                    baseURL: "https://api.openai.com/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "gpt-5.4",
                            displayName: "GPT-5.4",
                            visibility: .public,
                            matchers: [
                                BurnBarModelMatcher(all: ["gpt-5.4"], none: ["mini", "pro"])
                            ],
                            pricing: .defaultFallback,
                            capabilityClassID: "openai:standard"
                        ),
                        BurnBarCatalogModel(
                            id: "gpt-5.4-mini",
                            displayName: "GPT-5.4 Mini",
                            visibility: .public,
                            aliases: ["gpt-5.4-small"],
                            pricing: .defaultFallback,
                            capabilityClassID: "openai:standard"
                        )
                    ]
                ),
                BurnBarCatalogProvider(
                    id: "factory",
                    displayName: "Factory",
                    baseURL: "https://factory.ai",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [
                        BurnBarCatalogModel(
                            id: "factory-gpt-5.4-family",
                            displayName: "GPT-5.4 via Factory",
                            visibility: .public,
                            aliases: ["gpt-5.4"],
                            pricing: .defaultFallback,
                            capabilityClassID: "openai:standard"
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(catalog.canonicalModelID(forModelName: "gpt-5.4"), "gpt-5.4")
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "gpt-5.4-small", providerID: "openai"), "gpt-5.4-mini")
        XCTAssertNil(
            catalog.canonicalModelID(forModelName: "gpt-5.4-pro", providerID: "openai"),
            "Matcher-only similarity must not prove exact model identity."
        )
    }

    func test_bundledCatalog_hasCapabilityClassesForAnthropicModels() {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-opus-4-7", providerID: "anthropic"), "anthropic:opus")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-opus-4-8", providerID: "anthropic"), "anthropic:opus")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-opus-4-8[1m]", providerID: "anthropic"), "anthropic:opus")
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "claude-opus-4-8[1m]", providerID: "anthropic"), "claude-opus-4-8")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-sonnet-4-6", providerID: "anthropic"), "anthropic:sonnet")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "claude-haiku-4-5", providerID: "anthropic"), "anthropic:haiku")
    }

    func test_bundledCatalog_hasCapabilityClassesForOpenAIModels() {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.4-pro", providerID: "openai"), "openai:pro")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.4", providerID: "openai"), "openai:standard")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.4-mini", providerID: "openai"), "openai:mini")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "o3-pro", providerID: "openai"), "openai:pro")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "o1-pro", providerID: "openai"), "openai:pro")
    }

    func test_bundledCatalog_exposesCurrentGPTModelsThroughCodexProvider() {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertEqual(
            Array(catalog.suggestedModels(forProviderID: "codex").prefix(3)).map(\.id),
            ["codex-gpt-5.6-sol-family", "codex-gpt-5.6-terra-family", "codex-gpt-5.6-luna-family"]
        )
        XCTAssertTrue(catalog.supportsModel(named: "gpt-5.6", providerID: "codex"))
        XCTAssertTrue(catalog.supportsModel(named: "gpt-5.6-sol", providerID: "codex"))
        XCTAssertTrue(catalog.supportsModel(named: "gpt-5.6-terra", providerID: "codex"))
        XCTAssertTrue(catalog.supportsModel(named: "gpt-5.6-luna", providerID: "codex"))
        XCTAssertTrue(catalog.supportsModel(named: "gpt-5.5", providerID: "codex"))
        XCTAssertTrue(catalog.supportsModel(named: "gpt-5.5-codex", providerID: "codex"))
        XCTAssertTrue(catalog.supportsModel(named: "gpt-5.4", providerID: "codex"))
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "gpt-5.6", providerID: "codex"), "gpt-5.6-sol")
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "gpt-5.6-terra", providerID: "codex"), "gpt-5.6-terra")
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "gpt-5.6-luna", providerID: "codex"), "gpt-5.6-luna")
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "gpt-5.5", providerID: "codex"), "gpt-5.5")
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "gpt-5.4", providerID: "codex"), "gpt-5.4")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.6-sol", providerID: "codex"), "openai:codex")
        XCTAssertEqual(catalog.capabilityClassID(forModelName: "gpt-5.5", providerID: "codex"), "openai:codex")
    }

    func test_bundledCatalog_exposesOllamaCloudKimiAndGLMModels() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog

        XCTAssertTrue(catalog.supportsModel(named: "kimi-k2.7-code:cloud", providerID: "ollama"))
        XCTAssertTrue(catalog.supportsModel(named: "glm-5.2:cloud", providerID: "ollama"))
        XCTAssertEqual(
            catalog.canonicalModelID(forModelName: "kimi-k2.7-code:cloud", providerID: "ollama"),
            "kimi-k2.7-code:cloud"
        )
        XCTAssertEqual(
            catalog.canonicalModelID(forModelName: "glm-5.2:cloud", providerID: "ollama"),
            "glm-5.2:cloud"
        )

        let ollama = try XCTUnwrap(catalog.provider(id: "ollama"))
        let kimi = try XCTUnwrap(ollama.models.first { $0.id == "kimi-k2.7-code" })
        let glm = try XCTUnwrap(ollama.models.first { $0.id == "glm-5.2" })
        XCTAssertEqual(kimi.modelCapabilities?.contextWindowTokens, 262_144)
        XCTAssertEqual(kimi.modelCapabilities?.supportsImageInput, true)
        XCTAssertEqual(glm.modelCapabilities?.contextWindowTokens, 976_000)
        XCTAssertEqual(glm.modelCapabilities?.supportsImageInput, false)
    }

    func test_bundledCatalog_usesCanonicalProviderLogoAssets() throws {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        let expectedLogoNames: [String: String] = [
            "amazon": "AmazonProviderLogo",
            "meta": "MetaProviderLogo",
            "deepseek": "DeepSeekProviderLogo",
            "moonshot": "KimiProviderLogo",
            "cohere": "CohereProviderLogo",
            "mistral": "MistralProviderLogo",
            "alibaba": "AlibabaProviderLogo",
            "zai": "ZaiProviderLogo",
            "mlx": "MLXLogo"
        ]

        for (providerID, logoName) in expectedLogoNames {
            let provider = try XCTUnwrap(catalog.provider(id: providerID), providerID)
            XCTAssertEqual(provider.bundledLogoName, logoName, providerID)
        }

        XCTAssertEqual(BurnBarCatalogProvider.bundledLogoName(forProviderID: "deep-seek"), "DeepSeekProviderLogo")
        XCTAssertEqual(BurnBarCatalogProvider.bundledLogoName(forProviderID: "Kimi"), "KimiProviderLogo")
        XCTAssertEqual(BurnBarCatalogProvider.bundledLogoName(forProviderID: "bedrock"), "AmazonProviderLogo")
    }

    func test_bundledCatalog_resolvesGrokBuildCanonicalID() {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "grok-build-0.1"), "grok-build-0.1")
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "grok-build"), "grok-build-0.1")
    }

    func test_bundledCatalog_grokCodeFastAliasResolvesToCanonicalModel() {
        let catalog = BurnBarCatalogLoader.bundledCatalog
        XCTAssertEqual(catalog.canonicalModelID(forModelName: "grok-code-fast-1"), "grok-code-fast-1")
    }
}

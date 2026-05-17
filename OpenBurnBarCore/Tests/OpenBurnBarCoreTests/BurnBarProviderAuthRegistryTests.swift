import XCTest
@testable import OpenBurnBarCore

final class BurnBarProviderAuthRegistryTests: XCTestCase {

    func test_descriptor_lookupResolvesKnownProviders() {
        XCTAssertEqual(BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "zai")?.providerID, "zai")
        XCTAssertEqual(BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "minimax")?.providerID, "minimax")
        XCTAssertEqual(BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "Z-AI")?.providerID, "zai")
    }

    func test_descriptor_kimiAndMoonshotShareSameDescriptor() {
        let viaCatalog = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "moonshot")
        let viaAlias = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "kimi")

        XCTAssertNotNil(viaCatalog)
        XCTAssertNotNil(viaAlias)
        XCTAssertEqual(viaCatalog?.providerID, "moonshot")
        XCTAssertEqual(viaAlias?.providerID, "moonshot")
        XCTAssertEqual(viaAlias?.displayName, "Kimi (Moonshot)")
    }

    func test_descriptorOrFallback_returnsRegisteredDescriptorWhenAvailable() {
        let descriptor = BurnBarProviderAuthRegistry.descriptorOrFallback(
            forCatalogProviderID: "zai",
            displayName: "ignored",
            supportsProxyRouting: false
        )
        XCTAssertEqual(descriptor.providerID, "zai")
        XCTAssertTrue(descriptor.supportsProxyRouting)
    }

    func test_descriptorOrFallback_emitsDefaultForUnknownProvider() {
        let descriptor = BurnBarProviderAuthRegistry.descriptorOrFallback(
            forCatalogProviderID: "fictional-co",
            displayName: "Fictional Co",
            supportsProxyRouting: true
        )
        XCTAssertEqual(descriptor.providerID, "fictional-co")
        XCTAssertEqual(descriptor.displayName, "Fictional Co")
        XCTAssertEqual(descriptor.methods.count, 1)
        XCTAssertTrue(descriptor.methods[0].unlocksProxyRouting)
        XCTAssertFalse(descriptor.methods[0].unlocksQuotaRefresh)
    }

    func test_minimax_codingPlanIsPrimaryAndUnlocksQuotaWhereOpenPlatformDoesNot() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "minimax")
        XCTAssertEqual(descriptor?.primaryMethod.id, "minimax-coding-plan")
        XCTAssertTrue(descriptor?.primaryMethod.unlocksQuotaRefresh ?? false)
        XCTAssertTrue(descriptor?.primaryMethod.unlocksProxyRouting ?? false)

        let openPlatform = descriptor?.method(id: "minimax-open-platform")
        XCTAssertTrue(openPlatform?.unlocksProxyRouting ?? false)
        XCTAssertFalse(openPlatform?.unlocksQuotaRefresh ?? true)
    }

    func test_openAI_exposesAPIKeyAdminKeyAndCodexOAuthMethods() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "openai")
        XCTAssertEqual(descriptor?.primaryMethod.id, "openai-api-key")

        let apiKey = descriptor?.method(id: "openai-api-key")
        XCTAssertEqual(apiKey?.kind, .apiKey)
        XCTAssertTrue(apiKey?.unlocksProxyRouting ?? false)

        let adminKey = descriptor?.method(id: "openai-admin-key")
        XCTAssertEqual(adminKey?.kind, .apiKey)
        XCTAssertFalse(adminKey?.unlocksProxyRouting ?? true)
        XCTAssertTrue(adminKey?.unlocksQuotaRefresh ?? false)

        let oauth = descriptor?.method(id: "openai-codex-oauth")
        XCTAssertEqual(oauth?.kind, .browserLogin)
        XCTAssertFalse(oauth?.unlocksProxyRouting ?? true)
        XCTAssertTrue(oauth?.unlocksQuotaRefresh ?? false)
        XCTAssertFalse(oauth?.storage.usesDaemonSlot ?? true)
    }

    func test_anthropic_exposesAPIKeyOAuthBearerAndClaudeCodeLoginMethods() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "claude")
        XCTAssertEqual(descriptor?.providerID, "anthropic")

        let apiKey = descriptor?.method(id: "anthropic-api-key")
        XCTAssertEqual(apiKey?.kind, .apiKey)
        XCTAssertTrue(apiKey?.unlocksProxyRouting ?? false)

        let oauthBearer = descriptor?.method(id: "anthropic-claude-oauth")
        XCTAssertEqual(oauthBearer?.kind, .bearerToken)
        XCTAssertTrue(oauthBearer?.unlocksProxyRouting ?? false)
        XCTAssertTrue(oauthBearer?.unlocksQuotaRefresh ?? false)

        let login = descriptor?.method(id: "anthropic-claude-code-login")
        XCTAssertEqual(login?.kind, .browserLogin)
        XCTAssertFalse(login?.unlocksProxyRouting ?? true)
        XCTAssertTrue(login?.unlocksQuotaRefresh ?? false)
        XCTAssertFalse(login?.storage.usesDaemonSlot ?? true)
    }

    func test_kimiSessionMethodMirrorsToKimiAuthTokenKeychainAccount() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "moonshot")
        let session = descriptor?.method(id: "kimi-session-token")
        XCTAssertEqual(session?.kind, .sessionToken)
        XCTAssertTrue(session?.unlocksQuotaRefresh ?? false)
        XCTAssertFalse(session?.unlocksProxyRouting ?? true)
        XCTAssertEqual(session?.storage.mirrorAccountIdentifier, "kimi_auth_token")
    }

    func test_ollamaCloudAPIKeyIsRoutingCredentialNotBrowserLoginSession() {
        let descriptor = BurnBarProviderAuthRegistry.descriptor(forCatalogProviderID: "ollama")
        let method = descriptor?.method(id: "ollama-cloud-key")

        XCTAssertEqual(descriptor?.displayName, "Ollama Cloud")
        XCTAssertEqual(method?.kind, .apiKey)
        XCTAssertTrue(method?.storage.usesDaemonSlot ?? false)
        XCTAssertTrue(method?.unlocksProxyRouting ?? false)
        XCTAssertTrue(method?.unlocksQuotaRefresh ?? false)
        XCTAssertTrue(descriptor?.proxyHint?.localizedCaseInsensitiveContains("API key") ?? false)
        XCTAssertTrue(method?.validate("gmail").isWarning ?? false)
        XCTAssertTrue(method?.validate("ollama-realistic-api-key-123456").isOK ?? false)
        XCTAssertTrue(method?.validate("sk-ollama-test-key-123456").isOK ?? false)
        XCTAssertNil(method?.prefixHint)
    }

    func test_apiKeyValidation_warnsOnMissingPrefix() {
        let method = BurnBarProviderAuthMethod(
            id: "test",
            kind: .apiKey,
            displayName: "Test",
            summary: "",
            helperText: "",
            placeholder: "",
            prefixHint: "sk-cp-"
        )
        XCTAssertEqual(method.validate(""), .empty)
        XCTAssertTrue(method.validate("not-a-coding-plan-key-1234567890").isWarning)
        XCTAssertTrue(method.validate("sk-cp-abcdefghi1234567890").isOK)
    }

    func test_sessionTokenValidation_requiresJwtLikeShape() {
        let method = BurnBarProviderAuthMethod(
            id: "session",
            kind: .sessionToken,
            displayName: "Session",
            summary: "",
            helperText: "",
            placeholder: ""
        )
        XCTAssertTrue(method.validate("short").isWarning)
        XCTAssertTrue(method.validate(String(repeating: "a", count: 50)).isWarning)
        let jwtLike = String(repeating: "a", count: 30) + "." + String(repeating: "b", count: 30)
        XCTAssertTrue(method.validate(jwtLike).isOK)
    }

    func test_agentProvider_fromCatalogProviderID_mapsKimiAlias() {
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("moonshot"), .kimi)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("Kimi"), .kimi)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("zai"), .zai)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("minimax"), .minimax)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("openai"), .openAI)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("anthropic"), .claudeCode)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("google"), .geminiCLI)
    }

    func test_storageScope_appKeychainHasAccountIdentifier() {
        let scope = BurnBarProviderSecretStorageScope.appKeychain(account: "factory_cookie_header")
        XCTAssertEqual(scope.mirrorAccountIdentifier, "factory_cookie_header")
        XCTAssertFalse(scope.usesDaemonSlot)
    }

    func test_storageScope_daemonSlotMirroredHasIdentifierAndUsesSlot() {
        let scope = BurnBarProviderSecretStorageScope.daemonSlotMirroredToKeychain(account: "kimi_auth_token")
        XCTAssertEqual(scope.mirrorAccountIdentifier, "kimi_auth_token")
        XCTAssertTrue(scope.usesDaemonSlot)
    }

    func test_eachRegisteredDescriptorHasUniqueProviderID() {
        let providerIDs = BurnBarProviderAuthRegistry.descriptors.map(\.providerID)
        XCTAssertEqual(Set(providerIDs).count, providerIDs.count)
    }

    func test_eachRegisteredDescriptorHasAtLeastOneMethod() {
        for descriptor in BurnBarProviderAuthRegistry.descriptors {
            XCTAssertFalse(descriptor.methods.isEmpty, "\(descriptor.providerID) has no methods")
        }
    }
}

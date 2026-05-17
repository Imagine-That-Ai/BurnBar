import XCTest
@testable import OpenBurnBar

/// End-to-end coverage for `RoutingClientWiring` — the service that drops
/// the OpenBurnBar gateway entry into Claude Code (`~/.claude/settings.json`)
/// Codex (`~/.codex/config.toml`), and Forge (`~/forge/.forge.toml`) and
/// offers a shell-snippet alternative.
///
/// Every test runs against an isolated temporary "home" directory so we never
/// touch the user's real config files. Round-trip behaviour (wire → unwire)
/// is locked down because that's the operation users actually run when
/// switching their CLI between accounts.
final class RoutingClientWiringTests: XCTestCase {

    private var tempHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
        tempHome = nil
        try super.tearDownWithError()
    }

    // MARK: - Gateway validation

    func test_wire_allowsLoopbackGatewayWithoutAuthToken() throws {
        let wiring = makeWiring()
        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        XCTAssertNoThrow(try wiring.wire(target: .claudeCode, gateway: gateway))

        let root = try loadJSONObject(at: tempHome.appendingPathComponent(".claude/settings.json"))
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "openburnbar-local")
    }

    func test_wire_rejectsNonLoopbackGatewayWithoutAuthToken() {
        let wiring = makeWiring()
        let gateway = RoutingClientGateway(host: "192.168.0.10", port: 8317, authToken: "")
        XCTAssertThrowsError(try wiring.wire(target: .claudeCode, gateway: gateway)) { error in
            guard case RoutingClientWiringError.gatewayMisconfigured = error else {
                return XCTFail("expected .gatewayMisconfigured, got \(error)")
            }
        }
    }

    func test_wire_rejectsOutOfRangePort() {
        let wiring = makeWiring()
        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 70_000, authToken: "tok")
        XCTAssertThrowsError(try wiring.wire(target: .claudeCode, gateway: gateway))
    }

    // MARK: - Claude Code (settings.json)

    func test_wireClaudeCode_writesEnvBlock_andMarker() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "test-token-CLAUDE")
        let change = try wiring.wire(target: .claudeCode, gateway: gateway)

        XCTAssertEqual(change.target, .claudeCode)
        XCTAssertEqual(change.configURL, tempHome.appendingPathComponent(".claude/settings.json"))
        XCTAssertNil(change.backupURL, "no previous file → no backup expected")

        let root = try loadJSONObject(at: change.configURL)
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:8317")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "test-token-CLAUDE")
        XCTAssertEqual(env["OPENBURNBAR_WIRED"] as? String, "1")
    }

    func test_wireClaudeCode_preservesExistingKeys_andBacksUp() throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "theme": "dark",
            "env": ["EXISTING_VAR": "leave_me_alone"]
        ]
        try writeJSONObject(existing, to: url)

        let wiring = makeWiring()
        let change = try wiring.wire(target: .claudeCode, gateway: exampleGateway(token: "tok"))

        XCTAssertNotNil(change.backupURL, "existing file should produce a backup")
        let backupURL = try XCTUnwrap(change.backupURL)
        let backup = try loadJSONObject(at: backupURL)
        XCTAssertEqual(backup["theme"] as? String, "dark")

        let root = try loadJSONObject(at: url)
        XCTAssertEqual(root["theme"] as? String, "dark")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["EXISTING_VAR"] as? String, "leave_me_alone")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:8317")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "tok")
    }

    func test_wireClaudeCode_tolerates_jsonWithComments() throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let withComments = """
        // top-level comment
        {
            /* block comment */
            "theme": "dark"  // trailing comment
        }
        """
        try withComments.write(to: url, atomically: true, encoding: .utf8)

        let wiring = makeWiring()
        XCTAssertNoThrow(try wiring.wire(target: .claudeCode, gateway: exampleGateway(token: "tok")))
        let root = try loadJSONObject(at: url)
        XCTAssertEqual(root["theme"] as? String, "dark")
    }

    func test_isWired_claudeCode_detectsMarker() throws {
        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
        _ = try wiring.wire(target: .claudeCode, gateway: exampleGateway(token: "tok"))
        XCTAssertTrue(wiring.isWired(target: .claudeCode))
    }

    func test_unwireClaudeCode_removesEnvKeys_butKeepsUserSettings() throws {
        let url = tempHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original: [String: Any] = [
            "theme": "dark",
            "env": ["EXISTING_VAR": "leave_me_alone"]
        ]
        try writeJSONObject(original, to: url)

        let wiring = makeWiring()
        _ = try wiring.wire(target: .claudeCode, gateway: exampleGateway(token: "tok"))
        try wiring.unwire(target: .claudeCode)

        let root = try loadJSONObject(at: url)
        XCTAssertEqual(root["theme"] as? String, "dark")
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["EXISTING_VAR"] as? String, "leave_me_alone")
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["OPENBURNBAR_WIRED"])
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
    }

    func test_unwireClaudeCode_dropsEnvBlock_whenItBecomesEmpty() throws {
        let wiring = makeWiring()
        _ = try wiring.wire(target: .claudeCode, gateway: exampleGateway(token: "tok"))
        try wiring.unwire(target: .claudeCode)

        let url = tempHome.appendingPathComponent(".claude/settings.json")
        let root = try loadJSONObject(at: url)
        XCTAssertNil(root["env"], "empty env block should be removed entirely")
    }

    // MARK: - Codex (config.toml)

    func test_wireCodex_writesSentinelFencedProviderBlock() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "codex-token")
        let change = try wiring.wire(target: .codex, gateway: gateway)

        XCTAssertEqual(change.target, .codex)
        let configURL = tempHome.appendingPathComponent(".codex/config.toml")
        XCTAssertEqual(change.configURL, configURL)

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# openburnbar:routing — start"))
        XCTAssertTrue(text.contains("# openburnbar:routing — end"))
        XCTAssertTrue(text.contains("[model_providers.openburnbar]"))
        XCTAssertTrue(text.contains("[profiles.openburnbar]"))
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8317/v1\""))
        XCTAssertTrue(text.contains("env_key = \"OPENBURNBAR_GATEWAY_TOKEN\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertFalse(text.contains("wire_api = \"chat\""))
        XCTAssertTrue(text.contains("model_provider = \"openburnbar\""))
    }

    func test_wireCodex_setsProfileModelFromLiveCatalogWhenAvailable() throws {
        let wiring = makeWiring()
        let change = try wiring.wire(
            target: .codex,
            gateway: exampleGateway(token: "codex-token"),
            advertisedModels: liveGatewayModels()
        )

        let text = try String(contentsOf: change.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("model = \"glm-5\""))
    }

    func test_wireCodex_preservesPriorUserTOML() throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let priorTOML = """
        [profiles.work]
        model = "gpt-5.4"
        """
        try priorTOML.write(to: url, atomically: true, encoding: .utf8)

        let wiring = makeWiring()
        _ = try wiring.wire(target: .codex, gateway: exampleGateway(token: "tok"))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[profiles.work]"))
        XCTAssertTrue(text.contains("model = \"gpt-5.4\""))
        XCTAssertTrue(text.contains("[model_providers.openburnbar]"))
    }

    func test_isWired_codex_detectsSentinel() throws {
        let wiring = makeWiring()
        XCTAssertFalse(wiring.isWired(target: .codex))
        _ = try wiring.wire(target: .codex, gateway: exampleGateway(token: "tok"))
        XCTAssertTrue(wiring.isWired(target: .codex))
    }

    func test_isWired_codex_detectsExistingLocalGatewayProviderWithoutSentinel() throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [model_providers.factory-vibeproxy]
        base_url = "http://localhost:8317/v1"
        name = "Factory VibeProxy"
        wire_api = "responses"
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(makeWiring().isWired(target: .codex))
    }

    func test_unwireCodex_stripsBlock_keepsUserContent() throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let priorTOML = """
        [profiles.work]
        model = "gpt-5.4"
        """
        try priorTOML.write(to: url, atomically: true, encoding: .utf8)

        let wiring = makeWiring()
        _ = try wiring.wire(target: .codex, gateway: exampleGateway(token: "tok"))
        try wiring.unwire(target: .codex)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("openburnbar:routing"))
        XCTAssertFalse(text.contains("[model_providers.openburnbar]"))
        XCTAssertTrue(text.contains("[profiles.work]"))
    }

    func test_unwireCodex_deletesFile_whenEverythingOpenBurnBarOwned() throws {
        let wiring = makeWiring()
        _ = try wiring.wire(target: .codex, gateway: exampleGateway(token: "tok"))
        try wiring.unwire(target: .codex)

        let url = tempHome.appendingPathComponent(".codex/config.toml")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "config.toml should be removed when no user content remains"
        )
    }

    // MARK: - Forge (~/forge/.forge.toml)

    func test_wireForge_writesVibeProxyStyleProviderBlock() throws {
        let wiring = makeWiring()
        let change = try wiring.wire(target: .forge, gateway: exampleGateway(token: "forge-token"))

        XCTAssertEqual(change.target, .forge)
        let configURL = tempHome.appendingPathComponent("forge/.forge.toml")
        XCTAssertEqual(change.configURL, configURL)

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# openburnbar:routing — start"))
        XCTAssertTrue(text.contains("[[providers]]"))
        XCTAssertTrue(text.contains("id = \"openburnbar\""))
        XCTAssertTrue(text.contains("api_key_var = \"OPENBURNBAR_GATEWAY_TOKEN\""))
        XCTAssertTrue(text.contains("url = \"http://127.0.0.1:8317/v1/chat/completions\""))
        XCTAssertTrue(text.contains("models = \"http://127.0.0.1:8317/v1/models\""))
        XCTAssertTrue(text.contains("response_type = \"OpenAI\""))
    }

    func test_wireForge_preservesPriorUserTOML_andUnwireStripsOnlyOpenBurnBarBlock() throws {
        let url = tempHome.appendingPathComponent("forge/.forge.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let priorTOML = """
        [session]
        provider_id = "kimi_coding"

        [[providers]]
        id = "vibeproxy"
        api_key_var = "VIBEPROXY_API_KEY"
        url = "http://127.0.0.1:8317/v1/chat/completions"
        models = "http://127.0.0.1:8317/v1/models"
        response_type = "OpenAI"
        """
        try priorTOML.write(to: url, atomically: true, encoding: .utf8)

        let wiring = makeWiring()
        _ = try wiring.wire(target: .forge, gateway: exampleGateway(token: "tok"))
        XCTAssertTrue(wiring.isWired(target: .forge))

        try wiring.unwire(target: .forge)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("openburnbar:routing"))
        XCTAssertFalse(text.contains("id = \"openburnbar\""))
        XCTAssertTrue(text.contains("provider_id = \"kimi_coding\""))
        XCTAssertTrue(text.contains("id = \"vibeproxy\""))
    }

    func test_isWired_forge_detectsExistingLocalGatewayProviderWithoutSentinel() throws {
        let url = tempHome.appendingPathComponent("forge/.forge.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [[providers]]
        id = "vibeproxy"
        url = "http://127.0.0.1:8317/v1/chat/completions"
        models = "http://127.0.0.1:8317/v1/models"
        response_type = "OpenAI"
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(makeWiring().isWired(target: .forge))
    }

    // MARK: - Droid (~/.factory/*.json)

    func test_wireDroid_writesCustomModelsIntoKnownFactoryConfigs() throws {
        let wiring = makeWiring()
        let change = try wiring.wire(
            target: .droid,
            gateway: exampleGateway(token: "droid-token"),
            advertisedModels: liveGatewayModels()
        )

        XCTAssertEqual(change.target, .droid)
        let configURL = tempHome.appendingPathComponent(".factory/settings.local.json")
        XCTAssertEqual(change.configURL, configURL)

        let root = try loadJSONObject(at: configURL)
        let customModels = try XCTUnwrap(root["customModels"] as? [[String: Any]])
        XCTAssertEqual(customModels.count, 2)
        XCTAssertEqual(customModels.first?["model"] as? String, "glm-5")
        XCTAssertEqual(customModels.first?["displayName"] as? String, "OpenBurnBar GLM-5")
        XCTAssertEqual(customModels.first?["baseUrl"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(customModels.first?["apiKey"] as? String, "droid-token")
        XCTAssertEqual(customModels.first?["provider"] as? String, "generic-chat-completion-api")
        XCTAssertEqual(customModels.first?["id"] as? String, "custom:OpenBurnBar-glm-5-0")

        let settingsRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.json"))
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.map { $0["model"] as? String }, ["glm-5", "minimax-m2.7"])
        XCTAssertEqual(settingsModels.first?["baseUrl"] as? String, "http://127.0.0.1:8317/v1")

        let factoryConfigRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/config.json"))
        let factoryConfigModels = try XCTUnwrap(factoryConfigRoot["custom_models"] as? [[String: Any]])
        XCTAssertEqual(factoryConfigModels.map { $0["model"] as? String }, ["glm-5", "minimax-m2.7"])
        XCTAssertEqual(factoryConfigModels.first?["base_url"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(factoryConfigModels.first?["api_key"] as? String, "droid-token")
        XCTAssertEqual(factoryConfigModels.first?["provider"] as? String, "generic-chat-completion-api")
        XCTAssertTrue(wiring.isWired(target: .droid))
    }

    func test_wireDroid_requiresLiveRouteEligibleModels() throws {
        let wiring = makeWiring()
        XCTAssertThrowsError(
            try wiring.wire(target: .droid, gateway: exampleGateway(token: "droid-token"))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("No route-eligible OpenAI-compatible models"))
        }
    }

    func test_wireOpenCode_writesLiveCatalogModels() throws {
        let wiring = makeWiring()
        let change = try wiring.wire(
            target: .opencode,
            gateway: exampleGateway(token: "opencode-token"),
            advertisedModels: liveGatewayModels()
        )

        let root = try loadJSONObject(at: change.configURL)
        XCTAssertEqual(root["model"] as? String, "openburnbar/glm-5")
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        let openburnbar = try XCTUnwrap(providers["openburnbar"] as? [String: Any])
        let models = try XCTUnwrap(openburnbar["models"] as? [String: Any])
        XCTAssertNotNil(models["glm-5"])
        XCTAssertNotNil(models["minimax-m2.7"])
        XCTAssertNil(models["claude-sonnet-4-6"])
        XCTAssertTrue(wiring.isWired(target: .opencode))
    }

    func test_isWired_opencode_detectsProviderModelsWithoutDisplayName() throws {
        let url = tempHome.appendingPathComponent(".config/opencode/opencode.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "model": "openburnbar/glm-5",
          "provider": {
            "openburnbar": {
              "npm": "@ai-sdk/openai-compatible",
              "options": {"baseURL": "http://127.0.0.1:8317/v1", "apiKey": "openburnbar-local"},
              "models": {"glm-5": {"name": "GLM-5"}}
            }
          }
        }
        """.utf8).write(to: url)

        XCTAssertTrue(makeWiring().isWired(target: .opencode))
    }

    func test_unwireDroid_removesOnlyOpenBurnBarCustomModels() throws {
        let url = tempHome.appendingPathComponent(".factory/settings.local.json")
        let settingsURL = tempHome.appendingPathComponent(".factory/settings.json")
        let configURL = tempHome.appendingPathComponent(".factory/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "customModels": [
            {"model": "existing-model", "provider": "openai", "baseUrl": "https://example.com/v1"},
            {"model": "old-openburnbar", "id": "openburnbar:old-openburnbar", "provider": "openai"},
            {"model": "claude-opus-4-7", "id": "custom:VibeProxy-Claude-0", "displayName": "VibeProxy Claude", "provider": "anthropic", "baseUrl": "http://localhost:8317"}
          ]
        }
        """.utf8).write(to: url)
        try Data("""
        {
          "customModels": [
            {"model": "existing-settings-model", "provider": "openai", "baseUrl": "https://example.com/v1"},
            {"model": "old-openburnbar", "id": "openburnbar:old-openburnbar", "provider": "openai"},
            {"model": "claude-sonnet-4-6", "displayName": "VibeProxy Sonnet", "provider": "anthropic", "baseUrl": "http://localhost:8317"}
          ]
        }
        """.utf8).write(to: settingsURL)
        try Data("""
        {
          "custom_models": [
            {"model": "existing-config-model", "provider": "openai", "base_url": "https://example.com/v1"},
            {"model": "old-openburnbar", "model_display_name": "OpenBurnBar old", "provider": "openai"},
            {"model": "claude-opus-4-7", "model_display_name": "VibeProxy Claude", "provider": "anthropic", "base_url": "http://localhost:8317"}
          ]
        }
        """.utf8).write(to: configURL)

        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .droid,
            gateway: exampleGateway(token: "tok"),
            advertisedModels: liveGatewayModels()
        )
        try wiring.unwire(target: .droid)

        let root = try loadJSONObject(at: url)
        let customModels = try XCTUnwrap(root["customModels"] as? [[String: Any]])
        XCTAssertEqual(customModels.count, 1)
        XCTAssertEqual(customModels.first?["model"] as? String, "existing-model")

        let settingsRoot = try loadJSONObject(at: settingsURL)
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.count, 1)
        XCTAssertEqual(settingsModels.first?["model"] as? String, "existing-settings-model")

        let configRoot = try loadJSONObject(at: configURL)
        let configModels = try XCTUnwrap(configRoot["custom_models"] as? [[String: Any]])
        XCTAssertEqual(configModels.count, 1)
        XCTAssertEqual(configModels.first?["model"] as? String, "existing-config-model")
        XCTAssertFalse(wiring.isWired(target: .droid))
    }

    // MARK: - Shell snippet escaping

    func test_shellSnippet_claudeCode_singleQuotesTokens() {
        let wiring = makeWiring()
        let snippet = wiring.shellSnippet(
            target: .claudeCode,
            gateway: exampleGateway(token: "abc$weird")
        )
        XCTAssertTrue(snippet.contains("export ANTHROPIC_BASE_URL='http://127.0.0.1:8317'"))
        // `$weird` inside single quotes does NOT expand — that's the whole
        // reason we switched away from double quotes.
        XCTAssertTrue(snippet.contains("export ANTHROPIC_AUTH_TOKEN='abc$weird'"))
    }

    func test_shellSnippet_codex_includesOpenBurnBarGatewayToken() {
        let wiring = makeWiring()
        let snippet = wiring.shellSnippet(
            target: .codex,
            gateway: exampleGateway(token: "abc123")
        )
        XCTAssertTrue(snippet.contains("export OPENAI_BASE_URL='http://127.0.0.1:8317/v1'"))
        XCTAssertTrue(snippet.contains("export OPENAI_API_KEY='abc123'"))
        XCTAssertTrue(snippet.contains("export OPENBURNBAR_GATEWAY_TOKEN='abc123'"))
    }

    func test_shellSnippet_forge_includesProviderEnvVar() {
        let wiring = makeWiring()
        let snippet = wiring.shellSnippet(
            target: .forge,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        )
        XCTAssertTrue(snippet.contains("export OPENBURNBAR_GATEWAY_TOKEN='openburnbar-local'"))
        XCTAssertTrue(snippet.contains("export OPENAI_BASE_URL='http://127.0.0.1:8317/v1'"))
    }

    func test_shellSnippet_droid_includesProviderEnvVar() {
        let wiring = makeWiring()
        let snippet = wiring.shellSnippet(
            target: .droid,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
        )
        XCTAssertTrue(snippet.contains("export OPENBURNBAR_GATEWAY_TOKEN='openburnbar-local'"))
        XCTAssertTrue(snippet.contains("export OPENAI_BASE_URL='http://127.0.0.1:8317/v1'"))
    }

    func test_shellQuote_escapesEmbeddedSingleQuote() {
        XCTAssertEqual(RoutingClientWiring.shellQuote("a'b"), #"'a'\''b'"#)
    }

    func test_shellQuote_emptyStringIsTwoQuotes() {
        XCTAssertEqual(RoutingClientWiring.shellQuote(""), "''")
    }

    // MARK: - configURL accessor

    func test_configURL_pointsAtConventionalLocations() {
        let wiring = makeWiring()
        XCTAssertEqual(
            wiring.configURL(for: .claudeCode),
            tempHome.appendingPathComponent(".claude/settings.json")
        )
        XCTAssertEqual(
            wiring.configURL(for: .codex),
            tempHome.appendingPathComponent(".codex/config.toml")
        )
        XCTAssertEqual(
            wiring.configURL(for: .forge),
            tempHome.appendingPathComponent("forge/.forge.toml")
        )
        XCTAssertEqual(
            wiring.configURL(for: .droid),
            tempHome.appendingPathComponent(".factory/settings.local.json")
        )
    }

    // MARK: - helpers

    private func makeWiring() -> RoutingClientWiring {
        RoutingClientWiring(
            fileManager: .default,
            home: tempHome,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func exampleGateway(token: String) -> RoutingClientGateway {
        RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: token)
    }

    private func liveGatewayModels() -> [RoutingClientAdvertisedModel] {
        [
            RoutingClientAdvertisedModel(
                id: "glm-5",
                displayName: "GLM-5",
                providerID: "zai",
                providerName: "Z.AI",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "minimax-m2.7",
                displayName: "MiniMax M2.7",
                providerID: "minimax",
                providerName: "MiniMax",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6",
                providerID: "anthropic",
                providerName: "Anthropic",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "gpt-exhausted",
                displayName: "GPT Exhausted",
                providerID: "openai",
                providerName: "OpenAI",
                routeEligible: false
            )
        ]
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: [.atomic])
    }
}

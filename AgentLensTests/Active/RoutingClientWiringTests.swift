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
        RoutingProbeURLProtocol.reset()
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
        let change = try wiring.wire(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        XCTAssertEqual(change.target, .claudeCode)
        XCTAssertEqual(change.configURL, tempHome.appendingPathComponent(".claude/settings.json"))
        XCTAssertNil(change.backupURL, "no previous file → no backup expected")

        let root = try loadJSONObject(at: change.configURL)
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:8317")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "test-token-CLAUDE")
        XCTAssertEqual(env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] as? String, "1")
        XCTAssertEqual(env["ANTHROPIC_CUSTOM_HEADERS"] as? String, "X-OpenBurnBar-Client: claude-code")
        XCTAssertEqual(env["OPENBURNBAR_MODEL_CATALOG_IDS"] as? String, "glm-5,minimax-m2.7,claude-sonnet-4-6")
        XCTAssertNotNil(env["OPENBURNBAR_MODEL_CATALOG_FINGERPRINT"] as? String)
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
            "env": [
                "EXISTING_VAR": "leave_me_alone",
                "ANTHROPIC_CUSTOM_HEADERS": "X-Team-Trace: keep\nX-OpenBurnBar-Client: stale"
            ]
        ]
        try writeJSONObject(existing, to: url)

        let wiring = makeWiring()
        let change = try wiring.wire(
            target: .claudeCode,
            gateway: exampleGateway(token: "tok"),
            advertisedModels: liveGatewayModels()
        )

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
        XCTAssertEqual(
            env["ANTHROPIC_CUSTOM_HEADERS"] as? String,
            "X-Team-Trace: keep\nX-OpenBurnBar-Client: claude-code"
        )
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
        XCTAssertNil(env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"])
        XCTAssertNil(env["OPENBURNBAR_MODEL_CATALOG_IDS"])
        XCTAssertNil(env["OPENBURNBAR_MODEL_CATALOG_FINGERPRINT"])
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
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8317/v1\""))
        XCTAssertTrue(text.contains("env_key = \"OPENBURNBAR_GATEWAY_TOKEN\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertFalse(text.contains("wire_api = \"chat\""))
        XCTAssertFalse(text.contains("[profiles.openburnbar]"))

        let profileURL = tempHome.appendingPathComponent(".codex/openburnbar.config.toml")
        let profileText = try String(contentsOf: profileURL, encoding: .utf8)
        XCTAssertTrue(profileText.contains("model_provider = \"openburnbar\""))
        XCTAssertTrue(profileText.contains("model = \"openburnbar/gateway-default\""))
        XCTAssertTrue(profileText.contains("model_catalog_json = \"\(tempHome.path)/.codex/openburnbar-model-catalog.json\""))

        let catalog = try loadJSONObject(at: tempHome.appendingPathComponent(".codex/openburnbar-model-catalog.json"))
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertTrue(models.contains { $0["slug"] as? String == "gpt-5.5" })
        XCTAssertFalse(models.contains { ($0["slug"] as? String)?.hasPrefix("openburnbar/") == true })
    }

    func test_wireCodex_setsProfileModelFromLiveCatalogWhenAvailable() throws {
        let wiring = makeWiring()
        let change = try wiring.wire(
            target: .codex,
            gateway: exampleGateway(token: "codex-token"),
            advertisedModels: liveGatewayModels()
        )

        let text = try String(
            contentsOf: tempHome.appendingPathComponent(".codex/openburnbar.config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("model = \"openburnbar/glm-5\""))

        let catalog = try loadJSONObject(at: tempHome.appendingPathComponent(".codex/openburnbar-model-catalog.json"))
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertTrue(models.contains { $0["slug"] as? String == "gpt-5.5" })
        XCTAssertTrue(models.contains { $0["slug"] as? String == "openburnbar/glm-5" })
        XCTAssertTrue(models.contains { $0["slug"] as? String == "openburnbar/minimax-m2.7" })
        XCTAssertTrue(models.contains { $0["slug"] as? String == "openburnbar/claude-sonnet-4-6" })
        XCTAssertEqual(change.configURL, tempHome.appendingPathComponent(".codex/config.toml"))
    }

    func test_wireCodexIncludesNativeGPTFallbacksAndResponsesGatewayModels() throws {
        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .codex,
            gateway: exampleGateway(token: "codex-token"),
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "gpt-5.5",
                    displayName: "GPT-5.5 via OpenBurnBar",
                    providerID: "codex",
                    providerName: "Codex",
                    servedEndpoints: ["/v1/responses"],
                    contextWindowTokens: 272_000,
                    inputModalities: ["text", "image"],
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "claude-opus-4-8",
                    displayName: "Claude Opus 4.8",
                    providerID: "anthropic",
                    providerName: "Anthropic",
                    formatFamily: "anthropic",
                    servedEndpoints: ["/v1/messages"],
                    capabilities: ["anthropic"],
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "chat-only-model",
                    displayName: "Chat Only",
                    providerID: "test",
                    providerName: "Test",
                    servedEndpoints: ["/v1/chat/completions"],
                    routeEligible: true
                )
            ]
        )

        let profileText = try String(
            contentsOf: tempHome.appendingPathComponent(".codex/openburnbar.config.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(profileText.contains("model = \"openburnbar/gpt-5.5\""))

        let catalog = try loadJSONObject(at: tempHome.appendingPathComponent(".codex/openburnbar-model-catalog.json"))
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertTrue(models.contains { $0["slug"] as? String == "gpt-5.5" })
        XCTAssertTrue(models.contains { $0["slug"] as? String == "gpt-5.4" })
        XCTAssertTrue(models.contains { $0["slug"] as? String == "openburnbar/gpt-5.5" })
        let proxyModel = try XCTUnwrap(
            models.first { $0["slug"] as? String == "openburnbar/gpt-5.5" }
        )
        XCTAssertEqual(proxyModel["context_window"] as? Int, 272_000)
        XCTAssertEqual(proxyModel["max_context_window"] as? Int, 272_000)
        XCTAssertEqual(
            (proxyModel["truncation_policy"] as? [String: Any])?["limit"] as? Int,
            272_000
        )
        XCTAssertEqual(proxyModel["input_modalities"] as? [String], ["text", "image"])
        XCTAssertFalse(models.contains { $0["slug"] as? String == "openburnbar/claude-opus-4-8" })
        XCTAssertFalse(models.contains { $0["slug"] as? String == "openburnbar/chat-only-model" })
    }

    func test_advertisedModelsPreservesLiveContextWindowMetadata() async throws {
        let wiring = makeWiring()
        let session = makeProbeSession { _ in
            try JSONSerialization.data(withJSONObject: [
                "data": [
                    [
                        "id": "claude-opus-4-8",
                        "display_name": "Claude Opus 4.8",
                        "provider_id": "anthropic",
                        "provider_name": "Anthropic",
                        "served_endpoints": ["/v1/responses"],
                        "model_capabilities": [
                            "contextWindowTokens": 1_000_000,
                            "inputModalities": ["text", "image"]
                        ],
                        "route_eligible": true
                    ]
                ]
            ])
        }

        let models = await wiring.advertisedModels(
            gateway: exampleGateway(token: "catalog-token"),
            session: session
        )

        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.contextWindowTokens, 1_000_000)
        XCTAssertEqual(model.inputModalities, ["text", "image"])
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

    func test_wireCodex_replacesLegacyOpenBurnBarProviderWithoutSentinel() throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [profiles.work]
        model = "gpt-5.4"

        [model_providers.openburnbar]
        name = "OpenBurnBar Hydrant"
        base_url = "http://127.0.0.1:8317/v1"
        env_key = "OPENBURNBAR_GATEWAY_TOKEN"
        wire_api = "chat"
        """.write(to: url, atomically: true, encoding: .utf8)

        _ = try makeWiring().wire(target: .codex, gateway: exampleGateway(token: "tok"))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[profiles.work]"))
        XCTAssertTrue(text.contains("model = \"gpt-5.4\""))
        XCTAssertFalse(text.contains("OpenBurnBar Hydrant"))
        XCTAssertFalse(text.contains("wire_api = \"chat\""))
        XCTAssertEqual(text.components(separatedBy: "[model_providers.openburnbar]").count - 1, 1)
        XCTAssertTrue(text.contains("name = \"OpenBurnBar Gateway\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
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

    func test_migrateFromVibeProxy_codexReplacesVibeProxyBlocksAndKeepsUserProfiles() throws {
        let url = tempHome.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [profiles.work]
        model = "gpt-5.4"

        [model_providers.factory-vibeproxy]
        base_url = "http://localhost:8317/v1"
        wire_api = "responses"

        [profiles.vibeproxy]
        model_provider = "factory-vibeproxy"
        model = "claude-sonnet"
        """.write(to: url, atomically: true, encoding: .utf8)

        _ = try makeWiring().migrateFromVibeProxy(
            target: .codex,
            gateway: exampleGateway(token: "tok"),
            advertisedModels: liveGatewayModels()
        )

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[profiles.work]"))
        XCTAssertTrue(text.contains("model = \"gpt-5.4\""))
        XCTAssertFalse(text.contains("factory-vibeproxy"))
        XCTAssertFalse(text.contains("[profiles.vibeproxy]"))
        XCTAssertTrue(text.contains("[model_providers.openburnbar]"))
        XCTAssertFalse(text.contains("[profiles.openburnbar]"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempHome.appendingPathComponent(".codex/openburnbar.config.toml").path))
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempHome.appendingPathComponent(".codex/openburnbar.config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempHome.appendingPathComponent(".codex/openburnbar-model-catalog.json").path))
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

    func test_migrateFromVibeProxy_forgeReplacesProviderAndSessionPointer() throws {
        let url = tempHome.appendingPathComponent("forge/.forge.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [session]
        provider_id = "vibeproxy"

        [[providers]]
        id = "vibeproxy"
        api_key_var = "VIBEPROXY_API_KEY"
        url = "http://127.0.0.1:8317/v1/chat/completions"
        models = "http://127.0.0.1:8317/v1/models"
        response_type = "OpenAI"
        """.write(to: url, atomically: true, encoding: .utf8)

        _ = try makeWiring().migrateFromVibeProxy(
            target: .forge,
            gateway: exampleGateway(token: "tok")
        )

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#"provider_id = "openburnbar""#))
        XCTAssertFalse(text.contains(#"id = "vibeproxy""#))
        XCTAssertFalse(text.contains("VIBEPROXY_API_KEY"))
        XCTAssertTrue(text.contains(#"id = "openburnbar""#))
        XCTAssertTrue(text.contains("OPENBURNBAR_GATEWAY_TOKEN"))
    }

    // MARK: - Grok Build (~/.grok/config.toml)

    func test_wireGrok_writesCustomModelBlock() throws {
        let wiring = makeWiring()
        let change = try wiring.wire(target: .grok, gateway: exampleGateway(token: "grok-token"))

        XCTAssertEqual(change.target, .grok)
        let configURL = tempHome.appendingPathComponent(".grok/config.toml")
        XCTAssertEqual(change.configURL, configURL)

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# openburnbar:routing — start"))
        XCTAssertTrue(text.contains("[model.openburnbar]"))
        XCTAssertTrue(text.contains("model = \"openburnbar-gateway\""))
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8317/v1\""))
        XCTAssertTrue(text.contains("name = \"OpenBurnBar Gateway\""))
        XCTAssertTrue(text.contains("env_key = \"XAI_API_KEY\""))
    }

    func test_isWired_grok_detectsExistingCustomModelWithoutSentinel() throws {
        let url = tempHome.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [model.openburnbar]
        model = "openburnbar-gateway"
        base_url = "http://127.0.0.1:8317/v1"
        env_key = "XAI_API_KEY"
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(makeWiring().isWired(target: .grok))
    }

    func test_wireGrok_preservesPriorUserTOML_andUnwireStripsOnlyOpenBurnBarBlock() throws {
        let url = tempHome.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let priorTOML = """
        [models]
        default = "grok-3"

        [session]
        cwd = "/tmp"
        """
        try priorTOML.write(to: url, atomically: true, encoding: .utf8)

        let wiring = makeWiring()
        _ = try wiring.wire(target: .grok, gateway: exampleGateway(token: "tok"))
        XCTAssertTrue(wiring.isWired(target: .grok))

        try wiring.unwire(target: .grok)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("openburnbar:routing"))
        XCTAssertFalse(text.contains("[model.openburnbar]"))
        XCTAssertTrue(text.contains("default = \"grok-3\""))
        XCTAssertTrue(text.contains("cwd = \"/tmp\""))
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
        XCTAssertEqual(customModels.count, 3)
        XCTAssertEqual(customModels.first?["model"] as? String, "glm-5")
        XCTAssertEqual(customModels.first?["displayName"] as? String, "OBB GLM-5 Direct")
        XCTAssertEqual(customModels.first?["baseUrl"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(customModels.first?["apiKey"] as? String, "droid-token")
        XCTAssertEqual(customModels.first?["provider"] as? String, "generic-chat-completion-api")
        XCTAssertEqual(customModels.first?["id"] as? String, "custom:OpenBurnBar-glm-5-0")
        XCTAssertEqual(root["model"] as? String, "custom:OpenBurnBar-glm-5-0")

        let settingsRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.json"))
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.map { $0["model"] as? String }, ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"])
        XCTAssertEqual(settingsModels.first?["baseUrl"] as? String, "http://127.0.0.1:8317/v1")

        let factoryConfigRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/config.json"))
        let factoryConfigModels = try XCTUnwrap(factoryConfigRoot["custom_models"] as? [[String: Any]])
        XCTAssertEqual(factoryConfigModels.map { $0["model"] as? String }, ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"])
        XCTAssertEqual(factoryConfigModels.first?["base_url"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(factoryConfigModels.first?["api_key"] as? String, "droid-token")
        XCTAssertEqual(factoryConfigModels.first?["provider"] as? String, "generic-chat-completion-api")
        for path in [
            ".factory/settings.local.json",
            ".factory/settings.json",
            ".factory/config.json"
        ] {
            let text = try String(
                contentsOf: tempHome.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertFalse(text.contains("8333"), path)
            XCTAssertFalse(text.contains("codex_factory_bridge"), path)
            XCTAssertFalse(text.contains("find-generic-password"), path)
            XCTAssertFalse(text.contains("com.openburnbar.controller-runtime"), path)
            XCTAssertFalse(text.contains("secret_broker"), path)
        }
        XCTAssertTrue(wiring.isWired(target: .droid))
    }

    func test_wireDroid_collapsesLegacyAccountScopedGatewayModelsBeforeExport() throws {
        let wiring = makeWiring()
        _ = try wiring.wire(
            target: .droid,
            gateway: exampleGateway(token: "droid-token"),
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "zai/primary/glm-5",
                    displayName: "GLM-5",
                    providerID: "zai",
                    providerName: "Z.ai",
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "zai/backup/glm-5",
                    displayName: "GLM-5",
                    providerID: "zai",
                    providerName: "Z.ai",
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "anthropic/primary/claude-sonnet-4-6",
                    displayName: "Claude Sonnet 4.6",
                    providerID: "anthropic",
                    providerName: "Anthropic",
                    formatFamily: "anthropic",
                    servedEndpoints: ["/v1/messages", "/v1/chat/completions", "/v1/responses"],
                    capabilities: ["anthropic"],
                    routeEligible: true
                )
            ]
        )

        let root = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        let customModels = try XCTUnwrap(root["customModels"] as? [[String: Any]])
        XCTAssertEqual(customModels.map { $0["model"] as? String }, ["glm-5", "claude-sonnet-4-6"])
        XCTAssertFalse(customModels.contains { ($0["model"] as? String)?.contains("/primary/") == true })
        XCTAssertFalse(customModels.contains { ($0["model"] as? String)?.contains("/backup/") == true })
    }

    func test_wireDroid_requiresLiveRouteEligibleModels() throws {
        let wiring = makeWiring()
        XCTAssertThrowsError(
            try wiring.wire(target: .droid, gateway: exampleGateway(token: "droid-token"))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("No route-eligible gateway models"))
        }
    }

    func test_wireDroid_resyncReplacesStaleOpenBurnBarModelsWithLiveCatalog() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "droid-token")

        _ = try wiring.wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        let refreshedModels = [
            RoutingClientAdvertisedModel(
                id: "kimi-k2.6",
                displayName: "Kimi K2.6",
                providerID: "opencode",
                providerName: "OpenCode",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6",
                providerID: "anthropic",
                providerName: "Anthropic",
                routeEligible: true
            )
        ]

        _ = try wiring.wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: refreshedModels
        )

        let settingsLocalRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        let settingsLocalModels = try XCTUnwrap(settingsLocalRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsLocalModels.map { $0["model"] as? String }, ["kimi-k2.6", "claude-sonnet-4-6"])
        XCTAssertFalse(settingsLocalModels.contains { ($0["model"] as? String) == "glm-5" })
        XCTAssertFalse(settingsLocalModels.contains { ($0["model"] as? String) == "minimax-m2.7" })

        let settingsRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.json"))
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.map { $0["model"] as? String }, ["kimi-k2.6", "claude-sonnet-4-6"])

        let configRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/config.json"))
        let configModels = try XCTUnwrap(configRoot["custom_models"] as? [[String: Any]])
        XCTAssertEqual(configModels.map { $0["model"] as? String }, ["kimi-k2.6", "claude-sonnet-4-6"])
    }

    func test_droidModelSyncStatusFlagsStaleCachedOpenBurnBarModels() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "droid-token")
        let settingsURL = tempHome.appendingPathComponent(".factory/settings.local.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "customModels": [
            {"model": "MiniMax-M2.5", "id": "custom:OpenBurnBar-MiniMax-M2.5-0", "displayName": "OpenBurnBar MiniMax M2.5", "provider": "generic-chat-completion-api", "baseUrl": "http://127.0.0.1:8317/v1"}
          ]
        }
        """.utf8).write(to: settingsURL)

        let status = wiring.modelSyncStatus(
            target: .droid,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        guard case .stale(let installedModelIDs, let expectedModelIDs) = status else {
            XCTFail("Expected stale Droid sync status, got \(status)")
            return
        }
        XCTAssertEqual(installedModelIDs, ["MiniMax-M2.5"])
        XCTAssertEqual(expectedModelIDs, ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"])
        XCTAssertTrue(status.userMessage.contains("Press Sync models"))
    }

    func test_droidModelSyncStatusCurrentAfterWire() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "droid-token")
        _ = try wiring.wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        let status = wiring.modelSyncStatus(
            target: .droid,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        XCTAssertEqual(status, .current(modelIDs: ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"]))
    }

    func test_codexModelSyncStatusCurrentAfterWire() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "codex-token")
        _ = try wiring.wire(
            target: .codex,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        let status = wiring.modelSyncStatus(
            target: .codex,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        XCTAssertEqual(status, .current(modelIDs: ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"]))
    }

    func test_codexModelSyncStatusStaleWhenLiveCatalogChanges() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "codex-token")
        _ = try wiring.wire(
            target: .codex,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        let status = wiring.modelSyncStatus(
            target: .codex,
            gateway: gateway,
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "glm-5.2",
                    displayName: "GLM-5.2",
                    providerID: "zai",
                    providerName: "Z.AI",
                    servedEndpoints: ["/v1/responses", "/v1/chat/completions", "/v1/messages"],
                    routeEligible: true
                )
            ]
        )

        XCTAssertEqual(
            status,
            .stale(installedModelIDs: ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"], expectedModelIDs: ["glm-5.2"])
        )
    }

    func test_claudeCodeModelSyncStatusCurrentAfterWire() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "claude-token")
        _ = try wiring.wire(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        let status = wiring.modelSyncStatus(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        XCTAssertEqual(status, .current(modelIDs: ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"]))
    }

    func test_claudeCodeModelSyncStatusStaleWhenLiveCatalogChanges() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "claude-token")
        _ = try wiring.wire(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        let status = wiring.modelSyncStatus(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "claude-opus-4-8",
                    displayName: "Claude Opus 4.8",
                    providerID: "anthropic",
                    providerName: "Anthropic",
                    formatFamily: "anthropic",
                    servedEndpoints: ["/v1/messages"],
                    capabilities: ["anthropic"],
                    routeEligible: true
                )
            ]
        )

        XCTAssertEqual(
            status,
            .stale(installedModelIDs: ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"], expectedModelIDs: ["claude-opus-4-8"])
        )
    }

    func test_claudeCodeTreatsLegacyEndpointlessProxyRowsAsBridgeCompatible() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "claude-token")
        let legacyOpenAICompatibleRow = RoutingClientAdvertisedModel(
            id: "glm-5.2",
            displayName: "GLM-5.2",
            providerID: "zai",
            providerName: "Z.ai",
            formatFamily: "openai_compat",
            servedEndpoints: [],
            routeEligible: true
        )

        _ = try wiring.wire(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: [legacyOpenAICompatibleRow]
        )

        let status = wiring.modelSyncStatus(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: [legacyOpenAICompatibleRow]
        )

        XCTAssertEqual(status, .current(modelIDs: ["glm-5.2"]))
    }

    func test_wireClaudeCodeFiltersCatalogToMessagesEndpointModels() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "claude-token")
        let advertisedModels = [
            RoutingClientAdvertisedModel(
                id: "gpt-5.5",
                displayName: "GPT-5.5",
                providerID: "codex",
                providerName: "Codex",
                servedEndpoints: ["/v1/responses"],
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "claude-opus-4-8",
                displayName: "Claude Opus 4.8",
                providerID: "anthropic",
                providerName: "Anthropic",
                formatFamily: "anthropic",
                servedEndpoints: ["/v1/messages"],
                capabilities: ["anthropic"],
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "chat-only-model",
                displayName: "Chat Only",
                providerID: "test",
                providerName: "Test",
                servedEndpoints: ["/v1/chat/completions"],
                routeEligible: true
            )
        ]

        _ = try wiring.wire(
            target: .claudeCode,
            gateway: gateway,
            advertisedModels: advertisedModels
        )

        let root = try loadJSONObject(at: tempHome.appendingPathComponent(".claude/settings.json"))
        let env = try XCTUnwrap(root["env"] as? [String: Any])
        XCTAssertEqual(env["OPENBURNBAR_MODEL_CATALOG_IDS"] as? String, "claude-opus-4-8")
        XCTAssertEqual(
            wiring.modelSyncStatus(target: .claudeCode, gateway: gateway, advertisedModels: advertisedModels),
            .current(modelIDs: ["claude-opus-4-8"])
        )
    }

    func test_probeCodexUsesResponsesWithOpenBurnBarModelAlias() async throws {
        let session = makeProbeSession { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer probe-token")
            let body = try Self.jsonBody(from: request)
            XCTAssertEqual(body["model"] as? String, "openburnbar/glm-5")
            XCTAssertEqual(body["input"] as? String, "ping")
            XCTAssertEqual(body["max_output_tokens"] as? Int, 1)
            return Data(#"{"id":"resp_test","output_text":"ok"}"#.utf8)
        }

        let result = await makeWiring().probe(
            target: .codex,
            gateway: exampleGateway(token: "probe-token"),
            advertisedModels: liveGatewayModels(),
            session: session
        )

        XCTAssertEqual(result, .ok(modelID: "openburnbar/glm-5"))
    }

    func test_probeClaudeCodeUsesMessagesWithLiveGatewayModel() async throws {
        let session = makeProbeSession { request in
            XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer probe-token")
            let body = try Self.jsonBody(from: request)
            XCTAssertEqual(body["model"] as? String, "glm-5")
            XCTAssertEqual(body["max_tokens"] as? Int, 1)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["content"] as? String, "ping")
            return Data(#"{"id":"msg_test","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}]}"#.utf8)
        }

        let result = await makeWiring().probe(
            target: .claudeCode,
            gateway: exampleGateway(token: "probe-token"),
            advertisedModels: liveGatewayModels(),
            session: session
        )

        XCTAssertEqual(result, .ok(modelID: "glm-5"))
    }

    // Regression test: when the gateway auth token rotates after the last wire
    // (e.g. a new token is generated on daemon restart), the stored API key in
    // Droid's JSON config files no longer authenticates → every request gets a
    // 401. modelSyncStatus must detect the drift and return .stale so the sentry
    // immediately re-wires with the current token.
    func test_droidModelSyncStatusStaleWhenGatewayTokenRotated() throws {
        let wiring = makeWiring()
        let originalGateway = exampleGateway(token: "original-token")
        _ = try wiring.wire(
            target: .droid,
            gateway: originalGateway,
            advertisedModels: liveGatewayModels()
        )

        // Sanity: wiring with the original token is current.
        XCTAssertEqual(
            wiring.modelSyncStatus(
                target: .droid,
                gateway: originalGateway,
                advertisedModels: liveGatewayModels()
            ),
            .current(modelIDs: ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"])
        )

        // Simulate gateway token rotation — the daemon now uses a different token.
        let rotatedGateway = exampleGateway(token: "rotated-token")
        let status = wiring.modelSyncStatus(
            target: .droid,
            gateway: rotatedGateway,
            advertisedModels: liveGatewayModels()
        )

        // Model IDs still match, but the API key is stale → must be .stale.
        guard case .stale(let installedModelIDs, let expectedModelIDs) = status else {
            XCTFail(
                "Expected .stale after gateway token rotation, got \(status). " +
                "This means Droid CLI would keep sending the old token and receive 401s."
            )
            return
        }
        XCTAssertEqual(installedModelIDs, ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"])
        XCTAssertEqual(expectedModelIDs, ["glm-5", "minimax-m2.7", "claude-sonnet-4-6"])
        // The user-visible message should explain the token rotation — NOT show an
        // identical installed/expected diff which would be confusing and unhelpful.
        XCTAssertTrue(
            status.userMessage.contains("authentication credential is stale"),
            "Expected token-rotation message, got: \(status.userMessage)"
        )
        XCTAssertFalse(
            status.userMessage.contains("Installed: glm-5"),
            "Token-rotation stale should not show a redundant model-ID diff: \(status.userMessage)"
        )
    }

    func test_wireDroid_updatesStaleOpenBurnBarDefaultModelToLiveEntry() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "droid-token")
        let settingsURL = tempHome.appendingPathComponent(".factory/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "defaultModel": "custom:OpenBurnBar-MiniMax-M2.5-0",
          "sessionDefaultSettings": {
            "model": "custom:OpenBurnBar-MiniMax-M2.5-0"
          },
          "customModels": [
            {"model": "MiniMax-M2.5", "id": "custom:OpenBurnBar-MiniMax-M2.5-0", "displayName": "OpenBurnBar MiniMax M2.5", "provider": "generic-chat-completion-api", "baseUrl": "http://127.0.0.1:8317/v1"}
          ]
        }
        """.utf8).write(to: settingsURL)

        _ = try wiring.wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: liveGatewayModels()
        )

        let root = try loadJSONObject(at: settingsURL)
        let sessionDefaults = try XCTUnwrap(root["sessionDefaultSettings"] as? [String: Any])
        XCTAssertEqual(root["defaultModel"] as? String, "custom:OpenBurnBar-glm-5-0")
        XCTAssertEqual(sessionDefaults["model"] as? String, "custom:OpenBurnBar-glm-5-0")
    }

    func test_wireDroid_usesFactoryProviderAdapterMatchingModelFamily() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "droid-token")
        let models = [
            RoutingClientAdvertisedModel(
                id: "gpt-5-codex",
                displayName: "GPT-5 Codex",
                providerID: "openai",
                providerName: "OpenAI",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "kimi-k2.6",
                displayName: "Kimi K2.6",
                providerID: "moonshot",
                providerName: "Kimi",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "gpt-oss:120b",
                displayName: "GPT OSS 120B",
                providerID: "ollama",
                providerName: "Ollama Cloud",
                routeEligible: true
            ),
            RoutingClientAdvertisedModel(
                id: "claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6",
                providerID: "anthropic",
                providerName: "Anthropic",
                formatFamily: "anthropic",
                servedEndpoints: ["/v1/messages", "/v1/chat/completions", "/v1/responses"],
                routeEligible: true
            )
        ]

        _ = try wiring.wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: models
        )

        let settingsRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.map { $0["provider"] as? String }, ["openai", "generic-chat-completion-api", "generic-chat-completion-api", "anthropic"])
        XCTAssertEqual(settingsModels.map { $0["baseUrl"] as? String }, ["http://127.0.0.1:8317/v1", "http://127.0.0.1:8317/v1", "http://127.0.0.1:8317/v1", "http://127.0.0.1:8317"])

        let configRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/config.json"))
        let configModels = try XCTUnwrap(configRoot["custom_models"] as? [[String: Any]])
        XCTAssertEqual(configModels.map { $0["provider"] as? String }, ["openai", "generic-chat-completion-api", "generic-chat-completion-api", "anthropic"])
        XCTAssertEqual(configModels.map { $0["base_url"] as? String }, ["http://127.0.0.1:8317/v1", "http://127.0.0.1:8317/v1", "http://127.0.0.1:8317/v1", "http://127.0.0.1:8317"])
    }

    func test_wireDroid_prefersNonAnthropicDefaultWhenCatalogStartsWithClaude() throws {
        let wiring = makeWiring()
        let gateway = exampleGateway(token: "droid-token")

        _ = try wiring.wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "claude-sonnet-4-6",
                    displayName: "Claude Sonnet 4.6",
                    providerID: "anthropic",
                    providerName: "Anthropic",
                    formatFamily: "anthropic",
                    servedEndpoints: ["/v1/messages", "/v1/chat/completions", "/v1/responses"],
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "deepseek-v4-flash",
                    displayName: "DeepSeek V4 Flash",
                    providerID: "deepseek",
                    providerName: "DeepSeek",
                    routeEligible: true
                )
            ]
        )

        let settingsRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        XCTAssertEqual(settingsRoot["model"] as? String, "custom:OpenBurnBar-deepseek-v4-flash-1")
    }

    func test_wireDroid_resyncRemovesCurrentGatewayEntriesOnCustomPort() throws {
        let wiring = makeWiring()
        let gateway = RoutingClientGateway(host: "127.0.0.1", port: 9432, authToken: "droid-token")
        let settingsURL = tempHome.appendingPathComponent(".factory/settings.local.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "customModels": [
            {"model": "user-local", "displayName": "User Local", "provider": "generic-chat-completion-api", "baseUrl": "http://127.0.0.1:11434/v1"},
            {"model": "stale-openburnbar", "provider": "generic-chat-completion-api", "baseUrl": "http://127.0.0.1:9432/v1"}
          ]
        }
        """.utf8).write(to: settingsURL)

        _ = try wiring.wire(
            target: .droid,
            gateway: gateway,
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "kimi-k2.6",
                    displayName: "Kimi K2.6",
                    providerID: "moonshot",
                    providerName: "Kimi",
                    routeEligible: true
                )
            ]
        )

        let settingsRoot = try loadJSONObject(at: settingsURL)
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.map { $0["model"] as? String }, ["user-local", "kimi-k2.6"])
        XCTAssertEqual(settingsModels.first?["baseUrl"] as? String, "http://127.0.0.1:11434/v1")
    }

    func test_wireDroid_writesCloudSuffixedProxyModels() throws {
        let wiring = makeWiring()

        _ = try wiring.wire(
            target: .droid,
            gateway: exampleGateway(token: "droid-token"),
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "glm-5.2:cloud",
                    displayName: "GLM 5.2",
                    providerID: "ollama",
                    providerName: "Ollama Cloud",
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "kimi-k2.6:cloud",
                    displayName: "Kimi K2.6",
                    providerID: "ollama",
                    providerName: "Ollama Cloud",
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "deepseek-v4-pro:cloud",
                    displayName: "DeepSeek V4 Pro",
                    providerID: "ollama",
                    providerName: "Ollama Cloud",
                    routeEligible: true
                )
            ]
        )

        let settingsRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.map { $0["model"] as? String }, ["glm-5.2:cloud", "kimi-k2.6:cloud", "deepseek-v4-pro:cloud"])
        XCTAssertEqual(settingsModels.map { $0["id"] as? String }, [
            "custom:OpenBurnBar-glm-5.2-cloud-0",
            "custom:OpenBurnBar-kimi-k2.6-cloud-1",
            "custom:OpenBurnBar-deepseek-v4-pro-cloud-2"
        ])
        XCTAssertEqual(settingsModels.map { $0["displayName"] as? String }, [
            "OBB GLM 5.2 Ollama Cloud",
            "OBB Kimi K2.6 Ollama Cloud",
            "OBB DeepSeek V4 Pro Ollama Cloud"
        ])
        XCTAssertEqual(settingsModels.map { $0["provider"] as? String }, [
            "generic-chat-completion-api",
            "generic-chat-completion-api",
            "generic-chat-completion-api"
        ])

        let configRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/config.json"))
        let configModels = try XCTUnwrap(configRoot["custom_models"] as? [[String: Any]])
        XCTAssertEqual(configModels.map { $0["model"] as? String }, ["glm-5.2:cloud", "kimi-k2.6:cloud", "deepseek-v4-pro:cloud"])
        XCTAssertEqual(configModels.map { $0["model_display_name"] as? String }, [
            "OBB GLM 5.2 Ollama Cloud",
            "OBB Kimi K2.6 Ollama Cloud",
            "OBB DeepSeek V4 Pro Ollama Cloud"
        ])
        XCTAssertEqual(configModels.map { $0["base_url"] as? String }, [
            "http://127.0.0.1:8317/v1",
            "http://127.0.0.1:8317/v1",
            "http://127.0.0.1:8317/v1"
        ])
    }

    func test_wireDroid_labelsSameModelByRouteSource() throws {
        let wiring = makeWiring()

        _ = try wiring.wire(
            target: .droid,
            gateway: exampleGateway(token: "droid-token"),
            advertisedModels: [
                RoutingClientAdvertisedModel(
                    id: "deepseek-v4-pro",
                    displayName: "DeepSeek V4 Pro",
                    providerID: "deepseek",
                    providerName: "DeepSeek",
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "opencode/deepseek-v4-pro",
                    displayName: "DeepSeek V4 Pro",
                    providerID: "opencode",
                    providerName: "OpenCode",
                    routeEligible: true
                ),
                RoutingClientAdvertisedModel(
                    id: "deepseek-v4-pro:cloud",
                    displayName: "DeepSeek V4 Pro",
                    providerID: "ollama",
                    providerName: "Ollama Cloud",
                    routeEligible: true
                )
            ]
        )

        let settingsRoot = try loadJSONObject(at: tempHome.appendingPathComponent(".factory/settings.local.json"))
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(
            settingsModels.map { $0["displayName"] as? String },
            [
                "OBB DeepSeek V4 Pro Direct",
                "OBB DeepSeek V4 Pro OpenCode",
                "OBB DeepSeek V4 Pro Ollama Cloud"
            ]
        )
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
        XCTAssertNotNil(models["claude-sonnet-4-6"])
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
        XCTAssertNil(root["model"])

        let settingsRoot = try loadJSONObject(at: settingsURL)
        let settingsModels = try XCTUnwrap(settingsRoot["customModels"] as? [[String: Any]])
        XCTAssertEqual(settingsModels.count, 1)
        XCTAssertEqual(settingsModels.first?["model"] as? String, "existing-settings-model")
        XCTAssertNil(settingsRoot["model"])

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

    func test_shellSnippet_grok_exportsXAIKeyAndGatewayToken() {
        let wiring = makeWiring()
        let snippet = wiring.shellSnippet(
            target: .grok,
            gateway: RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "grok-local")
        )
        XCTAssertTrue(snippet.contains("export XAI_API_KEY='grok-local'"))
        XCTAssertTrue(snippet.contains("export OPENBURNBAR_GATEWAY_TOKEN='grok-local'"))
        XCTAssertTrue(snippet.contains("~/.grok/config.toml"))
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
        XCTAssertEqual(
            wiring.configURL(for: .grok),
            tempHome.appendingPathComponent(".grok/config.toml")
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

    private func makeProbeSession(
        handler: @escaping @Sendable (URLRequest) throws -> Data
    ) -> URLSession {
        RoutingProbeURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = request.httpBody ?? data(from: request.httpBodyStream)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private static func data(from stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
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
                formatFamily: "anthropic",
                servedEndpoints: ["/v1/messages", "/v1/chat/completions", "/v1/responses"],
                capabilities: ["anthropic"],
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

private final class RoutingProbeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?

    static func reset() {
        handler = nil
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let body = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

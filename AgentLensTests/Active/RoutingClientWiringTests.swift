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
        XCTAssertTrue(text.contains("model_provider = \"openburnbar\""))
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

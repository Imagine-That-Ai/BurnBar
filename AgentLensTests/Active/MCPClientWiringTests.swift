import XCTest
@testable import OpenBurnBar

/// One-click MCP install coverage (T0.4): surgical, idempotent, reversible
/// edits to the three coding-agent configs. The invariant that matters most is
/// preservation — a user's existing servers, keys, and TOML lines must survive
/// our wire/unwire byte-for-byte (JSON semantics; TOML lines outside the fence).
@MainActor
final class MCPClientWiringTests: XCTestCase {
    private var home: URL!
    private var wiring: MCPClientWiring!
    private let launch = MCPServerLaunch(
        command: "/usr/bin/python3",
        arguments: ["/repo/tools/openburnbar-mcp/server.py"],
        toolset: "memory"
    )

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // `configHome` is pinned under the fake home so the Muse target can
        // never reach the real `~/.config` (or an inherited `XDG_CONFIG_HOME`).
        wiring = MCPClientWiring(home: home, configHome: home.appendingPathComponent(".config"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: JSON targets

    func test_wireClaudeCode_createsFileAndEntry() throws {
        let change = try wiring.wire(target: .claudeCode, launch: launch)
        XCTAssertTrue(change.didMutate)

        let root = try json(at: wiring.configURL(for: .claudeCode))
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let entry = try XCTUnwrap(servers["openburnbar"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, "/usr/bin/python3")
        XCTAssertEqual(entry["args"] as? [String], ["/repo/tools/openburnbar-mcp/server.py"])
        XCTAssertEqual((entry["env"] as? [String: String])?["BURNBAR_MCP_TOOLSET"], "memory")

        // Idempotent: second wire is a no-op.
        XCTAssertFalse(try wiring.wire(target: .claudeCode, launch: launch).didMutate)
    }

    func test_wireCursor_preservesForeignServersAndUnrelatedKeys() throws {
        let url = wiring.configURL(for: .cursor)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        {"mcpServers": {"mem0": {"command": "npx", "args": ["mem0-mcp"]}}, "theme": "dark"}
        """
        try existing.data(using: .utf8)!.write(to: url)

        try wiring.wire(target: .cursor, launch: launch)

        let root = try json(at: url)
        XCTAssertEqual(root["theme"] as? String, "dark", "Unrelated keys must survive")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["mem0"], "Foreign servers must survive")
        XCTAssertNotNil(servers["openburnbar"])

        // Unwire removes exactly ours.
        try wiring.unwire(target: .cursor)
        let after = try json(at: url)
        let remaining = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertNotNil(remaining["mem0"])
        XCTAssertNil(remaining["openburnbar"])
    }

    func test_unwireJSON_removesEmptyServersObjectWeCreated() throws {
        try wiring.wire(target: .claudeCode, launch: launch)
        try wiring.unwire(target: .claudeCode)
        let root = try json(at: wiring.configURL(for: .claudeCode))
        XCTAssertNil(root["mcpServers"], "An mcpServers object we created empties away with us")
    }

    func test_wireJSON_refusesToClobberNonObjectConfig() throws {
        let url = wiring.configURL(for: .claudeCode)
        try "[1, 2, 3]".data(using: .utf8)!.write(to: url)
        XCTAssertThrowsError(try wiring.wire(target: .claudeCode, launch: launch)) { error in
            guard case MCPClientWiringError.unreadableConfig = error else {
                return XCTFail("Expected unreadableConfig, got \(error)")
            }
        }
        // And the file is untouched.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[1, 2, 3]")
    }

    // MARK: Codex TOML

    func test_wireCodex_appendsFencedBlockAndPreservesUserLines() throws {
        let url = wiring.configURL(for: .codex)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let userConfig = "model = \"gpt-5.6\"\n\n[profiles.work]\napproval = \"never\"\n"
        try userConfig.data(using: .utf8)!.write(to: url)

        try wiring.wire(target: .codex, launch: launch)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(contents.contains("[profiles.work]"))
        XCTAssertTrue(contents.contains("[mcp_servers.openburnbar]"))
        XCTAssertTrue(contents.contains("BURNBAR_MCP_TOOLSET = \"memory\""))
        XCTAssertTrue(contents.contains(MCPClientWiring.codexSentinelBegin))

        // Idempotent.
        XCTAssertFalse(try wiring.wire(target: .codex, launch: launch).didMutate)

        // Re-wire with a different launch replaces the block, not stacks it.
        let other = MCPServerLaunch(command: "/opt/python", arguments: ["/x/server.py"], toolset: "all")
        try wiring.wire(target: .codex, launch: other)
        let rewired = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            rewired.components(separatedBy: MCPClientWiring.codexSentinelBegin).count, 2,
            "Exactly one fenced block after re-wiring"
        )
        XCTAssertTrue(rewired.contains("/opt/python"))
        XCTAssertFalse(rewired.contains("/usr/bin/python3"))

        // Unwire restores the user's config without our block.
        try wiring.unwire(target: .codex)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(after.contains("[profiles.work]"))
        XCTAssertFalse(after.contains("openburnbar"))
        XCTAssertFalse(after.contains(MCPClientWiring.codexSentinelBegin))
    }

    func test_unwireCodex_missingFileIsANoOp() throws {
        XCTAssertFalse(try wiring.unwire(target: .codex).didMutate)
    }

    // MARK: Installed-state probe

    func test_isWired_reflectsRealConfigState() throws {
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
        XCTAssertFalse(wiring.isWired(target: .codex))

        try wiring.wire(target: .claudeCode, launch: launch)
        try wiring.wire(target: .codex, launch: launch)
        XCTAssertTrue(wiring.isWired(target: .claudeCode))
        XCTAssertTrue(wiring.isWired(target: .codex))

        try wiring.unwire(target: .claudeCode)
        try wiring.unwire(target: .codex)
        XCTAssertFalse(wiring.isWired(target: .claudeCode))
        XCTAssertFalse(wiring.isWired(target: .codex))
    }

    // MARK: The other JSON clients (Droid, Antigravity, Gemini CLI, Muse)

    /// Each path is pinned to the client's own documentation. A silent move
    /// here writes a config nothing reads, which is worse than no row at all.
    func test_configPaths_matchEachClientsDocumentedLocation() {
        func relative(_ target: MCPClientWiringTarget) -> String {
            wiring.configURL(for: target).path.replacingOccurrences(of: home.path + "/", with: "")
        }
        XCTAssertEqual(relative(.claudeCode), ".claude.json")
        XCTAssertEqual(relative(.cursor), ".cursor/mcp.json")
        XCTAssertEqual(relative(.codex), ".codex/config.toml")
        // https://docs.factory.ai/cli/configuration/mcp
        XCTAssertEqual(relative(.droid), ".factory/mcp.json")
        // https://antigravity.google/docs/cli/mcp/
        XCTAssertEqual(relative(.antigravity), ".gemini/config/mcp_config.json")
        // https://geminicli.com/docs/reference/configuration
        XCTAssertEqual(relative(.geminiCLI), ".gemini/settings.json")
        // $XDG_CONFIG_HOME/muse/settings.json
        XCTAssertEqual(relative(.muse), ".config/muse/settings.json")
    }

    func test_resolvedConfigHome_prefersXDGThenDotConfig() {
        XCTAssertEqual(
            MCPClientWiring.resolvedConfigHome(home: home, environment: [:]).path,
            home.appendingPathComponent(".config").path
        )
        XCTAssertEqual(
            MCPClientWiring.resolvedConfigHome(home: home, environment: ["XDG_CONFIG_HOME": "/xdg"]).path,
            "/xdg"
        )
        XCTAssertEqual(
            MCPClientWiring.resolvedConfigHome(home: home, environment: ["XDG_CONFIG_HOME": "   "]).path,
            home.appendingPathComponent(".config").path
        )
    }

    /// Factory documents `type: "stdio"` on local-process servers.
    func test_wireDroid_writesStdioTypedEntryAndKeepsForeignServers() throws {
        let url = wiring.configURL(for: .droid)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers": {"airtable": {"command": "npx", "args": ["-y", "airtable-mcp-server"]}}}"#
            .data(using: .utf8)!.write(to: url)

        XCTAssertTrue(try wiring.wire(target: .droid, launch: launch).didMutate)

        let servers = try XCTUnwrap(try json(at: url)["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["airtable"], "A user's other servers must survive")
        let entry = try XCTUnwrap(servers["openburnbar"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "stdio")
        XCTAssertEqual(entry["command"] as? String, "/usr/bin/python3")
        XCTAssertEqual((entry["env"] as? [String: String])?["BURNBAR_MCP_TOOLSET"], "memory")
        XCTAssertFalse(try wiring.wire(target: .droid, launch: launch).didMutate)

        try wiring.unwire(target: .droid)
        let after = try XCTUnwrap(try json(at: url)["mcpServers"] as? [String: Any])
        XCTAssertNotNil(after["airtable"])
        XCTAssertNil(after["openburnbar"])
    }

    /// Antigravity and Gemini CLI both live under `~/.gemini`, but in two
    /// different files. Wiring one must never touch the other.
    func test_antigravityAndGeminiCLI_areIndependentFiles() throws {
        let geminiURL = wiring.configURL(for: .geminiCLI)
        try FileManager.default.createDirectory(at: geminiURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers": {"warp": {"command": "warp-mcp"}}, "security": {"auth": {"selectedType": "oauth-personal"}}}"#
            .data(using: .utf8)!.write(to: geminiURL)

        try wiring.wire(target: .antigravity, launch: launch)
        XCTAssertTrue(wiring.isWired(target: .antigravity))
        XCTAssertFalse(wiring.isWired(target: .geminiCLI), "Antigravity's file is not Gemini CLI's file")
        XCTAssertNil(
            try XCTUnwrap(try json(at: geminiURL)["mcpServers"] as? [String: Any])["openburnbar"]
        )

        try wiring.wire(target: .geminiCLI, launch: launch)
        let gemini = try json(at: geminiURL)
        XCTAssertNotNil(gemini["security"], "Nested Gemini CLI settings must survive")
        let servers = try XCTUnwrap(gemini["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["warp"])
        XCTAssertNotNil(servers["openburnbar"])

        try wiring.unwire(target: .geminiCLI)
        XCTAssertTrue(wiring.isWired(target: .antigravity), "Unwiring one must not unwire the other")
    }

    /// Muse refuses to load a settings file without `schema_version`
    /// ("malformed settings file …: missing field `schema_version`"), so a
    /// file we create must carry it, and a file that already has one must
    /// keep the value the user chose.
    func test_wireMuse_writesStdioTransportAndTheRequiredSchemaVersion() throws {
        let url = wiring.configURL(for: .muse)
        XCTAssertTrue(try wiring.wire(target: .muse, launch: launch).didMutate)

        let root = try json(at: url)
        XCTAssertEqual(root["schema_version"] as? Int, 1)
        let entry = try XCTUnwrap((root["mcpServers"] as? [String: Any])?["openburnbar"] as? [String: Any])
        XCTAssertEqual(entry["transport"] as? String, "stdio")
        XCTAssertEqual(entry["command"] as? String, "/usr/bin/python3")
        XCTAssertEqual(entry["args"] as? [String], ["/repo/tools/openburnbar-mcp/server.py"])
        XCTAssertFalse(try wiring.wire(target: .muse, launch: launch).didMutate)

        // Unwiring leaves a file Muse can still load.
        try wiring.unwire(target: .muse)
        let after = try json(at: url)
        XCTAssertEqual(after["schema_version"] as? Int, 1)
        XCTAssertNil(after["mcpServers"])
    }

    func test_wireMuse_preservesExistingSettingsAndDoesNotRewriteSchemaVersion() throws {
        let url = wiring.configURL(for: .muse)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"schema_version": 2, "model": "muse-spark-1.3", "mcpServers": {"other": {"transport": "stdio", "command": "/bin/true"}}}"#
            .data(using: .utf8)!.write(to: url)

        try wiring.wire(target: .muse, launch: launch)

        let root = try json(at: url)
        XCTAssertEqual(root["schema_version"] as? Int, 2, "A user's schema_version is theirs")
        XCTAssertEqual(root["model"] as? String, "muse-spark-1.3")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        XCTAssertNotNil(servers["openburnbar"])
    }

    /// A pre-existing entry alone is not "wired" for Muse if the root is still
    /// missing the key its loader requires — the next wire repairs it.
    func test_wireMuse_repairsAConfigMissingSchemaVersion() throws {
        let url = wiring.configURL(for: .muse)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wiring.wire(target: .muse, launch: launch)

        var root = try json(at: url)
        root.removeValue(forKey: "schema_version")
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        XCTAssertTrue(try wiring.wire(target: .muse, launch: launch).didMutate)
        XCTAssertEqual(try json(at: url)["schema_version"] as? Int, 1)
    }

    /// Whatever we write, we take back — for every JSON client, with the
    /// user's other servers and unrelated keys intact.
    func test_everyJSONTarget_roundTripsSurgically() throws {
        let jsonTargets: [MCPClientWiringTarget] = [.claudeCode, .cursor, .droid, .antigravity, .geminiCLI, .muse]
        for target in jsonTargets {
            let url = wiring.configURL(for: target)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #"{"schema_version": 1, "keepMe": "yes", "mcpServers": {"foreign": {"command": "npx"}}}"#
                .data(using: .utf8)!.write(to: url)

            XCTAssertFalse(wiring.isWired(target: target), "\(target) starts unwired")
            try wiring.wire(target: target, launch: launch)
            XCTAssertTrue(wiring.isWired(target: target), "\(target) reports wired")

            try wiring.unwire(target: target)
            XCTAssertFalse(wiring.isWired(target: target), "\(target) reports unwired")
            let after = try json(at: url)
            XCTAssertEqual(after["keepMe"] as? String, "yes", "\(target) kept unrelated keys")
            let servers = try XCTUnwrap(after["mcpServers"] as? [String: Any], "\(target) kept foreign servers")
            XCTAssertNotNil(servers["foreign"], "\(target) kept the user's server")
            XCTAssertNil(servers["openburnbar"])
        }
    }

    // MARK: Launch resolution

    func test_resolver_prefersEnvOverride_thenBundle_thenCheckout() throws {
        // Build three servable locations under the fake home, then knock them
        // out in preference order.
        let envDirectory = home.appendingPathComponent("env-server")
        let bundleResources = home.appendingPathComponent("Bundle/Resources")
        let checkout = home.appendingPathComponent("Documents/Developer/BurnBar")

        func plantServer(pythonAt python: URL, serverAt server: URL) throws {
            try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: server.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: python)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try Data("# server\n".utf8).write(to: server)
        }

        let envPython = envDirectory.appendingPathComponent("python")
        let envServer = envDirectory.appendingPathComponent("server.py")
        try plantServer(pythonAt: envPython, serverAt: envServer)
        try plantServer(
            pythonAt: bundleResources.appendingPathComponent("openburnbar-mcp/.venv/bin/python"),
            serverAt: bundleResources.appendingPathComponent("openburnbar-mcp/server.py")
        )
        try plantServer(
            pythonAt: checkout.appendingPathComponent("tools/openburnbar-mcp/.venv/bin/python"),
            serverAt: checkout.appendingPathComponent("tools/openburnbar-mcp/server.py")
        )

        // 1. Env override wins.
        let withEnv = MCPServerLaunchResolver.resolve(
            home: home,
            environment: [
                "OPENBURNBAR_MCP_SERVER_PYTHON": envPython.path,
                "OPENBURNBAR_MCP_SERVER_PATH": envServer.path
            ],
            bundleResourceURL: bundleResources
        )
        XCTAssertEqual(withEnv.launch?.command, envPython.path)

        // 2. Without env, the bundle wins over the checkout.
        let withBundle = MCPServerLaunchResolver.resolve(
            home: home,
            environment: [:],
            bundleResourceURL: bundleResources
        )
        XCTAssertEqual(
            withBundle.launch?.command,
            bundleResources.appendingPathComponent("openburnbar-mcp/.venv/bin/python").path
        )

        // 3. Without either, the conventional checkout resolves.
        let withCheckout = MCPServerLaunchResolver.resolve(
            home: home,
            environment: [:],
            bundleResourceURL: nil
        )
        XCTAssertEqual(
            withCheckout.launch?.command,
            checkout.appendingPathComponent("tools/openburnbar-mcp/.venv/bin/python").path
        )
        XCTAssertEqual(withCheckout.launch?.toolset, "memory")
    }

    func test_resolver_nothingFound_returnsReasonNotALaunch() {
        let resolution = MCPServerLaunchResolver.resolve(
            home: home,
            environment: [:],
            bundleResourceURL: nil
        )
        XCTAssertNil(resolution.launch)
        XCTAssertNotNil(resolution.unavailabilityReason)
    }
}

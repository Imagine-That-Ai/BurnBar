import XCTest
@testable import OpenBurnBarCore
// P-15b: CLILaunchAdapter's internal test seams (environmentProvider/homeDirectoryProvider)
// moved to OpenBurnBarKernel; @testable reaches those internals (public CLILaunchAdapter
// members flow via the @_exported umbrella).
@testable import OpenBurnBarKernel
@testable import OpenBurnBarLaunchServices

final class CLIAuthDiscoveryTests: XCTestCase {
    override func tearDown() {
        CLILaunchAdapter.executableResolver = nil
        CLILaunchAdapter.environmentProvider = { ProcessInfo.processInfo.environment }
        CLILaunchAdapter.homeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser.path }
        CLIAuthDiscovery.environmentProvider = { ProcessInfo.processInfo.environment }
        super.tearDown()
    }

    func test_formattedAccountDescription_prefersNameAndEmail() {
        XCTAssertEqual(
            CLIAuthDiscovery.formattedAccountDescription(
                name: "Alberto Nunez-Garcia",
                email: "alberto8793@gmail.com"
            ),
            "Alberto Nunez-Garcia • alberto8793@gmail.com"
        )
    }

    func test_parseJWTClaims_decodesBase64URLPayload() throws {
        let payload = #"{"name":"Alberto Nunez-Garcia","email":"alberto8793@gmail.com"}"#
        let payloadData = try XCTUnwrap(payload.data(using: .utf8))
        let encoded = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(encoded).signature"

        let claims = try XCTUnwrap(CLIAuthDiscovery.parseJWTClaims(from: token))
        XCTAssertEqual(claims["name"] as? String, "Alberto Nunez-Garcia")
        XCTAssertEqual(claims["email"] as? String, "alberto8793@gmail.com")
    }

    func test_extractClaudeAccountDescription_prefersEmail() {
        let json = """
        {
          "loggedIn": true,
          "email": "alberto8793@icloud.com",
          "orgName": "Example Org"
        }
        """

        let value = CLIAuthDiscovery.extractClaudeAccountDescription(
            fromStatusJSONData: Data(json.utf8)
        )

        XCTAssertEqual(value, "alberto8793@icloud.com")
    }

    func test_claudeStatusEnvironment_usesConfigDirForScopedProfiles() {
        let scopedPath = "/tmp/openburnbar-scoped-claude"
        let environment = CLIAuthDiscovery.claudeStatusEnvironment(configDirectory: scopedPath)

        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], scopedPath)
        XCTAssertEqual(environment["CLAUDE_CONFIG_PATH"], scopedPath)
    }

    func test_junieDiscoveryRequiresRecordedSessionNotEmptyDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-junie-auth-\(UUID().uuidString)", isDirectory: true)
        let configDir = tempRoot.appendingPathComponent(".junie", isDirectory: true)
        let sessionsDir = configDir.appendingPathComponent("sessions", isDirectory: true)
        let executableURL = tempRoot.appendingPathComponent("junie")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .junie ? executableURL : nil
        }
        CLILaunchAdapter.environmentProvider = { [:] }

        let empty = CLIAuthDiscovery.discoverAuthState(for: .junie, configDirectoryOverride: configDir.path)
        XCTAssertEqual(empty.authState, .notAuthenticated)
        XCTAssertNil(empty.accountDescription)

        let sessionDir = sessionsDir.appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "{}\n".write(to: sessionDir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

        let recorded = CLIAuthDiscovery.discoverAuthState(for: .junie, configDirectoryOverride: configDir.path)
        XCTAssertEqual(recorded.authState, .authenticated(lastRefresh: nil))
        XCTAssertEqual(recorded.accountDescription, "Junie local sessions")
    }

    func test_primeAgentDiscoveryTreatsConfigHomeAsAuthAndSurfacesLocalSessions() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-prime-auth-\(UUID().uuidString)", isDirectory: true)
        let configDir = tempRoot.appendingPathComponent(".prime", isDirectory: true)
        let sessionsDir = configDir.appendingPathComponent("agent/sessions", isDirectory: true)
        let executableURL = tempRoot.appendingPathComponent("prime-agent")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .primeAgent ? executableURL : nil
        }
        CLILaunchAdapter.environmentProvider = { [:] }

        let missingHome = CLIAuthDiscovery.discoverAuthState(
            for: .primeAgent,
            configDirectoryOverride: configDir.path
        )
        XCTAssertEqual(missingHome.authState, .notAuthenticated)
        XCTAssertNil(missingHome.accountDescription)

        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let configOnly = CLIAuthDiscovery.discoverAuthState(
            for: .primeAgent,
            configDirectoryOverride: configDir.path
        )
        XCTAssertEqual(configOnly.authState, .authenticated(lastRefresh: nil))
        XCTAssertNil(configOnly.accountDescription)

        try "session\n".write(
            to: sessionsDir.appendingPathComponent("session-001.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let recorded = CLIAuthDiscovery.discoverAuthState(
            for: .primeAgent,
            configDirectoryOverride: configDir.path
        )
        XCTAssertEqual(recorded.authState, .authenticated(lastRefresh: nil))
        XCTAssertEqual(recorded.accountDescription, "Prime Agent local sessions")
    }

    func test_fxDiscoveryRequiresCredentialEvidenceNotConfigOrSessions() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-fx-auth-\(UUID().uuidString)", isDirectory: true)
        let configDir = tempRoot.appendingPathComponent(".fx", isDirectory: true)
        let sessionsDir = configDir.appendingPathComponent("sessions", isDirectory: true)
        let executableURL = tempRoot.appendingPathComponent("fx")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .fx ? executableURL : nil
        }
        CLILaunchAdapter.environmentProvider = { [:] }
        CLIAuthDiscovery.environmentProvider = { [:] }

        let configOnly = CLIAuthDiscovery.discoverAuthState(
            for: .fx,
            configDirectoryOverride: configDir.path
        )
        XCTAssertEqual(configOnly.authState, .notAuthenticated)

        try "{}\n".write(
            to: sessionsDir.appendingPathComponent("session-001.json"),
            atomically: true,
            encoding: .utf8
        )
        let sessionOnly = CLIAuthDiscovery.discoverAuthState(
            for: .fx,
            configDirectoryOverride: configDir.path
        )
        XCTAssertEqual(sessionOnly.authState, .notAuthenticated)
        XCTAssertEqual(sessionOnly.accountDescription, "fx local sessions")
    }

    func test_fxDiscoveryRecognizesOAuthAndAPIKeyFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-fx-credentials-\(UUID().uuidString)", isDirectory: true)
        let configDir = tempRoot.appendingPathComponent(".fx", isDirectory: true)
        let executableURL = tempRoot.appendingPathComponent("fx")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .fx ? executableURL : nil
        }
        CLILaunchAdapter.environmentProvider = { [:] }
        CLIAuthDiscovery.environmentProvider = { [:] }

        try "gateway-key\n".write(
            to: configDir.appendingPathComponent("api-key"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            CLIAuthDiscovery.discoverAuthState(
                for: .fx,
                configDirectoryOverride: configDir.path
            ).authState,
            .apiKeyPresent
        )

        try FileManager.default.removeItem(at: configDir.appendingPathComponent("api-key"))
        try #"{"access_token":"opaque"}"#.write(
            to: configDir.appendingPathComponent("auth.json"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            CLIAuthDiscovery.discoverAuthState(
                for: .fx,
                configDirectoryOverride: configDir.path
            ).authState,
            .authenticated(lastRefresh: nil)
        )

        try FileManager.default.removeItem(at: configDir.appendingPathComponent("auth.json"))
        CLIAuthDiscovery.environmentProvider = { ["AI_GATEWAY_API_KEY": "gateway-key"] }
        XCTAssertEqual(
            CLIAuthDiscovery.discoverAuthState(
                for: .fx,
                configDirectoryOverride: configDir.path
            ).authState,
            .apiKeyPresent
        )
    }

    func test_newCLIDiscoveryTreatsConfigHomeAsAuth() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-new-cli-auth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let cases: [(SwitcherCLIProfileType, String, String)] = [
            (.hermes, ".hermes", "Hermes local profile"),
            (.goose, ".config/goose", "Goose local profile"),
            (.openClaude, ".openclaude", "OpenClaude profile"),
            (.openClaw, ".openclaw", "OpenClaw profile")
        ]

        for (cliType, relativeConfig, accountDescription) in cases {
            let configDir = tempRoot.appendingPathComponent(relativeConfig, isDirectory: true)
            let executableURL = tempRoot.appendingPathComponent(cliType.executableName)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            CLILaunchAdapter.executableResolver = { $0 == cliType ? executableURL : nil }
            CLILaunchAdapter.environmentProvider = { [:] }

            // Goose also probes `~/.goose`, so a missing override is not hermetic there.
            if cliType != .goose {
                let missing = CLIAuthDiscovery.discoverAuthState(
                    for: cliType,
                    configDirectoryOverride: configDir.appendingPathComponent("missing").path
                )
                XCTAssertEqual(missing.authState, .notAuthenticated, cliType.rawValue)
            }

            let present = CLIAuthDiscovery.discoverAuthState(
                for: cliType,
                configDirectoryOverride: configDir.path
            )
            XCTAssertEqual(present.authState, .authenticated(lastRefresh: nil), cliType.rawValue)
            XCTAssertEqual(present.accountDescription, accountDescription, cliType.rawValue)
        }

        let windsurf = CLIAuthDiscovery.discoverAuthState(for: .windsurf)
        XCTAssertEqual(windsurf.cliType, .windsurf)

        let antigravityGemini = tempRoot.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: antigravityGemini, withIntermediateDirectories: true)
        let antigravityExecutable = tempRoot.appendingPathComponent("agy")
        try "#!/bin/sh\n".write(to: antigravityExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: antigravityExecutable.path)
        CLILaunchAdapter.executableResolver = { $0 == .antigravity ? antigravityExecutable : nil }
        let antigravity = CLIAuthDiscovery.discoverAuthState(
            for: .antigravity,
            configDirectoryOverride: antigravityGemini.path
        )
        XCTAssertEqual(antigravity.authState, .authenticated(lastRefresh: nil))
    }
}

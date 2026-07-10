import XCTest
@testable import OpenBurnBarCore

final class CLIAuthDiscoveryTests: XCTestCase {
    override func tearDown() {
        CLILaunchAdapter.executableResolver = nil
        CLILaunchAdapter.environmentProvider = { ProcessInfo.processInfo.environment }
        CLILaunchAdapter.homeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser.path }
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

    func test_claudeDiscoveryRunsStatusCommandForDesktopConfigDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-claude-auth-\(UUID().uuidString)", isDirectory: true)
        let configDir = tempRoot.appendingPathComponent("profile", isDirectory: true)
        let executableURL = tempRoot.appendingPathComponent("claude")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--json" ]; then
          printf '%s\\n' '{"loggedIn":true,"email":"desktop@example.test"}'
          exit 0
        fi
        exit 2
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .claude ? executableURL : nil
        }

        let discovered = CLIAuthDiscovery.discoverAuthState(
            for: .claude,
            configDirectoryOverride: configDir.path
        )

        XCTAssertTrue(discovered.isInstalled)
        XCTAssertEqual(discovered.authState, .authenticated(lastRefresh: nil))
        XCTAssertEqual(discovered.accountDescription, "desktop@example.test")
        XCTAssertEqual(discovered.configDirectory, configDir.path)
    }

    func test_verificationEnvironmentRetainsOnlySafeDesktopInputs() {
        let environment = CLIAuthDiscovery.verificationCommandEnvironment(
            overrides: [
                "CLAUDE_CONFIG_DIR": "/tmp/claude-profile",
                "CLAUDE_CONFIG_PATH": "/tmp/claude-profile",
                "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "override-secret"
            ],
            ambient: [
                "HOME": "/home/tester",
                "LANG": "en_US.UTF-8",
                "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "daemon-secret",
                "ANTHROPIC_API_KEY": "provider-secret",
                "PATH": "/tmp/untrusted"
            ]
        )

        XCTAssertEqual(environment["HOME"], "/home/tester")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-profile")
        XCTAssertEqual(environment["CLAUDE_CONFIG_PATH"], "/tmp/claude-profile")
        XCTAssertNotEqual(environment["PATH"], "/tmp/untrusted")
        XCTAssertNil(environment["OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
    }

    func test_runCommandDrainsNoisyOutputWithoutDeadlockAndCapsCapture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-auth-noisy-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("noisy-status")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        i=0
        while [ "$i" -lt 12000 ]; do
          printf '%s\\n' 'noisy provider diagnostic output that must be drained safely' >&2
          i=$((i + 1))
        done
        printf '%s\\n' '{"loggedIn":true}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let output = CLIAuthDiscovery.runCommand(
            executablePath: executable.path,
            arguments: [],
            timeout: 5
        )

        XCTAssertEqual(String(data: try XCTUnwrap(output), encoding: .utf8), "{\"loggedIn\":true}\n")
        XCTAssertLessThanOrEqual(try XCTUnwrap(output).count, 64 * 1_024)
    }

    func test_runCommandKillsAndReapsTermIgnoringProcessAfterTimeout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-auth-timeout-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("stuck-status")
        let pidFile = root.appendingPathComponent("pid")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf '%s\\n' "$$" > '\(pidFile.path)'
        trap '' TERM
        while :; do /bin/sleep 1; done
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let startedAt = Date()

        let output = CLIAuthDiscovery.runCommand(
            executablePath: executable.path,
            arguments: [],
            timeout: 0.15
        )

        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        let processID = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(processExists(processID))
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

    private func processExists(_ processID: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-0", String(processID)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

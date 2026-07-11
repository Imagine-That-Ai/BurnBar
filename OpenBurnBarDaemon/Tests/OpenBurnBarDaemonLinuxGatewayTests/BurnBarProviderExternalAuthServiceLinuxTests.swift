import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarDaemon

final class BurnBarProviderExternalAuthServiceLinuxTests: XCTestCase {
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private struct Fixture {
        let root: URL
        let now: Locked<Date>
        let auth: Locked<CLIAuthInfo>
        let launchedScript: Locked<URL?>
        let service: BurnBarProviderExternalAuthService
    }

    override func tearDown() {
        CLILaunchAdapter.executableResolver = nil
        super.tearDown()
    }

    func testLinuxServiceLaunchesPrivateValidScriptAndVerifiesSuccess() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))

        XCTAssertEqual(started.flow.state, .awaitingUser)
        let scriptURL = try XCTUnwrap(fixture.launchedScript.read())
        XCTAssertEqual(permissions(at: fixture.root), 0o700)
        XCTAssertEqual(permissions(at: scriptURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(permissions(at: scriptURL), 0o700)
        XCTAssertEqual(
            permissions(at: scriptURL.deletingLastPathComponent().appendingPathComponent("started.ready")),
            0o600
        )
        XCTAssertEqual(
            permissions(at: fixture.root.appendingPathComponent("current-flow.json")),
            0o600
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertEqual(script.components(separatedBy: "deadline_epoch=").count - 1, 1)
        XCTAssertTrue(script.contains("[ \"$now_epoch\" -ge \"$deadline_epoch\" ]"))
        XCTAssertFalse(script.contains("elapsed=0"))
        try assertShellSyntax(scriptURL)

        fixture.auth.write(authInfo(cliType: .codex, state: .authenticated(lastRefresh: nil)))
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )
        let verified = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(verified.flow.state, .succeeded)
        XCTAssertTrue(verified.flow.connected)
    }

    func testLinuxServiceReportsMissingTerminal() async throws {
        let fixture = try makeFixture(
            cliType: .claude,
            launchTerminal: { _ in
                throw BurnBarProviderExternalAuthTerminalLaunchError.unavailable
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))

        XCTAssertEqual(response.flow.state, .failed)
        XCTAssertEqual(response.flow.problem?.code, .terminalUnavailable)
        XCTAssertEqual(
            response.flow.problem?.message,
            "Install a supported terminal emulator before starting sign-in."
        )
    }

    func testLinuxServiceCancellationWritesPrivateSentinel() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))

        let cancelled = try await fixture.service.cancel(BurnBarProviderExternalAuthFlowRequest(
            flowID: try XCTUnwrap(started.flow.flowID)
        ))

        XCTAssertEqual(cancelled.flow.state, .cancelled)
        XCTAssertEqual(cancelled.flow.problem?.code, .cancelled)
        let scriptURL = try XCTUnwrap(fixture.launchedScript.read())
        let sentinel = scriptURL.deletingLastPathComponent().appendingPathComponent("cancel.requested")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(permissions(at: sentinel), 0o600)
    }

    func testLinuxServiceTimeoutRequestsScriptCancellation() async throws {
        let fixture = try makeFixture(cliType: .claude)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))
        fixture.now.write(fixture.now.read().addingTimeInterval(301))

        let timedOut = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "anthropic",
            flowID: started.flow.flowID
        ))

        XCTAssertEqual(timedOut.flow.state, .timedOut)
        XCTAssertEqual(timedOut.flow.problem?.code, .timeout)
        let scriptURL = try XCTUnwrap(fixture.launchedScript.read())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scriptURL.deletingLastPathComponent().appendingPathComponent("cancel.requested").path
        ))
        let repeated = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "anthropic",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(repeated.flow.state, .timedOut)
    }

    func testLinuxCLIAuthDiscoveryExecutesClaudeStatusCommand() throws {
        let root = temporaryRoot()
        let config = root.appendingPathComponent("claude-profile", isDirectory: true)
        let executable = root.appendingPathComponent("claude", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--json" ] || exit 2
        printf '%s\\n' '{"loggedIn":true,"email":"linux@example.test"}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        CLILaunchAdapter.executableResolver = { $0 == .claude ? executable : nil }

        let discovered = CLIAuthDiscovery.discoverAuthState(
            for: .claude,
            configDirectoryOverride: config.path
        )

        XCTAssertTrue(discovered.isInstalled)
        XCTAssertEqual(discovered.authState, .authenticated(lastRefresh: nil))
        XCTAssertEqual(discovered.accountDescription, "linux@example.test")
    }

    func testLinuxCLIAuthDiscoveryFailsClosedWithoutTrustedSetsid() throws {
        #if os(Linux)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invokedURL = root.appendingPathComponent("invoked")
        let executableURL = root.appendingPathComponent("fake-cli")
        try "#!/bin/sh\nprintf invoked > '\(invokedURL.path)'\nprintf authenticated\n"
            .write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let output = CLIAuthDiscovery.runCommand(
            executablePath: executableURL.path,
            arguments: ["auth", "status"],
            timeout: 1,
            linuxProcessGroupExecutablePath: "/missing/untrusted-setsid"
        )

        XCTAssertNil(output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invokedURL.path))
        #else
        throw XCTSkip("Trusted setsid fail-closed behavior runs in the Linux test matrix.")
        #endif
    }

    func testLinuxCLIAuthDiscoveryTimeoutKillsTermIgnoringProcessGroup() throws {
        #if os(Linux)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let leaderPIDURL = root.appendingPathComponent("leader.pid")
        let childPIDURL = root.appendingPathComponent("child.pid")
        let executableURL = root.appendingPathComponent("blocking-cli")
        let script = """
        #!/bin/sh
        trap 'exit 0' TERM
        /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
        child_pid=$!
        printf '%s' "$$" > '\(leaderPIDURL.path)'
        printf '%s' "$child_pid" > '\(childPIDURL.path)'
        wait "$child_pid"
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        XCTAssertNil(CLIAuthDiscovery.runCommand(
            executablePath: executableURL.path,
            arguments: [],
            timeout: 0.3
        ))
        let leaderPID = try XCTUnwrap(Int32(String(contentsOf: leaderPIDURL, encoding: .utf8)))
        let childPID = try XCTUnwrap(Int32(String(contentsOf: childPIDURL, encoding: .utf8)))
        try waitUntil(timeout: 1) {
            !self.processExists(leaderPID) && !self.processExists(childPID)
        }
        XCTAssertFalse(processExists(leaderPID))
        XCTAssertFalse(processExists(childPID))
        #else
        throw XCTSkip("Process-group timeout integration runs in the Linux test matrix.")
        #endif
    }

    func testLinuxCancelKillsLoginProcessGroupIncludingGrandchild() async throws {
        #if !os(Linux)
        throw XCTSkip("Process-group integration runs in the Linux gateway matrix")
        #else
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/setsid") else {
            throw XCTSkip("util-linux script and setsid are required")
        }

        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pidFile = fixture.root.appendingPathComponent("login-pids")
        try """
        #!/bin/sh
        /bin/sleep 600 &
        grandchild=$!
        printf '%s %s\\n' "$$" "$grandchild" > "$OPENBURNBAR_TEST_PID_FILE"
        trap '/bin/kill -TERM "$grandchild" 2>/dev/null; wait "$grandchild" 2>/dev/null; exit 0' HUP INT TERM
        wait "$grandchild"
        """.write(to: fixture.root.appendingPathComponent("codex"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.root.appendingPathComponent("codex").path
        )
        _ = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let scriptURL = try XCTUnwrap(fixture.launchedScript.read())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "-e", "-c", scriptURL.path, "/dev/null"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "OPENBURNBAR_TEST_PID_FILE": pidFile.path
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: pidFile.path) }
        let pids = try String(contentsOf: pidFile, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }
        XCTAssertEqual(pids.count, 2)

        let sentinel = scriptURL.deletingLastPathComponent().appendingPathComponent("cancel.requested")
        try Data().write(to: sentinel, options: .atomic)
        try waitUntil(timeout: 5) { !process.isRunning }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try waitUntil(timeout: 5) { pids.allSatisfy { !self.processExists($0) } }
        #endif
    }

    private func makeFixture(
        cliType: SwitcherCLIProfileType,
        launchTerminal: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> Fixture {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent(cliType.executableName, isDirectory: false)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let now = Locked(Date(timeIntervalSince1970: 1_750_000_000))
        let auth = Locked(authInfo(cliType: cliType, state: .notAuthenticated))
        let launchedScript = Locked<URL?>(nil)
        let launcher: @Sendable (URL) throws -> Void = launchTerminal ?? {
            launchedScript.write($0)
            try Self.writeStartedSentinel(for: $0)
        }
        let service = BurnBarProviderExternalAuthService(
            rootDirectoryURL: root,
            dependencies: .init(
                now: { now.read() },
                makeUUID: { UUID(uuidString: "22222222-2222-2222-2222-222222222222")! },
                resolveExecutable: { _ in executable },
                discoverAuth: { _, _ in auth.read() },
                launchTerminal: launcher
            )
        )
        return Fixture(root: root, now: now, auth: auth, launchedScript: launchedScript, service: service)
    }

    private static func writeStartedSentinel(for scriptURL: URL) throws {
        let startedURL = scriptURL.deletingLastPathComponent().appendingPathComponent("started.ready")
        try Data("started\n".utf8).write(to: startedURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: startedURL.path)
    }

    private func assertShellSyntax(_ scriptURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("condition did not become true before timeout")
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

    private func authInfo(cliType: SwitcherCLIProfileType, state: CLIAuthState) -> CLIAuthInfo {
        CLIAuthInfo(
            cliType: cliType,
            isInstalled: state != .notInstalled,
            executablePath: state == .notInstalled ? nil : "/trusted/\(cliType.executableName)",
            authState: state,
            configDirectory: nil,
            accountDescription: nil
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-provider-auth-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

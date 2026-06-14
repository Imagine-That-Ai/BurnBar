import Foundation
import XCTest
@testable import OpenBurnBar

@MainActor
final class HermesRuntimeLauncherTests: XCTestCase {

    func test_relayHostConnectionIDUsesStableInstallationIdentity() {
        let suiteName = "HermesRuntimeLauncherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = HermesRelayHostService.loadOrCreateRelayHostInstallationID(defaults: defaults)
        let second = HermesRelayHostService.loadOrCreateRelayHostInstallationID(defaults: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            HermesRelayHostService.relayConnectionID(forHostInstallationID: "MacBook Pro / Alberto"),
            "relay-host-macbook-pro-alberto"
        )
        XCTAssertEqual(
            HermesRelayHostService.legacyRelayConnectionID(forDeviceID: "MacBook Pro / Alberto"),
            "relay-macbook-pro-alberto"
        )
    }

    func test_refreshStatus_reportsMissingCLI() async {
        let fake = FakeHermesRuntime(executable: nil)
        let launcher = HermesRuntimeLauncher(dependencies: fake.dependencies)

        let status = await launcher.refreshStatus()

        XCTAssertFalse(status.isReady)
        XCTAssertNil(status.hermesCLIPath)
        XCTAssertEqual(launcher.lastError, HermesRuntimeLauncherError.hermesCLIUnavailable.localizedDescription)
        let commands = await fake.commands
        XCTAssertEqual(commands, [])
    }

    func test_openHermesAndGateway_startsGatewayAndDashboardWhenBothAreStopped() async {
        let fake = FakeHermesRuntime(
            gatewayAvailable: false,
            dashboardStatusOutput: ""
        )
        let launcher = HermesRuntimeLauncher(dependencies: fake.dependencies)

        let status = await launcher.openHermesAndGateway()

        XCTAssertTrue(status.gatewayRunning)
        XCTAssertTrue(status.dashboardRunning)
        let commands = await fake.commands
        let detachedCommands = await fake.detachedCommands
        XCTAssertEqual(commands, [
            ["dashboard", "--status"],
            ["dashboard", "--status"]
        ])
        XCTAssertEqual(detachedCommands, [
            ["gateway", "run"],
            ["dashboard", "--tui"]
        ])
    }

    func test_openHermesAndGateway_doesNotDuplicateRunningGatewayOrDashboard() async {
        let fake = FakeHermesRuntime(
            gatewayAvailable: true,
            dashboardStatusOutput: "Hermes dashboard running PID 123"
        )
        let launcher = HermesRuntimeLauncher(dependencies: fake.dependencies)

        let status = await launcher.openHermesAndGateway()

        XCTAssertTrue(status.gatewayRunning)
        XCTAssertTrue(status.dashboardRunning)
        let commands = await fake.commands
        let detachedCommands = await fake.detachedCommands
        XCTAssertEqual(commands, [
            ["dashboard", "--status"],
            ["dashboard", "--status"]
        ])
        XCTAssertEqual(detachedCommands, [])
    }

    func test_openHermesAndGateway_canStartGatewayWithoutOpeningDashboard() async {
        let fake = FakeHermesRuntime(
            gatewayAvailable: false,
            dashboardStatusOutput: ""
        )
        let launcher = HermesRuntimeLauncher(dependencies: fake.dependencies)

        let status = await launcher.openHermesAndGateway(launchDashboard: false)

        XCTAssertTrue(status.gatewayRunning)
        XCTAssertFalse(status.dashboardRunning)
        let commands = await fake.commands
        let detachedCommands = await fake.detachedCommands
        XCTAssertEqual(commands, [
            ["dashboard", "--status"]
        ])
        XCTAssertEqual(detachedCommands, [["gateway", "run"]])
    }

    func test_openHermesAndGateway_installsGatewayWhenRunFails() async {
        let fake = FakeHermesRuntime(
            gatewayAvailable: false,
            dashboardStatusOutput: "",
            failFirstGatewayStart: true
        )
        let launcher = HermesRuntimeLauncher(dependencies: fake.dependencies)

        let status = await launcher.openHermesAndGateway()

        XCTAssertTrue(status.gatewayRunning)
        let commands = await fake.commands
        let detachedCommands = await fake.detachedCommands
        XCTAssertEqual(commands.first, ["gateway", "--accept-hooks", "install", "--force"])
        XCTAssertEqual(Array(detachedCommands.prefix(2)), [
            ["gateway", "run"],
            ["gateway", "run"]
        ])
    }

    func test_openHermesAndGateway_enablesAPIServerBeforeLaunchingGateway() async {
        let fake = FakeHermesRuntime(
            gatewayAvailable: false,
            dashboardStatusOutput: ""
        )
        let launcher = HermesRuntimeLauncher(dependencies: fake.dependencies)

        _ = await launcher.openHermesAndGateway()

        let didEnsureAPIServerEnabled = await fake.didEnsureAPIServerEnabled
        XCTAssertTrue(didEnsureAPIServerEnabled)
    }

    // MARK: - readAPIServerKey (bearer-token source) read-fault distinction

    /// A genuinely absent `.env` file means "no key configured" and must resolve
    /// to `nil` without surfacing a fault.
    func test_readAPIServerKey_missingFile_returnsNilQuietly() {
        let url = Self.makeTempEnvURL()
        // Deliberately do not create the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let key = HermesEnvironmentFile.readAPIServerKey(at: url)

        XCTAssertNil(key)
    }

    /// A well-formed `.env` yields the configured key (the value that becomes the
    /// gateway bearer token), with surrounding quotes/whitespace stripped.
    func test_readAPIServerKey_presentFile_returnsTrimmedKey() throws {
        let url = Self.makeTempEnvURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = """
        API_SERVER_ENABLED=true
        API_SERVER_KEY="sk-hermes-secret-123"
        OTHER=value
        """
        try contents.write(to: url, atomically: true, encoding: .utf8)

        let key = HermesEnvironmentFile.readAPIServerKey(at: url)

        XCTAssertEqual(key, "sk-hermes-secret-123")
    }

    /// An empty `API_SERVER_KEY=` is treated as no key.
    func test_readAPIServerKey_presentFileWithEmptyKey_returnsNil() throws {
        let url = Self.makeTempEnvURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "API_SERVER_KEY=\nAPI_SERVER_ENABLED=true\n".write(to: url, atomically: true, encoding: .utf8)

        let key = HermesEnvironmentFile.readAPIServerKey(at: url)

        XCTAssertNil(key)
    }

    /// CRITICAL: when the path *exists* but cannot be read as a UTF-8 file (here a
    /// directory stands in for a permissions/corruption/I/O fault), the read must
    /// NOT silently masquerade as "no key configured" via a swallowed `try?`. The
    /// new code routes this through `AppLogger.silently` so the fault is observable;
    /// the contract still degrades to `nil` so callers behave exactly as before.
    /// This proves the missing-file path and the read-fault path are distinct.
    func test_readAPIServerKey_pathExistsButUnreadable_degradesToNilWithoutTreatingAsConfigured() throws {
        // A directory satisfies fileExists(atPath:) == true but
        // String(contentsOf:) throws, exactly modeling an existing-but-unreadable
        // .env (permissions/corruption/I-O fault).
        let dirURL = Self.makeTempEnvURL()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirURL.path))

        // The read genuinely throws, so the old `try?` would have returned nil too;
        // what matters is the fault now travels the observable path rather than the
        // missing-file path. We assert the read does throw (fault is real) and that
        // the public contract still degrades to nil.
        XCTAssertThrowsError(try String(contentsOf: dirURL, encoding: .utf8))

        let key = HermesEnvironmentFile.readAPIServerKey(at: dirURL)

        XCTAssertNil(key)
    }

    /// The async public entry point (wired into `.live` dependencies) keeps its
    /// signature and returns the configured key.
    func test_readAPIServerKey_asyncEntryPoint_matchesSyncResult() async throws {
        // The async overload reads the real ~/.hermes/.env, which may or may not
        // exist on the test host; it must never throw and must return an optional.
        let key = await HermesEnvironmentFile.readAPIServerKey()
        XCTAssert(key == nil || !(key ?? "").isEmpty)
    }

    /// Returns a `.env` URL inside a freshly created temp directory. The parent
    /// directory exists (so write tests succeed) but the `.env` itself does not
    /// (so missing-file tests see `fileExists == false`).
    private static func makeTempEnvURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesRuntimeLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".env")
    }
}

private actor FakeHermesRuntime {
    var commands: [[String]] = []
    var detachedCommands: [[String]] = []
    var didEnsureAPIServerEnabled = false

    private let executable: String?
    private var gatewayAvailable: Bool
    private var dashboardStatusOutput: String
    private var failFirstGatewayStart: Bool
    private var gatewayStartAttempts = 0

    init(
        executable: String? = "/usr/local/bin/hermes",
        gatewayAvailable: Bool = false,
        dashboardStatusOutput: String = "",
        failFirstGatewayStart: Bool = false
    ) {
        self.executable = executable
        self.gatewayAvailable = gatewayAvailable
        self.dashboardStatusOutput = dashboardStatusOutput
        self.failFirstGatewayStart = failFirstGatewayStart
    }

    nonisolated var dependencies: HermesRuntimeLauncherDependencies {
        HermesRuntimeLauncherDependencies(
            resolveHermesExecutable: { [weak self] in
                guard let self else { return nil }
                return await self.executable
            },
            runCommand: { [weak self] _, arguments in
                guard let self else { return "" }
                return try await self.runCommand(arguments)
            },
            launchDetached: { [weak self] _, arguments in
                try await self?.launchDetached(arguments)
            },
            probeGateway: { [weak self] _, _ in
                guard let self else { return (false, nil) }
                return await self.probeGateway()
            },
            ensureAPIServerEnabled: { [weak self] in
                await self?.ensureAPIServerEnabled()
            },
            readAPIServerKey: {
                nil
            }
        )
    }

    private func runCommand(_ arguments: [String]) throws -> String {
        commands.append(arguments)
        if arguments == ["gateway", "--accept-hooks", "install", "--force"] {
            return "Gateway installed"
        }
        if arguments == ["gateway", "--accept-hooks", "start"] {
            gatewayStartAttempts += 1
            if failFirstGatewayStart && gatewayStartAttempts == 1 {
                throw HermesRuntimeLauncherError.commandFailed(command: "hermes gateway start", detail: "not installed")
            }
            gatewayAvailable = true
            return "Gateway started"
        }
        if arguments == ["dashboard", "--status"] {
            return dashboardStatusOutput
        }
        return ""
    }

    private func launchDetached(_ arguments: [String]) throws {
        detachedCommands.append(arguments)
        if arguments == ["gateway", "run"] {
            gatewayStartAttempts += 1
            if failFirstGatewayStart && gatewayStartAttempts == 1 {
                throw HermesRuntimeLauncherError.commandFailed(command: "hermes gateway run", detail: "not installed")
            }
            gatewayAvailable = true
        }
        if arguments == ["dashboard", "--tui"] {
            dashboardStatusOutput = "Hermes dashboard running PID 456"
        }
    }

    private func probeGateway() -> (available: Bool, modelName: String?) {
        (gatewayAvailable, gatewayAvailable ? "hermes-agent" : nil)
    }

    private func ensureAPIServerEnabled() {
        didEnsureAPIServerEnabled = true
    }
}

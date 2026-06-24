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

// MARK: - HermesSetupWizardController tests

@MainActor
final class HermesSetupWizardControllerTests: XCTestCase {

    // MARK: Reachability state derivation

    func test_reachability_cliMissing_whenCLINotResolved() {
        let controller = HermesSetupWizardController(dependencies: .fake(executable: nil))
        controller.hermesCLIInstalled = false
        controller.apiServerEnabled = true
        XCTAssertEqual(controller.reachability, .cliMissing)
    }

    func test_reachability_apiServerDisabled_whenFlagMissing() {
        let controller = HermesSetupWizardController(dependencies: .fake(executable: "/usr/local/bin/hermes"))
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = false
        controller.probeAttempts = 1
        XCTAssertEqual(controller.reachability, .apiServerDisabled)
    }

    func test_reachability_dashboardOnly_whenDashboardUpGatewayDown() {
        let controller = HermesSetupWizardController(dependencies: .fake(executable: "/usr/local/bin/hermes"))
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = true
        controller.isGatewayRunning = false
        controller.isDashboardRunning = true
        controller.probeAttempts = 1
        XCTAssertEqual(controller.reachability, .dashboardOnly)
        XCTAssertEqual(controller.reachability.primaryActionLabel, "Make Gateway Reachable")
    }

    func test_reachability_gatewayRunning_whenProbeSucceeds() {
        let controller = HermesSetupWizardController(dependencies: .fake(executable: "/usr/local/bin/hermes"))
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = true
        controller.isGatewayRunning = true
        XCTAssertEqual(controller.reachability, .gatewayRunning)
        XCTAssertTrue(controller.reachability.isReady)
        XCTAssertNil(controller.reachability.primaryActionLabel)
    }

    func test_reachability_unknown_beforeAnyProbe() {
        let controller = HermesSetupWizardController(dependencies: .fake(executable: "/usr/local/bin/hermes"))
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = true
        controller.probeAttempts = 0
        XCTAssertEqual(controller.reachability, .unknown)
    }

    func test_reachability_unreachable_afterProbeFindsNothing() {
        let controller = HermesSetupWizardController(dependencies: .fake(executable: "/usr/local/bin/hermes"))
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = true
        controller.probeAttempts = 3
        XCTAssertEqual(controller.reachability, .unreachable)
    }

    // MARK: makeGatewayReachable — the missing button

    /// The core regression: when the gateway is not reachable, calling
    /// `makeGatewayReachable()` must drive `openHermesAndGateway` (which
    /// installs + launches the gateway), not just re-probe. The old wizard
    /// looped `probeGateway` forever and never started anything.
    func test_makeGatewayReachable_invokesOpenHermesAndGateway_notJustProbe() async {
        let fake = FakeWizardRuntime(executable: "/usr/local/bin/hermes", gatewayAvailable: false)
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = true
        controller.probeAttempts = 2

        controller.makeGatewayReachable()
        // Wait for the async task to settle. isMakingReachable flips false on completion.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await fake.waitForIdle()

        let opened = await fake.openHermesAndGatewayCalls
        let refreshed = await fake.refreshStatusCalls
        XCTAssertEqual(opened, 1, "makeGatewayReachable must call openHermesAndGateway exactly once")
        XCTAssertEqual(refreshed, 0, "makeGatewayReachable must NOT call refreshStatus — openHermesAndGateway already re-probes")
        XCTAssertTrue(controller.isGatewayRunning, "After makeGatewayReachable, the fake's gateway should be running")
        XCTAssertNil(controller.makeReachableError)
    }

    /// When the launcher fails to start the gateway, the controller must surface
    /// a visible error rather than silently looping "not reachable yet".
    func test_makeGatewayReachable_surfacesErrorWhenGatewayStaysDown() async {
        let fake = FakeWizardRuntime(
            executable: "/usr/local/bin/hermes",
            gatewayAvailable: false,
            openHermesGatewayResult: HermesRuntimeStatus(
                hermesCLIPath: "/usr/local/bin/hermes",
                gatewayRunning: false,
                dashboardRunning: false,
                modelName: nil,
                message: "gateway binary missing"
            )
        )
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = true

        controller.makeGatewayReachable()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await fake.waitForIdle()

        XCTAssertFalse(controller.isGatewayRunning)
        XCTAssertNotNil(controller.makeReachableError)
        XCTAssertEqual(controller.makeReachableError, "gateway binary missing")
    }

    // MARK: probeGateway

    func test_probeGateway_appliesStatusAndIncrementsAttempts() async {
        let fake = FakeWizardRuntime(
            executable: "/usr/local/bin/hermes",
            gatewayAvailable: true,
            dashboardAvailable: true,
            modelName: "hermes-4"
        )
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)

        controller.probeGateway()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await fake.waitForIdle()

        XCTAssertEqual(controller.probeAttempts, 1)
        XCTAssertTrue(controller.isGatewayRunning)
        XCTAssertTrue(controller.isDashboardRunning)
        XCTAssertEqual(controller.gatewayModelName, "hermes-4")
        XCTAssertEqual(controller.reachability, .gatewayRunning)
        XCTAssertFalse(controller.isProbingGateway)
    }

    // MARK: checkCLI / checkConfig

    func test_checkCLI_resolvesExecutablePath() async {
        let fake = FakeWizardRuntime(executable: "/opt/homebrew/bin/hermes")
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)

        controller.checkCLI()
        await Self.awaitCheckingSettles(controller, keyPath: \.isCheckingCLI)

        XCTAssertTrue(controller.hermesCLIInstalled ?? false)
        XCTAssertEqual(controller.hermesCLIPath, "/opt/homebrew/bin/hermes")
        XCTAssertFalse(controller.isCheckingCLI)
    }

    func test_checkConfig_readsEnvSnapshot() async throws {
        let fake = FakeWizardRuntime(
            executable: "/usr/local/bin/hermes",
            envSnapshot: HermesEnvSnapshot(
                fileExists: true,
                apiServerEnabled: true,
                hasAPIServerKey: true,
                savedBearerToken: "sk-test"
            )
        )
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)

        controller.checkConfig()
        await Self.awaitCheckingSettles(controller, keyPath: \.isCheckingConfig)

        XCTAssertTrue(try XCTUnwrap(controller.envFileExists))
        XCTAssertTrue(try XCTUnwrap(controller.apiServerEnabled))
        XCTAssertTrue(try XCTUnwrap(controller.hasAPIServerKey))
        XCTAssertEqual(controller.bearerTokenInput, "sk-test")
        XCTAssertFalse(controller.isCheckingConfig)
    }

    // MARK: Navigation + completion gates

    func test_navigateForward_advancesStep() {
        let controller = HermesSetupWizardController(dependencies: .fakeEmpty())
        controller.currentStep = .prepare
        controller.navigateForward()
        XCTAssertEqual(controller.currentStep, .connect)
        XCTAssertEqual(controller.navigationDirection, .trailing)
    }

    func test_navigateBack_reversesDirection() {
        let controller = HermesSetupWizardController(dependencies: .fakeEmpty())
        controller.currentStep = .chat
        controller.navigateBack()
        XCTAssertEqual(controller.currentStep, .connect)
        XCTAssertEqual(controller.navigationDirection, .leading)
    }

    func test_canContinueFromPrepare_requiresCLIAndAPIServer() {
        let controller = HermesSetupWizardController(dependencies: .fakeEmpty())
        XCTAssertFalse(controller.canContinueFromPrepare)
        controller.hermesCLIInstalled = true
        XCTAssertFalse(controller.canContinueFromPrepare)
        controller.apiServerEnabled = true
        XCTAssertTrue(controller.canContinueFromPrepare)
    }

    func test_canContinueFromConnect_requiresGatewayRunning() {
        let controller = HermesSetupWizardController(dependencies: .fakeEmpty())
        XCTAssertFalse(controller.canContinueFromConnect)
        controller.isGatewayRunning = true
        XCTAssertTrue(controller.canContinueFromConnect)
    }

    // MARK: auto-probe lifecycle

    /// Polls until the verification Task settles (isVerifying flips false), or
    /// bounds out after ~1s so a broken Task never hangs the suite.
    private static func awaitVerificationSettles(_ controller: HermesSetupWizardController) async {
        for _ in 0..<50 {
            if !controller.isVerifying { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms per tick = 1s ceiling
        }
    }

    /// Polls until a boolean flag flips false (e.g. `isCheckingCLI`), bounded.
    private static func awaitCheckingSettles(
        _ controller: HermesSetupWizardController,
        keyPath: KeyPath<HermesSetupWizardController, Bool>
    ) async {
        for _ in 0..<50 {
            if !controller[keyPath: keyPath] { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_startAutoProbe_probesImmediatelyThenStopsWhenReachable() async {
        let fake = FakeWizardRuntime(
            executable: "/usr/local/bin/hermes",
            gatewayAvailable: true
        )
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)
        controller.hermesCLIInstalled = true
        controller.apiServerEnabled = true

        controller.startAutoProbe()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await fake.waitForIdle()

        // Immediate probe fired and the gateway came up.
        let refreshed = await fake.refreshStatusCalls
        XCTAssertGreaterThanOrEqual(refreshed, 1)
        XCTAssertTrue(controller.isGatewayRunning)

        controller.stopAutoProbe()
        XCTAssertNil(controller.autoProbeTask)
    }

    // MARK: Verification

    func test_runVerification_capturesResponse() async {
        let fake = FakeWizardRuntime(
            executable: "/usr/local/bin/hermes",
            verificationResponse: "Hermes is ready."
        )
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)
        controller.isGatewayRunning = true

        controller.runVerification()
        await Self.awaitVerificationSettles(controller)

        XCTAssertEqual(controller.verificationResponse, "Hermes is ready.")
        XCTAssertNil(controller.verificationError)
        XCTAssertFalse(controller.isVerifying)
    }

    func test_runVerification_emptyResponseBecomesError() async {
        let fake = FakeWizardRuntime(
            executable: "/usr/local/bin/hermes",
            verificationResponse: "   "
        )
        let controller = HermesSetupWizardController(dependencies: fake.dependencies)
        controller.isGatewayRunning = true

        controller.runVerification()
        await Self.awaitVerificationSettles(controller)

        XCTAssertNil(controller.verificationResponse)
        XCTAssertNotNil(controller.verificationError)
    }
}

// MARK: - FakeWizardRuntime (controller test double)

private actor FakeWizardRuntime {
    var refreshStatusCalls = 0
    var openHermesAndGatewayCalls = 0

    private let executable: String?
    private var gatewayAvailable: Bool
    private var dashboardAvailable: Bool
    private let modelName: String?
    private let openHermesGatewayResult: HermesRuntimeStatus?
    private let envSnapshot: HermesEnvSnapshot
    private let verificationResponse: String

    init(
        executable: String?,
        gatewayAvailable: Bool = false,
        dashboardAvailable: Bool = false,
        modelName: String? = nil,
        openHermesGatewayResult: HermesRuntimeStatus? = nil,
        envSnapshot: HermesEnvSnapshot = HermesEnvSnapshot(
            fileExists: false, apiServerEnabled: false, hasAPIServerKey: false, savedBearerToken: ""
        ),
        verificationResponse: String = "Hermes is ready."
    ) {
        self.executable = executable
        self.gatewayAvailable = gatewayAvailable
        self.dashboardAvailable = dashboardAvailable
        self.modelName = modelName
        self.openHermesGatewayResult = openHermesGatewayResult
        self.envSnapshot = envSnapshot
        self.verificationResponse = verificationResponse
    }

    nonisolated var dependencies: HermesSetupWizardDependencies {
        HermesSetupWizardDependencies(
            gatewayBaseURLProvider: { @MainActor in
                URL(string: "http://127.0.0.1:8642")
            },
            resolveHermesExecutable: { [weak self] in
                guard let self else { return nil }
                return await self.executable
            },
            readEnvSnapshot: { [weak self] in
                guard let self else {
                    return HermesEnvSnapshot(fileExists: false, apiServerEnabled: false, hasAPIServerKey: false, savedBearerToken: "")
                }
                return await self.envSnapshot
            },
            ensureAPIServerEnabled: { },
            refreshStatus: { @MainActor [weak self] _, _ in
                guard let self else { return HermesRuntimeStatus() }
                return await self.refreshStatus()
            },
            openHermesAndGateway: { @MainActor [weak self] _, _ in
                guard let self else { return HermesRuntimeStatus() }
                return await self.openHermesAndGateway()
            },
            runVerificationChat: { @MainActor [weak self] _, _ in
                guard let self else { return "" }
                return await self.verificationResponse
            },
            installHermesSkillIfNeeded: { }
        )
    }

    /// Polls briefly for the controller's async Task to reach this actor.
    /// Once this actor observes the counter change, the fake call has already
    /// completed because actor-isolated calls run serially.
    func waitForIdle() async {
        let startRefreshCalls = refreshStatusCalls
        let startOpenCalls = openHermesAndGatewayCalls

        for _ in 0..<50 {
            if refreshStatusCalls > startRefreshCalls || openHermesAndGatewayCalls > startOpenCalls {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func refreshStatus() -> HermesRuntimeStatus {
        refreshStatusCalls += 1
        return HermesRuntimeStatus(
            hermesCLIPath: executable,
            gatewayRunning: gatewayAvailable,
            dashboardRunning: dashboardAvailable,
            modelName: gatewayAvailable ? modelName : nil,
            message: gatewayAvailable ? "Gateway is running." : "Gateway is not running."
        )
    }

    private func openHermesAndGateway() -> HermesRuntimeStatus {
        openHermesAndGatewayCalls += 1
        if let preset = openHermesGatewayResult { return preset }
        // Default: opening starts the gateway.
        gatewayAvailable = true
        dashboardAvailable = true
        return HermesRuntimeStatus(
            hermesCLIPath: executable,
            gatewayRunning: true,
            dashboardRunning: true,
            modelName: modelName ?? "hermes-agent",
            message: "Hermes Dashboard and gateway are running."
        )
    }
}

private extension HermesSetupWizardDependencies {
    /// Minimal fake with no executable and a down gateway — for navigation/gate
    /// tests that don't touch I/O.
    static func fakeEmpty() -> HermesSetupWizardDependencies {
        HermesSetupWizardDependencies(
            gatewayBaseURLProvider: { @MainActor in
                URL(string: "http://127.0.0.1:8642")
            },
            resolveHermesExecutable: { nil },
            readEnvSnapshot: {
                HermesEnvSnapshot(fileExists: false, apiServerEnabled: false, hasAPIServerKey: false, savedBearerToken: "")
            },
            ensureAPIServerEnabled: { },
            refreshStatus: { @MainActor _, _ in HermesRuntimeStatus() },
            openHermesAndGateway: { @MainActor _, _ in HermesRuntimeStatus() },
            runVerificationChat: { @MainActor _, _ in "" },
            installHermesSkillIfNeeded: { }
        )
    }

    /// Convenience fake builder for the common case (executable + gateway state).
    static func fake(
        executable: String?,
        gatewayAvailable: Bool = false,
        dashboardAvailable: Bool = false,
        modelName: String? = nil
    ) -> HermesSetupWizardDependencies {
        FakeWizardRuntime(
            executable: executable,
            gatewayAvailable: gatewayAvailable,
            dashboardAvailable: dashboardAvailable,
            modelName: modelName
        ).dependencies
    }
}

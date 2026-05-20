import Foundation
import XCTest
@testable import OpenBurnBar

@MainActor
final class HermesRuntimeLauncherTests: XCTestCase {

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
            ["gateway", "--accept-hooks", "start"],
            ["dashboard", "--status"],
            ["dashboard", "--status"]
        ])
        XCTAssertEqual(detachedCommands, [["dashboard", "--tui"]])
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
            ["gateway", "--accept-hooks", "start"],
            ["dashboard", "--status"]
        ])
        XCTAssertEqual(detachedCommands, [])
    }

    func test_openHermesAndGateway_installsGatewayWhenStartFails() async {
        let fake = FakeHermesRuntime(
            gatewayAvailable: false,
            dashboardStatusOutput: "",
            failFirstGatewayStart: true
        )
        let launcher = HermesRuntimeLauncher(dependencies: fake.dependencies)

        let status = await launcher.openHermesAndGateway()

        XCTAssertTrue(status.gatewayRunning)
        let commands = await fake.commands
        XCTAssertEqual(Array(commands.prefix(3)), [
            ["gateway", "--accept-hooks", "start"],
            ["gateway", "--accept-hooks", "install", "--force"],
            ["gateway", "--accept-hooks", "start"]
        ])
    }
}

private actor FakeHermesRuntime {
    var commands: [[String]] = []
    var detachedCommands: [[String]] = []

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
                await self?.launchDetached(arguments)
            },
            probeGateway: { [weak self] _, _ in
                guard let self else { return (false, nil) }
                return await self.probeGateway()
            }
        )
    }

    private func runCommand(_ arguments: [String]) throws -> String {
        commands.append(arguments)
        if arguments == ["gateway", "--accept-hooks", "start"] {
            gatewayStartAttempts += 1
            if failFirstGatewayStart && gatewayStartAttempts == 1 {
                throw HermesRuntimeLauncherError.commandFailed(command: "hermes gateway start", detail: "not installed")
            }
            gatewayAvailable = true
            return "Gateway started"
        }
        if arguments == ["gateway", "--accept-hooks", "install", "--force"] {
            return "Gateway installed"
        }
        if arguments == ["dashboard", "--status"] {
            return dashboardStatusOutput
        }
        return ""
    }

    private func launchDetached(_ arguments: [String]) {
        detachedCommands.append(arguments)
        if arguments == ["dashboard", "--tui"] {
            dashboardStatusOutput = "Hermes dashboard running PID 456"
        }
    }

    private func probeGateway() -> (available: Bool, modelName: String?) {
        (gatewayAvailable, gatewayAvailable ? "hermes-agent" : nil)
    }
}

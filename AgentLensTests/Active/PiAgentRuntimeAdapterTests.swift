import Foundation
import XCTest
@testable import OpenBurnBar

@MainActor
final class PiAgentRuntimeAdapterTests: XCTestCase {

    private let baseURL = URL(string: "http://127.0.0.1:8765")!

    func test_refreshStatus_reportsMissingCLI() async {
        let fake = FakePiRuntime(executable: nil)
        let adapter = PiAgentRuntimeAdapter(dependencies: fake.dependencies)

        let status = await adapter.refreshManagedStatus(baseURL: baseURL, bearerToken: nil)

        XCTAssertFalse(status.isReady)
        XCTAssertNil(status.executablePath)
        XCTAssertEqual(adapter.lastError, "Pi CLI is not installed or could not be found in the app PATH.")
        let commands = await fake.commands
        XCTAssertEqual(commands, [])
    }

    func test_openRuntime_startsGatewayAndLaunchesAgentWhenStopped() async {
        let fake = FakePiRuntime(
            gatewayAvailable: false,
            appStatusOutput: ""
        )
        let adapter = PiAgentRuntimeAdapter(dependencies: fake.dependencies)

        let status = await adapter.openManagedRuntime(baseURL: baseURL, bearerToken: nil)

        XCTAssertTrue(status.gatewayRunning)
        XCTAssertTrue(status.appRunning)
        let commands = await fake.commands
        let detached = await fake.detachedCommands
        XCTAssertEqual(commands, [
            ["gateway", "start", "--accept-hooks"],
            ["agent", "status"],
            ["agent", "status"]
        ])
        XCTAssertEqual(detached, [["agent", "start", "--detach"]])
    }

    func test_openRuntime_doesNotDuplicateRunningGatewayOrAgent() async {
        let fake = FakePiRuntime(
            gatewayAvailable: true,
            appStatusOutput: "Pi running PID 1234"
        )
        let adapter = PiAgentRuntimeAdapter(dependencies: fake.dependencies)

        let status = await adapter.openManagedRuntime(baseURL: baseURL, bearerToken: nil)

        XCTAssertTrue(status.gatewayRunning)
        XCTAssertTrue(status.appRunning)
        let commands = await fake.commands
        let detached = await fake.detachedCommands
        XCTAssertEqual(commands, [
            ["agent", "status"],
            ["agent", "status"]
        ])
        XCTAssertEqual(detached, [])
    }

    func test_openRuntime_installsGatewayWhenStartFails() async {
        let fake = FakePiRuntime(
            gatewayAvailable: false,
            appStatusOutput: "",
            failFirstGatewayStart: true
        )
        let adapter = PiAgentRuntimeAdapter(dependencies: fake.dependencies)

        let status = await adapter.openManagedRuntime(baseURL: baseURL, bearerToken: nil)

        XCTAssertTrue(status.gatewayRunning)
        let commands = await fake.commands
        XCTAssertEqual(Array(commands.prefix(3)), [
            ["gateway", "start", "--accept-hooks"],
            ["gateway", "install", "--force", "--accept-hooks"],
            ["gateway", "start", "--accept-hooks"]
        ])
    }

    func test_refreshStatus_fallsBackToSyntheticInstance_whenRedisUnavailable() async {
        let fake = FakePiRuntime(
            gatewayAvailable: true,
            appStatusOutput: "Pi running PID 1"
        )
        let adapter = PiAgentRuntimeAdapter(dependencies: fake.dependencies)

        let status = await adapter.refreshManagedStatus(baseURL: baseURL, bearerToken: nil)

        XCTAssertEqual(status.instances.count, 1)
        XCTAssertEqual(status.instances.first?.id, "default")
        XCTAssertEqual(status.selectedInstanceID, "default")
        XCTAssertNotNil(status.redisStatus)
    }

    func test_refreshStatus_surfacesRedisDiscoveredInstances() async {
        let fake = FakePiRuntime(
            gatewayAvailable: true,
            appStatusOutput: "Pi running PID 1",
            redisInstances: [
                ManagedAgentInstance(id: "alpha", displayName: "Alpha", isOnline: true),
                ManagedAgentInstance(id: "beta", displayName: "Beta", isOnline: false)
            ]
        )
        let adapter = PiAgentRuntimeAdapter(
            dependencies: fake.dependencies,
            preferredInstanceID: "beta"
        )

        let status = await adapter.refreshManagedStatus(baseURL: baseURL, bearerToken: nil)

        XCTAssertEqual(status.instances.count, 2)
        XCTAssertEqual(status.selectedInstanceID, "beta")
        XCTAssertEqual(status.instances.first?.id, "alpha")
    }
}

private actor FakePiRuntime {
    var commands: [[String]] = []
    var detachedCommands: [[String]] = []

    private let executable: String?
    private var gatewayAvailable: Bool
    private var appStatusOutput: String
    private var failFirstGatewayStart: Bool
    private var gatewayStartAttempts = 0
    private let redisInstances: [ManagedAgentInstance]

    init(
        executable: String? = "/usr/local/bin/pi",
        gatewayAvailable: Bool = false,
        appStatusOutput: String = "",
        failFirstGatewayStart: Bool = false,
        redisInstances: [ManagedAgentInstance] = []
    ) {
        self.executable = executable
        self.gatewayAvailable = gatewayAvailable
        self.appStatusOutput = appStatusOutput
        self.failFirstGatewayStart = failFirstGatewayStart
        self.redisInstances = redisInstances
    }

    nonisolated var dependencies: PiAgentRuntimeAdapterDependencies {
        PiAgentRuntimeAdapterDependencies(
            resolvePiExecutable: { [weak self] in
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
            },
            redisDiscovery: StubRedisDiscovery(instances: redisInstances),
            commandProfile: .live
        )
    }

    private func runCommand(_ arguments: [String]) throws -> String {
        commands.append(arguments)
        if arguments == ["gateway", "start", "--accept-hooks"] {
            gatewayStartAttempts += 1
            if failFirstGatewayStart && gatewayStartAttempts == 1 {
                throw ManagedRuntimeProcessRunner.CommandFailedError(
                    command: "pi gateway start",
                    detail: "not installed"
                )
            }
            gatewayAvailable = true
            return "Gateway started"
        }
        if arguments == ["gateway", "install", "--force", "--accept-hooks"] {
            return "Gateway installed"
        }
        if arguments == ["agent", "status"] {
            return appStatusOutput
        }
        return ""
    }

    private func launchDetached(_ arguments: [String]) {
        detachedCommands.append(arguments)
        if arguments == ["agent", "start", "--detach"] {
            appStatusOutput = "Pi running PID 9999"
        }
    }

    private func probeGateway() -> (available: Bool, modelName: String?) {
        (gatewayAvailable, gatewayAvailable ? "pi" : nil)
    }
}

private struct StubRedisDiscovery: PiAgentRedisDiscovery {
    let instances: [ManagedAgentInstance]

    func snapshot(redisURL: URL?, gatewayBaseURL: URL, bearerToken: String?) async -> PiAgentRedisSnapshot {
        guard !instances.isEmpty else {
            return PiAgentRedisSnapshot(
                available: false,
                statusMessage: "Pi gateway has no Redis-backed instance registry.",
                instances: []
            )
        }
        return PiAgentRedisSnapshot(
            available: true,
            statusMessage: "Pi Redis registry online — \(instances.count) instance\(instances.count == 1 ? "" : "s").",
            instances: instances
        )
    }
}

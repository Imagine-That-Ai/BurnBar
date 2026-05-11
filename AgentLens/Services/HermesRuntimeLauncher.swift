import Foundation

struct HermesRuntimeStatus: Equatable {
    var hermesCLIPath: String?
    var gatewayRunning: Bool = false
    var dashboardRunning: Bool = false
    var modelName: String?
    var message: String = "Hermes has not been checked yet."

    var isReady: Bool {
        hermesCLIPath != nil && gatewayRunning
    }
}

enum HermesRuntimeLauncherError: Error, LocalizedError, Equatable {
    case hermesCLIUnavailable
    case commandFailed(command: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .hermesCLIUnavailable:
            return "Hermes CLI is not installed or could not be found in the app PATH."
        case .commandFailed(let command, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "\(command) failed." }
            return "\(command) failed: \(trimmed)"
        }
    }
}

struct HermesRuntimeLauncherDependencies: Sendable {
    var resolveHermesExecutable: @Sendable () async -> String?
    var runCommand: @Sendable (_ executable: String, _ arguments: [String]) async throws -> String
    var launchDetached: @Sendable (_ executable: String, _ arguments: [String]) async throws -> Void
    var probeGateway: @Sendable (_ baseURL: URL, _ bearerToken: String?) async -> (available: Bool, modelName: String?)

    static let live = HermesRuntimeLauncherDependencies(
        resolveHermesExecutable: {
            await CLIExecutableResolver().resolveExecutable(named: "hermes")
        },
        runCommand: { executable, arguments in
            try await HermesRuntimeProcessRunner.run(executable: executable, arguments: arguments)
        },
        launchDetached: { executable, arguments in
            try await HermesRuntimeProcessRunner.launchDetached(executable: executable, arguments: arguments)
        },
        probeGateway: { baseURL, bearerToken in
            await OpenAICompatibleModelProbe.probeWithModel(baseURL: baseURL, bearerToken: bearerToken)
        }
    )
}

extension HermesRuntimeLauncher: ManagedAgentRuntimeAdapter {
    var kind: ManagedAgentRuntimeKind { .hermes }

    /// Generic snapshot derived from the Hermes-specific `status` so the
    /// Settings UI and `HermesRuntimeGate` can render Hermes through the same
    /// `ManagedAgentRuntimeAdapter` surface used by Pi.
    var managedStatus: ManagedAgentRuntimeStatus {
        var snapshot = ManagedAgentRuntimeStatus(
            executablePath: status.hermesCLIPath,
            gatewayRunning: status.gatewayRunning,
            appRunning: status.dashboardRunning,
            modelName: status.modelName,
            redisStatus: nil,
            selectedInstanceID: status.gatewayRunning ? "default" : nil,
            message: status.message
        )
        if status.gatewayRunning {
            snapshot.instances = [
                ManagedAgentInstance(
                    id: "default",
                    displayName: "Default",
                    isOnline: status.gatewayRunning,
                    activeSessionID: nil,
                    gatewayBaseURL: nil
                )
            ]
        }
        return snapshot
    }

    @discardableResult
    func refreshManagedStatus(
        baseURL: URL,
        bearerToken: String?
    ) async -> ManagedAgentRuntimeStatus {
        _ = await refreshStatus(baseURL: baseURL, bearerToken: bearerToken)
        return managedStatus
    }

    @discardableResult
    func openManagedRuntime(
        baseURL: URL,
        bearerToken: String?
    ) async -> ManagedAgentRuntimeStatus {
        _ = await openHermesAndGateway(baseURL: baseURL, bearerToken: bearerToken)
        return managedStatus
    }
}

@Observable
@MainActor
final class HermesRuntimeLauncher {
    private let dependencies: HermesRuntimeLauncherDependencies

    var status = HermesRuntimeStatus()
    var isBusy = false
    var lastError: String?

    init(dependencies: HermesRuntimeLauncherDependencies = .live) {
        self.dependencies = dependencies
    }

    func refreshStatus(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        bearerToken: String? = nil
    ) async -> HermesRuntimeStatus {
        isBusy = true
        defer { isBusy = false }

        guard let executable = await dependencies.resolveHermesExecutable() else {
            let next = HermesRuntimeStatus(
                hermesCLIPath: nil,
                gatewayRunning: false,
                dashboardRunning: false,
                modelName: nil,
                message: HermesRuntimeLauncherError.hermesCLIUnavailable.localizedDescription
            )
            status = next
            lastError = next.message
            return next
        }

        async let gatewayProbe = dependencies.probeGateway(baseURL, bearerToken)
        async let dashboard = dashboardIsRunning(executable: executable)
        let gateway = await gatewayProbe
        let dashboardRunning = await dashboard
        let next = HermesRuntimeStatus(
            hermesCLIPath: executable,
            gatewayRunning: gateway.available,
            dashboardRunning: dashboardRunning,
            modelName: gateway.modelName,
            message: statusMessage(gatewayRunning: gateway.available, dashboardRunning: dashboardRunning, modelName: gateway.modelName)
        )
        status = next
        lastError = nil
        return next
    }

    func openHermesAndGateway(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        bearerToken: String? = nil
    ) async -> HermesRuntimeStatus {
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        guard let executable = await dependencies.resolveHermesExecutable() else {
            let message = HermesRuntimeLauncherError.hermesCLIUnavailable.localizedDescription
            let next = HermesRuntimeStatus(message: message)
            status = next
            lastError = message
            return next
        }

        do {
            let gatewayProbe = await dependencies.probeGateway(baseURL, bearerToken)
            if !gatewayProbe.available {
                do {
                    _ = try await dependencies.runCommand(executable, ["gateway", "--accept-hooks", "start"])
                } catch {
                    _ = try await dependencies.runCommand(executable, ["gateway", "--accept-hooks", "install", "--force"])
                    _ = try await dependencies.runCommand(executable, ["gateway", "--accept-hooks", "start"])
                }
            }

            if !(await dashboardIsRunning(executable: executable)) {
                try await dependencies.launchDetached(executable, ["dashboard", "--tui"])
            }

            return await refreshStatus(baseURL: baseURL, bearerToken: bearerToken)
        } catch {
            let detail = error.localizedDescription
            let next = HermesRuntimeStatus(
                hermesCLIPath: executable,
                gatewayRunning: false,
                dashboardRunning: false,
                modelName: nil,
                message: detail
            )
            status = next
            lastError = detail
            return next
        }
    }

    private func dashboardIsRunning(executable: String) async -> Bool {
        do {
            let output = try await dependencies.runCommand(executable, ["dashboard", "--status"])
            return output.range(of: "running", options: .caseInsensitive) != nil
                || output.range(of: "PID", options: .caseInsensitive) != nil
        } catch {
            return false
        }
    }

    private func statusMessage(gatewayRunning: Bool, dashboardRunning: Bool, modelName: String?) -> String {
        if gatewayRunning && dashboardRunning {
            if let modelName, !modelName.isEmpty {
                return "Hermes Dashboard and gateway are running. Model: \(modelName)."
            }
            return "Hermes Dashboard and gateway are running."
        }
        if gatewayRunning {
            if let modelName, !modelName.isEmpty {
                return "Hermes gateway is running. Model: \(modelName)."
            }
            return "Hermes gateway is running."
        }
        if dashboardRunning {
            return "Hermes Dashboard is running, but the local gateway is not reachable yet."
        }
        return "Hermes Dashboard and gateway are not running."
    }
}

enum HermesRuntimeProcessRunner {
    static func run(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
            process.standardInput = FileHandle.nullDevice

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let command = ([executable] + arguments).joined(separator: " ")
                throw HermesRuntimeLauncherError.commandFailed(
                    command: command,
                    detail: error.isEmpty ? output : error
                )
            }
            return output.isEmpty ? error : output
        }.value
    }

    static func launchDetached(executable: String, arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }.value
    }
}

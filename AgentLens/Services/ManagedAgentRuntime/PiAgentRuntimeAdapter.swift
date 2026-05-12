import Foundation

// MARK: - Pi Agent Runtime Adapter Dependencies

struct PiAgentRuntimeAdapterDependencies: Sendable {
    var resolvePiExecutable: @Sendable () async -> String?
    var runCommand: @Sendable (_ executable: String, _ arguments: [String]) async throws -> String
    var launchDetached: @Sendable (_ executable: String, _ arguments: [String]) async throws -> Void
    var probeGateway: @Sendable (_ baseURL: URL, _ bearerToken: String?) async -> (available: Bool, modelName: String?)
    var redisDiscovery: PiAgentRedisDiscovery
    var commandProfile: PiAgentCommandProfile

    static let live = PiAgentRuntimeAdapterDependencies(
        resolvePiExecutable: {
            await CLIExecutableResolver().resolveExecutable(named: "pi")
        },
        runCommand: { executable, arguments in
            try await ManagedRuntimeProcessRunner.run(executable: executable, arguments: arguments)
        },
        launchDetached: { executable, arguments in
            try await ManagedRuntimeProcessRunner.launchDetached(executable: executable, arguments: arguments)
        },
        probeGateway: { baseURL, bearerToken in
            await OpenAICompatibleModelProbe.probeWithModel(baseURL: baseURL, bearerToken: bearerToken)
        },
        redisDiscovery: PiAgentRedisHTTPDiscovery(),
        commandProfile: .live
    )
}

// MARK: - Pi Agent Runtime Adapter

@Observable
@MainActor
final class PiAgentRuntimeAdapter: ManagedAgentRuntimeAdapter {
    let kind: ManagedAgentRuntimeKind = .piAgent

    var managedStatus = ManagedAgentRuntimeStatus(message: "Pi has not been checked yet.")
    var isBusy = false
    var lastError: String?

    private let dependencies: PiAgentRuntimeAdapterDependencies
    /// Currently selected instance ID, persisted by the caller (Settings).
    var preferredInstanceID: String?
    /// Optional Redis URL configured in Settings. Forwarded to the discovery
    /// adapter so the gateway can resolve the right registry.
    var redisURL: URL?

    init(
        dependencies: PiAgentRuntimeAdapterDependencies = .live,
        preferredInstanceID: String? = nil,
        redisURL: URL? = nil
    ) {
        self.dependencies = dependencies
        self.preferredInstanceID = preferredInstanceID
        self.redisURL = redisURL
    }

    @discardableResult
    func refreshManagedStatus(
        baseURL: URL,
        bearerToken: String?
    ) async -> ManagedAgentRuntimeStatus {
        isBusy = true
        defer { isBusy = false }

        guard let executable = await dependencies.resolvePiExecutable() else {
            let next = ManagedAgentRuntimeStatus(
                executablePath: nil,
                gatewayRunning: false,
                appRunning: false,
                modelName: nil,
                redisStatus: nil,
                selectedInstanceID: nil,
                instances: [],
                message: "Pi CLI is not installed or could not be found in the app PATH."
            )
            managedStatus = next
            lastError = next.message
            return next
        }

        async let gatewayProbe = dependencies.probeGateway(baseURL, bearerToken)
        async let appProbe = appIsRunning(executable: executable)
        async let redis = dependencies.redisDiscovery.snapshot(
            redisURL: redisURL,
            gatewayBaseURL: baseURL,
            bearerToken: bearerToken
        )

        let gateway = await gatewayProbe
        let appRunning = await appProbe
        let redisSnapshot = await redis

        let instances = composeInstances(
            redis: redisSnapshot,
            gatewayRunning: gateway.available,
            baseURL: baseURL
        )
        let selected = resolveSelectedInstance(from: instances)

        let next = ManagedAgentRuntimeStatus(
            executablePath: executable,
            gatewayRunning: gateway.available,
            appRunning: appRunning,
            modelName: gateway.modelName,
            redisStatus: redisSnapshot.statusMessage,
            selectedInstanceID: selected?.id,
            instances: instances,
            message: statusMessage(
                gatewayRunning: gateway.available,
                appRunning: appRunning,
                modelName: gateway.modelName,
                redis: redisSnapshot,
                selected: selected
            )
        )
        managedStatus = next
        lastError = nil
        return next
    }

    @discardableResult
    func openManagedRuntime(
        baseURL: URL,
        bearerToken: String?
    ) async -> ManagedAgentRuntimeStatus {
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        guard let executable = await dependencies.resolvePiExecutable() else {
            let message = "Pi CLI is not installed or could not be found in the app PATH."
            let next = ManagedAgentRuntimeStatus(message: message)
            managedStatus = next
            lastError = message
            return next
        }

        do {
            // Step 1: ensure the gateway is up.
            let gatewayProbe = await dependencies.probeGateway(baseURL, bearerToken)
            if !gatewayProbe.available {
                do {
                    _ = try await dependencies.runCommand(
                        executable,
                        dependencies.commandProfile.startGatewayArguments
                    )
                } catch {
                    _ = try await dependencies.runCommand(
                        executable,
                        dependencies.commandProfile.installGatewayArguments
                    )
                    _ = try await dependencies.runCommand(
                        executable,
                        dependencies.commandProfile.startGatewayArguments
                    )
                }
            }

            // Step 2: ensure the Pi app/instance is up. Detached, like Hermes
            // Dashboard.
            if !(await appIsRunning(executable: executable)) {
                try await dependencies.launchDetached(
                    executable,
                    dependencies.commandProfile.launchAppArguments
                )
            }

            return await refreshManagedStatus(baseURL: baseURL, bearerToken: bearerToken)
        } catch {
            let detail = error.localizedDescription
            let next = ManagedAgentRuntimeStatus(
                executablePath: executable,
                gatewayRunning: false,
                appRunning: false,
                modelName: nil,
                redisStatus: nil,
                selectedInstanceID: nil,
                instances: [],
                message: detail
            )
            managedStatus = next
            lastError = detail
            return next
        }
    }

    // MARK: - Helpers

    private func appIsRunning(executable: String) async -> Bool {
        do {
            let output = try await dependencies.runCommand(
                executable,
                dependencies.commandProfile.appStatusArguments
            )
            return output.range(of: "running", options: .caseInsensitive) != nil
                || output.range(of: "PID", options: .caseInsensitive) != nil
        } catch {
            return false
        }
    }

    private func composeInstances(
        redis: PiAgentRedisSnapshot,
        gatewayRunning: Bool,
        baseURL: URL
    ) -> [ManagedAgentInstance] {
        if redis.available, !redis.instances.isEmpty {
            return redis.instances
        }
        guard gatewayRunning else { return [] }
        // Single synthetic instance so the picker always offers something
        // when the gateway is alive but Redis isn't wired up.
        return [
            ManagedAgentInstance(
                id: "default",
                displayName: "Default",
                isOnline: true,
                activeSessionID: nil,
                gatewayBaseURL: baseURL
            )
        ]
    }

    private func resolveSelectedInstance(from instances: [ManagedAgentInstance]) -> ManagedAgentInstance? {
        if let preferredInstanceID,
           let match = instances.first(where: { $0.id == preferredInstanceID }) {
            return match
        }
        return instances.first
    }

    private func statusMessage(
        gatewayRunning: Bool,
        appRunning: Bool,
        modelName: String?,
        redis: PiAgentRedisSnapshot,
        selected: ManagedAgentInstance?
    ) -> String {
        if gatewayRunning && appRunning {
            var head = "Pi agent and gateway are running."
            if let modelName, !modelName.isEmpty {
                head = "Pi agent and gateway are running. Model: \(modelName)."
            }
            if let selected {
                head += " Active instance: \(selected.displayName)."
            }
            if redis.available, redis.instances.count > 1 {
                head += " Redis registry reports \(redis.instances.count) instances."
            }
            return head
        }
        if gatewayRunning {
            var head = "Pi gateway is running."
            if let modelName, !modelName.isEmpty {
                head = "Pi gateway is running. Model: \(modelName)."
            }
            return head
        }
        if appRunning {
            return "Pi agent is running, but the local gateway is not reachable yet."
        }
        return "Pi agent and gateway are not running."
    }
}

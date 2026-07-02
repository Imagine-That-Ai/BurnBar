import Foundation

struct HermesRuntimeStatus: Equatable {
    var hermesCLIPath: String?
    var gatewayRunning: Bool = false
    /// The gateway answered the catalog probe with 401/403: it is running, but
    /// the API key OpenBurnBar presented was rejected. Fixing the key — not
    /// (re)launching the gateway — is the remedy.
    var authRejected: Bool = false
    var dashboardRunning: Bool = false
    var modelName: String?
    var message: String = "Hermes has not been checked yet."

    var isReady: Bool {
        hermesCLIPath != nil && gatewayRunning && !authRejected
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
    var probeGateway: @Sendable (_ baseURL: URL, _ bearerToken: String?) async -> (available: Bool, authRejected: Bool, modelName: String?)
    var ensureAPIServerEnabled: @Sendable () async throws -> Void
    var readAPIServerKey: @Sendable () async -> String?

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
            await OpenAICompatibleModelProbe.probeWithModelAuth(
                baseURL: baseURL,
                bearerToken: bearerToken,
                timeout: 8
            )
        },
        ensureAPIServerEnabled: {
            try await HermesEnvironmentFile.ensureAPIServerEnabled()
        },
        readAPIServerKey: {
            await HermesEnvironmentFile.readAPIServerKey()
        }
    )
}

extension HermesRuntimeLauncher: ManagedAgentRuntimeAdapter {
    var kind: ManagedAgentRuntimeKind { .hermes }

    /// Generic snapshot derived from the Hermes-specific `status` so the
    /// Settings UI and `HermesRuntimeGate` can render Hermes through the same
    /// `ManagedAgentRuntimeAdapter` surface used by Pi.
    var managedStatus: ManagedAgentRuntimeStatus {
        let usableGatewayRunning = status.gatewayRunning && !status.authRejected
        var snapshot = ManagedAgentRuntimeStatus(
            executablePath: status.hermesCLIPath,
            gatewayRunning: usableGatewayRunning,
            appRunning: status.dashboardRunning,
            modelName: status.modelName,
            redisStatus: nil,
            selectedInstanceID: usableGatewayRunning ? "default" : nil,
            message: status.message
        )
        if usableGatewayRunning {
            snapshot.instances = [
                ManagedAgentInstance(
                    id: "default",
                    displayName: "Default",
                    isOnline: true,
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

        let effectiveBearerToken = await resolvedBearerToken(bearerToken)
        async let gatewayProbe = dependencies.probeGateway(baseURL, effectiveBearerToken)
        async let dashboard = dashboardIsRunning(executable: executable)
        let gateway = await gatewayProbe
        let dashboardRunning = await dashboard
        // A 401/403 catalog answer means the gateway IS running (something
        // answered) — report it as such so Settings tells the truth, with the
        // key called out as the thing to fix.
        let gatewayRunning = gateway.available || gateway.authRejected
        let next = HermesRuntimeStatus(
            hermesCLIPath: executable,
            gatewayRunning: gatewayRunning,
            authRejected: gateway.authRejected,
            dashboardRunning: dashboardRunning,
            modelName: gateway.modelName,
            message: statusMessage(
                gatewayRunning: gatewayRunning,
                authRejected: gateway.authRejected,
                dashboardRunning: dashboardRunning,
                modelName: gateway.modelName
            )
        )
        status = next
        lastError = nil
        return next
    }

    func openHermesAndGateway(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        bearerToken: String? = nil,
        launchDashboard: Bool = true
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
            try await dependencies.ensureAPIServerEnabled()
            let effectiveBearerToken = await resolvedBearerToken(bearerToken)
            let gatewayProbe = await dependencies.probeGateway(baseURL, effectiveBearerToken)
            if gatewayProbe.authRejected {
                // A gateway is already answering on this port but rejected the
                // key — it is running with a stale API_SERVER_KEY (e.g. the
                // .env was regenerated after it started). `gateway run
                // --replace` restarts it in place with the current .env; a
                // plain `gateway run` would fork a duplicate beside it.
                try await dependencies.launchDetached(executable, ["gateway", "run", "--replace"])
            } else if !gatewayProbe.available {
                do {
                    try await dependencies.launchDetached(executable, ["gateway", "run"])
                } catch {
                    _ = try await dependencies.runCommand(executable, ["gateway", "--accept-hooks", "install", "--force"])
                    try await dependencies.launchDetached(executable, ["gateway", "run"])
                }
            }

            if launchDashboard, !(await dashboardIsRunning(executable: executable)) {
                try await dependencies.launchDetached(executable, ["dashboard", "--tui"])
            }

            return await refreshStatus(baseURL: baseURL, bearerToken: effectiveBearerToken)
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
            AppLogger.network.error("hermes_runtime_health_check_failed", metadata: ["error": error.localizedDescription])
            return false
        }
    }

    private func resolvedBearerToken(_ explicitToken: String?) async -> String? {
        if let explicitToken,
           explicitToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return explicitToken
        }
        return await dependencies.readAPIServerKey()
    }

    private func statusMessage(gatewayRunning: Bool, authRejected: Bool, dashboardRunning: Bool, modelName: String?) -> String {
        if authRejected {
            return Self.authRejectedStatusMessage
        }
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

    /// Shown by Settings (and asserted by tests) when the gateway is up but the
    /// key is wrong — the one state where "Open Hermes + Gateway" cannot help.
    static let authRejectedStatusMessage = "Hermes gateway is running, but it rejected this app's API key. Update the Bearer Token below to match API_SERVER_KEY in ~/.hermes/.env — or clear it to reuse the local key automatically — then check health again."
}

enum HermesEnvironmentFile {
    private static var envURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent(".env")
    }

    /// Blocking file I/O runs off the main actor: this is a `nonisolated`
    /// `async` function, so main-actor callers leave it at the `await` (SE-0338).
    static func ensureAPIServerEnabled() async throws {
        try ensureAPIServerEnabled(at: envURL)
    }

    static func ensureAPIServerEnabled(
        at url: URL,
        generateKey: () throws -> String = { try OpenBurnBarSecureToken.randomBase64URL() }
    ) throws {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        var lines: [String] = []
        if fileManager.fileExists(atPath: url.path) {
            let content = try String(contentsOf: url, encoding: .utf8)
            lines = content.components(separatedBy: .newlines)
        }

        var replacedEnabled = false
        var hasUsableKey = false
        var firstKeyLineIndex: Int?

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("API_SERVER_ENABLED=") {
                replacedEnabled = true
                lines[index] = "API_SERVER_ENABLED=true"
            }
            if trimmed.hasPrefix("API_SERVER_KEY=") {
                if firstKeyLineIndex == nil {
                    firstKeyLineIndex = index
                }
                let rawValue = String(trimmed.dropFirst("API_SERVER_KEY=".count))
                if !normalizedEnvValue(rawValue).isEmpty {
                    hasUsableKey = true
                }
            }
        }
        if !replacedEnabled {
            if lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("API_SERVER_ENABLED=true")
        }
        if !hasUsableKey {
            let keyLine = "API_SERVER_KEY=\(try generateKey())"
            if let firstKeyLineIndex {
                lines[firstKeyLineIndex] = keyLine
            } else {
                if lines.last?.isEmpty == false {
                    lines.append("")
                }
                lines.append(keyLine)
            }
        }

        let output = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        try output.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads off the main actor (`nonisolated` `async`, SE-0338).
    static func readAPIServerKey() async -> String? {
        // Delegate to the absent-vs-fault-aware sync helper. No Task.detached:
        // the helper is a `nonisolated` static (SE-0338), so this async entry
        // point runs it off the main actor without reintroducing detached-task debt.
        readAPIServerKey(at: envURL)
    }

    /// Reads `API_SERVER_KEY` from the Hermes `.env` file.
    ///
    /// The returned key becomes the bearer token the app uses to authenticate to
    /// the local Hermes gateway (`resolvedBearerToken(_:)`), so a silent read
    /// failure cannot be allowed to masquerade as "no key configured": a missing
    /// file legitimately means no key, but a file that *exists* yet cannot be read
    /// (permissions, corruption, an I/O fault) is a real failure that must be
    /// observable instead of silently collapsing the gateway call to an
    /// unauthenticated request. We therefore separate the absent-file case (return
    /// `nil` quietly) from a genuine read fault (log via `silently`, still return
    /// `nil` so callers degrade exactly as before — but now the fault surfaces).
    static func readAPIServerKey(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No `.env` yet: there is genuinely no configured key. Quiet skip.
            return nil
        }
        guard let content = AppLogger.network.silently(
            "hermes_api_server_key_read_failed",
            try String(contentsOf: url, encoding: .utf8) as String?,
            fallback: nil
        ) else {
            return nil
        }
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("API_SERVER_KEY=") else { continue }
            let value = normalizedEnvValue(String(line.dropFirst("API_SERVER_KEY=".count)))
            guard !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func normalizedEnvValue(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HermesRuntimeProcessRunner {
    /// Runs off the main actor (`nonisolated` `async`, SE-0338); cancellation
    /// propagates from the awaiting task. Do not reintroduce a detached task.
    static func run(executable: String, arguments: [String]) async throws -> String {
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
    }

    /// Runs off the main actor (`nonisolated` `async`, SE-0338).
    static func launchDetached(executable: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

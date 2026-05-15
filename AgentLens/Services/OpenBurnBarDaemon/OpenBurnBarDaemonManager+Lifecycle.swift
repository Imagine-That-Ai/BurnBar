import Foundation
import OpenBurnBarCore

// MARK: - TODO(per-user-models)
//
// Mobile's `OpenClawService` polls `http://127.0.0.1:18789/v1/models` for
// OpenClaw model discovery and falls back to the bundled catalog when the
// endpoint isn't there. To make mobile's OpenClaw picker fully truthful
// per-user, the daemon (or a co-running OpenClaw binary) should serve an
// OpenAI-compatible `/v1/models` envelope that unions:
//   1. Ollama's `http://127.0.0.1:11434/api/tags` — installed local models.
//   2. The user's `ProviderAccountStore` entries — cloud routes OpenClaw
//      is configured to relay through.
//   3. (Optional) the website's `models.json` for display-name enrichment.
// See `OpenBurnBarMobile/Services/OpenClawService.swift` for the consumer.

extension OpenBurnBarDaemonManager {

    var launchctlDomain: String {
        "gui/\(getuid())"
    }

    var isInstalled: Bool {
        dependencies.fileManager.fileExists(atPath: paths.launchAgentPlistURL.path)
            || dependencies.fileManager.fileExists(atPath: paths.installedBinaryURL.path)
    }

    func installAndStart() async {
        await performBusyWork {
            try installFilesIfNeeded()
            try writeLaunchAgentPlist()
            try bootoutIfNeeded()
            try runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
            try runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"])
            supervisionState = OpenBurnBarDaemonSupervisor.resetAfterRepair()
            try await awaitHealthy()
        }
    }

    func repair() async {
        await performBusyWork {
            try installFilesIfNeeded()
            try writeLaunchAgentPlist()
            try bootoutIfNeeded()
            try runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
            try runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"])
            supervisionState = OpenBurnBarDaemonSupervisor.resetAfterRepair()
            try await awaitHealthy()
        }
    }

    func uninstall() async {
        await performBusyWork {
            try bootoutIfNeeded()
            if dependencies.fileManager.fileExists(atPath: paths.launchAgentPlistURL.path) {
                try dependencies.fileManager.removeItem(at: paths.launchAgentPlistURL)
            }
            if dependencies.fileManager.fileExists(atPath: paths.installedBinaryURL.path) {
                try dependencies.fileManager.removeItem(at: paths.installedBinaryURL)
            }
            if dependencies.fileManager.fileExists(atPath: paths.socketURL.path) {
                try dependencies.fileManager.removeItem(at: paths.socketURL)
            }
            status = .notInstalled
            lastError = nil
        }
    }

    func installFilesIfNeeded() throws {
        try dependencies.fileManager.createDirectory(at: paths.daemonDirectory, withIntermediateDirectories: true)
        try dependencies.fileManager.createDirectory(
            at: paths.launchAgentPlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sourceBinaryURL = dependencies.resolveDaemonBinary() ?? paths.installedBinaryURL
        guard dependencies.fileManager.isExecutableFile(atPath: sourceBinaryURL.path) else {
            throw OpenBurnBarDaemonManagerError.daemonBinaryUnavailable
        }

        if sourceBinaryURL.standardizedFileURL != paths.installedBinaryURL.standardizedFileURL {
            if dependencies.fileManager.fileExists(atPath: paths.installedBinaryURL.path) {
                try dependencies.fileManager.removeItem(at: paths.installedBinaryURL)
            }
            try dependencies.fileManager.copyItem(at: sourceBinaryURL, to: paths.installedBinaryURL)
            try dependencies.fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: paths.installedBinaryURL.path
            )
        }

        // Copy the OpenBurnBarCore resource bundle next to the daemon binary so that
        // SPM's Bundle.module (which checks Bundle.main.bundleURL for CLI tools)
        // can find it at runtime.
        let installedBundleURL = paths.daemonDirectory.appendingPathComponent(Self.resourceBundleName)
        if let sourceBundleURL = OpenBurnBarDaemonBinaryResolver.resolveResourceBundle(
            nearBinaryURL: sourceBinaryURL,
            appBundleURL: Bundle.main.bundleURL,
            fileManager: dependencies.fileManager
        ), sourceBundleURL.standardizedFileURL != installedBundleURL.standardizedFileURL {
            if dependencies.fileManager.fileExists(atPath: installedBundleURL.path) {
                try dependencies.fileManager.removeItem(at: installedBundleURL)
            }
            try dependencies.fileManager.copyItem(at: sourceBundleURL, to: installedBundleURL)
        }

        guard dependencies.fileManager.fileExists(atPath: installedBundleURL.path) else {
            throw OpenBurnBarDaemonManagerError.daemonResourceBundleUnavailable(
                expectedPath: installedBundleURL.path
            )
        }
    }

    func writeLaunchAgentPlist() throws {
        let indexDbPath = OpenBurnBarAppPaths.live(fileManager: dependencies.fileManager).databaseURL.path
        let daemonSocketAuthToken = try rotateDaemonSocketAuthToken()

        // SECURITY: Pass secrets via EnvironmentVariables, not ProgramArguments.
        // CLI arguments are visible to any local user via `ps aux`, so the auth
        // token and gateway auth token must be passed as environment variables
        // which are only visible to processes in the same Mach bootstrap context.
        var programArguments = [
            paths.installedBinaryURL.path,
            "--socket-path", paths.socketURL.path,
            "--index-database-path", indexDbPath
        ]

        var environmentVariables: [String: String] = [
            "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": daemonSocketAuthToken
        ]

        // Propagate Sentry DSN to the daemon so crash reports are captured.
        #if canImport(Sentry)
        if let sentryDSN = Bundle.main.object(forInfoDictionaryKey: "sentry.dsn") as? String,
           !sentryDSN.trimmingCharacters(in: .whitespaces).isEmpty {
            environmentVariables["OPENBURNBAR_SENTRY_DSN"] = sentryDSN
        }
        #endif

        let settings = settingsManager
        if settings.gatewayEnabled {
            programArguments.append(contentsOf: ["--gateway-enable"])
            programArguments.append(contentsOf: ["--gateway-host", settings.gatewayHost.isEmpty ? "127.0.0.1" : settings.gatewayHost])
            programArguments.append(contentsOf: ["--gateway-port", "\(settings.gatewayPort > 0 ? settings.gatewayPort : 8317)"])
            let gatewayAuthToken = settings.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gatewayAuthToken.isEmpty {
                environmentVariables["OPENBURNBAR_GATEWAY_AUTH_TOKEN"] = gatewayAuthToken
            }
        }

        let plist: [String: Any] = [
            "Label": OpenBurnBarDaemonRuntimePaths.launchAgentLabel,
            "ProgramArguments": programArguments,
            "EnvironmentVariables": environmentVariables,
            "RunAtLoad": true,
            "KeepAlive": true,
            "WorkingDirectory": paths.daemonDirectory.path,
            "StandardOutPath": paths.logURL.path,
            "StandardErrorPath": paths.logURL.path
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: paths.launchAgentPlistURL, options: .atomic)
        try dependencies.fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.launchAgentPlistURL.path
        )
    }

    /// Always rotates the daemon socket auth token on daemon reinstall.
    /// This invalidates any previously leaked token without requiring coordination.
    func rotateDaemonSocketAuthToken() throws -> String {
        let generatedToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            try Self.controllerRuntimeSecrets.set(generatedToken, for: Self.daemonSocketAuthTokenAccount)
            return generatedToken
        } catch {
            throw OpenBurnBarDaemonManagerError.daemonSocketAuthTokenUnavailable
        }
    }

    func bootoutIfNeeded() throws {
        do {
            _ = try dependencies.runProcess("/bin/launchctl", ["bootout", launchctlDomain, paths.launchAgentPlistURL.path])
        } catch {
            // Ignore if the service was not loaded yet.
        }
    }

    func runLaunchctl(_ arguments: [String]) throws {
        do {
            _ = try dependencies.runProcess("/bin/launchctl", arguments)
        } catch {
            throw OpenBurnBarDaemonManagerError.launchctlFailed(error.localizedDescription)
        }
    }

    func awaitHealthy(timeoutSeconds: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let socketURL = paths.socketURL
        while Date() < deadline {
            if let response = try? await daemonRPC({
                try OpenBurnBarDaemonSocketClient.health(at: socketURL)
            }),
               response.ok,
               response.protocolVersion == BurnBarProtocolVersion.current {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw OpenBurnBarDaemonManagerError.timedOutWaitingForHealth(
            logTail: daemonLogTailForDiagnostics(),
            logFilePath: paths.logURL.path
        )
    }
}

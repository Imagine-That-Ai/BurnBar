import Foundation
import OpenBurnBarCore

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
        var programArguments = [
            paths.installedBinaryURL.path,
            "--socket-path", paths.socketURL.path,
            "--index-database-path", indexDbPath,
            "--socket-auth-token", daemonSocketAuthToken
        ]

        let settings = settingsManager
        if settings.gatewayEnabled {
            programArguments.append(contentsOf: ["--gateway-enable"])
            programArguments.append(contentsOf: ["--gateway-host", settings.gatewayHost.isEmpty ? "127.0.0.1" : settings.gatewayHost])
            programArguments.append(contentsOf: ["--gateway-port", "\(settings.gatewayPort > 0 ? settings.gatewayPort : 8317)"])
            let gatewayAuthToken = settings.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gatewayAuthToken.isEmpty {
                programArguments.append(contentsOf: ["--gateway-auth-token", gatewayAuthToken])
            }
        }

        let plist: [String: Any] = [
            "Label": OpenBurnBarDaemonRuntimePaths.launchAgentLabel,
            "ProgramArguments": programArguments,
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

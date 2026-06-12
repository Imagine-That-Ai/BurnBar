import CryptoKit
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
            try await bootoutIfNeeded()
            try await runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
            try await runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"])
            supervisionState = OpenBurnBarDaemonSupervisor.resetAfterRepair()
            try await awaitHealthy()
        }
    }

    func repair() async {
        await performBusyWork {
            try installFilesIfNeeded()
            try writeLaunchAgentPlist()
            try await bootoutIfNeeded()
            try await runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
            try await runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"])
            supervisionState = OpenBurnBarDaemonSupervisor.resetAfterRepair()
            try await awaitHealthy()
        }
    }

    func installedDaemonBinaryNeedsRefresh() -> Bool {
        Self.installedDaemonBinaryNeedsRefresh(paths: paths, dependencies: dependencies)
    }

    nonisolated static func installedDaemonBinaryNeedsRefresh(
        paths: OpenBurnBarDaemonRuntimePaths,
        dependencies: OpenBurnBarDaemonDependencies
    ) -> Bool {
        guard let sourceBinaryURL = dependencies.resolveDaemonBinary() else { return false }
        let sourceURL = sourceBinaryURL.standardizedFileURL
        let installedURL = paths.installedBinaryURL.standardizedFileURL
        guard sourceURL != installedURL else { return false }
        guard dependencies.fileManager.isExecutableFile(atPath: sourceURL.path) else { return false }
        guard dependencies.fileManager.fileExists(atPath: installedURL.path) else { return true }

        let sourceAttributes = try? dependencies.fileManager.attributesOfItem(atPath: sourceURL.path)
        let installedAttributes = try? dependencies.fileManager.attributesOfItem(atPath: installedURL.path)
        let sourceSize = (sourceAttributes?[.size] as? NSNumber)?.int64Value
        let installedSize = (installedAttributes?[.size] as? NSNumber)?.int64Value
        if sourceSize != installedSize {
            return true
        }

        let sourceModifiedAt = sourceAttributes?[.modificationDate] as? Date
        let installedModifiedAt = installedAttributes?[.modificationDate] as? Date
        if let sourceModifiedAt,
           let installedModifiedAt,
           sourceModifiedAt.timeIntervalSince(installedModifiedAt) > 1 {
            return true
        }

        do {
            return try daemonBinaryDigest(at: sourceURL) != daemonBinaryDigest(at: installedURL)
        } catch {
            AppLogger.network.error("daemon_launchctl_loaded_check_failed", metadata: ["error": error.localizedDescription])
            return true
        }
    }

    func uninstall() async {
        await performBusyWork {
            try await bootoutIfNeeded()
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
        try validateDaemonBinary(at: sourceBinaryURL)

        if sourceBinaryURL.standardizedFileURL != paths.installedBinaryURL.standardizedFileURL {
            try atomicallyInstallBinary(from: sourceBinaryURL, to: paths.installedBinaryURL)
        }
        try validateDaemonBinary(at: paths.installedBinaryURL)

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

    /// Atomically replaces the installed daemon binary so `launchd` (KeepAlive: true)
    /// can never observe a missing binary mid-swap and flap into a crash loop.
    ///
    /// The new binary is copied to a sibling temp path on the same volume, made
    /// executable, then `rename(2)`-swapped into place via `replaceItemAt`. A
    /// currently-running daemon keeps executing its old inode; the path always
    /// resolves to a complete binary (old or new), never a partial/absent file.
    func atomicallyInstallBinary(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = dependencies.fileManager
        let directory = destinationURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).incoming-\(UUID().uuidString)"
        )

        if fileManager.fileExists(atPath: tempURL.path) {
            try? fileManager.removeItem(at: tempURL)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: tempURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempURL.path
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                // Atomic rename swap on the same volume; preserves a complete
                // binary at the destination path throughout.
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }

            // `replaceItemAt` may inherit metadata from the original; re-assert
            // the executable bit so launchd can always exec the new binary.
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    nonisolated private static func daemonBinaryDigest(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return Data(SHA256.hash(data: data))
    }

    func writeLaunchAgentPlist() throws {
        try validateDaemonBinary(at: paths.installedBinaryURL)
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
            // Fail-closed: auto-generate and persist a bearer token unless the
            // user explicitly opted into an unauthenticated loopback bind, so
            // no same-host process can spend the user's provider credits.
            // SECURITY: passed via EnvironmentVariables (above), never argv —
            // it must stay absent from `ps auxww`.
            if let gatewayAuthToken = settings.ensureGatewayAuthTokenForLaunch()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !gatewayAuthToken.isEmpty {
                environmentVariables["OPENBURNBAR_GATEWAY_AUTH_TOKEN"] = gatewayAuthToken
            } else if settings.gatewayAllowUnauthenticatedLoopback {
                environmentVariables["OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK"] = "1"
            }
        }

        // Experimental, off-by-default gateway routing opt-ins. These map the
        // app toggles to the daemon env vars read by
        // `ClaudeInteractiveSessionExecutor.makeIfEnabled()` and
        // `BurnBarCrossVendorDegradePolicy.fromEnvironment()` at gateway init,
        // so flipping a toggle takes effect on the next daemon restart.
        if settings.experimentalInteractiveClaudeEnabled {
            environmentVariables["OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE"] = "1"
        }
        if settings.crossVendorDegradeEnabled {
            environmentVariables["OPENBURNBAR_CROSS_VENDOR_DEGRADE"] = "1"
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

    private func validateDaemonBinary(at url: URL) throws {
        do {
            try dependencies.validateDaemonBinary(url)
        } catch {
            AppLogger.network.error(
                "daemon_binary_signature_invalid",
                metadata: ["path": url.path, "error": error.localizedDescription]
            )
            throw OpenBurnBarDaemonManagerError.daemonBinarySignatureInvalid(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    /// Always rotates the daemon socket auth token on daemon reinstall.
    /// This invalidates any previously leaked token without requiring coordination.
    func rotateDaemonSocketAuthToken() throws -> String {
        let generatedToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        do {
            try Self.controllerRuntimeSecrets.set(generatedToken, for: Self.daemonSocketAuthTokenAccount)
            OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken(generatedToken)
            return generatedToken
        } catch {
            throw OpenBurnBarDaemonManagerError.daemonSocketAuthTokenUnavailable
        }
    }

    func bootoutIfNeeded() async throws {
        do {
            _ = try await daemonProcess("/bin/launchctl", ["bootout", launchctlDomain, paths.launchAgentPlistURL.path])
        } catch {
            AppLogger.network.error("daemon_launchctl_bootout_skipped", metadata: ["error": error.localizedDescription])
        }
    }

    func runLaunchctl(_ arguments: [String]) async throws {
        do {
            _ = try await daemonProcess("/bin/launchctl", arguments)
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

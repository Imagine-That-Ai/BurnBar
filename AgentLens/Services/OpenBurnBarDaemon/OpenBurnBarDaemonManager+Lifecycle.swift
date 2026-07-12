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
            try await runInstallStartLifecycle()
        }
    }

    func repair() async {
        await performBusyWork {
            try await runInstallStartLifecycle()
        }
    }

    private func runInstallStartLifecycle() async throws {
        try daemonLifecycleStep("install files") {
            try installFilesIfNeeded()
        }
        try daemonLifecycleStep("write LaunchAgent plist") {
            try writeLaunchAgentPlist()
        }
        try daemonLifecycleStep("validate installed daemon") {
            try revalidateInstalledBinaryBeforeLaunch()
        }
        try await daemonLifecycleStep("bootout existing daemon") {
            try await bootoutIfNeeded()
        }
        try await daemonLifecycleStep("bootstrap LaunchAgent") {
            try await runLaunchctl(["bootstrap", launchctlDomain, paths.launchAgentPlistURL.path])
        }
        try await daemonLifecycleStep("kickstart LaunchAgent") {
            try await runLaunchctl(["kickstart", "-k", "\(launchctlDomain)/\(OpenBurnBarDaemonRuntimePaths.launchAgentLabel)"])
        }
        supervisionState = OpenBurnBarDaemonSupervisor.resetAfterRepair()
        try await daemonLifecycleStep("health check") {
            try await awaitHealthy()
        }
    }

    private func daemonLifecycleStep(_ step: String, _ operation: () throws -> Void) throws {
        AppLogger.daemon.info("daemon_lifecycle_step_started", metadata: ["step": step])
        do {
            try operation()
            AppLogger.daemon.info("daemon_lifecycle_step_finished", metadata: ["step": step])
        } catch {
            AppLogger.daemon.error(
                "daemon_lifecycle_step_failed",
                metadata: ["step": step, "error": error.localizedDescription]
            )
            throw OpenBurnBarDaemonManagerError.lifecycleStepFailed(
                step: step,
                underlying: error.localizedDescription
            )
        }
    }

    private func daemonLifecycleStep(_ step: String, _ operation: () async throws -> Void) async throws {
        AppLogger.daemon.info("daemon_lifecycle_step_started", metadata: ["step": step])
        do {
            try await operation()
            AppLogger.daemon.info("daemon_lifecycle_step_finished", metadata: ["step": step])
        } catch {
            AppLogger.daemon.error(
                "daemon_lifecycle_step_failed",
                metadata: ["step": step, "error": error.localizedDescription]
            )
            throw OpenBurnBarDaemonManagerError.lifecycleStepFailed(
                step: step,
                underlying: error.localizedDescription
            )
        }
    }

    /// RR-3: re-validate the on-disk installed daemon binary's code signature
    /// immediately before we ask launchd to (re)launch it.
    ///
    /// `installFilesIfNeeded()` validates the binary at install time, but a
    /// same-user attacker can swap the user-writable installed binary in the
    /// window between install and launch. Re-checking here refuses to bootstrap
    /// a binary that no longer satisfies the first-party requirement. The launchd
    /// `KeepAlive` re-exec we cannot intercept is mitigated by the daemon socket's
    /// peer code-signature gate (RR-3, daemon side) — that is the load-bearing
    /// fix; this is the install/launch-path complement.
    func revalidateInstalledBinaryBeforeLaunch() throws {
        try validateDaemonBinary(at: paths.installedBinaryURL)
    }

    func installedDaemonBinaryNeedsRefresh() -> Bool {
        Self.installedDaemonBinaryNeedsRefresh(paths: paths, dependencies: dependencies)
    }

    nonisolated static func installedDaemonBinaryNeedsRefresh(
        paths: OpenBurnBarDaemonRuntimePaths,
        dependencies: OpenBurnBarDaemonDependencies
    ) -> Bool {
        guard let sourceBinaryURL = dependencies.resolveDaemonBinary() else {
            return false
        }
        let sourceURL = sourceBinaryURL.standardizedFileURL
        let installedURL = paths.installedBinaryURL.standardizedFileURL
        guard dependencies.fileManager.isExecutableFile(atPath: sourceURL.path) else { return false }
        guard sourceURL != installedURL else { return false }
        guard dependencies.fileManager.fileExists(atPath: installedURL.path) else { return true }

        // Security/correctness: a same-user attacker can swap the user-writable
        // installed binary between install and launch (see RR-3). If we cannot
        // stat either binary, we have lost the size/mtime evidence needed to
        // decide staleness, so we FAIL CLOSED by treating the installed binary
        // as needing a refresh — the refresh path re-runs `validateDaemonBinary`
        // + atomic re-install, which is the safe action. Never silently keep the
        // possibly-swapped installed binary in place when the probe is blind.
        let sourceAttributes: [FileAttributeKey: Any]
        let installedAttributes: [FileAttributeKey: Any]
        do {
            sourceAttributes = try dependencies.fileManager.attributesOfItem(atPath: sourceURL.path)
            installedAttributes = try dependencies.fileManager.attributesOfItem(atPath: installedURL.path)
        } catch {
            AppLogger.network.error(
                "daemon_binary_attributes_unreadable_force_refresh",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return true
        }

        func trustedSourceCanDriveRefresh() -> Bool {
            // Never refresh a working installed daemon from a source binary that
            // fails the first-party signature requirement. A stale/ad-hoc leftover
            // source should not block provider mutations while the installed daemon
            // is otherwise healthy, and a trusted newer source still upgrades.
            do {
                try dependencies.validateDaemonBinary(sourceURL)
                return true
            } catch {
                AppLogger.network.notice(
                    "daemon_refresh_skipped_untrusted_source",
                    metadata: ["reason": error.localizedDescription]
                )
                return false
            }
        }

        let sourceSize = (sourceAttributes[.size] as? NSNumber)?.int64Value
        let installedSize = (installedAttributes[.size] as? NSNumber)?.int64Value
        if sourceSize != installedSize {
            return trustedSourceCanDriveRefresh()
        }

        let sourceModifiedAt = sourceAttributes[.modificationDate] as? Date
        let installedModifiedAt = installedAttributes[.modificationDate] as? Date
        if let sourceModifiedAt,
           let installedModifiedAt,
           sourceModifiedAt.timeIntervalSince(installedModifiedAt) > 1 {
            return trustedSourceCanDriveRefresh()
        }

        do {
            let digestDiffers = try daemonBinaryDigest(at: sourceURL) != daemonBinaryDigest(at: installedURL)
            guard digestDiffers else { return false }
            return trustedSourceCanDriveRefresh()
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
        try dependencies.fileManager.createDirectory(at: paths.frameworksDirectory, withIntermediateDirectories: true)
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
        try installRuntimeFrameworksIfAvailable(near: sourceBinaryURL)
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

        // Core-decomposition S2 (P-02): the catalog loader + secret PII gate moved to
        // OpenBurnBarKernel with their JSON resources, so `Bundle.module` in that code
        // path now resolves to OpenBurnBarCore_OpenBurnBarKernel.bundle. Stage it next
        // to the daemon binary alongside the OpenBurnBarCore bundle (which keeps the
        // SVGs + Pretext HTML/JS). Best-effort: the release/smoke pipeline fatally
        // asserts the Kernel bundle is present in the packaged app, so a locally staged
        // layout that predates the Kernel bundle still installs.
        let installedKernelBundleURL = paths.daemonDirectory
            .appendingPathComponent(Self.kernelResourceBundleName)
        if let sourceKernelBundleURL = OpenBurnBarDaemonBinaryResolver.resolveKernelResourceBundle(
            nearBinaryURL: sourceBinaryURL,
            appBundleURL: Bundle.main.bundleURL,
            fileManager: dependencies.fileManager
        ), sourceKernelBundleURL.standardizedFileURL != installedKernelBundleURL.standardizedFileURL {
            if dependencies.fileManager.fileExists(atPath: installedKernelBundleURL.path) {
                try dependencies.fileManager.removeItem(at: installedKernelBundleURL)
            }
            try dependencies.fileManager.copyItem(at: sourceKernelBundleURL, to: installedKernelBundleURL)
        }

        let installedProjectCodeMemoryDirectory = paths.daemonDirectory
            .appendingPathComponent(Self.projectCodeMemoryResourceDirectoryName, isDirectory: true)
        let installedSecretCorpusURL = installedProjectCodeMemoryDirectory
            .appendingPathComponent(Self.projectCodeMemorySecretCorpusFileName, isDirectory: false)
        if let sourceCorpusURL = OpenBurnBarDaemonBinaryResolver.resolveProjectCodeMemorySecretCorpus(
            nearBinaryURL: sourceBinaryURL,
            appBundleURL: Bundle.main.bundleURL,
            fileManager: dependencies.fileManager
        ), sourceCorpusURL.standardizedFileURL != installedSecretCorpusURL.standardizedFileURL {
            try dependencies.fileManager.createDirectory(
                at: installedProjectCodeMemoryDirectory,
                withIntermediateDirectories: true
            )
            if dependencies.fileManager.fileExists(atPath: installedSecretCorpusURL.path) {
                try dependencies.fileManager.removeItem(at: installedSecretCorpusURL)
            }
            try dependencies.fileManager.copyItem(at: sourceCorpusURL, to: installedSecretCorpusURL)
        }

        guard dependencies.fileManager.fileExists(atPath: installedSecretCorpusURL.path) else {
            throw OpenBurnBarDaemonManagerError.daemonProjectCodeMemoryResourceUnavailable(
                expectedPath: installedSecretCorpusURL.path
            )
        }
    }

    func installRuntimeFrameworksIfAvailable(near sourceBinaryURL: URL) throws {
        let frameworkURLs = OpenBurnBarDaemonBinaryResolver.resolveRuntimeFrameworks(
            nearBinaryURL: sourceBinaryURL,
            appBundleURL: Bundle.main.bundleURL,
            fileManager: dependencies.fileManager
        )
        guard !frameworkURLs.isEmpty else { return }

        try dependencies.fileManager.createDirectory(at: paths.frameworksDirectory, withIntermediateDirectories: true)
        let installedFrameworkNames = Set(frameworkURLs.map(\.lastPathComponent))
        for frameworkURL in frameworkURLs {
            let destinationURL = paths.frameworksDirectory.appendingPathComponent(
                frameworkURL.lastPathComponent,
                isDirectory: true
            )
            if frameworkURL.standardizedFileURL == destinationURL.standardizedFileURL {
                continue
            }
            try atomicallyInstallDirectory(from: frameworkURL, to: destinationURL)
        }

        let existingFrameworks = try dependencies.fileManager.contentsOfDirectory(
            at: paths.frameworksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for existingFramework in existingFrameworks
            where existingFramework.pathExtension == "framework"
            && !installedFrameworkNames.contains(existingFramework.lastPathComponent) {
            try dependencies.fileManager.removeItem(at: existingFramework)
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
            try? fileManager.removeItem(at: tempURL) // try?-ok(stale temp cleanup)
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
            try? fileManager.removeItem(at: tempURL) // try?-ok(temp cleanup on error)
            throw error
        }
    }

    func atomicallyInstallDirectory(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = dependencies.fileManager
        let parentDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let tempURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).incoming-\(UUID().uuidString)",
            isDirectory: true
        )

        if fileManager.fileExists(atPath: tempURL.path) {
            try? fileManager.removeItem(at: tempURL) // try?-ok(stale temp cleanup)
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: tempURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL) // try?-ok(temp cleanup on error)
            throw error
        }
    }

    nonisolated private static func daemonBinaryDigest(at url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return Data(SHA256.hash(data: data))
    }

    func writeLaunchAgentPlist() throws {
        try launchAgentPlistStep("validate_installed_binary") {
            try validateDaemonBinary(at: paths.installedBinaryURL)
        }
        let indexDbPath = OpenBurnBarCore.OpenBurnBarAppPaths.live(fileManager: dependencies.fileManager).databaseURL.path
        _ = try launchAgentPlistStep("rotate_socket_token") {
            try rotateDaemonSocketAuthToken()
        }

        // SECURITY: pass the daemon socket token through an owner-only file path,
        // never argv or LaunchAgent environment. CLI arguments are visible to any
        // local user via `ps aux`, and environment values are inherited by child
        // processes. The daemon reads the token from --socket-auth-token-file.
        var programArguments = [
            paths.installedBinaryURL.path,
            "--socket-path", paths.socketURL.path,
            "--index-database-path", indexDbPath,
            "--socket-auth-token-file", paths.socketAuthTokenFileURL.path
        ]

        var environmentVariables: [String: String] = [:]

        // Propagate Sentry DSN only when crash reporting consent allows it.
        // Uses the same resolution helper as the app: Info.plist first, then
        // GoogleService-Info.plist fallback (F-RR09-003).
        #if canImport(Sentry)
        if let sentryDSN = Self.daemonSentryDSNForLaunch(resolvedDSN: OpenBurnBarApp.resolveSentryDSN()) {
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

        // Experimental, off-by-default gateway routing opt-in. Maps the app
        // toggle to the daemon env var read by
        // `BurnBarCrossVendorDegradePolicy.fromEnvironment()` at gateway init,
        // so flipping the toggle takes effect on the next daemon restart.
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

        let data = try launchAgentPlistStep("serialize") {
            try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        }
        try launchAgentPlistStep("write_file") {
            try data.write(to: paths.launchAgentPlistURL, options: .atomic)
        }
        try launchAgentPlistStep("set_file_permissions") {
            try dependencies.fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paths.launchAgentPlistURL.path
            )
        }
    }

    #if canImport(Sentry)
    nonisolated static func daemonSentryDSNForLaunch(
        resolvedDSN: String?,
        defaults: UserDefaults = .standard
    ) -> String? {
        guard MacCrashReportingConsent.isEnabled(defaults: defaults) else {
            return nil
        }
        guard let trimmedDSN = resolvedDSN?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedDSN.isEmpty else {
            return nil
        }
        return trimmedDSN
    }
    #endif

    private func launchAgentPlistStep<T>(_ name: String, _ operation: () throws -> T) throws -> T {
        AppLogger.daemon.info("daemon_launch_agent_\(name)_started")
        do {
            let result = try operation()
            AppLogger.daemon.info("daemon_launch_agent_\(name)_finished")
            return result
        } catch {
            AppLogger.daemon.error("daemon_launch_agent_\(name)_failed")
            throw error
        }
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
        let generatedToken: String
        do {
            generatedToken = try OpenBurnBarSecureToken.randomBase64URL()
        } catch {
            throw OpenBurnBarDaemonManagerError.daemonSocketAuthTokenUnavailable
        }

        do {
            try writeDaemonSocketAuthTokenFile(generatedToken)
        } catch {
            AppLogger.daemon.error(
                "daemon_socket_auth_token_file_write_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            throw OpenBurnBarDaemonManagerError.daemonSocketAuthTokenUnavailable
        }

        if !writeDaemonSocketAuthTokenToKeychain(generatedToken) {
            AppLogger.daemon.error("daemon_socket_auth_token_keychain_write_failed_using_file_fallback")
        }
        OpenBurnBarDaemonSocketClient.cacheDaemonSocketAuthToken(generatedToken)
        return generatedToken
    }

    private func writeDaemonSocketAuthTokenToKeychain(_ generatedToken: String) -> Bool {
        do {
            try daemonSocketAuthTokenStore.set(generatedToken, for: Self.daemonSocketAuthTokenAccount)
            return true
        } catch {
            AppLogger.daemon.silentFailure(
                "OpenBurnBarDaemonManager.rotateDaemonSocketAuthToken.initialWrite",
                error: error
            )
            do {
                // This token is per-launch runtime glue, not a user secret. If
                // an older app/helper signature owns the existing Keychain item,
                // replacing it is safer than leaving stale socket auth around.
                try daemonSocketAuthTokenStore.delete(account: Self.daemonSocketAuthTokenAccount)
                try daemonSocketAuthTokenStore.set(generatedToken, for: Self.daemonSocketAuthTokenAccount)
                return true
            } catch {
                AppLogger.daemon.silentFailure(
                    "OpenBurnBarDaemonManager.rotateDaemonSocketAuthToken.rewrite",
                    error: error
                )
                return false
            }
        }
    }

    private func writeDaemonSocketAuthTokenFile(_ generatedToken: String) throws {
        try dependencies.fileManager.createDirectory(
            at: paths.supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(generatedToken.utf8).write(to: paths.socketAuthTokenFileURL, options: .atomic)
        try dependencies.fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.socketAuthTokenFileURL.path
        )
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
            if let response = try? await daemonRPC({ // try?-ok(health poll retry)
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

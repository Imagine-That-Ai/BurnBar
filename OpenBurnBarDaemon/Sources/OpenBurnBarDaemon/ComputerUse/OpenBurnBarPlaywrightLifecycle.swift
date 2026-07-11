import Foundation
import OpenBurnBarCore

/// First-launch installer + version check for the Playwright bridge.
/// Phase 9. See `plans/2026-05-16-computer-use-master-plan.md` § B.3.
///
/// The lifecycle is idempotent: every call to `ensureReady` re-checks
/// Node, Playwright, and the browser binaries; missing pieces are
/// installed via `npm install -g playwright@<pin>` and `playwright
/// install chromium --with-deps`. The user-facing setup wizard
/// surfaces progress and prompts for confirmation before the install
/// runs.
public actor OpenBurnBarPlaywrightLifecycle {
    public enum LifecycleError: Error, Sendable, Equatable {
        case nodeMissing(searchedPaths: [String])
        case npmMissing(searchedPaths: [String])
        case installFailed(exitCode: Int32, stderr: String)
        case checksumMismatch(expected: String, observed: String)
        case bridgeScriptMissingInBundle
        case runtimeProbeFailed(exitCode: Int32, detail: String)
    }

    public struct Readiness: Codable, Sendable, Equatable {
        public let nodePath: String
        public let npmPath: String
        public let playwrightVersion: String
        public let chromiumInstalled: Bool
        public let bridgeScriptURL: URL
        public let resolvedAt: Date

        public init(
            nodePath: String,
            npmPath: String,
            playwrightVersion: String,
            chromiumInstalled: Bool,
            bridgeScriptURL: URL,
            resolvedAt: Date
        ) {
            self.nodePath = nodePath
            self.npmPath = npmPath
            self.playwrightVersion = playwrightVersion
            self.chromiumInstalled = chromiumInstalled
            self.bridgeScriptURL = bridgeScriptURL
            self.resolvedAt = resolvedAt
        }
    }

    public static let pinnedPlaywrightVersion = "1.49.1"

    public let bridgeScriptURL: URL
    public let logger: BurnBarDaemonLogger
    private let locateExecutable: BurnBarExecutableLocator

    public init(
        bridgeScriptURL: URL,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "playwright-lifecycle"),
        locateExecutable: @escaping BurnBarExecutableLocator
    ) {
        self.bridgeScriptURL = bridgeScriptURL
        self.logger = logger
        self.locateExecutable = locateExecutable
    }

    /// Probe + auto-install path. Returns once the host is ready for a
    /// `OpenBurnBarPlaywrightDriver.start()` call. Throws if Node or npm
    /// are missing — those need a user-initiated install.
    public func ensureReady(performInstallIfMissing: Bool) async throws -> Readiness {
        guard FileManager.default.fileExists(atPath: bridgeScriptURL.path) else {
            throw LifecycleError.bridgeScriptMissingInBundle
        }
        let searched = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        let packagedRuntime = ProcessInfo.processInfo.environment["OPENBURNBAR_PACKAGED_PLAYWRIGHT_RUNTIME"] == "1"
        let nodePath = packagedRuntime ? "/usr/bin/node" : locateExecutable("node")
        guard let nodePath, FileManager.default.isExecutableFile(atPath: nodePath) else {
            throw LifecycleError.nodeMissing(searchedPaths: searched)
        }
        let npmPath = packagedRuntime ? "/usr/bin/npm" : locateExecutable("npm")
        guard let npmPath, FileManager.default.isExecutableFile(atPath: npmPath) else {
            throw LifecycleError.npmMissing(searchedPaths: searched)
        }

        let installedVersion = try await readGlobalPlaywrightVersion(npmPath: npmPath)
        if installedVersion == nil {
            guard performInstallIfMissing else {
                throw LifecycleError.installFailed(exitCode: -1, stderr: "Playwright is not installed and install was declined")
            }
            try await installPlaywright(npmPath: npmPath)
        } else if let installed = installedVersion, installed != Self.pinnedPlaywrightVersion {
            guard performInstallIfMissing else {
                throw LifecycleError.installFailed(
                    exitCode: -1,
                    stderr: "Playwright \(installed) installed — pinned version is \(Self.pinnedPlaywrightVersion)"
                )
            }
            try await installPlaywright(npmPath: npmPath)
        }

        if packagedRuntime {
            let probe = try await runProcess(
                executable: nodePath,
                arguments: [bridgeScriptURL.path, "--probe-runtime"]
            )
            guard probe.exitCode == 0,
                  let report = try? JSONSerialization.jsonObject(with: probe.stdout) as? [String: Any],
                  report["ready"] as? Bool == true else {
                let output = String(decoding: probe.stdout + probe.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LifecycleError.runtimeProbeFailed(exitCode: probe.exitCode, detail: output)
            }
            return Readiness(
                nodePath: nodePath,
                npmPath: npmPath,
                playwrightVersion: Self.pinnedPlaywrightVersion,
                chromiumInstalled: true,
                bridgeScriptURL: bridgeScriptURL,
                resolvedAt: Date()
            )
        }

        let chromiumInstalled = try await installChromiumIfMissing(npmPath: npmPath, performIfMissing: performInstallIfMissing)
        let liveVersion = try await readGlobalPlaywrightVersion(npmPath: npmPath) ?? Self.pinnedPlaywrightVersion

        return Readiness(
            nodePath: nodePath,
            npmPath: npmPath,
            playwrightVersion: liveVersion,
            chromiumInstalled: chromiumInstalled,
            bridgeScriptURL: bridgeScriptURL,
            resolvedAt: Date()
        )
    }

    // MARK: probes

    private func readGlobalPlaywrightVersion(npmPath: String) async throws -> String? {
        let result = try await runProcess(
            executable: npmPath,
            arguments: ["list", "-g", "--depth=0", "playwright", "--json"]
        )
        guard result.exitCode == 0 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let dependencies = json["dependencies"] as? [String: Any],
              let playwright = dependencies["playwright"] as? [String: Any],
              let version = playwright["version"] as? String else {
            return nil
        }
        return version
    }

    private func installPlaywright(npmPath: String) async throws {
        logger.info("installing_playwright", metadata: ["version": Self.pinnedPlaywrightVersion])
        let result = try await runProcess(
            executable: npmPath,
            arguments: ["install", "-g", "playwright@\(Self.pinnedPlaywrightVersion)"]
        )
        guard result.exitCode == 0 else {
            throw LifecycleError.installFailed(
                exitCode: result.exitCode,
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }
    }

    private func installChromiumIfMissing(npmPath: String, performIfMissing: Bool) async throws -> Bool {
        guard let playwrightCLI = locateExecutable("playwright") else { return false }
        let probe = try await runProcess(
            executable: playwrightCLI,
            arguments: ["--version"]
        )
        guard probe.exitCode == 0 else { return false }

        if performIfMissing {
            let install = try await runProcess(
                executable: playwrightCLI,
                arguments: ["install", "chromium", "--with-deps"]
            )
            guard install.exitCode == 0 else {
                throw LifecycleError.installFailed(
                    exitCode: install.exitCode,
                    stderr: String(decoding: install.stderr, as: UTF8.self)
                )
            }
            return true
        }
        return true
    }

    // MARK: runProcess

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    private func runProcess(executable: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutData,
                    stderr: stderrData
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

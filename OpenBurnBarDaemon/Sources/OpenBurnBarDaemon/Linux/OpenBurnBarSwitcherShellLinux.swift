#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarEngine

public enum BurnBarSwitcherShellError: LocalizedError, Equatable {
    case unsupportedCLI(String)
    case missingRequestedProfile(String)
    case requestedProfileMismatch(expected: SwitcherCLIProfileType, actual: SwitcherCLIProfileType?)
    case noProfilesConfigured(SwitcherCLIProfileType)
    case terminalSpawnFailed(String)
    case terminalExited(Int32, detail: String?)
    case quotaExhausted(String)
    case shimInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedCLI(let name):
            return name
        case .missingRequestedProfile(let profileID):
            return "Switcher profile '\(profileID)' was not found."
        case .requestedProfileMismatch(let expected, let actual):
            return "Requested profile does not match \(expected.displayName). Found \(actual?.displayName ?? "unknown")."
        case .noProfilesConfigured(let cliType):
            return "No \(cliType.displayName) switcher profiles are configured yet."
        case .terminalSpawnFailed(let detail):
            return detail
        case .terminalExited(let status, let detail):
            return detail ?? "CLI exited with status \(status)."
        case .quotaExhausted(let detail):
            return detail
        case .shimInstallFailed(let detail):
            return detail
        }
    }
}

public struct BurnBarCLIShellExecutionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let launchedProfileID: String?
    public let attemptedProfileIDs: [String]
    public let fallbackTriggered: Bool

    public init(
        exitCode: Int32,
        launchedProfileID: String?,
        attemptedProfileIDs: [String],
        fallbackTriggered: Bool
    ) {
        self.exitCode = exitCode
        self.launchedProfileID = launchedProfileID
        self.attemptedProfileIDs = attemptedProfileIDs
        self.fallbackTriggered = fallbackTriggered
    }
}

public struct BurnBarCLIShellLaunchRequest: Equatable, Sendable {
    public let cliType: SwitcherCLIProfileType
    public let forwardedArguments: [String]
    public let requestedProfileID: String?

    public init(
        cliType: SwitcherCLIProfileType,
        forwardedArguments: [String],
        requestedProfileID: String? = nil
    ) {
        self.cliType = cliType
        self.forwardedArguments = forwardedArguments
        self.requestedProfileID = requestedProfileID
    }
}

public protocol BurnBarCLIShellExecuting: Sendable {
    func execute(_ request: BurnBarCLIShellLaunchRequest) async throws -> BurnBarCLIShellExecutionResult
}

public protocol BurnBarSwitcherProfileStoreProviding: Sendable {
    func fetchProfile(id: String) -> SwitcherProfileRecord?
    func fetchAllProfiles() -> [SwitcherProfileRecord]
    func fetchActiveProfileID() -> String?
    func setActiveProfileID(_ profileID: String?)
    func updateProfile(_ profile: SwitcherProfileRecord)
}

/// Linux profile store: synthesizes PATH-discovered CLI profiles (no keychain).
public final class BurnBarSwitcherSQLiteProfileStore: BurnBarSwitcherProfileStoreProviding, Sendable {
    private let lock = Locked(StoreState())

    private struct StoreState: Sendable {
        var activeID: String?
        var cache: [SwitcherProfileRecord] = []
        var loaded = false
    }

    public init(databaseURL: URL = BurnBarDaemonPaths.supportDirectoryURL.appendingPathComponent("openburnbar.sqlite")) throws {
        _ = databaseURL
    }

    public func fetchProfile(id: String) -> SwitcherProfileRecord? {
        ensureLoaded()
        return lock.withLock { $0.cache.first { $0.id == id } }
    }

    public func fetchAllProfiles() -> [SwitcherProfileRecord] {
        ensureLoaded()
        return lock.withLock { $0.cache }
    }

    public func fetchActiveProfileID() -> String? {
        ensureLoaded()
        return lock.withLock { $0.activeID }
    }

    public func setActiveProfileID(_ profileID: String?) {
        lock.withLock { $0.activeID = profileID }
    }

    public func updateProfile(_ profile: SwitcherProfileRecord) {
        lock.withLock { state in
            if let idx = state.cache.firstIndex(where: { $0.id == profile.id }) {
                state.cache[idx] = profile
            } else {
                state.cache.append(profile)
            }
        }
    }

    private func ensureLoaded() {
        lock.withLock { state in
            guard !state.loaded else { return }
            state.loaded = true
            state.cache = Self.discoverPathProfiles()
            state.activeID = state.cache.first?.id
        }
    }

    private static func discoverPathProfiles() -> [SwitcherProfileRecord] {
        let mapping: [(SwitcherCLIProfileType, [String])] = [
            (.codex, ["codex"]),
            (.claude, ["claude"]),
            (.gemini, ["gemini"]),
            (.opencode, ["opencode"]),
            (.droid, ["droid"]),
            (.pi, ["pi"]),
            (.forge, ["forge"]),
            (.grok, ["grok"]),
            (.cursorAgent, ["cursor-agent", "cursoragent"]),
            (.omp, ["omp"]),
            (.kimi, ["kimi"]),
            (.junie, ["junie"]),
            (.antigravity, ["antigravity"])
        ]
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        var out: [SwitcherProfileRecord] = []
        var sort = 0
        for (cliType, names) in mapping {
            guard names.contains(where: { resolveExecutable($0, pathDirs: pathDirs) != nil }) else { continue }
            let id = "linux-path-\(cliType.rawValue)"
            let meta = SwitcherCLIProfileMetadata(
                displayLabel: "\(cliType.displayName) (PATH)"
            )
            out.append(
                SwitcherProfileRecord(
                    id: id,
                    targetKind: .cli,
                    cliType: cliType,
                    cliMetadata: meta,
                    sortKey: sort
                )
            )
            sort += 1
        }
        return out
    }

    static func resolveExecutable(_ name: String, pathDirs: [String]? = nil) -> URL? {
        let dirs = pathDirs ?? (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func defaultBinaryNames(for cliType: SwitcherCLIProfileType) -> [String] {
        switch cliType {
        case .codex: return ["codex"]
        case .claude: return ["claude"]
        case .gemini: return ["gemini"]
        case .opencode: return ["opencode"]
        case .droid: return ["droid"]
        case .pi: return ["pi"]
        case .forge: return ["forge"]
        case .grok: return ["grok"]
        case .cursorAgent: return ["cursor-agent", "cursoragent"]
        case .omp: return ["omp"]
        case .kimi: return ["kimi"]
        case .junie: return ["junie"]
        case .antigravity: return ["agy", "antigravity"]
        }
    }
}

/// POSIX Process-based CLI runner (no Darwin `script(1)` dependency).
public final class BurnBarCLIShellExecutor: BurnBarCLIShellExecuting, Sendable {
    private let profileStore: any BurnBarSwitcherProfileStoreProviding
    private let environmentProvider: @Sendable () -> [String: String]

    private static let deniedKeys: Set<String> = [
        "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN",
        "BURNBAR_DAEMON_SOCKET_AUTH_TOKEN",
        "OPENBURNBAR_GATEWAY_AUTH_TOKEN",
        "BURNBAR_GATEWAY_AUTH_TOKEN"
    ]
    private static let deniedPrefixes = ["OPENBURNBAR_DAEMON_", "BURNBAR_DAEMON_", "OPENBURNBAR_GATEWAY_", "BURNBAR_GATEWAY_"]

    public init(
        profileStore: any BurnBarSwitcherProfileStoreProviding,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.profileStore = profileStore
        self.environmentProvider = environmentProvider
    }

    public func execute(_ request: BurnBarCLIShellLaunchRequest) async throws -> BurnBarCLIShellExecutionResult {
        let environment = environmentProvider()
        let pathDirectories = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        let profiles = profileStore.fetchAllProfiles().filter {
            $0.targetKind == .cli && $0.cliType == request.cliType && !$0.isDisabled
        }
        guard !profiles.isEmpty else {
            // PATH-only fallback even without stored profiles.
            if let binary = BurnBarSwitcherSQLiteProfileStore.defaultBinaryNames(for: request.cliType)
                .compactMap({ BurnBarSwitcherSQLiteProfileStore.resolveExecutable($0, pathDirs: pathDirectories) })
                .first {
                let result = try await runProcess(executable: binary, arguments: request.forwardedArguments, workingDirectory: nil)
                return BurnBarCLIShellExecutionResult(
                    exitCode: result.status,
                    launchedProfileID: "linux-path-\(request.cliType.rawValue)",
                    attemptedProfileIDs: ["linux-path-\(request.cliType.rawValue)"],
                    fallbackTriggered: false
                )
            }
            throw BurnBarSwitcherShellError.noProfilesConfigured(request.cliType)
        }

        var candidates = profiles
        if let requested = request.requestedProfileID {
            guard let match = profiles.first(where: { $0.id == requested }) else {
                throw BurnBarSwitcherShellError.missingRequestedProfile(requested)
            }
            guard match.cliType == request.cliType else {
                throw BurnBarSwitcherShellError.requestedProfileMismatch(
                    expected: request.cliType,
                    actual: match.cliType
                )
            }
            candidates = [match]
        }

        var attempted: [String] = []
        var lastStatus: Int32 = EXIT_FAILURE
        var lastDetail: String?

        for profile in candidates {
            attempted.append(profile.id)
            guard let cliType = profile.cliType,
                  let binary = BurnBarSwitcherSQLiteProfileStore.defaultBinaryNames(for: cliType)
                    .compactMap({ BurnBarSwitcherSQLiteProfileStore.resolveExecutable($0, pathDirs: pathDirectories) })
                    .first
            else { continue }
            let cwd = profile.cliMetadata?.workingDirectory
            let extraArgs = profile.cliMetadata?.additionalArgs ?? []
            let result = try await runProcess(
                executable: binary,
                arguments: extraArgs + request.forwardedArguments,
                workingDirectory: cwd
            )
            lastStatus = result.status
            lastDetail = result.output
            if result.status == 0 {
                profileStore.setActiveProfileID(profile.id)
                return BurnBarCLIShellExecutionResult(
                    exitCode: 0,
                    launchedProfileID: profile.id,
                    attemptedProfileIDs: attempted,
                    fallbackTriggered: attempted.count > 1
                )
            }
        }

        if let lastDetail, !lastDetail.isEmpty {
            throw BurnBarSwitcherShellError.terminalExited(lastStatus, detail: String(lastDetail.prefix(2_000)))
        }
        return BurnBarCLIShellExecutionResult(
            exitCode: lastStatus,
            launchedProfileID: attempted.last,
            attemptedProfileIDs: attempted,
            fallbackTriggered: attempted.count > 1
        )
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        workingDirectory: String?
    ) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    var env = self.sanitizedEnvironment(self.environmentProvider())
                    env["TERM"] = env["TERM"] ?? "xterm-256color"
                    process.environment = env
                    if let workingDirectory {
                        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                    }
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (process.terminationStatus, text))
                } catch {
                    continuation.resume(
                        throwing: BurnBarSwitcherShellError.terminalSpawnFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            if Self.deniedKeys.contains(key) { return false }
            for prefix in Self.deniedPrefixes where key.hasPrefix(prefix) {
                return false
            }
            return true
        }
    }
}

public struct BurnBarCLIShellShimInstallResult: Equatable, Sendable {
    public let installDirectory: URL
    public let installedCommands: [String]
}

public protocol BurnBarCLIShellShimInstalling: Sendable {
    func installShims(invokedExecutablePath: String) throws -> BurnBarCLIShellShimInstallResult
}

public struct BurnBarCLIShellShimInstaller: BurnBarCLIShellShimInstalling, Sendable {
    public static let defaultInstallDirectory = BurnBarDaemonPaths.supportDirectoryURL
        .appendingPathComponent("bin", isDirectory: true)

    private let installDirectory: URL

    public init(installDirectory: URL = Self.defaultInstallDirectory) {
        self.installDirectory = installDirectory
    }

    public func installShims(invokedExecutablePath: String) throws -> BurnBarCLIShellShimInstallResult {
        let dir = installDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let commands = SwitcherCLIProfileType.allCases.map(\.rawValue)
        var installed: [String] = []
        for command in commands {
            let shim = dir.appendingPathComponent(command)
            let script = """
            #!/usr/bin/env bash
            exec \(Self.shellQuote(invokedExecutablePath)) exec \(command) -- "$@"
            """
            try script.write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
            installed.append(command)
        }
        return BurnBarCLIShellShimInstallResult(installDirectory: dir, installedCommands: installed)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif

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
            (.muse, ["muse", "muse-code"]),
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
        case .fx: return ["fx"]
        case .muse: return ["muse", "muse-code"]
        case .primeAgent: return ["prime-agent"]
        case .antigravity: return ["agy", "antigravity"]
        case .hermes: return ["hermes"]
        case .goose: return ["goose"]
        case .windsurf: return ["windsurf"]
        case .openClaude: return ["openclaude"]
        case .openClaw: return ["openclaw"]
        }
    }
}

/// Linux PTY-backed CLI runner.
///
/// A plain `Pipe` makes interactive CLIs switch to batch mode because their
/// standard streams are not terminals.  `LinuxPTYCLIProcess` below gives each
/// child a controlling PTY and a dedicated process group while keeping output
/// bounded and cancellation owned by the async caller.
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
    private static let terminalDetailByteCap = 2_000

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
                if result.status != 0 {
                    throw BurnBarSwitcherShellError.terminalExited(
                        result.status,
                        detail: Self.boundedTerminalDetail(result.output)
                    )
                }
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
        var didRunProcess = false

        for profile in candidates {
            attempted.append(profile.id)
            guard let cliType = profile.cliType,
                  let binary = BurnBarSwitcherSQLiteProfileStore.defaultBinaryNames(for: cliType)
                    .compactMap({ BurnBarSwitcherSQLiteProfileStore.resolveExecutable($0, pathDirs: pathDirectories) })
                    .first
            else { continue }
            let cwd = profile.cliMetadata?.workingDirectory
            let extraArgs = profile.cliMetadata?.additionalArgs ?? []
            didRunProcess = true
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

        if didRunProcess, lastStatus != 0 {
            throw BurnBarSwitcherShellError.terminalExited(
                lastStatus,
                detail: Self.boundedTerminalDetail(lastDetail ?? "")
            )
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
        var environment = sanitizedEnvironment(environmentProvider())
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        let session = LinuxPTYCLIProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory.map { URL(fileURLWithPath: $0) }
        )

        do {
            return try await session.run()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BurnBarSwitcherShellError {
            throw error
        } catch {
            throw BurnBarSwitcherShellError.terminalSpawnFailed(error.localizedDescription)
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

    /// Keep terminal diagnostics bounded in bytes, not characters.  A
    /// character-count prefix can exceed the contract for non-ASCII output.
    private static func boundedTerminalDetail(_ output: String) -> String? {
        guard !output.isEmpty else { return nil }

        var end = output.startIndex
        var byteCount = 0
        while end < output.endIndex {
            let next = output.index(after: end)
            let characterByteCount = output[end..<next].utf8.count
            guard byteCount + characterByteCount <= terminalDetailByteCap else { break }
            byteCount += characterByteCount
            end = next
        }

        guard end > output.startIndex else { return nil }
        return String(output[..<end])
    }
}

// AUDIT(@unchecked Sendable): mutable process state is guarded by `state`'s lock;
// launch configuration is immutable. sendable-allowlist: process-handle
/// One non-interactive invocation attached to a Linux pseudo-terminal.
///
/// `forkpty` creates the PTY pair, makes the child a session leader with the
/// slave as its controlling terminal, and gives the child a process group whose
/// negative PID can be used to terminate descendants.  The parent drains the
/// master from a nonblocking polling loop so a chatty CLI cannot deadlock or
/// grow memory without bound.
private final class LinuxPTYCLIProcess: @unchecked Sendable {
    /// C argument storage is prepared before `forkpty`.  The child then only
    /// performs `chdir`/`execve` using inherited pointers, avoiding Swift/heap
    /// allocation while another daemon thread may still be running.
    private final class PreparedLaunch {
        let executablePath: String
        let workingDirectoryPath: String?
        var argv: [UnsafeMutablePointer<CChar>?]
        var envp: [UnsafeMutablePointer<CChar>?]

        init(executablePath: String, arguments: [String], environment: [String: String], workingDirectoryPath: String?) {
            self.executablePath = executablePath
            self.workingDirectoryPath = workingDirectoryPath
            argv = ([executablePath] + arguments).map { argument in
                argument.withCString { strdup($0) }
            }
            argv.append(nil)

            let environmentEntries: [String] = environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
            envp = environmentEntries.map { entry in
                entry.withCString { strdup($0) }
            }
            envp.append(nil)
        }

        deinit {
            for pointer in argv {
                if let pointer { free(pointer) }
            }
            for pointer in envp {
                if let pointer { free(pointer) }
            }
        }

        /// Runs only in the forkpty child and never returns.
        func exec() -> Never {
            if let workingDirectoryPath {
                let result = workingDirectoryPath.withCString { chdir($0) }
                guard result == 0 else { _exit(126) }
            }

            executablePath.withCString { executablePath in
                argv.withUnsafeMutableBufferPointer { argvBuffer in
                    envp.withUnsafeMutableBufferPointer { envpBuffer in
                        guard let argvAddress = argvBuffer.baseAddress,
                              let envpAddress = envpBuffer.baseAddress else {
                            _exit(126)
                        }
                        _ = execve(executablePath, argvAddress, envpAddress)
                    }
                }
            }

            // Keep the child-side failure path allocation-free and bounded.
            let message = "openburnbar: exec failed\n"
            message.withCString { pointer in
                _ = write(STDERR_FILENO, pointer, strlen(pointer))
            }
            _exit(127)
        }
    }

    private struct State: Sendable {
        var ptyFD: Int32 = -1
        var childPID: pid_t = -1
        var cancelled = false
        var started = false
    }

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL?
    private let state = Locked(State())

    private static let outputByteCap = 256 * 1024
    private static let pollMilliseconds: Int32 = 100
    private static let terminationGraceNanoseconds: UInt64 = 250_000_000

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    func run() async throws -> (status: Int32, output: String) {
        try Task.checkCancellation()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, output: String), Error>) in
                start { result in
                    continuation.resume(with: result)
                }
            }
        }, onCancel: {
            cancel()
        })
    }

    private func start(completion: @escaping @Sendable (Result<(status: Int32, output: String), Error>) -> Void) {
        let canStart = state.withLock { state -> Bool in
            guard !state.started, !state.cancelled else { return false }
            state.started = true
            return true
        }
        guard canStart else {
            completion(.failure(CancellationError()))
            return
        }

        let launch = PreparedLaunch(
            executablePath: executable.path,
            arguments: arguments,
            environment: environment,
            workingDirectoryPath: workingDirectory?.path
        )
        var ptyFD: Int32 = -1
        var window = winsize(
            ws_row: 40,
            ws_col: 120,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let childPID = forkpty(&ptyFD, nil, nil, &window)
        guard childPID >= 0 else {
            let spawnErrno = errno
            state.withLock { state in
                state.started = false
            }
            completion(.failure(BurnBarSwitcherShellError.terminalSpawnFailed(
                "Failed to allocate a Linux pseudo-terminal: \(String(cString: strerror(spawnErrno)))."
            )))
            return
        }

        if childPID == 0 {
            launch.exec()
        }

        let shouldCancel = state.withLock { state -> Bool in
            state.ptyFD = ptyFD
            state.childPID = childPID
            return state.cancelled
        }
        if shouldCancel {
            terminateProcessGroup(childPID)
        }

        let flags = fcntl(ptyFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(ptyFD, F_SETFL, flags | O_NONBLOCK)
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            runLoop(completion: completion)
        }
    }

    /// Runs in a background queue until the child and any descendants have
    /// released the PTY.  The fixed-size read buffer plus capped state keeps
    /// output bounded even when a provider prints an unbounded diagnostic.
    private func runLoop(
        completion: @escaping @Sendable (Result<(status: Int32, output: String), Error>) -> Void
    ) {
        let (ptyFD, childPID) = state.withLock { ($0.ptyFD, $0.childPID) }
        guard ptyFD >= 0, childPID > 0 else {
            completion(.failure(BurnBarSwitcherShellError.terminalSpawnFailed("PTY session state was not initialized.")))
            return
        }

        var output = Data()
        var waitStatus: Int32 = 0
        var childReaped = false

        while !childReaped {
            var descriptor = pollfd(
                fd: ptyFD,
                events: Int16(truncatingIfNeeded: POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = poll(&descriptor, 1, Self.pollMilliseconds)
            if pollResult < 0, errno != EINTR {
                break
            }
            if pollResult > 0 {
                drain(ptyFD: ptyFD, into: &output)
            }

            let result = waitpid(childPID, &waitStatus, WNOHANG)
            if result == childPID {
                childReaped = true
            } else if result < 0, errno != EINTR {
                // ECHILD means another cleanup path already reaped the child;
                // the PTY drain below still preserves whatever output arrived.
                childReaped = errno == ECHILD
            }
        }

        // A CLI can leave grandchildren behind after its shell exits.  The
        // process group created by forkpty is ours, so clean it before closing
        // the master and returning to the caller.
        terminateProcessGroup(childPID)
        drain(ptyFD: ptyFD, into: &output)
        close(ptyFD)
        state.withLock { state in
            state.ptyFD = -1
            state.childPID = -1
        }

        let cancelled = state.read().cancelled
        if cancelled {
            completion(.failure(CancellationError()))
            return
        }

        let status = Self.exitCode(from: waitStatus)
        // Linux's default terminal output mode maps LF to CRLF.  Normalize it
        // at the shell boundary so existing quota classifiers and callers see
        // the same text they saw with pipe-backed execution.
        let text = String(decoding: output, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        completion(.success((status: status, output: text)))
    }

    private func drain(ptyFD: Int32, into output: inout Data) {
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                read(ptyFD, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 {
                let room = max(0, Self.outputByteCap - output.count)
                if room > 0 {
                    output.append(contentsOf: buffer.prefix(min(room, bytesRead)))
                }
                continue
            }
            if bytesRead < 0, errno == EINTR {
                continue
            }
            // PTY masters commonly report EIO instead of EOF when the slave
            // closes.  Both indicate that there is no more output to drain.
            return
        }
    }

    private func cancel() {
        let childPID = state.withLock { state -> pid_t in
            state.cancelled = true
            return state.childPID
        }
        guard childPID > 0 else { return }
        _ = kill(-childPID, SIGTERM)
        // The polling loop performs the final SIGKILL and wait.  This delayed
        // escalation covers a child that ignores SIGTERM without closing the
        // PTY from the cancellation handler itself.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(Self.terminationGraceNanoseconds))) { [weak self] in
            guard let self, self.state.read().childPID == childPID else { return }
            _ = kill(-childPID, SIGKILL)
        }
    }

    private func terminateProcessGroup(_ childPID: pid_t) {
        guard childPID > 0 else { return }
        _ = kill(-childPID, SIGTERM)
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.terminationGraceNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var status: Int32 = 0
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID || (result < 0 && errno == ECHILD) {
                break
            }
            if result < 0, errno != EINTR {
                break
            }
            usleep(25_000)
        }
        _ = kill(-childPID, SIGKILL)
        var status: Int32 = 0
        while waitpid(childPID, &status, 0) < 0, errno == EINTR {}
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        guard waitStatus & 0x7f == 0 else {
            return 128 + (waitStatus & 0x7f)
        }
        return (waitStatus >> 8) & 0xff
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

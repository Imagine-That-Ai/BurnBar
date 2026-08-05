import Foundation
import OpenBurnBarEngine

/// Result of a bounded subprocess run.
struct BurnBarAIInboxProcessResult: Sendable, Hashable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

enum BurnBarAIInboxProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case timedOut(String)
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "Executable not found on PATH: \(name)"
        case .timedOut(let name):
            return "\(name) timed out"
        case .launchFailed(let name, let reason):
            return "Failed to launch \(name): \(reason)"
        }
    }
}

/// Runs `git` and `gh` for the inbox's evidence collectors.
///
/// Everything here is injectable (`BurnBarAIInboxProcessRunning`) so tests drive
/// detectors from canned JSON without ever touching the real binaries or the
/// network.
///
/// Hardening (mirrors `BurnBarProjectCodeMemoryStore`'s hardened git process):
///   • absolute executable path, never a shell — no argument-injection surface
///   • hooks, credential helpers, and inherited `GIT_*` variables stripped
///   • hard wall-clock timeout with process termination
///   • output byte cap, so a pathological repo cannot balloon daemon memory
protocol BurnBarAIInboxProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval,
        environmentOverrides: [String: String]
    ) async throws -> BurnBarAIInboxProcessResult
}

extension BurnBarAIInboxProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> BurnBarAIInboxProcessResult {
        try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            environmentOverrides: [:]
        )
    }
}

struct BurnBarAIInboxProcessRunner: BurnBarAIInboxProcessRunning {
    /// 4 MiB. A `gh run list --limit 100` payload is ~200 KiB; this is generous
    /// while still bounding a hostile or broken tool.
    static let maxOutputBytes = 4 * 1024 * 1024

    /// Common install locations, probed in order. A LaunchAgent inherits a
    /// minimal `PATH` (typically `/usr/bin:/bin:/usr/sbin:/sbin`), so relying on
    /// `PATH` alone would make `gh` invisible to the daemon even when it is
    /// installed and authenticated for the user's shell.
    static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/opt/local/bin",
        "/run/current-system/sw/bin",
        "/home/linuxbrew/.linuxbrew/bin"
    ]

    /// Resolves an executable name to an absolute path, or `nil` when absent.
    /// Absolute inputs are returned as-is when executable.
    static func locate(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Last resort: honor an explicitly configured PATH.
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":").map(String.init) where directory.isEmpty == false {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval,
        environmentOverrides: [String: String]
    ) async throws -> BurnBarAIInboxProcessResult {
        guard let resolved = Self.locate(executable) else {
            throw BurnBarAIInboxProcessError.executableNotFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Hop off the caller's thread: `Process` + pipe draining is blocking.
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: resolved)
                process.arguments = arguments
                if let workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }
                process.environment = Self.hardenedEnvironment(overrides: environmentOverrides)

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                // Detach stdin so a tool that tries to prompt (a credential
                // helper, a pager) fails immediately instead of hanging the tick.
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: BurnBarAIInboxProcessError.launchFailed(
                            executable,
                            error.localizedDescription
                        )
                    )
                    return
                }

                // Drain both pipes concurrently. Reading them serially deadlocks
                // as soon as the child fills the pipe we are not reading.
                let group = DispatchGroup()
                let bufferLock = NSLock()
                var outputData = Data()
                var errorData = Data()

                for (pipe, isStdout) in [(outputPipe, true), (errorPipe, false)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { group.leave() }
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        bufferLock.lock()
                        if isStdout {
                            outputData = data.prefix(Self.maxOutputBytes)
                        } else {
                            errorData = data.prefix(64 * 1024)
                        }
                        bufferLock.unlock()
                    }
                }

                var timedOut = false
                let deadline = DispatchTime.now() + timeout
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                        // Escalate if the child ignores SIGTERM.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)

                process.waitUntilExit()
                watchdog.cancel()
                group.wait()

                if timedOut {
                    continuation.resume(throwing: BurnBarAIInboxProcessError.timedOut(executable))
                    return
                }

                bufferLock.lock()
                let result = BurnBarAIInboxProcessResult(
                    exitCode: process.terminationStatus,
                    standardOutput: String(data: outputData, encoding: .utf8) ?? "",
                    standardError: String(data: errorData, encoding: .utf8) ?? ""
                )
                bufferLock.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    /// Inherit the user's environment (so `gh` finds its config and token) but
    /// strip anything that could redirect git/gh at another repo, another host,
    /// or an interactive prompt.
    private static func hardenedEnvironment(overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { entry in
            entry.key.hasPrefix("GIT_") == false
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GCM_INTERACTIVE"] = "never"
        // gh: never page, never prompt, never color-code the JSON we parse.
        environment["GH_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        // Non-interactivity, belt and braces. A LaunchAgent has no terminal, so a
        // tool that decides to prompt would block until the watchdog kills it —
        // a hard-to-diagnose stall rather than a clean failure. These make every
        // known prompt path fail fast instead:
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"   // no "a new gh is available" interstitial
        environment["GH_PROMPT"] = "disabled"        // newer gh honours this spelling
        environment["CI"] = "1"                      // widely-honoured "assume non-interactive"
        environment["DEBIAN_FRONTEND"] = "noninteractive"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SUDO_ASKPASS"] = "/usr/bin/false"
        // Detach from any TTY/session so a credential helper cannot escalate to
        // a GUI prompt on the user's behalf.
        environment["DISPLAY"] = ""
        environment.removeValue(forKey: "SSH_AUTH_SOCK")
        if environment["PATH"] == nil || environment["PATH"]?.isEmpty == true {
            environment["PATH"] = searchPaths.joined(separator: ":")
        }
        for (key, value) in overrides { environment[key] = value }
        return environment
    }
}

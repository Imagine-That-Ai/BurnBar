#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation
import OSLog

/// A visible **interactive** agent-CLI session launched in Terminal.app, paired
/// with the `CGWindowID` of the Terminal window it created. Callers pin a
/// ScreenCaptureKit stream to `windowID` so the iPhone sees only that one
/// terminal (a native TUI) instead of the whole desktop.
struct LaunchedAgentTerminalSession: Sendable, Equatable {
    let sessionID: String
    let runtimeId: String
    /// `nil` if the new Terminal window could not be resolved (the caller then
    /// falls back to full-display capture rather than failing the mirror).
    let windowID: CGWindowID?
    let pidFilePath: String
    let sessionDirectoryPath: String
    let titleToken: String
}

/// Launches an agent's CLI **interactively** (bare REPL/TUI, no one-shot
/// `-p`/`exec` flags) in a visible Mac Terminal window and resolves the new
/// window's `CGWindowID`.
///
/// Reuses the same `open -a Terminal <run.command>` mechanism as the existing
/// one-shot visible-CLI mission path in `CLIAgentMissionRequestListener`, which
/// already ships in the sandboxed Mac App Store build — so this launcher is NOT
/// `DISTRIBUTION_MAS`-gated. Window enumeration uses
/// `ScreenCapturePipeline.availableWindows()` (ScreenCaptureKit), available in
/// both builds. Only live keystroke injection into the TUI (handled elsewhere
/// via `MacInputController`) is direct-build only.
@MainActor
enum InteractiveTerminalLauncher {
    static let terminalBundleIdentifier = "com.apple.Terminal"

    private static let log = Logger(
        subsystem: "com.openburnbar.app",
        category: "InteractiveTerminalLauncher"
    )

    enum Failure: LocalizedError, Equatable {
        case unsupportedRuntime(String)
        case executableNotFound(String)
        case terminalLaunchFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedRuntime(let runtime):
                return "Interactive CLI mode is not available for '\(runtime)'."
            case .executableNotFound(let name):
                return "The '\(name)' CLI was not found on the Mac PATH."
            case .terminalLaunchFailed:
                return "macOS could not open Terminal for the interactive CLI session."
            }
        }
    }

    /// The bare interactive invocation for a runtime, keyed by the runtime id
    /// string carried on the wire (`CLIAgentRuntime`/`AssistantRuntimeID` raw
    /// values). Returns `nil` for runtimes that have no interactive surface.
    struct Invocation: Equatable {
        let executableName: String
        let arguments: [String]
        let extraEnvironment: [String: String]
    }

    static func interactiveInvocation(
        runtimeId: String,
        modelID: String?,
        workingDirectory: URL?
    ) -> Invocation? {
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyToken
        switch runtimeId.lowercased() {
        case "codex":
            var arguments: [String] = []
            if let model { arguments += ["-m", model] }
            return Invocation(executableName: "codex", arguments: arguments, extraEnvironment: [:])
        case "claude":
            var arguments: [String] = []
            if let model { arguments += ["--model", model] }
            return Invocation(executableName: "claude", arguments: arguments, extraEnvironment: [:])
        case "droid":
            var arguments: [String] = []
            if let model { arguments += ["--model", model] }
            return Invocation(executableName: "droid", arguments: arguments, extraEnvironment: [:])
        case "forge":
            var arguments: [String] = []
            if let model, ["forge", "muse", "sage"].contains(model.lowercased()) {
                arguments += ["--agent", model]
            }
            return Invocation(executableName: "forge", arguments: arguments, extraEnvironment: [:])
        case "antigravity":
            var arguments: [String] = []
            if let workingDirectory { arguments += ["--add-dir", workingDirectory.path] }
            return Invocation(executableName: "agy", arguments: arguments, extraEnvironment: [:])
        case "grok":
            return Invocation(executableName: "grok", arguments: [], extraEnvironment: [:])
        case "openclaw":
            var arguments: [String] = []
            if let model { arguments += ["--model", model] }
            return Invocation(executableName: "openclaude", arguments: arguments, extraEnvironment: [:])
        case "cursoragent", "cursor-agent":
            var arguments: [String] = []
            if let model { arguments += ["--model", model] }
            return Invocation(executableName: "cursor-agent", arguments: arguments, extraEnvironment: [:])
        case "hermes":
            var arguments: [String] = []
            if let model { arguments += ["--model", model] }
            return Invocation(executableName: "hermes", arguments: arguments, extraEnvironment: [:])
        case "pi":
            var arguments: [String] = []
            if let model { arguments += ["--model", model] }
            return Invocation(executableName: "pi", arguments: arguments, extraEnvironment: [:])
        case "ollama":
            if let model {
                return Invocation(executableName: "ollama", arguments: ["run", model], extraEnvironment: [:])
            }
            return Invocation(
                executableName: "zsh",
                arguments: [
                    "-lc",
                    """
                    model="${OPENBURNBAR_OLLAMA_MODEL:-$(ollama list | awk 'NR==2 { print $1 }')}"
                    if [ -z "$model" ]; then
                      echo "No local Ollama model is installed. Pull a model or set OPENBURNBAR_OLLAMA_MODEL." >&2
                      exit 66
                    fi
                    exec ollama run "$model"
                    """
                ],
                extraEnvironment: [:]
            )
        default:
            return nil
        }
    }

    /// Launch the runtime's interactive CLI in Terminal.app and resolve the new
    /// window's `CGWindowID`.
    static func launchInteractive(
        runtimeId: String,
        workingDirectory: URL? = nil,
        modelID: String? = nil
    ) async throws -> LaunchedAgentTerminalSession {
        guard let invocation = interactiveInvocation(
            runtimeId: runtimeId,
            modelID: modelID,
            workingDirectory: workingDirectory
        ) else {
            throw Failure.unsupportedRuntime(runtimeId)
        }
        guard let executable = await CLIExecutableResolver().resolveExecutable(named: invocation.executableName) else {
            throw Failure.executableNotFound(invocation.executableName)
        }

        let sessionID = "interactive-\(runtimeId.lowercased())-\(UUID().uuidString)"
        let titleToken = "OBBCLI-\(UUID().uuidString.prefix(8))"

        // Snapshot existing Terminal windows so we can identify the new one by
        // diffing — robust even when the launched TUI overwrites its title.
        let existingTerminalWindows = (await ScreenCapturePipeline.availableWindows())
            .filter { $0.bundleIdentifier == terminalBundleIdentifier }
        let existingWindowIDs = Set(existingTerminalWindows.map(\.windowID))
        let existingTitlesByID = Dictionary(
            uniqueKeysWithValues: existingTerminalWindows.map { ($0.windowID, $0.title ?? "") }
        )

        let launched = try await Task.detached(priority: .userInitiated) { () -> (pidFilePath: String, sessionDirectory: String) in
            let fileManager = FileManager.default
            let rootURL = fileManager.temporaryDirectory
                .appendingPathComponent("OpenBurnBarInteractiveCLI", isDirectory: true)
            let sessionURL = rootURL.appendingPathComponent(sessionID, isDirectory: true)
            try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)

            let scriptURL = sessionURL.appendingPathComponent("run.command")
            let pidURL = sessionURL.appendingPathComponent("terminal.pid")
            let command = ([executable] + invocation.arguments)
                .map(Self.shellQuoted)
                .joined(separator: " ")

            var scriptEnvironment = ["PATH": CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)["PATH"] ?? ""]
            scriptEnvironment.merge(invocation.extraEnvironment) { _, new in new }
            let exportLines = scriptEnvironment
                .filter { Self.isValidEnvironmentKey($0.key) }
                .sorted { $0.key < $1.key }
                .map { "export \($0.key)=\(Self.shellQuoted($0.value))" }
                .joined(separator: "\n")
            let cdLine = workingDirectory.map { "cd \(Self.shellQuoted($0.path))" } ?? ""

            // Set a unique window title (best-effort secondary signal), record
            // the shell PID, then `exec` so the CLI owns the same PID — killing
            // it later terminates the TUI.
            let script = """
            #!/bin/zsh
            printf '\\033]0;\(titleToken)\\007'
            echo $$ > \(Self.shellQuoted(pidURL.path))
            \(exportLines)
            \(cdLine)
            exec \(command)
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = ["-a", "Terminal", scriptURL.path]
            try opener.run()
            opener.waitUntilExit()
            guard opener.terminationStatus == 0 else {
                throw Failure.terminalLaunchFailed
            }
            return (pidURL.path, sessionURL.path)
        }.value

        // Bring Terminal frontmost so the captured window is active and (direct
        // build) injected keystrokes land in it.
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == terminalBundleIdentifier }?
            .activate()

        let windowID = await resolveNewTerminalWindowID(
            excluding: existingWindowIDs,
            existingTitlesByID: existingTitlesByID,
            titleToken: titleToken
        )
        if windowID == nil {
            log.error("interactive_terminal_window_unresolved runtime=\(runtimeId, privacy: .public)")
        } else {
            log.info("interactive_terminal_window_resolved runtime=\(runtimeId, privacy: .public)")
        }

        return LaunchedAgentTerminalSession(
            sessionID: sessionID,
            runtimeId: runtimeId,
            windowID: windowID,
            pidFilePath: launched.pidFilePath,
            sessionDirectoryPath: launched.sessionDirectory,
            titleToken: titleToken
        )
    }

    /// Poll for the Terminal window that appeared after launch. Prefers a
    /// window still carrying the unique title token; otherwise the first
    /// window that was not present in the pre-launch snapshot.
    static func resolveNewTerminalWindowID(
        excluding existing: Set<CGWindowID>,
        existingTitlesByID: [CGWindowID: String] = [:],
        titleToken: String,
        attempts: Int = 24,
        intervalNanoseconds: UInt64 = 250_000_000
    ) async -> CGWindowID? {
        var lastTerminalWindows: [ScreenCapturePipeline.WindowDescriptor] = []
        for _ in 0..<max(1, attempts) {
            let terminalWindows = (await ScreenCapturePipeline.availableWindows())
                .filter { $0.bundleIdentifier == terminalBundleIdentifier }
            lastTerminalWindows = terminalWindows
            if let resolved = resolvedTerminalWindowID(
                from: terminalWindows,
                excluding: existing,
                existingTitlesByID: existingTitlesByID,
                titleToken: titleToken,
                allowFrontmostFallback: false
            ) {
                return resolved
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return resolvedTerminalWindowID(
            from: lastTerminalWindows,
            excluding: existing,
            existingTitlesByID: existingTitlesByID,
            titleToken: titleToken,
            allowFrontmostFallback: true
        )
    }

    static func resolvedTerminalWindowID(
        from terminalWindows: [ScreenCapturePipeline.WindowDescriptor],
        excluding existing: Set<CGWindowID>,
        existingTitlesByID: [CGWindowID: String] = [:],
        titleToken: String,
        allowFrontmostFallback: Bool
    ) -> CGWindowID? {
        if let tokenMatch = terminalWindows.first(where: { ($0.title ?? "").contains(titleToken) }) {
            return tokenMatch.windowID
        }
        if let fresh = terminalWindows.first(where: { !existing.contains($0.windowID) }) {
            return fresh.windowID
        }
        if let retitled = terminalWindows.first(where: { window in
            guard existing.contains(window.windowID),
                  let previousTitle = existingTitlesByID[window.windowID] else {
                return false
            }
            let currentTitle = window.title ?? ""
            return !currentTitle.isEmpty && currentTitle != previousTitle
        }) {
            return retitled.windowID
        }
        if allowFrontmostFallback {
            return terminalWindows.first?.windowID
        }
        return nil
    }

    /// Terminate the launched CLI process tree and clean up the session dir.
    /// The blocking kill runs off the main actor so teardown never stalls the UI.
    static func terminate(_ session: LaunchedAgentTerminalSession) {
        let pidFilePath = session.pidFilePath
        let sessionDirectoryPath = session.sessionDirectoryPath
        Task.detached(priority: .utility) {
            killSessionTree(pidURL: URL(fileURLWithPath: pidFilePath))
            try? FileManager.default.removeItem(atPath: sessionDirectoryPath)
        }
    }

    // MARK: - Helpers

    /// Recursively SIGTERM the launched shell/CLI and its children. Mirrors
    /// `CLIAgentMissionRequestListener.killVisibleTerminalSession`.
    private nonisolated static func killSessionTree(pidURL: URL) {
        guard let rawPID = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              pid > 0
        else { return }
        let killScript = """
        kill_tree() {
            local _pid=$1
            for _child in $(pgrep -P $_pid); do
                kill_tree $_child
            done
            kill -TERM $_pid 2>/dev/null
        }
        kill_tree \(pid)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", killScript]
        try? process.run()
        process.waitUntilExit()
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_").contains(first)
        else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        return key.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

private extension String {
    var nilIfEmptyToken: String? { isEmpty ? nil : self }
}
#endif

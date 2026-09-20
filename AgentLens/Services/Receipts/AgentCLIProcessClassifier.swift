import Foundation
import os
import OpenBurnBarKernel

/// The house `/bin/ps` ownership rules shared by Pixel Clock and receipt
/// announce. One matcher, one snapshot — Cursor.app does not count,
/// helpers do not count, `cursor-agent` does even when it lives inside
/// `Cursor.app/Contents`.
///
/// Matching is the **first real executable basename** after wrappers
/// (`node`, `env`, `npx`, …). Intermediate directories, later argv words
/// (`--message grok`, `git commit -m claude`), and `--model` flags must
/// not impersonate a running CLI.
enum AgentCLIProcessClassifier: Sendable {
    /// Pixel Clock and receipts must read the same `/bin/ps` columns.
    /// `COMM` plus `ARGS` (header dropped) — not `args=` alone.
    static let processListArguments = ["-axo", "comm,args"]

    /// Which agent owns this process line, if any.
    ///
    /// Hyphenated hosts still resolve (`codex-code-mode-host` → Codex) the
    /// same way Pixel Clock always did. Cursor is the exception: only the
    /// `cursor-agent` executable counts. The IDE GUI binary
    /// (`Cursor.app/Contents/MacOS/Cursor`) does not.
    static func provider(forProcessLine line: String) -> AgentProvider? {
        let lower = line.lowercased()
        guard let parsed = firstExecutable(in: lower) else { return nil }
        // House processes only — never a later argv word. `prime-agent
        // --provider openburnbar` and a Codex binary inside this worktree
        // must still count as live CLIs.
        if isHouseProcess(executable: parsed.base) { return nil }
        if isServiceProcess(executable: parsed.base, argumentBases: parsed.argumentBases) {
            return nil
        }

        func named(_ names: String..., hyphenatedHost: Bool = true) -> Bool {
            let base = parsed.base
            for name in names {
                if base == name { return true }
                if hyphenatedHost, base.hasPrefix(name + "-") { return true }
            }
            return false
        }

        if named("codex") { return .codex }
        if named("claudecode", "claude-code") || named("claude", hyphenatedHost: false) {
            return .claudeCode
        }
        // `droid` / `factory-cli` only. `factory` as a directory is not the CLI.
        if named("droid", hyphenatedHost: false) || named("factory-cli", hyphenatedHost: false) {
            return .factory
        }
        if named("opencode") || named("open-code") { return .openCode }
        if named("openclaw") || named("open-claw") { return .openClaw }
        // `cursor-agent` only. A lone `cursor` token is the IDE or a path.
        if named("cursor-agent", hyphenatedHost: false) { return .cursor }
        if named("minimax") || named("mini-max") { return .minimax }
        if named("zai", "z.ai") || named("z-ai") { return .zai }
        if named("kimi", "moonshot", hyphenatedHost: false) { return .kimi }
        if named("xai", "x.ai", "grok", "supergrok") || named("x-ai") { return .xAI }
        if named("hermes", hyphenatedHost: false) { return .hermes }
        if named("pi-agent", hyphenatedHost: false) { return .piAgent }
        if named("gemini", "gemini-cli", hyphenatedHost: false) { return .geminiCLI }
        if named("aider", hyphenatedHost: false) { return .aider }
        if named("goose", hyphenatedHost: false) { return .goose }
        if named("antigravity", "antigravity-cli", hyphenatedHost: false) { return .antigravity }
        if named("muse", hyphenatedHost: false) { return .muse }
        if named("openclaude") || named("open-claude") { return .openClaude }
        if named("prime-agent", hyphenatedHost: false) { return .primeAgent }
        if named("junie", hyphenatedHost: false) { return .junie }
        if named("ollama", hyphenatedHost: false) { return .ollama }
        if named("forge", "forgedev", hyphenatedHost: false) { return .forgeDev }
        if named("omp", hyphenatedHost: false) { return .omp }
        if named("copilot", hyphenatedHost: false) { return .copilot }
        if named("cline", hyphenatedHost: false) { return .cline }
        if named("kilo-code", "kilocode", hyphenatedHost: false) { return .kiloCode }
        if named("roo-code", hyphenatedHost: false) { return .rooCode }
        if named("auggie", "augment-cli", hyphenatedHost: false) { return .augment }
        if named("fx", hyphenatedHost: false) { return .fx }
        return nil
    }

    /// Receipt announce treats Cursor.app as closed and `cursor-agent` as
    /// open, whether the session was stored as `.cursor` or `.cursorAgent`.
    static func runtimeFamily(for provider: AgentProvider) -> AgentProvider {
        switch provider {
        case .cursor, .cursorAgent:
            return .cursor
        default:
            return provider
        }
    }

    /// True when receipts can actually see this harness leave: a named
    /// executable and/or a dedicated agent-app bundle. IDE-only providers
    /// (Windsurf, Devin, Cursor Composer without `cursor-agent`) cannot
    /// be proven closed from `/bin/ps`, so quiet time must not announce.
    static func canObserveRuntime(for provider: AgentProvider) -> Bool {
        if !ProcessReceiptCLIRuntimeProbe.dedicatedBundleIDs(for: provider).isEmpty {
            return true
        }
        switch runtimeFamily(for: provider) {
        case .codex, .claudeCode, .factory, .openCode, .openClaw, .cursor,
             .minimax, .zai, .kimi, .xAI, .hermes, .piAgent, .geminiCLI,
             .aider, .goose, .antigravity, .muse, .openClaude, .primeAgent,
             .junie, .ollama, .forgeDev, .omp, .copilot, .cline, .kiloCode,
             .rooCode, .augment, .fx, .warp:
            return true
        default:
            return false
        }
    }

    /// Last path component of each argv token. Flags (`--model grok-…`)
    /// and wrappers are skipped; only the first real executable remains.
    static func commandBases(in line: String) -> [String] {
        guard let parsed = firstExecutable(in: line.lowercased()) else { return [] }
        return [parsed.base]
    }

    /// Drop the `COMM ARGS` header that `ps -axo comm,args` prints.
    static func processLines(fromPSOutput output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).dropFirst().map(String.init)
    }

    /// When the project path is long enough to be distinctive and appears
    /// on a live process line, that session is still open. When other
    /// family processes name a *different* `/Users` or `/Volumes`
    /// workspace, this session is closed. Bare `codex exec` with no path
    /// stays conservative (any matching process holds every slip).
    static func projectPathKeepsSessionOpen(
        projectPath: String?,
        familyLines: [String]
    ) -> Bool {
        guard let needle = usableProjectNeedle(projectPath) else { return true }
        if familyLines.contains(where: { lineContainsProjectPath($0, needle) }) {
            return true
        }
        // A bare `codex exec` with no workspace may be this session. A
        // sibling that names a different repo must not close it.
        if familyLines.contains(where: { !mentionsWorkspaceRoot($0) }) {
            return true
        }
        let othersNameAWorkspace = familyLines.contains { line in
            mentionsWorkspaceRoot(line) && !lineContainsProjectPath(line, needle)
        }
        if othersNameAWorkspace { return false }
        return true
    }

    /// Live snapshot used by Pixel Clock and receipt announce.
    /// `/bin/ps` is capped at one second so a stuck spawn cannot hang
    /// the Pixel Clock heartbeat or the close monitor.
    static func liveProcessLines() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = processListArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }

        // Drain stdout while `ps` is still running. Waiting for exit first
        // deadlocks when the process list exceeds the pipe buffer, and an
        // empty snapshot looks like "every CLI closed."
        let handle = pipe.fileHandleForReading
        let chunks = OSAllocatedUnfairLock(initialState: Data())
        handle.readabilityHandler = { file in
            let more = file.availableData
            guard !more.isEmpty else { return }
            chunks.withLock { $0.append(more) }
        }

        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        handle.readabilityHandler = nil
        var data = chunks.withLock { $0 }
        data.append(handle.readDataToEndOfFile())
        guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return [] }
        return processLines(fromPSOutput: output)
    }

    private static let wrappers: Set<String> = [
        "node", "nodejs", "env", "nice", "nohup", "sudo", "arch",
        "command", "npx", "bun", "deno", "sh", "bash", "zsh", "time"
    ]

    private static let serviceTokens: Set<String> = [
        "daemon", "proxy", "bridge", "mcp", "server",
        "language-server", "tsserver", "typingsinstaller",
        "native-host", "helper", "helpers"
    ]

    private struct ParsedCommand: Sendable {
        let base: String
        let argumentBases: [String]
    }

    /// COMM + ARGS from `ps -axo comm,args`. Skip wrappers and `ENV=val`,
    /// then the first remaining basename is the executable.
    private static func firstExecutable(in line: String) -> ParsedCommand? {
        var base: String?
        var argumentBases: [String] = []
        for raw in line.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard !raw.isEmpty, !raw.hasPrefix("-") else { continue }
            if raw.contains("="), !raw.contains("/") { continue }
            let token = raw.split(separator: "/").last.map(String.init) ?? raw
            guard !token.isEmpty else { continue }
            if wrappers.contains(token) { continue }
            if base == nil {
                base = token
            } else if token != base {
                // `ps -axo comm,args` repeats the executable in ARGS
                // (`droid /path/to/droid daemon`). That copy is not the
                // subcommand.
                argumentBases.append(token)
            }
        }
        guard let base else { return nil }
        return ParsedCommand(base: base, argumentBases: argumentBases)
    }

    /// BurnBar itself, `/bin/ps`, and Chrome native-host helpers.
    /// Matching the *line* hid every CLI whose argv mentioned this repo.
    private static func isHouseProcess(executable: String) -> Bool {
        if executable == "ps" { return true }
        if executable.contains("openburnbar") { return true }
        if executable.contains("pixelclockexternalagentactivityscanner") { return true }
        if executable.contains("chrome-native-host") || executable == "native-host" {
            return true
        }
        return false
    }

    /// `codex-daemon` and `droid daemon` are services. A later prompt word
    /// (`codex exec "fix server"`) is not. `ollama serve` is the local
    /// daemon, not an agent session. A directory named `server` on the
    /// executable path is not a service either.
    private static func isServiceProcess(executable: String, argumentBases: [String]) -> Bool {
        if hyphenTokens(executable).contains(where: { serviceTokens.contains($0) }) {
            return true
        }
        guard let command = argumentBases.first else { return false }
        if executable == "ollama", command == "serve" || command == "runner" {
            return true
        }
        return serviceTokens.contains(command)
            || hyphenTokens(command).contains(where: { serviceTokens.contains($0) })
    }

    private static func hyphenTokens(_ value: String) -> [String] {
        value.split { $0 == "-" || (!$0.isLetter && !$0.isNumber && $0 != ".") }.map(String.init)
    }

    /// `/tmp` is too short to isolate sessions. Require a distinctive path.
    private static func usableProjectNeedle(_ projectPath: String?) -> String? {
        guard let raw = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 12
        else { return nil }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path.lowercased()
        guard path.count >= 12 else { return nil }
        return path
    }

    private static func mentionsWorkspaceRoot(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("/users/")
            || lower.contains("/volumes/")
            || lower.contains("/home/")
    }

    /// `/Users/a/burnbar` must not match `/Users/a/burnbar-old`.
    private static func lineContainsProjectPath(_ line: String, _ needle: String) -> Bool {
        let lower = line.lowercased()
        guard let range = lower.range(of: needle) else { return false }
        if range.upperBound == lower.endIndex { return true }
        let next = lower[range.upperBound]
        return next == "/" || next.isWhitespace || next == "\"" || next == "'"
    }
}

import Darwin
import Foundation
import OpenBurnBarCore

// MARK: - ClaudeInteractiveSessionExecutor (Part B2 — experimental, off by default)

/// **Experimental, off-by-default** gateway path that serves an Anthropic
/// subscription completion by driving a *genuine interactive* `claude` TUI
/// through a pseudo-terminal (no `-p`/`--print`, which are the explicitly
/// metered programmatic paths).
///
/// ## Risk posture (read before enabling)
///
/// Anthropic's post-June-15 terms prohibit routing Pro/Max credentials through
/// third-party apps, and the interactive-vs-programmatic detection heuristic is
/// undocumented and may change without notice. This path is therefore:
///
/// - **Off by default.** It is only constructed when
///   `OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE=1` is exported for the daemon.
/// - **Best-effort.** Driving and scraping a TUI is brittle; on any failure we
///   surface an error so the caller can fall back to the legit B3 path.
/// - **Subscription-only.** Eligibility requires an Anthropic OAuth token
///   (`sk-ant-oat…`); Console API keys (`sk-ant-api…`) never take this path.
///
/// ## How a turn runs
///
/// Each request spawns a fresh interactive `claude` in a unique temp working
/// directory. Because Claude Code derives its session-log directory from the
/// cwd, that isolation lets us read **exactly this turn's** assistant text and
/// real token usage from the freshly-written `~/.claude/projects/<encoded>/*.jsonl`
/// — far more reliable than parsing the ANSI render. ANSI scraping remains as a
/// fallback. Concurrency is bounded by an async semaphore (the "pool").
public final class ClaudeInteractiveSessionExecutor: Sendable {

    public struct Configuration: Sendable {
        public var maxConcurrentSessions: Int
        public var quiescenceIdle: TimeInterval
        public var overallTimeout: TimeInterval
        public var claudeExecutableURL: URL?

        public init(
            maxConcurrentSessions: Int = 2,
            quiescenceIdle: TimeInterval = 4.0,
            overallTimeout: TimeInterval = 180,
            claudeExecutableURL: URL? = nil
        ) {
            self.maxConcurrentSessions = max(1, maxConcurrentSessions)
            self.quiescenceIdle = quiescenceIdle
            self.overallTimeout = overallTimeout
            self.claudeExecutableURL = claudeExecutableURL
        }
    }

    private let configuration: Configuration
    private let semaphore: AsyncSemaphore
    private let logger: BurnBarDaemonLogger
    private let fileSystem: any SendableFileSystem
    private let warnedOnce = Locked(false)

    public init(
        configuration: Configuration = Configuration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "claude-interactive-executor"),
        fileSystem: any SendableFileSystem = DefaultSendableFileSystem()
    ) {
        self.configuration = configuration
        self.semaphore = AsyncSemaphore(value: configuration.maxConcurrentSessions)
        self.logger = logger
        self.fileSystem = fileSystem
    }

    /// Constructs the executor only when the experimental opt-in env var is set
    /// to a truthy value. Returns `nil` otherwise so the gateway leaves the path
    /// entirely off.
    public static func makeIfEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configuration: Configuration = Configuration(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "claude-interactive-executor")
    ) -> ClaudeInteractiveSessionExecutor? {
        guard Self.isOptedIn(environment: environment) else { return nil }
        logger.warning("claude_interactive_executor_enabled", metadata: [
            "warning": "experimental gray-area path; Anthropic ToS prohibits 3p credential routing"
        ])
        return ClaudeInteractiveSessionExecutor(configuration: configuration, logger: logger)
    }

    static func isOptedIn(environment: [String: String]) -> Bool {
        let raw = (environment["OPENBURNBAR_EXPERIMENTAL_INTERACTIVE_CLAUDE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["1", "true", "yes", "on"].contains(raw)
    }

    // MARK: - Eligibility

    /// Only genuine Anthropic OAuth subscription identities are eligible. The
    /// gateway should consult this before dispatching to keep Console keys and
    /// other vendors on their normal executors.
    public static func isEligible(route: BurnBarProviderRoute) -> Bool {
        let isAnthropicFamily = route.formatFamily == .anthropic
            || route.providerID.caseInsensitiveCompare("anthropic") == .orderedSame
            || route.providerID.caseInsensitiveCompare("claude") == .orderedSame
        guard isAnthropicFamily else { return false }
        let key = route.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.hasPrefix("sk-ant-oat")
    }

    // MARK: - Gateway-shaped entry points

    public func proxyChatCompletions(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let parsed = try Self.chatCompletionPrompt(from: body)
        let turn = try await runTurn(prompt: parsed.prompt, route: route)
        let body = try Self.chatCompletionResponseBody(
            modelID: route.resolvedModelID,
            output: turn.text,
            stream: parsed.stream,
            outputTokens: turn.outputTokens
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: parsed.stream ? "text/event-stream" : "application/json",
            body: body,
            usage: Self.usage(prompt: parsed.prompt, turn: turn)
        )
    }

    public func proxyResponses(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let parsed = try Self.responsesPrompt(from: body)
        let turn = try await runTurn(prompt: parsed.prompt, route: route)
        let body = try Self.responsesBody(
            modelID: route.resolvedModelID,
            output: turn.text,
            stream: parsed.stream,
            outputTokens: turn.outputTokens
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: parsed.stream ? "text/event-stream" : "application/json",
            body: body,
            usage: Self.usage(prompt: parsed.prompt, turn: turn)
        )
    }

    public func proxyMessages(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let parsed = try Self.anthropicPrompt(from: body)
        let turn = try await runTurn(prompt: parsed.prompt, route: route)
        let body = try Self.anthropicResponseBody(
            modelID: route.resolvedModelID,
            output: turn.text,
            inputTokens: turn.inputTokens ?? max(1, parsed.prompt.count / 4),
            outputTokens: turn.outputTokens ?? max(1, turn.text.count / 4)
        )
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: body,
            usage: Self.usage(prompt: parsed.prompt, turn: turn)
        )
    }

    // MARK: - Turn execution

    struct TurnResult: Sendable {
        let text: String
        let inputTokens: Int?
        let outputTokens: Int?
        var tokenConfidence: BurnBarUsageConfidence {
            (inputTokens != nil || outputTokens != nil) ? .highConfidenceEstimate : .lowConfidenceEstimate
        }
    }

    private func runTurn(prompt: String, route: BurnBarProviderRoute) async throws -> TurnResult {
        guard Self.isEligible(route: route) else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Interactive Claude executor received an ineligible (non-OAuth) route."
            )
        }
        warnOnce()

        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        let claudeURL = try resolveClaude()

        // Unique cwd → unique Claude project dir → clean per-turn JSONL.
        let cwd = fileSystem.temporaryDirectory
            .appendingPathComponent("obb-claude-interactive-\(UUID().uuidString)", isDirectory: true)
        try fileSystem.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Claude Code keys workspace trust by the *resolved* cwd (realpath), so
        // resolve symlinks (e.g. /var/folders → /private/var/folders) to match
        // the exact key it will consult.
        let resolvedCwdPath = Self.trustProjectKey(for: cwd)

        // Pre-trust this ephemeral cwd in `~/.claude.json` BEFORE spawning. A
        // fresh temp dir has never been trusted, so without this Claude Code
        // renders its first-run "do you trust the files in this folder" dialog
        // every turn. The dialog cannot be answered reliably from a headless
        // PTY, and the prompt line we send gets swallowed as the dialog's
        // confirmation (accepting trust but losing the prompt) — the root cause
        // of the historical retry loop. See `pretrustWorkspace` for details.
        Self.pretrustWorkspace(resolvedPath: resolvedCwdPath)
        defer {
            try? fileSystem.removeItem(at: cwd)
            // Drop the ephemeral trust entry and any session-log dir so the
            // shared config does not accumulate orphan `obb-claude-interactive-*`
            // entries (the previous behavior left one per turn, forever).
            Self.untrustWorkspace(resolvedPath: resolvedCwdPath)
        }

        let projectDir = ClaudeInteractiveHandoffService.claudeProjectDirectory(for: cwd.path)

        var environment = Self.sanitizedEnvironment()
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = route.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let session = PTYInteractiveSession(
            configuration: .init(
                executableURL: claudeURL,
                arguments: Self.claudeArguments(model: route.resolvedModelID),
                environment: environment,
                workingDirectory: cwd
            )
        )

        do {
            try session.start(onOutput: { _ in })
        } catch {
            throw BurnBarProviderExecutorError.upstreamError(502, "Failed to start interactive claude: \(error.localizedDescription)")
        }

        // Let the TUI settle, dismiss a first-run trust prompt if present, then
        // submit the prompt as a single line.
        _ = await session.waitForQuiescence(idle: 1.5, overall: 20)
        Self.dismissTrustPromptIfPresent(session)
        do {
            try session.sendLine(prompt)
        } catch {
            session.terminate()
            throw BurnBarProviderExecutorError.upstreamError(502, "Failed to drive interactive claude: \(error.localizedDescription)")
        }

        let completed = await session.waitForQuiescence(
            idle: configuration.quiescenceIdle,
            overall: configuration.overallTimeout
        )
        let transcript = session.plainTranscriptText()
        session.terminate()
        // Give Claude Code a beat to flush its session JSONL to disk.
        try? await Task.sleep(nanoseconds: 400_000_000)

        if let jsonl = Self.latestAssistantTurn(projectDirectory: projectDir), !jsonl.text.isEmpty {
            return TurnResult(text: jsonl.text, inputTokens: jsonl.inputTokens, outputTokens: jsonl.outputTokens)
        }

        let scraped = Self.scrapeAssistantText(fromTranscript: transcript, prompt: prompt)
        guard !scraped.isEmpty else {
            if !completed {
                throw BurnBarProviderExecutorError.upstreamError(504, "Interactive claude turn timed out before producing output.")
            }
            throw BurnBarProviderExecutorError.invalidResponse
        }
        return TurnResult(text: scraped, inputTokens: nil, outputTokens: nil)
    }

    private func warnOnce() {
        let shouldWarn = warnedOnce.withLock { warned -> Bool in
            guard !warned else { return false }
            warned = true
            return true
        }
        if shouldWarn {
            logger.warning("claude_interactive_turn", metadata: [
                "notice": "serving completion via experimental interactive TUI; brittle and ToS-sensitive"
            ])
        }
    }

    private func resolveClaude() throws -> URL {
        if let url = configuration.claudeExecutableURL { return url }
        do {
            return try ClaudeInteractiveMeterExperiment.resolveClaudeExecutable()
        } catch {
            throw BurnBarProviderExecutorError.upstreamError(502, "The `claude` executable was not found for the interactive executor.")
        }
    }

    static func claudeArguments(model: String) -> [String] {
        var args = ["--append-system-prompt", systemPrompt]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            args.append(contentsOf: ["--model", trimmed])
        }
        return args
    }

    static let systemPrompt = """
    You are serving one OpenBurnBar routed completion in an interactive session. \
    Respond directly to the user's message as plain text. Do not run tools, edit files, \
    or execute commands unless the user explicitly asks.
    """

    /// Last-resort fallback for Claude Code's first-run workspace-trust dialog.
    ///
    /// The primary mechanism is `pretrustWorkspace`, which seeds the trust entry
    /// before launch so the dialog never renders (verified against Claude Code
    /// 2.1.183). This scraper exists only as defense-in-depth for a future
    /// version that might surface a trust gate the pre-seed does not cover. It
    /// runs once, before the user prompt is sent, so a stray Enter can never
    /// contaminate real assistant output.
    ///
    /// Detection is whitespace-insensitive: the TUI renders inter-word spacing
    /// with cursor-positioning escapes, so `plainTranscriptText()` concatenates
    /// words ("Yes,Itrustthisfolder"). The markers target the current (post
    /// 2.1.x) dialog copy; the old "do you trust the files" markers no longer
    /// match and were silently failing, which masked the loop.
    static func dismissTrustPromptIfPresent(_ session: PTYInteractiveSession) {
        let compact = session.plainTranscriptText().filter { !$0.isWhitespace }.lowercased()
        let trustDialogMarkers = [
            "issthisaprojectyoucreated", // "Is this a project you created..."
            "yes,itrustthisfolder",
            "no,exit"
        ]
        guard trustDialogMarkers.contains(where: { compact.contains($0) }) else { return }
        try? session.sendLine("")
    }

    // MARK: - Workspace trust

    /// Location of the Claude Code global config that records per-workspace trust.
    static func claudeConfigURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".claude.json", isDirectory: false)
    }

    /// The realpath key Claude Code uses for a working directory's trust entry.
    /// `~/.claude.json` `projects` is keyed by `process.cwd()`, which is the
    /// kernel-resolved realpath (symlinks fully expanded). On macOS the temp
    /// tree is `/var/folders → /private/var/folders`. Foundation's
    /// `URL.resolvingSymlinksInPath()` does NOT always reproduce that (it left
    /// the `/var` symlink unresolved in practice), so we call `realpath(3)`
    /// directly to match the exact key Claude Code consults. Requires the path
    /// to exist (the temp cwd is created before seeding); falls back to
    /// Foundation if `realpath` fails (e.g. a race removed the dir).
    static func trustProjectKey(for workingDirectory: URL) -> String {
        let path = workingDirectory.path
        if let resolved = path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return workingDirectory.resolvingSymlinksInPath().path
    }

    /// Atomically pre-trust `resolvedPath` in `~/.claude.json` so Claude Code
    /// skips its first-run workspace-trust dialog for that directory.
    ///
    /// Claude Code persists the result of clicking "Yes, I trust this folder" as
    /// `projects[<resolved-cwd>].hasTrustDialogAccepted = true` and consults it
    /// on startup to decide whether to render the gate. Setting it before launch
    /// is exactly that — verified to suppress the dialog against Claude Code
    /// 2.1.183. `resolvedPath` MUST be the realpath form (see `trustProjectKey`)
    /// because that is the key Claude Code uses.
    ///
    /// Concurrency: `~/.claude.json` is also written by the Claude Code desktop
    /// app and other daemon turns. We take an exclusive `flock` for the RMW
    /// window and commit via an atomic write, mutating only the single
    /// `projects[resolvedPath]` entry. Any read/parse/serialize failure aborts
    /// (best-effort) — the file is never replaced with partial or lossy content.
    /// Failures are logged, not thrown, so the caller still proceeds and the
    /// scrape fallback remains in play.
    static func pretrustWorkspace(
        resolvedPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "claude-interactive-executor")
    ) {
        mutateClaudeConfigProjects(resolvedPath: resolvedPath, homeDirectory: homeDirectory, logger: logger) { projects in
            var entry = (projects[resolvedPath] as? [String: Any]) ?? [:]
            entry["hasTrustDialogAccepted"] = true
            entry["hasCompletedProjectOnboarding"] = true
            projects[resolvedPath] = entry
        }
    }

    /// Inverse of `pretrustWorkspace`: removes the ephemeral trust entry so the
    /// shared config does not accumulate one orphan `obb-claude-interactive-*`
    /// entry per turn (the previous behavior left cruft forever), and deletes
    /// any session-log dir Claude Code created for this cwd.
    static func untrustWorkspace(
        resolvedPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "claude-interactive-executor")
    ) {
        let encoded = resolvedPath.replacingOccurrences(of: "/", with: "-")
        let sessionDir = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
        try? FileManager.default.removeItem(at: sessionDir)

        mutateClaudeConfigProjects(resolvedPath: resolvedPath, homeDirectory: homeDirectory, logger: logger) { projects in
            projects.removeValue(forKey: resolvedPath)
        }
    }

    /// Read-mutate-write the `projects` subtree of `~/.claude.json` under an
    /// exclusive advisory lock with an atomic commit. All failures are swallowed
    /// (logged) so trust seeding can never corrupt the shared config.
    private static func mutateClaudeConfigProjects(
        resolvedPath: String,
        homeDirectory: URL,
        logger: BurnBarDaemonLogger,
        mutate: (_ projects: inout [String: Any]) -> Void
    ) {
        let configURL = claudeConfigURL(homeDirectory: homeDirectory)
        guard configURL.isFileURL, configURL.path == configURL.standardizedFileURL.path else {
            // Defensive: never operate on a non-resolved/escaped path.
            return
        }

        let fd = configURL.path.withCString { open($0, O_RDWR) }
        guard fd >= 0 else {
            logger.warning("claude_trust_open_failed", metadata: ["errno": "\(errno)"])
            return
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            logger.warning("claude_trust_lock_failed", metadata: ["errno": "\(errno)"])
            return
        }
        defer { flock(fd, LOCK_UN) }

        guard let data = try? Data(contentsOf: configURL) else {
            logger.warning("claude_trust_read_failed")
            return
        }
        guard var root = (try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])) as? [String: Any] else {
            logger.warning("claude_trust_parse_failed")
            return
        }
        var projects = (root["projects"] as? [String: Any]) ?? [:]
        mutate(&projects)
        root["projects"] = projects

        guard let outgoing = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            logger.warning("claude_trust_serialize_failed")
            return
        }

        // Atomic write (temp + rename) preserves integrity if we crash mid-write.
        guard (try? outgoing.write(to: configURL, options: [.atomic])) != nil else {
            logger.warning("claude_trust_write_failed")
            return
        }
        // The config carries identity/session data; keep it owner-only.
        _ = configURL.path.withCString { chmod($0, 0o600) }
    }

    // MARK: - Environment

    static func sanitizedEnvironment() -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME", "SHELL"] {
            if let value = current[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                environment[key] = value
            }
        }
        environment["PATH"] = ClaudeInteractiveMeterExperiment
            .claudeRuntimePathEntries(environment: current)
            .joined(separator: ":")
        environment["HOME"] = NSHomeDirectory()
        environment["TERM"] = "xterm-256color"
        return environment
    }

    // MARK: - JSONL extraction

    struct JSONLTurn: Sendable, Equatable {
        let text: String
        let inputTokens: Int?
        let outputTokens: Int?
    }

    /// Reads the newest session JSONL in `projectDirectory` and returns the last
    /// assistant message's text plus its reported token usage.
    static func latestAssistantTurn(projectDirectory: URL?) -> JSONLTurn? {
        guard let projectDirectory else { return nil }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }
        guard !jsonlFiles.isEmpty else { return nil }
        let newest = jsonlFiles.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l < r
        }
        guard let newest, let content = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        return parseLatestAssistantTurn(jsonlContent: content)
    }

    /// Pure parser (unit-testable) over JSONL content: returns the last
    /// assistant text block and the token usage from that message.
    static func parseLatestAssistantTurn(jsonlContent: String) -> JSONLTurn? {
        var latest: JSONLTurn?
        jsonlContent.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant" else {
                return
            }
            let text = assistantText(from: message["content"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var input: Int?
            var output: Int?
            if let usage = message["usage"] as? [String: Any] {
                input = intValue(usage["input_tokens"]).map {
                    $0 + (intValue(usage["cache_read_input_tokens"]) ?? 0) + (intValue(usage["cache_creation_input_tokens"]) ?? 0)
                }
                output = intValue(usage["output_tokens"])
            }
            latest = JSONLTurn(text: text, inputTokens: input, outputTokens: output)
        }
        return latest
    }

    private static func assistantText(from content: Any?) -> String {
        switch content {
        case let string as String:
            return string
        case let array as [Any]:
            let parts = array.compactMap { element -> String? in
                guard let block = element as? [String: Any] else { return nil }
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    return text
                }
                return nil
            }
            return parts.joined(separator: "\n")
        default:
            return ""
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    // MARK: - ANSI transcript scraping (fallback)

    /// Best-effort extraction of the assistant's reply from a stripped TUI
    /// transcript, removing the echoed prompt and common chrome lines. Used only
    /// when JSONL extraction is unavailable.
    static func scrapeAssistantText(fromTranscript transcript: String, prompt: String) -> String {
        let promptTail = prompt.split(whereSeparator: \.isNewline).last.map(String.init) ?? prompt
        var lines = transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        // Drop everything up to and including the echoed prompt, if present.
        if let promptIndex = lines.lastIndex(where: { !promptTail.isEmpty && $0.contains(promptTail) }) {
            lines = Array(lines.suffix(from: lines.index(after: promptIndex)))
        }

        let chrome: [String] = [
            "? for shortcuts", "esc to interrupt", "bypass permissions",
            "do you trust", "yes, proceed", "auto-update", "tokens", "context left"
        ]
        let cleaned = lines.filter { line in
            guard !line.isEmpty else { return false }
            let lower = line.lowercased()
            if chrome.contains(where: { lower.contains($0) }) { return false }
            // Drop pure box-drawing / prompt-gutter lines.
            let stripped = line.filter { !"│╭╮╰╯─➤>•⏵✻✽✶ ".contains($0) }
            return !stripped.isEmpty
        }
        return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt parsing

    static func chatCompletionPrompt(from body: Data) throws -> (prompt: String, stream: Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        let messages = (object["messages"] as? [[String: Any]]) ?? []
        var parts: [String] = []
        for message in messages {
            let role = (message["role"] as? String ?? "user")
            let content = text(from: message["content"])
            guard !content.isEmpty else { continue }
            parts.append(role == "user" ? content : "\(role.capitalized): \(content)")
        }
        let prompt = parts.joined(separator: "\n\n")
        guard !prompt.isEmpty else { throw BurnBarProviderExecutorError.invalidResponse }
        return (prompt, object["stream"] as? Bool ?? false)
    }

    static func responsesPrompt(from body: Data) throws -> (prompt: String, stream: Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        var parts: [String] = []
        if let instructions = object["instructions"] as? String,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(instructions)
        }
        if let input = object["input"] {
            let inputText = text(from: input)
            if !inputText.isEmpty { parts.append(inputText) }
        }
        let prompt = parts.joined(separator: "\n\n")
        guard !prompt.isEmpty else { throw BurnBarProviderExecutorError.invalidResponse }
        return (prompt, object["stream"] as? Bool ?? false)
    }

    static func anthropicPrompt(from body: Data) throws -> (prompt: String, stream: Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        var parts: [String] = []
        if let system = object["system"] {
            let systemText = text(from: system)
            if !systemText.isEmpty { parts.append(systemText) }
        }
        let messages = (object["messages"] as? [[String: Any]]) ?? []
        for message in messages {
            let role = (message["role"] as? String ?? "user")
            let content = text(from: message["content"])
            guard !content.isEmpty else { continue }
            parts.append(role == "user" ? content : "\(role.capitalized): \(content)")
        }
        let prompt = parts.joined(separator: "\n\n")
        guard !prompt.isEmpty else { throw BurnBarProviderExecutorError.invalidResponse }
        return (prompt, object["stream"] as? Bool ?? false)
    }

    private static func text(from value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let array as [Any]:
            return array.map(text(from:)).filter { !$0.isEmpty }.joined(separator: "\n")
        case let object as [String: Any]:
            if let text = object["text"] as? String { return text }
            if let content = object["content"] { return text(from: content) }
            return ""
        default:
            return ""
        }
    }

    // MARK: - Response synthesis

    private static func usage(prompt: String, turn: TurnResult) -> BurnBarProviderProxyUsage {
        BurnBarProviderProxyUsage(
            inputTokens: turn.inputTokens ?? max(1, prompt.count / 4),
            outputTokens: turn.outputTokens ?? max(1, turn.text.count / 4),
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            confidence: turn.tokenConfidence
        )
    }

    static func chatCompletionResponseBody(
        modelID: String,
        output: String,
        stream: Bool,
        outputTokens: Int?
    ) throws -> Data {
        let id = "chatcmpl-openburnbar-claude-interactive-\(UUID().uuidString)"
        if stream {
            let chunk: [String: Any] = [
                "id": id,
                "object": "chat.completion.chunk",
                "created": Int(Date().timeIntervalSince1970),
                "model": modelID,
                "choices": [["index": 0, "delta": ["role": "assistant", "content": output], "finish_reason": NSNull()]]
            ]
            let done: [String: Any] = [
                "id": id,
                "object": "chat.completion.chunk",
                "created": Int(Date().timeIntervalSince1970),
                "model": modelID,
                "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]
            ]
            return try sseBody(events: [chunk, done])
        }
        let body: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelID,
            "choices": [["index": 0, "message": ["role": "assistant", "content": output], "finish_reason": "stop"]],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": outputTokens ?? max(1, output.count / 4),
                "total_tokens": outputTokens ?? max(1, output.count / 4)
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func responsesBody(
        modelID: String,
        output: String,
        stream: Bool,
        outputTokens: Int?
    ) throws -> Data {
        let id = "resp_openburnbar_claude_interactive_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        if stream {
            let delta: [String: Any] = [
                "type": "response.output_text.delta",
                "response_id": id,
                "delta": output
            ]
            let completed: [String: Any] = [
                "type": "response.completed",
                "response": ["id": id, "object": "response", "model": modelID, "status": "completed"]
            ]
            return try sseBody(events: [delta, completed])
        }
        let body: [String: Any] = [
            "id": id,
            "object": "response",
            "created_at": Date().timeIntervalSince1970,
            "model": modelID,
            "status": "completed",
            "output": [[
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": output]]
            ]],
            "usage": [
                "input_tokens": 0,
                "output_tokens": outputTokens ?? max(1, output.count / 4),
                "total_tokens": outputTokens ?? max(1, output.count / 4)
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func anthropicResponseBody(
        modelID: String,
        output: String,
        inputTokens: Int,
        outputTokens: Int
    ) throws -> Data {
        let body: [String: Any] = [
            "id": "msg_openburnbar_claude_interactive_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "type": "message",
            "role": "assistant",
            "model": modelID,
            "stop_reason": "end_turn",
            "stop_sequence": NSNull(),
            "content": [["type": "text", "text": output]],
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func sseBody(events: [[String: Any]]) throws -> Data {
        var text = ""
        for event in events {
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            text += "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        text += "data: [DONE]\n\n"
        return Data(text.utf8)
    }
}

// MARK: - AsyncSemaphore

/// A minimal FIFO async semaphore used to bound concurrent interactive
/// sessions without blocking a thread.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = max(0, value)
    }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}

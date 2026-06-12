import Darwin
import Foundation
import OpenBurnBarCore

// MARK: - ClaudeInteractiveMeterExperiment (Part B0)

/// One-shot diagnostic that drives a **single** interactive `claude` TUI session
/// through a PTY and measures where the resulting usage lands. It is the cheap
/// de-risking experiment described in the Part B plan: before investing in the
/// orchestrated handoff (B1) or the resident PTY executor (B2), confirm that
/// interactive Claude Code (launched without `-p`/`--print`) actually draws from
/// the flat **subscription window** rather than the new metered Agent SDK credit
/// pool.
///
/// ## What it measures
///
/// 1. **Local JSONL ledger** (`~/.claude/projects/*.jsonl`): the token counts
///    Claude Code writes for every turn. This proves the turn *happened* and how
///    many tokens it cost, but it cannot by itself distinguish billing pools.
/// 2. **Subscription window** (`/api/oauth/usage` `five_hour`/`seven_day`): the
///    distinguishing signal. If the used-percentage of these windows moves, the
///    turn billed against the subscription. If JSONL grew but the windows did
///    **not** move, the turn billed against a different pool (Agent SDK credit).
///
/// The subscription-window probe is **opt-in** and only runs when a Claude OAuth
/// access token is discoverable (env `OPENBURNBAR_CLAUDE_OAUTH_ACCESS_TOKEN`, or
/// `~/.claude/.credentials.json`). Without it the experiment still reports the
/// JSONL delta and records that the billing-pool signal was unavailable.
///
/// This type performs no routing and is never wired into the gateway. It exists
/// to produce evidence a human reads before enabling B1/B2.
public struct ClaudeInteractiveMeterExperiment: Sendable {

    public struct Options: Sendable {
        public var prompt: String
        public var claudeExecutableURL: URL?
        public var model: String?
        /// Seconds of output silence that signal the assistant finished a turn.
        public var idleQuiescence: TimeInterval
        /// Hard ceiling for the whole turn.
        public var turnTimeout: TimeInterval

        public init(
            prompt: String = "Reply with exactly the single word: PONG. Do not use any tools.",
            claudeExecutableURL: URL? = nil,
            model: String? = nil,
            idleQuiescence: TimeInterval = 5,
            turnTimeout: TimeInterval = 120
        ) {
            self.prompt = prompt
            self.claudeExecutableURL = claudeExecutableURL
            self.model = model
            self.idleQuiescence = idleQuiescence
            self.turnTimeout = turnTimeout
        }
    }

    public struct Report: Codable, Sendable {
        public let startedAt: Date
        public let finishedAt: Date
        public let prompt: String
        public let claudeExecutablePath: String

        public let jsonlBaselineTokens: Int
        public let jsonlFinalTokens: Int
        public let jsonlTokenDelta: Int
        public let jsonlChangedSessions: [String]

        public let subscriptionWindowsObserved: Bool
        public let fiveHourUsedBefore: Double?
        public let fiveHourUsedAfter: Double?
        public let sevenDayUsedBefore: Double?
        public let sevenDayUsedAfter: Double?

        public let verdict: Verdict
        public let verdictDetail: String
        public let transcriptExcerpt: String

        public enum Verdict: String, Codable, Sendable {
            /// Subscription window moved — interactive route bills the subscription.
            case drewFromSubscription
            /// JSONL grew but the subscription window did not move — likely a
            /// separate (Agent SDK credit) pool.
            case didNotDrawFromSubscription
            /// JSONL did not change — the turn likely never completed; rerun.
            case turnDidNotComplete
            /// Could not observe the subscription window (no OAuth token).
            case inconclusiveNoSubscriptionSignal
        }
    }

    private let options: Options
    private let session: URLSession

    public init(options: Options = Options(), session: URLSession = .shared) {
        self.options = options
        self.session = session
    }

    // MARK: - Run

    public func run() async throws -> Report {
        let startedAt = Date()
        let claudeURL = try options.claudeExecutableURL ?? Self.resolveClaudeExecutable()

        let probe = ClaudeCodeJSONLUsageProbe()
        let baseline = probe.snapshot()
        let oauthToken = Self.discoverOAuthAccessToken()
        let windowsBefore: SubscriptionWindows?
        if let oauthToken {
            windowsBefore = await fetchSubscriptionWindows(accessToken: oauthToken)
        } else {
            windowsBefore = nil
        }

        let transcript = try await driveInteractiveTurn(claudeURL: claudeURL)

        // Claude Code flushes its JSONL asynchronously; give it a moment.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let final = probe.snapshot()
        let windowsAfter: SubscriptionWindows?
        if let oauthToken {
            windowsAfter = await fetchSubscriptionWindows(accessToken: oauthToken)
        } else {
            windowsAfter = nil
        }

        let tokenDelta = final.totalTokens - baseline.totalTokens
        let changedSessions = ClaudeCodeJSONLUsageProbe.changedSessions(before: baseline, after: final)

        let (verdict, detail) = Self.evaluate(
            tokenDelta: tokenDelta,
            windowsBefore: windowsBefore,
            windowsAfter: windowsAfter,
            haveToken: oauthToken != nil
        )

        return Report(
            startedAt: startedAt,
            finishedAt: Date(),
            prompt: options.prompt,
            claudeExecutablePath: claudeURL.path,
            jsonlBaselineTokens: baseline.totalTokens,
            jsonlFinalTokens: final.totalTokens,
            jsonlTokenDelta: tokenDelta,
            jsonlChangedSessions: changedSessions,
            subscriptionWindowsObserved: windowsBefore != nil && windowsAfter != nil,
            fiveHourUsedBefore: windowsBefore?.fiveHourUsed,
            fiveHourUsedAfter: windowsAfter?.fiveHourUsed,
            sevenDayUsedBefore: windowsBefore?.sevenDayUsed,
            sevenDayUsedAfter: windowsAfter?.sevenDayUsed,
            verdict: verdict,
            verdictDetail: detail,
            transcriptExcerpt: Self.excerpt(transcript)
        )
    }

    // MARK: - Drive one interactive turn

    private func driveInteractiveTurn(claudeURL: URL) async throws -> String {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-claude-meter-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: workingDirectory) }

        var arguments: [String] = []
        if let model = options.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            arguments += ["--model", model]
        }

        let interactiveSession = PTYInteractiveSession(
            configuration: .init(
                executableURL: claudeURL,
                arguments: arguments,
                environment: Self.sanitizedEnvironment(),
                workingDirectory: workingDirectory
            )
        )

        try interactiveSession.start(onOutput: { _ in })
        defer { interactiveSession.terminate() }

        // Let the TUI finish its first render / auth check before typing.
        _ = await interactiveSession.waitForQuiescence(idle: 2.0, overall: 20)
        try interactiveSession.sendLine(options.prompt)
        _ = await interactiveSession.waitForQuiescence(idle: options.idleQuiescence, overall: options.turnTimeout)

        return interactiveSession.plainTranscriptText()
    }

    // MARK: - Subscription window probe

    struct SubscriptionWindows: Sendable {
        let fiveHourUsed: Double?
        let sevenDayUsed: Double?
    }

    private func fetchSubscriptionWindows(accessToken: String) async -> SubscriptionWindows? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claude-Code/2.1 (OpenBurnBar meter experiment)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let buckets = (root["rate_limits"] as? [String: Any]) ?? root
        return SubscriptionWindows(
            fiveHourUsed: Self.usedPercentage(in: buckets["five_hour"] as? [String: Any]),
            sevenDayUsed: Self.usedPercentage(in: buckets["seven_day"] as? [String: Any])
        )
    }

    private static func usedPercentage(in payload: [String: Any]?) -> Double? {
        guard let payload else { return nil }
        for key in ["used_percentage", "usedPercent", "percentage", "utilization", "used"] {
            if let v = payload[key] as? Double { return v }
            if let v = payload[key] as? Int { return Double(v) }
            if let v = payload[key] as? String, let parsed = Double(v) { return parsed }
        }
        return nil
    }

    // MARK: - Verdict

    static func evaluate(
        tokenDelta: Int,
        windowsBefore: SubscriptionWindows?,
        windowsAfter: SubscriptionWindows?,
        haveToken: Bool
    ) -> (Report.Verdict, String) {
        if tokenDelta <= 0 {
            return (
                .turnDidNotComplete,
                "No new tokens appeared in ~/.claude JSONL. The interactive turn likely did not complete (auth prompt, no subscription, or the TUI needed manual input). Re-run and watch the transcript."
            )
        }

        guard haveToken, let before = windowsBefore, let after = windowsAfter else {
            return (
                .inconclusiveNoSubscriptionSignal,
                "Recorded a +\(tokenDelta) token turn in JSONL, but no Claude OAuth token was available to read /api/oauth/usage, so the billing pool could not be confirmed. Export OPENBURNBAR_CLAUDE_OAUTH_ACCESS_TOKEN and re-run to confirm whether the subscription window moves."
            )
        }

        let fiveMoved = movedUp(before.fiveHourUsed, after.fiveHourUsed)
        let sevenMoved = movedUp(before.sevenDayUsed, after.sevenDayUsed)
        if fiveMoved || sevenMoved {
            return (
                .drewFromSubscription,
                "Subscription window moved (5h: \(fmt(before.fiveHourUsed))→\(fmt(after.fiveHourUsed)), 7d: \(fmt(before.sevenDayUsed))→\(fmt(after.sevenDayUsed))). Interactive Claude Code billed the flat subscription — the Part B premise holds; B1/B2 are worth building."
            )
        }
        return (
            .didNotDrawFromSubscription,
            "JSONL grew by +\(tokenDelta) tokens but the subscription window did NOT move (5h: \(fmt(before.fiveHourUsed)), 7d: \(fmt(before.sevenDayUsed))). The turn likely billed a separate pool (Agent SDK credit). Stop the gray bet and fall back to B3 (Console key + cross-vendor degrade)."
        )
    }

    private static func movedUp(_ before: Double?, _ after: Double?) -> Bool {
        guard let before, let after else { return false }
        return after - before > 0.0001
    }

    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f%%", value)
    }

    // MARK: - Discovery helpers

    static func resolveClaudeExecutable() throws -> URL {
        let candidates = claudeExecutableCandidatePaths()
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw PTYInteractiveSessionError.executableNotFound("claude (not found on PATH or common install locations)")
    }

    static func claudeExecutableCandidatePaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        var candidates = [
            homeDirectory.appendingPathComponent(".local/bin/claude").path,
            homeDirectory.appendingPathComponent(".homebrew/bin/claude").path,
            homeDirectory.appendingPathComponent(".bun/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        candidates.append(contentsOf: nvmClaudeCandidatePaths(homeDirectory: homeDirectory, fileManager: fileManager))
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path }
        candidates.append(contentsOf: pathEntries)
        return dedupe(candidates)
    }

    static func claudeRuntimePathEntries(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        var entries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        entries.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent(".homebrew/bin").path,
            homeDirectory.appendingPathComponent(".bun/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])
        entries.append(contentsOf: nvmClaudeCandidatePaths(homeDirectory: homeDirectory, fileManager: fileManager).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })
        return dedupe(entries)
    }

    private static func nvmClaudeCandidatePaths(homeDirectory: URL, fileManager: FileManager) -> [String] {
        let nodeVersions = homeDirectory
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let versionNames = try? fileManager.contentsOfDirectory(atPath: nodeVersions.path) else {
            return []
        }
        return versionNames
            .filter { !$0.hasPrefix(".") }
            .map { nodeVersions.appendingPathComponent($0, isDirectory: true) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("claude").path }
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return false }
            seen.insert(trimmed)
            return true
        }
    }

    static func discoverOAuthAccessToken() -> String? {
        if let envToken = ProcessInfo.processInfo.environment["OPENBURNBAR_CLAUDE_OAUTH_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envToken.isEmpty {
            return envToken
        }
        // Best-effort: Claude Code stores OAuth credentials in ~/.claude/.credentials.json
        // on platforms without a system keychain. macOS keychain discovery is
        // intentionally out of scope for this diagnostic.
        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: credentialsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            return token
        }
        if let token = root["accessToken"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    static func sanitizedEnvironment() -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "LANG", "LC_ALL", "TERM", "TMPDIR", "SHELL", "USER", "LOGNAME"] {
            if let value = current[key], !value.isEmpty {
                environment[key] = value
            }
        }
        if environment["PATH"] == nil {
            environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }
        environment["HOME"] = NSHomeDirectory()
        return environment
    }

    static func excerpt(_ text: String, limit: Int = 2000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.suffix(limit))
    }

    // MARK: - Human-readable formatting

    public static func format(_ report: Report) -> String {
        var lines: [String] = []
        lines.append("Claude interactive meter experiment")
        lines.append("===================================")
        lines.append("claude:        \(report.claudeExecutablePath)")
        lines.append("prompt:        \(report.prompt)")
        lines.append("JSONL tokens:  \(report.jsonlBaselineTokens) → \(report.jsonlFinalTokens) (Δ +\(report.jsonlTokenDelta))")
        if !report.jsonlChangedSessions.isEmpty {
            lines.append("sessions:      \(report.jsonlChangedSessions.joined(separator: ", "))")
        }
        if report.subscriptionWindowsObserved {
            lines.append("5h window:     \(fmt(report.fiveHourUsedBefore)) → \(fmt(report.fiveHourUsedAfter))")
            lines.append("7d window:     \(fmt(report.sevenDayUsedBefore)) → \(fmt(report.sevenDayUsedAfter))")
        } else {
            lines.append("5h/7d window:  (no OAuth token — billing pool unconfirmed)")
        }
        lines.append("")
        lines.append("VERDICT: \(report.verdict.rawValue)")
        lines.append(report.verdictDetail)
        return lines.joined(separator: "\n")
    }
}

// MARK: - ClaudeCodeJSONLUsageProbe

/// Lean reader of `~/.claude/projects/*.jsonl` that sums token usage across
/// recently-modified session files. Deliberately independent of the app target's
/// full `ClaudeCodeParser` so it can run inside the daemon/CLI for the B0
/// experiment. Bounded by an mtime cutoff so it never walks a huge history.
struct ClaudeCodeJSONLUsageProbe: Sendable {
    let projectsDirectory: URL
    let recencyCutoff: TimeInterval

    init(
        projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        recencyCutoff: TimeInterval = 6 * 60 * 60
    ) {
        self.projectsDirectory = projectsDirectory
        self.recencyCutoff = recencyCutoff
    }

    struct Snapshot: Sendable {
        /// Per-session-file token sums (path → tokens).
        let perFileTokens: [String: Int]
        var totalTokens: Int { perFileTokens.values.reduce(0, +) }
    }

    func snapshot() -> Snapshot {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return Snapshot(perFileTokens: [:])
        }
        let cutoff = Date().addingTimeInterval(-recencyCutoff)
        var perFile: [String: Int] = [:]
        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard modified >= cutoff else { continue }
                perFile[file.path] = Self.sumTokens(in: file)
            }
        }
        return Snapshot(perFileTokens: perFile)
    }

    /// Session file paths whose token sum changed (or appeared) between snapshots.
    static func changedSessions(before: Snapshot, after: Snapshot) -> [String] {
        var changed: [String] = []
        for (path, afterTokens) in after.perFileTokens where before.perFileTokens[path] != afterTokens {
            changed.append((path as NSString).lastPathComponent)
        }
        return changed.sorted()
    }

    private static func sumTokens(in file: URL) -> Int {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return 0 }
        var total = 0
        content.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            guard let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                return
            }
            for key in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                if let v = usage[key] as? Int { total += v } else if let v = usage[key] as? Double { total += Int(v) }
            }
        }
        return total
    }
}

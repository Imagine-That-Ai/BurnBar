import Foundation

// MARK: - Grok CLI Parser

/// GrokCLIParser extracts token usage from Grok CLI session directories at
/// `~/.grok/sessions/<url-encoded-project>/` (real-shaped sessions verified
/// 2026-08-12; see docs/fleet/BURNBAR_FLEET_SIGNALS.md §6).
///
/// Each session directory contains `events.jsonl` (turn lifecycle + usage),
/// `updates.jsonl` (session/update RPC frames with `turn_completed` usage),
/// `chat_history.jsonl` (conversation content), and `summary.json` (session
/// metadata: `id`, `cwd`, `current_model_id`, `created_at`, `updated_at`).
///
/// Usage sources, in priority order:
/// 1. `updates.jsonl` `turn_completed` frames — exact per-turn usage
///    (`usage.inputTokens/outputTokens/cachedReadTokens/totalTokens`).
/// 2. `events.jsonl` `turn_ended` frames — exact per-turn usage
///    (`usage.inputTokens/outputTokens/cachedReadTokens/totalTokens`).
/// 3. `summary.json` `current_model_id` + `created_at`/`updated_at` — model
///    and session timestamps (no token counts; rows are only emitted when a
///    usage source exists).
///
/// Project names are URL-decoded from the session directory name
/// (`%2FUsers%2Falbertonunez` → `/Users/albertonunez`); percent-escapes and
/// non-ASCII names decode exactly (VAL-PROV-016).
///
/// Honesty invariants: timestamps come from the session's own timestamps
/// (never epoch-zero); a missing/empty model stays empty; unknown models use
/// the catalog fallback pricing (never a fabricated exact $0.00); malformed
/// lines degrade the parse health without dropping valid rows; empty and
/// zero-byte files are silent no-ops.
final class GrokCLIParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .grokCLI

    /// Root override seam (hermetic tests): `BURNBAR_FLEET_ROOT_GROK_CLI` wins
    /// over `BURNBAR_FLEET_ROOTS_DIR` (which maps to `<override>/grok`),
    /// matching the daemon probe-root resolver. Both overrides point at the
    /// GROK root (the parent of `sessions/`); the parser appends `sessions`.
    /// With no overrides the real `~/.grok/sessions` root is used.
    ///
    /// The live process environment is consulted via `getenv` at resolution
    /// time (not a launch-time snapshot), so hermetic tests can `setenv`
    /// before constructing an aggregator that builds parsers internally.
    /// An explicitly passed `environment` dictionary wins over the live env.
    static func resolvedSessionsRoot(
        environment: [String: String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        var env = ProcessInfo.processInfo.environment
        for key in ["BURNBAR_FLEET_ROOT_GROK_CLI", "BURNBAR_FLEET_ROOTS_DIR"] {
            if let raw = getenv(key) {
                env[key] = String(cString: raw)
            }
        }
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        let trimmed = { (value: String?) -> String? in
            guard let value else { return nil }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        if let perProbe = trimmed(env["BURNBAR_FLEET_ROOT_GROK_CLI"]) {
            return URL(fileURLWithPath: perProbe, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .path
        }
        if let base = trimmed(env["BURNBAR_FLEET_ROOTS_DIR"]) {
            return URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent("grok/sessions", isDirectory: true)
                .path
        }
        return homeDirectory
            .appendingPathComponent(".grok/sessions", isDirectory: true)
            .path
    }

    private let sessionsRootOverride: String?
    private let fileManager: FileManager
    private let environment: [String: String]?

    /// Parse-health surface (VAL-PROV-007): populated after every `parse()`.
    private(set) var lastParseHealth = TranscriptParseHealth()

    init(
        sessionsRoot: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String]? = nil
    ) {
        self.sessionsRootOverride = sessionsRoot
        self.fileManager = fileManager
        self.environment = environment
    }

    private var sessionsRoot: String {
        sessionsRootOverride ?? Self.resolvedSessionsRoot(environment: environment)
    }

    func parse() async throws -> ParseResult {
        var health = TranscriptParseHealth()
        defer { lastParseHealth = health }

        guard fileManager.fileExists(atPath: sessionsRoot) else {
            return ParseResult(usages: [], conversations: [])
        }

        let rootURL = URL(fileURLWithPath: sessionsRoot, isDirectory: true)
        let topLevelEntries = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        // The real layout is two-level: `sessions/<url-encoded-project>/<session-id>/`.
        // A session dir is recognized by its files (summary.json / updates.jsonl /
        // events.jsonl / chat_history.jsonl); anything else is treated as a
        // project dir and descended one level. A flat one-level tree (session
        // dirs directly under the root) is also supported for hermetic tests.
        for entry in topLevelEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if Self.isSessionDirectory(entry) {
                health.itemsScanned += 1
                let parsed = parseSessionDirectory(entry, health: &health)
                if let parsed {
                    usages.append(parsed.usage)
                    if let conversation = parsed.conversation {
                        conversations.append(conversation)
                    }
                    health.itemsParsed += 1
                } else {
                    health.itemsSkipped += 1
                }
                continue
            }

            let sessionDirs = (try? fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.isDirectoryKey]
            ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

            for sessionDir in sessionDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                health.itemsScanned += 1
                let parsed = parseSessionDirectory(sessionDir, health: &health)
                if let parsed {
                    usages.append(parsed.usage)
                    if let conversation = parsed.conversation {
                        conversations.append(conversation)
                    }
                    health.itemsParsed += 1
                } else {
                    health.itemsSkipped += 1
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    /// A session directory carries at least one of the session files
    /// (`summary.json`, `updates.jsonl`, `events.jsonl`, `chat_history.jsonl`).
    private static func isSessionDirectory(_ directory: URL) -> Bool {
        let names = ["summary.json", "updates.jsonl", "events.jsonl", "chat_history.jsonl"]
        return names.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    // MARK: - Session Parsing

    private func parseSessionDirectory(
        _ sessionDir: URL,
        health: inout TranscriptParseHealth
    ) -> (usage: TokenUsage, conversation: ConversationRecord?)? {
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        let summaryFile = sessionDir.appendingPathComponent("summary.json")
        let chatFile = sessionDir.appendingPathComponent("chat_history.jsonl")

        let summary = readSummary(summaryFile)
        let projectName = summary.cwd ?? Self.decodeProjectName(sessionDir.lastPathComponent)
        let sessionId = summary.id ?? sessionDir.lastPathComponent
        let model = summary.model ?? ""

        // Usage: updates.jsonl turn_completed frames, then events.jsonl
        // turn_ended frames. Both are summed; the first source that yields
        // tokens wins (the other is not double-counted).
        var usage = readUsage(fromUpdates: updatesFile, health: &health)
        if usage == nil {
            usage = readUsage(fromEvents: eventsFile, health: &health)
        }

        // Timestamps: summary created_at/updated_at, then the usage frame's
        // own timestamps. No parseable timestamp → honest skip (VAL-PROV-015).
        let startTime = summary.createdAt ?? usage?.startTime
        let endTime = summary.updatedAt ?? usage?.endTime
        guard let startTime, let endTime else { return nil }

        let inputTokens = usage?.inputTokens ?? 0
        let outputTokens = usage?.outputTokens ?? 0
        let cacheReadTokens = usage?.cacheReadTokens ?? 0

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens
        )

        let usageRow = TokenUsage(
            provider: .grokCLI,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime
        )

        let conversation = readConversation(
            chatFile: chatFile,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            health: &health
        )

        return (usageRow, conversation)
    }

    // MARK: - Usage Sources

    private struct GrokUsage {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var startTime: Date?
        var endTime: Date?
    }

    /// Reads `updates.jsonl` `session/update` frames carrying
    /// `update.sessionUpdate == "turn_completed"` with a `usage` object.
    private func readUsage(fromUpdates file: URL, health: inout TranscriptParseHealth) -> GrokUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var usage = GrokUsage()
        var found = false

        for line in handle.readAllUTF8LinesLossy() {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                health.malformedLines += 1
                continue
            }
            guard let params = json["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let frameUsage = update["usage"] as? [String: Any] else {
                continue
            }
            let input = Self.strictInt(frameUsage["inputTokens"]) ?? 0
            let output = Self.strictInt(frameUsage["outputTokens"]) ?? 0
            let cached = Self.strictInt(frameUsage["cachedReadTokens"]) ?? 0
            if input > 0 || output > 0 || cached > 0 {
                usage.inputTokens += input
                usage.outputTokens += output
                usage.cacheReadTokens += cached
                found = true
            }
            if let timestamp = json["timestamp"] as? Double {
                let date = Date(timeIntervalSince1970: timestamp)
                if usage.startTime == nil { usage.startTime = date }
                usage.endTime = date
            }
        }

        return found ? usage : nil
    }

    /// Reads `events.jsonl` `turn_ended` frames carrying a `usage` object.
    private func readUsage(fromEvents file: URL, health: inout TranscriptParseHealth) -> GrokUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var usage = GrokUsage()
        var found = false

        for line in handle.readAllUTF8LinesLossy() {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                health.malformedLines += 1
                continue
            }
            guard json["type"] as? String == "turn_ended",
                  let frameUsage = json["usage"] as? [String: Any] else {
                continue
            }
            let input = Self.strictInt(frameUsage["inputTokens"]) ?? 0
            let output = Self.strictInt(frameUsage["outputTokens"]) ?? 0
            let cached = Self.strictInt(frameUsage["cachedReadTokens"]) ?? 0
            if input > 0 || output > 0 || cached > 0 {
                usage.inputTokens += input
                usage.outputTokens += output
                usage.cacheReadTokens += cached
                found = true
            }
            if let timestamp = json["ts"] as? String,
               let date = Self.parseTimestamp(timestamp) {
                if usage.startTime == nil { usage.startTime = date }
                usage.endTime = date
            }
        }

        return found ? usage : nil
    }

    // MARK: - Summary

    private struct GrokSessionSummary {
        var id: String?
        var cwd: String?
        var model: String?
        var createdAt: Date?
        var updatedAt: Date?
    }

    private func readSummary(_ file: URL) -> GrokSessionSummary {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GrokSessionSummary()
        }
        var summary = GrokSessionSummary()
        // Real summary.json nests id/cwd under `info`; top-level fields are
        // the fallback for older or synthetic shapes.
        if let info = json["info"] as? [String: Any] {
            if let id = info["id"] as? String, !id.isEmpty {
                summary.id = id
            }
            if let cwd = info["cwd"] as? String, !cwd.isEmpty {
                summary.cwd = cwd
            }
        }
        if summary.id == nil, let id = json["id"] as? String, !id.isEmpty {
            summary.id = id
        }
        if summary.cwd == nil, let cwd = json["cwd"] as? String, !cwd.isEmpty {
            summary.cwd = cwd
        }
        if let model = json["current_model_id"] as? String, !model.isEmpty {
            summary.model = TokenExtractionUtility.normalizeModelName(model)
        }
        if let created = json["created_at"] as? String {
            summary.createdAt = Self.parseTimestamp(created)
        }
        if let updated = json["updated_at"] as? String {
            summary.updatedAt = Self.parseTimestamp(updated)
        }
        return summary
    }

    // MARK: - Conversation

    private func readConversation(
        chatFile: URL,
        sessionId: String,
        projectName: String,
        startTime: Date,
        endTime: Date,
        health: inout TranscriptParseHealth
    ) -> ConversationRecord? {
        guard let handle = try? FileHandle(forReadingFrom: chatFile) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? fileManager.attributesOfItem(atPath: chatFile.path)[.modificationDate]) as? Date
        var userChars = 0
        var assistantChars = 0
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0
        var fullText = ""
        var firstUserText: String?
        var lastAssistantText = ""

        for line in handle.readAllUTF8LinesLossy() {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                health.malformedLines += 1
                continue
            }
            let type = json["type"] as? String ?? ""
            let content = Self.extractContent(from: json)
            guard !content.isEmpty else { continue }

            if type == "user" {
                userChars += content.count
                userWords += Self.wordCount(content)
                if firstUserText == nil {
                    firstUserText = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                }
                messageCount += 1
            } else if type == "assistant" {
                assistantChars += content.count
                assistantWords += Self.wordCount(content)
                lastAssistantText = content
                messageCount += 1
            }
            if !fullText.isEmpty { fullText += "\n\n" }
            fullText += content
        }

        guard messageCount > 0 else { return nil }

        return ConversationRecord(
            id: ConversationRecord.stableId(provider: .grokCLI, sessionId: sessionId),
            provider: .grokCLI,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUserText ?? projectName,
            lastAssistantMessage: lastAssistantText,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )
    }

    // MARK: - Helpers

    /// URL-decodes a Grok session directory name into a project path
    /// (`%2FUsers%2Falbertonunez` → `/Users/albertonunez`). Percent-escapes
    /// and non-ASCII names decode exactly; undecodable names are returned
    /// unchanged (VAL-PROV-016).
    static func decodeProjectName(_ slug: String) -> String {
        slug.removingPercentEncoding ?? slug
    }

    /// ISO-8601 with optional fractional seconds and optional non-UTC offsets.
    static func parseTimestamp(_ string: String) -> Date? {
        if let date = Self.fractionalFormatter.date(from: string) {
            return date
        }
        return Self.plainFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Strict integer extraction: rejects booleans, fractional values, and
    /// non-finite numbers (mirrors the daemon's strict JSON decoding).
    static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double <= Double(Int.max),
              double.rounded() == double else {
            return nil
        }
        return Int(double)
    }

    private static func extractContent(from json: [String: Any]) -> String {
        if let content = json["content"] as? String {
            return content
        }
        if let parts = json["content"] as? [[String: Any]] {
            return parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func wordCount(_ string: String) -> Int {
        string.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

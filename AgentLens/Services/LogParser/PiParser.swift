import Foundation

// MARK: - Pi Parser

/// PiParser extracts token usage from Pi CLI transcripts at
/// `~/.pi/agent/sessions/<project-dir>/*.jsonl` (real-shaped transcripts
/// verified 2026-08-12; see docs/fleet/BURNBAR_FLEET_SIGNALS.md §7).
///
/// Transcript shape (line 1 is the authoritative session record):
/// ```json
/// {"type":"session","version":3,"id":"<uuid>","timestamp":"2026-08-10T23:06:04.080Z","cwd":"/Users/albertonunez"}
/// {"type":"model_change","id":"…","timestamp":"…","provider":"deepseek","modelId":"deepseek-v4-flash"}
/// {"type":"message","id":"…","timestamp":"…","message":{"role":"assistant","content":[…],"usage":{"input":4302,"output":199,"cacheRead":0,"cacheWrite":0,"reasoning":50,"totalTokens":4501,"cost":{…}}}}
/// ```
///
/// Project-name decoding (VAL-PROV-011/016): the real session-dir encoding on
/// this machine is `--` + `-`-joined path components + `--` (e.g.
/// `--Users-albertonunez-Documents-Developer-imaginethat-llc--`), which is
/// ambiguous for hyphenated path components. The transcript line-1 `cwd`
/// field is the AUTHORITATIVE project path when present; the `--`-boundary
/// slug decode (split only on `--`, single hyphens preserved) is the fallback.
///
/// Honesty invariants: timestamps come from the transcript's own timestamps
/// (never epoch-zero); a missing/empty model stays empty; unknown models use
/// the catalog fallback pricing (never a fabricated exact $0.00); malformed
/// lines degrade the parse health without dropping valid rows; empty and
/// zero-byte files are silent no-ops.
final class PiParser: LogParser, @unchecked Sendable {
    let provider: AgentProvider = .pi

    /// Root override seam (hermetic tests): `BURNBAR_FLEET_ROOT_PI` wins over
    /// `BURNBAR_FLEET_ROOTS_DIR` (which maps to `<override>/pi`), matching the
    /// daemon probe-root resolver. Both overrides point at the PI ROOT (the
    /// parent of `agent/`); the parser appends `agent/sessions`. With no
    /// overrides the real `~/.pi/agent/sessions` root is used.
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
        for key in ["BURNBAR_FLEET_ROOT_PI", "BURNBAR_FLEET_ROOTS_DIR"] {
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
        if let perProbe = trimmed(env["BURNBAR_FLEET_ROOT_PI"]) {
            return URL(fileURLWithPath: perProbe, isDirectory: true)
                .appendingPathComponent("agent/sessions", isDirectory: true)
                .path
        }
        if let base = trimmed(env["BURNBAR_FLEET_ROOTS_DIR"]) {
            return URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent("pi/agent/sessions", isDirectory: true)
                .path
        }
        return homeDirectory
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
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
        let projectDirs = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for projectDir in projectDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let transcriptFiles = (try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: nil
            ))?.filter { $0.pathExtension == "jsonl" }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) ?? []

            for transcriptFile in transcriptFiles {
                health.itemsScanned += 1
                let parsed = parseTranscript(
                    file: transcriptFile,
                    projectDirName: projectDir.lastPathComponent,
                    health: &health
                )
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

    // MARK: - Transcript Parsing

    private func parseTranscript(
        file: URL,
        projectDirName: String,
        health: inout TranscriptParseHealth
    ) -> (usage: TokenUsage, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        var accumulator = PiSessionAccumulator()
        var sessionID: String?
        var cwd: String?
        var sawAnyLine = false
        var headerCaptured = false

        for line in handle.readAllUTF8LinesLossy() {
            // Blank-line detection trims whitespace AND newlines: a
            // whitespace-only physical line is a blank line, not a
            // malformed record (round-4 scrutiny, issue 3). The documented
            // rule is "first NONBLANK record" — whitespace-only preamble
            // lines before a valid session header must not invalidate the
            // transcript. Non-whitespace content (including lossy-decoded
            // garbage) still reaches the malformed-first-bytes path below.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sawAnyLine = true
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Line-1 authority (VAL-PROV-011/016): the FIRST nonblank
                // PHYSICAL record must be a well-formed session record.
                // Malformed first bytes (lossy-decode garbage, truncated
                // JSON) invalidate the transcript exactly like a
                // wrong-shaped first record — a later session header is
                // never accepted as the line-1 authority (round-3
                // scrutiny, issue 1). Only malformed lines AFTER a valid
                // header continue.
                health.malformedLines += 1
                if !headerCaptured {
                    return nil
                }
                continue
            }
            if !headerCaptured {
                // Line-1 authority (VAL-PROV-011/016): the FIRST nonblank
                // record must be a well-formed session record. Any other
                // first record (unknown type, wrong shape, malformed
                // session) invalidates the transcript: it is skipped
                // honestly and a later session record is never accepted as
                // the line-1 authority (round-2 scrutiny, issue 5).
                guard json["type"] as? String == "session",
                      Self.isValidSessionRecord(json) else {
                    health.malformedLines += 1
                    return nil
                }
                headerCaptured = true
                sessionID = (json["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                cwd = (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let timestamp = json["timestamp"] as? String,
                   let date = Self.parseTimestamp(timestamp) {
                    accumulator.startTime = date
                    accumulator.endTime = date
                }
                continue
            }
            ingestLine(json, into: &accumulator, health: &health)
        }

        // Zero-byte and blank-lines-only files are silent no-ops (VAL-PROV-013).
        guard sawAnyLine else { return nil }
        // A transcript with no session record never yields a row with
        // fabricated identity (line-1 authority).
        guard headerCaptured else { return nil }

        let projectName = cwd ?? Self.decodeProjectName(projectDirName)
        let sessionId = sessionID ?? file.deletingPathExtension().lastPathComponent
        let model = accumulator.model ?? ""

        guard let startTime = accumulator.startTime, let endTime = accumulator.endTime else {
            // No parseable timestamps: honest skip, never epoch-zero (VAL-PROV-015).
            return nil
        }

        let inputTokens = accumulator.inputTokens
        let outputTokens = accumulator.outputTokens
        let cacheReadTokens = accumulator.cacheReadTokens
        let cacheCreationTokens = accumulator.cacheCreationTokens

        guard inputTokens > 0 || outputTokens > 0 else {
            return nil
        }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )

        let usage = TokenUsage(
            provider: .pi,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: startTime,
            endTime: endTime
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .pi, sessionId: sessionId),
            provider: .pi,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: accumulator.messageCount,
            userWordCount: accumulator.userWordCount,
            assistantWordCount: accumulator.assistantWordCount,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: accumulator.firstUserText ?? projectName,
            lastAssistantMessage: accumulator.lastAssistantText,
            fullText: accumulator.fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    private func ingestLine(
        _ json: [String: Any],
        into accumulator: inout PiSessionAccumulator,
        health: inout TranscriptParseHealth
    ) {
        let type = json["type"] as? String ?? ""

        // Timestamps: ISO-8601 with optional fractional seconds and optional
        // non-UTC offsets (VAL-PROV-015). Unparseable timestamps are ignored
        // (the session is skipped honestly when none parse).
        if let timestamp = json["timestamp"] as? String,
           let date = Self.parseTimestamp(timestamp) {
            accumulator.endTime = date
        }

        switch type {
        case "session":
            // Line-1 authority: a later session record is not the header.
            // A well-formed duplicate is ignored; a malformed one degrades
            // the parse health instead of being silently skipped.
            if !Self.isValidSessionRecord(json) {
                health.malformedLines += 1
            }
        case "model_change", "thinking_level_change":
            // Tolerated non-usage record kinds (documented in
            // docs/fleet/BURNBAR_FLEET_SIGNALS.md §7): model_change carries
            // the model fallback, thinking_level_change is a benign
            // transcript event.
            if type == "model_change",
               let model = json["modelId"] as? String, !model.isEmpty {
                accumulator.model = TokenExtractionUtility.normalizeModelName(model)
            }
        case "message":
            guard let message = json["message"] as? [String: Any] else {
                // Valid JSON with the wrong shape: typed malformed, never a
                // silent skip (VAL-PROV-007).
                health.malformedLines += 1
                return
            }
            let role = (message["role"] as? String ?? "").lowercased()
            let content = Self.extractContent(from: message)

            // Real transcripts carry the model on assistant message lines
            // (`message.model`); the model_change event is the fallback.
            if let model = message["model"] as? String, !model.isEmpty {
                accumulator.model = TokenExtractionUtility.normalizeModelName(model)
            }

            if !content.isEmpty {
                if role == "user" {
                    accumulator.userChars += content.count
                    accumulator.userWordCount += Self.wordCount(content)
                    if accumulator.firstUserText == nil {
                        accumulator.firstUserText = String(
                            content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
                        )
                    }
                    accumulator.messageCount += 1
                } else if role == "assistant" {
                    accumulator.assistantChars += content.count
                    accumulator.assistantWordCount += Self.wordCount(content)
                    accumulator.lastAssistantText = content
                    accumulator.messageCount += 1
                }
                if !accumulator.fullText.isEmpty { accumulator.fullText += "\n\n" }
                accumulator.fullText += content
            }

            if let usage = message["usage"] as? [String: Any] {
                // Strict usage primitives: a present-but-malformed usage
                // field degrades the parse health instead of being silently
                // coerced to zero (VAL-PROV-007). Absent fields are simply
                // not counted.
                var malformed = false
                let input = Self.strictInt(usage["input"], malformed: &malformed)
                let output = Self.strictInt(usage["output"], malformed: &malformed)
                let cacheRead = Self.strictInt(usage["cacheRead"], malformed: &malformed)
                let cacheWrite = Self.strictInt(usage["cacheWrite"], malformed: &malformed)
                if malformed {
                    health.malformedLines += 1
                }
                if input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 {
                    accumulator.inputTokens = Self.addingChecked(accumulator.inputTokens, input)
                    accumulator.outputTokens = Self.addingChecked(accumulator.outputTokens, output)
                    accumulator.cacheReadTokens = Self.addingChecked(accumulator.cacheReadTokens, cacheRead)
                    accumulator.cacheCreationTokens = Self.addingChecked(accumulator.cacheCreationTokens, cacheWrite)
                }
            } else if let present = message["usage"], !(present is NSNull) {
                // A PRESENT usage value that is not an object (string,
                // array, number, boolean) is wrong-typed: typed malformed,
                // never a silent skip (round-2 scrutiny, issue 1). Absent
                // and null usage remain acceptable.
                health.malformedLines += 1
            }
        default:
            // Unknown record kinds are NOT silently accepted: an arbitrary
            // top-level type (e.g. {"type":"bogus"}) is wrong-shaped input
            // and degrades the typed parse health (round-2 scrutiny,
            // issue 2). The tolerated kinds are the explicit allowlist
            // above; the real transcript format's future event kinds must
            // be added there deliberately.
            health.malformedLines += 1
        }
    }

    // MARK: - Project Name Decoding

    /// Decodes a Pi session-dir slug into a project path.
    ///
    /// The documented contract (VAL-PROV-011/016) splits ONLY on `--`
    /// boundaries and preserves single hyphens inside one path component:
    /// `--Users-test--my-cool-proj` → `/Users/test/my-cool-proj`. Each
    /// component is percent-decoded so URL-encoded dir names
    /// (`--Users-test--caf%C3%A9--`) decode to their Unicode form.
    ///
    /// The REAL encoding on this machine is `--` + `-`-joined components + `--`
    /// (`--Users-albertonunez-Documents-Developer-imaginethat-llc--`), which
    /// is ambiguous for hyphenated components. The transcript line-1 `cwd`
    /// field is authoritative when present; this slug decode is the fallback
    /// and is documented as such in docs/fleet/BURNBAR_FLEET_SIGNALS.md.
    static func decodeProjectName(_ slug: String) -> String {
        guard slug.hasPrefix("--") else { return slug }
        let components = slug.components(separatedBy: "--").filter { !$0.isEmpty }
        guard !components.isEmpty else { return slug }
        let decoded = components.map { $0.removingPercentEncoding ?? $0 }
        return "/" + decoded.joined(separator: "/")
    }

    // MARK: - Helpers

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
    ///
    /// The upper bound is checked with EXACT JSON-number/integer validation
    /// (`Int64(exactly:)` on the bridged value) — never `Double(Int.max)`,
    /// which rounds to 2^63 and is not representable as an Int. A JSON
    /// number at the 64-bit boundary is rejected instead of trapping at
    /// `Int(double)` (usage-parsers scrutiny, reviewer issue 3).
    ///
    /// `malformed` is set when the field is PRESENT but not a valid
    /// non-negative integer (boolean, fractional, out-of-range, non-numeric)
    /// so the caller can degrade parse health instead of silently coercing
    /// to zero (VAL-PROV-007). Absent/null fields are not malformed.
    static func strictInt(_ value: Any?, malformed: inout Bool) -> Int {
        guard let number = value as? NSNumber else {
            if value != nil, !(value is NSNull) {
                malformed = true
            }
            return 0
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID(),
              let int64 = Self.exactInt64(number),
              int64 >= 0,
              let int = Int(exactly: int64) else {
            malformed = true
            return 0
        }
        return int
    }

    /// Exact JSON-number → Int64 conversion. Integer-backed NSNumber values
    /// bridge directly; floating-point-backed values convert only when the
    /// value is finite and integral (fractional values are rejected, and
    /// `Int64(exactly:)` returns nil for values beyond the representable
    /// range — including the Double(Int64.max) boundary trap, which rounds
    /// to 2^63).
    private static func exactInt64(_ number: NSNumber) -> Int64? {
        let type = String(cString: number.objCType)
        if type == "d" || type == "f" {
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return Int64(exactly: double)
        }
        return number as? Int64
    }

    /// Checked accumulation: a sum that would overflow Int.max saturates at
    /// Int.max instead of trapping (untrusted usage input never crashes the
    /// parser; the saturated row is still honest about the magnitude).
    static func addingChecked(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    /// Line-1 session-record shape (VAL-PROV-011/016): `type == "session"`
    /// with a non-empty string `id` and, when present, a string `cwd` and a
    /// string `timestamp`. A record with a missing/empty id, or a mistyped
    /// cwd/timestamp, is malformed — it can never become session identity.
    static func isValidSessionRecord(_ json: [String: Any]) -> Bool {
        guard let id = json["id"] as? String, !id.isEmpty else { return false }
        if let cwd = json["cwd"], !(cwd is String) { return false }
        if let timestamp = json["timestamp"], !(timestamp is String) { return false }
        return true
    }

    private static func extractContent(from message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let text = content as? String {
            return text
        }
        if let parts = content as? [[String: Any]] {
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

// MARK: - Pi Session Accumulator

private struct PiSessionAccumulator {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var model: String?
    var startTime: Date?
    var endTime: Date?
    var userChars = 0
    var assistantChars = 0
    var userWordCount = 0
    var assistantWordCount = 0
    var messageCount = 0
    var fullText = ""
    var firstUserText: String?
    var lastAssistantText = ""
}

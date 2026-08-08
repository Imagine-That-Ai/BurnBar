import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

// MARK: - Prime Agent Parser

/// Parses Prime Agent (Prime Intellect) sessions from `~/.prime/agent/sessions/*.jsonl`.
///
/// **Research findings — Prime Agent on macOS 14+ (observed 2026-08, https://www.primeintellect.ai/#inference):**
///
/// - **Session logs:** Flat-file JSONL, one file per session at `~/.prime/agent/sessions/*.jsonl`
///   (no nested `YYYY/MM/DD` — compare Muse's XDG-style nesting). Each line is a JSON
///   discriminated union on `type`. BurnBar ignores `child_usage_attributed`, `custom`,
///   `compaction`, and other non-message types for token accounting; authoritative
///   totals are in `message.usage` buckets.
/// - **Model identifiers:** `message.provider` (e.g., `"prime"`, `"openai"`, `"anthropic"`) +
///   `message.model` (e.g., `"muse-spark-1.2"`, `"gpt-5.6-luna"`, `"claude-4-opus"`).
///   The parser auto-detects the underlying model per turn and uses the *last* model
///   in the file as the session's `TokenUsage.model` — matching multi-backend sessions
///   that route different turns to different providers.
/// - **Token usage:** `message.usage` carries `input`, `output`, `cacheRead`, `cacheWrite`
///   (all ints; string/double coerced). `totalTokens` is advisory; BurnBar sums
///   `input+output+cacheRead+cacheWrite` across all assistant turns. Buckets are
///   disjoint — no double-counting of `cacheRead` inside `input`.
/// - **Auth state:** Prime stores credentials outside the session logs at
///   `~/.prime/agent/auth.json` and `~/.prime/agent/models.json` (per-backend API
///   keys, not read by the meter). The parser requires no auth — local-first like
///   Hermes/Codex/Droid — and reads only the session logs.
/// - **Timestamps:** `session.timestamp` and `message.timestamp` are RFC3339/ISO8601
///   with fractional seconds; parser falls back to numeric epoch seconds string.
///   File `mtime` is final fallback for `startTime`/`endTime` when no in-file
///   timestamps exist.
/// - **Cost:** The daemon pre-computes exact USD per turn in `usage.cost.total`
///   across diverse routed backends. BurnBar prefers this explicit total; when
///   `total` is `0` or missing, it falls back to the shared `ModelPricing` catalog
///   (`ModelPricing.lookup(providerID:"prime-agent")`). Unknown models (e.g.,
///   `muse-spark-1.2` before catalog entry) stay at `0` until pricing is added —
///   graceful fallback, not crash.
/// - **Content:** `message.content` may be a string or an array of blocks
///   (`text`/`thinking`/`toolCall` with `name`/`tool` + `arguments`). Tool names
///   are collected into `ConversationRecord.keyTools` (sorted, prefix 20).
///
/// The parser is flat-file, stateless, `Sendable`, and Windows-buildable (uses
/// only `FileManager` + `FileHandle` + `JSONSerialization`). Every JSON decode
/// is `try?`-guarded; truncated lines, missing fields, empty sessions, and
/// non-UTF8 tails are skipped without aborting the whole file.
public final class PrimeAgentParser: LogParser, Sendable {
    public let provider: AgentProvider = .primeAgent
    let logDirectoryOverride: String?

    public init(logDirectoryOverride: String? = nil) {
        self.logDirectoryOverride = logDirectoryOverride
    }

    public func parse() async throws -> ParseResult {
        try parseSynchronously(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        try parseSynchronously(options: options)
    }

    public func parseSynchronously(options: LogParseOptions = .default) throws -> ParseResult {
        let fm = FileManager.default
        let gate = ParserFileReadGate(options: options, fileManager: fm)
        var sessionsPath = logDirectoryOverride ?? NSString(string: provider.logDirectory).expandingTildeInPath
        // BurnBar convention `~/.prime/agent/sessions` is not vendor-documented
        // (Prime docs only cover the HTTP API). If the vendor later ships
        // `~/.prime/sessions`, fall back to it rather than silently showing 0.
        if logDirectoryOverride == nil, !fm.fileExists(atPath: sessionsPath) {
            let alt = ("~/.prime/sessions" as NSString).expandingTildeInPath
            if fm.fileExists(atPath: alt) { sessionsPath = alt }
        }
        guard fm.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }
        let sessionsURL = URL(fileURLWithPath: sessionsPath)

        // Prime Intellect may evolve from flat `*.jsonl` to nested `YYYY/MM/DD/<id>.jsonl`
        // (like Muse's XDG layout). The enumerator handles both without double-counting,
        // and the `.jsonl` filter keeps the file-watcher cheap. This fixes the flat-only
        // loophole that would silently miss nested sessions.
        var candidates: [URL] = []
        if let enumerator = fm.enumerator(at: sessionsURL, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.pathExtension == "jsonl" {
                    candidates.append(url)
                }
            }
        } else if let contents = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isRegularFileKey]) {
            candidates = contents.filter { $0.pathExtension == "jsonl" }
        }
        candidates.sort { $0.path < $1.path }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        for file in candidates {
            guard try gate.shouldRead(file) else { continue }
            if let pair = try parseFile(file: file) {
                if let usage = pair.usage { usages.append(usage) }
                if options.includeConversationBodies, let conv = pair.conversation { conversations.append(conv) }
            }
        }
        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Per-file parsing

    private func parseFile(file: URL) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date

        let rawSessionId = file.deletingPathExtension().lastPathComponent
        var sessionId = rawSessionId
        var cwd: String?
        var sessionTimestamp: Date?
        var projectName: String?

        // Aggregated usage across all assistant messages in this file
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalCacheWrite = 0
        var totalCost: Double = 0
        var costWasExplicit = false
        var lastModel: String?
        var firstTime: Date?
        var lastTime: Date?

        var turns: [(role: String, text: String, timestamp: Date?)] = []
        var toolNames = Set<String>()
        var messageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let type = json["type"] as? String else { continue }

            if type == "session" {
                if let sid = json["id"] as? String, !sid.isEmpty {
                    sessionId = sid
                }
                cwd = json["cwd"] as? String ?? cwd
                if let ts = json["timestamp"] as? String {
                    sessionTimestamp = parseDate(ts) ?? sessionTimestamp
                }
                // also try git repo as fallback project
                if projectName == nil, let cwdString = cwd as String? {
                    projectName = URL(fileURLWithPath: cwdString).lastPathComponent
                }
                continue
            }

            if type != "message" { continue }

            guard let msg = json["message"] as? [String: Any] else { continue }
            let role = (msg["role"] as? String ?? "").lowercased()
            let tsString = json["timestamp"] as? String ?? msg["timestamp"] as? String
            let date = tsString.flatMap { parseDate($0) }

            if let d = date {
                if firstTime == nil { firstTime = d }
                lastTime = d
            }

            // Accumulate usage if present on the message (assistant turns)
            if let usage = msg["usage"] as? [String: Any] {
                let input = intVal(usage["input"])
                let output = intVal(usage["output"])
                let cacheRead = intVal(usage["cacheRead"])
                let cacheWrite = intVal(usage["cacheWrite"])
                // totalTokens is advisory — input+output+cache
                totalInput += max(input, 0)
                totalOutput += max(output, 0)
                totalCacheRead += max(cacheRead, 0)
                totalCacheWrite += max(cacheWrite, 0)

                // Distinguish `cost.total` *presence* vs *value*: a free turn (e.g.,
                // `muse-spark-1.2-contributor` cached) is explicitly `0` and must
                // stay `0`, not fall back to catalog pricing. Only missing `cost`
                // triggers the fallback.
                if let costObj = usage["cost"] as? [String: Any], costObj["total"] != nil, let total = doubleVal(costObj["total"]) {
                    totalCost += total
                    costWasExplicit = true
                }
                if let provider = msg["provider"] as? String, !provider.isEmpty {
                    // keep for debugging; model is more specific
                    _ = provider
                }
                if let model = msg["model"] as? String, !model.isEmpty {
                    lastModel = model
                } else if let inner = msg["modelId"] as? String, !inner.isEmpty {
                    lastModel = inner
                }
            } else {
                // Some messages may have provider/model without usage (user/tool) — still track model
                if role == "assistant" {
                    if let model = msg["model"] as? String, !model.isEmpty {
                        lastModel = model
                    }
                }
            }

            // Conversation extraction
            let content = msg["content"]
            var chunkText = ""
            if let str = content as? String {
                chunkText = str.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let arr = content as? [[String: Any]] {
                for block in arr {
                    let btype = block["type"] as? String ?? ""
                    if btype == "text", let t = block["text"] as? String, !t.isEmpty {
                        if !chunkText.isEmpty { chunkText += "\n" }
                        chunkText += t
                    } else if btype == "thinking", let t = block["thinking"] as? String, !t.isEmpty {
                        if !chunkText.isEmpty { chunkText += "\n" }
                        chunkText += t
                    } else if btype == "toolCall" {
                        let name = (block["name"] as? String) ?? (block["tool"] as? String) ?? ""
                        if !name.isEmpty { toolNames.insert(name) }
                        if let args = block["arguments"] {
                            let s = stringify(args)
                            if !s.isEmpty {
                                if !chunkText.isEmpty { chunkText += "\n" }
                                chunkText += s
                            }
                        }
                    }
                }
            } else if let arr = content as? [Any] {
                for item in arr {
                    if let block = item as? [String: Any] {
                        let btype = block["type"] as? String ?? ""
                        if btype == "text", let t = block["text"] as? String, !t.isEmpty {
                            if !chunkText.isEmpty { chunkText += "\n" }
                            chunkText += t
                        } else if btype == "toolCall" {
                            let name = (block["name"] as? String) ?? ""
                            if !name.isEmpty { toolNames.insert(name) }
                        }
                    } else if let s = item as? String, !s.isEmpty {
                        if !chunkText.isEmpty { chunkText += "\n" }
                        chunkText += s
                    }
                }
            }

            // Normalize role mapping
            let normalizedRole: String
            switch role {
            case "user": normalizedRole = "user"
            case "assistant": normalizedRole = "assistant"
            case "toolresult", "tool_result", "tool": normalizedRole = "tool"
            default: normalizedRole = role
            }

            if normalizedRole == "user" || normalizedRole == "assistant" || normalizedRole == "tool" {
                if !chunkText.isEmpty {
                    turns.append((role: normalizedRole == "tool" ? "tool" : normalizedRole, text: chunkText, timestamp: date))
                } else if normalizedRole == "assistant" || normalizedRole == "user" {
                    // Empty content blocks (e.g., thinking-only) still count as a turn if usage present
                    if msg["usage"] != nil {
                        turns.append((role: normalizedRole, text: "", timestamp: date))
                    }
                }
            }

            if normalizedRole == "user" || normalizedRole == "assistant" {
                messageCount += 1
            }
        }

        // Resolve project name fallback
        if projectName == nil {
            if let cwdString = cwd {
                let last = URL(fileURLWithPath: cwdString).lastPathComponent
                projectName = last.isEmpty ? "Prime Agent" : last
            } else {
                projectName = "Prime Agent"
            }
        }
        let resolvedProject = projectName ?? "Prime Agent"
        let model = lastModel ?? "prime-agent"

        // If no usage at all, skip (e.g., empty session that never called a model)
        guard totalInput > 0 || totalOutput > 0 || totalCacheRead > 0 || totalCacheWrite > 0 else {
            return nil
        }

        let resolvedStart = firstTime ?? sessionTimestamp ?? mtime ?? Date()
        let resolvedEnd = lastTime ?? sessionTimestamp ?? mtime ?? resolvedStart

        // Cost: prefer the explicit total from the log when `cost.total` was present
        // (even if `0` for free/cached turns); only missing `cost` falls back to
        // catalog pricing. This prevents a free turn from being re-priced as paid.
        let cost: Double
        if costWasExplicit {
            cost = totalCost
        } else {
            let pricing = ModelPricing.lookup(model: model, providerID: "prime-agent")
            cost = (try? pricing.cost(inputTokens: totalInput, outputTokens: totalOutput, cacheCreationTokens: totalCacheWrite, cacheReadTokens: totalCacheRead)) ?? totalCost
        }

        let usage = TokenUsage(
            provider: .primeAgent,
            sessionId: sessionId,
            projectName: resolvedProject,
            model: model,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheWrite,
            cacheReadTokens: totalCacheRead,
            costUSD: cost,
            startTime: resolvedStart,
            endTime: resolvedEnd,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )

        // Build conversation record
        let conversation: ConversationRecord?
        if !turns.isEmpty {
            let userTurns = turns.filter { $0.role == "user" }
            let assistantTurns = turns.filter { $0.role == "assistant" }
            let filteredForTranscript = turns.filter { $0.role == "user" || $0.role == "assistant" }
            let fullText = filteredForTranscript.map { turn in
                SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: turn.role == "assistant", body: turn.text)
            }.joined(separator: "\n\n")
            let firstUser = userTurns.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let inferredTitle = firstUser.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) } ?? resolvedProject
            let lastAssistant = assistantTurns.last?.text ?? ""
            conversation = ConversationRecord(
                id: ConversationRecord.stableId(provider: .primeAgent, sessionId: sessionId),
                provider: .primeAgent,
                sessionId: sessionId,
                projectName: resolvedProject,
                startTime: resolvedStart,
                endTime: resolvedEnd,
                messageCount: filteredForTranscript.count,
                userWordCount: userTurns.reduce(0) { $0 + $1.text.split { $0.isWhitespace || $0.isNewline }.count },
                assistantWordCount: assistantTurns.reduce(0) { $0 + $1.text.split { $0.isWhitespace || $0.isNewline }.count },
                keyFiles: [],
                keyCommands: [],
                keyTools: Array(toolNames.sorted().prefix(20)),
                inferredTaskTitle: inferredTitle,
                lastAssistantMessage: String(lastAssistant.prefix(500)),
                fullText: fullText,
                indexedAt: Date(),
                workingDirectory: cwd,
                fileModifiedAt: mtime,
                summary: nil
            )
        } else {
            conversation = nil
        }

        return (usage, conversation)
    }

    // MARK: - Helpers

    private func parseDate(_ s: String) -> Date? {
        // Prime sessions use RFC3339/ISO8601 with fractional seconds
        if let d = ThreadSafeISO8601DateFormatter.parse(s) { return d }
        // Fallback: numeric epoch seconds string
        if let n = Double(s) { return Date(timeIntervalSince1970: n) }
        return nil
    }

    private func intVal(_ v: Any?) -> Int {
        switch v {
        case let i as Int: return i
        case let i as Int64: return Int(clamping: i)
        case let d as Double: return Int(d.rounded())
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        default: return 0
        }
    }

    private func doubleVal(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let i as Int64: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let d = v as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: d), let s = String(data: data, encoding: .utf8) { return s }
        if let a = v as? [Any], let data = try? JSONSerialization.data(withJSONObject: a), let s = String(data: data, encoding: .utf8) { return s }
        return "\(v)"
    }
}

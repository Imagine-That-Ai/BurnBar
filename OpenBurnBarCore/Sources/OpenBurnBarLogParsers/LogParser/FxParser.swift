import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

// MARK: - fx Parser
//
// Research findings — fx (https://fx.sh, Vercel Labs, Apache-2.0, Zig):
//
// Storage layout (pinned from the fx source, vercel-labs/fx @ v0.0.3):
//   ~/.fx/sessions/<session-id>/session.json    — schema-v3 manifest
//   ~/.fx/sessions/<session-id>/usage-v2.json   — rich usage sidecar (primary usage source)
//   ~/.fx/sessions/<session-id>/events.jsonl    — durable event log (turn transcript)
//   ~/.fx/sessions/<session-id>/display.json    — derived display metadata (title)
//   ~/.fx/sessions/list.json / summary.json     — root-level caches, not parsed
//
// Session ids look like `1770000000000-1770000000000000000-a1b2c3d4e5f60718`
// (millis-nanos-hex). The workspace a session belongs to is carried as
// `workspace_root` on the manifest, not by directory nesting.
//
// Usage sidecar (`usage-v2.json`, schema_version 2):
//   { schema_version, billing: "complete"|"incomplete", total_cost (exact USD),
//     input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
//     reasoning_tokens, billable_web_search_calls, lines_added, lines_removed,
//     models: [{ model: "provider/model-id", total_cost, input_tokens, ... }] }
//   `total_cost` is the exact USD the gateway billed — BurnBar prefers it
//   verbatim (same policy as PrimeAgentParser's `usage.cost.total`).
//
// Manifest (`session.json`, schema_version 3):
//   { schema_version, id, workspace_root, created_at_ms, updated_at_ms,
//     total_input_tokens, total_output_tokens, history_len, preferences: { model } }
//   Legacy schema-1/2 manifests carry a `history` array instead of the event
//   log; the parser reads totals from them but transcripts come from
//   events.jsonl when present. `created_at_ms`/`updated_at_ms` are the
//   authoritative session bounds — usage-only ingestion never opens
//   events.jsonl, so dating rows off the manifest file's mtime would
//   misallocate spend whenever a session file is rewritten, restored or copied.
//
// Event log (`events.jsonl`):
//   One JSON object per line: { seq, timestamp_ms, kind, payload } — `kind` is
//   a TOP-LEVEL field (session_started, history_turn_committed,
//   usage_checkpointed, ...). Turns live in
//   payload.turn: { kind: "assistant"|"background_command"|"interrupted"|"compacted_summary",
//     user: { text }, assistant: <text>, execution: { tool_steps: [{ tool_calls: [{ name }] }],
//     files: [{ path }] } }.
//
// Robustness: fx is experimental (v0.0.3) and its schema may drift. The parser
// is defensive: every JSON decode is try?-guarded, unknown sidecar schema
// versions fall back to manifest totals with `.lowConfidenceEstimate`, and
// truncated lines are skipped without aborting the whole file.
//
// The parser is flat-file, stateless, `Sendable`, and Windows-buildable (uses
// only `FileManager` + `FileHandle` + `JSONSerialization`).
public final class FxParser: LogParser, Sendable {
    public let provider: AgentProvider = .fx
    let logDirectoryOverride: String?
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSetSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    /// Highest `usage-v2.json` schema version this parser understands.
    /// Newer sidecars fall back to manifest totals instead of misparsing.
    static let maxSupportedSidecarSchemaVersion = 2

    public init(
        logDirectoryOverride: String? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.logDirectoryOverride = logDirectoryOverride
        self.fileManager = fileManager
        let cacheURL: URL
        if let override = logDirectoryOverride {
            cacheURL = URL(fileURLWithPath: override).appendingPathComponent(".obb-fx-parser-cache.plist")
        } else {
            cacheURL = appPaths.fxParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "FxParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult {
        try parseSynchronously(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        try parseSynchronously(options: options)
    }

    public func parseSynchronously(options: LogParseOptions = .default) throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        let sessionsPath = logDirectoryOverride ?? NSString(string: provider.logDirectory).expandingTildeInPath
        guard fileManager.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }
        let sessionsURL = URL(fileURLWithPath: sessionsPath)

        // One directory per session; root-level list.json/summary.json caches
        // are files, not session dirs, and are skipped by the isDirectory filter.
        let sessionDirs = (try? fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys + [.isDirectoryKey]
        ))
            .map { $0.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } }
            ?? []
        guard !sessionDirs.isEmpty else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        for sessionDir in sessionDirs.sorted(by: { $0.path < $1.path }) {
            let sessionId = sessionDir.lastPathComponent
            let sessionFiles = Self.sessionFiles(in: sessionDir)
            guard !sessionFiles.isEmpty else { continue }

            let cacheKey = sessionDir.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(sessionFiles) else { continue }

            let signature = FileSetSignature(urls: sessionFiles, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .fx) })
                continue
            }

            sessionScanCount.withLock { $0 += 1 }
            if let pair = tryParseSession(
                sessionId: sessionId,
                sessionDir: sessionDir,
                options: options
            ) {
                if let usage = pair.usage {
                    usages.append(usage)
                    if let signature {
                        parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                            signature: signature,
                            usages: [usage]
                        )
                        cacheMutated = true
                    }
                }
                if let conversation = pair.conversation {
                    conversations.append(conversation)
                }
            }
        }

        let stalePaths = Set(parseCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                parseCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    // MARK: - Discovery

    private static func sessionFiles(in sessionDir: URL) -> [URL] {
        let names = ["session.json", "usage-v2.json", "events.jsonl", "display.json"]
        return names.compactMap { name in
            let url = sessionDir.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // MARK: - Per-session

    private func tryParseSession(
        sessionId: String,
        sessionDir: URL,
        options: LogParseOptions
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        let manifestURL = sessionDir.appendingPathComponent("session.json")
        let sidecarURL = sessionDir.appendingPathComponent("usage-v2.json")
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl")
        let displayURL = sessionDir.appendingPathComponent("display.json")

        let manifest = readJSONObject(at: manifestURL)
        let sidecar = readJSONObject(at: sidecarURL)
        let display = readJSONObject(at: displayURL)

        let mtime = (try? fileManager.attributesOfItem(atPath: manifestURL.path)[.modificationDate]) as? Date
        // Authoritative session bounds. These are the only timestamps available
        // during usage-only ingestion, where events.jsonl is never opened.
        let manifestCreated = Self.msDate(manifest?["created_at_ms"])
        let manifestUpdated = Self.msDate(manifest?["updated_at_ms"])

        // Usage: sidecar first (exact), manifest totals as fallback.
        var totalInput = 0
        var totalOutput = 0
        var totalCacheWrite = 0
        var totalCacheRead = 0
        var totalReasoning = 0
        var totalCost: Double = 0
        var costWasExplicit = false
        var model: String?
        var confidence: UsageProvenanceConfidence = .lowConfidenceEstimate

        if let sidecar {
            let schemaVersion = Self.intVal(sidecar["schema_version"])
            if schemaVersion <= Self.maxSupportedSidecarSchemaVersion {
                totalInput = max(Self.intVal(sidecar["input_tokens"]), 0)
                totalOutput = max(Self.intVal(sidecar["output_tokens"]), 0)
                totalCacheWrite = max(Self.intVal(sidecar["cache_write_tokens"]), 0)
                totalCacheRead = max(Self.intVal(sidecar["cache_read_tokens"]), 0)
                totalReasoning = max(Self.intVal(sidecar["reasoning_tokens"]), 0)
                totalCost = Self.doubleVal(sidecar["total_cost"])
                costWasExplicit = true
                model = Self.dominantModel(in: sidecar["models"])
                // A sidecar whose billing projection is incomplete still carries
                // in-flight generations; grade it as a high-confidence estimate
                // until the session settles.
                let billing = sidecar["billing"] as? String
                confidence = billing == "complete" ? .exact : .highConfidenceEstimate
            }
        }

        if totalInput == 0, totalOutput == 0, totalCacheRead == 0, totalCacheWrite == 0,
           let manifest {
            totalInput = max(Self.intVal(manifest["total_input_tokens"]), 0)
            totalOutput = max(Self.intVal(manifest["total_output_tokens"]), 0)
            costWasExplicit = false
            confidence = .lowConfidenceEstimate
        }

        if model == nil, let manifest {
            if let preferences = manifest["preferences"] as? [String: Any],
               let preferred = preferences["model"] as? String, !preferred.isEmpty {
                model = Self.normalizeModelName(preferred)
            }
        }

        let hasUsage = totalInput > 0 || totalOutput > 0 || totalCacheRead > 0 || totalCacheWrite > 0

        // Transcript from events.jsonl (top-level `kind` frames). Turns are kept
        // in event-log order (U1, A1, U2, A2) so each answer stays attached to
        // the prompt it replied to.
        var turns: [(isAssistant: Bool, text: String)] = []
        var toolNames = Set<String>()
        var filePaths = Set<String>()
        var firstTime: Date?
        var lastTime: Date?

        if options.includeConversationBodies,
           let handle = try? FileHandle(forReadingFrom: eventsURL) {
            defer { try? handle.close() }
            for line in handle.readAllUTF8Lines() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue // truncated/partial line — skip
                }
                if let date = Self.msDate(json["timestamp_ms"]) {
                    if firstTime == nil { firstTime = date }
                    lastTime = date
                }
                guard let kind = json["kind"] as? String, kind == "history_turn_committed",
                      let payload = json["payload"] as? [String: Any],
                      let turn = payload["turn"] as? [String: Any] else {
                    continue
                }
                if let user = turn["user"] as? [String: Any],
                   let text = user["text"] as? String, !text.isEmpty {
                    turns.append((isAssistant: false, text: text))
                }
                if let assistant = turn["assistant"] as? String, !assistant.isEmpty {
                    turns.append((isAssistant: true, text: assistant))
                }
                if let execution = turn["execution"] as? [String: Any] {
                    if let steps = execution["tool_steps"] as? [[String: Any]] {
                        for step in steps {
                            if let calls = step["tool_calls"] as? [[String: Any]] {
                                for call in calls {
                                    if let name = call["name"] as? String, !name.isEmpty {
                                        toolNames.insert(name)
                                    }
                                }
                            }
                        }
                    }
                    if let files = execution["files"] as? [[String: Any]] {
                        for file in files {
                            if let path = file["path"] as? String, !path.isEmpty {
                                filePaths.insert(path)
                            }
                        }
                    }
                }
            }
        }

        // Workspace + title.
        let workspaceRoot = (manifest?["workspace_root"] as? String).flatMap(nonBlank)
        let projectName: String = {
            if let workspaceRoot {
                let last = URL(fileURLWithPath: workspaceRoot).lastPathComponent
                if !last.isEmpty { return last }
            }
            return "fx"
        }()
        let displayTitle = (display?["title"] as? String).flatMap(nonBlank)

        // Manifest timestamps win over event timestamps so a session is dated
        // identically whether or not this pass read events.jsonl; mtime is the
        // last resort for legacy manifests that carry neither.
        let start = manifestCreated ?? firstTime ?? mtime ?? Date()
        let end = max(manifestUpdated ?? lastTime ?? firstTime ?? mtime ?? start, start)

        // Cost: prefer the explicit sidecar total; fall back to catalog pricing
        // when only manifest totals exist.
        let resolvedModel = model ?? "unknown"
        let cost: Double
        if costWasExplicit {
            cost = totalCost
        } else if hasUsage {
            let pricing = ModelPricing.lookup(model: resolvedModel, providerID: "fx")
            cost = (try? pricing.cost(
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheCreationTokens: totalCacheWrite,
                cacheReadTokens: totalCacheRead
            )) ?? 0
        } else {
            cost = 0
        }

        var usage: TokenUsage?
        if hasUsage {
            usage = TokenUsage(
                provider: .fx,
                sessionId: sessionId,
                projectName: projectName,
                model: resolvedModel,
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheCreationTokens: totalCacheWrite,
                cacheReadTokens: totalCacheRead,
                reasoningTokens: totalReasoning,
                costUSD: cost,
                startTime: start,
                endTime: end,
                provenanceMethod: .providerLog,
                provenanceConfidence: confidence,
                estimatorVersion: ""
            )
        }

        var conversation: ConversationRecord?
        if options.includeConversationBodies, !turns.isEmpty {
            let fullText = turns.map {
                SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: $0.isAssistant, body: $0.text)
            }.joined(separator: "\n\n")
            let firstUser = turns.first { !$0.isAssistant }?
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            let inferredTitle = displayTitle
                ?? firstUser.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                ?? projectName
            let lastAssistant = turns.last { $0.isAssistant }?.text ?? ""
            conversation = ConversationRecord(
                id: ConversationRecord.stableId(provider: .fx, sessionId: sessionId),
                provider: .fx,
                sessionId: sessionId,
                projectName: projectName,
                startTime: start,
                endTime: end,
                messageCount: turns.count,
                userWordCount: Self.wordCount(of: turns, isAssistant: false),
                assistantWordCount: Self.wordCount(of: turns, isAssistant: true),
                keyFiles: Array(filePaths.sorted().prefix(20)),
                keyCommands: [],
                keyTools: Array(toolNames.sorted().prefix(20)),
                inferredTaskTitle: inferredTitle,
                lastAssistantMessage: String(lastAssistant.prefix(500)),
                fullText: fullText,
                indexedAt: Date(),
                workingDirectory: workspaceRoot,
                fileModifiedAt: mtime,
                summary: nil
            )
        }

        if usage == nil && conversation == nil { return nil }
        return (usage, conversation)
    }

    // MARK: - Helpers

    /// fx model ids are `provider/model-id`; BurnBar's catalog keys on the
    /// bare model id, so strip the provider prefix when present.
    static func normalizeModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.firstIndex(of: "/") {
            let suffix = trimmed[trimmed.index(after: slash)...]
            if !suffix.isEmpty { return String(suffix) }
        }
        return trimmed
    }

    /// The model with the highest billed cost in the sidecar's `models[]`
    /// array; ties break on input tokens. Returns `nil` for an empty array.
    private static func dominantModel(in modelsValue: Any?) -> String? {
        guard let models = modelsValue as? [[String: Any]], !models.isEmpty else { return nil }
        var best: [String: Any]?
        var bestCost = -Double.greatestFiniteMagnitude
        var bestInput = 0
        for entry in models {
            let cost = Self.doubleVal(entry["total_cost"])
            let input = Self.intVal(entry["input_tokens"])
            if cost > bestCost || (cost == bestCost && input > bestInput) {
                best = entry
                bestCost = cost
                bestInput = input
            }
        }
        guard let best, let raw = best["model"] as? String, !raw.isEmpty else { return nil }
        return normalizeModelName(raw)
    }

    /// Words spoken by one side of an ordered transcript.
    private static func wordCount(of turns: [(isAssistant: Bool, text: String)], isAssistant: Bool) -> Int {
        turns.reduce(0) { total, turn in
            guard turn.isAssistant == isAssistant else { return total }
            return total + turn.text.split { $0.isWhitespace || $0.isNewline }.count
        }
    }

    /// fx timestamps are epoch milliseconds. Missing, non-numeric, and
    /// non-positive values are treated as absent rather than as 1970.
    private static func msDate(_ value: Any?) -> Date? {
        guard let ms = int64Val(value), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1_000.0)
    }

    private func readJSONObject(at url: URL) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil } // try?-ok(absent or unreadable file)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] // try?-ok(malformed JSON skipped)
    }

    private func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intVal(_ value: Any?) -> Int {
        switch value {
        case let i as Int: return i
        case let i as Int64: return Int(clamping: i)
        case let d as Double: return Int(d.rounded())
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        default: return 0
        }
    }

    private static func int64Val(_ value: Any?) -> Int64? {
        switch value {
        case let i as Int64: return i
        case let i as Int: return Int64(i)
        case let d as Double: return Int64(d)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }

    private static func doubleVal(_ value: Any?) -> Double {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let i as Int64: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }
}

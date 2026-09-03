import Foundation
import OpenBurnBarKernel
import OpenBurnBarParserSupport

// MARK: - Muse Parser
//
// Research findings — Muse (https://developer.meta.com/ai/products/muse-code/) on macOS:
//
// Storage layout (2026-08-05 observed on macOS 14, Muse v0.1.0):
//   ~/.local/share/muse/sessions/YYYY/MM/DD/<session_id>/session.jsonl  (XDG-style)
//   ~/.local/share/muse/sessions/YYYY/MM/DD/<session_id>/subagent/<uuid>/session.jsonl
//   ~/.local/share/muse/session-index.db  (SQLite index, mirrors Codex pattern but
//          not parsed directly — the JSONL is canonical for token accuracy)
//   ~/.local/share/muse/model-catalog/*.json  (pricing: see below)
//   ~/.local/share/muse/tui-history.jsonl  (TUI command history, not usage)
//
// Log format:
//   Envelope JSONL — each line is an envelope:
//     { schema_version, id, stream:{kind:"session",id:sessionId}, sequence,
//       recorded_at: Int64 microseconds since epoch,
//       record_type:"event", durability:"durable",
//       payload_type:"runtime.session.metadata" | "runtime.session" | "tool_batch.effect.started" | ...,
//       payload_schema_version, payload:{kind, ...} }
//   The durable payloads that carry usage are:
//     payload_type == "runtime.session" && payload.kind == "run" && event.kind == "model_completed"
//       → usage:{input_tokens, output_tokens, cached_tokens, cache_write_tokens,
//                cache_read_tokens, reasoning_tokens} + model:"muse-spark-1.2-contributor"
//     payload_type == "runtime.session" && event.kind == "goal_usage_attribution"
//       → record.quantity:{input_tokens, output_tokens, cached_tokens, reasoning_tokens} (duplicates
//         model_completed; the parser prefers model_completed to avoid double-counting).
//   Prompts live in:
//     payload_type == "runtime.session" && event.kind == "started" → prompt:String
//     event.kind == "inbox_item_queued" → summary/body
//     event.kind == "assistant_message_committed" → text (assistant completion)
//   Tool calls:
//     payload_type == "tool_batch.effect.started" → record.tool_name, parallel_profile.subject
//
// Model identifiers:
//   provider_id:"meta" , model_id:"muse-spark-1.3" / "muse-spark-1.3-contributor"
//     (also 1.2 / 1.2-contributor / 1.1)
//   Pricing (Meta Model API):
//     muse-spark-1.3:              input $1.25 /M, output $4.25 /M, cached $0.15 /M
//     muse-spark-1.3-contributor:  input $0.10 /M, output $0.20 /M, cached $0.002 /M
//   The parser uses ModelPricing.lookup(model:providerID:) — catalog entries are under
//   the "meta" provider (see Resources/catalog.json). Fallback pricing applies when
//   the catalog is absent (e.g., offline tests).
//
// Muse Code 1.0.2+ also writes retained_frame wrapper lines whose usage lives in
// children[].record_json, and run.model.configured for the selected model.
//
// Auth state:
//   Muse authenticates via a browser-linked device flow; credentials are stored outside
//   the session logs (Keychain / ~/.config not read by the meter). The parser requires
//   no auth — it reads only the local session logs, matching the Hermes/Codex/Droid
//   local-first pattern.
//
// Robustness: every JSON decode is try?-guarded; truncated lines, missing fields,
// empty sessions, and non-UTF8 tails are skipped without aborting the whole file.
//
public final class MuseParser: LogParser, Sendable {
    public let provider: AgentProvider = .muse
    let logDirectoryOverride: String?

    // Injected seam for tests (mirrors ClineFormatParser / OpenCode patterns).
    private let fileManager: FileManager
    private let cacheStore: ParserDiskCacheStore<CachedUsageBundleEntry<FileSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    public init(
        logDirectoryOverride: String? = nil,
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.logDirectoryOverride = logDirectoryOverride
        self.fileManager = fileManager
        let cacheURL: URL
        if let override = logDirectoryOverride {
            cacheURL = URL(fileURLWithPath: override).appendingPathComponent(".obb-muse-parser-cache.plist")
        } else {
            cacheURL = appPaths.museParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 2,
            logLabel: "MuseParser"
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

        // Recursive discovery — Muse nests YYYY/MM/DD/<id>/session.jsonl.
        // We accept any *.jsonl under the sessions root (including subagent).
        let candidates = recursiveJSONLFiles(under: sessionsURL)
        guard !candidates.isEmpty else {
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

        for file in candidates {
            let cacheKey = file.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(file) else { continue }
            let signature = FileSignature(for: file, using: fileManager)
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(contentsOf: cached.sessions.map { $0.makeUsage(provider: .muse) })
                continue
            }

            sessionScanCount.withLock { $0 += 1 }
            if let pair = tryParseFile(file: file, options: options) {
                if let u = pair.usage {
                    usages.append(u)
                    if let signature {
                        parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                            signature: signature,
                            usages: [u]
                        )
                        cacheMutated = true
                    }
                }
                if let c = pair.conversation { conversations.append(c) }
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

    private func recursiveJSONLFiles(under root: URL) -> [URL] {
        var out: [URL] = []
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys, options: [.skipsHiddenFiles]) else {
            return out
        }
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" && url.lastPathComponent == "session.jsonl" {
                out.append(url)
            } else if url.pathExtension == "jsonl" {
                // Accept any jsonl fallback (future-proof) but prefer session.jsonl
                // to avoid double counting non-session artifacts.
                // Currently only session.jsonl exists; keep narrow.
                continue
            }
        }
        // Fallback: if no session.jsonl found (e.g., test fixtures with flat files),
        // accept any *.jsonl directly under root.
        if out.isEmpty, let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys
        ) {
            out.append(contentsOf: contents.filter { $0.pathExtension == "jsonl" })
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - Per-file

    private func tryParseFile(file: URL, options: LogParseOptions) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date

        var sessionId: String?
        var workspaceRoot: String?
        var modelId: String?

        var totalInput = 0
        var totalOutput = 0
        var totalCached = 0 // cached_tokens doubles as cache_read
        var totalCacheWrite = 0
        var totalCacheRead = 0
        var totalReasoning = 0
        var lastModel: String?
        var promptTexts: [String] = []
        var assistantTexts: [String] = []
        var toolNames = Set<String>()
        var firstTime: Date?
        var lastTime: Date?
        var sequencePromptCount = 0

        // For dedup: if we see both goal_usage_attribution and model_completed, we
        // prefer model_completed. Collect both then choose.
        var modelCompletedCount = 0
        var goalAttributionOnlyInput = 0
        var goalAttributionOnlyOutput = 0

        func consumeEnvelope(_ json: [String: Any]) {
            // session id from stream (authoritative)
            if sessionId == nil, let stream = json["stream"] as? [String: Any], let sid = stream["id"] as? String, !sid.isEmpty {
                sessionId = sid
            }

            // recorded_at → Date
            let recDate: Date? = {
                if let us = json["recorded_at"] as? Int64 { return dateFromMicroseconds(us) }
                if let us = json["recorded_at"] as? Int { return dateFromMicroseconds(Int64(us)) }
                if let us = json["recorded_at"] as? NSNumber { return dateFromMicroseconds(us.int64Value) }
                return nil
            }()
            if let d = recDate {
                if firstTime == nil { firstTime = d }
                lastTime = d
            }

            guard let payloadType = json["payload_type"] as? String else { return }
            guard let payload = json["payload"] as? [String: Any] else { return }

            // Metadata: workspace_root / model
            if payloadType == "runtime.session.metadata" {
                if let record = payload["record"] as? [String: Any] {
                    workspaceRoot = (record["workspace_root"] as? String) ?? workspaceRoot
                    modelId = (record["model_id"] as? String) ?? modelId
                    if let m = record["model_id"] as? String, !m.isEmpty { lastModel = m }
                }
                return
            }

            if payloadType == "run.model.configured" {
                if let record = payload["record"] as? [String: Any] {
                    if let m = record["model_id"] as? String, !m.isEmpty {
                        lastModel = m
                        modelId = m
                    }
                }
                return
            }

            // Tool calls
            if payloadType == "tool_batch.effect.started" {
                if options.includeConversationBodies,
                   let record = payload["record"] as? [String: Any], let name = record["tool_name"] as? String, !name.isEmpty {
                    toolNames.insert(name)
                }
                return
            }

            // Run events
            if payloadType == "runtime.session" {
                guard let kind = payload["kind"] as? String, kind == "run" else {
                    // Also handle started prompts at run level? The prompt event is inside run event.kind == "started"
                    // But our guard already filters to kind==run, so extract started inside.
                    return
                }
                guard let event = payload["event"] as? [String: Any], let eventKind = event["kind"] as? String else { return }

                switch eventKind {
                case "started":
                    if options.includeConversationBodies,
                       let prompt = event["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        promptTexts.append(prompt)
                        sequencePromptCount += 1
                    }
                case "inbox_item_queued":
                    if options.includeConversationBodies,
                       let body = event["body"] as? String, !body.isEmpty {
                        // avoid duplicating started prompt (queued mirrors started)
                        // only add if not already counted
                        if promptTexts.last != body {
                            promptTexts.append(body)
                        }
                    }
                case "assistant_message_committed":
                    if options.includeConversationBodies,
                       let text = event["text"] as? String, !text.isEmpty {
                        assistantTexts.append(text)
                    }
                case "model_completed":
                    let usage = event["usage"] as? [String: Any]
                    let inp = intVal(usage?["input_tokens"])
                    let out = intVal(usage?["output_tokens"])
                    let cached = intVal(usage?["cached_tokens"])
                    let cw = intVal(usage?["cache_write_tokens"])
                    let cr = intVal(usage?["cache_read_tokens"])
                    let reas = intVal(usage?["reasoning_tokens"])
                    totalInput += max(inp, 0)
                    totalOutput += max(out, 0)
                    totalCached += max(cached, 0)
                    totalCacheWrite += max(cw, 0)
                    // cache_read may duplicate cached; prefer explicit cache_read when non-zero
                    let effectiveCR = cr > 0 ? cr : cached
                    totalCacheRead += max(effectiveCR, 0)
                    totalReasoning += max(reas, 0)
                    modelCompletedCount += 1
                    if let m = event["model"] as? String, !m.isEmpty { lastModel = m }
                case "goal_usage_attribution":
                    // Only accumulate if we never see model_completed (fallback)
                    if let record = event["record"] as? [String: Any],
                       let qty = record["quantity"] as? [String: Any],
                       let reported = qty["reported"] as? Bool, reported,
                       let family = record["usage_family"] as? String, family == "provider" {
                        let inp = intVal(qty["input_tokens"])
                        let out = intVal(qty["output_tokens"])
                        let cached = intVal(qty["cached_tokens"])
                        let reas = intVal(qty["reasoning_tokens"])
                        // Hold as fallback; only use if modelCompletedCount==0
                        goalAttributionOnlyInput += inp
                        goalAttributionOnlyOutput += reas == 0 ? out : out // keep separate
                        _ = cached
                        // we don't sum cached here yet; will use model_completed when available
                    }
                case "model_response_created", "assistant_tool_calls_committed", "reasoning_committed":
                    // not needed for token totals
                    break
                default:
                    break
                }
            }
        }

        for line in handle.readAllUTF8Lines() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue // truncated/partial line — skip
            }

            for envelopeJSON in expandedEnvelopes(from: json) {
                consumeEnvelope(envelopeJSON)
            }
        }

        // If no model_completed but we have attribution fallback, use it
        if modelCompletedCount == 0 && (goalAttributionOnlyInput > 0 || goalAttributionOnlyOutput > 0) {
            totalInput = max(totalInput, goalAttributionOnlyInput)
            totalOutput = max(totalOutput, goalAttributionOnlyOutput)
            // cached unknown in attribution fallback — keep 0
        }

        // Resolve session identity: prefer envelope stream id, fallback to filename parent dir name
        let resolvedSessionId: String = {
            if let sid = sessionId, !sid.isEmpty { return sid }
            // file is .../<session_id>/session.jsonl  → parent is session id
            let parent = file.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty && parent != "sessions" { return parent }
            return file.deletingPathExtension().lastPathComponent
        }()

        // Deduplicate empty sessions: if no tokens and no prompt, skip (e.g., empty startup)
        let hasPrompt = !promptTexts.isEmpty
        let hasUsage = totalInput > 0 || totalOutput > 0 || totalCached > 0 || totalCacheRead > 0
        // Also handle case where session had only assistant text but no usage (rare) — still skip usage row
        // but keep conversation if we have text and includeConversation requested.
        if !hasUsage && !hasPrompt && assistantTexts.isEmpty {
            // Check if this was a valid but empty session (e.g., early exit) — skip usage row
            // but still possibly return nil for both to avoid polluting meter with zero rows.
            // Only emit usage row when there is real token data.
            if !options.includeConversationBodies || (assistantTexts.isEmpty && promptTexts.isEmpty) {
                return nil
            }
        }

        // No usage row but we have conversation content and caller wants it → still need to produce conversation
        let resolvedModel = lastModel ?? modelId ?? "muse-spark-1.3-contributor"
        let projectName: String = {
            if let ws = workspaceRoot, !ws.isEmpty {
                let last = URL(fileURLWithPath: ws).lastPathComponent
                if !last.isEmpty { return last }
            }
            // fallback: parent folder name or session id prefix
            let parent = file.deletingLastPathComponent().lastPathComponent
            if parent.count >= 8 { return parent }
            return "Muse"
        }()

        let start = firstTime ?? mtime ?? Date()
        let end = lastTime ?? firstTime ?? mtime ?? start

        // Cost — prefer catalog pricing; Muse pricing lives under the "meta" provider
        // in Resources/catalog.json (the canonical vendor key). Scoped lookup with
        // "meta" is exact; nil fallback also works via global search but is less precise.
        let costUSD: Double = {
            if hasUsage {
                let pricing = ModelPricing.lookup(model: resolvedModel, providerID: "meta")
                // If model is unknown to catalog, lookup returns fallback (2.5/10/1.25); we keep it.
                // For the contributor variant, catalog correctly returns 0.10/0.20/0.002.
                return (try? pricing.cost(inputTokens: totalInput, outputTokens: totalOutput, cacheCreationTokens: totalCacheWrite, cacheReadTokens: totalCacheRead)) ?? 0
            }
            return 0
        }()

        // Also account for cached token pricing: ModelPricing.cost already includes cacheReadTokens,
        // but our totalInput includes cached_tokens (which are subset of input). The catalog's
        // cacheReadPerMToken discounts them correctly (inputTokens already contains cached portion;
        // the cost formula adds cacheRead separately, so we pass them as stored).
        // This matches ClaudeCodeParser's pattern where inputTokens is total and cacheRead is extra.

        var usage: TokenUsage?
        if hasUsage {
            // Build TokenUsage — provider .muse, raw sessionId, project, model, counts, cost
            // Provenance is exact (log-reported), no estimation.
            usage = TokenUsage(
                provider: .muse,
                sessionId: resolvedSessionId,
                projectName: projectName,
                model: resolvedModel,
                inputTokens: totalInput,
                outputTokens: totalOutput,
                cacheCreationTokens: totalCacheWrite,
                cacheReadTokens: totalCacheRead,
                reasoningTokens: totalReasoning,
                costUSD: costUSD,
                startTime: start,
                endTime: end,
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact,
                estimatorVersion: ""
            )
        }

        var conversation: ConversationRecord?
        if options.includeConversationBodies {
            let hasContent = !promptTexts.isEmpty || !assistantTexts.isEmpty
            if hasContent {
                let userText = promptTexts.first ?? projectName
                let lastAssistant = assistantTexts.last ?? ""
                // Full transcript: interleave prompts then assistants (best-effort, since envelope order
                // is preserved by our sequential read, but we collected separately for simplicity).
                // For now join with clear sections.
                var transcriptParts: [String] = []
                for p in promptTexts {
                    transcriptParts.append(SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: false, body: p))
                }
                for a in assistantTexts {
                    transcriptParts.append(SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: true, body: a))
                }
                let fullText = transcriptParts.joined(separator: "\n\n")

                // Tool names deduped sorted
                let tools = Array(toolNames.sorted().prefix(20))

                conversation = ConversationRecord(
                    id: ConversationRecord.stableId(provider: .muse, sessionId: resolvedSessionId),
                    provider: .muse,
                    sessionId: resolvedSessionId,
                    projectName: projectName,
                    startTime: start,
                    endTime: end,
                    messageCount: promptTexts.count + assistantTexts.count,
                    userWordCount: promptTexts.joined(separator: " ").split { $0.isWhitespace || $0.isNewline }.count,
                    assistantWordCount: assistantTexts.joined(separator: " ").split { $0.isWhitespace || $0.isNewline }.count,
                    keyFiles: [],
                    keyCommands: [],
                    keyTools: tools,
                    inferredTaskTitle: String(userText.prefix(120)),
                    lastAssistantMessage: String(lastAssistant.prefix(500)),
                    fullText: fullText,
                    indexedAt: Date(),
                    workingDirectory: workspaceRoot,
                    fileModifiedAt: mtime,
                    summary: nil
                )
            } else if hasUsage {
                // Usage-only session without extractable prompts — still build minimal conversation
                // so SessionLogs shows something? Reuse PromptTexts fallback: empty.
                // Only emit if we have usage and the caller asked for conversations (mirrors
                // FactoryDroidParser behavior where conversation is optional when include flag false).
                // Here we skip when no text.
            }
        }

        // If neither produced, skip
        if usage == nil && conversation == nil { return nil }
        return (usage, conversation)
    }

    // MARK: - Helpers

    /// Muse Code 1.0.2+ prefixes some durable records with a retained_frame
    /// wrapper. Usage still lives in the inner envelope JSON.
    private func expandedEnvelopes(from json: [String: Any]) -> [[String: Any]] {
        if json["payload_type"] != nil {
            return [json]
        }
        guard json["retained_frame"] != nil,
              let children = json["children"] as? [[String: Any]] else {
            return []
        }
        var out: [[String: Any]] = []
        out.reserveCapacity(children.count)
        for child in children {
            guard let recordJSON = child["record_json"] as? String,
                  let data = recordJSON.data(using: .utf8),
                  let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            out.append(contentsOf: expandedEnvelopes(from: inner))
        }
        return out
    }

    private func dateFromMicroseconds(_ us: Int64) -> Date {
        // Muse writes microseconds since epoch (see sample: 1785970740961126 ~ 2026-08-05)
        // Some sessions may store milliseconds; heuristic: values > 1e15 are microseconds.
        let seconds: Double
        if us > 1_000_000_000_000_000 { // > 1e15 → microseconds
            seconds = Double(us) / 1_000_000.0
        } else if us > 1_000_000_000_000 { // > 1e12 → milliseconds
            seconds = Double(us) / 1_000.0
        } else {
            seconds = Double(us)
        }
        return Date(timeIntervalSince1970: seconds)
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
}

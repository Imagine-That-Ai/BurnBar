import Foundation
import OpenBurnBarKernel

// MARK: - Codex Rollout Scanner
//
// Shared JSONL scanning engine for Codex `rollout-*.jsonl` session files,
// used by both CodexParser copies (the macOS app's GRDB-backed parser and
// Core's SQLiteReader-backed parser). Keeping the file-scanning state machine
// in one place is what keeps the two copies from drifting.
//
// Two hard-won properties, both born from the 2026-07-16 incident where an
// ungoverned scan of a 21GB ~/.codex corpus drove the app to a 25.4GB
// footprint and the machine into swap death:
//
//  * **Incremental**: rollout files are append-only event logs that grow for
//    hours while sessions run. The scanner persists a byte offset plus the
//    token accumulator per file, so a re-scan of a grown file reads only the
//    appended tail instead of the whole file every refresh tick.
//  * **Bounded**: every decoded line is wrapped in `autoreleasepool` (the
//    `JSONSerialization` object graphs are autoreleased, and parse loops run
//    inside dispatch blocks that never drain), lines that cannot contain
//    token events are skipped before JSON decoding, and a shared
//    `ParserResourceGovernor` can abort on memory ceiling.

/// Persistable per-file scan state for incremental token extraction.
///
/// `byteOffset` always points just past the last *terminated* line consumed;
/// an unterminated trailing line (a record mid-append by a live writer) is
/// parsed into returned totals but never into persisted state, so the next
/// scan re-reads it once complete.
public struct CodexTokenScanState: Codable, Equatable, Sendable {
    public var byteOffset: Int64
    /// FNV-1a 64 digest of the file's first `headDigestLength` bytes when the
    /// state was created. A mismatch on a later scan means the file was
    /// rewritten (not appended) and the scan restarts from offset 0.
    public var headDigest: String
    public var headDigestLength: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var foundCumulative: Bool
    public var foundDelta: Bool
    /// Signature of the last processed Codex token event. Current Codex logs
    /// can repeat the same token payload under multiple rate-limit envelopes;
    /// persisting this prevents double counting across incremental resumes.
    public var lastTokenEventSignature: String?

    public init(
        byteOffset: Int64,
        headDigest: String,
        headDigestLength: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        foundCumulative: Bool = false,
        foundDelta: Bool = false,
        lastTokenEventSignature: String? = nil
    ) {
        self.byteOffset = byteOffset
        self.headDigest = headDigest
        self.headDigestLength = headDigestLength
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.foundCumulative = foundCumulative
        self.foundDelta = foundDelta
        self.lastTokenEventSignature = lastTokenEventSignature
    }
}

/// Lightweight projection of one Codex `threads` row; materialized so the
/// database reader (GRDB in the app, SQLiteReader in Core) can be closed
/// before any rollout file is scanned.
public struct CodexThreadRow: Sendable {
    public let threadId: String
    public let model: String
    public let rawTitle: String
    public let projectName: String
    public let tokensUsed: Int
    public let startTime: Date
    public let endTime: Date
    public let expandedRolloutPath: String?

    public init(
        threadId: String,
        model: String,
        rawTitle: String,
        projectName: String,
        tokensUsed: Int,
        startTime: Date,
        endTime: Date,
        expandedRolloutPath: String?
    ) {
        self.threadId = threadId
        self.model = model
        self.rawTitle = rawTitle
        self.projectName = projectName
        self.tokensUsed = tokensUsed
        self.startTime = startTime
        self.endTime = endTime
        self.expandedRolloutPath = expandedRolloutPath
    }
}

public enum CodexSessionLogScanner {

    /// How many bytes of file head the rewrite-detection digest covers.
    static let headDigestSpan = 4096
    /// Governor memory checkpoints happen every this many scanned lines.
    static let checkpointLineInterval = 4096
    /// Cold scans larger than this use Codex's state-DB total immediately.
    /// Incremental tails below the cap still converge to exact billing buckets.
    static let maximumTokenScanBytesPerFile: Int64 = 16 * 1024 * 1024
    /// Exact bucket refinement is optional because `threads.tokens_used`
    /// already supplies the authoritative total. Keep the entire foreground
    /// Codex pass bounded, even when many medium-sized rollouts are present.
    static let maximumTokenScanBytesPerPass: Int64 = 16 * 1024 * 1024

    public struct TokenScanResult {
        /// Exact token breakdown, or `nil` when the file contained no token
        /// events (callers fall back to their heuristic estimate).
        public let usage: (input: Int, output: Int, cacheRead: Int)?
        /// State to persist for the next incremental scan.
        public let state: CodexTokenScanState
    }

    // MARK: - Token Scanning

    /// Scans a rollout file for token counts, resuming from `previousState`
    /// when the file has only grown since that state was captured.
    ///
    /// Returns `nil` when the file does not exist or cannot be opened.
    /// Throws only `ParserResourceExceeded` (from the governor).
    ///
    /// Token semantics prefer per-turn Codex `last_token_usage` deltas when
    /// present. Current Codex rollout logs also carry `total_token_usage`, but
    /// that value is an account/window counter and can dwarf one session by
    /// orders of magnitude. Cumulative totals remain the fallback for legacy
    /// files that do not emit deltas.
    public static func scanTokens(
        path: String,
        fileManager: FileManager = .default,
        previousState: CodexTokenScanState?,
        governor: ParserResourceGovernor? = nil
    ) throws -> TokenScanResult? {
        guard fileManager.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        let fileSize = ((try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0

        var accumulator: TokenAccumulator
        var resumeOffset: Int64 = 0
        var headDigest: String
        var headDigestLength: Int

        if let previous = previousState,
           previous.byteOffset <= fileSize,
           matchesHeadDigest(previous, handle: handle) {
            accumulator = TokenAccumulator(
                input: previous.inputTokens,
                output: previous.outputTokens,
                cacheRead: previous.cacheReadTokens,
                foundCumulative: previous.foundCumulative,
                foundDelta: previous.foundDelta,
                lastTokenEventSignature: previous.lastTokenEventSignature
            )
            resumeOffset = previous.byteOffset
            headDigest = previous.headDigest
            headDigestLength = previous.headDigestLength
        } else {
            accumulator = TokenAccumulator()
            headDigestLength = Int(min(Int64(headDigestSpan), fileSize))
            headDigest = digestOfHead(handle: handle, length: headDigestLength)
        }

        try? handle.seek(toOffset: UInt64(resumeOffset)) // try?-ok(seek failure falls back to reading from current position 0)
        let reader = BufferedLineReader(fileHandle: handle, startOffset: resumeOffset)

        var persistedOffset = resumeOffset
        var scannedLines = 0
        var tailAccumulator: TokenAccumulator?

        while let line = reader.nextLine() {
            scannedLines += 1
            if scannedLines % checkpointLineInterval == 0 {
                try governor?.checkpoint()
            }

            // Cheap byte-scan prefilter: every envelope shape that can carry
            // token counts (`token_count`, `total_token_usage`,
            // `last_token_usage`, root `input_tokens`/`output_tokens`)
            // mentions "token"; lines without it cannot change the result.
            guard line.text.contains("token") else {
                if line.isTerminated { persistedOffset = line.endOffset }
                continue
            }

            if line.isTerminated {
                autoreleasepool {
                    Self.reduceTokenLine(line.text, into: &accumulator)
                }
                persistedOffset = line.endOffset
            } else {
                // Unterminated trailing line: count it toward the returned
                // totals but never toward persisted state — a live writer may
                // still be appending it, and the next scan must re-read it.
                var tail = accumulator
                autoreleasepool {
                    Self.reduceTokenLine(line.text, into: &tail)
                }
                tailAccumulator = tail
            }
        }

        let effective = tailAccumulator ?? accumulator
        let state = CodexTokenScanState(
            byteOffset: persistedOffset,
            headDigest: headDigest,
            headDigestLength: headDigestLength,
            inputTokens: accumulator.input,
            outputTokens: accumulator.output,
            cacheReadTokens: accumulator.cacheRead,
            foundCumulative: accumulator.foundCumulative,
            foundDelta: accumulator.foundDelta,
            lastTokenEventSignature: accumulator.lastTokenEventSignature
        )
        let usage: (input: Int, output: Int, cacheRead: Int)? =
            (effective.foundCumulative || effective.foundDelta)
            ? (effective.input, effective.output, effective.cacheRead)
            : nil
        return TokenScanResult(usage: usage, state: state)
    }

    struct TokenAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var foundCumulative = false
        var foundDelta = false
        var lastTokenEventSignature: String?
    }

    /// One line of the Codex token state machine.
    static func reduceTokenLine(_ text: String, into accumulator: inout TokenAccumulator) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
            return
        }
        guard let info = TokenExtractionUtility.codexTokenCountInfo(from: json) else {
            return
        }

        let cumulative = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(info)

        if let lastUsage = info["last_token_usage"] as? [String: Any] {
            let signature = duplicateGuardSignature(cumulative: cumulative, delta: lastUsage)
            if let signature, signature == accumulator.lastTokenEventSignature {
                return
            }

            if accumulator.foundCumulative && !accumulator.foundDelta {
                accumulator.input = 0
                accumulator.output = 0
                accumulator.cacheRead = 0
            }

            let deltaInput = lastUsage["input_tokens"] as? Int ?? 0
            let deltaCacheRead = lastUsage["cached_input_tokens"] as? Int
                ?? lastUsage["cache_read_input_tokens"] as? Int
                ?? 0
            accumulator.input += max(deltaInput - deltaCacheRead, 0)
            accumulator.output += lastUsage["output_tokens"] as? Int ?? 0
            accumulator.cacheRead += deltaCacheRead
            accumulator.foundCumulative = accumulator.foundCumulative || cumulative != nil
            accumulator.foundDelta = true
            accumulator.lastTokenEventSignature = signature
            return
        }

        guard !accumulator.foundDelta, let extracted = cumulative else {
            return
        }

        // Codex reports `input_tokens` inclusive of `cached_input_tokens`.
        // Subtract the cached portion so the non-cached input and cached
        // buckets stay disjoint (VAL-TOKEN-002).
        let nonCachedInput = max(extracted.input - extracted.cacheRead, 0)
        accumulator.input = nonCachedInput
        accumulator.output = extracted.output
        accumulator.cacheRead = extracted.cacheRead
        accumulator.foundCumulative = true
        accumulator.lastTokenEventSignature = duplicateGuardSignature(cumulative: extracted, delta: nil)
    }

    private static func duplicateGuardSignature(
        cumulative: (input: Int, output: Int, cacheRead: Int)?,
        delta: [String: Any]?
    ) -> String? {
        guard let cumulative else { return nil }
        let deltaInput = delta?["input_tokens"] as? Int ?? -1
        let deltaOutput = delta?["output_tokens"] as? Int ?? -1
        let deltaCacheRead = delta?["cached_input_tokens"] as? Int
            ?? delta?["cache_read_input_tokens"] as? Int
            ?? -1
        return [
            "codex-token-v1",
            "\(cumulative.input)",
            "\(cumulative.output)",
            "\(cumulative.cacheRead)",
            "\(deltaInput)",
            "\(deltaOutput)",
            "\(deltaCacheRead)"
        ].joined(separator: ":")
    }

    // MARK: - Conversation Scanning

    /// Full-file conversation extraction (message turns, tools, key files).
    ///
    /// Conversation bodies are privacy-sensitive and are never persisted to
    /// parser caches, so there is no incremental state here — callers bound
    /// the cost by only scanning files whose modification date crossed the
    /// indexing watermark.
    ///
    /// Returns `nil` when the file cannot be read or holds no message turns.
    /// Throws only `ParserResourceExceeded` (from the governor).
    public static func scanConversation(
        path: String,
        fallbackTitle: String,
        fileManager: FileManager = .default,
        governor: ParserResourceGovernor? = nil
    ) throws -> CodexConversationCacheEntry? {
        guard fileManager.fileExists(atPath: path),
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        var turns: [(role: String, text: String)] = []
        var keyFiles = Set<String>()
        var keyCommands = Set<String>()
        var keyTools = Set<String>()

        let reader = BufferedLineReader(fileHandle: handle)
        var scannedLines = 0
        while let line = reader.nextLine() {
            scannedLines += 1
            if scannedLines % checkpointLineInterval == 0 {
                try governor?.checkpoint()
            }
            autoreleasepool {
                guard let data = line.text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
                    return
                }
                if let extracted = Self.extractCodexMessage(from: json) {
                    turns.append(extracted)
                }
                if let tool = Self.extractCodexTool(from: json) {
                    keyTools.insert(tool.name)
                    if let detail = tool.detail {
                        if tool.name.lowercased().contains("bash") || tool.name.lowercased().contains("exec") {
                            keyCommands.insert(detail)
                        } else if detail.contains("/") || detail.contains(".swift") || detail.contains(".ts") || detail.contains(".kt") {
                            keyFiles.insert(detail)
                        }
                    }
                }
            }
        }

        guard !turns.isEmpty else { return nil }

        let markdown = turns.map { turn -> String in
            let header = turn.role == "assistant" ? "## Assistant" : "## You"
            return "\(header)\n\n\(turn.text)"
        }.joined(separator: "\n\n")
        let title = turns.first(where: { $0.role == "user" })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Codex session"
        let lastAssistant = turns.last(where: { $0.role == "assistant" })?.text ?? ""
        let userWords = turns
            .filter { $0.role == "user" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        let assistantWords = turns
            .filter { $0.role == "assistant" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }

        return CodexConversationCacheEntry(
            title: String(title.prefix(160)),
            markdown: markdown,
            messageCount: turns.count,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: Array(Array(keyFiles).sorted().prefix(12)),
            keyCommands: Array(Array(keyCommands).sorted().prefix(12)),
            keyTools: Array(Array(keyTools).sorted().prefix(12)),
            lastAssistantMessage: String(lastAssistant.prefix(500))
        )
    }

    public static func extractCodexMessage(from json: [String: Any]) -> (role: String, text: String)? {
        let item = (json["item"] as? [String: Any])
            ?? (json["payload"] as? [String: Any])?["item"] as? [String: Any]
            ?? (json["msg"] as? [String: Any])?["item"] as? [String: Any]
        guard let item,
              let role = item["role"] as? String,
              role == "user" || role == "assistant" else {
            return nil
        }
        let text = extractText(from: item["content"])
            ?? extractText(from: item["message"])
            ?? (item["text"] as? String)
        guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        return (role, cleaned)
    }

    public static func extractText(from raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let pieces = raw as? [[String: Any]] {
            let text = pieces.compactMap { piece -> String? in
                if let text = piece["text"] as? String { return text }
                if let text = piece["content"] as? String { return text }
                return nil
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    public static func extractCodexTool(from json: [String: Any]) -> (name: String, detail: String?)? {
        let item = (json["item"] as? [String: Any])
            ?? (json["payload"] as? [String: Any])?["item"] as? [String: Any]
            ?? (json["msg"] as? [String: Any])?["item"] as? [String: Any]
        guard let item else { return nil }
        let name = (item["name"] as? String)
            ?? (item["tool_name"] as? String)
            ?? (item["type"] as? String)
        guard let name, !name.isEmpty else { return nil }
        let detail = (item["command"] as? String)
            ?? (item["path"] as? String)
            ?? (item["file_path"] as? String)
            ?? (item["query"] as? String)
            ?? (item["pattern"] as? String)
        return (name, detail)
    }

    // MARK: - Shared Thread Processing

    /// Turns materialized `threads` rows into usage/conversation records —
    /// the single implementation behind both CodexParser copies. Owns cache
    /// load/persist; persists incremental progress even when the pass aborts
    /// mid-corpus (memory ceiling), so completed files keep their scan states
    /// and the next pass resumes instead of restarting.
    public static func processThreadRows(
        _ threadRows: [CodexThreadRow],
        options: LogParseOptions,
        fileManager: FileManager,
        cacheStore: ParserDiskCacheStore<CodexCacheEntry>
    ) throws -> (usages: [TokenUsage], conversations: [ConversationRecord]) {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var sessionCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        var tokenScanConsumedBytes: Int64 = 0
        let governor = options.resourceGovernor

        defer {
            if cacheMutated {
                cacheStore.persist(sessionCache)
            }
        }

        for row in threadRows {
            try governor?.checkpoint()

            // Try to get exact token breakdown from JSONL session file
            var inputTokens: Int = 0
            var outputTokens: Int = 0
            var cacheReadTokens: Int = 0
            var foundExact = false
            var parsedConversation: CodexConversationCacheEntry?
            var shouldEmitConversation = options.includeConversationBodies && row.expandedRolloutPath == nil

            if let expandedPath = row.expandedRolloutPath {
                let fileURL = URL(fileURLWithPath: expandedPath)
                let cacheKey = fileURL.standardizedFileURL.path
                activePaths.insert(cacheKey)

                // Signature captured BEFORE scanning: if a live writer grows
                // the file mid-scan, the next pass sees a size mismatch and
                // resumes from the persisted offset instead of trusting a
                // stale-complete entry.
                let signature = FileSignature(for: fileURL, using: fileManager)
                let cached = sessionCache.fileEntries[cacheKey]
                let isUnchanged = signature != nil && cached?.signature == signature

                let boundaryDeferred = isDeferredByBoundary(
                    signature: signature,
                    minimumFileModificationDate: options.minimumFileModificationDate
                )

                if isUnchanged {
                    if let tokenUsage = cached?.tokenUsage {
                        inputTokens = tokenUsage.input
                        outputTokens = tokenUsage.output
                        cacheReadTokens = tokenUsage.cacheRead
                        foundExact = true
                    }
                } else if boundaryDeferred {
                    // Changed file below the indexing boundary: reuse cached
                    // tokens without a content read; never emit a heuristic
                    // row over previously exact data.
                    if let tokenUsage = cached?.tokenUsage {
                        inputTokens = tokenUsage.input
                        outputTokens = tokenUsage.output
                        cacheReadTokens = tokenUsage.cacheRead
                        foundExact = true
                    } else {
                        // The state database still carries Codex's exact total
                        // for this thread. Fall through to the cache-aware
                        // split below so a cold cache remains complete; the
                        // confidence-aware usage upsert preserves any exact
                        // row already stored for this identity.
                    }
                } else {
                    let fileSize = signature?.sizeBytes ?? 0
                    let resumeOffset = cached?.scanState?.byteOffset ?? 0
                    let newBytes = max(fileSize - min(resumeOffset, fileSize), 0)

                    let isWithinPerFileScanLimit = newBytes <= maximumTokenScanBytesPerFile
                    let remainingTokenScanBytes = max(maximumTokenScanBytesPerPass - tokenScanConsumedBytes, 0)
                    let isWithinPassScanLimit = newBytes <= remainingTokenScanBytes
                    if isWithinPerFileScanLimit, isWithinPassScanLimit,
                       governor?.admitFile(estimatedBytes: newBytes) ?? true {
                        tokenScanConsumedBytes += newBytes
                        let scan = try scanTokens(
                            path: expandedPath,
                            fileManager: fileManager,
                            previousState: cached?.scanState,
                            governor: governor
                        )
                        if let usage = scan?.usage {
                            inputTokens = usage.input
                            outputTokens = usage.output
                            cacheReadTokens = usage.cacheRead
                            foundExact = true
                        }

                        if let signature, let scan {
                            sessionCache.fileEntries[cacheKey] = CodexCacheEntry(
                                signature: signature,
                                tokenUsage: scan.usage.map {
                                    CodexTokenUsage(input: $0.input, output: $0.output, cacheRead: $0.cacheRead)
                                },
                                scanState: scan.state
                            )
                            cacheMutated = true
                        } else if cached != nil {
                            sessionCache.fileEntries.removeValue(forKey: cacheKey)
                            cacheMutated = true
                        }
                    } else if let tokenUsage = cached?.tokenUsage {
                        if !isWithinPerFileScanLimit || !isWithinPassScanLimit {
                            governor?.recordDeferredFile()
                        }
                        // Byte budget exhausted: keep last known exact values
                        // this tick; the unchanged cache entry retries next.
                        inputTokens = tokenUsage.input
                        outputTokens = tokenUsage.output
                        cacheReadTokens = tokenUsage.cacheRead
                        foundExact = true
                    } else {
                        if !isWithinPerFileScanLimit || !isWithinPassScanLimit {
                            governor?.recordDeferredFile()
                        }
                        // Fall through to the state-database estimate below.
                    }
                }

                // Conversation bodies re-read the whole file (they are
                // privacy-transient — never disk-cached), so they get their
                // own budget admission. A denial counts as a deferral, which
                // freezes the caller's indexing watermark for this pass.
                if options.includeConversationBodies, !boundaryDeferred,
                   governor?.admitFile(estimatedBytes: signature?.sizeBytes ?? 0) ?? true {
                    parsedConversation = try scanConversation(
                        path: expandedPath,
                        fallbackTitle: row.rawTitle,
                        fileManager: fileManager,
                        governor: governor
                    )
                    shouldEmitConversation = parsedConversation != nil
                } else {
                    parsedConversation = nil
                    shouldEmitConversation = false
                }
            }

            // Codex updates `threads.tokens_used` independently from parser
            // cache persistence. Preserve exact buckets already scanned, then
            // estimate only the newer monotonic delta so an active or
            // oversized thread never reports a stale total.
            let materializedTotal = inputTokens + outputTokens + cacheReadTokens
            if foundExact, row.tokensUsed > materializedTotal {
                let delta = estimatedTokenBreakdown(totalTokens: row.tokensUsed - materializedTotal)
                inputTokens += delta.input
                outputTokens += delta.output
                cacheReadTokens += delta.cacheRead
                foundExact = false
            }

            if !foundExact, inputTokens == 0, outputTokens == 0, cacheReadTokens == 0 {
                let estimated = estimatedTokenBreakdown(totalTokens: row.tokensUsed)
                inputTokens = estimated.input
                outputTokens = estimated.output
                cacheReadTokens = estimated.cacheRead
            }

            if inputTokens > 0 || outputTokens > 0 {
                let pricing = ModelPricing.lookup(model: row.model)
                let cost = try pricing.cost(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens
                )

                let usage = TokenUsage(
                    provider: .codex,
                    sessionId: row.threadId,
                    projectName: row.projectName,
                    model: row.model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cacheReadTokens,
                    costUSD: cost,
                    startTime: row.startTime,
                    endTime: row.endTime,
                    provenanceMethod: foundExact ? .providerLog : .heuristicEstimate,
                    provenanceConfidence: foundExact ? .exact : .lowConfidenceEstimate,
                    estimatorVersion: foundExact ? "" : "tokens-used-cache-split-v2"
                )
                usages.append(usage)
            }

            if shouldEmitConversation {
                let inferredTitle = parsedConversation?.title
                    ?? row.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? row.threadId
                let fullText = parsedConversation?.markdown
                    ?? row.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let conversation = ConversationRecord(
                    id: ConversationRecord.stableId(provider: .codex, sessionId: row.threadId),
                    provider: .codex,
                    sessionId: row.threadId,
                    projectName: row.projectName,
                    startTime: row.startTime,
                    endTime: row.endTime,
                    messageCount: parsedConversation?.messageCount ?? (fullText.isEmpty ? 0 : 1),
                    userWordCount: parsedConversation?.userWordCount ?? row.rawTitle.split(separator: " ").count,
                    assistantWordCount: parsedConversation?.assistantWordCount ?? 0,
                    keyFiles: parsedConversation?.keyFiles ?? [],
                    keyCommands: parsedConversation?.keyCommands ?? [],
                    keyTools: parsedConversation?.keyTools ?? [],
                    inferredTaskTitle: inferredTitle,
                    lastAssistantMessage: parsedConversation?.lastAssistantMessage ?? "",
                    fullText: fullText,
                    indexedAt: Date(),
                    fileModifiedAt: row.expandedRolloutPath.flatMap { modificationDate(of: $0, fileManager: fileManager) },
                    summary: nil
                )
                conversations.append(conversation)
            }
        }

        let stalePaths = Set(sessionCache.fileEntries.keys).subtracting(activePaths)
        if !stalePaths.isEmpty {
            for stalePath in stalePaths {
                sessionCache.fileEntries.removeValue(forKey: stalePath)
            }
            cacheMutated = true
        }

        return (usages, conversations)
    }

    /// Codex's state database exposes an exact per-thread total but not its
    /// billing buckets. Modern Codex sessions are overwhelmingly cache reads;
    /// this conservative split keeps cold-cache totals complete without
    /// pricing every cached token as fresh input. Provider-log scans replace
    /// the estimate with exact buckets as the resource-governed cache warms.
    static func estimatedTokenBreakdown(totalTokens: Int) -> (input: Int, output: Int, cacheRead: Int) {
        let total = max(totalTokens, 0)
        let cacheRead = Int(Double(total) * 0.95)
        let output = Int(Double(total) * 0.005)
        let input = max(total - cacheRead - output, 0)
        return (input, output, cacheRead)
    }

    /// `LogParseOptions.minimumFileModificationDate` contract: files whose
    /// modification date is before the boundary are not content-read.
    /// Unstatable files count as deferred (no basis for reading them).
    static func isDeferredByBoundary(
        signature: FileSignature?,
        minimumFileModificationDate: Date?
    ) -> Bool {
        guard let minimumFileModificationDate else { return false }
        guard let signature else { return true }
        return Date(timeIntervalSince1970: signature.modifiedAt) < minimumFileModificationDate
    }

    private static func modificationDate(of path: String, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path)[.modificationDate]) as? Date // try?-ok(optional mtime)
    }

    // MARK: - Head Digest

    private static func matchesHeadDigest(_ state: CodexTokenScanState, handle: FileHandle) -> Bool {
        guard state.headDigestLength > 0 else { return state.byteOffset == 0 }
        return ParserScanDigest.headDigestHex(handle: handle, length: state.headDigestLength) == state.headDigest
    }

    private static func digestOfHead(handle: FileHandle, length: Int) -> String {
        ParserScanDigest.headDigestHex(handle: handle, length: length)
    }
}

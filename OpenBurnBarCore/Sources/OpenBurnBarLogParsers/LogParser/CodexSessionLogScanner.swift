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
//  * **Bounded**: every decoded line is wrapped in `parserAutoReleasePool`
//    (on Darwin the `JSONSerialization` object graphs are autoreleased, and
//    parse loops run inside dispatch blocks that never drain; on Linux/Windows
//    the closure runs inline), lines that cannot contain token events are
//    skipped before JSON decoding, and a shared
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

    public init(
        byteOffset: Int64,
        headDigest: String,
        headDigestLength: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        foundCumulative: Bool = false,
        foundDelta: Bool = false
    ) {
        self.byteOffset = byteOffset
        self.headDigest = headDigest
        self.headDigestLength = headDigestLength
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.foundCumulative = foundCumulative
        self.foundDelta = foundDelta
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

    public struct TokenScanResult {
        /// Exact token breakdown, or `nil` when the file contained no token
        /// events (callers fall back to their heuristic estimate).
        public let usage: (input: Int, output: Int, cacheRead: Int)?
        /// State to persist for the next incremental scan.
        public let state: CodexTokenScanState
    }

    private enum TokenScanAttempt {
        case scanned(TokenScanResult, contentReadBytes: Int64)
        case deferred(contentReadBytes: Int64)
        case unavailable(contentReadBytes: Int64)
    }

    // MARK: - Token Scanning

    /// Scans a rollout file for token counts, resuming from `previousState`
    /// when the file has only grown since that state was captured.
    ///
    /// Returns `nil` when the file does not exist, cannot be opened, or the
    /// governor defers the planned content read.
    /// Throws only `ParserResourceExceeded` (from governor checkpoints).
    ///
    /// Token semantics are byte-for-byte those of the original full-file
    /// loop (VAL-TOKEN-002 / VAL-TOKEN-010): cumulative totals overwrite and
    /// then suppress delta accumulation; delta events accumulate only until
    /// the first cumulative event.
    public static func scanTokens(
        path: String,
        fileManager: FileManager = .default,
        previousState: CodexTokenScanState?,
        governor: ParserResourceGovernor? = nil
    ) throws -> TokenScanResult? {
        try scanTokens(
            path: path,
            fileManager: fileManager,
            previousState: previousState,
            governor: governor,
            openFileForReading: { FileHandle(forReadingAtPath: $0) }
        )
    }

    static func scanTokens(
        path: String,
        fileManager: FileManager,
        previousState: CodexTokenScanState?,
        governor: ParserResourceGovernor?,
        openFileForReading: (String) -> FileHandle?
    ) throws -> TokenScanResult? {
        switch try scanTokenFile(
            path: path,
            fileManager: fileManager,
            previousState: previousState,
            governor: governor,
            openFileForReading: openFileForReading
        ) {
        case let .scanned(result, _):
            return result
        case .deferred, .unavailable:
            return nil
        }
    }

    private static func scanTokenFile(
        path: String,
        fileManager: FileManager,
        previousState: CodexTokenScanState?,
        governor: ParserResourceGovernor?,
        openFileForReading: (String) -> FileHandle?
    ) throws -> TokenScanAttempt {
        guard fileManager.fileExists(atPath: path),
              let rawFileSize = (try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              rawFileSize.int64Value >= 0 else {
            return .unavailable(contentReadBytes: 0)
        }

        let fileSize = rawFileSize.int64Value
        var contentReadBytes: Int64 = 0
        func admitAdditionalRead(_ bytes: Int64) -> Bool {
            guard bytes > 0 else { return true }
            guard governor?.admitFile(estimatedBytes: bytes) ?? true else { return false }
            contentReadBytes += bytes
            return true
        }

        let canProbePreviousHead: Bool
        if let previous = previousState {
            canProbePreviousHead = previous.byteOffset >= 0
                && previous.byteOffset <= fileSize
                && previous.headDigestLength > 0
                && previous.headDigestLength <= headDigestSpan
                && Int64(previous.headDigestLength) <= fileSize
        } else {
            canProbePreviousHead = false
        }

        let probeBytes = canProbePreviousHead ? Int64(previousState?.headDigestLength ?? 0) : 0
        let appendBytes = canProbePreviousHead
            ? max(fileSize - (previousState?.byteOffset ?? fileSize), 0)
            : 0
        // A cached scan must validate its old head before it can trust the
        // append offset. Admit that probe before opening the file; a matching
        // append tail is admitted separately immediately before it is read.
        // Cold scans admit their full known span up front.
        let initialReadBytes = canProbePreviousHead ? probeBytes : fileSize
        guard admitAdditionalRead(initialReadBytes) else {
            return .deferred(contentReadBytes: contentReadBytes)
        }
        guard let handle = openFileForReading(path) else {
            return .unavailable(contentReadBytes: contentReadBytes)
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        var accumulator: TokenAccumulator
        var resumeOffset: Int64
        let headDigest: String
        let headDigestLength: Int

        if let previous = previousState, canProbePreviousHead {
            let observedHeadDigest = digestOfHead(handle: handle, length: previous.headDigestLength)
            if observedHeadDigest == previous.headDigest,
               !admitAdditionalRead(appendBytes) {
                return .deferred(contentReadBytes: contentReadBytes)
            }
            if observedHeadDigest == previous.headDigest {
                accumulator = TokenAccumulator(
                    input: previous.inputTokens,
                    output: previous.outputTokens,
                    cacheRead: previous.cacheReadTokens,
                    foundCumulative: previous.foundCumulative,
                    foundDelta: previous.foundDelta
                )
                resumeOffset = previous.byteOffset
                headDigest = previous.headDigest
                headDigestLength = previous.headDigestLength

            } else {
                accumulator = TokenAccumulator()
                resumeOffset = 0
                headDigestLength = Int(min(Int64(headDigestSpan), fileSize))

                // A mismatched head restarts from byte zero. The head probe
                // was already charged for this attempt; admit the unread
                // remainder so the rewrite totals one full file.
                let additionalBytes = max(fileSize - probeBytes, 0)
                guard admitAdditionalRead(additionalBytes) else {
                    return .deferred(contentReadBytes: contentReadBytes)
                }
                headDigest = previous.headDigestLength == headDigestLength
                    ? observedHeadDigest
                    : digestOfHead(handle: handle, length: headDigestLength)
            }
        } else {
            // Cold scans, truncations, and legacy empty-head states all read
            // from byte zero. Their full known span was admitted before the
            // handle was opened, so the digest cannot bypass the byte budget.
            accumulator = TokenAccumulator()
            resumeOffset = 0
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
                parserAutoReleasePool {
                    Self.reduceTokenLine(line.text, into: &accumulator)
                }
                persistedOffset = line.endOffset
            } else {
                // Unterminated trailing line: count it toward the returned
                // totals but never toward persisted state — a live writer may
                // still be appending it, and the next scan must re-read it.
                var tail = accumulator
                parserAutoReleasePool {
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
            foundDelta: accumulator.foundDelta
        )
        let usage: (input: Int, output: Int, cacheRead: Int)? =
            (effective.foundCumulative || effective.foundDelta)
            ? (effective.input, effective.output, effective.cacheRead)
            : nil
        return .scanned(TokenScanResult(usage: usage, state: state), contentReadBytes: contentReadBytes)
    }

    struct TokenAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var foundCumulative = false
        var foundDelta = false
    }

    /// One line of the VAL-TOKEN-002 / VAL-TOKEN-010 state machine, verbatim
    /// from the original parsers.
    static func reduceTokenLine(_ text: String, into accumulator: inout TokenAccumulator) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(per-line decode, skip)
            return
        }
        guard let info = TokenExtractionUtility.codexTokenCountInfo(from: json) else {
            return
        }

        // VAL-TOKEN-010: cumulative totals take precedence over delta events.
        if let extracted = TokenExtractionUtility.codexCumulativeTotalsFromTokenCountInfo(info) {
            // Codex reports `input_tokens` inclusive of `cached_input_tokens`.
            // Subtract the cached portion so the non-cached input and cached
            // buckets stay disjoint (VAL-TOKEN-002).
            let nonCachedInput = max(extracted.input - extracted.cacheRead, 0)
            accumulator.input = nonCachedInput
            accumulator.output = extracted.output
            accumulator.cacheRead = extracted.cacheRead
            accumulator.foundDelta = false
            accumulator.foundCumulative = true
            return
        }

        // VAL-TOKEN-002: only accumulate delta events until cumulative totals
        // appear; this prevents additive double-counting.
        if !accumulator.foundCumulative,
           let lastUsage = info["last_token_usage"] as? [String: Any] {
            let deltaInput = lastUsage["input_tokens"] as? Int ?? 0
            let deltaCacheRead = lastUsage["cached_input_tokens"] as? Int
                ?? lastUsage["cache_read_input_tokens"] as? Int
                ?? 0
            accumulator.input += max(deltaInput - deltaCacheRead, 0)
            accumulator.output += lastUsage["output_tokens"] as? Int ?? 0
            accumulator.cacheRead += deltaCacheRead
            accumulator.foundDelta = true
        }
    }

    private enum ConversationScanAttempt {
        case scanned(CodexConversationCacheEntry?)
        case unavailable
    }

    // MARK: - Conversation Scanning

    /// Full-file conversation extraction (message turns, tools, key files).
    ///
    /// Conversation bodies are privacy-sensitive and are never persisted to
    /// parser caches, so there is no incremental state here — callers bound
    /// the cost by only scanning files whose modification date crossed the
    /// indexing watermark.
    ///
    /// Distinguishes an unreadable file from a successful scan with no message
    /// turns so token-only rollouts can still advance the discovery manifest.
    private static func scanConversation(
        path: String,
        fallbackTitle: String,
        fileManager: FileManager,
        governor: ParserResourceGovernor?,
        openFileForReading: (String) -> FileHandle?
    ) throws -> ConversationScanAttempt {
        guard fileManager.fileExists(atPath: path),
              let handle = openFileForReading(path) else {
            return .unavailable
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
            parserAutoReleasePool {
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

        guard !turns.isEmpty else { return .scanned(nil) }

        let markdown = turns.map { turn in
            turn.role == "user"
                ? "## User\n\n\(turn.text)"
                : "## Assistant\n\n\(turn.text)"
        }.joined(separator: "\n\n")

        let firstUser = turns.first(where: { $0.role == "user" })?.text ?? fallbackTitle
        let title = firstUser
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? fallbackTitle
        let lastAssistant = turns.last(where: { $0.role == "assistant" })?.text ?? ""
        let userWordCount = turns
            .filter { $0.role == "user" }
            .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let assistantWordCount = turns
            .filter { $0.role == "assistant" }
            .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let sortedKeyFiles = Array(Array(keyFiles).sorted().prefix(12))
        let sortedKeyCommands = Array(Array(keyCommands).sorted().prefix(12))
        let sortedKeyTools = Array(Array(keyTools).sorted().prefix(12))
        let conversation = CodexConversationCacheEntry(
            title: String(title.prefix(160)),
            markdown: markdown,
            messageCount: turns.count,
            userWordCount: userWordCount,
            assistantWordCount: assistantWordCount,
            keyFiles: sortedKeyFiles,
            keyCommands: sortedKeyCommands,
            keyTools: sortedKeyTools,
            lastAssistantMessage: String(lastAssistant.prefix(500))
        )
        return .scanned(conversation)
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
        try processThreadRows(
            threadRows,
            options: options,
            fileManager: fileManager,
            cacheStore: cacheStore,
            openFileForReading: { FileHandle(forReadingAtPath: $0) }
        )
    }

    static func processThreadRows(
        _ threadRows: [CodexThreadRow],
        options: LogParseOptions,
        fileManager: FileManager,
        cacheStore: ParserDiskCacheStore<CodexCacheEntry>,
        openFileForReading: (String) -> FileHandle?
    ) throws -> (usages: [TokenUsage], conversations: [ConversationRecord]) {
        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var sessionCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        let governor = options.resourceGovernor

        defer {
            if cacheMutated {
                cacheStore.persist(sessionCache)
            }
        }

        for row in threadRows {
            try governor?.checkpoint()

            var inputTokens = 0
            var outputTokens = 0
            var cacheReadTokens = 0
            var foundExact = false
            var deferredWithoutCache = false
            var contentUnavailable = false

            var parsedConversation: CodexConversationCacheEntry?
            var shouldEmitConversation = options.includeConversationBodies && row.expandedRolloutPath == nil

            if let expandedPath = row.expandedRolloutPath {
                let fileURL = URL(fileURLWithPath: expandedPath)
                let cacheKey = fileURL.standardizedFileURL.path
                activePaths.insert(cacheKey)
                options.metrics?.recordCandidate()
                options.metrics?.recordMetadataStat()

                let signature = FileSignature(for: fileURL, using: fileManager)
                let discoveredFile = ParserDiscoveredFile.capture(
                    for: fileURL,
                    attributes: try? fileManager.attributesOfItem(atPath: fileURL.path)
                )
                let isNewlyDiscovered = options.fileDiscoveryTracker?.record(discoveredFile) ?? false
                let cached = sessionCache.fileEntries[cacheKey]

                if governor != nil, signature == nil {
                    governor?.recordDeferredFile()
                    options.metrics?.recordDeferred(.metadataUnavailable)
                    deferredWithoutCache = cached?.tokenUsage == nil
                    if let tokenUsage = cached?.tokenUsage {
                        inputTokens = tokenUsage.input
                        outputTokens = tokenUsage.output
                        cacheReadTokens = tokenUsage.cacheRead
                        foundExact = true
                    }
                } else {
                    let isUnchanged = !isNewlyDiscovered
                        && signature != nil
                        && cached?.signature == signature
                    let boundaryDeferred = !isNewlyDiscovered && isDeferredByBoundary(
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
                        if let tokenUsage = cached?.tokenUsage {
                            inputTokens = tokenUsage.input
                            outputTokens = tokenUsage.output
                            cacheReadTokens = tokenUsage.cacheRead
                            foundExact = true
                        } else {
                            deferredWithoutCache = true
                        }
                    } else {
                        switch try scanTokenFile(
                            path: expandedPath,
                            fileManager: fileManager,
                            previousState: cached?.scanState,
                            governor: governor,
                            openFileForReading: openFileForReading
                        ) {
                        case let .scanned(scan, contentReadBytes):
                            options.fileDiscoveryTracker?.recordAdmitted(discoveredFile)
                            options.metrics?.recordContentRead(bytes: contentReadBytes)

                            if let usage = scan.usage {
                                inputTokens = usage.input
                                outputTokens = usage.output
                                cacheReadTokens = usage.cacheRead
                                foundExact = true
                            }

                            if let signature {
                                sessionCache.fileEntries[cacheKey] = CodexCacheEntry(
                                    signature: signature,
                                    tokenUsage: scan.usage.map {
                                        CodexTokenUsage(input: $0.input, output: $0.output, cacheRead: $0.cacheRead)
                                    },
                                    scanState: scan.state
                                )
                                cacheMutated = true
                            }

                        case let .deferred(contentReadBytes):
                            if contentReadBytes > 0 {
                                options.metrics?.recordContentRead(bytes: contentReadBytes)
                            }
                            options.fileDiscoveryTracker?.recordDeferred(discoveredFile)
                            options.metrics?.recordDeferred(.byteBudget)
                            if let tokenUsage = cached?.tokenUsage {
                                inputTokens = tokenUsage.input
                                outputTokens = tokenUsage.output
                                cacheReadTokens = tokenUsage.cacheRead
                                foundExact = true
                            } else {
                                deferredWithoutCache = true
                            }

                        case let .unavailable(contentReadBytes):
                            if contentReadBytes > 0 {
                                options.metrics?.recordContentRead(bytes: contentReadBytes)
                            }
                            governor?.recordDeferredFile()
                            options.fileDiscoveryTracker?.recordDeferred(discoveredFile)
                            options.metrics?.recordDeferred(.contentReadFailed)
                            deferredWithoutCache = cached?.tokenUsage == nil
                            contentUnavailable = true
                            if let tokenUsage = cached?.tokenUsage {
                                inputTokens = tokenUsage.input
                                outputTokens = tokenUsage.output
                                cacheReadTokens = tokenUsage.cacheRead
                                foundExact = true
                            }
                        }
                    }

                    if options.includeConversationBodies,
                       !boundaryDeferred,
                       (!isUnchanged || options.fileDiscoveryTracker == nil),
                       !contentUnavailable {
                        let conversationBytes = signature?.sizeBytes ?? 0
                        if governor?.admitFile(estimatedBytes: conversationBytes) ?? true {
                            options.metrics?.recordContentRead(bytes: conversationBytes)
                            do {
                                switch try scanConversation(
                                    path: expandedPath,
                                    fallbackTitle: row.rawTitle,
                                    fileManager: fileManager,
                                    governor: governor,
                                    openFileForReading: openFileForReading
                                ) {
                                case let .scanned(conversation):
                                    parsedConversation = conversation
                                    shouldEmitConversation = conversation != nil
                                case .unavailable:
                                    governor?.recordDeferredFile()
                                    options.metrics?.recordDeferred(.contentReadFailed)
                                    options.fileDiscoveryTracker?.recordDeferred(discoveredFile)
                                    parsedConversation = nil
                                    shouldEmitConversation = false
                                }
                            } catch {
                                options.fileDiscoveryTracker?.recordDeferred(discoveredFile)
                                throw error
                            }
                        } else {
                            options.metrics?.recordDeferred(.byteBudget)
                            options.fileDiscoveryTracker?.recordDeferred(discoveredFile)
                            parsedConversation = nil
                            shouldEmitConversation = false
                        }
                    } else {
                        parsedConversation = nil
                        shouldEmitConversation = false
                    }
                }
            }

            if deferredWithoutCache { continue }

            if !foundExact {
                inputTokens = Int(Double(row.tokensUsed) * 0.95)
                outputTokens = max(row.tokensUsed - inputTokens, 0)
            }

            if inputTokens > 0 || outputTokens > 0 {
                let pricing = ModelPricing.lookup(model: row.model)
                let cost = try pricing.cost(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens
                )

                usages.append(TokenUsage(
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
                    estimatorVersion: foundExact ? "" : "tokens-used-split-v1"
                ))
            }

            if shouldEmitConversation {
                let inferredTitle = parsedConversation?.title
                    ?? row.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? row.threadId
                let fullText = parsedConversation?.markdown
                    ?? row.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                conversations.append(ConversationRecord(
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
                ))
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

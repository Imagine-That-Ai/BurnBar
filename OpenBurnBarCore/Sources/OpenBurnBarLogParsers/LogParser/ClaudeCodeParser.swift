import Foundation
import OpenBurnBarKernel

// MARK: - Claude Code Parser

/// Parses Claude Code-compatible transcripts (including OpenClaude) into token
/// usage and, optionally, conversation records.
///
/// Resource behavior (2026-07-16 incident fix — this corpus was 4.2GB/3804
/// files on the incident machine, with live transcripts growing for hours):
///  * files at or above `incrementalScanThresholdBytes` carry a
///    `ClaudeTokenScanState` in the parser cache, so a grown append-only
///    transcript costs only its new tail on the next usage tick;
///  * usage-only passes skip conversation accumulation entirely (previously
///    the full conversation text was built and thrown away every tick) and
///    pre-filter lines by the quoted `"usage"` key before JSON decoding;
///  * every decoded line runs inside `parserAutoReleasePool` — on Darwin the
///    `JSONSerialization` graphs are autoreleased and parse loops run inside
///    dispatch blocks that never drain; on Linux/Windows the closure runs
///    inline (no autorelease pool to drain);
///  * `LogParseOptions.resourceGovernor` bounds bytes read per pass and
///    aborts on the process memory ceiling;
///  * conversation bodies are never written to the on-disk parser cache
///    (privacy-transient, PR #1808) — the cache stores usage + scan state.
public final class ClaudeCodeParser: LogParser, Sendable {
    public let provider: AgentProvider
    private let fileManager: FileManager
    private let appPaths: OpenBurnBarAppPaths
    private let cacheURL: URL
    private let cacheStore: ParserDiskCacheStore<ClaudeCodeCacheEntry>
    private let projectsDirectoryOverride: URL?
    private let openFileForReading: @Sendable (URL) -> FileHandle?

    /// Files at or above this size keep incremental scan state in the cache;
    /// smaller files re-parse fully (cheap) without carrying state.
    static let incrementalScanThresholdBytes: Int64 = 8 * 1024 * 1024
    /// Governor memory checkpoints happen every this many scanned lines.
    static let checkpointLineInterval = 4096
    /// How many bytes of file head the rewrite-detection digest covers.
    static let headDigestSpan = 4096

    public convenience init(
        fileManager: FileManager = .default,
        appPaths: OpenBurnBarAppPaths = .live(),
        projectsDirectoryOverride: URL? = nil, provider: AgentProvider = .claudeCode
    ) {
        self.init(
            fileManager: fileManager,
            appPaths: appPaths,
            projectsDirectoryOverride: projectsDirectoryOverride,
            provider: provider,
            openFileForReading: { try? FileHandle(forReadingFrom: $0) }
        )
    }

    init(
        fileManager: FileManager,
        appPaths: OpenBurnBarAppPaths,
        projectsDirectoryOverride: URL?, provider: AgentProvider = .claudeCode,
        openFileForReading: @escaping @Sendable (URL) -> FileHandle?
    ) {
        self.provider = provider
        self.fileManager = fileManager
        self.appPaths = appPaths
        self.projectsDirectoryOverride = projectsDirectoryOverride
        self.openFileForReading = openFileForReading
        self.cacheURL = provider == .claudeCode ? appPaths.claudeCodeParserCacheURL : appPaths.supportDirectory.appendingPathComponent("\(provider.persistedToken)_parser_cache.json")
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 3,
            logLabel: "ClaudeCodeParser"
        )
        _ = try? OpenBurnBarMigration.prepareSupportDirectory(fileManager: fileManager, paths: appPaths) // try?-ok(best-effort dir prep)
    }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        try parseSynchronously(options: options)
    }

    public func parseSynchronously(options: LogParseOptions) throws -> ParseResult {
        let projectsURL = projectsDirectoryOverride
            ?? URL(fileURLWithPath: (provider.logDirectory as NSString).expandingTildeInPath)
        let projectsPath = projectsURL.path

        guard fileManager.fileExists(atPath: projectsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false

        // Persist incremental progress even when the pass aborts mid-corpus
        // (memory ceiling): completed files keep their scan states and the
        // next pass resumes instead of restarting.
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        // try?-ok(dir read returns empty)
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return ParseResult(usages: [], conversations: [])
        }

        let filteredDirs = projectDirs.filter { $0.hasDirectoryPath }

        for projectDir in filteredDirs {
            let projectName = decodeProjectName(projectDir.lastPathComponent)

            guard let files = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else { // try?-ok(dir read skip)
                continue
            }

            let jsonlFiles = files.filter { $0.pathExtension == "jsonl" }

            for jsonlFile in jsonlFiles {
                let sessionId = jsonlFile.deletingPathExtension().lastPathComponent
                try processSessionFile(
                    file: jsonlFile,
                    sessionId: sessionId,
                    projectName: projectName,
                    includeConversation: options.includeConversationBodies,
                    options: options,
                    parseCache: &parseCache,
                    activePaths: &activePaths,
                    cacheMutated: &cacheMutated,
                    usages: &usages,
                    conversations: &conversations
                )

                // Parse subagent sessions in {sessionId}/subagents/agent-*.jsonl
                let subagentsDir = projectDir
                    .appendingPathComponent(sessionId)
                    .appendingPathComponent("subagents")
                if let subagentFiles = try? fileManager.contentsOfDirectory( // try?-ok(optional dir skip)
                    at: subagentsDir,
                    includingPropertiesForKeys: nil
                ) {
                    let agentJsonlFiles = subagentFiles.filter {
                        $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-")
                    }
                    for agentFile in agentJsonlFiles {
                        let agentId = agentFile.deletingPathExtension().lastPathComponent
                        try processSessionFile(
                            file: agentFile,
                            sessionId: "\(sessionId)/\(agentId)",
                            projectName: projectName,
                            includeConversation: false,
                            options: options,
                            parseCache: &parseCache,
                            activePaths: &activePaths,
                            cacheMutated: &cacheMutated,
                            usages: &usages,
                            conversations: &conversations
                        )
                    }
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

    // MARK: - Per-File Processing

    /// Cache/defer/budget gatekeeping for one transcript file, shared by main
    /// sessions and subagent sessions.
    private func processSessionFile(
        file: URL,
        sessionId: String,
        projectName: String,
        includeConversation: Bool,
        options: LogParseOptions,
        parseCache: inout ParserDiskCache<ClaudeCodeCacheEntry>,
        activePaths: inout Set<String>,
        cacheMutated: inout Bool,
        usages: inout [TokenUsage],
        conversations: inout [ConversationRecord]
    ) throws {
        let cacheKey = cachePath(for: file)
        activePaths.insert(cacheKey)
        options.metrics?.recordCandidate()
        options.metrics?.recordMetadataStat()

        // Signature captured BEFORE scanning: if a live writer grows the file
        // mid-scan, the next pass sees a size mismatch and resumes from the
        // persisted offset instead of trusting a stale-complete entry.
        let signature = FileSignature(for: file, using: fileManager)
        let discoveredFile = ParserDiscoveredFile.capture(
            for: file,
            attributes: try? fileManager.attributesOfItem(atPath: file.path)
        )
        let isNewlyDiscovered = options.fileDiscoveryTracker?.record(discoveredFile) ?? false
        let cached = parseCache.fileEntries[cacheKey]
        let governor = options.resourceGovernor

        try governor?.checkpoint()

        if options.minimumFileModificationDate != nil, signature == nil {
            governor?.recordDeferredFile()
            options.metrics?.recordDeferred(.metadataUnavailable)
            if let usage = cached?.usage { usages.append(usage) }
            return
        }

        // Historical files below the indexing boundary are never content-read;
        // cached usage rows still surface.
        if !isNewlyDiscovered,
           shouldDeferHistoricalFile(
               signature: signature,
               minimumFileModificationDate: options.minimumFileModificationDate
           ) {
            if let signature, let cached, cached.signature == signature,
               let usage = cached.usage {
                usages.append(usage)
            }
            return
        }

        let isUnchanged = !isNewlyDiscovered && signature != nil && cached?.signature == signature
        if isUnchanged, !includeConversation || options.fileDiscoveryTracker != nil {
            if let usage = cached?.usage { usages.append(usage) }
            return
        }

        let fileSize = signature?.sizeBytes ?? 0
        let resumableState = (!includeConversation && fileSize >= Self.incrementalScanThresholdBytes)
            ? cached?.scanState
            : nil
        let estimatedNewBytes: Int64 = includeConversation
            ? fileSize
            : max(fileSize - min(resumableState?.byteOffset ?? 0, fileSize), 0)

        guard governor?.admitFile(estimatedBytes: estimatedNewBytes) ?? true else {
            options.metrics?.recordDeferred(.byteBudget)
            if let usage = cached?.usage { usages.append(usage) }
            return
        }
        options.fileDiscoveryTracker?.recordAdmitted(discoveredFile)
        options.metrics?.recordContentRead(bytes: estimatedNewBytes)

        guard let outcome = try scanClaudeSession(
            file: file,
            sessionId: sessionId,
            projectName: projectName,
            includeConversation: includeConversation,
            previousState: resumableState,
            governor: governor
        ) else {
            governor?.recordDeferredFile()
            options.fileDiscoveryTracker?.recordDeferred(discoveredFile)
            options.metrics?.recordDeferred(.contentReadFailed)
            if let usage = cached?.usage { usages.append(usage) }
            return
        }

        if let usage = outcome.usage { usages.append(usage) }
        if includeConversation, let conversation = outcome.conversation {
            conversations.append(conversation)
        }

        if let signature {
            let persistedState = fileSize >= Self.incrementalScanThresholdBytes ? outcome.scanState : nil
            parseCache.fileEntries[cacheKey] = ClaudeCodeCacheEntry(
                signature: signature,
                usage: outcome.usage,
                scanState: persistedState
            )
            cacheMutated = true
        } else if cached != nil {
            parseCache.fileEntries.removeValue(forKey: cacheKey)
            cacheMutated = true
        }
    }

    // MARK: - Session Scanning

    private struct SessionScanOutcome {
        let usage: TokenUsage?
        let conversation: ConversationRecord?
        let scanState: ClaudeTokenScanState
    }

    /// Accumulated token reduction over transcript lines. The reduction is a
    /// deterministic function of (state, line), which is what makes saved
    /// state resumable across passes.
    struct ClaudeTokenAccumulator {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var models: Set<String> = []
        var startTime: Date?
        var endTime: Date?
        var seenUsageKeyHashes: Set<UInt64> = []

        init() {}

        init(from state: ClaudeTokenScanState) {
            inputTokens = state.inputTokens
            outputTokens = state.outputTokens
            cacheCreationTokens = state.cacheCreationTokens
            cacheReadTokens = state.cacheReadTokens
            models = Set(state.models)
            startTime = state.startTime
            endTime = state.endTime
            seenUsageKeyHashes = Set(state.seenUsageKeyHashes.map { UInt64(bitPattern: $0) })
        }
    }

    private func scanClaudeSession(
        file: URL,
        sessionId: String,
        projectName: String,
        includeConversation: Bool,
        previousState: ClaudeTokenScanState?,
        governor: ParserResourceGovernor?
    ) throws -> SessionScanOutcome? {
        guard let handle = openFileForReading(file) else {
            return nil
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        let mtime = modificationDate(of: file)
        let fileSize = ((try? fileManager.attributesOfItem(atPath: file.path))?[.size] as? Int64) ?? 0

        var accumulator: ClaudeTokenAccumulator
        var resumeOffset: Int64 = 0
        let headDigest: String
        let headDigestLength: Int

        if let previous = previousState,
           !includeConversation,
           previous.byteOffset <= fileSize,
           previous.headDigestLength > 0,
           ParserScanDigest.headDigestHex(handle: handle, length: previous.headDigestLength) == previous.headDigest {
            accumulator = ClaudeTokenAccumulator(from: previous)
            resumeOffset = previous.byteOffset
            headDigest = previous.headDigest
            headDigestLength = previous.headDigestLength
        } else {
            accumulator = ClaudeTokenAccumulator()
            headDigestLength = Int(min(Int64(Self.headDigestSpan), fileSize))
            headDigest = ParserScanDigest.headDigestHex(handle: handle, length: headDigestLength)
        }

        try? handle.seek(toOffset: UInt64(resumeOffset)) // try?-ok(seek failure degrades to offset-0 read)
        let reader = BufferedLineReader(fileHandle: handle, startOffset: resumeOffset)
        let conversationAccumulator = includeConversation ? ClaudeConversationAccumulator() : nil

        var persistedOffset = resumeOffset
        var scannedLines = 0
        var tailAccumulator: ClaudeTokenAccumulator?

        while let line = reader.nextLine() {
            scannedLines += 1
            if scannedLines % Self.checkpointLineInterval == 0 {
                try governor?.checkpoint()
            }

            // Usage-only prefilter: a line can only contribute tokens if it
            // carries a quoted "usage" key; skip JSON decoding otherwise.
            // Bodies passes need every line (conversation accumulation).
            if conversationAccumulator == nil, !line.text.contains("\"usage\"") {
                if line.isTerminated { persistedOffset = line.endOffset }
                continue
            }

            if line.isTerminated {
                parserAutoReleasePool {
                    Self.reduceLine(line.text, tokenAccumulator: &accumulator, conversation: conversationAccumulator)
                }
                persistedOffset = line.endOffset
            } else {
                // Unterminated trailing line (mid-append by a live writer):
                // counted toward returned totals, never toward persisted
                // state — the next scan re-reads it once complete.
                var tail = accumulator
                parserAutoReleasePool {
                    Self.reduceLine(line.text, tokenAccumulator: &tail, conversation: conversationAccumulator)
                }
                tailAccumulator = tail
            }
        }

        let effective = tailAccumulator ?? accumulator
        let scanState = ClaudeTokenScanState(
            byteOffset: persistedOffset,
            headDigest: headDigest,
            headDigestLength: headDigestLength,
            inputTokens: accumulator.inputTokens,
            outputTokens: accumulator.outputTokens,
            cacheCreationTokens: accumulator.cacheCreationTokens,
            cacheReadTokens: accumulator.cacheReadTokens,
            models: accumulator.models.sorted(),
            startTime: accumulator.startTime,
            endTime: accumulator.endTime,
            seenUsageKeyHashes: accumulator.seenUsageKeyHashes.map { Int64(bitPattern: $0) }.sorted()
        )

        conversationAccumulator?.finalizeArrays()

        guard effective.inputTokens > 0
            || effective.outputTokens > 0
            || effective.cacheCreationTokens > 0
            || effective.cacheReadTokens > 0 else {
            return SessionScanOutcome(usage: nil, conversation: nil, scanState: scanState)
        }

        let model = effective.models.first ?? "claude"
        let pricing = ModelPricing.lookup(model: model)
        let totalCost = try pricing.cost(
            inputTokens: effective.inputTokens,
            outputTokens: effective.outputTokens,
            cacheCreationTokens: effective.cacheCreationTokens,
            cacheReadTokens: effective.cacheReadTokens
        )

        let usageStartTime = effective.startTime ?? conversationAccumulator?.startTime ?? mtime ?? Date()
        let usageEndTime = effective.endTime ?? conversationAccumulator?.endTime ?? mtime ?? usageStartTime

        let usage = TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: effective.inputTokens,
            outputTokens: effective.outputTokens,
            cacheCreationTokens: effective.cacheCreationTokens,
            cacheReadTokens: effective.cacheReadTokens,
            costUSD: totalCost,
            startTime: usageStartTime,
            endTime: usageEndTime,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact
        )

        var conversation: ConversationRecord?
        if let conv = conversationAccumulator {
            conversation = ConversationRecord(
                id: ConversationRecord.stableId(provider: provider, sessionId: sessionId),
                provider: provider,
                sessionId: sessionId,
                projectName: projectName,
                startTime: conv.startTime ?? usage.startTime,
                endTime: conv.endTime ?? usage.endTime,
                messageCount: conv.messageCount,
                userWordCount: conv.userWordCount,
                assistantWordCount: conv.assistantWordCount,
                keyFiles: conv.keyFiles,
                keyCommands: conv.keyCommands,
                keyTools: conv.keyTools,
                inferredTaskTitle: conv.firstUserText ?? projectName,
                lastAssistantMessage: conv.lastAssistantText,
                fullText: conv.fullText,
                indexedAt: Date(),
                workingDirectory: projectName.hasPrefix("~/") || projectName.hasPrefix("/") ? projectName : nil,
                fileModifiedAt: mtime,
                summary: nil
            )
        }

        return SessionScanOutcome(usage: usage, conversation: conversation, scanState: scanState)
    }

    /// One line of the token reduction, verbatim from the original loop.
    static func reduceLine(
        _ text: String,
        tokenAccumulator accumulator: inout ClaudeTokenAccumulator,
        conversation: ClaudeConversationAccumulator?
    ) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { // try?-ok(malformed line skip)
            return
        }

        conversation?.ingest(jsonLine: json)

        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let usage = message["usage"] as? [String: Any] else {
            return
        }

        if let usageKey = claudeUsageIdentity(json: json, message: message) {
            let keyHash = ParserScanDigest.fnv1a64(usageKey)
            guard accumulator.seenUsageKeyHashes.insert(keyHash).inserted else { return }
        }

        if let date = Self.parseTimestamp(json["timestamp"]) {
            if accumulator.startTime == nil { accumulator.startTime = date }
            accumulator.endTime = date
        }

        let extracted = TokenExtractionUtility.extractUsageTokens(
            usage,
            inputHint: accumulator.inputTokens,
            outputHint: accumulator.outputTokens
        )
        accumulator.inputTokens += extracted.input
        accumulator.outputTokens += extracted.output
        accumulator.cacheCreationTokens += extracted.cacheCreation
        accumulator.cacheReadTokens += extracted.cacheRead

        if let model = message["model"] as? String {
            accumulator.models.insert(model)
        }
    }

    public func decodeProjectName(_ encoded: String) -> String {
        var decoded = ClaudeCodeProjectPathCodec.decode(encoded)
        if decoded.isAmbiguous {
            decoded = ClaudeCodeProjectPathCodec.decode(encoded, style: .windows)
        }
        let path = decoded.displayPath

        if decoded.style == .posix, path.hasPrefix("/Users/") {
            let components = path.split(separator: "/")
            if components.count >= 2 {
                let rest = components.dropFirst(2).joined(separator: "/")
                return rest.isEmpty ? "~" : "~/" + rest
            }
        }

        if decoded.style == .windows {
            let components = path.split(separator: "\\")
            if components.count >= 3,
               components[0].hasSuffix(":"),
               components[1].lowercased() == "users" {
                let rest = components.dropFirst(3).joined(separator: "\\")
                return rest.isEmpty ? "~" : "~\\" + rest
            }
        }

        return path
    }

    private static func claudeUsageIdentity(json: [String: Any], message: [String: Any]) -> String? {
        guard let messageID = message["id"] as? String,
              let requestID = json["requestId"] as? String,
              !messageID.isEmpty,
              !requestID.isEmpty else {
            return nil
        }
        return "\(messageID):\(requestID)"
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date // try?-ok(optional mtime fallback)
    }

    private func cachePath(for file: URL) -> String {
        file.standardizedFileURL.path
    }

    private func shouldDeferHistoricalFile(
        signature: FileSignature?,
        minimumFileModificationDate: Date?
    ) -> Bool {
        guard let minimumFileModificationDate else { return false }
        guard let signature else { return true }
        return Date(timeIntervalSince1970: signature.modifiedAt) < minimumFileModificationDate
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        if let string = raw as? String {
            return ThreadSafeISO8601DateFormatter.parse(string)
        }

        let epoch: Double?
        if let number = raw as? NSNumber {
            epoch = number.doubleValue
        } else if let value = raw as? Double {
            epoch = value
        } else if let value = raw as? Int {
            epoch = Double(value)
        } else if let value = raw as? Int64 {
            epoch = Double(value)
        } else {
            epoch = nil
        }

        guard let epoch else { return nil }
        let seconds = epoch > 100_000_000_000 ? epoch / 1000.0 : epoch
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Persistable per-file scan state for incremental usage extraction from
/// append-only Claude Code transcripts. `byteOffset` always points just past
/// the last *terminated* line consumed. `seenUsageKeyHashes` stores FNV-1a 64
/// bit patterns of `messageID:requestID` dedupe keys (as `Int64` for property
/// list encoding); it exists only for files above the incremental threshold,
/// bounding cache growth.
public struct ClaudeTokenScanState: Codable, Equatable, Sendable {
    public var byteOffset: Int64
    public var headDigest: String
    public var headDigestLength: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var models: [String]
    public var startTime: Date?
    public var endTime: Date?
    public var seenUsageKeyHashes: [Int64]

    public init(
        byteOffset: Int64,
        headDigest: String,
        headDigestLength: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        models: [String],
        startTime: Date?,
        endTime: Date?,
        seenUsageKeyHashes: [Int64]
    ) {
        self.byteOffset = byteOffset
        self.headDigest = headDigest
        self.headDigestLength = headDigestLength
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.models = models
        self.startTime = startTime
        self.endTime = endTime
        self.seenUsageKeyHashes = seenUsageKeyHashes
    }
}

/// v3 (schemaVersion 3): carries the incremental `scanState` and, by
/// construction, can no longer hold conversation bodies — parser caches are
/// privacy-transient for conversation text (PR #1808).
struct ClaudeCodeCacheEntry: Codable, Equatable {
    let signature: FileSignature
    let usage: TokenUsage?
    let scanState: ClaudeTokenScanState?
}

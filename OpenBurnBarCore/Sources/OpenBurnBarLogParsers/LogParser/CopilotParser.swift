import Foundation
import OpenBurnBarKernel

/// Parses Copilot CLI sessions from `~/.copilot/session-state` and the legacy
/// CompactionProcessor fallback in `~/.copilot/logs`.
///
/// Idle usage ticks resume unchanged session directories from a mtime+size disk
/// cache (token totals only — never conversation bodies). The process-log
/// fallback token integers participate in the signature.
public final class CopilotParser: LogParser, Sendable {
    public let provider: AgentProvider = .copilot

    private let fileManager: FileManager
    private let sessionStateURL: URL
    private let logsURL: URL
    private let cacheStore: ParserDiskCacheStore<CachedUsageEntry<CopilotCacheSignature>>
    private let sessionScanCount = Locked(0)
    private let sessionCacheHitCount = Locked(0)

    /// Session-directory file set plus the process-log fallback used when JSONL
    /// rows omit token counts. The fallback integers are part of the key so a
    /// later process-log parse that fills in tokens cannot reuse a zeroed cache
    /// row.
    private struct CopilotCacheSignature: Codable, Equatable, Sendable {
        var files: FileSetSignature
        var fallbackInput: Int
        var fallbackOutput: Int
    }

    public init(
        fileManager: FileManager = .default,
        sessionStateURL: URL? = nil,
        logsURL: URL? = nil,
        appPaths: OpenBurnBarAppPaths = .live()
    ) {
        self.fileManager = fileManager
        self.sessionStateURL = sessionStateURL
            ?? URL(fileURLWithPath: NSString(string: "~/.copilot/session-state").expandingTildeInPath)
        self.logsURL = logsURL
            ?? URL(fileURLWithPath: NSString(string: "~/.copilot/logs").expandingTildeInPath)
        let cacheURL: URL
        if sessionStateURL != nil {
            cacheURL = self.sessionStateURL.appendingPathComponent(".obb-copilot-parser-cache.plist")
        } else {
            cacheURL = appPaths.copilotParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "CopilotParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        guard fileManager.fileExists(atPath: sessionStateURL.path) else {
            return ParseResult(usages: [], conversations: [])
        }

        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        let fallbackBySession = try parseProcessLogs(gate: gate)
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: sessionStateURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.path < $1.path }

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

        for directory in sessionDirectories {
            let eventFiles = try eventFiles(in: directory)
            guard !eventFiles.isEmpty else { continue }

            let metadataURL = directory.appendingPathComponent("metadata.json")
            var readableFiles = eventFiles
            if fileManager.fileExists(atPath: metadataURL.path) {
                readableFiles.append(metadataURL)
            }
            let cacheKey = directory.standardizedFileURL.path
            activePaths.insert(cacheKey)
            guard try gate.shouldRead(readableFiles) else { continue }

            let files = FileSetSignature(urls: readableFiles, using: fileManager)
            let fallback = fallbackBySession[directory.lastPathComponent]
            let signature = files.map {
                CopilotCacheSignature(
                    files: $0,
                    fallbackInput: fallback?.input ?? 0,
                    fallbackOutput: fallback?.output ?? 0
                )
            }
            if !options.includeConversationBodies,
               let signature,
               let cached = parseCache.fileEntries[cacheKey],
               cached.signature == signature {
                sessionCacheHitCount.withLock { $0 += 1 }
                usages.append(cached.totals.makeUsage(provider: .copilot, sessionId: directory.lastPathComponent))
                continue
            }

            sessionScanCount.withLock { $0 += 1 }
            let metadata = readableFiles.contains(metadataURL) ? parseMetadata(metadataURL) : nil
            if let parsed = parseSession(
                eventFiles: eventFiles,
                sessionID: directory.lastPathComponent,
                metadata: metadata,
                fallback: fallbackBySession[directory.lastPathComponent],
                includeConversationBody: options.includeConversationBodies
            ) {
                usages.append(parsed.usage)
                if let conversation = parsed.conversation {
                    conversations.append(conversation)
                }
                if let signature {
                    parseCache.fileEntries[cacheKey] = CachedUsageEntry(signature: signature, usage: parsed.usage)
                    cacheMutated = true
                }
            } else {
                options.metrics?.recordDeferred(.contentReadFailed)
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

    private func eventFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            let name = url.lastPathComponent
            return name == "events.jsonl"
                || name.hasPrefix("events.jsonl.")
                || (name.hasPrefix("events-") && name.hasSuffix(".jsonl"))
        }
        .sorted(by: fileOrder)
    }

    private func fileOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.lastPathComponent < rhs.lastPathComponent
    }

    private struct Metadata {
        let model: String?
        let input: Int
        let output: Int
        let cacheRead: Int
    }

    private func parseMetadata(_ url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let usage = object["usage"] as? [String: Any] ?? object["tokenUsage"] as? [String: Any]
        guard let usage else { return nil }
        let tokens = TokenExtractionUtility.extractUsageTokens(usage)
        guard tokens.input > 0 || tokens.output > 0 else { return nil }
        return Metadata(
            model: object["model"] as? String,
            input: tokens.input,
            output: tokens.output,
            cacheRead: tokens.cacheRead
        )
    }

    private struct SessionAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var foundExact = false
        var foundTurnUsage = false
        var shutdownInput = 0
        var shutdownOutput = 0
        var shutdownCacheRead = 0
        var foundShutdownUsage = false
        var userCharacters = 0
        var assistantCharacters = 0
        var start: Date?
        var end: Date?
        var model = "copilot"
        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0
    }

    private func parseSession(
        eventFiles: [URL],
        sessionID: String,
        metadata: Metadata?,
        fallback: (input: Int, output: Int)?,
        includeConversationBody: Bool
    ) -> (usage: TokenUsage, conversation: ConversationRecord?)? {
        var state = SessionAccumulator()
        state.model = metadata?.model ?? "copilot"
        var seenEventIDs = Set<String>()
        var linesFromOlderSegments = Set<String>()
        var newestModificationDate: Date?

        for file in eventFiles {
            let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            if let modifiedAt {
                newestModificationDate = newestModificationDate.map { max($0, modifiedAt) } ?? modifiedAt
            }
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            var linesInThisSegment = Set<String>()
            for line in handle.readAllUTF8Lines() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let eventID = object["id"] as? String, !eventID.isEmpty {
                    guard seenEventIDs.insert(eventID).inserted else { continue }
                } else if linesFromOlderSegments.contains(line) {
                    // Rotation copies can overlap byte-for-byte. Without a
                    // stable event id, suppress overlap only across segments;
                    // identical id-less turns inside one file remain distinct.
                    continue
                }
                guard accumulate(object, includeConversationBody: includeConversationBody, into: &state) else {
                    try? handle.close()
                    return nil
                }
                linesInThisSegment.insert(line)
            }
            try? handle.close()
            linesFromOlderSegments.formUnion(linesInThisSegment)
        }

        let input: Int
        let output: Int
        let cacheRead: Int
        let exact: Bool
        if state.foundTurnUsage {
            (input, output, cacheRead, exact) = (state.input, state.output, state.cacheRead, true)
        } else if state.foundShutdownUsage {
            (input, output, cacheRead, exact) = (
                state.shutdownInput,
                state.shutdownOutput,
                state.shutdownCacheRead,
                true
            )
        } else if state.foundExact {
            (input, output, cacheRead, exact) = (state.input, state.output, state.cacheRead, true)
        } else if let metadata {
            (input, output, cacheRead, exact) = (metadata.input, metadata.output, metadata.cacheRead, true)
        } else if let fallback {
            (input, output, cacheRead, exact) = (fallback.input, fallback.output, 0, true)
        } else {
            input = TokenExtractionUtility.estimatedTokenCount(for: state.userCharacters, charsPerToken: 3.5)
            output = TokenExtractionUtility.estimatedTokenCount(for: state.assistantCharacters, charsPerToken: 3.5)
            cacheRead = 0
            exact = false
        }
        guard input > 0 || output > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: state.model)
        guard let cost = try? pricing.cost(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead
        ) else { return nil }
        let fallbackDate = newestModificationDate ?? Date(timeIntervalSince1970: 0)
        let usage = TokenUsage(
            provider: .copilot,
            sessionId: sessionID,
            projectName: "Copilot",
            model: state.model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            costUSD: cost,
            startTime: state.start ?? fallbackDate,
            endTime: state.end ?? fallbackDate,
            provenanceMethod: exact ? .providerLog : .heuristicEstimate,
            provenanceConfidence: exact ? .exact : .lowConfidenceEstimate,
            estimatorVersion: exact ? "" : TokenExtractionUtility.currentEstimatorVersion
        )

        guard includeConversationBody else { return (usage, nil) }
        return (
            usage,
            ConversationRecord(
                id: ConversationRecord.stableId(provider: .copilot, sessionId: sessionID),
                provider: .copilot,
                sessionId: sessionID,
                projectName: "Copilot",
                startTime: state.start ?? fallbackDate,
                endTime: state.end ?? fallbackDate,
                messageCount: state.messageCount,
                userWordCount: state.userWords,
                assistantWordCount: state.assistantWords,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: state.firstUser ?? "Copilot Session",
                lastAssistantMessage: state.lastAssistant,
                fullText: state.fullText,
                indexedAt: fallbackDate,
                fileModifiedAt: newestModificationDate,
                summary: nil
            )
        )
    }

    private func accumulate(
        _ object: [String: Any],
        includeConversationBody: Bool,
        into state: inout SessionAccumulator
    ) -> Bool {
        let eventType = object["type"] as? String ?? object["event"] as? String ?? ""
        let eventData = object["data"] as? [String: Any]
        let role = object["role"] as? String ?? eventData?["role"] as? String ?? ""
        if let timestamp = parseTimestamp(object["timestamp"]) {
            state.start = state.start.map { min($0, timestamp) } ?? timestamp
            state.end = state.end.map { max($0, timestamp) } ?? timestamp
        }
        if let model = object["model"] as? String ?? eventData?["model"] as? String,
           !model.isEmpty {
            state.model = model
        }

        let explicitUsage = object["usage"] as? [String: Any]
            ?? object["token_usage"] as? [String: Any]
            ?? eventData?["usage"] as? [String: Any]
            ?? eventData
        if let explicitUsage {
            let tokens = TokenExtractionUtility.extractUsageTokens(explicitUsage)
            if tokens.input > 0 || tokens.output > 0 || tokens.cacheRead > 0 {
                if eventType == "session.shutdown" {
                    // Shutdown persistence is a session summary. Use it only
                    // when no per-turn assistant.usage events are present.
                    state.shutdownInput = tokens.input
                    state.shutdownOutput = tokens.output
                    state.shutdownCacheRead = tokens.cacheRead
                    state.foundShutdownUsage = true
                } else {
                    guard checkedAdd(tokens.input, to: &state.input),
                          checkedAdd(tokens.output, to: &state.output),
                          checkedAdd(tokens.cacheRead, to: &state.cacheRead)
                    else { return false }
                    state.foundExact = true
                    if eventType == "assistant.usage" { state.foundTurnUsage = true }
                }
            }
        }

        let content = object["content"] as? String
            ?? object["text"] as? String
            ?? eventData?["content"] as? String
            ?? eventData?["text"] as? String
            ?? ""
        if role == "user" || eventType == "user_message" {
            guard checkedAdd(content.count, to: &state.userCharacters) else { return false }
            if includeConversationBody, !content.isEmpty {
                guard checkedAdd(wordCount(content), to: &state.userWords),
                      checkedAdd(1, to: &state.messageCount)
                else { return false }
                state.firstUser = state.firstUser
                    ?? String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                appendText(&state.fullText, content, isAssistant: false)
            }
        } else if role == "assistant" || eventType == "assistant_message" {
            guard checkedAdd(content.count, to: &state.assistantCharacters) else { return false }
            if includeConversationBody, !content.isEmpty {
                guard checkedAdd(wordCount(content), to: &state.assistantWords),
                      checkedAdd(1, to: &state.messageCount)
                else { return false }
                state.lastAssistant = content
                appendText(&state.fullText, content, isAssistant: true)
            }
        }
        return true
    }

    private func parseTimestamp(_ value: Any?) -> Date? {
        if let string = value as? String { return ThreadSafeISO8601DateFormatter.parse(string) }
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        return nil
    }

    private func checkedAdd(_ value: Int, to total: inout Int) -> Bool {
        guard value >= 0 else { return false }
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { return false }
        total = result.partialValue
        return true
    }

    private func parseProcessLogs(gate: ParserFileReadGate) throws -> [String: (input: Int, output: Int)] {
        guard fileManager.fileExists(atPath: logsURL.path) else { return [:] }
        let files = try fileManager.contentsOfDirectory(
            at: logsURL,
            includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix("process-")
                && $0.lastPathComponent.hasSuffix(".log")
                && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
        }
        .sorted(by: fileOrder)

        var checkpoints: [String: [Int]] = [:]
        var seenLines = Set<String>()
        for file in files {
            guard try gate.shouldRead(file), let data = fileManager.contents(atPath: file.path),
                  let content = String(data: data, encoding: .utf8)
            else { continue }
            for line in content.split(whereSeparator: \.isNewline).map(String.init)
                where seenLines.insert(line).inserted {
                guard line.contains("CompactionProcessor") || line.contains("context_tokens") else { continue }
                var sessionID: String?
                var tokens: Int?
                for part in line.split(whereSeparator: \.isWhitespace) {
                    if part.hasPrefix("session=") { sessionID = String(part.dropFirst(8)) }
                    if part.hasPrefix("context_tokens=") { tokens = Int(part.dropFirst(15)) }
                }
                if let sessionID, let tokens, tokens >= 0 { checkpoints[sessionID, default: []].append(tokens) }
            }
        }

        return checkpoints.reduce(into: [:]) { result, pair in
            guard let last = pair.value.last else { return }
            let previous = pair.value.dropLast().last ?? 0
            let output = max(last - previous, last / 20)
            result[pair.key] = (input: max(last - output, 0), output: output)
        }
    }

    private func appendText(_ fullText: inout String, _ content: String, isAssistant: Bool) {
        if !fullText.isEmpty { fullText += "\n\n" }
        fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(
            isAssistant: isAssistant,
            body: content
        )
    }

    private func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: { $0.isWhitespace }).count
    }
}

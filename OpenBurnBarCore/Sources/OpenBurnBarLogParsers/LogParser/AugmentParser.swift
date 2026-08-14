import Foundation
import OpenBurnBarKernel

// MARK: - Augment Parser

/// Best-effort Augment parser. Discovers likely VS Code-family storage roots, but
/// remains conservative until a real token-bearing sample is available.
public final class AugmentParser: LogParser, Sendable {
    public let provider: AgentProvider = .augment
    private let logDirectoryOverride: String?
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
            cacheURL = URL(fileURLWithPath: override).appendingPathComponent(".obb-augment-parser-cache.plist")
        } else {
            cacheURL = appPaths.augmentParserCacheURL
        }
        self.cacheStore = ParserDiskCacheStore(
            cacheURL: cacheURL,
            fileManager: fileManager,
            schemaVersion: 1,
            logLabel: "AugmentParser"
        )
    }

    var lastSessionScanCount: Int { sessionScanCount.read() }
    var lastSessionCacheHitCount: Int { sessionCacheHitCount.read() }

    public func parse() async throws -> ParseResult {
        try await parse(options: .default)
    }

    public func parse(options: LogParseOptions) async throws -> ParseResult {
        sessionScanCount.write(0)
        sessionCacheHitCount.write(0)
        let gate = ParserFileReadGate(options: options, fileManager: fileManager)
        let roots = candidateRoots().filter { fileManager.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else {
            return ParseResult(usages: [], conversations: [])
        }

        var usagesBySessionId: [String: TokenUsage] = [:]
        var conversationsBySessionId: [String: ConversationRecord] = [:]
        var parseCache = cacheStore.load()
        var activePaths = Set<String>()
        var cacheMutated = false
        defer {
            if cacheMutated {
                cacheStore.persist(parseCache)
            }
        }

        for root in roots {
            for file in recursiveJSONFiles(in: root) {
                let cacheKey = file.standardizedFileURL.path
                activePaths.insert(cacheKey)
                guard try gate.shouldRead(file) else { continue }
                let sessionId = sessionIdentifier(for: file, root: root)
                let signature = FileSignature(for: file, using: fileManager)
                if !options.includeConversationBodies,
                   let signature,
                   let cached = parseCache.fileEntries[cacheKey],
                   cached.signature == signature {
                    sessionCacheHitCount.withLock { $0 += 1 }
                    for session in cached.sessions {
                        usagesBySessionId[session.sessionId] = session.makeUsage(provider: .augment)
                    }
                    continue
                }
                sessionScanCount.withLock { $0 += 1 }
                let pair = try (file.pathExtension == "jsonl"
                    ? parseJSONL(file: file, sessionId: sessionId, includeConversationBodies: options.includeConversationBodies)
                    : parseJSON(file: file, sessionId: sessionId, includeConversationBodies: options.includeConversationBodies))

                if let usage = pair?.usage {
                    usagesBySessionId[usage.sessionId] = usage
                    if let signature {
                        parseCache.fileEntries[cacheKey] = CachedUsageBundleEntry(
                            signature: signature,
                            usages: [usage]
                        )
                        cacheMutated = true
                    }
                }
                if options.includeConversationBodies, let conversation = pair?.conversation {
                    conversationsBySessionId[conversation.sessionId] = conversation
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

        return ParseResult(
            usages: Array(usagesBySessionId.values),
            conversations: Array(conversationsBySessionId.values)
        )
    }

    private func candidateRoots() -> [URL] {
        if let override = logDirectoryOverride {
            return [URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)]
        }
        let candidates = [
            provider.logDirectory,
            "~/Library/Application Support/Code/User/globalStorage/augment.vscode-augment",
            "~/Library/Application Support/Cursor/User/globalStorage/augment.vscode-augment",
            "~/Library/Application Support/Windsurf/User/globalStorage/augment.vscode-augment"
        ]

        var seen: Set<String> = []
        return candidates.compactMap {
            let expanded = ($0 as NSString).expandingTildeInPath
            guard seen.insert(expanded).inserted else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
    }

    private func recursiveJSONFiles(in root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let file as URL in enumerator {
            let isRegularFile = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true // try?-ok(skip on metadata read failure)
            guard isRegularFile else { continue }
            guard ["json", "jsonl"].contains(file.pathExtension.lowercased()) else { continue }
            result.append(file)
        }
        return result
    }

    private func sessionIdentifier(for file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.deletingPathExtension().path
        guard filePath.hasPrefix(rootPath) else {
            return file.deletingPathExtension().lastPathComponent
        }
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? file.deletingPathExtension().lastPathComponent : relative
    }

    private func parseJSONL(
        file: URL,
        sessionId: String,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil } // try?-ok(log open guard-return-nil)
        defer { try? handle.close() } // try?-ok(handle teardown)

        var summary = AugmentSummary()
        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { // try?-ok(skip malformed log line)
                continue
            }
            summary.consume(json, includeConversationBodies: includeConversationBodies)
        }

        return try buildPair(
            sessionId: sessionId,
            summary: summary,
            file: file,
            includeConversationBodies: includeConversationBodies
        )
    }

    private func parseJSON(
        file: URL,
        sessionId: String,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let data = try? Data(contentsOf: file), // try?-ok(log read guard-return-nil)
              let json = try? JSONSerialization.jsonObject(with: data) else { // try?-ok(malformed JSON guard-return-nil)
            return nil
        }

        var summary = AugmentSummary()
        switch json {
        case let array as [Any]:
            for element in array {
                summary.consume(element, includeConversationBodies: includeConversationBodies)
            }
        default:
            summary.consume(json, includeConversationBodies: includeConversationBodies)
        }

        return try buildPair(
            sessionId: sessionId,
            summary: summary,
            file: file,
            includeConversationBodies: includeConversationBodies
        )
    }

    private func buildPair(
        sessionId: String,
        summary: AugmentSummary,
        file: URL,
        includeConversationBodies: Bool
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard summary.hasUsage || summary.hasConversation else { return nil }

        let model = TokenExtractionUtility.normalizeModelName(summary.model ?? "augment")
        let modifiedAt = modificationDate(of: file) ?? Date()

        let usage: TokenUsage?
        if summary.hasUsage {
            let pricing = ModelPricing.lookup(model: model)
            let cost = try pricing.cost(
                inputTokens: summary.inputTokens,
                outputTokens: summary.outputTokens,
                cacheCreationTokens: summary.cacheCreationTokens,
                cacheReadTokens: summary.cacheReadTokens
            )
            usage = TokenUsage(
                provider: .augment,
                sessionId: sessionId,
                projectName: sessionId,
                model: model,
                inputTokens: summary.inputTokens,
                outputTokens: summary.outputTokens,
                cacheCreationTokens: summary.cacheCreationTokens,
                cacheReadTokens: summary.cacheReadTokens,
                costUSD: cost,
                startTime: summary.startTime ?? modifiedAt,
                endTime: summary.endTime ?? modifiedAt,
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact
            )
        } else {
            usage = nil
        }

        let conversation: ConversationRecord? = includeConversationBodies && summary.hasConversation ? ConversationRecord(
            id: ConversationRecord.stableId(provider: .augment, sessionId: sessionId),
            provider: .augment,
            sessionId: sessionId,
            projectName: sessionId,
            startTime: summary.startTime ?? modifiedAt,
            endTime: summary.endTime ?? modifiedAt,
            messageCount: summary.messageCount,
            userWordCount: summary.userWords,
            assistantWordCount: summary.assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: summary.firstUser ?? sessionId,
            lastAssistantMessage: summary.lastAssistant,
            fullText: summary.fullText,
            indexedAt: Date(),
            fileModifiedAt: modificationDate(of: file),
            summary: nil
        ) : nil

        return (usage, conversation)
    }

    private func modificationDate(of file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date // try?-ok(mtime read with fallback)
    }
}

private struct AugmentSummary {
    var model: String?
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationTokens = 0
    var cacheReadTokens = 0
    var startTime: Date?
    var endTime: Date?
    var messageCount = 0
    var userWords = 0
    var assistantWords = 0
    var firstUser: String?
    var lastAssistant = ""
    var fullText = ""

    var hasUsage: Bool {
        inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0
    }

    var hasConversation: Bool {
        !fullText.isEmpty || messageCount > 0
    }

    mutating func consume(_ raw: Any, includeConversationBodies: Bool) {
        guard let json = raw as? [String: Any] else { return }
        let message = json["message"] as? [String: Any]

        if let model = (message?["model"] as? String) ?? (json["model"] as? String), !model.isEmpty {
            self.model = model
        }

        if let usage = (message?["usage"] as? [String: Any]) ?? (json["usage"] as? [String: Any]) {
            let extracted = TokenExtractionUtility.extractUsageTokens(usage)
            inputTokens += extracted.input
            outputTokens += extracted.output
            cacheCreationTokens += extracted.cacheCreation
            cacheReadTokens += extracted.cacheRead
        }

        let timestamp = dateValue(json["timestamp"]) ?? dateValue(message?["timestamp"])
        if let timestamp {
            if startTime == nil { startTime = timestamp }
            endTime = timestamp
        }

        guard includeConversationBodies else { return }

        let role = ((message?["role"] as? String) ?? (json["role"] as? String) ?? "").lowercased()
        let content = stringValue(message?["content"] ?? json["content"])
        guard !content.isEmpty else { return }

        switch role {
        case "user":
            userWords += content.split { $0.isWhitespace || $0.isNewline }.count
            if firstUser == nil {
                firstUser = String(content.prefix(120))
            }
            append(content, isAssistant: false)
            messageCount += 1
        case "assistant":
            assistantWords += content.split { $0.isWhitespace || $0.isNewline }.count
            lastAssistant = content
            append(content, isAssistant: true)
            messageCount += 1
        default:
            break
        }
    }

    private mutating func append(_ content: String, isAssistant: Bool) {
        if !fullText.isEmpty { fullText += "\n\n" }
        fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: content)
    }

    private func stringValue(_ raw: Any?) -> String {
        switch raw {
        case let value as String:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case let array as [Any]:
            return array.compactMap { element in
                if let element = element as? String {
                    return element.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }.joined(separator: "\n")
        default:
            return ""
        }
    }

    private func dateValue(_ raw: Any?) -> Date? {
        switch raw {
        case let value as Double:
            return TimestampNormalizationUtility.date(fromEpoch: value)
        case let value as Int:
            return TimestampNormalizationUtility.date(fromEpoch: Double(value))
        case let value as Int64:
            return TimestampNormalizationUtility.date(fromEpoch: Double(value))
        case let value as String:
            return ThreadSafeISO8601DateFormatter.parse(value)
        default:
            return nil
        }
    }
}

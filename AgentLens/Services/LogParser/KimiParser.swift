import Foundation

// MARK: - Kimi Parser

/// KimiParser extracts token usage from Kimi (Moonshot) CLI sessions.
/// Prefers exact token counts from wire.jsonl (available since v0.66, Dec 2025).
/// Falls back to character-based estimation from context.jsonl for older sessions.
final class KimiParser: LogParser, Sendable {
    let provider: AgentProvider = .kimi
    let logDirectoryOverride: String?

    init(logDirectoryOverride: String? = nil) {
        self.logDirectoryOverride = logDirectoryOverride
    }

    func parse() async throws -> ParseResult {
        let fileManager = FileManager.default
        let sessionsPath = logDirectoryOverride ?? NSString(string: provider.logDirectory).expandingTildeInPath
        let sessionsURL = URL(fileURLWithPath: sessionsPath)

        guard fileManager.fileExists(atPath: sessionsPath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let workspaceDirs = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for workspaceDir in workspaceDirs {
            let workspaceId = workspaceDir.lastPathComponent

            let sessionDirs = try fileManager.contentsOfDirectory(at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

            for sessionDir in sessionDirs {
                let sessionId = sessionDir.lastPathComponent
                let contextFile = sessionDir.appendingPathComponent("context.jsonl")
                let wireFile = sessionDir.appendingPathComponent("wire.jsonl")

                guard fileManager.fileExists(atPath: contextFile.path) else { continue }

                if let pair = try parseSession(
                    sessionId: sessionId,
                    contextFile: contextFile,
                    wireFile: fileManager.fileExists(atPath: wireFile.path) ? wireFile : nil,
                    projectName: workspaceId
                ), let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation {
                        conversations.append(conv)
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseSession(
        sessionId: String,
        contextFile: URL,
        wireFile: URL?,
        projectName: String
    ) throws -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: contextFile.path)[.modificationDate]) as? Date

        // Try wire.jsonl first for exact token counts
        var wireTokens: WireTokenData?
        if let wireFile {
            wireTokens = parseWireFile(wireFile)
        }

        // Always parse context.jsonl for conversation data and fallback estimation
        guard let handle = try? FileHandle(forReadingFrom: contextFile) else {
            return nil
        }
        defer { try? handle.close() }

        var assistantChars = 0
        var userChars = 0
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var model = "kimi-for-coding"

        var fullText = ""
        var firstUser: String?
        var lastAssistant = ""
        var userWords = 0
        var assistantWords = 0
        var messageCount = 0
        var allContent = ""

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let role = json["role"] as? String ?? ""
            let content = json["content"] as? String ?? ""
            let charCount = content.count

            switch role {
            case "assistant":
                assistantChars += charCount
                if !content.isEmpty {
                    let w = wordCount(content)
                    assistantWords += w
                    lastAssistant = content
                    appendText(&fullText, content)
                    allContent += content
                    messageCount += 1
                }
            case "user":
                userChars += charCount
                if !content.isEmpty {
                    userWords += wordCount(content)
                    if firstUser == nil {
                        firstUser = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                    }
                    appendText(&fullText, content)
                    allContent += content
                    messageCount += 1
                }
            default:
                break
            }

            if let ts = json["created_at"] as? String ?? json["timestamp"] as? String {
                let date = ISO8601DateFormatter().date(from: ts)
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            }
        }

        // Determine token counts — prefer wire.jsonl exact data
        // VAL-TOKEN-005: Kimi uses wire.jsonl whenever any exact bucket is present,
        // including cache-only cases (cacheRead or cacheCreation without inputOther/output)
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int

        if let wt = wireTokens, (wt.inputOther > 0 || wt.output > 0 || wt.inputCacheRead > 0 || wt.inputCacheCreation > 0) {
            inputTokens = wt.inputOther
            outputTokens = wt.output
            cacheCreationTokens = wt.inputCacheCreation
            cacheReadTokens = wt.inputCacheRead
            if let m = wt.model, !m.isEmpty { model = m }
        } else {
            // Fallback: estimate from character counts with CJK awareness
            let ratio = TokenExtractionUtility.charsPerToken(for: allContent, defaultRatio: 3.5)
            inputTokens = TokenExtractionUtility.estimatedTokenCount(for: userChars, charsPerToken: ratio)
            outputTokens = TokenExtractionUtility.estimatedTokenCount(for: assistantChars, charsPerToken: ratio)
            cacheCreationTokens = 0
            cacheReadTokens = 0
        }

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
            provider: .kimi,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: cost,
            startTime: firstTimestamp ?? Date(),
            endTime: lastTimestamp ?? Date(),
            provenanceMethod: wireTokens != nil ? .providerLog : .heuristicEstimate,
            provenanceConfidence: wireTokens != nil ? .exact : .lowConfidenceEstimate,
            estimatorVersion: wireTokens != nil ? "" : TokenExtractionUtility.currentEstimatorVersion
        )

        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .kimi, sessionId: sessionId),
            provider: .kimi,
            sessionId: sessionId,
            projectName: projectName,
            startTime: firstTimestamp ?? usage.startTime,
            endTime: lastTimestamp ?? usage.endTime,
            messageCount: messageCount,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: firstUser ?? projectName,
            lastAssistantMessage: lastAssistant,
            fullText: fullText,
            indexedAt: Date(),
            fileModifiedAt: mtime,
            summary: nil
        )

        return (usage, conversation)
    }

    // MARK: - Wire Protocol Parsing

    /// Parse wire.jsonl for exact token counts from StatusUpdate messages.
    private func parseWireFile(_ file: URL) -> WireTokenData? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var result = WireTokenData()

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard let message = json["message"] as? [String: Any],
                  message["type"] as? String == "StatusUpdate",
                  let payload = message["payload"] as? [String: Any],
                  let tokenUsage = payload["token_usage"] as? [String: Any] else {
                continue
            }

            // Sum per-turn token counts
            result.inputOther += tokenUsage["input_other"] as? Int ?? 0
            result.output += tokenUsage["output"] as? Int ?? 0
            result.inputCacheRead += tokenUsage["input_cache_read"] as? Int ?? 0
            result.inputCacheCreation += tokenUsage["input_cache_creation"] as? Int ?? 0

            if result.model == nil,
               let model = Self.validWireModel(from: tokenUsage, payload: payload) {
                result.model = model
            }
        }

        return (result.inputOther > 0 || result.output > 0) ? result : nil
    }

    private static func validWireModel(
        from tokenUsage: [String: Any],
        payload: [String: Any]
    ) -> String? {
        let candidates = [
            tokenUsage["model"],
            tokenUsage["model_id"],
            tokenUsage["modelId"],
            tokenUsage["model_name"],
            tokenUsage["modelName"],
            payload["model"],
            payload["model_id"],
            payload["modelId"],
            payload["model_name"],
            payload["modelName"],
        ]

        for candidate in candidates {
            guard let raw = candidate as? String else { continue }
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, !isRequestIDLikeModel(model) else { continue }
            return model
        }
        return nil
    }

    private static func isRequestIDLikeModel(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("chatcmpl-")
            || normalized.hasPrefix("cmpl-")
            || normalized.hasPrefix("resp_")
            || normalized.hasPrefix("response-")
            || normalized.hasPrefix("msg_")
    }

    private func appendText(_ full: inout String, _ chunk: String) {
        if !full.isEmpty { full += "\n\n" }
        full += chunk
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
    }
}

private struct WireTokenData {
    var inputOther: Int = 0
    var output: Int = 0
    var inputCacheRead: Int = 0
    var inputCacheCreation: Int = 0
    var model: String?
}

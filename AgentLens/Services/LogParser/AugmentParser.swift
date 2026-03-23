import Foundation

// MARK: - Augment Parser

/// Scaffold parser for Augment Code VS Code extension.
/// Checks globalStorage directory and attempts best-effort JSON parsing.
/// Returns empty if the format is unrecognizable.
final class AugmentParser: LogParser {
    let provider: AgentProvider = .augment

    func parse() async throws -> ParseResult {
        let fm = FileManager.default
        let basePath = (provider.logDirectory as NSString).expandingTildeInPath

        guard fm.fileExists(atPath: basePath) else {
            return ParseResult(usages: [], conversations: [])
        }

        var usages: [TokenUsage] = []
        var conversations: [ConversationRecord] = []

        let baseURL = URL(fileURLWithPath: basePath)
        let contents = (try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []

        // Attempt to parse any JSON/JSONL files found
        let jsonFiles = contents.filter { ["json", "jsonl"].contains($0.pathExtension) }

        for file in jsonFiles {
            let sessionId = file.deletingPathExtension().lastPathComponent

            if file.pathExtension == "jsonl" {
                if let pair = parseJsonlFile(file: file, sessionId: sessionId),
                   let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation { conversations.append(conv) }
                }
            } else {
                if let pair = parseJsonFile(file: file, sessionId: sessionId),
                   let usage = pair.usage {
                    usages.append(usage)
                    if let conv = pair.conversation { conversations.append(conv) }
                }
            }
        }

        // Also check subdirectories for session data
        let dirs = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for dir in dirs {
            let dirName = dir.lastPathComponent
            let subFiles = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in subFiles where ["json", "jsonl"].contains(file.pathExtension) {
                let sessionId = "\(dirName)/\(file.deletingPathExtension().lastPathComponent)"
                if file.pathExtension == "jsonl" {
                    if let pair = parseJsonlFile(file: file, sessionId: sessionId),
                       let usage = pair.usage {
                        usages.append(usage)
                        if let conv = pair.conversation { conversations.append(conv) }
                    }
                } else {
                    if let pair = parseJsonFile(file: file, sessionId: sessionId),
                       let usage = pair.usage {
                        usages.append(usage)
                        if let conv = pair.conversation { conversations.append(conv) }
                    }
                }
            }
        }

        return ParseResult(usages: usages, conversations: conversations)
    }

    private func parseJsonlFile(
        file: URL,
        sessionId: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        var inputTokens = 0
        var outputTokens = 0
        var model = "unknown"
        var messageCount = 0

        for line in handle.readAllUTF8Lines() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let m = json["model"] as? String, !m.isEmpty { model = m }

            if let usage = json["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
            }

            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                inputTokens += extracted.input
                outputTokens += extracted.output
            }

            messageCount += 1
        }

        guard inputTokens > 0 || outputTokens > 0 else { return nil }

        let pricing = ModelPricing.lookup(model: model)
        let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)

        let usage = TokenUsage(
            provider: .augment,
            sessionId: sessionId,
            projectName: sessionId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: cost,
            startTime: mtime ?? Date(),
            endTime: mtime ?? Date()
        )

        return (usage, nil)
    }

    private func parseJsonFile(
        file: URL,
        sessionId: String
    ) -> (usage: TokenUsage?, conversation: ConversationRecord?)? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date

        // Try array of messages format
        if let messages = json as? [[String: Any]] {
            var inputTokens = 0
            var outputTokens = 0
            var model = "unknown"

            for message in messages {
                if let m = message["model"] as? String, !m.isEmpty { model = m }
                if let usage = message["usage"] as? [String: Any] {
                    let extracted = TokenExtractionUtility.extractUsageTokens(usage)
                    inputTokens += extracted.input
                    outputTokens += extracted.output
                }
            }

            guard inputTokens > 0 || outputTokens > 0 else { return nil }

            let pricing = ModelPricing.lookup(model: model)
            let cost = pricing.cost(inputTokens: inputTokens, outputTokens: outputTokens)

            let usage = TokenUsage(
                provider: .augment,
                sessionId: sessionId,
                projectName: sessionId,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                costUSD: cost,
                startTime: mtime ?? Date(),
                endTime: mtime ?? Date()
            )

            return (usage, nil)
        }

        return nil
    }
}

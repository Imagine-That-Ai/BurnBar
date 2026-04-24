import Foundation
import OpenBurnBarCore

// MARK: - Claude-format JSONL conversation extraction

/// Accumulates user/assistant text and tool metadata from Claude Code / Factory JSONL lines.
final class ClaudeConversationAccumulator {
    private(set) var fullText = ""
    private(set) var firstUserText: String?
    private(set) var lastAssistantText = ""
    private(set) var messageCount = 0
    private(set) var userWordCount = 0
    private(set) var assistantWordCount = 0
    private(set) var keyFiles: [String] = []
    private(set) var keyCommands: [String] = []
    private(set) var keyTools: [String] = []
    private var fileSet = Set<String>()
    private var commandSet = Set<String>()
    private var toolSet = Set<String>()
    private(set) var startTime: Date?
    private(set) var endTime: Date?

    private let titleMax = 120

    func ingest(jsonLine: [String: Any]) {
        applyTimeline(from: jsonLine)

        guard let type = jsonLine["type"] as? String else { return }

        switch type {
        case "user":
            guard let message = jsonLine["message"] as? [String: Any],
                  (message["role"] as? String) == "user" else { return }
            processMessageContent(message["content"], isAssistant: false)
        case "assistant":
            guard let message = jsonLine["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant" else { return }
            processMessageContent(message["content"], isAssistant: true)
        default:
            break
        }
    }

    /// Picks up timestamps from several Factory / Claude JSONL shapes (string ISO8601, epoch seconds/ms, camelCase keys).
    private func applyTimeline(from json: [String: Any]) {
        let keys = ["timestamp", "created_at", "createdAt"]
        for key in keys {
            if let s = json[key] as? String, let date = Self.parseFlexibleISO8601(s) {
                noteTimeline(date)
                return
            }
            if let n = json[key] as? NSNumber {
                noteTimeline(Self.dateFromEpoch(n.doubleValue))
                return
            }
            if let n = json[key] as? Double {
                noteTimeline(Self.dateFromEpoch(n))
                return
            }
            if let n = json[key] as? Int64 {
                noteTimeline(Self.dateFromEpoch(Double(n)))
                return
            }
            if let n = json[key] as? Int {
                noteTimeline(Self.dateFromEpoch(Double(n)))
                return
            }
        }
    }

    private func noteTimeline(_ date: Date) {
        if startTime == nil { startTime = date }
        endTime = date
    }

    private static func parseFlexibleISO8601(_ s: String) -> Date? {
        ThreadSafeISO8601DateFormatter.parse(s)
    }

    /// Interprets JSON numeric timestamps as seconds or milliseconds since 1970.
    private static func dateFromEpoch(_ n: Double) -> Date {
        let sec = n > 100_000_000_000 ? n / 1000.0 : n
        return Date(timeIntervalSince1970: sec)
    }

    private func processMessageContent(_ rawContent: Any?, isAssistant: Bool) {
        if let text = rawContent as? String, text.isEmpty == false {
            appendMessageText(text, isAssistant: isAssistant)
            if isAssistant {
                lastAssistantText = text
            }
            messageCount += 1
            return
        }

        if let blocks = rawContent as? [[String: Any]] {
            processContentBlocks(blocks, isAssistant: isAssistant)
            return
        }

        if let items = rawContent as? [Any] {
            let blocks = items.compactMap { $0 as? [String: Any] }
            if blocks.isEmpty == false {
                processContentBlocks(blocks, isAssistant: isAssistant)
                return
            }

            let joinedText = items.compactMap { $0 as? String }.joined(separator: "\n\n")
            if joinedText.isEmpty == false {
                appendMessageText(joinedText, isAssistant: isAssistant)
                if isAssistant {
                    lastAssistantText = joinedText
                }
                messageCount += 1
            }
        }
    }

    private func processContentBlocks(_ blocks: [[String: Any]], isAssistant: Bool) {
        var sawText = false
        for block in blocks {
            let kind = block["type"] as? String ?? ""
            if kind == "text", let text = block["text"] as? String, !text.isEmpty {
                appendMessageText(text, isAssistant: isAssistant)
                sawText = true
                if isAssistant {
                    lastAssistantText = text
                }
            } else if kind == "tool_use" {
                let name = block["name"] as? String ?? ""
                if !name.isEmpty { toolSet.insert(name) }
                guard let input = block["input"] as? [String: Any] else { continue }
                if let path = input["path"] as? String, !path.isEmpty {
                    fileSet.insert(path)
                } else if let fp = input["file_path"] as? String, !fp.isEmpty {
                    fileSet.insert(fp)
                }
                if name == "Bash", let cmd = input["command"] as? String, !cmd.isEmpty {
                    commandSet.insert(cmd)
                }
            }
        }
        if sawText {
            messageCount += 1
        }
    }

    private func appendMessageText(_ text: String, isAssistant: Bool) {
        if !fullText.isEmpty { fullText += "\n\n" }
        fullText += SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: text)
        let words = text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
        if isAssistant {
            assistantWordCount += words
        } else {
            userWordCount += words
            if firstUserText == nil {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    firstUserText = String(trimmed.prefix(titleMax))
                }
            }
        }
    }

    func finalizeArrays() {
        keyFiles = Array(fileSet).sorted()
        keyCommands = Array(commandSet).sorted()
        keyTools = Array(toolSet).sorted()
    }
}

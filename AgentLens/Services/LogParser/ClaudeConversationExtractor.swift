import Foundation

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
        if let ts = jsonLine["timestamp"] as? String,
           let date = ISO8601DateFormatter().date(from: ts) {
            if startTime == nil { startTime = date }
            endTime = date
        }

        guard let type = jsonLine["type"] as? String else { return }

        switch type {
        case "user":
            guard let message = jsonLine["message"] as? [String: Any],
                  (message["role"] as? String) == "user",
                  let content = message["content"] as? [[String: Any]] else { return }
            processContentBlocks(content, isAssistant: false)
        case "assistant":
            guard let message = jsonLine["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant",
                  let content = message["content"] as? [[String: Any]] else { return }
            processContentBlocks(content, isAssistant: true)
        default:
            break
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
        fullText += text
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

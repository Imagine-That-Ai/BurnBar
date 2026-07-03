import Foundation
import OpenBurnBarCore

// MARK: - Claude-format JSONL conversation extraction

/// Accumulates user/assistant text and tool metadata from Claude Code / Factory JSONL lines.
///
/// Round-4 perf sweep: bounded accumulator. The previous implementation used
/// `fullText += ...` on every message, which is O(n²) due to string reallocation
/// and grows unbounded for long sessions (a 500-message session can produce a
/// 5MB+ string held entirely in memory). The bounded accumulator:
///
/// 1. Collects message text fragments into an array (O(1) amortized append).
/// 2. Joins once at finalize time (single O(n) allocation).
/// 3. Caps total `fullText` byte count at `maxFullTextBytes` (default 1MB).
///    Once the cap is reached, subsequent text fragments are counted for
///    word/message metrics but not appended to `fullText`. This bounds peak
///    memory regardless of session length.
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

    // Round-4 perf sweep: bounded accumulator state.
    private var fullTextParts: [String] = []
    private var fullTextByteCount: Int = 0
    private var fullTextCapped = false
    /// Maximum byte count for `fullText`. Once exceeded, new text fragments
    /// are counted for metrics but not appended. 1MB covers ~200K words,
    /// sufficient for relevance search on any conversation.
    let maxFullTextBytes: Int

    init(maxFullTextBytes: Int = 1 << 20) {
        self.maxFullTextBytes = maxFullTextBytes
    }

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
        // Round-4 perf sweep: array-based accumulator with byte cap.
        // Word/message metrics are always counted; fullText is capped.
        let formatted = SessionLogMarkdownFormatter.transcriptTurnMarkdown(isAssistant: isAssistant, body: text)
        if !fullTextCapped {
            let partBytes = formatted.utf8.count
            if fullTextByteCount + partBytes > maxFullTextBytes {
                // Cap reached: append what fits (truncated to the byte budget)
                // and mark as capped. Subsequent calls skip the append.
                let remaining = maxFullTextBytes - fullTextByteCount
                if remaining > 0 {
                    let truncated = Self.truncateToUTF8Bytes(formatted, maxBytes: remaining)
                    fullTextParts.append(truncated)
                    fullTextByteCount += truncated.utf8.count
                }
                fullTextCapped = true
            } else {
                fullTextParts.append(formatted)
                fullTextByteCount += partBytes
            }
        }

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

    /// Truncates a string to at most `maxBytes` UTF-8 bytes without splitting
    /// a multi-byte scalar. Returns a substring of the first complete scalars
    /// whose UTF8 encoding fits within the budget.
    private static func truncateToUTF8Bytes(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let utf8 = string.utf8
        if utf8.count <= maxBytes { return string }
        // Find the last valid scalar boundary at or before maxBytes.
        var cut = maxBytes
        // Walk back to a scalar boundary (UTF8 continuation bytes start with 10xxxxxx).
        while cut > 0 {
            let byte = utf8[utf8.index(utf8.startIndex, offsetBy: cut - 1)]
            if byte & 0xC0 != 0x80 { break } // Not a continuation byte
            cut -= 1
        }
        if cut == 0 { return "" }
        let endIndex = utf8.index(utf8.startIndex, offsetBy: cut)
        let stringIndex = String.Index(endIndex, within: string) ?? string.startIndex
        return String(string[string.startIndex..<stringIndex])
    }

    func finalizeArrays() {
        keyFiles = Array(fileSet).sorted()
        keyCommands = Array(commandSet).sorted()
        keyTools = Array(toolSet).sorted()
        // Round-4 perf sweep: join once (single O(n) allocation) instead of
        // O(n²) repeated string concatenation.
        fullText = fullTextParts.joined(separator: "\n\n")
        // Release the parts array to free memory before returning.
        fullTextParts.removeAll(keepingCapacity: false)
    }
}

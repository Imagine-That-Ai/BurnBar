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
///    word/message metrics, while bounded credential-match snippets from
///    overflow text are retained so security scans do not lose recall.
public final class ClaudeConversationAccumulator {
    public private(set) var fullText = ""
    public private(set) var firstUserText: String?
    public private(set) var lastAssistantText = ""
    public private(set) var messageCount = 0
    public private(set) var userWordCount = 0
    public private(set) var assistantWordCount = 0
    public private(set) var keyFiles: [String] = []
    public private(set) var keyCommands: [String] = []
    public private(set) var keyTools: [String] = []
    private var fileSet = Set<String>()
    private var commandSet = Set<String>()
    private var toolSet = Set<String>()
    public private(set) var startTime: Date?
    public private(set) var endTime: Date?

    private let titleMax = 120

    // Round-4 perf sweep: bounded accumulator state.
    private var fullTextParts: [String] = []
    private var fullTextByteCount: Int = 0
    private var fullTextCapped = false
    private var credentialOverflowSnippetByteCount = 0
    /// Maximum byte count for `fullText`. Once exceeded, new text fragments
    /// are counted for metrics but not fully appended. 1MB covers ~200K words,
    /// sufficient for relevance search on any conversation.
    let maxFullTextBytes: Int
    /// Bounded extra transcript surface reserved for credential-looking text
    /// that appears after `maxFullTextBytes`.
    let maxCredentialOverflowSnippetBytes: Int

    public init(maxFullTextBytes: Int = 1 << 20, maxCredentialOverflowSnippetBytes: Int = 64 << 10) {
        self.maxFullTextBytes = maxFullTextBytes
        self.maxCredentialOverflowSnippetBytes = maxCredentialOverflowSnippetBytes
    }

    public func ingest(jsonLine: [String: Any]) {
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

    public func ingest(jsonLine: [String: BurnBarJSONValue]) {
        ingest(jsonLine: jsonLine.untypedJSONDictionary)
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
                // and mark as capped. Subsequent calls keep only credential
                // snippets needed by the exposure scanner.
                let remaining = maxFullTextBytes - fullTextByteCount
                var unappendedText = formatted
                if remaining > 0 {
                    let tailStart = Self.unicodeScalarIndexAfterUTF8Prefix(formatted, maxBytes: remaining)
                    let truncated = String(formatted.unicodeScalars[..<tailStart])
                    if truncated.isEmpty == false {
                        fullTextParts.append(truncated)
                        fullTextByteCount += truncated.utf8.count
                    }
                    unappendedText = String(formatted.unicodeScalars[tailStart...])
                }
                appendCredentialOverflowSnippets(from: unappendedText)
                fullTextCapped = true
            } else {
                fullTextParts.append(formatted)
                fullTextByteCount += partBytes
            }
        } else {
            appendCredentialOverflowSnippets(from: formatted)
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

    private func appendCredentialOverflowSnippets(from text: String) {
        guard text.isEmpty == false,
              credentialOverflowSnippetByteCount < maxCredentialOverflowSnippetBytes,
              Self.credentialExposureRegexes.isEmpty == false else { return }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var seenRanges = Set<String>()

        for regex in Self.credentialExposureRegexes {
            let matches = regex.matches(in: text, range: fullRange)
            for match in matches {
                let rangeKey = "\(match.range.location):\(match.range.length)"
                guard seenRanges.insert(rangeKey).inserted else { continue }
                appendCredentialOverflowSnippet(Self.credentialOverflowSnippet(text: nsText, matchRange: match.range))
            }
        }
    }

    private func appendCredentialOverflowSnippet(_ snippet: String) {
        let remaining = maxCredentialOverflowSnippetBytes - credentialOverflowSnippetByteCount
        guard remaining > 0 else { return }

        let formatted = "## Security Scan Overflow\n\n\(snippet)"
        let clipped = Self.truncateToUTF8Bytes(formatted, maxBytes: remaining)
        guard clipped.isEmpty == false else { return }

        fullTextParts.append(clipped)
        credentialOverflowSnippetByteCount += clipped.utf8.count
    }

    private static func credentialOverflowSnippet(text: NSString, matchRange: NSRange, radius: Int = 160) -> String {
        let start = max(0, matchRange.location - radius)
        let end = min(text.length, matchRange.location + matchRange.length + radius)
        let snippetRange = NSRange(location: start, length: max(0, end - start))
        let raw = text.substring(with: snippetRange)
        let compact = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var prefix = ""
        var suffix = ""
        if start > 0 { prefix = "..." }
        if end < text.length { suffix = "..." }
        return prefix + compact + suffix
    }

    private static let credentialExposureRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(?i)\b[A-Z0-9_]*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|TOKEN|SECRET|PASSWORD)\b\s*[:=]\s*["']?[A-Za-z0-9_\-./+=]{8,}"#,
            #"\bsk-[A-Za-z0-9]{16,}\b"#,
            #"\bAIza[0-9A-Za-z\-_]{16,}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) } // try?-ok(literal regex compile)
    }()

    /// Truncates a string to at most `maxBytes` UTF-8 bytes without splitting
    /// a multi-byte scalar. Returns a substring of the first complete scalars
    /// whose UTF8 encoding fits within the budget.
    private static func truncateToUTF8Bytes(_ string: String, maxBytes: Int) -> String {
        let endIndex = unicodeScalarIndexAfterUTF8Prefix(string, maxBytes: maxBytes)
        return String(string.unicodeScalars[..<endIndex])
    }

    private static func unicodeScalarIndexAfterUTF8Prefix(
        _ string: String,
        maxBytes: Int
    ) -> String.UnicodeScalarView.Index {
        guard maxBytes > 0 else { return string.unicodeScalars.startIndex }
        if string.utf8.count <= maxBytes { return string.unicodeScalars.endIndex }

        var usedBytes = 0
        var scalarIndex = string.unicodeScalars.startIndex
        while scalarIndex < string.unicodeScalars.endIndex {
            let scalar = string.unicodeScalars[scalarIndex]
            let scalarBytes = String(scalar).utf8.count
            guard usedBytes + scalarBytes <= maxBytes else { break }
            usedBytes += scalarBytes
            scalarIndex = string.unicodeScalars.index(after: scalarIndex)
        }
        return scalarIndex
    }

    public func finalizeArrays() {
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

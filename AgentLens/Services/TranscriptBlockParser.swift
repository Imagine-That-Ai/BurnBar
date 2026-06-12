import Foundation

// MARK: - Transcript Block

/// A parsed block from a raw session transcript for structured rendering.
struct TranscriptBlock {
    enum Kind {
        case userMessage
        case assistantMessage
        case toolUse
        case codeBlock
        case separator
    }

    let kind: Kind
    let content: String
    /// Optional label — language for code blocks, tool name for toolUse.
    let label: String?
}

// MARK: - Transcript Block Parser

/// Parses raw session transcript text (from Claude Code, Codex, etc.) into
/// structured blocks for the beautified transcript view.
enum TranscriptBlockParser {

    static func parse(_ text: String) -> [TranscriptBlock] {
        let cleaned = stripSystemTags(text)
        guard !cleaned.isEmpty else { return [] }

        var blocks: [TranscriptBlock] = []
        let lines = cleaned.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Separator (--- or similar)
            if trimmed.allSatisfy({ $0 == "-" || $0 == "=" }) && trimmed.count >= 3 {
                blocks.append(TranscriptBlock(kind: .separator, content: "", label: nil))
                i += 1
                continue
            }

            // Markdown table (skip rendering as raw text)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                // Collect entire table
                var tableLines: [String] = []
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    guard tl.hasPrefix("|") && tl.hasSuffix("|") else { break }
                    // Skip separator rows like |---|---|
                    if !tl.allSatisfy({ $0 == "|" || $0 == "-" || $0 == " " || $0 == ":" }) {
                        tableLines.append(tl)
                    }
                    i += 1
                }
                // Parse table into key-value pairs for metadata display
                // (already handled by metadata card — skip table in transcript)
                continue
            }

            // Code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                if !code.isEmpty {
                    // Tool-use code blocks
                    if lang == "tool-use" || lang == "tool_use" {
                        let toolLines = code.components(separatedBy: "\n")
                        let toolName = toolLines.first ?? "Tool"
                        let detail = toolLines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        blocks.append(TranscriptBlock(kind: .toolUse, content: detail, label: toolName))
                    } else {
                        blocks.append(TranscriptBlock(kind: .codeBlock, content: code, label: lang.isEmpty ? nil : lang))
                    }
                }
                continue
            }

            // H1/H2 headings that indicate role
            if trimmed.hasPrefix("## You") || trimmed.hasPrefix("## User") || trimmed.hasPrefix("## Human") {
                i += 1
                // Collect user message content until next heading or separator
                var msgLines: [String] = []
                while i < lines.count {
                    let ml = lines[i].trimmingCharacters(in: .whitespaces)
                    if ml.hasPrefix("## ") || ml.hasPrefix("# ") { break }
                    if ml.allSatisfy({ $0 == "-" || $0 == "=" }) && ml.count >= 3 { break }
                    msgLines.append(lines[i])
                    i += 1
                }
                let msg = msgLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    blocks.append(TranscriptBlock(kind: .userMessage, content: msg, label: nil))
                }
                continue
            }

            if trimmed.hasPrefix("## Assistant") || trimmed.hasPrefix("## Claude") || trimmed.hasPrefix("## Response") {
                i += 1
                // Collect assistant message content, handling inline code blocks
                var msgLines: [String] = []
                while i < lines.count {
                    let ml = lines[i].trimmingCharacters(in: .whitespaces)
                    if ml.hasPrefix("## ") || ml.hasPrefix("# ") { break }
                    if (ml.allSatisfy({ $0 == "-" || $0 == "=" }) && ml.count >= 3) &&
                        !ml.hasPrefix("```") { break }
                    // Check for code blocks inside assistant messages
                    if ml.hasPrefix("```") {
                        // Flush accumulated text
                        let accText = msgLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !accText.isEmpty {
                            blocks.append(TranscriptBlock(kind: .assistantMessage, content: accText, label: nil))
                            msgLines = []
                        }
                        // Parse the code block
                        let lang = String(ml.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        i += 1
                        var codeLines: [String] = []
                        while i < lines.count {
                            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                                i += 1
                                break
                            }
                            codeLines.append(lines[i])
                            i += 1
                        }
                        let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                        if !code.isEmpty {
                            if lang == "tool-use" || lang == "tool_use" {
                                let toolLines = code.components(separatedBy: "\n")
                                let toolName = toolLines.first ?? "Tool"
                                let detail = toolLines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                                blocks.append(TranscriptBlock(kind: .toolUse, content: detail, label: toolName))
                            } else {
                                blocks.append(TranscriptBlock(kind: .codeBlock, content: code, label: lang.isEmpty ? nil : lang))
                            }
                        }
                        continue
                    }
                    msgLines.append(lines[i])
                    i += 1
                }
                let msg = msgLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    blocks.append(TranscriptBlock(kind: .assistantMessage, content: msg, label: nil))
                }
                continue
            }

            // H1 headings — skip (title is shown in header)
            if trimmed.hasPrefix("# ") {
                i += 1
                continue
            }

            // Session Summary heading — skip (shown as card)
            if trimmed == "## Session Summary" {
                i += 1
                // Skip summary content (already displayed)
                while i < lines.count {
                    let sl = lines[i].trimmingCharacters(in: .whitespaces)
                    if sl.hasPrefix("## ") || sl.hasPrefix("# ") { break }
                    if sl.allSatisfy({ $0 == "-" || $0 == "=" }) && sl.count >= 3 { break }
                    i += 1
                }
                continue
            }

            // Generic heading — treat next content as assistant
            if trimmed.hasPrefix("## ") {
                i += 1
                continue
            }

            // Claude Code raw format: lines starting with role markers
            // "Human:" or "H:" patterns
            if trimmed.hasPrefix("Human:") || trimmed.hasPrefix("H:") {
                let msgStart = trimmed.hasPrefix("Human:") ? trimmed.dropFirst(6) : trimmed.dropFirst(2)
                var msgLines = [String(msgStart)]
                i += 1
                while i < lines.count {
                    let ml = lines[i].trimmingCharacters(in: .whitespaces)
                    if ml.hasPrefix("Assistant:") || ml.hasPrefix("A:") || ml.hasPrefix("Human:") || ml.hasPrefix("H:") { break }
                    if ml.hasPrefix("## ") || ml.hasPrefix("# ") { break }
                    msgLines.append(lines[i])
                    i += 1
                }
                let msg = msgLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    blocks.append(TranscriptBlock(kind: .userMessage, content: msg, label: nil))
                }
                continue
            }

            if trimmed.hasPrefix("Assistant:") || trimmed.hasPrefix("A:") {
                let msgStart = trimmed.hasPrefix("Assistant:") ? trimmed.dropFirst(10) : trimmed.dropFirst(2)
                var msgLines = [String(msgStart)]
                i += 1
                while i < lines.count {
                    let ml = lines[i].trimmingCharacters(in: .whitespaces)
                    if ml.hasPrefix("Assistant:") || ml.hasPrefix("A:") || ml.hasPrefix("Human:") || ml.hasPrefix("H:") { break }
                    if ml.hasPrefix("## ") || ml.hasPrefix("# ") { break }
                    msgLines.append(lines[i])
                    i += 1
                }
                let msg = msgLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty {
                    blocks.append(TranscriptBlock(kind: .assistantMessage, content: msg, label: nil))
                }
                continue
            }

            // Plain text — accumulate into assistant block
            var plainLines: [String] = [line]
            i += 1
            while i < lines.count {
                let pl = lines[i].trimmingCharacters(in: .whitespaces)
                if pl.hasPrefix("## ") || pl.hasPrefix("# ") { break }
                if pl.hasPrefix("```") { break }
                if pl.hasPrefix("|") && pl.hasSuffix("|") { break }
                if pl.hasPrefix("Human:") || pl.hasPrefix("H:") { break }
                if pl.hasPrefix("Assistant:") || pl.hasPrefix("A:") { break }
                if pl.allSatisfy({ $0 == "-" || $0 == "=" }) && pl.count >= 3 { break }
                plainLines.append(lines[i])
                i += 1
            }
            let plain = plainLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                blocks.append(TranscriptBlock(kind: .assistantMessage, content: plain, label: nil))
            }
        }

        return blocks
    }

    /// Strips XML-like system tags from transcript text.
    static func stripSystemTags(_ text: String) -> String {
        var result = text

        // Remove entire <system-reminder>...</system-reminder> blocks
        let systemReminderPattern = #"<system-reminder>[\s\S]*?</system-reminder>"#
        result = result.replacingOccurrences(of: systemReminderPattern, with: "", options: .regularExpression)

        // Remove <local-command-caveat>...</local-command-caveat> blocks
        let caveatPattern = #"<local-command-caveat>[\s\S]*?</local-command-caveat>"#
        result = result.replacingOccurrences(of: caveatPattern, with: "", options: .regularExpression)

        // Remove <command-name>...</command-name> tags
        let cmdNamePattern = #"<command-name>[\s\S]*?</command-name>"#
        result = result.replacingOccurrences(of: cmdNamePattern, with: "", options: .regularExpression)

        // Remove <command-message>...</command-message> tags
        let cmdMsgPattern = #"<command-message>[\s\S]*?</command-message>"#
        result = result.replacingOccurrences(of: cmdMsgPattern, with: "", options: .regularExpression)

        // Remove <command-args>...</command-args> tags
        let cmdArgsPattern = #"<command-args>[\s\S]*?</command-args>"#
        result = result.replacingOccurrences(of: cmdArgsPattern, with: "", options: .regularExpression)

        // Remove <local-command-stdout>...</local-command-stdout> tags
        let cmdStdoutPattern = #"<local-command-stdout>[\s\S]*?</local-command-stdout>"#
        result = result.replacingOccurrences(of: cmdStdoutPattern, with: "", options: .regularExpression)

        // Remove standalone opening/closing tags
        let genericTagPattern = #"</?[a-zA-Z][a-zA-Z0-9_-]*>"#
        result = result.replacingOccurrences(of: genericTagPattern, with: "", options: .regularExpression)

        // Clean up excessive blank lines (more than 2 consecutive)
        let excessiveNewlines = #"\n{4,}"#
        result = result.replacingOccurrences(of: excessiveNewlines, with: "\n\n\n", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

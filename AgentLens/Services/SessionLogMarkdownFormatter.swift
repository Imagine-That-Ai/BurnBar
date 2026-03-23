import Foundation

// MARK: - Session Log Markdown Formatter

/// Deterministic Markdown renderer for session log records.
/// Used by both the Session Logs UI (preview/export) and CloudSyncService (full-log upload).
enum SessionLogMarkdownFormatter {

    // MARK: - Public API

    /// Returns Markdown for a persisted `ConversationRecord`.
    /// - Provider logs: metadata table + transcript body.
    /// - CLI assistant: pre-built Markdown stored in `record.fullText`.
    static func markdown(for record: ConversationRecord) -> String {
        switch record.sourceType {
        case .providerLog:
            return providerMarkdown(record)
        case .cliAssistant:
            return record.fullText
        }
    }

    /// Builds role-aware Markdown from a list of persisted chat messages.
    /// Used when synthesizing the `cli_assistant` ConversationRecord for storage.
    static func cliMarkdown(from messages: [ChatMessageRecord]) -> String {
        guard !messages.isEmpty else { return "" }

        var lines: [String] = []

        lines.append("# BurnBar Assistant")
        lines.append("")

        if let first = messages.first {
            lines.append("_Session started \(formatDate(first.timestamp))_")
            lines.append("")
        }

        lines.append("---")
        lines.append("")

        for message in messages {
            switch message.role {
            case .user:
                lines.append("## You")
                lines.append("")
                if message.content.isEmpty == false {
                    lines.append(message.content)
                }
                lines.append("")

            case .assistant:
                lines.append("## Assistant")
                lines.append("")

                let pieces = message.displayTranscript
                if pieces.isEmpty {
                    if message.content.isEmpty == false {
                        lines.append(message.content)
                    }
                } else {
                    for piece in pieces {
                        switch piece.kind {
                        case .text:
                            if piece.value.isEmpty == false {
                                lines.append(piece.value)
                            }
                        case .toolUse:
                            lines.append("")
                            lines.append("```tool-use")
                            lines.append(piece.value)
                            if let detail = piece.detail, detail.isEmpty == false {
                                lines.append(detail)
                            }
                            lines.append("```")
                            lines.append("")
                        }
                    }
                }
                lines.append("")

            case .system:
                break
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Provider Log Markdown

    private static func providerMarkdown(_ record: ConversationRecord) -> String {
        var lines: [String] = []

        let title = record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle
        lines.append("# \(title)")
        lines.append("")

        // Metadata table
        lines.append("| Field | Value |")
        lines.append("|---|---|")
        lines.append("| Provider | \(record.provider.displayName) |")
        lines.append("| Project | \(record.projectName) |")
        lines.append("| Session ID | \(record.sessionId) |")
        if let start = record.startTime {
            lines.append("| Started | \(formatDate(start)) |")
        }
        if let end = record.endTime {
            lines.append("| Ended | \(formatDate(end)) |")
        }
        lines.append("| Messages | \(record.messageCount) |")
        if record.userWordCount > 0 || record.assistantWordCount > 0 {
            lines.append("| Words (user / assistant) | \(record.userWordCount) / \(record.assistantWordCount) |")
        }
        if record.keyFiles.isEmpty == false {
            lines.append("| Key Files | \(record.keyFiles.prefix(6).joined(separator: ", ")) |")
        }
        if record.keyTools.isEmpty == false {
            lines.append("| Tools | \(record.keyTools.prefix(8).joined(separator: ", ")) |")
        }

        lines.append("")
        lines.append("---")
        lines.append("")

        if record.fullText.isEmpty == false {
            lines.append(record.fullText)
        }

        if let summary = record.summary, summary.isEmpty == false {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append("## Summary")
            lines.append("")
            lines.append(summary)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

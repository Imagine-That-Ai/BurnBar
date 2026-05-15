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

    /// One message turn in stored provider `fullText` — matches `cliMarkdown` headings so
    /// `TranscriptBlockParser` can label You vs Assistant in Session Logs.
    static func transcriptTurnMarkdown(isAssistant: Bool, body: String) -> String {
        let header = isAssistant ? "## Assistant" : "## You"
        return "\(header)\n\n\(body)"
    }

    /// Builds role-aware Markdown from a list of persisted chat messages.
    /// Used when synthesizing the `cli_assistant` ConversationRecord for storage.
    static func cliMarkdown(from messages: [ChatMessageRecord]) -> String {
        guard !messages.isEmpty else { return "" }

        var lines: [String] = []

        lines.append("# OpenBurnBar Assistant")
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
                        case .toolUse, .toolResult:
                            lines.append("")
                            lines.append(piece.kind == .toolResult ? "```tool-result" : "```tool-use")
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

        let title = displayTitle(for: record)
        lines.append("# \(title)")
        lines.append("")

        if let summary = record.summary, summary.isEmpty == false {
            lines.append("## Session Summary")
            lines.append("")
            if let summaryTitle = record.summaryTitle, summaryTitle.isEmpty == false {
                lines.append("**Name:** \(summaryTitle)")
                lines.append("")
            }
            lines.append(summary)
            lines.append("")
            lines.append("---")
            lines.append("")
        }

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

    private static func displayTitle(for record: ConversationRecord) -> String {
        if let summaryTitle = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryTitle.isEmpty {
            return summaryTitle
        }
        return record.inferredTaskTitle.isEmpty ? "Session" : record.inferredTaskTitle
    }
}

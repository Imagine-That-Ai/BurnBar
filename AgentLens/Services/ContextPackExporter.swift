import Foundation

// MARK: - Context Pack Export Target

/// Supported export targets for context packs.
enum ContextPackExportTarget: String, CaseIterable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case cursor = "cursor"
    case hermes = "hermes"
    case markdown = "markdown"

    /// User-facing display name for the export target.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .hermes: return "Hermes"
        case .markdown: return "Markdown"
        }
    }

    /// File extension for the exported content.
    var fileExtension: String {
        switch self {
        case .claude, .codex, .cursor, .hermes: return "txt"
        case .markdown: return "md"
        }
    }
}

// MARK: - Context Pack Exporter

/// Renders context packs into agent-specific export formats.
/// All targets share the same underlying session body semantics;
/// only the envelope/header framing differs.
enum ContextPackExporter {

    // MARK: - Shared Body

    /// Builds the shared body text for a context pack (session entries only, no envelope).
    /// This is used as the foundation for all export targets.
    static func buildSharedBody(_ pack: ContextPack) -> String {
        guard !pack.isEmpty else { return "" }

        var lines: [String] = []

        // Key files section
        if !pack.keyFiles.isEmpty {
            lines.append("Key files:")
            for file in pack.keyFiles {
                lines.append("  - \(file)")
            }
            lines.append("")
        }

        // Key commands section
        if !pack.keyCommands.isEmpty {
            lines.append("Key commands:")
            for cmd in pack.keyCommands {
                lines.append("  - \(cmd)")
            }
            lines.append("")
        }

        // Sessions
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Export

    /// Renders a context pack for a specific export target.
    static func export(_ pack: ContextPack, target: ContextPackExportTarget) -> String {
        switch target {
        case .claude, .hermes:
            return exportCLAUDEStyle(pack)
        case .codex:
            return exportCodexStyle(pack)
        case .cursor:
            return exportCursorStyle(pack)
        case .markdown:
            return exportMarkdownStyle(pack)
        }
    }

    // MARK: - CLAUDE / Hermes Style

    /// CLAUDE-style header + <context_pack> envelope.
    /// Used by both claude and hermes targets.
    private static func exportCLAUDEStyle(_ pack: ContextPack) -> String {
        var lines: [String] = []

        // CLAUDE-style header comment
        lines.append("# Context Pack")
        lines.append("#")
        lines.append("# This context pack provides relevant session history and project context.")
        lines.append("#")

        if let project = pack.project {
            lines.append("# Project: \(project)")
        }

        lines.append("# Sessions: \(pack.sessions.count)")
        lines.append("# Char estimate: \(pack.charEstimate)")
        lines.append("")

        // Usage summary
        lines.append("## Summary")
        lines.append(pack.usageSummary)
        lines.append("")

        // Open envelope
        lines.append("<context_pack>")
        lines.append("")

        // Key files and commands
        if !pack.keyFiles.isEmpty {
            lines.append("## Key Files")
            for file in pack.keyFiles {
                lines.append("- \(file)")
            }
            lines.append("")
        }

        if !pack.keyCommands.isEmpty {
            lines.append("## Key Commands")
            for cmd in pack.keyCommands {
                lines.append("- \(cmd)")
            }
            lines.append("")
        }

        // Sessions
        lines.append("## Sessions")
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        // Close envelope
        lines.append("</context_pack>")

        return lines.joined(separator: "\n")
    }

    // MARK: - Codex Style

    /// Minimal prompt with ## Context framing.
    private static func exportCodexStyle(_ pack: ContextPack) -> String {
        var lines: [String] = []

        // Minimal header
        lines.append("## Context")
        lines.append("")

        if let project = pack.project {
            lines.append("Project: \(project)")
            lines.append("")
        }

        // Usage summary
        lines.append("Summary: \(pack.usageSummary)")
        lines.append("")

        // Key files
        if !pack.keyFiles.isEmpty {
            lines.append("Key files:")
            for file in pack.keyFiles {
                lines.append("  - \(file)")
            }
            lines.append("")
        }

        // Key commands
        if !pack.keyCommands.isEmpty {
            lines.append("Key commands:")
            for cmd in pack.keyCommands {
                lines.append("  - \(cmd)")
            }
            lines.append("")
        }

        // Sessions
        lines.append("## Sessions")
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Cursor Style

    /// .cursorrules-style framing.
    private static func exportCursorStyle(_ pack: ContextPack) -> String {
        var lines: [String] = []

        // .cursorrules style header
        lines.append("<!--")
        lines.append("  context-pack:")
        lines.append("    version: 1.0")
        if let project = pack.project {
            lines.append("    project: \"\(project)\"")
        }
        lines.append("    sessions: \(pack.sessions.count)")
        lines.append("    char-estimate: \(pack.charEstimate)")
        lines.append("-->")
        lines.append("")

        // Summary
        lines.append("## Context Summary")
        lines.append(pack.usageSummary)
        lines.append("")

        // Key files
        if !pack.keyFiles.isEmpty {
            lines.append("### Key Files")
            for file in pack.keyFiles {
                lines.append("- `\(file)`")
            }
            lines.append("")
        }

        // Key commands
        if !pack.keyCommands.isEmpty {
            lines.append("### Key Commands")
            for cmd in pack.keyCommands {
                lines.append("- `\(cmd)`")
            }
            lines.append("")
        }

        // Sessions
        lines.append("### Sessions")
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown Style

    /// Canonical markdown brief structure.
    static func exportMarkdownStyle(_ pack: ContextPack) -> String {
        var lines: [String] = []

        // Title
        if let project = pack.project {
            lines.append("# Context Pack: \(project)")
        } else {
            lines.append("# Context Pack")
        }
        lines.append("")

        // Metadata
        lines.append("| Property | Value |")
        lines.append("|----------|-------|")
        lines.append("| Sessions | \(pack.sessions.count) |")
        lines.append("| Est. Characters | \(pack.charEstimate) |")
        if let start = pack.dateWindow.start {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            lines.append("| Start Date | \(formatter.string(from: start)) |")
        }
        if let end = pack.dateWindow.end {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            lines.append("| End Date | \(formatter.string(from: end)) |")
        }
        lines.append("")

        // Usage summary
        lines.append("## Summary")
        lines.append(pack.usageSummary)
        lines.append("")

        // Key files
        if !pack.keyFiles.isEmpty {
            lines.append("## Key Files")
            for file in pack.keyFiles {
                lines.append("- \(file)")
            }
            lines.append("")
        }

        // Key commands
        if !pack.keyCommands.isEmpty {
            lines.append("## Key Commands")
            for cmd in pack.keyCommands {
                lines.append("- `\(cmd)`")
            }
            lines.append("")
        }

        // Sessions
        lines.append("## Sessions")
        lines.append("")
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

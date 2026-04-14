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
/// All targets share the same underlying session body content;
/// only the envelope/header framing differs.
enum ContextPackExporter {

    // MARK: - XML Escaping

    /// Escapes XML-sensitive characters for safe insertion inside an XML envelope.
    /// This prevents content from breaking the <context_pack> envelope.
    private static func xmlEscape(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }

    // MARK: - Shared Body Pipeline

    /// Builds the canonical shared body content for a context pack.
    /// This single pipeline produces the body content used by ALL export targets,
    /// ensuring byte-for-byte equivalence of session content across all envelopes.
    ///
    /// Returns structured components: (keyFilesSection, keyCommandsSection, sessionsSection)
    /// Each component is already formatted and ready for envelope-specific framing.
    private static func buildSharedBodyComponents(_ pack: ContextPack) -> (
        keyFilesSection: String,
        keyCommandsSection: String,
        sessionsSection: String
    ) {
        var keyFilesLines: [String] = []
        var keyCommandsLines: [String] = []
        var sessionLines: [String] = []

        // Key files section (canonical format used across all targets)
        if !pack.keyFiles.isEmpty {
            keyFilesLines.append("Key files:")
            for file in pack.keyFiles {
                keyFilesLines.append("  - \(file)")
            }
        }

        // Key commands section (canonical format used across all targets)
        if !pack.keyCommands.isEmpty {
            keyCommandsLines.append("Key commands:")
            for cmd in pack.keyCommands {
                keyCommandsLines.append("  - \(cmd)")
            }
        }

        // Sessions section (canonical - uses session.bodyText directly)
        for session in pack.sessions {
            sessionLines.append(session.bodyText)
            sessionLines.append("")
        }

        return (
            keyFilesSection: keyFilesLines.joined(separator: "\n"),
            keyCommandsSection: keyCommandsLines.joined(separator: "\n"),
            sessionsSection: sessionLines.joined(separator: "\n")
        )
    }

    /// Builds the complete shared body text for a context pack.
    /// This is the canonical body string used as the foundation for all export targets.
    static func buildSharedBody(_ pack: ContextPack) -> String {
        guard !pack.isEmpty else { return "" }

        let components = buildSharedBodyComponents(pack)
        var lines: [String] = []

        if !components.keyFilesSection.isEmpty {
            lines.append(components.keyFilesSection)
            lines.append("")
        }

        if !components.keyCommandsSection.isEmpty {
            lines.append(components.keyCommandsSection)
            lines.append("")
        }

        if !components.sessionsSection.isEmpty {
            lines.append(components.sessionsSection)
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

    /// CLAUDE-style header + <context_pack> XML envelope.
    /// Used by both claude and hermes targets.
    /// Body content is XML-escaped to prevent envelope breakage from sensitive characters.
    private static func exportCLAUDEStyle(_ pack: ContextPack) -> String {
        let components = buildSharedBodyComponents(pack)

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

        // Key files section (formatted for CLAUDE style)
        if !components.keyFilesSection.isEmpty {
            lines.append("## Key Files")
            // Convert canonical "Key files:" format to bullet list
            let fileLines = components.keyFilesSection.components(separatedBy: "\n")
            for line in fileLines {
                if line.hasPrefix("Key files:") {
                    lines.append(line)  // Keep header
                } else if line.hasPrefix("  - ") {
                    lines.append("- \(String(line.dropFirst(4)))")  // Convert indent to bullet
                } else if !line.isEmpty {
                    lines.append(line)
                }
            }
            lines.append("")
        }

        // Key commands section (formatted for CLAUDE style)
        if !components.keyCommandsSection.isEmpty {
            lines.append("## Key Commands")
            let cmdLines = components.keyCommandsSection.components(separatedBy: "\n")
            for line in cmdLines {
                if line.hasPrefix("Key commands:") {
                    lines.append(line)
                } else if line.hasPrefix("  - ") {
                    lines.append("- \(String(line.dropFirst(4)))")
                } else if !line.isEmpty {
                    lines.append(line)
                }
            }
            lines.append("")
        }

        // Sessions section - body content is XML-escaped for safety
        lines.append("## Sessions")
        for session in pack.sessions {
            // Escape XML-sensitive characters in body content
            let escapedBody = xmlEscape(session.bodyText)
            lines.append(escapedBody)
            lines.append("")
        }

        // Close envelope
        lines.append("</context_pack>")

        return lines.joined(separator: "\n")
    }

    // MARK: - Codex Style

    /// Minimal prompt with ## Context framing.
    /// Uses shared body pipeline for session content.
    private static func exportCodexStyle(_ pack: ContextPack) -> String {
        let components = buildSharedBodyComponents(pack)

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

        // Key files (canonical format)
        if !components.keyFilesSection.isEmpty {
            lines.append(components.keyFilesSection)
            lines.append("")
        }

        // Key commands (canonical format)
        if !components.keyCommandsSection.isEmpty {
            lines.append(components.keyCommandsSection)
            lines.append("")
        }

        // Sessions (using canonical session body content)
        lines.append("## Sessions")
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Cursor Style

    /// .cursorrules-style framing.
    /// Uses shared body pipeline for session content.
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

        // Key files (formatted for cursorrules style with code fences)
        if !pack.keyFiles.isEmpty {
            lines.append("### Key Files")
            for file in pack.keyFiles {
                lines.append("- `\(file)`")
            }
            lines.append("")
        }

        // Key commands (formatted for cursorrules style with code fences)
        if !pack.keyCommands.isEmpty {
            lines.append("### Key Commands")
            for cmd in pack.keyCommands {
                lines.append("- `\(cmd)`")
            }
            lines.append("")
        }

        // Sessions (using canonical session body content)
        lines.append("### Sessions")
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown Style

    /// Canonical markdown brief structure.
    /// Uses shared body pipeline for session content.
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

        // Sessions (using canonical session body content)
        lines.append("## Sessions")
        lines.append("")
        for session in pack.sessions {
            lines.append(session.bodyText)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

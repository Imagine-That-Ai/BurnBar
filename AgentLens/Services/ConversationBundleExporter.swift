import Foundation
import OpenBurnBarCore

// MARK: - Conversation Bundle Exporter
//
// Exports a set of indexed conversations into a self-contained folder bundle:
//
//   <bundle>/
//     conversations.json   — machine-readable array (metadata + full transcript)
//     README.md            — human index linking each Markdown file
//     markdown/
//       <provider>-<title>-<shortid>.md   — one transcript per conversation
//
// JSON is the round-trippable source of truth; the Markdown mirror is for
// reading and sharing. Bodies are resolved lazily through `bodyProvider` so the
// caller controls where full text comes from (local DB, cloud download, iCloud
// mirror) without this type knowing about those services.

enum ConversationBundleExporter {

    struct Result: Sendable {
        let folderURL: URL
        let conversationCount: Int
        let jsonURL: URL
    }

    /// Codable export record — a flattened, ISO-8601-dated projection of
    /// `ConversationRecord` plus the resolved transcript body.
    struct ExportedConversation: Codable {
        let id: String
        let provider: String
        let providerDisplayName: String
        let sessionId: String
        let projectName: String
        let title: String
        let summary: String?
        let model: String?
        let sourceType: String
        let startTime: String?
        let endTime: String?
        let indexedAt: String
        let messageCount: Int
        let userWordCount: Int
        let assistantWordCount: Int
        let workingDirectory: String?
        let keyFiles: [String]
        let keyCommands: [String]
        let keyTools: [String]
        let sourceDeviceName: String?
        let transcript: String
    }

    struct ExportManifest: Codable {
        let schemaVersion: Int
        let generatedAt: String
        let app: String
        let conversationCount: Int
        let conversations: [ExportedConversation]
    }

    /// Exports `records` into a new timestamped folder under `directory`.
    /// `bodyProvider` resolves the full transcript for a record (defaults to its
    /// already-loaded `fullText`). Runs file I/O off the main actor.
    static func exportBundle(
        records: [ConversationRecord],
        to directory: URL,
        bodyProvider: @escaping @Sendable (ConversationRecord) async -> String = { $0.fullText }
    ) async throws -> Result {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let stamp = bundleTimestamp()
        let folderURL = directory.appendingPathComponent("OpenBurnBar-Conversations-\(stamp)", isDirectory: true)
        let markdownDir = folderURL.appendingPathComponent("markdown", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: markdownDir, withIntermediateDirectories: true)

        var exported: [ExportedConversation] = []
        var indexLines: [String] = [
            "# OpenBurnBar — Conversation Export",
            "",
            "Generated \(iso.string(from: Date())) · \(records.count) conversation\(records.count == 1 ? "" : "s")",
            "",
            "| Provider | Title | Project | When | Messages | File |",
            "|----------|-------|---------|------|----------|------|",
        ]

        var usedFilenames: Set<String> = []

        for record in records {
            let body = await bodyProvider(record)
            let title = displayTitle(for: record)
            let filename = uniqueMarkdownFilename(for: record, title: title, used: &usedFilenames)

            let exportedRecord = ExportedConversation(
                id: record.id,
                provider: record.provider.rawValue,
                providerDisplayName: record.provider.displayName,
                sessionId: record.sessionId,
                projectName: record.projectName,
                title: title,
                summary: record.summary,
                model: record.summaryModel,
                sourceType: record.sourceType.rawValue,
                startTime: record.startTime.map(iso.string(from:)),
                endTime: record.endTime.map(iso.string(from:)),
                indexedAt: iso.string(from: record.indexedAt),
                messageCount: record.messageCount,
                userWordCount: record.userWordCount,
                assistantWordCount: record.assistantWordCount,
                workingDirectory: record.workingDirectory,
                keyFiles: record.keyFiles,
                keyCommands: record.keyCommands,
                keyTools: record.keyTools,
                sourceDeviceName: record.sourceDeviceName,
                transcript: body
            )
            exported.append(exportedRecord)

            let markdown = renderMarkdown(record: record, title: title, body: body, iso: iso)
            try markdown.data(using: .utf8)?.write(to: markdownDir.appendingPathComponent(filename))

            let whenLabel = (record.startTime ?? record.endTime ?? record.indexedAt)
                .formatted(date: .abbreviated, time: .shortened)
            indexLines.append(
                "| \(record.provider.displayName) | \(escapeCell(title)) | \(escapeCell(record.projectName)) | \(whenLabel) | \(record.messageCount) | [md](markdown/\(filename)) |"
            )
        }

        let manifest = ExportManifest(
            schemaVersion: 1,
            generatedAt: iso.string(from: Date()),
            app: "OpenBurnBar",
            conversationCount: exported.count,
            conversations: exported
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let jsonURL = folderURL.appendingPathComponent("conversations.json")
        try encoder.encode(manifest).write(to: jsonURL)

        try indexLines.joined(separator: "\n").data(using: .utf8)?
            .write(to: folderURL.appendingPathComponent("README.md"))

        return Result(folderURL: folderURL, conversationCount: exported.count, jsonURL: jsonURL)
    }

    // MARK: - Markdown rendering

    private static func renderMarkdown(
        record: ConversationRecord,
        title: String,
        body: String,
        iso: ISO8601DateFormatter
    ) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("| Property | Value |")
        lines.append("|----------|-------|")
        lines.append("| Provider | \(record.provider.displayName) |")
        if let model = record.summaryModel, !model.isEmpty { lines.append("| Model | \(model) |") }
        lines.append("| Project | \(record.projectName.isEmpty ? "—" : record.projectName) |")
        if let start = record.startTime { lines.append("| Started | \(iso.string(from: start)) |") }
        if let end = record.endTime { lines.append("| Ended | \(iso.string(from: end)) |") }
        lines.append("| Messages | \(record.messageCount) |")
        if let dir = record.workingDirectory, !dir.isEmpty { lines.append("| Working dir | `\(dir)` |") }
        if let device = record.sourceDeviceName, !device.isEmpty { lines.append("| Device | \(device) |") }
        lines.append("")
        if let summary = record.summary, !summary.isEmpty {
            lines.append("## Summary")
            lines.append(summary)
            lines.append("")
        }
        if !record.keyFiles.isEmpty {
            lines.append("## Key Files")
            for file in record.keyFiles { lines.append("- `\(file)`") }
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        lines.append(body.isEmpty ? "_No transcript body was available for this conversation._" : body)
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func displayTitle(for record: ConversationRecord) -> String {
        if let summaryTitle = record.summaryTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !summaryTitle.isEmpty {
            return summaryTitle
        }
        if !record.inferredTaskTitle.isEmpty { return record.inferredTaskTitle }
        if !record.projectName.isEmpty { return record.projectName }
        return "\(record.provider.displayName) session"
    }

    private static func bundleTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func uniqueMarkdownFilename(
        for record: ConversationRecord,
        title: String,
        used: inout Set<String>
    ) -> String {
        let slugTitle = slugify(title)
        let shortId = String(record.id.suffix(8)).filter { $0.isLetter || $0.isNumber }
        var base = "\(record.provider.rawValue)-\(slugTitle)-\(shortId)"
        if base.count > 120 { base = String(base.prefix(120)) }
        var candidate = "\(base).md"
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(counter).md"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "session" : String(trimmed.prefix(60))
    }

    private static func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

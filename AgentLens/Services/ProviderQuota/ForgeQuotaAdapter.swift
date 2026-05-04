import Foundation
import SQLite3

// MARK: - Forge Quota Adapter

/// Reports real Forge coding agent activity from its local SQLite database.
///
/// ## Ground truth sources
///
/// 1. **`~/forge/.forge.db`** — SQLite database with conversation metadata:
///    - `conversations` table: conversation_id, title, created_at, updated_at, metrics (JSON)
///    - Metrics JSON contains: started_at, files_changed (lines_added, lines_removed, tool)
///
/// 2. **`~/forge/.forge.toml`** — TOML config with:
///    - `[session]` provider_id, model_id
///    - `max_tokens`, `top_p`, `top_k`
///
/// 3. **`~/forge/.forge_history`** — Command history
///
/// ## Token tracking
/// Forge routes all API calls through the local BurnBar HTTP gateway
/// (default: `http://127.0.0.1:8317/v1/chat/completions`). Actual token counts
/// are tracked by the gateway/daemon. This adapter reports Forge-specific
/// metadata: conversation counts, active model, and file change statistics.
///
/// ## Data returned
/// - Session count (active conversations)
/// - Recent activity (files changed, line counts)
/// - Active model and provider from config
/// - Per-conversation file change metrics
///
/// Reference: Forge CLI (forgecode.dev), SQLite schema reverse-engineered 2026-05-03.

struct ForgeQuotaAdapter: ProviderQuotaAdapter {

    // MARK: - Constants

    private static let forgeDBPath = ("~/forge/.forge.db" as NSString).expandingTildeInPath
    private static let forgeTOMLPath = ("~/forge/.forge.toml" as NSString).expandingTildeInPath
    private static let forgeHistoryPath = ("~/forge/.forge_history" as NSString).expandingTildeInPath

    // MARK: - Fetch

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let metadata = readForgeMetadata()

        guard metadata.hasData else {
            return ProviderQuotaSnapshot(
                provider: .forgeDev,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: "https://forgecode.dev",
                statusMessage: "Forge not detected. Install at forgecode.dev.",
                buckets: []
            )
        }

        var buckets: [ProviderQuotaBucket] = []

        // Session count bucket
        buckets.append(ProviderQuotaBucket(
            key: "forge-sessions",
            label: "Conversations",
            windowKind: .lifetime,
            usedValue: Double(metadata.conversationCount),
            limitValue: Double(metadata.maxConversations > 0 ? metadata.maxConversations : 100),
            remainingValue: nil,
            usedPercent: metadata.maxConversations > 0
                ? Double(metadata.conversationCount) / Double(metadata.maxConversations) * 100
                : 0,
            resetsAt: nil,
            unit: .sessions,
            isEstimated: false
        ))

        // Files changed bucket (from recent conversations)
        if metadata.totalLinesChanged > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "forge-files",
                label: "Lines changed",
                windowKind: .lifetime,
                usedValue: Double(metadata.totalLinesChanged),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: 0,
                resetsAt: nil,
                unit: .lines,
                isEstimated: false
            ))
        }

        // Files modified bucket
        if metadata.uniqueFilesChanged > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "forge-files-modified",
                label: "Files modified",
                windowKind: .lifetime,
                usedValue: Double(metadata.uniqueFilesChanged),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: 0,
                resetsAt: nil,
                unit: .files,
                isEstimated: false
            ))
        }

        let modelLabel = [metadata.modelId, metadata.providerId]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " via ")

        return ProviderQuotaSnapshot(
            provider: .forgeDev,
            fetchedAt: Date(),
            source: .localSession,
            confidence: .exact,
            managementURL: "https://forgecode.dev",
            statusMessage: "Forge · \(metadata.conversationCount) conversations"
                + (modelLabel.isEmpty ? "" : " · \(modelLabel)")
                + (metadata.totalLinesChanged > 0 ? " · \(metadata.totalLinesChanged) lines changed" : ""),
            buckets: buckets
        )
    }

    // MARK: - Metadata Reading

    private struct ForgeMetadata {
        let conversationCount: Int
        let maxConversations: Int
        let totalLinesChanged: Int
        let uniqueFilesChanged: Int
        let modelId: String?
        let providerId: String?

        var hasData: Bool {
            // Forge is "detected" if the DB exists and has conversations,
            // OR if the TOML config exists (installed but no conversations yet)
            conversationCount > 0
                || FileManager.default.fileExists(atPath: forgeTOMLPath)
                || FileManager.default.fileExists(atPath: forgeDBPath)
        }
    }

    private func readForgeMetadata() -> ForgeMetadata {
        var conversationCount = 0
        var maxConversations = 100
        var totalLinesChanged = 0
        var uniqueFiles = Set<String>()
        var modelId: String?
        var providerId: String?

        // Read SQLite DB
        if FileManager.default.fileExists(atPath: Self.forgeDBPath) {
            var db: OpaquePointer?
            if sqlite3_open(Self.forgeDBPath, &db) == SQLITE_OK, let db = db {
                defer { sqlite3_close(db) }

                // Count conversations
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM conversations", -1, &stmt, nil) == SQLITE_OK {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        conversationCount = Int(sqlite3_column_int64(stmt, 0))
                    }
                    sqlite3_finalize(stmt)
                }

                // Parse metrics for file changes
                if sqlite3_prepare_v2(db,
                    "SELECT metrics FROM conversations WHERE metrics IS NOT NULL AND metrics != ''",
                    -1, &stmt, nil) == SQLITE_OK {
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let text = sqlite3_column_text(stmt, 0) {
                            let jsonStr = String(cString: text)
                            if let data = jsonStr.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let filesChanged = json["files_changed"] as? [String: [String: Any]] {
                                for (path, changes) in filesChanged {
                                    uniqueFiles.insert(path)
                                    totalLinesChanged += (changes["lines_added"] as? Int ?? 0)
                                    totalLinesChanged += (changes["lines_removed"] as? Int ?? 0)
                                }
                            }
                        }
                    }
                    sqlite3_finalize(stmt)
                }
            }
        }

        // Read TOML config for model/provider
        if FileManager.default.fileExists(atPath: Self.forgeTOMLPath),
           let tomlContent = try? String(contentsOfFile: Self.forgeTOMLPath, encoding: .utf8) {
            // Simple TOML parsing for [session] section
            var inSession = false
            for line in tomlContent.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "[session]" {
                    inSession = true
                    continue
                }
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    inSession = false
                    continue
                }
                if inSession {
                    if trimmed.hasPrefix("model_id") {
                        modelId = extractTOMLValue(trimmed)
                    }
                    if trimmed.hasPrefix("provider_id") {
                        providerId = extractTOMLValue(trimmed)
                    }
                    if trimmed.hasPrefix("max_conversations") {
                        maxConversations = Int(extractTOMLValue(trimmed) ?? "") ?? maxConversations
                    }
                }
            }
        }

        return ForgeMetadata(
            conversationCount: conversationCount,
            maxConversations: maxConversations,
            totalLinesChanged: totalLinesChanged,
            uniqueFilesChanged: uniqueFiles.count,
            modelId: modelId,
            providerId: providerId
        )
    }

    private func extractTOMLValue(_ line: String) -> String? {
        guard let eqIndex = line.firstIndex(of: "=") else { return nil }
        let valuePart = line[line.index(after: eqIndex)...]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        return valuePart.isEmpty ? nil : valuePart
    }
}

import Foundation
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

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

public struct ForgeQuotaAdapter: ProviderQuotaAdapter {
    public init() {}

    // MARK: - Constants

    private static var candidateDBPaths: [String] {
        [
            ("~/.forge/.forge.db" as NSString).expandingTildeInPath,
            ("~/.forge/database.sqlite" as NSString).expandingTildeInPath,
            ("~/.forge/forge.db" as NSString).expandingTildeInPath,
            ("~/.forge/sessions/.forge.db" as NSString).expandingTildeInPath,
            ("~/forge/.forge.db" as NSString).expandingTildeInPath,
            ("~/.forge.db" as NSString).expandingTildeInPath
        ]
    }

    private static var candidateTOMLPaths: [String] {
        [
            ("~/.forge/.forge.toml" as NSString).expandingTildeInPath,
            ("~/.forge/forge.toml" as NSString).expandingTildeInPath,
            ("~/forge/.forge.toml" as NSString).expandingTildeInPath,
            ("~/.forge.toml" as NSString).expandingTildeInPath
        ]
    }

    // MARK: - Fetch

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
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
        let detected: Bool

        var hasData: Bool {
            conversationCount > 0 || detected
        }
    }

    private func readForgeMetadata() -> ForgeMetadata {
        var conversationCount = 0
        var maxConversations = 100
        var totalLinesChanged = 0
        var uniqueFiles = Set<String>()
        var modelId: String?
        var providerId: String?
        var detected = false

        for dbPath in Self.candidateDBPaths {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            detected = true
            do {
                let reader = try SQLiteConnection.openReadOnly(path: dbPath)
                defer { reader.close() }
                let countRows = try reader.query("SELECT COUNT(*) AS c FROM conversations", arguments: [])
                if let row = countRows.first, let n = row.int64("c") ?? row.int("c").map(Int64.init) {
                    conversationCount = Int(n)
                }
                let metricRows = try reader.query(
                    "SELECT metrics FROM conversations WHERE metrics IS NOT NULL AND metrics != ''",
                    arguments: []
                )
                for row in metricRows {
                    guard let jsonStr = row.string("metrics"), !jsonStr.isEmpty else { continue }
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
                break
            } catch {
                // Best-effort local metadata; omit DB-derived buckets when unreadable.
            }
        }

        // Read TOML config for model/provider
        for tomlPath in Self.candidateTOMLPaths {
            guard FileManager.default.fileExists(atPath: tomlPath),
                  let tomlContent = try? String(contentsOfFile: tomlPath, encoding: .utf8) else { continue }
            detected = true
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
            break
        }

        return ForgeMetadata(
            conversationCount: conversationCount,
            maxConversations: maxConversations,
            totalLinesChanged: totalLinesChanged,
            uniqueFilesChanged: uniqueFiles.count,
            modelId: modelId,
            providerId: providerId,
            detected: detected
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

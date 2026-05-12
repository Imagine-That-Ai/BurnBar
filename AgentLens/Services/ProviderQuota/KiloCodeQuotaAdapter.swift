import Foundation

// MARK: - Kilo Code Quota Adapter

/// Reports real Kilo Code usage from VS Code/Cursor/Windsurf extension storage.
///
/// ## Ground truth source
///
/// Kilo Code (VS Code extension) stores task data under:
/// `~/Library/Application Support/{host}/User/globalStorage/kilocode.kilo-code/tasks/`
///
/// Where `{host}` is one of: Code, Cursor, Code - Insiders, Windsurf - Next.
///
/// Each task directory contains:
/// - `ui_messages.json` — array of UI messages including `api_req_started` events
///   with `tokensIn`, `tokensOut`, `cacheWrites`, `cacheReads`, `cost`
/// - `api_conversation_history.json` — conversation messages
///
/// ## Data returned
/// - Task count
/// - Total tokens: input, output, cache writes, cache reads
/// - Estimated cost in USD
///
/// Verified: 1 task on this machine via Cursor globalStorage.

struct KiloCodeQuotaAdapter: ProviderQuotaAdapter {

    private static let extensionID = "kilocode.kilo-code"

    // Host directories to search
    private static let hostDirs: [String] = [
        "Code",
        "Cursor",
        "Code - Insiders",
        "Windsurf - Next",
    ]

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let tasksDir = findTasksDirectory()

        guard let tasksDir, FileManager.default.fileExists(atPath: tasksDir) else {
            return ProviderQuotaSnapshot(
                provider: .kiloCode,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: "vscode:extension/kilocode.kilo-code",
                statusMessage: "Kilo Code not detected. Install the VS Code extension.",
                buckets: []
            )
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: tasksDir) else {
            return ProviderQuotaSnapshot(
                provider: .kiloCode,
                fetchedAt: Date(),
                source: .localSession,
                confidence: .exact,
                managementURL: nil,
                statusMessage: "Kilo Code · No tasks yet",
                buckets: []
            )
        }

        let taskIDs = contents.filter { !$0.hasPrefix(".") }
        var totalInput: Int64 = 0
        var totalOutput: Int64 = 0
        var totalCacheWrites: Int64 = 0
        var totalCacheReads: Int64 = 0
        var totalCost: Double = 0

        for taskID in taskIDs {
            let uiMessagesPath = "\(tasksDir)/\(taskID)/ui_messages.json"
            guard FileManager.default.fileExists(atPath: uiMessagesPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: uiMessagesPath)),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }

            for message in messages {
                guard let type = message["type"] as? String,
                      type == "say",
                      let say = message["say"] as? String,
                      say == "api_req_started",
                      let text = message["text"] as? String,
                      let jsonData = text.data(using: .utf8),
                      let apiReq = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    continue
                }

                totalInput += (apiReq["tokensIn"] as? Int64) ?? 0
                totalOutput += (apiReq["tokensOut"] as? Int64) ?? 0
                totalCacheWrites += (apiReq["cacheWrites"] as? Int64) ?? 0
                totalCacheReads += (apiReq["cacheReads"] as? Int64) ?? 0
                totalCost += (apiReq["cost"] as? Double) ?? 0
            }
        }

        let totalTokens = totalInput + totalOutput + totalCacheWrites + totalCacheReads
        var buckets: [ProviderQuotaBucket] = []

        buckets.append(ProviderQuotaBucket(
            key: "kilo-tasks",
            label: "Tasks",
            windowKind: .lifetime,
            usedValue: Double(taskIDs.count),
            limitValue: nil,
            remainingValue: nil,
            usedPercent: 0,
            resetsAt: nil,
            unit: .sessions,
            isEstimated: false
        ))

        if totalTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "kilo-tokens",
                label: "Total tokens",
                windowKind: .lifetime,
                usedValue: Double(totalTokens),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: 0,
                resetsAt: nil,
                unit: .tokens,
                isEstimated: false
            ))
        }

        let costLabel = totalCost > 0 ? String(format: " · $%.4f est.", totalCost) : ""

        return ProviderQuotaSnapshot(
            provider: .kiloCode,
            fetchedAt: Date(),
            source: .localSession,
            confidence: .exact,
            managementURL: nil,
            statusMessage: "Kilo Code · \(taskIDs.count) tasks · \(formatCount(totalTokens)) tokens\(costLabel)",
            buckets: buckets
        )
    }

    // MARK: - Helpers

    private func findTasksDirectory() -> String? {
        let appSupport = ("~/Library/Application Support" as NSString).expandingTildeInPath
        for host in Self.hostDirs {
            let path = "\(appSupport)/\(host)/User/globalStorage/\(Self.extensionID)/tasks"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func formatCount(_ count: Int64) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.2fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

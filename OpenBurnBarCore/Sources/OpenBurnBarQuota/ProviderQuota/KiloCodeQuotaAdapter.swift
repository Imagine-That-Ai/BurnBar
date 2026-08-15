import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

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
/// - `api_conversation_history.json` — conversation messages (never cached)
///
/// ## Data returned
/// - Task count
/// - Total tokens: input, output, cache writes, cache reads
/// - Estimated cost in USD
///
/// Unchanged `ui_messages.json` files resume from a mtime+size disk cache of
/// **quota totals only**. Conversation bodies are not stored.
///
/// Verified: 1 task on this machine via Cursor globalStorage.

public struct KiloCodeQuotaAdapter: ProviderQuotaAdapter {
    private let tasksDirectoryOverride: URL?
    private let cacheURLOverride: URL?
    private let contentReadCount = Locked(0)

    public init(
        tasksDirectoryOverride: URL? = nil,
        cacheURLOverride: URL? = nil
    ) {
        self.tasksDirectoryOverride = tasksDirectoryOverride
        self.cacheURLOverride = cacheURLOverride
    }

    var lastContentReadCount: Int { contentReadCount.read() }

    private static let extensionID = "kilocode.kilo-code"

    // Host directories to search
    private static let hostDirs: [String] = [
        "Code",
        "Cursor",
        "Code - Insiders",
        "Windsurf - Next"
    ]

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        contentReadCount.write(0)
        let fm = context.fileManager
        let tasksDir = findTasksDirectory(context: context)

        guard let tasksDir, fm.fileExists(atPath: tasksDir.path) else {
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

        guard let taskURLs = try? fm.contentsOfDirectory(
            at: tasksDir,
            includingPropertiesForKeys: FileSignature.directoryListingPrefetchKeys,
            options: [.skipsHiddenFiles]
        ) else { // try?-ok(no tasks, skip)
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

        let taskIDs = taskURLs.map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
        let cacheStore = ParserDiskCacheStore<KiloTaskQuotaCacheEntry>(
            cacheURL: cacheURL(context: context, tasksDir: tasksDir),
            fileManager: fm,
            schemaVersion: 1,
            logLabel: "KiloCodeQuotaAdapter"
        )
        var parseCache = cacheStore.load()
        var cacheMutated = false
        var activeKeys = Set<String>()

        var totalInput: Int64 = 0
        var totalOutput: Int64 = 0
        var totalCacheWrites: Int64 = 0
        var totalCacheReads: Int64 = 0
        var totalCost: Double = 0

        for taskURL in taskURLs where !taskURL.lastPathComponent.hasPrefix(".") {
            let uiMessagesURL = taskURL.appendingPathComponent("ui_messages.json")
            let cacheKey = uiMessagesURL.standardizedFileURL.path
            guard let signature = FileSignature(for: uiMessagesURL, using: fm) else { continue }
            activeKeys.insert(cacheKey)
            if let cached = parseCache.fileEntries[cacheKey], cached.signature == signature {
                totalInput += cached.totals.input
                totalOutput += cached.totals.output
                totalCacheWrites += cached.totals.cacheWrites
                totalCacheReads += cached.totals.cacheReads
                totalCost += cached.totals.cost
                continue
            }

            guard let totals = readTotals(from: uiMessagesURL, fileManager: fm) else { continue }
            parseCache.fileEntries[cacheKey] = KiloTaskQuotaCacheEntry(signature: signature, totals: totals)
            cacheMutated = true
            totalInput += totals.input
            totalOutput += totals.output
            totalCacheWrites += totals.cacheWrites
            totalCacheReads += totals.cacheReads
            totalCost += totals.cost
        }

        let staleKeys = parseCache.fileEntries.keys.filter { !activeKeys.contains($0) }
        if !staleKeys.isEmpty {
            parseCache.prune(staleKeys: Array(staleKeys))
            cacheMutated = true
        }
        if cacheMutated {
            cacheStore.persist(parseCache)
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

    private func findTasksDirectory(context: ProviderQuotaAdapterContext) -> URL? {
        if let tasksDirectoryOverride {
            return tasksDirectoryOverride
        }
        let appSupport = context.homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        for host in Self.hostDirs {
            let path = appSupport
                .appendingPathComponent(host, isDirectory: true)
                .appendingPathComponent("User/globalStorage/\(Self.extensionID)/tasks", isDirectory: true)
            if context.fileManager.fileExists(atPath: path.path) {
                return path
            }
        }
        return nil
    }

    private func cacheURL(context: ProviderQuotaAdapterContext, tasksDir: URL) -> URL {
        if let cacheURLOverride { return cacheURLOverride }
        if tasksDirectoryOverride != nil {
            return tasksDir.appendingPathComponent(".obb-kilo-quota-cache.plist")
        }
        return context.appPaths.kiloCodeQuotaCacheURL
    }

    private func readTotals(from url: URL, fileManager: FileManager) -> KiloTaskQuotaTotals? {
        contentReadCount.withLock { $0 += 1 }
        guard let data = try? Data(contentsOf: url), // try?-ok(sidecar read, skip)
              let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { // try?-ok(malformed json, skip)
            return nil
        }

        var totals = KiloTaskQuotaTotals()
        for message in messages {
            guard let type = message["type"] as? String,
                  type == "say",
                  let say = message["say"] as? String,
                  say == "api_req_started",
                  let text = message["text"] as? String,
                  let jsonData = text.data(using: .utf8),
                  let apiReq = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { // try?-ok(malformed json, skip)
                continue
            }

            totals.input += int64(apiReq["tokensIn"])
            totals.output += int64(apiReq["tokensOut"])
            totals.cacheWrites += int64(apiReq["cacheWrites"])
            totals.cacheReads += int64(apiReq["cacheReads"])
            totals.cost += doubleValue(apiReq["cost"])
        }
        return totals
    }

    private func int64(_ value: Any?) -> Int64 {
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        if let number = value as? NSNumber { return number.int64Value }
        if let number = value as? Double { return Int64(number) }
        return 0
    }

    private func doubleValue(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Int64 { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return 0
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

struct KiloTaskQuotaTotals: Codable, Equatable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheWrites: Int64 = 0
    var cacheReads: Int64 = 0
    var cost: Double = 0
}

struct KiloTaskQuotaCacheEntry: Codable, Equatable, Sendable {
    var signature: FileSignature
    var totals: KiloTaskQuotaTotals
}

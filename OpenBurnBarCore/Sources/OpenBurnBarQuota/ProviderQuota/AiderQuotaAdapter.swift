import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

// MARK: - Aider Quota Adapter

/// Surfaces Aider token usage and cost data from the analytics JSONL log.
///
/// Ground truth: `~/.aider/analytics.jsonl` — Aider's own analytics system
/// configured via `.aider.conf.yml` with `analytics-log: ~/.aider/analytics.jsonl`.
///
/// Aider has no rate limits — it uses your own API keys for each model provider.
/// This adapter reports real token usage and cost, with no "quota" concept.
///
/// Unchanged analytics files resume from a mtime+size disk cache of **quota
/// facts only** (`time`, tokens, cost) plus a byte offset past the last
/// terminated line. Window membership (today / this month) is recomputed at
/// fetch time. JSONL line text, prompts, and conversation bodies are not stored.
///
/// Reference: `AiderParser.swift` in UsageAggregatorParsers (same data source).

public struct AiderQuotaAdapter: ProviderQuotaAdapter {
    private let analyticsDirectoryOverride: URL?
    private let cacheURLOverride: URL?
    private let contentReadCount = Locked(0)

    public init(
        analyticsDirectoryOverride: URL? = nil,
        cacheURLOverride: URL? = nil
    ) {
        self.analyticsDirectoryOverride = analyticsDirectoryOverride
        self.cacheURLOverride = cacheURLOverride
    }

    var lastContentReadCount: Int { contentReadCount.read() }

    private static let headPrefixSpan = 4096

    // MARK: - Public API

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        contentReadCount.write(0)
        let fm = context.fileManager
        let analyticsFiles = findAnalyticsFiles(fileManager: fm, homeDirectoryURL: context.homeDirectoryURL)

        guard !analyticsFiles.isEmpty else {
            return ProviderQuotaSnapshot(
                provider: .aider,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: nil,
                statusMessage: "Aider analytics log not found. Add `analytics-log: ~/.aider/analytics.jsonl` to .aider.conf.yml to enable tracking.",
                buckets: []
            )
        }

        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? now

        let aiderDir = analyticsDirectoryOverride
            ?? context.homeDirectoryURL.appendingPathComponent(".aider", isDirectory: true)
        let cacheStore = ParserDiskCacheStore<AiderQuotaCacheEntry>(
            cacheURL: cacheURL(context: context, analyticsDirectory: aiderDir),
            fileManager: fm,
            schemaVersion: 1,
            logLabel: "AiderQuotaAdapter"
        )
        var parseCache = cacheStore.load()
        var cacheMutated = false
        var activeKeys = Set<String>()

        var dailyTokens = 0
        var dailyCost = 0.0
        var monthlyTokens = 0
        var monthlyCost = 0.0
        var sessionsFound = 0
        var latestTimestamp: Date?

        for (fileURL, signature) in analyticsFiles {
            let cacheKey = fileURL.standardizedFileURL.path
            activeKeys.insert(cacheKey)

            let scanned = scanFile(
                fileURL,
                signature: signature,
                cached: parseCache.fileEntries[cacheKey]
            )
            if scanned.didReadContent {
                contentReadCount.withLock { $0 += 1 }
            }
            if scanned.entry != parseCache.fileEntries[cacheKey] {
                parseCache.fileEntries[cacheKey] = scanned.entry
                cacheMutated = true
            }

            sessionsFound += scanned.sessionCount
            for fact in scanned.facts {
                guard let time = fact.time else { continue }
                let timestamp = Date(timeIntervalSince1970: time)
                latestTimestamp = max(timestamp, latestTimestamp ?? .distantPast)
                if timestamp >= startOfDay {
                    dailyTokens += fact.tokens
                    dailyCost += fact.cost
                }
                if timestamp >= startOfMonth {
                    monthlyTokens += fact.tokens
                    monthlyCost += fact.cost
                }
            }
        }

        let staleKeys = parseCache.fileEntries.keys.filter { !activeKeys.contains($0) }
        if !staleKeys.isEmpty {
            parseCache.prune(staleKeys: Array(staleKeys))
            cacheMutated = true
        }
        if cacheMutated {
            cacheStore.persist(parseCache)
        }

        var buckets: [ProviderQuotaBucket] = []

        if dailyTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "aider-daily-tokens",
                label: "Today's tokens",
                windowKind: .daily,
                usedValue: Double(dailyTokens),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: calendar.date(byAdding: .day, value: 1, to: startOfDay),
                unit: .tokens,
                isEstimated: false
            ))
        }

        if monthlyTokens > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "aider-monthly-tokens",
                label: "This month's tokens",
                windowKind: .monthly,
                usedValue: Double(monthlyTokens),
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: nextMonth,
                unit: .tokens,
                isEstimated: false
            ))
        }

        // Cost bucket (in USD)
        let costDisplay = dailyCost > 0
            ? String(format: "$%.2f today", dailyCost)
            : String(format: "$%.2f this month", monthlyCost)
        if monthlyCost > 0 {
            buckets.append(ProviderQuotaBucket(
                key: "aider-monthly-cost",
                label: "Estimated cost",
                windowKind: .monthly,
                usedValue: monthlyCost,
                limitValue: nil,
                remainingValue: nil,
                usedPercent: nil,
                resetsAt: nextMonth,
                unit: .count,
                isEstimated: false
            ))
        }

        let statusMessage: String
        if !buckets.isEmpty {
            statusMessage = "Aider analytics: \(sessionsFound) session(s) tracked. \(costDisplay). No rate limits — your API keys are billed directly."
        } else {
            statusMessage = "Aider analytics log found but no token usage recorded yet."
        }

        return ProviderQuotaSnapshot(
            provider: .aider,
            fetchedAt: latestTimestamp ?? Date(),
            source: .localSession,
            confidence: buckets.isEmpty ? .unavailable : .exact,
            managementURL: nil,
            statusMessage: statusMessage,
            buckets: buckets
        )
    }

    // MARK: - File Discovery

    private func findAnalyticsFiles(
        fileManager: FileManager,
        homeDirectoryURL: URL
    ) -> [(url: URL, signature: FileSignature)] {
        let aiderDir = analyticsDirectoryOverride
            ?? homeDirectoryURL.appendingPathComponent(".aider", isDirectory: true)
        return ["analytics.jsonl", "analytics.json"].compactMap { name in
            let url = aiderDir.appendingPathComponent(name)
            guard let signature = FileSignature(for: url, using: fileManager) else { return nil }
            return (url, signature)
        }
    }

    private func cacheURL(context: ProviderQuotaAdapterContext, analyticsDirectory: URL) -> URL {
        if let cacheURLOverride { return cacheURLOverride }
        if analyticsDirectoryOverride != nil {
            return analyticsDirectory.appendingPathComponent(".obb-aider-quota-cache.plist")
        }
        return context.appPaths.aiderQuotaCacheURL
    }

    private func scanFile(
        _ fileURL: URL,
        signature: FileSignature,
        cached: AiderQuotaCacheEntry?
    ) -> (facts: [AiderQuotaFact], sessionCount: Int, entry: AiderQuotaCacheEntry, didReadContent: Bool) {
        if let cached, cached.signature == signature {
            return (cached.facts, cached.sessionCount, cached, false)
        }

        if let cached, let resumed = resumeAppendIfPossible(
            fileURL: fileURL,
            signature: signature,
            cached: cached
        ) {
            return resumed
        }

        return fullScan(fileURL: fileURL, signature: signature)
    }

    private func resumeAppendIfPossible(
        fileURL: URL,
        signature: FileSignature,
        cached: AiderQuotaCacheEntry
    ) -> (facts: [AiderQuotaFact], sessionCount: Int, entry: AiderQuotaCacheEntry, didReadContent: Bool)? {
        guard signature.sizeBytes >= cached.signature.sizeBytes,
              cached.byteOffset >= 0,
              cached.byteOffset <= signature.sizeBytes,
              !cached.headPrefix.isEmpty,
              cached.headPrefix.count <= signature.sizeBytes else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil } // try?-ok(append probe)
        defer { try? handle.close() } // try?-ok(handle teardown)

        try? handle.seek(toOffset: 0) // try?-ok(seek 0 before head read)
        let observedHead = handle.readData(ofLength: cached.headPrefix.count)
        guard observedHead == cached.headPrefix else { return nil }

        if cached.byteOffset == signature.sizeBytes {
            let entry = AiderQuotaCacheEntry(
                signature: signature,
                byteOffset: cached.byteOffset,
                headPrefix: cached.headPrefix,
                facts: cached.facts,
                sessionCount: cached.sessionCount,
                openSessionTokens: cached.openSessionTokens
            )
            return (cached.facts, cached.sessionCount, entry, false)
        }

        do {
            try handle.seek(toOffset: UInt64(cached.byteOffset))
        } catch {
            return nil
        }
        let reduced = reduceLines(
            handle: handle,
            startOffset: cached.byteOffset,
            facts: cached.facts,
            sessionCount: cached.sessionCount,
            openSessionTokens: cached.openSessionTokens
        )
        let entry = AiderQuotaCacheEntry(
            signature: signature,
            byteOffset: reduced.persistedOffset,
            headPrefix: cached.headPrefix,
            facts: reduced.persistedFacts,
            sessionCount: reduced.persistedSessionCount,
            openSessionTokens: reduced.persistedOpenSessionTokens
        )
        return (reduced.snapshotFacts, reduced.snapshotSessionCount, entry, true)
    }

    private func fullScan(
        fileURL: URL,
        signature: FileSignature
    ) -> (facts: [AiderQuotaFact], sessionCount: Int, entry: AiderQuotaCacheEntry, didReadContent: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { // try?-ok(skip unreadable analytics file)
            let entry = AiderQuotaCacheEntry(
                signature: signature,
                byteOffset: 0,
                headPrefix: Data(),
                facts: [],
                sessionCount: 0,
                openSessionTokens: 0
            )
            return ([], 0, entry, false)
        }
        defer { try? handle.close() } // try?-ok(handle teardown)

        let headLength = Int(min(Int64(Self.headPrefixSpan), max(signature.sizeBytes, 0)))
        try? handle.seek(toOffset: 0) // try?-ok(seek 0 before head read)
        let headPrefix = handle.readData(ofLength: headLength)
        try? handle.seek(toOffset: 0) // try?-ok(rewind after head)

        let reduced = reduceLines(
            handle: handle,
            startOffset: 0,
            facts: [],
            sessionCount: 0,
            openSessionTokens: 0
        )
        let entry = AiderQuotaCacheEntry(
            signature: signature,
            byteOffset: reduced.persistedOffset,
            headPrefix: headPrefix,
            facts: reduced.persistedFacts,
            sessionCount: reduced.persistedSessionCount,
            openSessionTokens: reduced.persistedOpenSessionTokens
        )
        return (reduced.snapshotFacts, reduced.snapshotSessionCount, entry, true)
    }

    private func reduceLines(
        handle: FileHandle,
        startOffset: Int64,
        facts: [AiderQuotaFact],
        sessionCount: Int,
        openSessionTokens: Int
    ) -> (
        snapshotFacts: [AiderQuotaFact],
        snapshotSessionCount: Int,
        persistedFacts: [AiderQuotaFact],
        persistedSessionCount: Int,
        persistedOpenSessionTokens: Int,
        persistedOffset: Int64
    ) {
        var persistedFacts = facts
        var persistedSessionCount = sessionCount
        var persistedOpenSessionTokens = openSessionTokens
        var persistedOffset = startOffset
        var snapshotFacts = facts
        var snapshotSessionCount = sessionCount
        var snapshotOpenSessionTokens = openSessionTokens

        let reader = BufferedLineReader(fileHandle: handle, startOffset: startOffset)
        while let line = reader.nextLine() {
            if line.isTerminated {
                Self.reduceLine(
                    line.text,
                    facts: &persistedFacts,
                    sessionCount: &persistedSessionCount,
                    openSessionTokens: &persistedOpenSessionTokens
                )
                persistedOffset = line.endOffset
                snapshotFacts = persistedFacts
                snapshotSessionCount = persistedSessionCount
                snapshotOpenSessionTokens = persistedOpenSessionTokens
            } else {
                snapshotFacts = persistedFacts
                snapshotSessionCount = persistedSessionCount
                snapshotOpenSessionTokens = persistedOpenSessionTokens
                Self.reduceLine(
                    line.text,
                    facts: &snapshotFacts,
                    sessionCount: &snapshotSessionCount,
                    openSessionTokens: &snapshotOpenSessionTokens
                )
            }
        }
        _ = snapshotOpenSessionTokens
        return (
            snapshotFacts,
            snapshotSessionCount,
            persistedFacts,
            persistedSessionCount,
            persistedOpenSessionTokens,
            persistedOffset
        )
    }

    private static func reduceLine(
        _ text: String,
        facts: inout [AiderQuotaFact],
        sessionCount: inout Int,
        openSessionTokens: inout Int
    ) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(skip malformed JSONL line)
              let event = json["event"] as? String else { return }

        let time = jsonTime(json["time"])

        switch event {
        case "message_send":
            let props = json["properties"] as? [String: Any] ?? [:]
            let promptTokens = jsonInt(props["prompt_tokens"])
            let completionTokens = jsonInt(props["completion_tokens"])
            let cost = jsonDouble(props["cost"])
            let total = promptTokens + completionTokens

            openSessionTokens += total
            facts.append(AiderQuotaFact(time: time, tokens: total, cost: cost))

        case "exit", "launched", "cli session":
            if openSessionTokens > 0 { sessionCount += 1 }
            openSessionTokens = 0

        default:
            break
        }
    }

    private static func jsonInt(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Double { return Int(number) }
        return 0
    }

    private static func jsonDouble(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Int64 { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return 0
    }

    private static func jsonTime(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Int64 { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

struct AiderQuotaFact: Codable, Equatable, Sendable {
    var time: Double?
    var tokens: Int
    var cost: Double
}

struct AiderQuotaCacheEntry: Codable, Equatable, Sendable {
    var signature: FileSignature
    var byteOffset: Int64
    var headPrefix: Data
    var facts: [AiderQuotaFact]
    var sessionCount: Int
    var openSessionTokens: Int
}

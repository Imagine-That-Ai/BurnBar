import Foundation

// MARK: - Aider Quota Adapter

/// Surfaces Aider token usage and cost data from the analytics JSONL log.
///
/// Ground truth: `~/.aider/analytics.jsonl` — Aider's own analytics system
/// configured via `.aider.conf.yml` with `analytics-log: ~/.aider/analytics.jsonl`.
///
/// Aider has no rate limits — it uses your own API keys for each model provider.
/// This adapter reports real token usage and cost, with no "quota" concept.
///
/// Reference: `AiderParser.swift` in UsageAggregatorParsers (same data source).

struct AiderQuotaAdapter: ProviderQuotaAdapter {

    // MARK: - Public API

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let analyticsFiles = findAnalyticsFiles(fileManager: context.fileManager)

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

        var dailyTokens = 0
        var dailyCost = 0.0
        var monthlyTokens = 0
        var monthlyCost = 0.0
        var sessionsFound = 0
        var latestTimestamp: Date?

        for fileURL in analyticsFiles {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }

            var currentSessionTokens = 0
            var currentSessionCost = 0.0

            for line in handle.readAllUTF8Lines() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = json["event"] as? String else { continue }

                let time = json["time"] as? Double
                let timestamp = time.map { Date(timeIntervalSince1970: $0) }

                switch event {
                case "message_send":
                    let props = json["properties"] as? [String: Any] ?? [:]
                    let promptTokens = props["prompt_tokens"] as? Int ?? 0
                    let completionTokens = props["completion_tokens"] as? Int ?? 0
                    let cost = props["cost"] as? Double ?? 0
                    let total = promptTokens + completionTokens

                    currentSessionTokens += total
                    currentSessionCost += cost

                    if let ts = timestamp {
                        latestTimestamp = max(ts, latestTimestamp ?? .distantPast)
                        if ts >= startOfDay {
                            dailyTokens += total
                            dailyCost += cost
                        }
                        if ts >= startOfMonth {
                            monthlyTokens += total
                            monthlyCost += cost
                        }
                    }

                case "exit", "launched", "cli session":
                    if currentSessionTokens > 0 { sessionsFound += 1 }
                    currentSessionTokens = 0
                    currentSessionCost = 0

                default:
                    break
                }
            }
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

    private func findAnalyticsFiles(fileManager: FileManager) -> [URL] {
        let candidatePaths = [
            ("~/.aider/analytics.jsonl" as NSString).expandingTildeInPath,
            ("~/.aider/analytics.json" as NSString).expandingTildeInPath,
        ]

        return candidatePaths.compactMap { path in
            guard fileManager.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}

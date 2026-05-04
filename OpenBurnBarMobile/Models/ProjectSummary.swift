import Foundation
import OpenBurnBarCore

// MARK: - Project Summary
//
// In-memory aggregate built from `users/{uid}/usage` documents grouped by
// `projectName`. Stored as a value type so views diff cleanly.

struct ProjectSummary: Identifiable, Hashable, Sendable {
    let id: String          // projectName (lowercased) — stable diffing key
    let projectName: String // display
    let sessions: Int
    let totalTokens: Int
    let totalCost: Double
    let dominantProvider: AgentProvider?
    let topModel: String?
    let lastSeen: Date
    let dailyTokens: [Date: Int] // last 14 days

    var sortedDailyPoints: [(date: Date, value: Double)] {
        dailyTokens.sorted { $0.key < $1.key }.map { ($0.key, Double($0.value)) }
    }

    static let placeholder = ProjectSummary(
        id: "—",
        projectName: "—",
        sessions: 0,
        totalTokens: 0,
        totalCost: 0,
        dominantProvider: nil,
        topModel: nil,
        lastSeen: .distantPast,
        dailyTokens: [:]
    )
}

// MARK: - Aggregator (pure, testable)

enum ProjectSummaryAggregator {

    /// Aggregates a list of `TokenUsage` rows into per-project summaries.
    /// Pure function — no Firestore, no main actor, fully testable.
    static func aggregate(_ usages: [TokenUsage], now: Date = Date()) -> [ProjectSummary] {
        // Group by normalized project name (preserve display casing of first occurrence).
        struct Bucket {
            var projectName: String
            var sessions: Set<String>
            var totalTokens: Int
            var totalCost: Double
            var providerTokens: [AgentProvider: Int]
            var modelTokens: [String: Int]
            var lastSeen: Date
            var dailyTokens: [Date: Int]
        }

        var buckets: [String: Bucket] = [:]
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -14, to: now) ?? now

        for usage in usages {
            let raw = usage.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = raw.isEmpty ? "(Untitled)" : raw
            let key = display.lowercased()

            var bucket = buckets[key] ?? Bucket(
                projectName: display,
                sessions: [],
                totalTokens: 0,
                totalCost: 0,
                providerTokens: [:],
                modelTokens: [:],
                lastSeen: .distantPast,
                dailyTokens: [:]
            )

            bucket.sessions.insert(usage.sessionId)
            bucket.totalTokens += usage.totalTokens
            bucket.totalCost += usage.cost
            bucket.providerTokens[usage.provider, default: 0] += usage.totalTokens
            bucket.modelTokens[usage.model, default: 0] += usage.totalTokens
            if usage.startTime > bucket.lastSeen { bucket.lastSeen = usage.startTime }

            if usage.startTime >= cutoff {
                let day = calendar.startOfDay(for: usage.startTime)
                bucket.dailyTokens[day, default: 0] += usage.totalTokens
            }

            buckets[key] = bucket
        }

        return buckets
            .map { key, bucket -> ProjectSummary in
                let provider = bucket.providerTokens.max(by: { $0.value < $1.value })?.key
                let model = bucket.modelTokens.max(by: { $0.value < $1.value })?.key
                return ProjectSummary(
                    id: key,
                    projectName: bucket.projectName,
                    sessions: bucket.sessions.count,
                    totalTokens: bucket.totalTokens,
                    totalCost: bucket.totalCost,
                    dominantProvider: provider,
                    topModel: model,
                    lastSeen: bucket.lastSeen,
                    dailyTokens: bucket.dailyTokens
                )
            }
            .sorted { $0.totalCost > $1.totalCost }
    }
}

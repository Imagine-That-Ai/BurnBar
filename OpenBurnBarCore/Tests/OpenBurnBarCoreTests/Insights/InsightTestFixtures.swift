import Foundation
@testable import OpenBurnBarCore

/// Shared fixtures for the Insights test suites.
enum InsightTestFixtures {

    /// Build a snapshot with two weeks of synthetic usage spanning four
    /// providers, three models, and two projects.
    static func twoWeeksOfUsage(now: Date = Date()) -> InsightDataSnapshot {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
        let start = cal.date(byAdding: .day, value: -14, to: end) ?? now

        var usages: [InsightUsageRow] = []
        var sessions: [InsightSessionRow] = []
        let providers = ["Claude Code", "Codex", "Hermes", "Pi Agent"]
        let models = ["claude-sonnet-4-6", "gpt-5", "hermes-mercury-1"]
        let projects = ["/Users/me/foo", "/Users/me/bar"]

        for day in 0..<14 {
            for hour in stride(from: 9, through: 21, by: 2) {
                guard let date = cal.date(byAdding: .hour, value: day * 24 + hour, to: start) else { continue }
                let sessionID = "session-\(day)-\(hour)"
                let provider = providers[(day + hour) % providers.count]
                let model = models[(day * 3 + hour) % models.count]
                let project = projects[hour % projects.count]
                let session = InsightSessionRow(
                    sessionID: sessionID,
                    provider: provider,
                    projectName: project,
                    startTime: date,
                    endTime: date.addingTimeInterval(900),
                    messageCount: 5 + hour % 4,
                    inferredTaskTitle: hour % 2 == 0 ? "Fix bug in module" : "Refactor data layer",
                    keyTools: ["read", "grep", hour % 2 == 0 ? "git diff" : "pytest"],
                    keyCommands: hour % 3 == 0 ? ["pytest"] : ["git diff"],
                    keyFiles: ["sensitive_file.swift"]
                )
                sessions.append(session)
                usages.append(InsightUsageRow(
                    sessionID: sessionID,
                    provider: provider,
                    model: model,
                    projectName: project,
                    deviceID: "device-A",
                    deviceName: "Alberto's Mac",
                    startTime: date,
                    endTime: date.addingTimeInterval(900),
                    inputTokens: 1200 + day * 50,
                    outputTokens: 600 + day * 25,
                    reasoningTokens: hour % 4 == 0 ? 800 : 0,
                    cacheReadTokens: hour % 3 == 0 ? 1500 : 0,
                    cacheCreationTokens: 100,
                    totalTokens: 0,
                    costUSD: 0.012 + Double(day) * 0.002 + Double(hour) * 0.0005
                ))
            }
        }
        // Backfill totalTokens.
        for i in 0..<usages.count {
            usages[i].totalTokens = usages[i].inputTokens
                + usages[i].outputTokens
                + usages[i].reasoningTokens
                + usages[i].cacheReadTokens
                + usages[i].cacheCreationTokens
        }

        let quota = InsightQuotaBucket(
            providerKey: "anthropic",
            providerDisplayName: "Claude Code",
            bucketName: "5h",
            used: 0.72,
            limit: 1.0,
            resetsAt: now.addingTimeInterval(3600),
            sourceKind: "officialAPI",
            confidence: "high"
        )
        let actions: [InsightOperatingAction] = (0..<8).map { i in
            .init(id: "op-\(i)",
                  actionKind: i % 2 == 0 ? "agent_run" : "tool_call",
                  projectName: projects[i % 2],
                  occurredAt: now.addingTimeInterval(-Double(i) * 3600),
                  summary: "Synthetic operating action #\(i)")
        }
        let summaryRuns: [InsightSummaryRun] = (0..<5).map { i in
            .init(id: "sr-\(i)",
                  providerKey: "anthropic",
                  modelID: "claude-haiku-4-5",
                  costUSD: 0.005,
                  ranAt: now.addingTimeInterval(-Double(i) * 7200))
        }

        return InsightDataSnapshot(
            window: DateInterval(start: start, end: end),
            generatedAt: now,
            usages: usages,
            sessions: sessions,
            quotaBuckets: [quota],
            operatingActions: actions,
            summaryRuns: summaryRuns
        )
    }

    static func emptySnapshot(window: DateInterval) -> InsightDataSnapshot {
        InsightDataSnapshot(window: window, generatedAt: window.end)
    }
}

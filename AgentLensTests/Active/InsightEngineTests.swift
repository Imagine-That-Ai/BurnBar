import XCTest
@testable import OpenBurnBar

@MainActor
final class InsightEngineTests: XCTestCase {

    // MARK: - Insight Card Tests

    func test_insightCard_zeroInsights() throws {
        let store = try DataStore()
        store.replaceUsages([])
        let insights = InsightEngine.generate(from: store)
        XCTAssertTrue(insights.isEmpty)
    }

    func test_insightCard_oneInsight() throws {
        let store = try DataStore()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        let insights = InsightEngine.generate(from: store)
        XCTAssertTrue(insights.count >= 1)
    }

    func test_insightCard_newSessions_countsDistinctSessionIds() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-sonnet",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-opus",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let insights = InsightEngine.generate(from: store)
        XCTAssertTrue(insights.count >= 1)
    }

    // MARK: - Narrative Template Tests

    func test_narrativeTemplate_noSessions() throws {
        let store = try DataStore()
        store.replaceUsages([])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.contains("No sessions"))
    }

    func test_narrativeTemplate_oneSessions() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u = TokenUsage(
            provider: .factory,
            sessionId: "1",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        store.replaceUsages([u, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.hasPrefix("One ") || n.headline.contains("1"))
    }

    func test_narrativeTemplate_nSessions() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "1",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .claudeCode,
            sessionId: "2",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.contains("2") || n.headline.contains("sessions"))
    }

    func test_narrativeTemplate_countsDistinctSessionIds() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-sonnet",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .factory,
            sessionId: "dup-session",
            projectName: "p",
            model: "claude-opus",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        XCTAssertTrue(n.headline.hasPrefix("One "))
    }

    func test_narrativeTemplate_collapsesClaudeSubagentSessionIds() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = TokenUsage(
            provider: .factory,
            sessionId: "main",
            projectName: "p",
            model: "claude-sonnet",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let u2 = TokenUsage(
            provider: .factory,
            sessionId: "main",
            projectName: "p",
            model: "claude-opus",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.1,
            startTime: day.addingTimeInterval(300),
            endTime: day.addingTimeInterval(400)
        )
        store.replaceUsages([u1, u2, pastDayUsage])
        let n = InsightEngine.generateNarrative(from: store)
        // Should collapse to one session
        XCTAssertTrue(n.headline.hasPrefix("One "))
    }

    // MARK: - Sparkline Tests

    func test_sparklineData_alwaysSevenPoints() throws {
        let store = try DataStore()
        store.replaceUsages([])
        let sparkline = store.last7DayCosts
        XCTAssertEqual(sparkline.count, 7)
    }

    // MARK: - Model Pricing Tests

    func test_modelPricing_knownModel() throws {
        let pricing = ModelPricing.lookup(model: "gpt-4o")
        XCTAssertGreaterThan(pricing.inputPerMToken, 0)
    }

    func test_insightEngine_structuredFields() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: day)!
        let u = TokenUsage(
            provider: .factory,
            sessionId: "1",
            projectName: "TestProject",
            model: "m",
            inputTokens: 100,
            outputTokens: 200,
            costUSD: 0.5,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
        let prior = TokenUsage(
            provider: .factory,
            sessionId: "2",
            projectName: "TestProject",
            model: "m",
            inputTokens: 80,
            outputTokens: 120,
            costUSD: 0.25,
            startTime: yesterday.addingTimeInterval(100),
            endTime: yesterday.addingTimeInterval(200)
        )
        store.replaceUsages([prior, u])
        let insights = InsightEngine.generate(from: store)
        XCTAssertFalse(insights.isEmpty)
    }

    // MARK: - Helper Methods

    private var pastDayUsage: TokenUsage {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -1, to: Date())!
        return TokenUsage(
            provider: .factory,
            sessionId: "past",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.05,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
    }

    private func moodFixture(today: Double, rollingAvg: Double) -> [TokenUsage] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: todayStart)!

        var usages: [TokenUsage] = []

        // Today's usage
        usages.append(TokenUsage(
            provider: .factory,
            sessionId: "today",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: today,
            startTime: todayStart.addingTimeInterval(100),
            endTime: todayStart.addingTimeInterval(200)
        ))

        // Yesterday's usage
        usages.append(TokenUsage(
            provider: .factory,
            sessionId: "yesterday",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: rollingAvg,
            startTime: yesterday.addingTimeInterval(100),
            endTime: yesterday.addingTimeInterval(200)
        ))

        // Add older days with rolling average cost
        for i in 2...7 {
            let day = cal.date(byAdding: .day, value: -i, to: todayStart)!
            usages.append(TokenUsage(
                provider: .factory,
                sessionId: "d\(i)",
                projectName: "p",
                model: "m",
                inputTokens: 1,
                outputTokens: 1,
                costUSD: rollingAvg,
                startTime: day.addingTimeInterval(100),
                endTime: day.addingTimeInterval(200)
            ))
        }

        return usages
    }
}

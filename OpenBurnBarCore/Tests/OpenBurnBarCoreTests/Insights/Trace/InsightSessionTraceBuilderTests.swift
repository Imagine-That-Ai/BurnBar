import XCTest
@testable import OpenBurnBarCore

final class InsightSessionTraceBuilderTests: XCTestCase {

    private func makeSnapshot(
        sessions: [InsightSessionRow] = [],
        actions: [InsightOperatingAction] = [],
        usages: [InsightUsageRow] = []
    ) -> InsightDataSnapshot {
        InsightDataSnapshot(
            window: DateInterval(start: Date().addingTimeInterval(-86400), end: Date()),
            generatedAt: Date(),
            usages: usages,
            sessions: sessions,
            quotaBuckets: [],
            operatingActions: actions,
            summaryRuns: [],
            modelBenchmarks: []
        )
    }

    private func makeSession(
        id: String,
        provider: String,
        start: TimeInterval,
        end: TimeInterval,
        title: String
    ) -> InsightSessionRow {
        InsightSessionRow(
            sessionID: id,
            provider: provider,
            projectName: nil,
            startTime: Date().addingTimeInterval(start),
            endTime: Date().addingTimeInterval(end),
            messageCount: 1,
            inferredTaskTitle: title,
            keyTools: [],
            keyCommands: [],
            keyFiles: []
        )
    }

    private func makeUsage(
        sessionID: String,
        provider: String,
        cost: Double,
        start: TimeInterval
    ) -> InsightUsageRow {
        InsightUsageRow(
            sessionID: sessionID,
            provider: provider,
            model: "test-model",
            projectName: nil,
            deviceID: nil,
            deviceName: nil,
            startTime: Date().addingTimeInterval(start),
            endTime: Date().addingTimeInterval(start + 1),
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            totalTokens: 0,
            costUSD: cost
        )
    }

    func testEmptySnapshotReturnsNil() {
        let builder = InsightSessionTraceBuilder()
        let snapshot = makeSnapshot()
        XCTAssertNil(builder.build(from: snapshot))
    }

    func testPicksMostConsequentialSessionByCost() {
        let cheapSession = makeSession(id: "cheap", provider: "anthropic", start: -3600, end: -1800, title: "Cheap session")
        let expensiveSession = makeSession(id: "expensive", provider: "anthropic", start: -7200, end: -3600, title: "Expensive session")
        let usages = [
            makeUsage(sessionID: "cheap", provider: "anthropic", cost: 0.50, start: -3600),
            makeUsage(sessionID: "expensive", provider: "anthropic", cost: 5.00, start: -7200)
        ]
        let snapshot = makeSnapshot(sessions: [cheapSession, expensiveSession], usages: usages)
        let builder = InsightSessionTraceBuilder()
        let trace = builder.build(from: snapshot)

        XCTAssertNotNil(trace)
        XCTAssertEqual(trace?.sessionID, "expensive")
        XCTAssertEqual(trace?.summary, "Expensive session")
        XCTAssertEqual(trace?.costUSD ?? -1, 5.00, accuracy: 0.01)
    }

    func testBuildsLanesFromActions() {
        let session = makeSession(id: "s1", provider: "openai", start: -300, end: 0, title: "Test session")
        let actions = [
            InsightOperatingAction(id: "a1", sessionID: "s1", actionKind: "tool_call", projectName: nil, occurredAt: Date().addingTimeInterval(-200), duration: 2.0, summary: "Search files"),
            InsightOperatingAction(id: "a2", sessionID: "s1", actionKind: "cache_hit", projectName: nil, occurredAt: Date().addingTimeInterval(-100), duration: 0.5, summary: "Read cache"),
            InsightOperatingAction(id: "a3", sessionID: "s1", actionKind: "model_call", projectName: nil, occurredAt: Date().addingTimeInterval(-50), duration: 1.5, summary: "Completion")
        ]
        let snapshot = makeSnapshot(sessions: [session], actions: actions)
        let builder = InsightSessionTraceBuilder()
        let trace = builder.build(from: snapshot)

        XCTAssertNotNil(trace)
        XCTAssertTrue(trace!.lanes.count >= 4) // prompt + actions + response

        let kinds: [TraceLane.Kind] = trace!.lanes.map(\.kind)
        XCTAssertTrue(kinds.contains(.prompt))
        XCTAssertTrue(kinds.contains(.tool))
        XCTAssertTrue(kinds.contains(.cache))
        XCTAssertTrue(kinds.contains(.model))
        XCTAssertTrue(kinds.contains(.response))
    }

    func testBuildsTicksFromUsages() {
        let session = makeSession(id: "s1", provider: "anthropic", start: -120, end: 0, title: "Tick test")
        let usages = [
            makeUsage(sessionID: "s1", provider: "anthropic", cost: 0.10, start: -100),
            makeUsage(sessionID: "s1", provider: "anthropic", cost: 0.20, start: -50),
            makeUsage(sessionID: "s1", provider: "anthropic", cost: 0.30, start: -10)
        ]
        let snapshot = makeSnapshot(sessions: [session], usages: usages)
        let builder = InsightSessionTraceBuilder()
        let trace = builder.build(from: snapshot)

        XCTAssertNotNil(trace)
        XCTAssertEqual(trace?.ticks.count, 3)
        XCTAssertEqual(trace?.ticks.last?.costUSD ?? -1, 0.60, accuracy: 0.01)
    }

    func testCapsTicksAtTwelve() {
        let session = makeSession(id: "s1", provider: "anthropic", start: -1000, end: 0, title: "Many ticks")
        var usages: [InsightUsageRow] = []
        for i in 0..<20 {
            usages.append(makeUsage(sessionID: "s1", provider: "anthropic", cost: 0.10, start: -Double(50 * (20 - i))))
        }
        let snapshot = makeSnapshot(sessions: [session], usages: usages)
        let builder = InsightSessionTraceBuilder()
        let trace = builder.build(from: snapshot)

        XCTAssertNotNil(trace)
        XCTAssertLessThanOrEqual(trace!.ticks.count, 12)
    }

    func testDidTimeoutForLongSessions() {
        let shortSession = makeSession(id: "short", provider: "anthropic", start: -60, end: 0, title: "Short")
        let longSession = makeSession(id: "long", provider: "anthropic", start: -400, end: 0, title: "Long")

        let builder = InsightSessionTraceBuilder()
        let shortTrace = builder.build(from: makeSnapshot(sessions: [shortSession]))
        let longTrace = builder.build(from: makeSnapshot(sessions: [longSession]))

        XCTAssertEqual(shortTrace?.didTimeout, false)
        XCTAssertEqual(longTrace?.didTimeout, true)
    }

    func testProviderTintMapping() {
        let session = makeSession(id: "s1", provider: "openai", start: -100, end: 0, title: "OpenAI session")
        let snapshot = makeSnapshot(sessions: [session])
        let builder = InsightSessionTraceBuilder()
        let trace = builder.build(from: snapshot)

        XCTAssertEqual(trace?.tint, .whimsy)
    }
}

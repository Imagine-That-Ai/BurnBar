import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class ProviderDashboardStoreTests: XCTestCase {

    func testInitialState() {
        let store = ProviderDashboardStore(provider: .claudeCode)
        XCTAssertTrue(store.usages.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.hasMore)
    }

    func testAggregatesWithEmptyUsages() {
        let store = ProviderDashboardStore(provider: .claudeCode)
        XCTAssertEqual(store.totalCost, 0)
        XCTAssertEqual(store.totalTokens, 0)
        XCTAssertEqual(store.totalSessions, 0)
        XCTAssertEqual(store.inputTokens, 0)
        XCTAssertEqual(store.outputTokens, 0)
        XCTAssertTrue(store.dailyPoints.isEmpty)
    }

    func testAggregatesWithSampleUsages() {
        let store = ProviderDashboardStore(provider: .claudeCode)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        store.usages = [
            TokenUsage(provider: .claudeCode, sessionId: "1", projectName: "P", model: "claude-3", inputTokens: 100, outputTokens: 50, costUSD: 0.01, startTime: now, endTime: now),
            TokenUsage(provider: .claudeCode, sessionId: "2", projectName: "P", model: "claude-3", inputTokens: 200, outputTokens: 100, costUSD: 0.02, startTime: yesterday, endTime: yesterday)
        ]

        XCTAssertEqual(store.totalCost, 0.03, accuracy: 0.001)
        XCTAssertEqual(store.totalTokens, 450)
        XCTAssertEqual(store.totalSessions, 2)
        XCTAssertEqual(store.inputTokens, 300)
        XCTAssertEqual(store.outputTokens, 150)
        XCTAssertEqual(store.dailyPoints.count, 2)
    }
}

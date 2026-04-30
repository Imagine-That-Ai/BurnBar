import XCTest
import GRDB
@testable import OpenBurnBar

@MainActor
final class DataStoreTests: XCTestCase {

    // MARK: - Rolling Daily Average Tests

    func test_rollingDailyAverage_sevenDays() throws {
        let store = try DataStoreCoordinator()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in 1...7 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 100,
                    outputTokens: 100,
                    costUSD: Double(d),
                    startTime: day.addingTimeInterval(3600),
                    endTime: day.addingTimeInterval(7200)
                )
            )
        }
        store.replaceUsages(usages)
        let expected = (1.0 + 2.0 + 3.0 + 4.0 + 5.0 + 6.0 + 7.0) / 7.0
        XCTAssertEqual(store.rollingDailyAverage, expected, accuracy: 0.0001)
    }

    func test_rollingDailyAverage_zeroFillsMissingDays() throws {
        let store = try DataStoreCoordinator()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in [1, 3, 5] {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: 10,
                    startTime: day.addingTimeInterval(100),
                    endTime: day.addingTimeInterval(200)
                )
            )
        }
        store.replaceUsages(usages)
        XCTAssertEqual(store.rollingDailyAverage, 30.0 / 7.0, accuracy: 0.0001)
    }

    // MARK: - Mood Band Tests

    func test_moodBand_light() throws {
        let store = try DataStoreCoordinator()
        store.replaceUsages(moodFixture(today: 0.5, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .light)
    }

    func test_moodBand_onPace() throws {
        let store = try DataStoreCoordinator()
        store.replaceUsages(moodFixture(today: 1.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .onPace)
    }

    func test_moodBand_heavy() throws {
        let store = try DataStoreCoordinator()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .heavy)
    }

    func test_moodBand_baseline() throws {
        let store = try DataStoreCoordinator()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u = TokenUsage(
            provider: .factory,
            sessionId: "a",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 1,
            startTime: day.addingTimeInterval(10),
            endTime: day.addingTimeInterval(20)
        )
        store.replaceUsages([u])
        XCTAssertEqual(store.moodBand, .baseline)
    }

    func test_moodBand_quiet() throws {
        let store = try DataStoreCoordinator()
        store.replaceUsages(moodFixture(today: 0, rollingAvg: 5))
        XCTAssertEqual(store.moodBand, .quiet)
    }

    func test_moodBand_zeroAverage() throws {
        let store = try DataStoreCoordinator()
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: Date())
        let d1 = cal.date(byAdding: .day, value: -1, to: d0)!
        let older = TokenUsage(
            provider: .factory,
            sessionId: "old",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0,
            startTime: d1.addingTimeInterval(10),
            endTime: d1.addingTimeInterval(20)
        )
        let today = TokenUsage(
            provider: .factory,
            sessionId: "new",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 3,
            startTime: d0.addingTimeInterval(10),
            endTime: d0.addingTimeInterval(20)
        )
        store.replaceUsages([older, today])
        XCTAssertEqual(store.rollingDailyAverage, 0, accuracy: 0.0001)
        XCTAssertEqual(store.moodBand, .onPace)
    }

    // MARK: - Token Usage Tests

    func test_cacheRatio_aboveThreshold() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "c",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            cacheCreationTokens: 0,
            cacheReadTokens: 25,
            costUSD: 1,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertTrue(u.totalTokens > 0)
        XCTAssertGreaterThan(Double(u.cacheReadTokens) / Double(u.totalTokens), 0.5)
    }

    func test_cacheRatio_zeroTotal() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "z",
            projectName: "p",
            model: "m",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 0,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertEqual(u.totalTokens, 0)
    }

    // MARK: - Local Authority Snapshot Tests

    func test_dataStoreLocalAuthoritySnapshot_reportsCountsAndControllerMirrorPresence() throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        try store.insert(
            TokenUsage(
                provider: .factory,
                sessionId: "authority-1",
                projectName: "Apollo",
                model: "glm-5",
                inputTokens: 10,
                outputTokens: 12,
                costUSD: 0.12,
                startTime: Date(),
                endTime: Date()
            )
        )
        try store.saveControllerRuntimeMirror(OpenBurnBarControllerRuntimeSnapshot.empty)

        let snapshot = try store.localAuthoritySnapshot()

        XCTAssertEqual(snapshot.usageRowCount, 1)
        XCTAssertEqual(snapshot.conversationRowCount, 0)
        XCTAssertEqual(snapshot.sharedArtifactCount, 0)
        XCTAssertTrue(snapshot.controllerRuntimeCached)
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
        let older = cal.date(byAdding: .day, value: -2, to: todayStart)!

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

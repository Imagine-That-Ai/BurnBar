import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

@MainActor
final class DashboardLiveCostCurveCacheTests: XCTestCase {

    private func usage(at offset: TimeInterval, cost: Double, inputTokens: Int = 100, outputTokens: Int = 100) -> TokenUsage {
        let start = Date(timeIntervalSinceNow: offset)
        return TokenUsage(
            provider: .factory,
            sessionId: "s\(offset)",
            projectName: "project",
            model: "model",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: cost,
            startTime: start,
            endTime: start.addingTimeInterval(30)
        )
    }

    private func minuteDomain() -> ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-60)...now
    }

    private func hourDomain() -> ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-3600)...now
    }

    // MARK: - Cumulative behavior

    func testBuildSamples_minute_emptyInput_returnsZeroBaseline() {
        let samples = DashboardLiveCostCurve.buildSamples(
            usages: [],
            unit: .cost,
            granularity: .minute,
            domain: minuteDomain()
        )
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(samples.first?.cumulative, 0)
        XCTAssertEqual(samples.last?.cumulative, 0)
    }

    func testBuildSamples_costUnit_isMonotonicallyNonDecreasing() {
        let usages = [
            usage(at: -50, cost: 1.0),
            usage(at: -30, cost: 2.0),
            usage(at: -10, cost: 0.5)
        ]
        let samples = DashboardLiveCostCurve.buildSamples(
            usages: usages,
            unit: .cost,
            granularity: .minute,
            domain: minuteDomain()
        )
        for i in 1..<samples.count {
            XCTAssertGreaterThanOrEqual(samples[i].cumulative, samples[i - 1].cumulative)
        }
    }

    func testBuildSamples_finalCumulative_equalsTotalCost() {
        let usages = [
            usage(at: -50, cost: 1.0),
            usage(at: -30, cost: 2.0),
            usage(at: -10, cost: 0.5)
        ]
        let samples = DashboardLiveCostCurve.buildSamples(
            usages: usages,
            unit: .cost,
            granularity: .minute,
            domain: minuteDomain()
        )
        XCTAssertEqual(samples.last?.cumulative ?? 0, 3.5, accuracy: 0.0001)
    }

    func testBuildSamples_tokensUnit_sumsTokenTotal() {
        let usages = [
            usage(at: -50, cost: 1.0, inputTokens: 200, outputTokens: 100),
            usage(at: -30, cost: 2.0, inputTokens: 400, outputTokens: 100)
        ]
        let samples = DashboardLiveCostCurve.buildSamples(
            usages: usages,
            unit: .tokens,
            granularity: .minute,
            domain: minuteDomain()
        )
        XCTAssertEqual(samples.last?.cumulative ?? 0, 800, accuracy: 0.0001)
    }

    func testBuildSamples_ignoresUsagesOutsideDomain() {
        let usages = [
            usage(at: -50, cost: 1.0),
            // Way outside the minute window:
            usage(at: -7200, cost: 999.0),
            usage(at: 60, cost: 999.0)
        ]
        let samples = DashboardLiveCostCurve.buildSamples(
            usages: usages,
            unit: .cost,
            granularity: .minute,
            domain: minuteDomain()
        )
        XCTAssertEqual(samples.last?.cumulative ?? 0, 1.0, accuracy: 0.0001)
    }

    func testBuildSamples_granularityHour_returnsExpectedBucketCount() {
        let samples = DashboardLiveCostCurve.buildSamples(
            usages: [],
            unit: .cost,
            granularity: .hour,
            domain: hourDomain()
        )
        XCTAssertEqual(samples.count, 31) // initial baseline + 30 buckets
    }

    func testBuildSamples_isPure_sameInputsProduceSameOutputs() {
        let usages = [
            usage(at: -45, cost: 0.25),
            usage(at: -15, cost: 0.5)
        ]
        let domain = minuteDomain()
        let a = DashboardLiveCostCurve.buildSamples(
            usages: usages,
            unit: .cost,
            granularity: .minute,
            domain: domain
        )
        let b = DashboardLiveCostCurve.buildSamples(
            usages: usages,
            unit: .cost,
            granularity: .minute,
            domain: domain
        )
        XCTAssertEqual(a, b)
    }
}

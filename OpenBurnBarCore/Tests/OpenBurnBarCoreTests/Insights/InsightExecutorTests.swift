import XCTest
@testable import OpenBurnBarCore

final class InsightExecutorTests: XCTestCase {

    private var snapshot: InsightDataSnapshot!
    private var filter: InsightFilter!
    private var executor: InsightExecutor!

    override func setUp() {
        super.setUp()
        snapshot = InsightTestFixtures.twoWeeksOfUsage()
        filter = InsightFilter(window: .last30d)
        executor = InsightExecutor()
    }

    func testKPITotalCostMatchesSum() {
        let result = executor.evaluate(binding: .kpi(metric: .totalCost, window: .last30d),
                                       filter: filter, snapshot: snapshot)
        guard case .kpi(let kpi) = result else { return XCTFail("expected kpi") }
        let expected = snapshot.usages.reduce(0) { $0 + $1.costUSD }
        XCTAssertEqual(kpi.value, expected, accuracy: 0.0001)
        XCTAssertEqual(kpi.valueFormat, .currency)
    }

    func testKPICacheHitRateIsBoundedZeroOne() {
        let result = executor.evaluate(binding: .kpi(metric: .cacheHitRate, window: .last30d),
                                       filter: filter, snapshot: snapshot)
        guard case .kpi(let kpi) = result else { return XCTFail("expected kpi") }
        XCTAssertGreaterThanOrEqual(kpi.value, 0)
        XCTAssertLessThanOrEqual(kpi.value, 1)
    }

    func testTimeSeriesWithDimensionEmitsSeries() {
        let result = executor.evaluate(
            binding: .timeSeries(metric: .cost, dimension: .provider, window: .last30d),
            filter: filter, snapshot: snapshot
        )
        guard case .timeSeries(let ts) = result else { return XCTFail("expected timeSeries") }
        XCTAssertFalse(ts.series.isEmpty)
        XCTAssertLessThanOrEqual(ts.series.count, 5)
        for s in ts.series {
            XCTAssertFalse(s.points.isEmpty)
        }
    }

    func testRankingRespectsLimit() {
        let result = executor.evaluate(
            binding: .ranking(metric: .cost, dimension: .model, limit: 2, window: .last30d),
            filter: filter, snapshot: snapshot
        )
        guard case .ranking(let r) = result else { return XCTFail("expected ranking") }
        XCTAssertLessThanOrEqual(r.rows.count, 2)
        // Descending by value.
        let values = r.rows.map(\.value)
        XCTAssertEqual(values, values.sorted(by: >))
    }

    func testHeatmapHasSevenByTwentyFour() {
        let result = executor.evaluate(
            binding: .heatmap(metric: .sessions, window: .last30d),
            filter: filter, snapshot: snapshot
        )
        guard case .heatmap(let h) = result else { return XCTFail("expected heatmap") }
        XCTAssertEqual(h.cells.count, 7)
        XCTAssertEqual(h.cells.first?.count, 24)
    }

    func testForecastEmitsBands() {
        let result = executor.evaluate(
            binding: .forecast(metric: .cost, horizonDays: 5),
            filter: filter, snapshot: snapshot
        )
        guard case .forecast(let f) = result else { return XCTFail("expected forecast") }
        XCTAssertEqual(f.forecast.count, 5)
        XCTAssertEqual(f.lowerBound.count, 5)
        XCTAssertEqual(f.upperBound.count, 5)
        for i in 0..<5 {
            XCTAssertLessThanOrEqual(f.lowerBound[i].value, f.forecast[i].value)
            XCTAssertGreaterThanOrEqual(f.upperBound[i].value, f.forecast[i].value)
        }
    }

    func testQuotaBindingReturnsBuckets() {
        let result = executor.evaluate(binding: .quota(providerKey: nil),
                                       filter: filter, snapshot: snapshot)
        guard case .quota(let q) = result else { return XCTFail("expected quota") }
        XCTAssertFalse(q.buckets.isEmpty)
    }

    func testAnomalyTableSurfacesSpike() {
        // Inject an outlier day at the front.
        var injected = snapshot!
        var spike = injected.usages.first!
        spike.startTime = injected.window.start.addingTimeInterval(86_400)
        spike.endTime = spike.startTime.addingTimeInterval(900)
        spike.costUSD = 50    // way above baseline ~0.012–0.04
        spike.sessionID = "spike-session"
        injected.usages.append(spike)

        let result = executor.evaluate(binding: .anomaly(window: .last90d),
                                       filter: filter, snapshot: injected)
        guard case .anomaly(let table) = result else { return XCTFail("expected anomaly") }
        XCTAssertFalse(table.rows.isEmpty, "Expected at least one anomaly when a spike is injected")
        XCTAssertTrue(table.rows.first!.label.lowercased().contains("spike"))
    }

    func testAnomalyTableEmitsSessionCitationsForDrilldown() throws {
        var injected = snapshot!
        var spike = try XCTUnwrap(injected.usages.first)
        spike.startTime = injected.window.start.addingTimeInterval(86_400)
        spike.endTime = spike.startTime.addingTimeInterval(900)
        spike.costUSD = 50
        spike.sessionID = "drilldown-session-1"
        injected.usages.append(spike)
        var spike2 = spike
        spike2.sessionID = "drilldown-session-2"
        injected.usages.append(spike2)

        let result = executor.evaluate(binding: .anomaly(window: .last90d),
                                       filter: filter, snapshot: injected)
        guard case .anomaly(let table) = result else { return XCTFail("expected anomaly") }
        let row = try XCTUnwrap(table.rows.first)
        let sessionIDs: [String] = row.citations.compactMap { cite in
            if case .session(let id, _) = cite.kind { return id }
            return nil
        }
        XCTAssertTrue(sessionIDs.contains("drilldown-session-1"),
                      "anomaly row should cite the spike session for drilldown")
    }

    func testAnomalyTableCapsAtTwelveRows() {
        var injected = snapshot!
        // Add many high-cost days across 14+ days so >12 anomalies could
        // theoretically surface; the executor must trim to the cap.
        let start = injected.window.start
        for i in 0..<20 {
            var spike = injected.usages.first!
            spike.startTime = start.addingTimeInterval(Double(i + 1) * 86_400)
            spike.endTime = spike.startTime.addingTimeInterval(900)
            spike.costUSD = 100 + Double(i)
            spike.sessionID = "synthetic-spike-\(i)"
            injected.usages.append(spike)
        }
        let result = executor.evaluate(binding: .anomaly(window: .last90d),
                                       filter: filter, snapshot: injected)
        guard case .anomaly(let table) = result else { return XCTFail("expected anomaly") }
        XCTAssertLessThanOrEqual(table.rows.count, 12)
    }

    func testAnomalyTableRespectsZThreshold() {
        // No spike: baseline noise should not surface anomalies above z=2.
        let result = executor.evaluate(binding: .anomaly(window: .last90d),
                                       filter: filter, snapshot: snapshot)
        guard case .anomaly(let table) = result else { return XCTFail("expected anomaly") }
        for row in table.rows {
            XCTAssertGreaterThanOrEqual(row.score, 2.0)
        }
    }

    func testRadarSeriesValuesNormalized() {
        let result = executor.evaluate(binding: .radar(target: .allAgents, window: .last30d),
                                       filter: filter, snapshot: snapshot)
        guard case .radar(let radar) = result else { return XCTFail("expected radar") }
        XCTAssertFalse(radar.axes.isEmpty)
        for series in radar.series {
            XCTAssertEqual(series.values.count, radar.axes.count)
            for v in series.values {
                XCTAssertGreaterThanOrEqual(v, 0)
                XCTAssertLessThanOrEqual(v, 1.001)
            }
        }
    }

    func testDistributionTotalEqualsSlicesSum() {
        let result = executor.evaluate(
            binding: .distribution(metric: .cost, dimension: .provider, window: .last30d),
            filter: filter, snapshot: snapshot
        )
        guard case .distribution(let d) = result else { return XCTFail("expected distribution") }
        let sum = d.slices.reduce(0) { $0 + $1.value }
        XCTAssertEqual(d.total, sum, accuracy: 0.001)
    }

    func testComposedRecursivelyEvaluatesChildren() {
        let composed = InsightDataBinding.composed([
            .kpi(metric: .totalCost, window: .last7d),
            .kpi(metric: .totalTokens, window: .last7d)
        ])
        let result = executor.evaluate(binding: composed, filter: filter, snapshot: snapshot)
        guard case .composed(let children) = result else { return XCTFail("expected composed") }
        XCTAssertEqual(children.count, 2)
        for child in children {
            if case .kpi = child {} else { XCTFail("child should be kpi, got \(child)") }
        }
    }

    func testExecutorIsDeterministic() {
        let a = executor.evaluate(binding: .ranking(metric: .cost, dimension: .model, limit: 5, window: .last30d),
                                  filter: filter, snapshot: snapshot)
        let b = executor.evaluate(binding: .ranking(metric: .cost, dimension: .model, limit: 5, window: .last30d),
                                  filter: filter, snapshot: snapshot)
        XCTAssertEqual(a, b)
    }
}

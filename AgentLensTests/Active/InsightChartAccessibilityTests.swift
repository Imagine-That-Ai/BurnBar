import XCTest
import Accessibility
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - InsightChartAccessibilityTests
//
// Unit coverage for the shared Insight chart accessibility engine
// (`InsightWidgetData` → spoken summary / AXChartDescriptor) plus the
// menu bar MiniSparkline summary.

@MainActor
final class InsightChartAccessibilityTests: XCTestCase {

    // MARK: - Fixtures

    private func timeSeries() -> InsightWidgetData.TimeSeries {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return InsightWidgetData.TimeSeries(
            series: [
                .init(id: "claude", name: "Claude", points: [
                    .init(date: base, value: 10),
                    .init(date: base.addingTimeInterval(86_400), value: 42.5)
                ]),
                .init(id: "codex", name: "Codex", points: [
                    .init(date: base, value: 4),
                    .init(date: base.addingTimeInterval(86_400), value: 6)
                ])
            ],
            xAxisLabel: "Date",
            yAxisLabel: "Spend",
            yFormat: .currency,
            annotations: [.init(date: base, label: "Release day", tone: .positive)]
        )
    }

    private func ranking() -> InsightWidgetData.Ranking {
        InsightWidgetData.Ranking(
            rows: [
                .init(id: "a", label: "Claude Code", value: 92.1),
                .init(id: "b", label: "Codex", value: 24.8)
            ],
            valueFormat: .currency,
            dimensionLabel: "Provider"
        )
    }

    private func distribution() -> InsightWidgetData.Distribution {
        InsightWidgetData.Distribution(
            slices: [
                .init(id: "in", label: "Input", value: 750),
                .init(id: "out", label: "Output", value: 250)
            ],
            valueFormat: .tokens,
            total: 1000
        )
    }

    // MARK: - Summaries

    func test_timeSeriesSummary_namesSeriesAxesAndRange() {
        let summary = InsightChartAccessibility.timeSeriesSummary(timeSeries())
        XCTAssertTrue(summary.contains("2 series"), summary)
        XCTAssertTrue(summary.contains("Claude"), summary)
        XCTAssertTrue(summary.contains("Codex"), summary)
        XCTAssertTrue(summary.contains("Spend ranges from $4.00 to $42.50"), summary)
        XCTAssertTrue(summary.contains("Release day"), summary)
    }

    func test_timeSeriesSummary_emptySaysNoData() {
        let empty = InsightWidgetData.TimeSeries(
            series: [], xAxisLabel: "Date", yAxisLabel: "Spend", yFormat: .currency
        )
        XCTAssertTrue(InsightChartAccessibility.timeSeriesSummary(empty).contains("No data"))
    }

    func test_rankingSummary_speaksTopRow() {
        let summary = InsightChartAccessibility.rankingSummary(ranking())
        XCTAssertTrue(summary.contains("Ranking by Provider"), summary)
        XCTAssertTrue(summary.contains("2 rows"), summary)
        XCTAssertTrue(summary.contains("Top: Claude Code"), summary)
    }

    func test_distributionSummary_speaksSlicesWithPercent() {
        let summary = InsightChartAccessibility.distributionSummary(distribution())
        XCTAssertTrue(summary.contains("2 slices"), summary)
        XCTAssertTrue(summary.contains("Input"), summary)
        XCTAssertTrue(summary.contains("(75%)"), summary)
    }

    func test_kpiSummary_speaksValueDeltaAndTrend() {
        let kpi = InsightWidgetData.KPI(
            metricLabel: "Total spend",
            value: 42.5,
            valueFormat: .currency,
            delta: 0.12,
            deltaIsPercent: true,
            sparkline: [1, 2, 3]
        )
        let summary = InsightChartAccessibility.kpiSummary(kpi)
        XCTAssertTrue(summary.contains("Total spend: $42.50"), summary)
        XCTAssertTrue(summary.contains("Up +12%"), summary)
        XCTAssertTrue(summary.contains("trending up"), summary)
    }

    func test_heatmapSummary_speaksGridShapeAndPeak() {
        let heatmap = InsightWidgetData.Heatmap(
            rowLabels: ["Mon", "Tue"],
            columnLabels: ["0h", "1h", "2h"],
            cells: [[0, 1, 2], [3, 9, 4]],
            valueFormat: .count
        )
        let summary = InsightChartAccessibility.heatmapSummary(heatmap)
        XCTAssertTrue(summary.contains("2 rows by 3 columns"), summary)
        XCTAssertTrue(summary.contains("Peak at Tue, 1h: 9"), summary)
    }

    func test_sankeySummary_speaksLargestFlows() {
        let sankey = InsightWidgetData.Sankey(
            nodes: [
                .init(id: "s1", label: "Claude"),
                .init(id: "t1", label: "Coding")
            ],
            links: [.init(source: "s1", target: "t1", value: 1200)]
        )
        let summary = InsightChartAccessibility.sankeySummary(sankey)
        XCTAssertTrue(summary.contains("Claude to Coding"), summary)
        XCTAssertTrue(summary.contains("1.2k"), summary)
    }

    func test_summaryDispatch_coversChartKindsAndSkipsTextKinds() {
        XCTAssertNotNil(InsightChartAccessibility.summary(for: .timeSeries(timeSeries())))
        XCTAssertNotNil(InsightChartAccessibility.summary(for: .ranking(ranking())))
        XCTAssertNotNil(InsightChartAccessibility.summary(for: .distribution(distribution())))
        XCTAssertNotNil(InsightChartAccessibility.summary(for: .empty(reason: "nothing")))
        XCTAssertNotNil(InsightChartAccessibility.summary(for: .error(message: "boom")))
        // Text-first kinds render as regular accessible text already.
        XCTAssertNil(InsightChartAccessibility.summary(
            for: .narrative(.init(headline: "H", body: "B"))
        ))
        XCTAssertNil(InsightChartAccessibility.summary(for: .mermaid("graph TD")))
    }

    // MARK: - Descriptors

    func test_timeSeriesDescriptor_mapsSeriesAndAxes() {
        let descriptor = InsightChartAccessibility.timeSeriesDescriptor(timeSeries())
        XCTAssertEqual(descriptor.series.count, 2)
        XCTAssertEqual(descriptor.series.map(\.name), ["Claude", "Codex"])
        XCTAssertTrue(descriptor.series.allSatisfy(\.isContinuous))
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 2)

        let xAxis = descriptor.xAxis as? AXNumericDataAxisDescriptor
        XCTAssertNotNil(xAxis, "Time axis is numeric (intervals) with date descriptions")
        XCTAssertEqual(xAxis?.title, "Date")

        let yAxis = descriptor.yAxis
        XCTAssertEqual(yAxis?.title, "Spend")
        XCTAssertEqual(yAxis?.range.lowerBound, 0)
        XCTAssertEqual(yAxis?.range.upperBound ?? 0, 42.5, accuracy: 0.0001)
    }

    func test_rankingDescriptor_isCategoricalWithRowOrder() {
        let descriptor = InsightChartAccessibility.rankingDescriptor(ranking())
        let xAxis = descriptor.xAxis as? AXCategoricalDataAxisDescriptor
        XCTAssertEqual(xAxis?.title, "Provider")
        XCTAssertEqual(xAxis?.categoryOrder, ["Claude Code", "Codex"])
        XCTAssertEqual(descriptor.series.count, 1)
        XCTAssertEqual(descriptor.series.first?.isContinuous, false)
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 2)
    }

    func test_distributionDescriptor_mapsSlices() {
        let descriptor = InsightChartAccessibility.distributionDescriptor(distribution())
        let xAxis = descriptor.xAxis as? AXCategoricalDataAxisDescriptor
        XCTAssertEqual(xAxis?.categoryOrder, ["Input", "Output"])
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 2)
    }

    func test_forecastDescriptor_hasActualAndForecastSeries() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let forecast = InsightWidgetData.Forecast(
            actual: [.init(date: base, value: 10)],
            forecast: [.init(date: base.addingTimeInterval(86_400), value: 12)],
            lowerBound: [.init(date: base.addingTimeInterval(86_400), value: 9)],
            upperBound: [.init(date: base.addingTimeInterval(86_400), value: 15)],
            xAxisLabel: "Date",
            yAxisLabel: "Spend",
            yFormat: .currency
        )
        let descriptor = InsightChartAccessibility.forecastDescriptor(forecast)
        XCTAssertEqual(descriptor.series.map(\.name), ["Actual", "Forecast"])
        XCTAssertTrue(descriptor.series.allSatisfy(\.isContinuous))
        // Y range must cover the confidence band, not just the lines.
        let yAxis = descriptor.yAxis
        XCTAssertEqual(yAxis?.range.upperBound ?? 0, 15, accuracy: 0.0001)
    }

    // MARK: - Sparkline summaries

    func test_insightSparklineSummary_directionsAndFormat() {
        XCTAssertTrue(
            InsightChartAccessibility.sparklineSummary(values: [1, 2, 3], format: .currency)
                .contains("trending up, from $1.00 to $3.00")
        )
        XCTAssertTrue(
            InsightChartAccessibility.sparklineSummary(values: [3, 1], format: .raw)
                .contains("trending down")
        )
        XCTAssertEqual(InsightChartAccessibility.sparklineSummary(values: []), "no data")
    }

    func test_miniSparklineSummary_titleTrendAndExtremes() {
        let summary = MiniSparkline.accessibilitySummary(
            data: [1, 9, 3],
            title: "7-day spending trend",
            format: { String(format: "$%.2f", $0) }
        )
        XCTAssertTrue(summary.hasPrefix("7-day spending trend: "), summary)
        XCTAssertTrue(summary.contains("trending up"), summary)
        XCTAssertTrue(summary.contains("from $1.00 to $3.00"), summary)
        XCTAssertTrue(summary.contains("low $1.00"), summary)
        XCTAssertTrue(summary.contains("high $9.00"), summary)
    }

    func test_miniSparklineSummary_edgeCases() {
        XCTAssertEqual(MiniSparkline.accessibilitySummary(data: []), "no data")
        XCTAssertEqual(MiniSparkline.accessibilitySummary(data: [5]), "single value 5")
        XCTAssertTrue(MiniSparkline.accessibilitySummary(data: [2, 2]).contains("trending flat"))
    }
}

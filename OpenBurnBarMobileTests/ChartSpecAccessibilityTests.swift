import XCTest
import Accessibility
@testable import OpenBurnBarMobile

// MARK: - ChartSpecAccessibilityTests
//
// Unit coverage for the Chart Studio accessibility engine: ChartSpec →
// spoken summary, ChartSpec → AXChartDescriptor mapping, non-color series
// encodings, and the ASCII/insight canvas summaries.

final class ChartSpecAccessibilityTests: XCTestCase {

    // MARK: - Fixtures

    private func barSpec() -> ChartSpec {
        ChartSpec(
            kind: .bar,
            title: "Cost by provider",
            subtitle: "Last 7 days",
            xAxis: .init(title: "Provider", kind: "category"),
            yAxis: .init(title: "USD", kind: "linear"),
            series: [
                .init(name: "USD", points: [
                    .init(x: .string("Claude Code"), y: 92.10),
                    .init(x: .string("Codex"), y: 24.80)
                ])
            ],
            valueFormat: "currency"
        )
    }

    private func multiLineSpec() -> ChartSpec {
        ChartSpec(
            kind: .line,
            title: "Daily burn",
            series: [
                .init(name: "Claude", points: [
                    .init(x: .string("2026-07-01"), y: 10),
                    .init(x: .string("2026-07-02"), y: 20)
                ]),
                .init(name: "Codex", points: [
                    .init(x: .string("2026-07-01"), y: 5),
                    .init(x: .string("2026-07-02"), y: 8)
                ])
            ],
            valueFormat: "currency"
        )
    }

    private func donutSpec() -> ChartSpec {
        ChartSpec(
            kind: .donut,
            title: "Share",
            series: [
                .init(name: "Share", points: [
                    .init(x: .string("Claude"), y: 75),
                    .init(x: .string("Codex"), y: 25)
                ])
            ],
            valueFormat: "percent"
        )
    }

    private func emptySpec() -> ChartSpec {
        ChartSpec(kind: .line, title: "Nothing yet", series: [.init(name: "S", points: [])])
    }

    // MARK: - Value formatting

    func testFormattedValueCurrency() {
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(12.345, format: "currency"), "$12.35")
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(123.45, format: "currency"), "$123.5")
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(5000, format: "currency"), "$5000")
    }

    func testFormattedValueTokens() {
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(1500, format: "tokens"), "1.5k tokens")
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(2_000_000, format: "tokens"), "2.0M tokens")
    }

    func testFormattedValuePercent() {
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(0.58, format: "percent"), "58%")
    }

    func testFormattedValueRawAndNil() {
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(42, format: "raw"), "42")
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(42.5, format: nil), "42.50")
        XCTAssertEqual(ChartSpecAccessibility.formattedValue(1_200_000_000, format: nil), "1.2B")
    }

    // MARK: - Empty detection

    func testIsEmptyAndEmptyLabel() {
        XCTAssertTrue(ChartSpecAccessibility.isEmpty(emptySpec()))
        XCTAssertFalse(ChartSpecAccessibility.isEmpty(barSpec()))
        let label = ChartSpecAccessibility.emptyStateLabel(for: emptySpec())
        XCTAssertTrue(label.contains("Line chart"))
        XCTAssertTrue(label.contains("Nothing yet"))
        XCTAssertTrue(label.contains("No data"))
    }

    // MARK: - Summary label

    func testBarSummaryIncludesKindTitleSeriesAndTotal() {
        let summary = ChartSpecAccessibility.summaryLabel(for: barSpec())
        XCTAssertTrue(summary.contains("Bar chart"), summary)
        XCTAssertTrue(summary.contains("Cost by provider"), summary)
        XCTAssertTrue(summary.contains("Last 7 days"), summary)
        XCTAssertTrue(summary.contains("USD"), summary)
        XCTAssertTrue(summary.contains("2 categories"), summary)
        // 92.10 + 24.80 = 116.90 → "$116.9" under the >=100 currency rule.
        XCTAssertTrue(summary.contains("Total $116.9"), summary)
    }

    func testMultiSeriesSummaryNamesEverySeries() {
        let summary = ChartSpecAccessibility.summaryLabel(for: multiLineSpec())
        XCTAssertTrue(summary.contains("2 series"), summary)
        XCTAssertTrue(summary.contains("Claude"), summary)
        XCTAssertTrue(summary.contains("Codex"), summary)
    }

    func testDonutSummaryListsSlicesWithPercentages() {
        let summary = ChartSpecAccessibility.summaryLabel(for: donutSpec())
        XCTAssertTrue(summary.contains("Donut chart"), summary)
        XCTAssertTrue(summary.contains("2 slices"), summary)
        XCTAssertTrue(summary.contains("Claude"), summary)
        XCTAssertTrue(summary.contains("(75%)"), summary)
    }

    func testEmptySpecSummarySaysNoData() {
        let summary = ChartSpecAccessibility.summaryLabel(for: emptySpec())
        XCTAssertTrue(summary.contains("No data available"), summary)
    }

    // MARK: - X kind inference

    func testInferredXKindExplicitOverride() {
        let spec = ChartSpec(
            kind: .line,
            title: "T",
            xAxis: .init(title: nil, kind: "time"),
            series: [.init(name: "S", points: [.init(x: .string("not a date"), y: 1)])]
        )
        XCTAssertEqual(ChartSpecAccessibility.inferredXKind(for: spec), .time)
    }

    func testInferredXKindFromValues() {
        XCTAssertEqual(ChartSpecAccessibility.inferredXKind(for: barSpec()), .category)
        XCTAssertEqual(ChartSpecAccessibility.inferredXKind(for: multiLineSpec()), .time)
        let numeric = ChartSpec(
            kind: .scatter,
            title: "N",
            series: [.init(name: "S", points: [.init(x: .double(3.5), y: 1)])]
        )
        XCTAssertEqual(ChartSpecAccessibility.inferredXKind(for: numeric), .number)
    }

    // MARK: - Donut breakdown

    func testDonutBreakdownAggregatesAndPreservesOrder() {
        let spec = ChartSpec(
            kind: .donut,
            title: "D",
            series: [
                .init(name: "A", points: [
                    .init(x: .string("Claude"), y: 40),
                    .init(x: .string("Codex"), y: 25),
                    .init(x: .string("Claude"), y: 35)
                ])
            ]
        )
        let breakdown = ChartSpecAccessibility.donutBreakdown(for: spec)
        XCTAssertEqual(breakdown.map(\.label), ["Claude", "Codex"])
        XCTAssertEqual(breakdown[0].value, 75, accuracy: 0.0001)
        XCTAssertEqual(breakdown[1].value, 25, accuracy: 0.0001)
    }

    // MARK: - Non-color encodings

    func testMarkersAreUniqueAcrossFirstEightSeries() {
        let markers = (0..<8).map { ChartSpecAccessibility.marker(forSeriesIndex: $0) }
        XCTAssertEqual(Set(markers).count, 8, "First 8 series need distinct marker shapes")
        // Wraps deterministically afterwards.
        XCTAssertEqual(ChartSpecAccessibility.marker(forSeriesIndex: 8), markers[0])
    }

    func testDashPatternsFirstSeriesSolidRestDistinct() {
        XCTAssertTrue(ChartSpecAccessibility.dashPattern(forSeriesIndex: 0).isEmpty,
                      "Primary series stays a solid line")
        let patterns = (0..<8).map { ChartSpecAccessibility.dashPattern(forSeriesIndex: $0) }
        XCTAssertEqual(Set(patterns.map { $0.map(Double.init) }).count, 8,
                       "First 8 series need distinct dash patterns")
        XCTAssertEqual(ChartSpecAccessibility.dashPattern(forSeriesIndex: 9),
                       ChartSpecAccessibility.dashPattern(forSeriesIndex: 1))
    }

    // MARK: - AXChartDescriptor mapping

    func testCategoricalDescriptorMapsAxesAndSeries() {
        let descriptor = ChartSpecAccessibility.makeChartDescriptor(for: barSpec())
        XCTAssertEqual(descriptor.title, "Cost by provider")
        XCTAssertNotNil(descriptor.summary)
        XCTAssertTrue(descriptor.summary?.contains("Bar chart") ?? false)

        let xAxis = descriptor.xAxis as? AXCategoricalDataAxisDescriptor
        XCTAssertNotNil(xAxis, "Categorical spec must yield a categorical x axis")
        XCTAssertEqual(xAxis?.title, "Provider")
        XCTAssertEqual(xAxis?.categoryOrder, ["Claude Code", "Codex"])

        let yAxis = descriptor.yAxis as? AXNumericDataAxisDescriptor
        XCTAssertNotNil(yAxis)
        XCTAssertEqual(yAxis?.title, "USD")

        XCTAssertEqual(descriptor.series.count, 1)
        XCTAssertEqual(descriptor.series.first?.name, "USD")
        XCTAssertEqual(descriptor.series.first?.isContinuous, false)
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 2)
    }

    func testTimeDescriptorUsesNumericAxisAndContinuousSeries() {
        let descriptor = ChartSpecAccessibility.makeChartDescriptor(for: multiLineSpec())
        let xAxis = descriptor.xAxis as? AXNumericDataAxisDescriptor
        XCTAssertNotNil(xAxis, "Time spec must yield a numeric (interval) x axis")
        XCTAssertEqual(descriptor.series.count, 2)
        XCTAssertEqual(descriptor.series.map(\.name), ["Claude", "Codex"])
        XCTAssertTrue(descriptor.series.allSatisfy(\.isContinuous),
                      "Line series must be continuous for audio graphs")
    }

    func testDescriptorYAxisRangeSpansZeroToMax() {
        let descriptor = ChartSpecAccessibility.makeChartDescriptor(for: barSpec())
        guard let yAxis = descriptor.yAxis as? AXNumericDataAxisDescriptor else {
            XCTFail("Expected numeric y axis")
            return
        }
        XCTAssertEqual(yAxis.range.lowerBound, 0)
        XCTAssertEqual(yAxis.range.upperBound, 92.10, accuracy: 0.0001)
    }

    func testDescriptorForEmptySpecDoesNotCrash() {
        let descriptor = ChartSpecAccessibility.makeChartDescriptor(for: emptySpec())
        XCTAssertEqual(descriptor.series.count, 1)
        XCTAssertEqual(descriptor.series.first?.dataPoints.count, 0)
    }

    // MARK: - ASCII summary

    func testAsciiSummaryStripsArtAndKeepsLabelsAndValues() {
        let spec = AsciiSpec(
            title: "Cost by provider",
            subtitle: "USD, last 7 days",
            variant: .bar,
            blocks: [
                .init(label: "Claude Code", lines: ["▉▉▉▉▉▉▉▉  $92.10"]),
                .init(label: "Codex", lines: ["▉▉▉  $24.80"])
            ],
            footnote: "7-day window"
        )
        let summary = ChartSpecAccessibility.asciiSummary(for: spec)
        XCTAssertTrue(summary.contains("Terminal bar chart"), summary)
        XCTAssertTrue(summary.contains("Cost by provider"), summary)
        XCTAssertTrue(summary.contains("Claude Code: $92.10"), summary)
        XCTAssertTrue(summary.contains("Codex: $24.80"), summary)
        XCTAssertTrue(summary.contains("7-day window"), summary)
        XCTAssertFalse(summary.contains("▉"), "Art glyphs must not be spoken: \(summary)")
    }

    func testBlockDigestPureArtReturnsLabelOnly() {
        let block = AsciiSpec.Block(label: "Sparkline", lines: ["▁▂▃▄▅▆▇█"])
        XCTAssertEqual(ChartSpecAccessibility.blockDigest(block), "Sparkline")
    }

    func testBlockDigestNothingUsefulReturnsNil() {
        let block = AsciiSpec.Block(label: nil, lines: ["╭──╮", "│  │", "╰──╯"])
        XCTAssertNil(ChartSpecAccessibility.blockDigest(block))
    }

    // MARK: - Sparkline + insight summaries

    func testSparklineSummaryDirections() {
        XCTAssertTrue(ChartSpecAccessibility.sparklineSummary(values: [1, 2, 3]).contains("trending up"))
        XCTAssertTrue(ChartSpecAccessibility.sparklineSummary(values: [3, 2, 1]).contains("trending down"))
        XCTAssertTrue(ChartSpecAccessibility.sparklineSummary(values: [2, 5, 2]).contains("trending flat"))
        XCTAssertEqual(ChartSpecAccessibility.sparklineSummary(values: []), "no data")
        XCTAssertTrue(ChartSpecAccessibility.sparklineSummary(values: [7]).contains("single value 7"))
    }

    func testSparklineSummaryIncludesExtremes() {
        let summary = ChartSpecAccessibility.sparklineSummary(values: [1, 9, 3])
        XCTAssertTrue(summary.contains("low 1"), summary)
        XCTAssertTrue(summary.contains("high 9"), summary)
    }

    func testInsightSummarySpeaksToneAndTrend() {
        let spec = InsightSpec(
            title: "You saved $12.40",
            body: "Cache reads carried 58% of input.",
            sparkline: [1, 2, 3],
            tone: "positive"
        )
        let summary = ChartSpecAccessibility.insightSummary(for: spec)
        XCTAssertTrue(summary.hasPrefix("Positive insight"), summary)
        XCTAssertTrue(summary.contains("You saved $12.40"), summary)
        XCTAssertTrue(summary.contains("trending up"), summary)
    }
}

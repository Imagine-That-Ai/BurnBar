import OpenBurnBarCore
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// The spend cube's rules.
///
/// `HomeSpendSeries` is `static` and pure precisely so bucketing, ranking, folding and
/// scaling can be pinned without mounting a chart — the same contract
/// `LivingSpaceBudgetTests` and `DashboardHomeLayoutTests` keep. The chart is a
/// rendering of these values; if the partition is wrong here, no amount of colour
/// fixes it.
final class HomeSpendSeriesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let window: TimeInterval = 24 * 60 * 60

    // MARK: - Bucketing

    func test_bucketsSpanTheWindowAndAreAligned() {
        let cube = makeCube([usage(.claudeCode, "claude-opus-4", cost: 3, agoHours: 1)], buckets: 24)
        XCTAssertEqual(cube.dates.count, 24)
        XCTAssertEqual(cube.dates.first, now.addingTimeInterval(-window))
        for band in cube.byHarness {
            XCTAssertEqual(band.values.count, 24, "every band must be bucket-aligned")
        }
    }

    /// A row that landed before the window opened is not this day's spend. Folding it
    /// into bucket zero is how a 24h chart quietly becomes an all-time chart.
    func test_rowsOutsideTheWindowAreExcluded() {
        let cube = makeCube([
            usage(.claudeCode, "claude-opus-4", cost: 5, agoHours: 2),
            usage(.codex, "gpt-5", cost: 99, agoHours: 40)
        ])
        XCTAssertEqual(cube.byHarness.map(\.id), [AgentProvider.claudeCode.rawValue])
        XCTAssertEqual(cube.totalsPerBucket.reduce(0, +), 5, accuracy: 0.0001)
    }

    // MARK: - The partition

    /// Both cuts are complete partitions of the same rows, so both must sum to the same
    /// number as the flat curve. A breakdown that does not add up is a chart that lies
    /// about the total while looking more informative.
    func test_everyCutSumsToTheSameTotal() {
        let cube = makeCube(spread)
        let flat = cube.totalsPerBucket.reduce(0, +)
        XCTAssertEqual(cube.byHarness.reduce(0) { $0 + $1.total }, flat, accuracy: 0.0001)
        XCTAssertEqual(cube.byModel.reduce(0) { $0 + $1.total }, flat, accuracy: 0.0001)
        XCTAssertEqual(cube.samples.reduce(0) { $0 + $1.cost }, flat, accuracy: 0.0001)
    }

    /// Bucket-by-bucket, not just in aggregate: a stack whose columns are individually
    /// wrong can still total correctly.
    func test_theCutsAgreeInEveryBucket() {
        let cube = makeCube(spread)
        for index in cube.dates.indices {
            let harness = cube.byHarness.reduce(0) { $0 + $1.values[index] }
            let model = cube.byModel.reduce(0) { $0 + $1.values[index] }
            XCTAssertEqual(harness, cube.totalsPerBucket[index], accuracy: 0.0001)
            XCTAssertEqual(model, cube.totalsPerBucket[index], accuracy: 0.0001)
        }
    }

    /// One model run through three harnesses is one model. The model cut has to cross
    /// harness boundaries or it is just the harness cut with different labels.
    func test_theModelCutCrossesHarnesses() {
        let cube = makeCube([
            usage(.claudeCode, "claude-opus-4", cost: 4, agoHours: 1),
            usage(.codex, "claude-opus-4", cost: 6, agoHours: 2),
            usage(.cursor, "claude-opus-4", cost: 2, agoHours: 3)
        ])
        XCTAssertEqual(cube.byHarness.count, 3)
        XCTAssertEqual(cube.byModel.count, 1)
        XCTAssertEqual(cube.byModel[0].total, 12, accuracy: 0.0001)
    }

    // MARK: - Ranking and folding

    func test_bandsAreRankedBySpend() {
        let cube = makeCube([
            usage(.cursor, "cursor-small", cost: 1, agoHours: 1),
            usage(.claudeCode, "claude-opus-4", cost: 9, agoHours: 1),
            usage(.codex, "gpt-5", cost: 5, agoHours: 1)
        ])
        XCTAssertEqual(
            cube.byHarness.map(\.label),
            [AgentProvider.claudeCode.rawValue, AgentProvider.codex.rawValue, AgentProvider.cursor.rawValue]
        )
    }

    /// The tail is folded, never dropped. If `Other` lost the rows it absorbed, the top
    /// of the stack would stop being the true total — the one thing the crest promises.
    func test_theTailFoldsIntoOtherWithoutLosingASingleDollar() {
        let providers: [AgentProvider] = [.claudeCode, .codex, .cursor, .deepSeek, .kimi, .ollama]
        let rows = providers.enumerated().map { index, provider in
            usage(provider, "model-\(index)", cost: Double(60 - index * 10), agoHours: 1)
        }
        let cube = makeCube(rows, limit: 2)

        XCTAssertEqual(cube.byHarness.count, 3, "two ranked bands plus one Other")
        XCTAssertEqual(cube.byHarness.last?.id, "other")
        XCTAssertEqual(cube.byHarness.last?.label, "Other (4)")
        XCTAssertEqual(
            cube.byHarness.reduce(0) { $0 + $1.total },
            rows.reduce(0) { $0 + $1.cost },
            accuracy: 0.0001
        )
    }

    /// Nothing to fold means no `Other` chip cluttering the legend.
    func test_noOtherBandWhenEverythingFits() {
        let cube = makeCube([
            usage(.claudeCode, "claude-opus-4", cost: 3, agoHours: 1),
            usage(.codex, "gpt-5", cost: 2, agoHours: 1)
        ], limit: 5)
        XCTAssertFalse(cube.byHarness.contains { $0.id == "other" })
    }

    /// A provider that ran but cost nothing is not a band — it would render as an
    /// invisible layer with a legend chip you cannot turn off meaningfully.
    func test_zeroCostRowsProduceNoBand() {
        let cube = makeCube([
            usage(.claudeCode, "claude-opus-4", cost: 0, agoHours: 1),
            usage(.codex, "gpt-5", cost: 4, agoHours: 1)
        ])
        XCTAssertEqual(cube.byHarness.map(\.id), [AgentProvider.codex.rawValue])
    }

    /// Identical data must produce an identical stack. Ties broken on identity keep the
    /// colours from shuffling between renders, which would read as a glitch.
    func test_tiesBreakDeterministically() {
        let rows = [
            usage(.codex, "gpt-5", cost: 5, agoHours: 1),
            usage(.claudeCode, "claude-opus-4", cost: 5, agoHours: 1)
        ]
        XCTAssertEqual(makeCube(rows).byHarness.map(\.id), makeCube(rows.reversed()).byHarness.map(\.id))
    }

    // MARK: - Colour

    /// Every Claude model resolves to the same brand ochre, so a stack of Opus over
    /// Sonnet would have an invisible seam. Repeats have to be pulled apart or the
    /// breakdown is decorative.
    func test_repeatedBrandColoursAreSeparated() {
        let cube = makeCube([
            usage(.claudeCode, "claude-opus-4", cost: 9, agoHours: 1),
            usage(.claudeCode, "claude-sonnet-4", cost: 6, agoHours: 2),
            usage(.claudeCode, "claude-haiku-4", cost: 3, agoHours: 3)
        ])
        let colors = cube.byModel.map(\.color)
        XCTAssertEqual(cube.byModel.count, 3)
        XCTAssertEqual(Set(colors).count, 3, "three same-family models must not share one colour")
    }

    /// Different families keep their own brand colour untouched — separation is for
    /// collisions, not a hash that throws the mapping away.
    func test_distinctFamiliesKeepTheirBrandColour() {
        let cube = makeCube([
            usage(.claudeCode, "claude-opus-4", cost: 9, agoHours: 1),
            usage(.codex, "gpt-5", cost: 6, agoHours: 2)
        ])
        XCTAssertEqual(cube.byModel.first?.color, DesignSystem.Colors.colorForModel("claude-opus-4"))
        XCTAssertEqual(cube.byModel.last?.color, DesignSystem.Colors.colorForModel("gpt-5"))
    }

    // MARK: - The total breakdown

    func test_totalIsAStackOfOneMatchingTheFlatCurve() {
        let cube = makeCube(spread)
        let bands = cube.bands(for: .total)
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands[0].values, cube.totalsPerBucket)
    }

    /// No spend is a real state on a fresh install. Every mode has to agree it is empty,
    /// or `.total` becomes the one cut that renders a flat zero line as a series.
    func test_noSpendYieldsNoBandsInAnyMode() {
        let cube = makeCube([])
        for breakdown in HomeSpendBreakdown.allCases {
            XCTAssertTrue(cube.bands(for: breakdown).isEmpty, "\(breakdown) invented a band")
        }
    }

    // MARK: - Scaling

    /// The rule that made the curve visible: scale to a high percentile so one 40×
    /// spike cannot squash the whole day onto the baseline. The spike still clips, and
    /// the peak readout still names it.
    func test_ceilingIgnoresALoneSpike() {
        let quiet = [Double](repeating: 2, count: 20)
        let ceiling = HomeSpendSeries.ceiling(of: quiet + [400])
        XCTAssertLessThan(ceiling, 400 * 0.2, "one spike must not become the whole scale")
        XCTAssertGreaterThan(ceiling, 0)
    }

    /// A flat day scales to itself — the percentile must not shrink a curve that has
    /// no outlier to protect it from.
    func test_ceilingOfAFlatDayIsThatDay() {
        XCTAssertEqual(HomeSpendSeries.ceiling(of: [Double](repeating: 3, count: 10)), 3, accuracy: 0.0001)
    }

    /// …and never collapses onto the floor on a nearly flat day, which would divide by
    /// something arbitrarily close to zero.
    func test_ceilingNeverCollapses() {
        XCTAssertGreaterThan(HomeSpendSeries.ceiling(of: [0, 0, 0, 7]), 0)
        XCTAssertEqual(HomeSpendSeries.ceiling(of: []), 0)
    }

    // MARK: - Helpers

    private var spread: [TokenUsage] {
        [
            usage(.claudeCode, "claude-opus-4", cost: 12.5, agoHours: 1),
            usage(.claudeCode, "claude-sonnet-4", cost: 4.25, agoHours: 3),
            usage(.codex, "gpt-5", cost: 7.5, agoHours: 5),
            usage(.codex, "claude-opus-4", cost: 1.75, agoHours: 9),
            usage(.cursor, "gemini-3-pro", cost: 3, agoHours: 14),
            usage(.deepSeek, "deepseek-v3", cost: 0.5, agoHours: 20)
        ]
    }

    private func makeCube(
        _ usages: [TokenUsage],
        buckets: Int = 48,
        limit: Int = HomeSpendSeries.bandLimit
    ) -> HomeSpendCube {
        HomeSpendSeries.cube(usages, buckets: buckets, now: now, window: window, limit: limit)
    }

    private func usage(
        _ provider: AgentProvider,
        _ model: String,
        cost: Double,
        agoHours: Double
    ) -> TokenUsage {
        let end = now.addingTimeInterval(-agoHours * 3600)
        return TokenUsage(
            provider: provider,
            sessionId: "\(provider.rawValue)-\(model)-\(agoHours)",
            projectName: "BurnBar",
            model: model,
            inputTokens: 100,
            outputTokens: 50,
            costUSD: cost,
            startTime: end.addingTimeInterval(-60),
            endTime: end
        )
    }
}

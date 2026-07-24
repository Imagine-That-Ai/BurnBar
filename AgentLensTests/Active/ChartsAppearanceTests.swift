import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

final class ChartsAppearanceTests: XCTestCase {

    // MARK: Defaults

    func test_default_matchesPreMoodGallery() {
        let appearance = ChartsAppearance.default
        XCTAssertEqual(appearance.paletteMood, .ember)
        XCTAssertEqual(appearance.density, .comfortable)
        XCTAssertEqual(appearance.columns, 2)
        XCTAssertEqual(appearance.primaryMetric, .cost)
        XCTAssertTrue(appearance.accentOverrides.isEmpty)
    }

    // MARK: Clamping & sanitizing

    func test_init_clampsColumnsToSupportedRange() {
        XCTAssertEqual(ChartsAppearance(columns: 1).columns, 2)
        XCTAssertEqual(ChartsAppearance(columns: 99).columns, 3)
        XCTAssertEqual(ChartsAppearance(columns: 3).columns, 3)
    }

    func test_init_dropsUnknownKindsSlotsAndRedundantOverrides() {
        let appearance = ChartsAppearance(accentOverrides: [
            "burnOverTime": "ocean",          // unknown slot
            "quantumOracle": "mix",           // unknown kind
            "providerMix": "mix",             // redundant (providerMix defaults to mix)
            "cacheROI": "burn"                // legitimate override
        ])
        XCTAssertEqual(appearance.accentOverrides, ["cacheROI": "burn"])
    }

    // MARK: Accent resolution

    func test_slot_defaultsToKindSemantics() {
        let appearance = ChartsAppearance.default
        XCTAssertEqual(appearance.slot(for: .burnOverTime), .burn)
        XCTAssertEqual(appearance.slot(for: .providerMix), .mix)
        XCTAssertEqual(appearance.slot(for: .cacheROI), .cache)
        XCTAssertEqual(appearance.slot(for: .reasoningShare), .reasoning)
        XCTAssertEqual(appearance.slot(for: .hourOfDayHeatmap), .rhythm)
        XCTAssertEqual(appearance.slot(for: .weekOverWeekDelta), .delta)
    }

    func test_setAccentSlot_storesAndClearsOverrides() {
        var appearance = ChartsAppearance.default
        appearance.setAccentSlot(.cache, for: .burnOverTime)
        XCTAssertEqual(appearance.slot(for: .burnOverTime), .cache)
        // Setting back to the default clears the stored entry.
        appearance.setAccentSlot(.burn, for: .burnOverTime)
        XCTAssertTrue(appearance.accentOverrides.isEmpty)
        XCTAssertEqual(appearance.slot(for: .burnOverTime), .burn)
    }

    func test_everyKind_resolvesAnAccentInEveryMood() {
        // The mapping must be total: every chart draws in every mood.
        for mood in ChartsPaletteMood.allCases {
            let appearance = ChartsAppearance(paletteMood: mood)
            for kind in ChartKind.allCases {
                _ = appearance.accent(for: kind)
            }
        }
    }

    // MARK: Persistence

    func test_jsonRoundTrip_preservesAllFields() throws {
        var appearance = ChartsAppearance(
            paletteMood: .orchid,
            density: .compact,
            columns: 3,
            primaryMetric: .tokens
        )
        appearance.setAccentSlot(.rhythm, for: .modelMix)

        let data = try XCTUnwrap(appearance.encoded())
        XCTAssertEqual(ChartsAppearance.decode(from: data), appearance)
    }

    func test_decode_unknownEnumCases_fallBackToDefaults() {
        let json = """
        {
          "paletteMood": "synthwave",
          "density": "ultra",
          "columns": 7,
          "primaryMetric": "vibes"
        }
        """
        let decoded = ChartsAppearance.decode(from: Data(json.utf8))
        XCTAssertEqual(decoded.paletteMood, .ember)
        XCTAssertEqual(decoded.density, .comfortable)
        XCTAssertEqual(decoded.columns, 3) // clamped, not reset
        XCTAssertEqual(decoded.primaryMetric, .cost)
    }

    func test_decode_garbage_fallsBackToDefault() {
        XCTAssertEqual(ChartsAppearance.decode(from: Data("not json".utf8)), .default)
    }

    func test_reset_restoresDefaults() {
        var appearance = ChartsAppearance(paletteMood: .meadow, density: .compact, columns: 3)
        appearance.setAccentSlot(.delta, for: .providerMix)
        appearance.reset()
        XCTAssertEqual(appearance, .default)
    }

    // MARK: Metric formatting

    func test_primaryMetric_formatsValues() {
        // NB: the literal formatters live in both OpenBurnBarCore and the app
        // module (ambiguous from tests), so assert shape, not exact strings.
        XCTAssertTrue(ChartsPrimaryMetric.cost.format(12.5).contains("12"))
        XCTAssertTrue(ChartsPrimaryMetric.tokens.format(1_250_000).contains("1"))
        XCTAssertNotEqual(
            ChartsPrimaryMetric.cost.format(12.5),
            ChartsPrimaryMetric.tokens.format(12.5)
        )
    }

    // MARK: Hero copy

    private func makeSnapshot(rows: [TokenUsage]) -> ChartsSnapshot {
        ChartsSnapshot.build(rows: rows, recentRows: rows, timeRange: .last7Days, usagesVersion: 0)
    }

    func test_heroCopy_emptyWindow_isInviting() {
        let line = ChartsHeroCopy.line(for: makeSnapshot(rows: []), metric: .cost)
        XCTAssertTrue(line.contains("quiet"))
    }

    func test_heroCopy_withPeakHour_leadsWithRhythm() {
        let snapshot = makeSnapshot(rows: ChartsSnapshotFixtures.sampleRows())
        XCTAssertNotNil(snapshot.peakWeekdayIndex)
        XCTAssertNotNil(snapshot.peakHour)
        let line = ChartsHeroCopy.line(for: snapshot, metric: .cost)
        XCTAssertTrue(line.contains("furnace hour"))
    }

    func test_heroCopy_speaksInBothMetrics() {
        let snapshot = makeSnapshot(rows: ChartsSnapshotFixtures.sampleRows())
        XCTAssertFalse(ChartsHeroCopy.line(for: snapshot, metric: .cost).isEmpty)
        XCTAssertFalse(ChartsHeroCopy.line(for: snapshot, metric: .tokens).isEmpty)
    }
}

import OpenBurnBarCore
import XCTest

@testable import OpenBurnBar

/// The Spend Lens splits one window of spend into API dollars, plan value, and
/// whatever resisted classification. The property that makes it trustworthy is
/// **conservation**: however the money is bucketed, none of it may disappear.
///
/// It did disappear. Split mode rendered only the API and Plan panes, and the
/// card headline totalled only those two, so any unclassified spend vanished
/// from the figures *and* the curves — while Overlay showed it. The two modes
/// reported different totals for identical data.
///
/// These tests pin conservation at the snapshot layer, which is where both
/// modes read from, so neither can drift from the other again.
final class SpendLensConservationTests: XCTestCase {

    /// A row whose provenance cannot be inferred from provider or source, so it
    /// lands in the unclassified bucket rather than being guessed into one of
    /// the other two.
    ///
    /// `.openCode` is in neither `subscriptionFirstProviders` nor
    /// `apiKeyFirstProviders`, so a provider-log row from it is exactly the
    /// case the classifier declines to guess at — which is the bucket this
    /// suite exists to prove is never dropped.
    private func unclassifiedRow(cost: Double, hoursAgo: Double, now: Date) -> TokenUsage {
        TokenUsage(
            provider: .openCode,
            sessionId: "session-unclassified",
            projectName: "",
            model: "mystery-model",
            inputTokens: 10,
            outputTokens: 10,
            costUSD: cost,
            startTime: now.addingTimeInterval(-hoursAgo * 3_600),
            endTime: now.addingTimeInterval(-(hoursAgo - 0.5) * 3_600),
            provenanceConfidence: .lowConfidenceEstimate
        )
    }

    private func snapshot(rows: [TokenUsage], now: Date) -> ChartsSnapshot {
        ChartsSnapshot.build(
            rows: rows,
            recentRows: rows,
            timeRange: .last7Days,
            usagesVersion: 1,
            now: now
        )
    }

    /// Every dollar lands in exactly one bucket.
    func testBucketsConserveTotalCost() throws {
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(unclassifiedRow(cost: 7.5, hoursAgo: 3, now: now))
        let snap = snapshot(rows: rows, now: now)

        XCTAssertEqual(
            snap.apiCost + snap.subscriptionCost + snap.unknownBillingCost,
            snap.totalCost,
            accuracy: 0.0001,
            """
            Spend Lens buckets do not sum to the window total. Money is being \
            dropped between API / Plan / Unclassified.
            """
        )
    }

    /// Each series has to carry its own bucket's money, or a pane draws a curve
    /// that disagrees with the number printed above it.
    func testEachSeriesSumsToItsBucketTotal() throws {
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(unclassifiedRow(cost: 7.5, hoursAgo: 3, now: now))
        rows.append(unclassifiedRow(cost: 2.25, hoursAgo: 30, now: now))
        let snap = snapshot(rows: rows, now: now)

        for (name, series, total) in [
            ("api", snap.apiBurnSeries, snap.apiCost),
            ("subscription", snap.subscriptionBurnSeries, snap.subscriptionCost),
            ("unknown", snap.unknownBurnSeries, snap.unknownBillingCost)
        ] {
            XCTAssertEqual(
                series.map(\.value).reduce(0, +), total, accuracy: 0.0001,
                "\(name) series does not sum to its bucket total"
            )
        }
    }

    /// The unclassified bucket must be drawable, not merely nameable. Split
    /// could not render it before because no series existed for it.
    func testUnclassifiedSpendProducesADrawableSeries() throws {
        let now = Date()
        let rows = [unclassifiedRow(cost: 4.0, hoursAgo: 5, now: now)]
        let snap = snapshot(rows: rows, now: now)

        XCTAssertGreaterThan(snap.unknownBillingCost, SpendLensBurnBody.disclosureFloor)
        XCTAssertFalse(snap.unknownBurnSeries.isEmpty, "no series to draw the unclassified pane from")
        XCTAssertGreaterThan(
            snap.unknownBurnSeries.map(\.value).max() ?? 0, 0,
            "unclassified series is all zeroes, so the pane would render an empty chart"
        )
    }

    /// All three series share the window's bucketing, so panes placed beside
    /// each other are reading the same x-axis.
    func testAllBillingSeriesShareTheWindowBucketing() throws {
        let now = Date()
        var rows = ChartsSnapshotFixtures.sampleRows(now: now)
        rows.append(unclassifiedRow(cost: 1.0, hoursAgo: 10, now: now))
        let snap = snapshot(rows: rows, now: now)

        let expected = snap.burnSeries.map(\.start)
        XCTAssertEqual(snap.apiBurnSeries.map(\.start), expected)
        XCTAssertEqual(snap.subscriptionBurnSeries.map(\.start), expected)
        XCTAssertEqual(snap.unknownBurnSeries.map(\.start), expected)
    }

    /// With nothing unclassified the disclosure stays silent, so the ordinary
    /// two-pane split is unchanged for the common case.
    func testNoUnclassifiedSpendStaysBelowTheDisclosureFloor() throws {
        let now = Date()
        let snap = snapshot(rows: ChartsSnapshotFixtures.sampleRows(now: now), now: now)
        XCTAssertLessThanOrEqual(snap.unknownBillingCost, SpendLensBurnBody.disclosureFloor)
    }
}

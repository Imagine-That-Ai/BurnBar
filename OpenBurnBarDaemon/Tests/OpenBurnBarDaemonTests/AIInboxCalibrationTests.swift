import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The learning loop.
///
/// The inbox ships with hand-picked thresholds, which are wrong for somebody.
/// These tests pin the two properties that make self-adjustment safe: it needs
/// real evidence before it acts, and it can never bury a detector entirely.
final class AIInboxCalibrationTests: XCTestCase {
    // MARK: - Evidence thresholds

    func test_singleComplaintDoesNotDemote() {
        var calibration = BurnBarAIInboxCalibration.empty
        calibration.recordFeedback(kind: .ciWaste, useful: false, now: Date())

        XCTAssertEqual(
            calibration.adjustedPriority(for: .ciWaste, proposed: .p1),
            .p1,
            "One thumbs-down is an opinion, not evidence"
        )
        XCTAssertNil(calibration.explanation(for: .ciWaste))
    }

    func test_repeatedNotUsefulDemotesByExactlyOneBand() {
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<8 {
            calibration.recordFeedback(kind: .costAnomaly, useful: false, now: Date())
        }

        XCTAssertEqual(calibration.adjustedPriority(for: .costAnomaly, proposed: .p1), .p2)
        XCTAssertEqual(calibration.adjustedPriority(for: .costAnomaly, proposed: .p2), .p3)
        XCTAssertNotNil(calibration.explanation(for: .costAnomaly))
    }

    /// The most important safety property: a disliked detector still reports,
    /// it just stops interrupting. Silencing must be an explicit user action.
    func test_demotionNeverSilencesAKind() {
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<40 {
            calibration.recordFeedback(kind: .stuckPR, useful: false, now: Date())
        }
        XCTAssertEqual(
            calibration.adjustedPriority(for: .stuckPR, proposed: .p4),
            .p4,
            "P4 is the floor — the item is still published and browsable"
        )
    }

    func test_usefulFeedbackKeepsNaturalPriority() {
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<8 {
            calibration.recordFeedback(kind: .ciWaste, useful: true, now: Date())
        }
        XCTAssertEqual(calibration.adjustedPriority(for: .ciWaste, proposed: .p1), .p1)
        XCTAssertGreaterThan(calibration.score(for: .ciWaste), 0)
    }

    /// Positive feedback must not let a detector escalate itself into an
    /// interruption it never claimed to deserve.
    func test_calibrationNeverPromotes() {
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<30 {
            calibration.recordFeedback(kind: .uncommittedWork, useful: true, now: Date())
        }
        XCTAssertEqual(calibration.adjustedPriority(for: .uncommittedWork, proposed: .p3), .p3)
    }

    // MARK: - Learning from resolutions

    /// The signal that costs the user nothing: an item that fixes itself within
    /// minutes was not worth raising.
    func test_fastSelfResolutionCountsAgainstAKind() {
        var calibration = BurnBarAIInboxCalibration.empty
        let start = Date()
        for index in 0..<8 {
            calibration.recordResolution(
                kind: .uncommittedWork,
                firstSeenAt: start.addingTimeInterval(Double(index) * 60),
                resolvedAt: start.addingTimeInterval(Double(index) * 60 + 120),
                now: start
            )
        }
        XCTAssertLessThan(calibration.score(for: .uncommittedWork), 0)
        XCTAssertEqual(calibration.adjustedPriority(for: .uncommittedWork, proposed: .p2), .p3)
        XCTAssertEqual(
            calibration.explanation(for: .uncommittedWork)?.contains("resolve on their own"),
            true
        )
    }

    /// An item that stood for days was worth raising, even if it eventually
    /// resolved.
    func test_durableItemsCountInFavourOfAKind() {
        var calibration = BurnBarAIInboxCalibration.empty
        let start = Date()
        for index in 0..<8 {
            calibration.recordResolution(
                kind: .promisedNotLanded,
                firstSeenAt: start,
                resolvedAt: start.addingTimeInterval(Double(index + 1) * 86_400),
                now: start
            )
        }
        XCTAssertGreaterThan(calibration.score(for: .promisedNotLanded), 0)
        XCTAssertEqual(calibration.adjustedPriority(for: .promisedNotLanded, proposed: .p2), .p2)
    }

    func test_mixedSignalStaysNeutral() {
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<5 {
            calibration.recordFeedback(kind: .stuckPR, useful: true, now: Date())
            calibration.recordFeedback(kind: .stuckPR, useful: false, now: Date())
        }
        XCTAssertEqual(calibration.score(for: .stuckPR), 0, accuracy: 0.01)
        XCTAssertEqual(calibration.adjustedPriority(for: .stuckPR, proposed: .p2), .p2)
    }

    // MARK: - Recovery

    /// A user who retunes a workflow (or changes their mind) must be able to
    /// climb back. Without decay, the first bad week would dominate forever.
    func test_decayLetsAKindRecover() {
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<30 {
            calibration.recordFeedback(kind: .ciWaste, useful: false, now: Date())
        }
        XCTAssertLessThan(calibration.score(for: .ciWaste), 0)

        for _ in 0..<40 {
            calibration.recordFeedback(kind: .ciWaste, useful: true, now: Date())
        }
        XCTAssertGreaterThan(
            calibration.score(for: .ciWaste),
            BurnBarAIInboxCalibration.demotionThreshold,
            "Sustained positive feedback must undo an earlier demotion"
        )
        XCTAssertEqual(calibration.adjustedPriority(for: .ciWaste, proposed: .p1), .p1)
    }

    func test_countersStayBoundedUnderSustainedUse() throws {
        var calibration = BurnBarAIInboxCalibration.empty
        for _ in 0..<500 {
            calibration.recordFeedback(kind: .brief, useful: true, now: Date())
        }
        let stats = try XCTUnwrap(calibration.kinds[BurnBarInboxItemKind.brief.rawValue])
        XCTAssertLessThanOrEqual(
            stats.sampleCount,
            60,
            "Decay must keep the counters from growing without limit"
        )
    }

    // MARK: - Persistence

    func test_calibrationRoundTripsThroughJSON() throws {
        var calibration = BurnBarAIInboxCalibration.empty
        calibration.recordFeedback(kind: .ciWaste, useful: false, now: Date())
        calibration.recordResolution(
            kind: .stuckPR,
            firstSeenAt: Date().addingTimeInterval(-600),
            resolvedAt: Date(),
            now: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            BurnBarAIInboxCalibration.self,
            from: try encoder.encode(calibration)
        )

        XCTAssertEqual(restored.kinds, calibration.kinds)
    }

    /// A kind added in a later release must start neutral rather than failing to
    /// decode the whole calibration.
    func test_unknownKindsDecodeAsNeutral() throws {
        let json = Data("""
            {"kinds": {"some_future_kind": {"useful": 3, "notUseful": 1,
             "quickResolutions": 0, "durableItems": 0}},
             "updatedAt": "2026-08-04T12:00:00Z"}
            """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let calibration = try decoder.decode(BurnBarAIInboxCalibration.self, from: json)

        XCTAssertEqual(calibration.score(for: .ciWaste), 0)
        XCTAssertEqual(calibration.adjustedPriority(for: .ciWaste, proposed: .p1), .p1)
    }
}

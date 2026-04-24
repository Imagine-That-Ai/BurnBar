import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - InsightBriefCard

@MainActor
final class InsightBriefCardTests: XCTestCase {

    func test_rendersWithTitleAndBody() throws {
        let view = InsightBriefCard(
            title: "Where you left off",
            bodyText: "Working on auth module",
            icon: "arrow.right",
            accent: .blue,
            action: {}
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(ViewType.Button.self))
    }

    func test_showsTitleText() throws {
        let view = InsightBriefCard(
            title: "Test Title",
            bodyText: "Test body content",
            icon: "star",
            accent: .red,
            action: {}
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(
            try sut.find(textWhere: { value, _ in
                value.caseInsensitiveCompare("Test Title") == .orderedSame
            })
        )
    }

    func test_showsBodyText() throws {
        let view = InsightBriefCard(
            title: "Title",
            bodyText: "Detailed body text here",
            icon: "star",
            accent: .green,
            action: {}
        )
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("Detailed body text here") }))
    }

    func test_actionCallbackFires() throws {
        var actionFired = false
        let view = InsightBriefCard(
            title: "Title",
            bodyText: "Body",
            icon: "star",
            accent: .blue
        ) {
            actionFired = true
        }
        let sut = try view.inspect()
        try sut.find(ViewType.Button.self).tap()
        XCTAssertTrue(actionFired)
    }
}

// MARK: - InsightBriefSnapshot Logic Tests

@MainActor
final class InsightBriefSnapshotTests: XCTestCase {

    func test_emptySnapshot_hasNoContent() {
        let snapshot = ViewTestFixtures.makeInsightBrief(
            whereLeftOff: nil,
            heaviestTaskTitle: nil,
            heaviestTaskCost: nil,
            heaviestTaskProject: nil
        )
        XCTAssertFalse(snapshot.hasInlineContent)
    }

    func test_snapshotWithWhereLeftOff_hasContent() {
        let snapshot = ViewTestFixtures.makeInsightBrief(whereLeftOff: "Something")
        XCTAssertTrue(snapshot.hasInlineContent)
    }

    func test_snapshotWithHeaviestTask_hasContent() {
        let snapshot = ViewTestFixtures.makeInsightBrief(
            whereLeftOff: nil,
            heaviestTaskTitle: "Big task",
            heaviestTaskCost: 5.0,
            heaviestTaskProject: "MyProject"
        )
        XCTAssertTrue(snapshot.hasInlineContent)
    }

    func test_snapshotWithModelShift_hasContent() {
        let snapshot = ViewTestFixtures.makeInsightBrief(modelShiftHeadline: "Switched to GPT-4o")
        XCTAssertTrue(snapshot.hasInlineContent)
    }

    func test_snapshotWithIncompleteHint_hasContent() {
        let snapshot = ViewTestFixtures.makeInsightBrief(incompleteHint: "Unfinished work")
        XCTAssertTrue(snapshot.hasInlineContent)
    }

    func test_rollupStatusLine_fresh_returnsNil() {
        let snapshot = ViewTestFixtures.makeInsightBrief(rollupFreshness: .fresh)
        XCTAssertNil(snapshot.rollupStatusLine)
    }

    func test_rollupStatusLine_stale_returnsMessage() {
        let snapshot = ViewTestFixtures.makeInsightBrief(rollupFreshness: .stale)
        XCTAssertNotNil(snapshot.rollupStatusLine)
    }

    func test_rollupStatusLine_customMessage() {
        let snapshot = ViewTestFixtures.makeInsightBrief(
            rollupFreshness: .rebuilding,
            rollupStatusMessage: "Rebuilding from scratch"
        )
        XCTAssertEqual(snapshot.rollupStatusLine, "Rebuilding from scratch")
    }

    func test_rollupStatusLine_rebuilding_returnsMessage() {
        let snapshot = ViewTestFixtures.makeInsightBrief(rollupFreshness: .rebuilding)
        XCTAssertEqual(snapshot.rollupStatusLine, "Workflow insights are rebuilding.")
    }

    func test_rollupStatusLine_unavailable_returnsMessage() {
        let snapshot = ViewTestFixtures.makeInsightBrief(rollupFreshness: .unavailable)
        XCTAssertEqual(snapshot.rollupStatusLine, "Workflow insights are unavailable.")
    }
}

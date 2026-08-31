import Foundation
import XCTest
@testable import OpenBurnBar

/// Covers the Memory (Pensieve) walkthrough content and pager: the copy the
/// modal teaches from, the live connection strings it must never drift from,
/// and the clamped page navigation.
final class MemoryMCPWalkthroughTests: XCTestCase {

    // MARK: - Content contract

    func testWalkthroughHasFiveStepsWithUniqueIDs() {
        let steps = MemoryWalkthroughContent.steps
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(Set(steps.map(\.id)).count, steps.count, "Step IDs must be unique")
        XCTAssertEqual(steps.map(\.id), Array(steps.indices), "Step IDs must match presentation order")
    }

    func testEveryStepHasCompleteCopy() {
        for step in MemoryWalkthroughContent.steps {
            XCTAssertFalse(step.symbol.isEmpty, "Step \(step.id) needs a symbol")
            XCTAssertFalse(step.eyebrow.isEmpty, "Step \(step.id) needs an eyebrow")
            XCTAssertFalse(step.title.isEmpty, "Step \(step.id) needs a title")
            XCTAssertFalse(step.body.isEmpty, "Step \(step.id) needs a body")
        }
    }

    func testConnectionStringsMatchTheLiveRemoteMCPValues() {
        // These are the same strings the Remote MCP card renders. If the real
        // endpoint or shim command ever changes, this test forces the
        // walkthrough copy to move with it.
        XCTAssertEqual(MemoryWalkthroughContent.endpoint, "https://mcp.burnbar.ai/mcp")
        XCTAssertEqual(MemoryWalkthroughContent.shimCommand, "openburnbar-mcp-remote mcp serve")
        XCTAssertEqual(MemoryWalkthroughContent.doctorCommand, "openburnbar mcp doctor")
        XCTAssertEqual(MemoryWalkthroughContent.setupURL.absoluteString, "https://burnbar.ai/product")
    }

    func testRecallStepTeachesExamplePrompts() {
        let recallStep = MemoryWalkthroughContent.steps[3]
        XCTAssertFalse(recallStep.chips.isEmpty, "The recall page must show example prompts")
        for chip in recallStep.chips {
            XCTAssertFalse(chip.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testControlStepPointsAtDataAndPrivacy() {
        let controlStep = MemoryWalkthroughContent.steps[4]
        XCTAssertTrue(controlStep.body.contains("Data & Privacy"))
        XCTAssertTrue(controlStep.body.contains("Panic"))
    }

    func testSpotlightAnchorsAreRealManifestAnchors() {
        let anchored = MemoryWalkthroughContent.steps.compactMap(\.tourAnchor)
        XCTAssertFalse(anchored.isEmpty, "At least one tour page should spotlight a real control")
        for anchor in anchored {
            XCTAssertTrue(
                SettingsManifest.visibleAnchorIDs.contains(anchor),
                "Spotlight anchor \(anchor) must be a visible anchor so Show me can scroll and halo it"
            )
            XCTAssertNotNil(
                SettingsManifest.all.first(where: { $0.anchorID == anchor }),
                "Spotlight anchor \(anchor) must have a manifest item or the deep link will 404"
            )
        }
    }

    func testSpotlightPagesCarryFindPaths() {
        for step in MemoryWalkthroughContent.steps where step.tourAnchor != nil {
            XCTAssertNotNil(step.findPath, "Step \(step.id) spotlights \(step.tourAnchor ?? "") but has no findPath breadcrumb")
            XCTAssertFalse(step.findPath?.isEmpty ?? true)
        }
        for step in MemoryWalkthroughContent.steps where step.tourAnchor == nil {
            XCTAssertNil(step.findPath, "Step \(step.id) has no spotlight anchor but carries a stray findPath")
        }
    }

    func testMemoryTourIsDiscoverableViaSearch() {
        let ids = Set(SettingsManifest.all.map(\.id))
        XCTAssertTrue(ids.contains("cloud.memoryTour"), "The Help/search re-entry must be a manifest item so ⌘K can find it")
        let hits = SettingsSearchEngine.search("memory tour", in: SettingsManifest.all)
        XCTAssertTrue(hits.contains(where: { $0.id == "cloud.memoryTour" }), "Searching 'memory tour' must surface the tour")
        let pensieveHits = SettingsSearchEngine.search("pensieve tour", in: SettingsManifest.all)
        XCTAssertTrue(pensieveHits.contains(where: { $0.id == "cloud.memoryTour" }))
    }

    // MARK: - Pager

    func testPagerAdvancesAndClampsAtLastPage() {
        var pager = MemoryWalkthroughPager(count: MemoryWalkthroughContent.steps.count)
        XCTAssertEqual(pager.page, 0)
        XCTAssertFalse(pager.canGoBack)
        XCTAssertFalse(pager.isLastPage)

        for _ in 0..<10 { pager.advance() }
        XCTAssertEqual(pager.page, MemoryWalkthroughContent.steps.count - 1, "Pager must clamp at the last page")
        XCTAssertTrue(pager.isLastPage)
        XCTAssertTrue(pager.canGoBack)
    }

    func testPagerRetreatsAndClampsAtFirstPage() {
        var pager = MemoryWalkthroughPager(count: MemoryWalkthroughContent.steps.count)
        pager.advance()
        pager.advance()
        for _ in 0..<10 { pager.retreat() }
        XCTAssertEqual(pager.page, 0, "Pager must clamp at the first page")
        XCTAssertFalse(pager.canGoBack)
        XCTAssertFalse(pager.isLastPage)
    }

    func testPagerNeverDividesByZeroForEmptyContent() {
        var pager = MemoryWalkthroughPager(count: 0)
        pager.advance()
        XCTAssertEqual(pager.page, 0)
        XCTAssertTrue(pager.isLastPage)
    }
}

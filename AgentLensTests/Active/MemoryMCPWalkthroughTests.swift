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

    func testMacCloudConsoleURLsPointAtTheLiveConsole() {
        // Every macOS surface that offers the web console (Cloud pane, the
        // walkthrough's "Open Pensieve online", the Data & Privacy landing)
        // must route members to the real deployed console, not a typo'd host.
        XCTAssertEqual(MacCloudConsoleURLs.root.absoluteString, "https://app.burnbar.ai")
        XCTAssertEqual(MacCloudConsoleURLs.pensieve.absoluteString, "https://app.burnbar.ai/pensieve")
        XCTAssertEqual(
            MemoryWalkthroughContent.consoleURL.absoluteString, "https://app.burnbar.ai/pensieve",
            "The walkthrough's online action must deep-link to the Pensieve dashboard, not the console root"
        )
    }

    func testControlStepSurfacesTheWebConsole() {
        let step = MemoryWalkthroughContent.steps[4]
        XCTAssertTrue(
            step.body.contains("app.burnbar.ai"),
            "The Control page must tell members the same data is visible and governable in the web console"
        )
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

    // MARK: - Spotlight destinations are real, actionable controls

    func testZeroSetupStepSpotlightsOnDeviceMemoryControls() {
        let step = MemoryWalkthroughContent.steps[1]
        XCTAssertEqual(
            step.tourAnchor, SettingsAnchor.indexingMemory,
            "The 'saves itself' page must land on the real on-device Memory controls, not the decorative Cloud hero"
        )
        XCTAssertEqual(step.findPath, "Settings › General › Indexing")

        let item = SettingsManifest.all.first { $0.anchorID == step.tourAnchor }
        XCTAssertEqual(item?.tab, .general)
        XCTAssertEqual(item?.pageRoute, .indexing)
    }

    func testZeroSetupCopyDoesNotSellCloudProAsTheSwitch() {
        let step = MemoryWalkthroughContent.steps[1]
        XCTAssertFalse(
            step.body.contains("Sign in once with Cloud Pro"),
            "Local memory is consent-gated, not Cloud-Pro-gated; the copy must not sell a paywall as the switch"
        )
        XCTAssertTrue(step.body.contains("this Mac"), "The copy must say memory runs on-device")
        XCTAssertTrue(step.body.contains("free"), "The copy must tell the user the controls are free")
    }

    func testConnectStepSpotlightsTheRealLinkCLIAction() {
        let step = MemoryWalkthroughContent.steps[2]
        XCTAssertEqual(step.tourAnchor, SettingsAnchor.cloudRemoteMCPConnect)
        XCTAssertTrue(step.body.contains("Link this Mac's CLI"))

        let item = SettingsManifest.all.first { $0.anchorID == SettingsAnchor.cloudRemoteMCPConnect }
        XCTAssertTrue(
            item?.title.contains("Link this Mac's CLI") ?? false,
            "The connect anchor's manifest item must name the same action the walkthrough tells the user to tap"
        )
    }

    func testControlStepSpotlightsThePensieveWorkbench() {
        let step = MemoryWalkthroughContent.steps[4]
        XCTAssertEqual(step.tourAnchor, SettingsAnchor.dataControlCenterInventory)

        let item = SettingsManifest.all.first { $0.anchorID == step.tourAnchor }
        XCTAssertEqual(item?.pageRoute, .dataControlCenterRoot)

        // The Control page must be honest about what's free vs. Cloud Pro so
        // a free user never reads a promise that dead-ends on a paywall.
        XCTAssertTrue(step.body.contains("General › Indexing"), "Free on-device controls must be named")
        XCTAssertTrue(step.body.contains("Cloud Pro"), "The workbench's tier requirement must be named")
    }

    func testSpotlightPreviewsMatchTheirDestinations() {
        for step in MemoryWalkthroughContent.steps where step.tourAnchor != nil {
            XCTAssertNotNil(step.previewIcon, "Step \(step.id) has a spotlight but no preview icon")
            XCTAssertFalse(step.previewTitle?.isEmpty ?? true,
                           "Step \(step.id) has a spotlight but no preview title")
            XCTAssertFalse(step.previewSubtitle?.isEmpty ?? true,
                           "Step \(step.id) has a spotlight but no preview subtitle")
        }
        for step in MemoryWalkthroughContent.steps where step.tourAnchor == nil {
            XCTAssertNil(step.previewIcon, "Step \(step.id) has no spotlight but carries a stray preview icon")
            XCTAssertNil(step.previewTitle, "Step \(step.id) has no spotlight but carries a stray preview title")
            XCTAssertNil(step.previewSubtitle, "Step \(step.id) has no spotlight but carries a stray preview subtitle")
        }
    }

    func testOnDeviceMemoryControlsAreSearchable() {
        let hits = SettingsSearchEngine.search("memory controls", in: SettingsManifest.all)
        XCTAssertTrue(
            hits.contains(where: { $0.id == "general.indexing.memory" }),
            "Searching 'memory controls' must surface the on-device Memory section"
        )
        let pensieveHits = SettingsSearchEngine.search("pensieve", in: SettingsManifest.all)
        XCTAssertTrue(
            pensieveHits.contains(where: { $0.id == "general.indexing.memory" }),
            "A Pensieve search must surface the free on-device controls, not only Cloud surfaces"
        )
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

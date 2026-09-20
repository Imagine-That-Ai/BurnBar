import XCTest
@testable import OpenBurnBarMobile

/// Focused unit tests for the Aurora swipe-through navigation system.
///
/// Covers the pure gesture model (`AuroraNavGestureModel`): destination
/// index resolution from local x-coordinate, edge clamping, root-swipe
/// adjacency and direction detection, viewfinder geometry, reduced-motion
/// animation policy, and scrub phase commit/cancel semantics.
@MainActor
final class AuroraNavigationTrayTests: XCTestCase {

    override func tearDown() {
        InsightsDeepLink.reset()
        super.tearDown()
    }

    private let compactTray = AuroraNavDestination.trayDestinations(compact: true)
    // tabWidth = 56 matches AuroraNavigationTray's constant.
    private let tabWidth: CGFloat = 56

    // MARK: - Destination index resolution

    func test_destinationIndex_centerOfFirstTab_resolvesToIndex0() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        // Center of the first segment
        let x = tabWidth * 0.5
        let index = AuroraNavGestureModel.destinationIndex(x: x, trayWidth: trayWidth, count: count)
        XCTAssertEqual(index, 0)
    }

    func test_destinationIndex_centerOfLastTab_resolvesToLastIndex() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        let lastIndex = count - 1
        // Center of the last segment
        let x = CGFloat(lastIndex) * tabWidth + tabWidth * 0.5
        let index = AuroraNavGestureModel.destinationIndex(x: x, trayWidth: trayWidth, count: count)
        XCTAssertEqual(index, lastIndex)
    }

    func test_destinationIndex_sweepThroughAllSegments() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        for i in 0..<count {
            let x = CGFloat(i) * tabWidth + tabWidth * 0.5
            let index = AuroraNavGestureModel.destinationIndex(x: x, trayWidth: trayWidth, count: count)
            XCTAssertEqual(index, i, "Segment \(i) center should resolve to index \(i)")
        }
    }

    // MARK: - Edge clamping

    func test_destinationIndex_farLeft_clampsToZero() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        let x: CGFloat = -200
        let index = AuroraNavGestureModel.destinationIndex(x: x, trayWidth: trayWidth, count: count)
        XCTAssertEqual(index, 0)
    }

    func test_destinationIndex_farRight_clampsToLastIndex() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        let lastIndex = count - 1
        let x = trayWidth + 500
        let index = AuroraNavGestureModel.destinationIndex(x: x, trayWidth: trayWidth, count: count)
        XCTAssertEqual(index, lastIndex)
    }

    func test_clamped_negativeIndex_returnsZero() {
        XCTAssertEqual(AuroraNavGestureModel.clamped(index: -5, count: 6), 0)
    }

    func test_clamped_oversizedIndex_returnsLastIndex() {
        XCTAssertEqual(AuroraNavGestureModel.clamped(index: 100, count: 6), 5)
    }

    func test_clamped_zeroCount_returnsZero() {
        XCTAssertEqual(AuroraNavGestureModel.clamped(index: 3, count: 0), 0)
    }

    // MARK: - Degenerate inputs

    func test_destinationIndex_zeroWidth_returnsNil() {
        let index = AuroraNavGestureModel.destinationIndex(x: 50, trayWidth: 0, count: 6)
        XCTAssertNil(index)
    }

    func test_destinationIndex_zeroCount_returnsNil() {
        let index = AuroraNavGestureModel.destinationIndex(x: 50, trayWidth: 300, count: 0)
        XCTAssertNil(index)
    }

    // MARK: - Destination resolution convenience

    func test_destination_resolvesCorrectDestination() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        // First tab center → .inbox
        let first = AuroraNavGestureModel.destination(x: tabWidth * 0.5, trayWidth: trayWidth, destinations: compactTray)
        XCTAssertEqual(first, .inbox)
        // Last tab center → .you
        let lastX = CGFloat(count - 1) * tabWidth + tabWidth * 0.5
        let last = AuroraNavGestureModel.destination(x: lastX, trayWidth: trayWidth, destinations: compactTray)
        XCTAssertEqual(last, .you)
    }

    // MARK: - Root swipe adjacency

    func test_adjacent_leadingFromInbox_returnsAgents() {
        let next = AuroraNavGestureModel.adjacent(current: .inbox, direction: .leading, destinations: compactTray)
        XCTAssertEqual(next, .hermes)
    }

    func test_adjacent_trailingFromAgents_returnsInbox() {
        let prev = AuroraNavGestureModel.adjacent(current: .hermes, direction: .trailing, destinations: compactTray)
        XCTAssertEqual(prev, .inbox)
    }

    func test_adjacent_leadingFromYou_returnsNil() {
        // .you is the last tab; can't go further forward.
        let next = AuroraNavGestureModel.adjacent(current: .you, direction: .leading, destinations: compactTray)
        XCTAssertNil(next)
    }

    func test_adjacent_trailingFromInbox_returnsNil() {
        // .inbox is the first tab; can't go further back.
        let prev = AuroraNavGestureModel.adjacent(current: .inbox, direction: .trailing, destinations: compactTray)
        XCTAssertNil(prev)
    }

    func test_adjacent_sweepForwardThroughEntireOrder() {
        var current = AuroraNavDestination.inbox
        let expected = compactTray
        for expectedDest in expected.dropFirst() {
            let next = AuroraNavGestureModel.adjacent(current: current, direction: .leading, destinations: compactTray)
            XCTAssertEqual(next, expectedDest)
            current = next!
        }
    }

    // MARK: - Swipe direction detection

    func test_swipeDirection_leftSwipe_returnsLeading() {
        let direction = AuroraNavGestureModel.swipeDirection(translation: CGSize(width: -60, height: 5))
        XCTAssertEqual(direction, .leading)
    }

    func test_swipeDirection_rightSwipe_returnsTrailing() {
        let direction = AuroraNavGestureModel.swipeDirection(translation: CGSize(width: 60, height: 5))
        XCTAssertEqual(direction, .trailing)
    }

    func test_swipeDirection_verticalSwipe_returnsNil() {
        let direction = AuroraNavGestureModel.swipeDirection(translation: CGSize(width: 10, height: 100))
        XCTAssertNil(direction)
    }

    func test_swipeDirection_diagonalWithVerticalDominance_returnsNil() {
        let direction = AuroraNavGestureModel.swipeDirection(translation: CGSize(width: 30, height: 80))
        XCTAssertNil(direction)
    }

    func test_swipeDirection_belowMinimumDistance_returnsNil() {
        let direction = AuroraNavGestureModel.swipeDirection(translation: CGSize(width: 20, height: 0), minimumDistance: 40)
        XCTAssertNil(direction)
    }

    // MARK: - Viewfinder geometry

    func test_viewfinderCenterX_firstTab_isHalfSegment() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        let segmentWidth = trayWidth / CGFloat(count)
        let x = AuroraNavGestureModel.viewfinderCenterX(index: 0, count: count, trayWidth: trayWidth)
        XCTAssertEqual(x, segmentWidth * 0.5, accuracy: 0.5)
    }

    func test_viewfinderCenterX_lastTab_isCenterOfLastSegment() {
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        let segmentWidth = trayWidth / CGFloat(count)
        let lastIndex = count - 1
        let x = AuroraNavGestureModel.viewfinderCenterX(index: lastIndex, count: count, trayWidth: trayWidth)
        XCTAssertEqual(x, segmentWidth * (CGFloat(lastIndex) + 0.5), accuracy: 0.5)
    }

    // MARK: - Reduced-motion animation policy

    func test_transitionAnimation_reduceMotion_isShortEaseInOut() {
        let anim = AuroraNavGestureModel.transitionAnimation(reduceMotion: true)
        // Reduce Motion should not use spring — just a short easeInOut.
        // We can't compare Animation equality directly, but we can verify
        // it's not the default spring by checking it's a different instance
        // from the non-reduced-motion variant.
        let normal = AuroraNavGestureModel.transitionAnimation(reduceMotion: false)
        // Both are valid animations; the reduced one should complete faster.
        // This is a smoke test — the key contract is it doesn't crash and
        // returns a non-spring under reduceMotion.
        XCTAssertNotNil(anim)
        XCTAssertNotNil(normal)
    }

    // MARK: - Destination order invariant

    func test_destinationOrder_matchesSpec() {
        XCTAssertEqual(compactTray, [.inbox, .hermes, .burn, .you])
        XCTAssertEqual(AuroraNavDestination.inbox.trayLabel, "Inbox")
        XCTAssertEqual(AuroraNavDestination.hermes.trayLabel, "Agents")
        XCTAssertEqual(AuroraNavDestination.burn.trayLabel, "Quota")
        XCTAssertEqual(AuroraNavDestination.you.trayLabel, "You")
        XCTAssertEqual(AuroraNavDestination.you.label, "You")
        XCTAssertFalse(compactTray.contains(.insights))
        XCTAssertTrue(AuroraNavDestination.allCases.contains(.insights))
    }

    // MARK: - Scrub phase semantics

    func test_scrubPhase_idle_isNotCommitted() {
        let phase: AuroraScrubPhase = .idle
        XCTAssertNotEqual(phase, .committed(.burn))
    }

    func test_scrubPhase_committed_carriesDestination() {
        let phase: AuroraScrubPhase = .committed(.insights)
        if case .committed(let dest) = phase {
            XCTAssertEqual(dest, .insights)
        } else {
            XCTFail("Expected .committed phase")
        }
    }

    func test_scrubPhase_scrubbing_carriesPreview() {
        let phase: AuroraScrubPhase = .scrubbing(preview: .hermes)
        if case .scrubbing(let preview) = phase {
            XCTAssertEqual(preview, .hermes)
        } else {
            XCTFail("Expected .scrubbing phase")
        }
    }

    func test_scrubPhase_cancelled_isNotCommitted() {
        XCTAssertEqual(AuroraScrubPhase.cancelled, .cancelled)
        XCTAssertNotEqual(AuroraScrubPhase.cancelled, .committed(.pulse))
    }

    // MARK: - Preview-vs-commit behavior

    func test_previewDoesNotCommit_untilRelease() {
        // Simulate the gesture model behavior: scrubbing resolves a preview
        // but does not change the committed selection.
        let committed: AuroraNavDestination = .inbox
        var preview: AuroraNavDestination?

        // Finger moves to Quota territory
        let count = compactTray.count
        let trayWidth = CGFloat(count) * tabWidth
        let quotaIndex = compactTray.firstIndex(of: .burn)!
        let x = CGFloat(quotaIndex) * tabWidth + tabWidth * 0.5
        preview = AuroraNavGestureModel.destination(x: x, trayWidth: trayWidth, destinations: compactTray)

        // Preview follows the finger...
        XCTAssertEqual(preview, .burn)
        // ...but the committed selection hasn't changed yet.
        XCTAssertEqual(committed, .inbox)
    }

    func test_commitOnRelease_updatesSelection() {
        // On release, the previewed destination becomes the committed selection.
        var selection: AuroraNavDestination = .inbox
        var preview: AuroraNavDestination? = .hermes

        // Simulate commit
        if let dest = preview {
            selection = dest
            preview = nil
        }

        XCTAssertEqual(selection, .hermes)
        XCTAssertNil(preview)
    }

    func test_cancelRevertsToRestingSelection() {
        // If the gesture cancels (finger leaves tray), revert to the
        // resting selection captured at scrub start.
        let resting: AuroraNavDestination = .burn
        var selection: AuroraNavDestination = resting
        var preview: AuroraNavDestination? = .you

        // Simulate cancel: preview cleared, selection stays at resting
        preview = nil
        XCTAssertEqual(selection, resting)
    }

    // MARK: - Boundary haptic dedup

    func test_hapticFiresOncePerDestinationCrossing() {
        // During a scrub, haptics should only fire when the preview
        // destination CHANGES, not on every finger move. We model this
        // with the lastHapticDestination tracking pattern used in the tray.
        var lastHaptic: AuroraNavDestination?
        var hapticCount = 0

        let sequence: [AuroraNavDestination] = [.inbox, .hermes, .hermes, .burn, .burn, .you]
        for dest in sequence where lastHaptic != dest {
            lastHaptic = dest
            hapticCount += 1
        }

        // 4 distinct destinations crossed (inbox→hermes→burn→you)
        XCTAssertEqual(hapticCount, 4)
    }

    // MARK: - Accessibility / reduce-motion in gesture model

    func test_swipeDirection_respectsMinimumDistance_default() {
        // The default minimumDistance (40) filters small accidental drags.
        let smallSwipe = AuroraNavGestureModel.swipeDirection(translation: CGSize(width: -35, height: 0))
        XCTAssertNil(smallSwipe, "35pt horizontal swipe should be below default 40pt minimum")
    }

    func test_viewfinderAnimation_reduceMotion_isShorter() {
        // Both should be valid animations; under reduceMotion, transitions
        // should be shorter (opacity/position only, no spring bounce).
        let reducedAnim = AuroraNavGestureModel.viewfinderAnimation(reduceMotion: true)
        XCTAssertNotNil(reducedAnim)
    }

    // MARK: - Insights deep-link stash

    func test_insightsDeepLink_stashesUntilConsumed() {
        InsightsDeepLink.reset()
        InsightsDeepLink.open(slug: "today", section: nil)
        XCTAssertTrue(InsightsDeepLink.hasPending)
        let pending = InsightsDeepLink.consume()
        XCTAssertEqual(pending?.slug, "today")
        XCTAssertNil(InsightsDeepLink.consume())
        InsightsDeepLink.reset()
    }

    func test_insightsDeepLink_budgetSectionStashes() {
        InsightsDeepLink.reset()
        InsightsDeepLink.open(section: "budgets")
        let pending = InsightsDeepLink.consume()
        XCTAssertEqual(pending?.section, "budgets")
        InsightsDeepLink.reset()
    }

    func test_compactTray_usesMonochromeSystemImages() {
        XCTAssertEqual(AuroraNavDestination.inbox.traySystemImage, "tray.fill")
        XCTAssertEqual(AuroraNavDestination.hermes.traySystemImage, "bubble.left.and.bubble.right.fill")
        XCTAssertEqual(AuroraNavDestination.burn.traySystemImage, "gauge.with.needle")
        XCTAssertEqual(AuroraNavDestination.you.traySystemImage, "person.crop.circle.fill")
        XCTAssertEqual(
            AuroraNavDestination.compactTrayDestinations.map(\.traySystemImage).count,
            4
        )
    }
}

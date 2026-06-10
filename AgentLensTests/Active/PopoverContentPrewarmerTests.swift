import XCTest
@testable import OpenBurnBar

/// Behavior contract for the menu-bar popover prewarm scheduler
/// (docs/architecture/macos-performance.md §15): one rebuild per burst,
/// never while the popover is shown, and re-armable after every turn so a
/// factory reinstall always invalidates stale content.
@MainActor
final class PopoverContentPrewarmerTests: XCTestCase {

    private final class Harness {
        var shown = false
        var primeCount = 0
        var pendingWork: [() -> Void] = []
        private(set) var prewarmer: PopoverContentPrewarmer!

        @MainActor
        init() {
            prewarmer = PopoverContentPrewarmer(
                isPopoverShown: { [unowned self] in shown },
                prime: { [unowned self] in primeCount += 1 },
                scheduler: { [unowned self] work in pendingWork.append(work) }
            )
        }

        func drain() {
            let work = pendingWork
            pendingWork = []
            work.forEach { $0() }
        }
    }

    func testSchedulePrime_buildsOnceOnNextTurn() {
        let harness = Harness()
        harness.prewarmer.schedulePrime()
        XCTAssertEqual(harness.primeCount, 0, "Prime must run off the scheduling turn")
        harness.drain()
        XCTAssertEqual(harness.primeCount, 1)
    }

    func testSchedulePrime_coalescesBursts() {
        let harness = Harness()
        // A factory reinstall and a close can land in the same turn.
        harness.prewarmer.schedulePrime()
        harness.prewarmer.schedulePrime()
        harness.prewarmer.schedulePrime()
        harness.drain()
        XCTAssertEqual(harness.primeCount, 1)
    }

    func testSchedulePrime_skipsWhileShown_thenReArms() {
        let harness = Harness()
        harness.shown = true
        harness.prewarmer.schedulePrime()
        harness.drain()
        XCTAssertEqual(harness.primeCount, 0, "Never replace live content mid-display")

        // The close re-prime picks up the latest factory.
        harness.shown = false
        harness.prewarmer.schedulePrime()
        harness.drain()
        XCTAssertEqual(harness.primeCount, 1)
    }

    func testSchedulePrime_reArmsAfterEachTurn() {
        let harness = Harness()
        harness.prewarmer.schedulePrime()
        harness.drain()
        harness.prewarmer.schedulePrime()
        harness.drain()
        XCTAssertEqual(harness.primeCount, 2, "Every close/reinstall must be able to rebuild fresh content")
    }
}

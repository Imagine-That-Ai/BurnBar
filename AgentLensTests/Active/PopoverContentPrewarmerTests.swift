import AppKit
import SwiftUI
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

/// `AppDelegate` half of the §15 prewarm wiring: `installPopoverPrewarming`
/// must hook the router's factory-change signal, prime immediately when the
/// factory already landed, rebuild real `NSPopover` content off the click
/// path, and re-prime after every close. The status item never exists in
/// the XCTest host, so these drive the internal seams directly.
@MainActor
final class AppDelegatePopoverPrewarmWiringTests: XCTestCase {

    private var savedFactory: ((@escaping () -> Void) -> AnyView)?
    private var savedFactoryChangedHook: (() -> Void)?

    override func setUp() {
        super.setUp()
        savedFactory = AppCommandRouter.shared.makeMenuBarPopoverContent
        savedFactoryChangedHook = AppCommandRouter.shared.onMenuBarPopoverFactoryChanged
        // Detach the hook BEFORE clearing the factory so resetting state
        // never pings whatever the app host installed.
        AppCommandRouter.shared.onMenuBarPopoverFactoryChanged = nil
        AppCommandRouter.shared.makeMenuBarPopoverContent = nil
    }

    override func tearDown() {
        AppCommandRouter.shared.onMenuBarPopoverFactoryChanged = nil
        AppCommandRouter.shared.makeMenuBarPopoverContent = savedFactory
        AppCommandRouter.shared.onMenuBarPopoverFactoryChanged = savedFactoryChangedHook
        savedFactory = nil
        savedFactoryChangedHook = nil
        super.tearDown()
    }

    /// The prewarmer schedules on the next main-queue turn; XCTest's
    /// `wait(for:)` pumps the main run loop so that turn executes.
    private func drainMainQueue() {
        let turn = expectation(description: "main queue turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 5)
    }

    func testInstallPopoverPrewarming_withFactoryAlreadyInstalled_primesOffTheClickPath() {
        let delegate = AppDelegate()
        AppCommandRouter.shared.makeMenuBarPopoverContent = { _ in AnyView(Text("Prewarmed")) }

        delegate.installPopoverPrewarming()
        XCTAssertNotNil(delegate.popoverPrewarmer)
        XCTAssertNil(
            delegate.popover?.contentViewController,
            "Priming must happen on the NEXT turn, never synchronously inside the install"
        )

        drainMainQueue()

        let popover = delegate.popover
        XCTAssertNotNil(popover?.contentViewController, "The prime must build real popover content")
        XCTAssertEqual(popover?.behavior, .transient)
        XCTAssertTrue(popover?.delegate === delegate)
        let size = popover?.contentViewController?.view.fittingSize ?? .zero
        XCTAssertGreaterThan(size.width, 1, "The prime must pay the first layout off the click path")
    }

    func testFactoryInstall_afterWiring_schedulesPrime() {
        let delegate = AppDelegate()
        delegate.installPopoverPrewarming()
        drainMainQueue()
        XCTAssertNil(delegate.popover, "No factory yet — nothing to prewarm")

        // The router's didSet pings the freshly installed hook.
        AppCommandRouter.shared.makeMenuBarPopoverContent = { _ in AnyView(Text("Runtime ready")) }
        drainMainQueue()

        XCTAssertNotNil(
            delegate.popover?.contentViewController,
            "A late factory install (runtime context ready) must trigger a prewarm"
        )
    }

    func testPopoverDidClose_clearsContent_thenReprimesNextTurn() {
        let delegate = AppDelegate()
        AppCommandRouter.shared.makeMenuBarPopoverContent = { _ in AnyView(Text("Fresh state")) }
        delegate.installPopoverPrewarming()
        drainMainQueue()
        let primedController = delegate.popover?.contentViewController
        XCTAssertNotNil(primedController)

        delegate.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertNil(
            delegate.popover?.contentViewController,
            "Close must clear content for fresh state on next show (fd19d53ac)"
        )

        drainMainQueue()
        let reprimedController = delegate.popover?.contentViewController
        XCTAssertNotNil(reprimedController, "The close re-prime must rebuild content off the click path")
        XCTAssertFalse(
            reprimedController === primedController,
            "The re-prime must build NEW content, never freeze the stale controller back in"
        )
    }

    func testPrimePopoverContent_withoutFactory_leavesPopoverUntouched() {
        let delegate = AppDelegate()
        delegate.primePopoverContent()
        XCTAssertNil(delegate.popover, "Priming without a factory must not fabricate an empty popover")
    }

    func testInstalledContent_handsFactoryADismissHandlerThatClosesThePopover() {
        let delegate = AppDelegate()
        var capturedDismiss: (() -> Void)?
        AppCommandRouter.shared.makeMenuBarPopoverContent = { onDismiss in
            capturedDismiss = onDismiss
            return AnyView(Text("Dismissable"))
        }

        delegate.primePopoverContent()

        XCTAssertNotNil(delegate.popover?.contentViewController)
        let dismiss = capturedDismiss
        XCTAssertNotNil(dismiss, "The content factory must receive a working dismiss handler")
        // Closing an unshown popover is a no-op; the pin here is that the
        // handler routes to performClose on the SAME popover instance and
        // never crashes after a re-prime replaced the content.
        dismiss?()
        XCTAssertNotNil(delegate.popover)
    }

    func testPrimePopoverContent_rebuildsFromCurrentFactory() {
        let delegate = AppDelegate()
        AppCommandRouter.shared.makeMenuBarPopoverContent = { _ in AnyView(Text("First")) }
        delegate.primePopoverContent()
        let first = delegate.popover?.contentViewController
        XCTAssertNotNil(first)

        // A factory reinstall (e.g. EmptyView fallback -> real runtime
        // content) must never freeze stale content into the popover.
        AppCommandRouter.shared.makeMenuBarPopoverContent = { _ in AnyView(Text("Second")) }
        delegate.primePopoverContent()
        let second = delegate.popover?.contentViewController
        XCTAssertNotNil(second)
        XCTAssertFalse(second === first, "Re-priming must rebuild from the CURRENT factory")
    }
}

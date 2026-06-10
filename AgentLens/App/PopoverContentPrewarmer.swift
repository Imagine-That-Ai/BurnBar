import Foundation

/// Schedules menu-bar popover content (re)builds OFF the click path.
///
/// `popoverDidClose` nils the popover's `contentViewController` on every
/// close (deliberate fresh-state fix, fd19d53ac), so without prewarming
/// every click rebuilt the full `MenuBarPopoverView` hierarchy +
/// `NSHostingController` and paid a synchronous `fittingSize` layout
/// inside the click handler. The prewarmer re-primes:
///   * when `AppCommandRouter.makeMenuBarPopoverContent` is (re)installed
///     — i.e. exactly when the runtime context becomes ready, never on a
///     fixed timer (a timer could freeze the startup-recovery `EmptyView`
///     fallback into the popover), and
///   * on the next main-queue turn after each close.
///
/// Decision logic is extracted here so it is unit-testable
/// (`PopoverContentPrewarmerTests`); the actual content build stays in
/// `AppDelegate.primePopoverContent`.
///
/// See docs/architecture/macos-performance.md §15.
@MainActor
final class PopoverContentPrewarmer {
    private let isPopoverShown: () -> Bool
    private let prime: () -> Void
    private let scheduler: (@escaping () -> Void) -> Void
    private(set) var isPrimeScheduled = false

    init(
        isPopoverShown: @escaping () -> Bool,
        prime: @escaping () -> Void,
        scheduler: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.async { work() }
        }
    ) {
        self.isPopoverShown = isPopoverShown
        self.prime = prime
        self.scheduler = scheduler
    }

    /// Coalesces bursts (a factory reinstall and a close can land in the
    /// same turn) into one rebuild on the next scheduler turn. Skipped
    /// while the popover is shown — replacing live content mid-display is
    /// never correct, and the close re-prime picks up the latest factory.
    func schedulePrime() {
        guard !isPrimeScheduled else { return }
        isPrimeScheduled = true
        scheduler { [weak self] in
            guard let self else { return }
            self.isPrimeScheduled = false
            guard !self.isPopoverShown() else { return }
            self.prime()
        }
    }
}

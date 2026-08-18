import Foundation
import Observation
import OpenBurnBarKernel

/// The loop that makes standing orders actually run (W6 of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// Deliberately thin. Every decision — what is due, where it goes, what waits —
/// lives in `StandingOrderRuntime` in the Kernel, which is unit-tested without a
/// database or a clock. This type only supplies the clock, the fleet, and the
/// two side effects: dispatch, and mark fired.
@MainActor
@Observable
final class StandingOrderRuntimeHost {
    /// A minute is fine granularity for a rhythm measured in hours, and it
    /// keeps a sleeping Mac from waking on our account.
    static let tickInterval: TimeInterval = 60

    private(set) var lastTickAt: Date?
    private(set) var lastDispatchCount = 0
    private(set) var lastDeferralCount = 0

    private let store: StandingOrderStore
    private let directory: HermesBodyDirectory
    private let dispatcher: MacWandMissionDispatcher
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(
        store: StandingOrderStore,
        directory: HermesBodyDirectory,
        dispatcher: MacWandMissionDispatcher
    ) {
        self.store = store
        self.directory = directory
        self.dispatcher = dispatcher
    }

    /// The fleet directory is shared with the other War Room hosts, so its
    /// listener is started and stopped by whoever owns it — stopping it here
    /// would starve every other reader.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Self.tickInterval)) // try?-ok(cancellation only; the loop condition handles it)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    deinit {
        loop?.cancel()
    }

    /// One pass. Separated from the loop so it can be driven directly.
    func tick(now: Date = Date()) async {
        lastTickAt = now
        let orders: [StandingOrder]
        do {
            orders = try await store.fetchOrders()
        } catch {
            AppLogger.dataStore.silentFailure("standing_order_fetch_failed", error: error)
            return
        }
        guard !orders.isEmpty else {
            lastDispatchCount = 0
            lastDeferralCount = 0
            return
        }

        let plan = StandingOrderRuntime.plan(
            orders: orders,
            fleet: directory.fleetSnapshot(now: now),
            now: now
        )
        lastDispatchCount = plan.dispatches.count
        lastDeferralCount = plan.deferrals.count

        for dispatch in plan.dispatches {
            await fire(dispatch, now: now)
        }
    }

    private func fire(_ dispatch: StandingOrderDispatch, now: Date) async {
        do {
            _ = try await dispatcher.dispatch(
                title: dispatch.order.title,
                prompt: dispatch.order.instruction,
                workerCount: 1,
                missionKind: "standing_order",
                originator: dispatch.originator,
                targetBodyID: dispatch.plan.targetBodyID
            )
            // Only a mission that was actually created advances the schedule.
            // Marking a failed dispatch as fired would silently skip the cycle
            // the user asked for.
            try await store.markFired(id: dispatch.order.id, at: now)
        } catch {
            AppLogger.network.silentFailure("standing_order_dispatch_failed", error: error)
        }
    }
}

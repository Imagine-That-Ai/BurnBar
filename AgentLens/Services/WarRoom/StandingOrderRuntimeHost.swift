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
    private static let cadenceID = "standing-order-runtime"

    private(set) var lastTickAt: Date?
    private(set) var lastDispatchCount = 0
    private(set) var lastDeferralCount = 0

    private let store: StandingOrderStore
    private let directory: HermesBodyDirectory
    private let dispatcher: MacWandMissionDispatcher
    private let killSwitchProvider: () -> Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var tickInFlight = false

    init(
        store: StandingOrderStore,
        directory: HermesBodyDirectory,
        dispatcher: MacWandMissionDispatcher,
        killSwitchProvider: @escaping () -> Bool
    ) {
        self.store = store
        self.directory = directory
        self.dispatcher = dispatcher
        self.killSwitchProvider = killSwitchProvider
    }

    /// The fleet directory is shared with the other War Room hosts, so its
    /// listener is started and stopped by whoever owns it — stopping it here
    /// would starve every other reader.
    func start() {
        guard !started else { return }
        started = true
        generation &+= 1
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceID,
                activeInterval: Self.tickInterval,
                backgroundInterval: Self.tickInterval * 5,
                sleepInterval: nil,
                fireImmediately: true,
                cancellableInFlight: false,
                work: { [weak self] in
                    await self?.tick()
                }
            )
        )
    }

    func stop() {
        started = false
        generation &+= 1
        BackgroundCadenceCoordinator.shared.unregister(id: Self.cadenceID)
    }

    /// One pass. Separated from the loop so it can be driven directly.
    func tick(now: Date = Date()) async {
        guard started || generation == 0 else { return }
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }
        let tickGeneration = generation
        lastTickAt = now
        // The kill switch halts every War Room actuator, not just the Wire:
        // stored standing orders must stop creating missions the moment the
        // operator engages the documented rollback.
        if killSwitchProvider() {
            lastDispatchCount = 0
            lastDeferralCount = 0
            return
        }
        let orders: [StandingOrder]
        do {
            orders = try await store.fetchOrders()
        } catch {
            AppLogger.dataStore.silentFailure("standing_order_fetch_failed", error: error)
            return
        }
        guard generation == tickGeneration, started || tickGeneration == 0 else { return }
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
            guard generation == tickGeneration, started || tickGeneration == 0 else { return }
            await fire(dispatch, now: now, generation: tickGeneration)
        }
    }

    private func fire(
        _ dispatch: StandingOrderDispatch,
        now: Date,
        generation fireGeneration: UInt64
    ) async {
        guard generation == fireGeneration, started || fireGeneration == 0 else { return }
        // Re-checked per dispatch: the switch can engage mid-tick, between
        // the plan and a later order in the same pass.
        guard !killSwitchProvider() else { return }
        // The claim commits BEFORE the external mission write, so a crash or
        // DB failure between the two can only skip an occurrence — never let
        // the next tick double-run paid or destructive scheduled work. A
        // failed dispatch rolls the claim back, so a transient Firestore
        // outage retries next tick instead of silently eating the cycle.
        let previousFiredAt = dispatch.order.lastFiredAt
        do {
            try await store.markFired(id: dispatch.order.id, at: now)
        } catch {
            AppLogger.dataStore.silentFailure("standing_order_claim_failed", error: error)
            return
        }
        guard generation == fireGeneration, started || fireGeneration == 0 else {
            // Nothing external happened yet; hand the occurrence back.
            await rollBack(dispatch, claimedAt: now, to: previousFiredAt)
            return
        }
        do {
            _ = try await dispatcher.dispatch(
                title: dispatch.order.title,
                prompt: dispatch.order.instruction,
                workerCount: 1,
                missionKind: "standing_order",
                originator: dispatch.originator,
                targetBodyID: dispatch.plan.targetBodyID
            )
        } catch {
            AppLogger.network.silentFailure("standing_order_dispatch_failed", error: error)
            await rollBack(dispatch, claimedAt: now, to: previousFiredAt)
        }
    }

    /// A rollback that itself fails leaves the claim standing, which skips this
    /// occurrence rather than risking a double run of paid work — the safe
    /// direction, but never a silent one.
    private func rollBack(
        _ dispatch: StandingOrderDispatch,
        claimedAt: Date,
        to previous: Date?
    ) async {
        do {
            try await store.rollBackFire(id: dispatch.order.id, from: claimedAt, to: previous)
        } catch {
            AppLogger.dataStore.silentFailure("standing_order_rollback_failed", error: error)
        }
    }
}

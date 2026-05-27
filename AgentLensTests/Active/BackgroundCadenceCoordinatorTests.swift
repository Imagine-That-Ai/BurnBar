import XCTest
@testable import OpenBurnBar

@MainActor
final class BackgroundCadenceCoordinatorTests: XCTestCase {

    /// `BackgroundCadenceCoordinator` is a singleton, so make sure each
    /// test starts and ends with a clean slate: unregister all cadences
    /// the test added.
    override func tearDown() {
        super.tearDown()
        for state in BackgroundCadenceCoordinator.shared.allStates() {
            BackgroundCadenceCoordinator.shared.unregister(id: state.id)
        }
    }

    // MARK: - Interval selection

    func testInterval_appActive_displayAwake_picksActiveInterval() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "active-interval",
                activeInterval: 5,
                backgroundInterval: 30,
                sleepInterval: nil,
                work: { }
            )
        )

        let state = BackgroundCadenceCoordinator.shared.state(forId: "active-interval")
        XCTAssertEqual(state?.appliedInterval, 5)
    }

    func testInterval_appResigned_picksBackgroundInterval() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appResignedActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "background-interval",
                activeInterval: 5,
                backgroundInterval: 30,
                sleepInterval: nil,
                work: { }
            )
        )

        let state = BackgroundCadenceCoordinator.shared.state(forId: "background-interval")
        XCTAssertEqual(state?.appliedInterval, 30)
    }

    func testInterval_displaySleep_pausesEntirelyWhenSleepIntervalNil() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayWillSleep)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "sleep-paused",
                activeInterval: 5,
                backgroundInterval: 30,
                sleepInterval: nil,
                work: { }
            )
        )

        let state = BackgroundCadenceCoordinator.shared.state(forId: "sleep-paused")
        XCTAssertEqual(state?.appliedInterval, .infinity)
    }

    func testInterval_displaySleep_usesSleepIntervalWhenProvided() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayWillSleep)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "sleep-throttled",
                activeInterval: 5,
                backgroundInterval: 30,
                sleepInterval: 300,
                work: { }
            )
        )

        let state = BackgroundCadenceCoordinator.shared.state(forId: "sleep-throttled")
        XCTAssertEqual(state?.appliedInterval, 300)
    }

    func testInterval_observerActive_picksObserverInterval() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "observer-cadence",
                activeInterval: 2,
                backgroundInterval: 30,
                sleepInterval: nil,
                observerActiveInterval: 60,
                work: { }
            )
        )
        BackgroundCadenceCoordinator.shared.observerDidEmit(id: "observer-cadence")

        let state = BackgroundCadenceCoordinator.shared.state(forId: "observer-cadence")
        XCTAssertEqual(state?.appliedInterval, 60)
        XCTAssertTrue(state?.observerActive ?? false)
    }

    func testObserverGoingSilent_snapsBackToActive() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "observer-snapback",
                activeInterval: 2,
                backgroundInterval: 30,
                sleepInterval: nil,
                observerActiveInterval: 60,
                work: { }
            )
        )
        BackgroundCadenceCoordinator.shared.observerDidEmit(id: "observer-snapback")
        XCTAssertEqual(
            BackgroundCadenceCoordinator.shared.state(forId: "observer-snapback")?.appliedInterval,
            60
        )
        BackgroundCadenceCoordinator.shared.observerDidGoSilent(id: "observer-snapback")
        XCTAssertEqual(
            BackgroundCadenceCoordinator.shared.state(forId: "observer-snapback")?.appliedInterval,
            2
        )
    }

    func testGate_disabledCadence_pausesEvenWhenActive() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "gated-cadence",
                activeInterval: 5,
                backgroundInterval: 30,
                sleepInterval: nil,
                isEnabled: { false },
                work: { }
            )
        )

        let state = BackgroundCadenceCoordinator.shared.state(forId: "gated-cadence")
        XCTAssertEqual(state?.appliedInterval, .infinity)
        XCTAssertFalse(state?.active ?? true)
    }

    // MARK: - Lifecycle signal hook

    func testLifecycleSignalForTesting_fires() {
        var observed: [BackgroundCadenceCoordinator.LifecycleSignal] = []
        BackgroundCadenceCoordinator.shared.lifecycleSignalForTesting = { observed.append($0) }
        defer { BackgroundCadenceCoordinator.shared.lifecycleSignalForTesting = nil }

        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayWillSleep)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        XCTAssertEqual(observed, [.appBecameActive, .displayWillSleep, .displayDidWake])
    }

    // MARK: - Provider-style intervals

    func testProviderInterval_reEvaluatedOnEachStateRead() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        var liveInterval: TimeInterval = 10
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "provider-interval",
                activeIntervalProvider: { liveInterval },
                work: { }
            )
        )

        XCTAssertEqual(
            BackgroundCadenceCoordinator.shared.state(forId: "provider-interval")?.appliedInterval,
            10
        )

        liveInterval = 90
        XCTAssertEqual(
            BackgroundCadenceCoordinator.shared.state(forId: "provider-interval")?.appliedInterval,
            90
        )
    }

    // MARK: - Registration replacement

    func testRegister_replacesExistingCadence() {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "replaceable",
                activeInterval: 5,
                work: { }
            )
        )

        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "replaceable",
                activeInterval: 25,
                work: { }
            )
        )

        XCTAssertEqual(
            BackgroundCadenceCoordinator.shared.state(forId: "replaceable")?.appliedInterval,
            25
        )
    }

    func testUnregister_removesCadence() {
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "deletable",
                activeInterval: 5,
                work: { }
            )
        )
        XCTAssertNotNil(BackgroundCadenceCoordinator.shared.state(forId: "deletable"))

        BackgroundCadenceCoordinator.shared.unregister(id: "deletable")
        XCTAssertNil(BackgroundCadenceCoordinator.shared.state(forId: "deletable"))
    }

    // MARK: - Lifecycle changes while sleeping

    func testRunLoop_reEvaluatesPausedStateAfterSleepBeforeFiring() async throws {
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.appBecameActive)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayDidWake)

        var fireCount = 0
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "pause-before-fire",
                activeInterval: 0.05,
                backgroundInterval: 0.05,
                sleepInterval: nil,
                work: { fireCount += 1 }
            )
        )

        try await Task.sleep(nanoseconds: 20_000_000)
        BackgroundCadenceCoordinator.shared.handleLifecycleSignal(.displayWillSleep)
        try await Task.sleep(nanoseconds: 90_000_000)

        XCTAssertEqual(fireCount, 0)
    }
}

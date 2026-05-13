import XCTest
@preconcurrency import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class PixelClockInputControllerTests: XCTestCase {
    private var settingsManager: SettingsManager!
    private var observedNotifications: [Notification] = []
    private var notificationObserver: NSObjectProtocol?
    private var pushPixelClockNowCallCount = 0
    private var returnToBurnBarCallCount = 0

    override func setUp() async throws {
        try await super.setUp()
        settingsManager = makeSettingsManager()
        observedNotifications = []
        pushPixelClockNowCallCount = 0
        returnToBurnBarCallCount = 0
        notificationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("ShowAssistantsTab"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.observedNotifications.append(note)
            }
        }
    }

    override func tearDown() async throws {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        notificationObserver = nil
        settingsManager = nil
        try await super.tearDown()
    }

    private func makeController() -> PixelClockInputController {
        PixelClockInputController(
            settingsManager: settingsManager,
            quotaService: nil,
            client: AWTRIXClient(),
            pushPixelClockNow: { [weak self] in
                self?.pushPixelClockNowCallCount += 1
            },
            returnToBurnBar: { [weak self] _ in
                self?.returnToBurnBarCallCount += 1
            }
        )
    }

    private func configureForRotation(initialIndex: Int = 0) {
        // Bind every known quota provider so the rotation actually has
        // pages to step through — `PixelClockSnapshotAdapter.quotaCycleItems`
        // emits 2 buckets per provider (5h + 7d), so the page count
        // exceeds 1 regardless of which providers are reachable in tests.
        var config = settingsManager.pixelClockConfig
        config.enabled = true
        config.providerIDs = []
        config.selectedProviderIndex = initialIndex
        settingsManager.pixelClockConfig = config
    }

    func testLeftSentinelDispatchesPreviousProviderAction() async {
        configureForRotation(initialIndex: 0)
        let controller = makeController()

        await controller.ingest(
            currentAppName: "openburnbar_btn_left",
            config: settingsManager.pixelClockConfig
        )

        XCTAssertGreaterThan(settingsManager.pixelClockConfig.selectedProviderIndex, 0,
                             "Wrap-around: pressing Left at index 0 should jump to the last provider page.")
        XCTAssertEqual(returnToBurnBarCallCount, 1)
        XCTAssertGreaterThan(pushPixelClockNowCallCount, 0)
    }

    func testRightSentinelDispatchesNextProviderAction() async {
        configureForRotation(initialIndex: 0)
        let controller = makeController()

        await controller.ingest(
            currentAppName: "openburnbar_btn_right",
            config: settingsManager.pixelClockConfig
        )

        XCTAssertEqual(settingsManager.pixelClockConfig.selectedProviderIndex, 1)
        XCTAssertEqual(returnToBurnBarCallCount, 1)
        XCTAssertGreaterThan(pushPixelClockNowCallCount, 0)
    }

    func testSelectSentinelOpensHermes() async {
        configureForRotation()
        let controller = makeController()

        await controller.ingest(
            currentAppName: "openburnbar_btn_select",
            config: settingsManager.pixelClockConfig
        )

        // Notification is posted synchronously on the main queue, but the
        // observer hops back through MainActor — give the runloop a tick.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(observedNotifications.isEmpty)
        XCTAssertEqual(returnToBurnBarCallCount, 1)
    }

    func testDebounceSwallowsRepeatedSamePolls() async {
        configureForRotation(initialIndex: 0)
        let controller = makeController()
        let start = Date()

        await controller.ingest(
            currentAppName: "openburnbar_btn_right",
            config: settingsManager.pixelClockConfig,
            now: start
        )
        await controller.ingest(
            currentAppName: "openburnbar_btn_right",
            config: settingsManager.pixelClockConfig,
            now: start.addingTimeInterval(0.05)
        )

        XCTAssertEqual(settingsManager.pixelClockConfig.selectedProviderIndex, 1,
                       "Two right-button polls within the 250 ms debounce window must only advance once.")
    }

    func testReturningToBurnBarBetweenPressesAllowsTheNextActionToFire() async {
        configureForRotation(initialIndex: 0)
        let controller = makeController()
        let start = Date()

        await controller.ingest(
            currentAppName: "openburnbar_btn_right",
            config: settingsManager.pixelClockConfig,
            now: start
        )
        // Device returned to BurnBar — debounce should clear.
        await controller.ingest(
            currentAppName: "openburnbar0",
            config: settingsManager.pixelClockConfig,
            now: start.addingTimeInterval(0.05)
        )
        await controller.ingest(
            currentAppName: "openburnbar_btn_right",
            config: settingsManager.pixelClockConfig,
            now: start.addingTimeInterval(0.10)
        )

        XCTAssertEqual(settingsManager.pixelClockConfig.selectedProviderIndex, 2)
    }

    func testRebindingLeftToCycleLayoutRotatesLayout() async {
        var config = settingsManager.pixelClockConfig
        config.enabled = true
        config.layout = .providerDashboard
        config.buttonBindings.left = .cycleLayout
        settingsManager.pixelClockConfig = config
        let controller = makeController()

        await controller.ingest(
            currentAppName: "openburnbar_btn_left",
            config: settingsManager.pixelClockConfig
        )

        XCTAssertEqual(settingsManager.pixelClockConfig.layout, .quotaCarousel)
    }

    func testSnoozeBindingSetsMutedUntilOneHourOut() async {
        var config = settingsManager.pixelClockConfig
        config.enabled = true
        config.buttonBindings.select = .snoozeAlert
        settingsManager.pixelClockConfig = config
        let controller = makeController()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        await controller.ingest(
            currentAppName: "openburnbar_btn_select",
            config: settingsManager.pixelClockConfig,
            now: now
        )

        XCTAssertEqual(
            settingsManager.pixelClockConfig.mutedUntil,
            now.addingTimeInterval(3600)
        )
        XCTAssertTrue(settingsManager.pixelClockConfig.isMuted(at: now.addingTimeInterval(60)))
        XCTAssertFalse(settingsManager.pixelClockConfig.isMuted(at: now.addingTimeInterval(3601)))
    }

    func testNonSentinelAppDoesNotFireAction() async {
        configureForRotation(initialIndex: 0)
        let controller = makeController()

        await controller.ingest(
            currentAppName: "openburnbar0",
            config: settingsManager.pixelClockConfig
        )

        XCTAssertEqual(settingsManager.pixelClockConfig.selectedProviderIndex, 0)
        XCTAssertEqual(returnToBurnBarCallCount, 0)
        XCTAssertEqual(pushPixelClockNowCallCount, 0)
    }
}

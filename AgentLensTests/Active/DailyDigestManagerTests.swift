import XCTest
import UserNotifications
@testable import OpenBurnBar

@MainActor
final class DailyDigestManagerTests: XCTestCase {

    private var mockNotificationCenter: MockUNUserNotificationCenter!
    private var manager: DailyDigestManager!

    override func setUp() {
        super.setUp()
        mockNotificationCenter = MockUNUserNotificationCenter()
        manager = DailyDigestManager(notificationCenter: mockNotificationCenter)
    }

    override func tearDown() {
        manager = nil
        mockNotificationCenter = nil
        super.tearDown()
    }

    // MARK: - Request Authorization Tests

    func test_requestAuthorization_succeedsWithGranted() async throws {
        // Given
        mockNotificationCenter.authorizationStatus = .authorized

        // When
        await manager.requestAuthorization()

        // Then
        XCTAssertEqual(mockNotificationCenter.requestAuthorizationCallsCount, 1)
        XCTAssertEqual(mockNotificationCenter.lastRequestedOptions, [.alert, .sound])
    }

    func test_requestAuthorization_handlesDenied() async throws {
        // Given
        mockNotificationCenter.authorizationStatus = .denied

        // When
        await manager.requestAuthorization()

        // Then
        XCTAssertEqual(mockNotificationCenter.requestAuthorizationCallsCount, 1)
        XCTAssertEqual(mockNotificationCenter.lastRequestedOptions, [.alert, .sound])
    }

    func test_requestAuthorization_handlesNotDetermined() async throws {
        // Given
        mockNotificationCenter.authorizationStatus = .notDetermined

        // When
        await manager.requestAuthorization()

        // Then
        XCTAssertEqual(mockNotificationCenter.requestAuthorizationCallsCount, 1)
        XCTAssertEqual(mockNotificationCenter.lastRequestedOptions, [.alert, .sound])
    }

    // MARK: - Schedule Digest Tests

    func test_scheduleDigest_createsNotificationRequest() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()
        let hour = 18

        // When
        manager.scheduleDigest(from: store, at: hour)

        // Then - notification request should be added
        XCTAssertFalse(mockNotificationCenter.addedRequests.isEmpty)
    }

    func test_scheduleDigest_usesCorrectHour() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When - schedule for 9 AM
        manager.scheduleDigest(from: store, at: 9)

        // Then - verify request was added
        XCTAssertFalse(mockNotificationCenter.addedRequests.isEmpty)
    }

    func test_scheduleDigest_usesCorrectIdentifier() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertEqual(request?.identifier, OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier)
    }

    func test_scheduleDigest_removesPendingNotifications() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()
        mockNotificationCenter.pendingRequests = [
            UNNotificationRequest(identifier: OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier, content: UNMutableNotificationContent(), trigger: nil),
            UNNotificationRequest(identifier: "legacy-id-1", content: UNMutableNotificationContent(), trigger: nil)
        ]

        // When
        manager.scheduleDigest(from: store)

        // Then - old requests should be removed
        // The manager should have called removePendingNotificationRequests
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
    }

    func test_scheduleDigest_includesLegacyIdentifiers() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)

        // Then - legacy identifiers should be removed
        for legacyId in OpenBurnBar.OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers {
            XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(legacyId))
        }
    }

    func test_scheduleDigest_notificationContent_hasCorrectTitle() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertEqual(request?.content.title, "\(OpenBurnBar.OpenBurnBarIdentity.productName) Daily Digest")
    }

    func test_scheduleDigest_notificationContent_hasDefaultSound() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertEqual(request?.content.sound, .default)
    }

    func test_scheduleDigest_notificationContent_includesNarrative() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)

        // Then - content body should not be empty
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertFalse(request?.content.body.isEmpty ?? true)
    }

    func test_scheduleDigest_trigger_isCalendarBased() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()
        let hour = 20

        // When
        manager.scheduleDigest(from: store, at: hour)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertNotNil(request?.trigger as? UNCalendarNotificationTrigger)
    }

    func test_scheduleDigest_trigger_isOneShot() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)

        // Then - a repeating trigger reuses the content it was registered with,
        // so a Mac left running would replay the sentence computed at launch
        // every day. The cadence in `activate` re-arms instead.
        let request = mockNotificationCenter.addedRequests.first
        if let trigger = request?.trigger as? UNCalendarNotificationTrigger {
            XCTAssertFalse(trigger.repeats)
        } else {
            XCTFail("Trigger should be UNCalendarNotificationTrigger")
        }
    }

    func test_scheduleDigest_trigger_targetsAnExplicitCalendarDate() throws {
        // Given - 10:00 on the 15th, digest due at 18:00
        let store = try DataStore.makeInMemoryForTesting()
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))

        // When
        manager.scheduleDigest(from: store, at: 18)

        // Then - a one-shot trigger needs the full date, not just hour/minute,
        // so it resolves to exactly one occurrence.
        let trigger = try XCTUnwrap(
            mockNotificationCenter.addedRequests.first?.trigger as? UNCalendarNotificationTrigger
        )
        XCTAssertEqual(trigger.dateComponents.year, 2026)
        XCTAssertEqual(trigger.dateComponents.month, 8)
        XCTAssertEqual(trigger.dateComponents.day, 15)
        XCTAssertEqual(trigger.dateComponents.hour, 18)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
    }

    func test_scheduleDigest_targetsTomorrow_whenHourAlreadyPassedToday() throws {
        // Given - 19:00, past today's 18:00 slot
        let store = try DataStore.makeInMemoryForTesting()
        let manager = makeManager(now: Self.date(2026, 8, 15, 19, 0))

        // When
        manager.scheduleDigest(from: store, at: 18)

        // Then
        let trigger = try XCTUnwrap(
            mockNotificationCenter.addedRequests.first?.trigger as? UNCalendarNotificationTrigger
        )
        XCTAssertEqual(trigger.dateComponents.day, 16)
    }

    func test_scheduleDigest_trigger_minuteIsZero() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store, at: 14)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        if let trigger = request?.trigger as? UNCalendarNotificationTrigger {
            XCTAssertEqual(trigger.dateComponents.minute, 0)
        }
    }

    // MARK: - Cancel Digest Tests

    func test_cancelDigest_removesNotification() {
        // Given
        mockNotificationCenter.pendingRequests = [
            UNNotificationRequest(identifier: OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier, content: UNMutableNotificationContent(), trigger: nil)
        ]

        // When
        manager.cancelDigest()

        // Then
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
    }

    func test_cancelDigest_removesLegacyIdentifiers() {
        // Given
        mockNotificationCenter.pendingRequests = [
            UNNotificationRequest(identifier: "legacy-id-1", content: UNMutableNotificationContent(), trigger: nil),
            UNNotificationRequest(identifier: "legacy-id-2", content: UNMutableNotificationContent(), trigger: nil)
        ]

        // When
        manager.cancelDigest()

        // Then
        for legacyId in OpenBurnBar.OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers {
            XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(legacyId))
        }
    }

    func test_cancelDigest_idempotent() {
        // Given - no pending notifications
        mockNotificationCenter.pendingRequests = []

        // When - cancel multiple times
        manager.cancelDigest()
        manager.cancelDigest()

        // Then - armed fire date is cleared and removals are issued
        XCTAssertNil(manager.armedFireDate)
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
    }

    // MARK: - Integration Tests

    func test_scheduleThenCancel_lifecycle() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)
        manager.cancelDigest()

        // Then - scheduled request should be removed
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
    }

    func test_reschedule_replacesExistingNotification() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()
        mockNotificationCenter.pendingRequests = [
            UNNotificationRequest(identifier: OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier, content: UNMutableNotificationContent(), trigger: nil)
        ]

        // When - reschedule
        manager.scheduleDigest(from: store, at: 10)

        // Then - old notification should be removed
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
        // And new notification should be added
        XCTAssertFalse(mockNotificationCenter.addedRequests.isEmpty)
    }

    // MARK: - Edge Cases

    func test_scheduleDigest_differentHours() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()
        let hours = [0, 6, 12, 18, 23]

        for hour in hours {
            // Reset mock
            mockNotificationCenter = MockUNUserNotificationCenter()

            // When
            manager = DailyDigestManager(notificationCenter: mockNotificationCenter)
            manager.scheduleDigest(from: store, at: hour)

            // Then
            let request = mockNotificationCenter.addedRequests.first
            if let trigger = request?.trigger as? UNCalendarNotificationTrigger {
                XCTAssertEqual(trigger.dateComponents.hour, hour)
            }
        }
    }

    func test_scheduleDigest_emptyStore() throws {
        // Given - empty data store
        let store = try DataStore.makeInMemoryForTesting()

        // When
        manager.scheduleDigest(from: store)

        // Then - should still create notification with empty narrative
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertNotNil(request)
    }

    func test_scheduleDigest_withUsages() throws {
        // Given - store with usages
        let store = try DataStore.makeInMemoryForTesting()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in 1...3 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 100,
                    outputTokens: 100,
                    costUSD: Double(d),
                    startTime: day.addingTimeInterval(3600),
                    endTime: day.addingTimeInterval(7200)
                )
            )
        }
        store.replaceUsages(usages)

        // When
        manager.scheduleDigest(from: store)

        // Then - notification should be created
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertNotNil(request)
        // And body should contain some content
        XCTAssertFalse(request?.content.body.isEmpty ?? true)
    }

    // MARK: - Delivery-Time Freshness

    func test_reArm_bodyReflectsDataAsOfReArming_notFirstRegistration() throws {
        // Given - armed at 10:00 against a store that has nothing yet
        let store = try DataStore.makeInMemoryForTesting()
        let clock = ClockBox(Self.date(2026, 8, 15, 10, 0))
        let manager = makeManager(clock: clock)
        manager.scheduleDigest(from: store, at: 18)
        let registrationBody = primaryRequests.last?.content.body

        // When - yesterday's sessions are imported after that first arming, and
        // the cadence re-arms later the same day
        store.replaceUsages([Self.usage(costUSD: 12.34, at: Self.date(2026, 8, 14, 9, 0))])
        clock.now = Self.date(2026, 8, 15, 12, 0)
        manager.scheduleDigest(from: store, at: 18)
        let deliveryBody = try XCTUnwrap(primaryRequests.last?.content.body)

        // Then - the body that will actually be delivered describes the data as
        // of re-arming. Under the old repeating trigger both firings carried
        // `registrationBody` forever.
        XCTAssertNotEqual(registrationBody, deliveryBody)
        XCTAssertEqual(primaryRequests.count, 2)
        XCTAssertTrue(
            deliveryBody.contains("$12.34"),
            "expected yesterday's spend in the body, got: \(deliveryBody)"
        )
    }

    func test_digestBody_summarizesYesterday_notToday() throws {
        // Given - spend on both days
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages([
            Self.usage(costUSD: 99.00, at: Self.date(2026, 8, 15, 11, 0)), // today
            Self.usage(costUSD: 5.00, at: Self.date(2026, 8, 14, 11, 0))   // yesterday
        ])
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))

        // When
        manager.scheduleDigest(from: store, at: 18)

        // Then - Settings promises "yesterday's burn", so today's spend must
        // stay out of it.
        let body = try XCTUnwrap(mockNotificationCenter.addedRequests.first?.content.body)
        XCTAssertTrue(body.contains("$5.00"), "expected yesterday's spend, got: \(body)")
        XCTAssertFalse(body.contains("$99.00"), "today's spend leaked into the digest: \(body)")
    }

    func test_digestBody_anchorsToDeliveryDate_notArmingTime() throws {
        // Given - spend on the 14th and the 15th
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages([
            Self.usage(costUSD: 7.77, at: Self.date(2026, 8, 15, 12, 0)),
            Self.usage(costUSD: 3.33, at: Self.date(2026, 8, 14, 12, 0))
        ])

        // When - armed at 23:50 on the 15th for a 09:00 delivery on the 16th
        let manager = makeManager(now: Self.date(2026, 8, 15, 23, 50))
        manager.scheduleDigest(from: store, at: 9)

        // Then - "yesterday" is resolved against the fire date, so this
        // describes the 15th. Resolving against "now" would describe the 14th
        // and the digest would arrive a day behind.
        let body = try XCTUnwrap(mockNotificationCenter.addedRequests.first?.content.body)
        XCTAssertTrue(body.contains("$7.77"), "expected the 15th's spend, got: \(body)")
    }

    func test_digestBody_reportsQuietDay_whenYesterdayHadNoSessions() throws {
        // Given - spend today only
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages([Self.usage(costUSD: 4.00, at: Self.date(2026, 8, 15, 11, 0))])
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))

        // When
        manager.scheduleDigest(from: store, at: 18)

        // Then
        let body = try XCTUnwrap(mockNotificationCenter.addedRequests.first?.content.body)
        let dayName = Self.expectedDayName(forDeliveryAt: Self.date(2026, 8, 15, 18, 0))
        XCTAssertTrue(body.contains("No burn \(dayName)"), "got: \(body)")
    }

    func test_digestBody_namesTheDayItDescribes_notRelativeToNow() throws {
        // Given - yesterday had spend
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages([Self.usage(costUSD: 5.00, at: Self.date(2026, 8, 14, 11, 0))])
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))

        // When
        manager.scheduleDigest(from: store, at: 18)

        // Then - a Mac asleep through 18:00 gets this on wake, possibly a day
        // or more later, where "yesterday" would point at the wrong day. The
        // weekday it names stays true whenever it is finally shown.
        let body = try XCTUnwrap(mockNotificationCenter.addedRequests.first?.content.body)
        let dayName = Self.expectedDayName(forDeliveryAt: Self.date(2026, 8, 15, 18, 0))
        XCTAssertEqual(dayName, "Friday", "2026-08-14 was a Friday")
        XCTAssertTrue(body.contains("Friday:"), "expected the covered day named, got: \(body)")
        XCTAssertFalse(body.lowercased().contains("yesterday"), "got: \(body)")
    }

    func test_persistedDigestArming_readsTwoDaysWithoutHydratingPresentation() async throws {
        let store = try DataStore.makeInMemoryForTesting()
        try await store.insert([
            Self.usage(costUSD: 5.00, at: Self.date(2026, 8, 14, 11, 0)),
            Self.usage(costUSD: 2.50, at: Self.date(2026, 8, 13, 11, 0))
        ])
        XCTAssertFalse(store.debugHasLoadedUsagePresentationForTesting)
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))

        await manager.scheduleDigestUsingPersistedUsage(from: store, at: 18)

        let body = try XCTUnwrap(mockNotificationCenter.addedRequests.first?.content.body)
        XCTAssertTrue(body.contains("$5.00"), "expected persisted Friday spend, got: \(body)")
        XCTAssertTrue(body.contains("Up 100%"), "expected prior-day comparison, got: \(body)")
        XCTAssertFalse(
            store.debugHasLoadedUsagePresentationForTesting,
            "Digest arming must not force the dashboard aggregate snapshot"
        )
    }

    // MARK: - Horizon (delivery while the app is quit)

    func test_scheduleDigest_armsAWeekOfDistinctOneShots() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))

        // When
        manager.scheduleDigest(from: store, at: 18)

        // Then - a quit app still delivers a digest each day instead of firing
        // once and going silent.
        XCTAssertEqual(mockNotificationCenter.addedRequests.count, 7)
        XCTAssertEqual(Set(mockNotificationCenter.addedRequests.map(\.identifier)).count, 7)

        // …on seven consecutive days, all at the chosen hour.
        let days = try mockNotificationCenter.addedRequests.map { request -> Int in
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertFalse(trigger.repeats)
            XCTAssertEqual(trigger.dateComponents.hour, 18)
            return try XCTUnwrap(trigger.dateComponents.day)
        }
        XCTAssertEqual(days, Array(15...21))
    }

    func test_horizonBeyondTheFirstDay_makesNoNumericClaim() throws {
        // Given - a store with real spend on every recent day
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages([
            Self.usage(costUSD: 5.00, at: Self.date(2026, 8, 14, 11, 0)),
            Self.usage(costUSD: 9.00, at: Self.date(2026, 8, 13, 11, 0))
        ])
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))

        // When
        manager.scheduleDigest(from: store, at: 18)

        // Then - only day one can carry a total; the days after it cover
        // windows that have not happened yet, so they must not invent one.
        let later = mockNotificationCenter.addedRequests.dropFirst()
        XCTAssertEqual(later.count, 6)
        for request in later {
            XCTAssertFalse(
                request.content.body.contains("$"),
                "a future digest claimed a total it cannot know: \(request.content.body)"
            )
        }
        let firstBody = try XCTUnwrap(mockNotificationCenter.addedRequests.first?.content.body)
        XCTAssertTrue(firstBody.contains("$5.00"), "got: \(firstBody)")
    }

    func test_cancelDigest_removesTheWholeHorizon() throws {
        // Given
        let store = try DataStore.makeInMemoryForTesting()
        let manager = makeManager(now: Self.date(2026, 8, 15, 10, 0))
        manager.scheduleDigest(from: store, at: 18)

        // When
        manager.cancelDigest()

        // Then - switching the digest off must not leave later horizon days
        // armed to fire on their own.
        for offset in 0..<7 {
            let identifier = DailyDigestManager.digestIdentifier(dayOffset: offset)
            XCTAssertTrue(
                mockNotificationCenter.removedIdentifiers.contains(identifier),
                "horizon day \(offset) (\(identifier)) survived cancellation"
            )
        }
    }

    // MARK: - Re-Arm Guard

    func test_scheduleDigest_leavesPendingRequestAlone_nearDelivery() throws {
        // Given - armed at 17:00 for 18:00
        let store = try DataStore.makeInMemoryForTesting()
        let clock = ClockBox(Self.date(2026, 8, 15, 17, 0))
        let manager = makeManager(clock: clock)
        manager.scheduleDigest(from: store, at: 18)
        XCTAssertEqual(primaryRequests.count, 1)
        let removalsAfterFirstArm = mockNotificationCenter.removedIdentifiers.count

        // When - a cadence tick lands two minutes before delivery
        clock.now = Self.date(2026, 8, 15, 17, 58)
        manager.scheduleDigest(from: store, at: 18)

        // Then - removing and re-adding here would re-target tomorrow and
        // swallow today's digest entirely.
        XCTAssertEqual(primaryRequests.count, 1)
        XCTAssertEqual(mockNotificationCenter.removedIdentifiers.count, removalsAfterFirstArm)
    }

    func test_scheduleDigest_reArmsForNextDay_onceClearOfDelivery() throws {
        // Given - armed at 17:00 for 18:00
        let store = try DataStore.makeInMemoryForTesting()
        let clock = ClockBox(Self.date(2026, 8, 15, 17, 0))
        let manager = makeManager(clock: clock)
        manager.scheduleDigest(from: store, at: 18)

        // When - the next tick after delivery has passed
        clock.now = Self.date(2026, 8, 15, 18, 30)
        manager.scheduleDigest(from: store, at: 18)

        // Then - a fresh one-shot for tomorrow, which is what keeps a
        // long-running Mac receiving a digest every day.
        XCTAssertEqual(primaryRequests.count, 2)
        let trigger = try XCTUnwrap(primaryRequests.last?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.day, 16)
        XCTAssertEqual(trigger.dateComponents.hour, 18)
    }

    func test_cancelDigest_clearsGuard_soANewHourArmsImmediately() throws {
        // Given - armed at 17:00 for 18:00, then cancelled
        let store = try DataStore.makeInMemoryForTesting()
        let clock = ClockBox(Self.date(2026, 8, 15, 17, 0))
        let manager = makeManager(clock: clock)
        manager.scheduleDigest(from: store, at: 18)
        manager.cancelDigest()

        // When - the user picks a new hour inside the old guard window
        clock.now = Self.date(2026, 8, 15, 17, 58)
        manager.scheduleDigest(from: store, at: 21)

        // Then - the guard protects a *pending* request; once cancelled there
        // is nothing to protect.
        XCTAssertEqual(primaryRequests.count, 2)
        let trigger = try XCTUnwrap(primaryRequests.last?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.hour, 21)
    }

    // MARK: - Performance Tests

    func test_scheduleDigest_performance() throws {
        // Given - 100 days of history ending the day before the fixed clock, so
        // every iteration walks the full set and lands in the digest window.
        let store = try DataStore.makeInMemoryForTesting()
        let clockNow = Self.date(2026, 8, 15, 10, 0)
        var usages: [TokenUsage] = []
        for d in 1...100 {
            let day = Self.calendar.date(byAdding: .day, value: -d, to: Self.calendar.startOfDay(for: clockNow))!
            usages.append(Self.usage(costUSD: Double(d), at: day.addingTimeInterval(3600)))
        }
        store.replaceUsages(usages)
        XCTAssertEqual(usages.count, 100)

        let manager = makeManager(now: clockNow)
        measure {
            manager.cancelDigest() // clear the re-arm guard so each pass does real work
            manager.scheduleDigest(from: store, at: 18)
        }
        XCTAssertFalse(mockNotificationCenter.addedRequests.isEmpty)
    }

    // MARK: - Helpers

    /// UTC, so the fixed dates below cannot drift with the runner's time zone
    /// or land on a DST transition. The locale is pinned too, because the
    /// digest names its day via `Calendar.weekdaySymbols` — production
    /// localises that, tests must not depend on the runner's language.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Requests carrying the canonical identifier — the next digest to fire, as
    /// opposed to the later horizon days armed alongside it.
    private var primaryRequests: [UNNotificationRequest] {
        mockNotificationCenter.addedRequests.filter {
            $0.identifier == OpenBurnBar.OpenBurnBarIdentity.dailyDigestNotificationIdentifier
        }
    }

    private static func expectedDayName(forDeliveryAt deliveryDate: Date) -> String {
        let covered = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: deliveryDate))!
        return calendar.weekdaySymbols[calendar.component(.weekday, from: covered) - 1]
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date()
    }

    private static func usage(costUSD: Double, at start: Date) -> TokenUsage {
        TokenUsage(
            provider: .factory,
            sessionId: UUID().uuidString,
            projectName: "p",
            model: "m",
            inputTokens: 100,
            outputTokens: 100,
            costUSD: costUSD,
            startTime: start,
            endTime: start.addingTimeInterval(3600)
        )
    }

    /// Mutable clock, so one manager can be stepped through a delivery window
    /// the way the background cadence steps it.
    @MainActor
    private final class ClockBox {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeManager(now: Date) -> DailyDigestManager {
        DailyDigestManager(
            notificationCenter: mockNotificationCenter,
            calendar: Self.calendar,
            now: { now }
        )
    }

    private func makeManager(clock: ClockBox) -> DailyDigestManager {
        DailyDigestManager(
            notificationCenter: mockNotificationCenter,
            calendar: Self.calendar,
            now: { clock.now }
        )
    }
}

// MARK: - Mock UNUserNotificationCenter

private final class MockUNUserNotificationCenter: OpenBurnBarUserNotificationCentering {
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingRequests: [UNNotificationRequest] = []
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []
    var requestAuthorizationCallsCount = 0
    var lastRequestedOptions: UNAuthorizationOptions?

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCallsCount += 1
        lastRequestedOptions = options
        return authorizationStatus == .authorized
    }

    func add(_ request: UNNotificationRequest) {
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}

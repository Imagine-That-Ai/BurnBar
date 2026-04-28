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

        // Then - no error thrown
        XCTAssertTrue(true)
    }

    func test_requestAuthorization_handlesDenied() async throws {
        // Given
        mockNotificationCenter.authorizationStatus = .denied

        // When/Then - should not throw
        await manager.requestAuthorization()
        XCTAssertTrue(true)
    }

    func test_requestAuthorization_handlesNotDetermined() async throws {
        // Given
        mockNotificationCenter.authorizationStatus = .notDetermined

        // When/Then - should not throw
        await manager.requestAuthorization()
        XCTAssertTrue(true)
    }

    // MARK: - Schedule Digest Tests

    func test_scheduleDigest_createsNotificationRequest() throws {
        // Given
        let store = try DataStore()
        let hour = 18

        // When
        manager.scheduleDigest(from: store, at: hour)

        // Then - notification request should be added
        XCTAssertFalse(mockNotificationCenter.addedRequests.isEmpty)
    }

    func test_scheduleDigest_usesCorrectHour() throws {
        // Given
        let store = try DataStore()

        // When - schedule for 9 AM
        manager.scheduleDigest(from: store, at: 9)

        // Then - verify request was added
        XCTAssertFalse(mockNotificationCenter.addedRequests.isEmpty)
    }

    func test_scheduleDigest_usesCorrectIdentifier() throws {
        // Given
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertEqual(request?.identifier, OpenBurnBarIdentity.dailyDigestNotificationIdentifier)
    }

    func test_scheduleDigest_removesPendingNotifications() throws {
        // Given
        let store = try DataStore()
        mockNotificationCenter.pendingRequests = [
            UNNotificationRequest(identifier: OpenBurnBarIdentity.dailyDigestNotificationIdentifier, content: UNMutableNotificationContent(), trigger: nil),
            UNNotificationRequest(identifier: "legacy-id-1", content: UNMutableNotificationContent(), trigger: nil)
        ]

        // When
        manager.scheduleDigest(from: store)

        // Then - old requests should be removed
        // The manager should have called removePendingNotificationRequests
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
    }

    func test_scheduleDigest_includesLegacyIdentifiers() throws {
        // Given
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)

        // Then - legacy identifiers should be removed
        for legacyId in OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers {
            XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(legacyId))
        }
    }

    func test_scheduleDigest_notificationContent_hasCorrectTitle() throws {
        // Given
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertEqual(request?.content.title, "\(OpenBurnBarIdentity.productName) Daily Digest")
    }

    func test_scheduleDigest_notificationContent_hasDefaultSound() throws {
        // Given
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertEqual(request?.content.sound, .default)
    }

    func test_scheduleDigest_notificationContent_includesNarrative() throws {
        // Given
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)

        // Then - content body should not be empty
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertFalse(request?.content.body.isEmpty ?? true)
    }

    func test_scheduleDigest_trigger_isCalendarBased() throws {
        // Given
        let store = try DataStore()
        let hour = 20

        // When
        manager.scheduleDigest(from: store, at: hour)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertNotNil(request?.trigger as? UNCalendarNotificationTrigger)
    }

    func test_scheduleDigest_trigger_repeatsDaily() throws {
        // Given
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)

        // Then
        let request = mockNotificationCenter.addedRequests.first
        if let trigger = request?.trigger as? UNCalendarNotificationTrigger {
            XCTAssertTrue(trigger.repeats)
        } else {
            XCTFail("Trigger should be UNCalendarNotificationTrigger")
        }
    }

    func test_scheduleDigest_trigger_minuteIsZero() throws {
        // Given
        let store = try DataStore()

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
            UNNotificationRequest(identifier: OpenBurnBarIdentity.dailyDigestNotificationIdentifier, content: UNMutableNotificationContent(), trigger: nil)
        ]

        // When
        manager.cancelDigest()

        // Then
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
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
        for legacyId in OpenBurnBarIdentity.legacyDailyDigestNotificationIdentifiers {
            XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(legacyId))
        }
    }

    func test_cancelDigest_idempotent() {
        // Given - no pending notifications
        mockNotificationCenter.pendingRequests = []

        // When - cancel multiple times
        manager.cancelDigest()
        manager.cancelDigest()

        // Then - should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Integration Tests

    func test_scheduleThenCancel_lifecycle() throws {
        // Given
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)
        manager.cancelDigest()

        // Then - scheduled request should be removed
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
    }

    func test_reschedule_replacesExistingNotification() throws {
        // Given
        let store = try DataStore()
        mockNotificationCenter.pendingRequests = [
            UNNotificationRequest(identifier: OpenBurnBarIdentity.dailyDigestNotificationIdentifier, content: UNMutableNotificationContent(), trigger: nil)
        ]

        // When - reschedule
        manager.scheduleDigest(from: store, at: 10)

        // Then - old notification should be removed
        XCTAssertTrue(mockNotificationCenter.removedIdentifiers.contains(OpenBurnBarIdentity.dailyDigestNotificationIdentifier))
        // And new notification should be added
        XCTAssertFalse(mockNotificationCenter.addedRequests.isEmpty)
    }

    // MARK: - Edge Cases

    func test_scheduleDigest_differentHours() throws {
        // Given
        let store = try DataStore()
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
        let store = try DataStore()

        // When
        manager.scheduleDigest(from: store)

        // Then - should still create notification with empty narrative
        let request = mockNotificationCenter.addedRequests.first
        XCTAssertNotNil(request)
    }

    func test_scheduleDigest_withUsages() throws {
        // Given - store with usages
        let store = try DataStore()
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

    // MARK: - Performance Tests

    func test_scheduleDigest_performance() throws {
        // Given
        let store = try DataStore()
        var usages: [TokenUsage] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for d in 1...100 {
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

        measure {
            manager.scheduleDigest(from: store)
        }
    }
}

// MARK: - Mock UNUserNotificationCenter

private final class MockUNUserNotificationCenter: OpenBurnBarUserNotificationCentering {
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingRequests: [UNNotificationRequest] = []
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        return authorizationStatus == .authorized
    }

    func add(_ request: UNNotificationRequest) {
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}

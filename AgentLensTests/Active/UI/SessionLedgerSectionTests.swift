import XCTest
import SwiftUI
@testable import OpenBurnBar

// MARK: - SessionLedgerSupport Logic Tests

@MainActor
final class SessionLedgerSupportTests: XCTestCase {

    // MARK: - matchesSearch

    func test_matchesSearch_emptyQuery_returnsTrue() {
        let usage = ViewTestFixtures.makeUsage()
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: ""))
    }

    func test_matchesSearch_whitespaceQuery_returnsTrue() {
        let usage = ViewTestFixtures.makeUsage()
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: "   "))
    }

    func test_matchesSearch_matchesProjectName() {
        let usage = ViewTestFixtures.makeUsage(projectName: "OpenBurnBar")
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: "burn"))
    }

    func test_matchesSearch_matchesModel() {
        let usage = ViewTestFixtures.makeUsage(model: "claude-3-opus")
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: "opus"))
    }

    func test_matchesSearch_matchesSessionId() {
        let usage = ViewTestFixtures.makeUsage(sessionId: "abc-123")
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: "abc"))
    }

    func test_matchesSearch_matchesProviderDisplayName() {
        let usage = ViewTestFixtures.makeUsage(provider: .claudeCode)
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: "claude code"))
    }

    func test_matchesSearch_matchesUUID() {
        let usage = ViewTestFixtures.makeUsage()
        let uuidStr = usage.id.uuidString.lowercased()
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: uuidStr.prefix(8).description))
    }

    func test_matchesSearch_caseInsensitive() {
        let usage = ViewTestFixtures.makeUsage(projectName: "OpenBurnBar")
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: "BURNBAR"))
        XCTAssertTrue(SessionLedgerSupport.matchesSearch(usage, query: "openburnbar"))
    }

    func test_matchesSearch_noMatch_returnsFalse() {
        let usage = ViewTestFixtures.makeUsage(sessionId: "s1", projectName: "OpenBurnBar", model: "claude-3-opus")
        XCTAssertFalse(SessionLedgerSupport.matchesSearch(usage, query: "nonexistent"))
    }

    // MARK: - groupedSessions

    func test_groupedSessions_emptyInput() {
        let groups = SessionLedgerSupport.groupedSessions([], bucket: .day)
        XCTAssertTrue(groups.isEmpty)
    }

    func test_groupedSessions_singleUsage() {
        let usage = ViewTestFixtures.makeUsage()
        let groups = SessionLedgerSupport.groupedSessions([usage], bucket: .day)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.count, 1)
    }

    func test_groupedSessions_sameDay_oneGroup() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u1 = ViewTestFixtures.makeUsage(startTime: day.addingTimeInterval(3600))
        let u2 = ViewTestFixtures.makeUsage(sessionId: "s2", startTime: day.addingTimeInterval(7200))
        let groups = SessionLedgerSupport.groupedSessions([u1, u2], bucket: .day)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.count, 2)
    }

    func test_groupedSessions_differentDays_multipleGroups() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let u1 = ViewTestFixtures.makeUsage(startTime: today.addingTimeInterval(3600))
        let u2 = ViewTestFixtures.makeUsage(sessionId: "s2", startTime: yesterday.addingTimeInterval(3600))
        let groups = SessionLedgerSupport.groupedSessions([u1, u2], bucket: .day)
        XCTAssertEqual(groups.count, 2)
    }

    func test_groupedSessions_sortedDescending() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let u1 = ViewTestFixtures.makeUsage(sessionId: "old", startTime: yesterday.addingTimeInterval(3600))
        let u2 = ViewTestFixtures.makeUsage(sessionId: "new", startTime: today.addingTimeInterval(3600))
        let groups = SessionLedgerSupport.groupedSessions([u1, u2], bucket: .day)
        // Most recent bucket first
        XCTAssertEqual(groups[0].sessions.first?.sessionId, "new")
    }
}

// MARK: - SessionLedgerBucket

@MainActor
final class SessionLedgerBucketTests: XCTestCase {

    func test_allCases_haveShortLabels() {
        for bucket in SessionLedgerBucket.allCases {
            XCTAssertFalse(bucket.shortLabel.isEmpty, "\(bucket.rawValue) has empty shortLabel")
        }
    }

    func test_startOfBucket_day() {
        let cal = Calendar.current
        let now = Date()
        let start = SessionLedgerBucket.day.startOfBucket(containing: now, calendar: cal)
        let expected = cal.startOfDay(for: now)
        XCTAssertEqual(start, expected)
    }

    func test_startOfBucket_hour() {
        let cal = Calendar.current
        let now = Date()
        let start = SessionLedgerBucket.hour.startOfBucket(containing: now, calendar: cal)
        let expected = cal.dateInterval(of: .hour, for: now)?.start ?? now
        XCTAssertEqual(start, expected)
    }

    func test_sectionTitle_nonEmpty() {
        let cal = Calendar.current
        let now = Date()
        for bucket in SessionLedgerBucket.allCases {
            let start = bucket.startOfBucket(containing: now, calendar: cal)
            let title = bucket.sectionTitle(for: start, calendar: cal)
            XCTAssertFalse(title.isEmpty, "\(bucket.rawValue) section title is empty")
        }
    }
}

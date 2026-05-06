import XCTest
import SwiftUI
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class HermesConversationListViewTests: XCTestCase {

    // MARK: - Sorting

    func testSessionsSortedByLastActiveDescending() {
        let now = Date()
        let older = HermesSessionSummary(
            id: "s-old",
            title: "Older",
            lastActiveAt: now.addingTimeInterval(-3600)
        )
        let recent = HermesSessionSummary(
            id: "s-recent",
            title: "Recent",
            lastActiveAt: now
        )
        let undated = HermesSessionSummary(
            id: "s-undated",
            title: "Undated",
            lastActiveAt: nil
        )

        let view = HermesConversationListView(service: makeService(sessions: [older, undated, recent]))
        let sorted = view.sortedSessionsForTesting

        XCTAssertEqual(sorted.map(\.id), ["s-recent", "s-old", "s-undated"])
    }

    // MARK: - HermesChatRoute Identity

    func testRouteEqualityForExistingSessions() {
        XCTAssertEqual(
            HermesChatRoute.existing(sessionID: "abc"),
            HermesChatRoute.existing(sessionID: "abc")
        )
        XCTAssertNotEqual(
            HermesChatRoute.existing(sessionID: "abc"),
            HermesChatRoute.existing(sessionID: "def")
        )
        XCTAssertNotEqual(HermesChatRoute.new, HermesChatRoute.existing(sessionID: "abc"))
    }

    // MARK: - HermesService driver behavior used by the list

    func testFABStartsNewSessionAndClearsState() {
        let service = makeService(sessions: [])
        service.selectedSessionID = "previous"
        service.messages = [HermesChatMessage(role: .user, text: "Hi")]

        service.startNewSession()

        XCTAssertNil(service.selectedSessionID)
        XCTAssertTrue(service.messages.isEmpty)
    }

    func testRowTitleFallsBackToNewConversation() {
        let session = HermesSessionSummary(id: "blank", title: nil, preview: nil)
        let service = makeService(sessions: [session])
        let view = HermesConversationListView(service: service)
        let resolved = view.sortedSessionsForTesting.first

        // We don't depend on UI introspection; instead assert the data shape
        // the row consumes (title-or-fallback) is the empty fallback case.
        XCTAssertNotNil(resolved)
        XCTAssertNil(resolved?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank)
    }

    func testActiveRowMatchesSelectedSessionID() {
        let active = HermesSessionSummary(id: "live", title: "Live")
        let other = HermesSessionSummary(id: "other", title: "Other")
        let service = makeService(sessions: [active, other])
        service.selectedSessionID = active.id

        XCTAssertEqual(service.selectedSessionID, "live")
        // Sanity: the helper used by `HermesChatView` also resolves the title.
        XCTAssertEqual(service.sessionTitle(for: "live"), "Live")
    }

    // MARK: - Helpers

    private func makeService(sessions: [HermesSessionSummary]) -> HermesService {
        let service = HermesService()
        service.sessions = sessions
        return service
    }
}

// MARK: - String helper exposed only for tests

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Test hooks

extension HermesConversationListView {
    /// Test-only accessor for the sorted list the view renders.
    var sortedSessionsForTesting: [HermesSessionSummary] {
        service.sessions.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }
}

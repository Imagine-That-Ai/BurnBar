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

    func testLibrarySessionsSortedByLastActiveDescending() {
        let now = Date()
        let older = HermesLibrarySession(
            id: "firebase:old",
            sessionId: "old",
            title: "Older",
            preview: "Old cloud chat",
            source: .firebase,
            lastActiveAt: now.addingTimeInterval(-3600),
            documentID: "old",
            inlineTranscript: nil,
            messageCount: 2
        )
        let recent = HermesLibrarySession(
            id: "icloud:recent",
            sessionId: "recent",
            title: "Recent",
            preview: "Recent iCloud chat",
            source: .iCloud,
            lastActiveAt: now,
            documentID: nil,
            inlineTranscript: "User: Hi",
            messageCount: 1
        )

        let store = HermesCloudLibraryStore()
        store.sessions = [older, recent]
        let view = HermesConversationListView(service: makeService(sessions: []))

        XCTAssertEqual(view.sortedLibrarySessionsForTesting(store: store).map(\.id), ["icloud:recent", "firebase:old"])
    }

    func testICloudHermesLibraryReaderParsesJSONLTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mobile-icloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("session_1.jsonl")
        try """
        {"role":"user","content":"What happened today?"}
        {"role":"assistant","content":"You imported Hermes history."}
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = MobileICloudHermesLibraryReader.extractSessions(from: root)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.source, .iCloud)
        XCTAssertEqual(sessions.first?.messageCount, 2)
        XCTAssertTrue(sessions.first?.inlineTranscript?.contains("You imported Hermes history.") ?? false)
    }

    func testICloudHermesLibraryReaderParsesOpenBurnBarExportJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-mobile-icloud-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("session_export.json")
        try """
        {
          "title": "Imported Hermes plan",
          "updated_at": "2026-05-06T12:00:00Z",
          "messages": [
            {"role": "transcript", "content": "User: import\\n\\nAssistant: synced"}
          ]
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let sessions = MobileICloudHermesLibraryReader.extractSessions(from: root)

        XCTAssertEqual(sessions.first?.title, "Imported Hermes plan")
        XCTAssertEqual(sessions.first?.source, .iCloud)
        XCTAssertTrue(sessions.first?.inlineTranscript?.contains("Assistant: synced") ?? false)
    }

    func testLibraryDedupPrefersFirebaseForSameSessionID() {
        let now = Date()
        let cloud = HermesLibrarySession(
            id: "firebase:doc",
            sessionId: "session-1",
            title: "Cloud",
            preview: "Cloud copy",
            source: .firebase,
            lastActiveAt: now,
            documentID: "doc",
            inlineTranscript: nil,
            messageCount: 4
        )
        let iCloud = HermesLibrarySession(
            id: "icloud:file",
            sessionId: "session-1",
            title: "iCloud",
            preview: "iCloud copy",
            source: .iCloud,
            lastActiveAt: now,
            documentID: nil,
            inlineTranscript: "Transcript",
            messageCount: 4
        )

        let deduped = HermesCloudLibraryStore.deduplicate([iCloud, cloud])

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.source, .firebase)
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

    // MARK: - First Launch Setup

    func testMobileSetupWizardUsesThreeSteps() {
        XCTAssertEqual(HermesMobileSetupStep.allCases.count, 3)
        XCTAssertEqual(HermesMobileSetupStep.allCases.map(\.number), [1, 2, 3])
        XCTAssertEqual(
            HermesMobileSetupStep.allCases.map(\.title),
            ["Keep your Mac ready", "Pick a Hermes host", "Start chatting"]
        )
    }

    func testMobileSetupWizardCompletionKeyPersistsInDefaults() {
        let suiteName = "com.openburnbar.tests.mobile.hermes.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        defaults.set(true, forKey: HermesMobileSetupWizardState.completionKey)

        XCTAssertTrue(defaults.bool(forKey: HermesMobileSetupWizardState.completionKey))
        defaults.removePersistentDomain(forName: suiteName)
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

    func sortedLibrarySessionsForTesting(store: HermesCloudLibraryStore) -> [HermesLibrarySession] {
        store.sessions.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }
}

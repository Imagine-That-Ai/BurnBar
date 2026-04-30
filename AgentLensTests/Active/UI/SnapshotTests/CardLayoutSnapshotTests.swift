import XCTest
import SwiftUI
import SnapshotTesting
import GRDB
@testable import OpenBurnBar

// MARK: - Card Layout Visual Regression Tests

/// Guards card padding, corner radius, borders, shadows, and bubble strokes
/// across light and dark modes.
@MainActor
final class CardLayoutSnapshotTests: XCTestCase {

    func test_insightBriefCard() {
        let view = InsightBriefCard(
            title: "Where you left off",
            bodyText: "Working on auth module in OpenBurnBar.",
            icon: "arrow.right",
            accent: .blue,
            action: {}
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 360, height: 100),
            named: SnapshotName.insightBriefCard
        )
    }

    func test_narrativeCard_withData() throws {
        let store = try makeIsolatedStore()
        store.replaceUsages(ViewTestFixtures.makeWeekOfUsages())
        let view = NarrativeCardView(dataStore: store)
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 360, height: 120),
            named: SnapshotName.narrativeCard
        )
    }

    func test_chatMessageView_assistantBubble() {
        let message = ViewTestFixtures.makeAssistantMessage(content: "This is an assistant reply bubble.")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 100),
            named: SnapshotName.chatMessageAssistant
        )
    }

    func test_hermesToolCard_geometry() {
        // Verify the tool card's UnevenRoundedRectangle, border width,
        // ultraThinMaterial background, and mercury gradient stroke.
        let view = HermesToolCard(
            toolName: "Edit",
            detail: "Replace 'foo' with 'bar' in /src/main.swift",
            isRunning: false
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 320, height: 70),
            named: "hermesToolCard.geometry"
        )
    }

    // MARK: - Helpers

    private func makeIsolatedStore() throws -> DataStore {
        try DataStore(databaseQueue: DatabaseQueue(), refreshOnInit: false)
    }
}

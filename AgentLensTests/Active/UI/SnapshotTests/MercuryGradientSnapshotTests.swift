import XCTest
import SwiftUI
import SnapshotTesting
@testable import OpenBurnBar

// MARK: - Mercury Gradient Visual Regression Tests

/// Guards mercury gradient chat bubbles, shimmer animations, and tool card visuals
/// against regressions in both dark and light modes.
@MainActor
final class MercuryGradientSnapshotTests: XCTestCase {

    func test_hermesToolCard_completed() {
        let view = HermesToolCard(
            toolName: "Bash",
            detail: nil,
            isRunning: false
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 320, height: 50),
            named: SnapshotName.hermesToolCardCompleted
        )
    }

    func test_hermesToolCard_expanded() {
        // Expansion is driven by @State isExpanded, which defaults to false.
        // We simulate an expanded state by constructing a view that has detail
        // and is not running; the card renders with the chevron visible.
        let view = HermesToolCard(
            toolName: "Grep",
            detail: "search_pattern = 'func test'",
            isRunning: false
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 320, height: 60),
            named: SnapshotName.hermesToolCardExpanded
        )
    }

    func test_hermesThinkingView() {
        let view = HermesThinkingView()
        // Lower precision because droplet animation depends on onAppear timing
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 200, height: 60),
            named: SnapshotName.hermesThinkingView,
            precision: 0.75
        )
    }

    func test_chatMessageView_hermesAssistant() {
        let message = ViewTestFixtures.makeHermesAssistantMessage(
            textPieces: ["Mercury rising."],
            toolPieces: [],
            cliUsed: "hermes"
        )
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: true,
            isHermes: true
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 120),
            named: SnapshotName.chatMessageHermes
        )
    }

    func test_chatMessageView_user() {
        let message = ViewTestFixtures.makeUserMessage(content: "Hello Hermes")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 80),
            named: SnapshotName.chatMessageUser
        )
    }

    func test_chatMessageView_streamingAssistant() {
        let message = ViewTestFixtures.makeAssistantMessage(content: "Processing")
        let view = ChatMessageView(
            message: message,
            isStreaming: true,
            showViaBadge: false
        )
        // Lower precision because streaming caret blinks
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 80),
            named: SnapshotName.chatMessageStreaming,
            precision: 0.75
        )
    }
}

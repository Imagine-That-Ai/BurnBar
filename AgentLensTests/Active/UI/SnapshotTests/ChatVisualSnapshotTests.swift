import XCTest
import SwiftUI
import SnapshotTesting
@testable import OpenBurnBar

// MARK: - Chat Visual Regression Tests

/// Guards chat bubbles, panel chrome, and FAB visuals in both color schemes.
@MainActor
final class ChatVisualSnapshotTests: XCTestCase {

    func test_chatMessageView_user() {
        let message = ViewTestFixtures.makeUserMessage(content: "What's my burn rate today?")
        let view = ChatMessageView(
            message: message,
            isStreaming: false,
            showViaBadge: false
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 400, height: 80),
            named: "chatVisual.userMessage"
        )
    }

    func test_chatMessageView_hermesWithBadge() {
        let message = ViewTestFixtures.makeHermesAssistantMessage(
            textPieces: ["Your burn rate is $4.20 today."],
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
            named: "chatVisual.hermesBadge"
        )
    }

    func test_chatFAB_withInsights() {
        let view = ChatFAB(hasNewInsights: true, action: {})
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 80, height: 80),
            named: SnapshotName.chatFAB
        )
    }

    func test_chatFAB_withoutInsights() {
        let view = ChatFAB(hasNewInsights: false, action: {})
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 80, height: 80),
            named: "chatFAB.noInsights"
        )
    }
}

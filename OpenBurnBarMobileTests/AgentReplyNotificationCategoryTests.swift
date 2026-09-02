import XCTest
@testable import OpenBurnBarMobile

/// Pins the notification-category set `AgentReplyNotificationService`
/// registers with `UNUserNotificationCenter`. `setNotificationCategories`
/// REPLACES the whole set, so a category that drops out of
/// `registeredCategories` silently loses its actions — including the
/// device-approval Approve/Deny pair, which is a security surface.
@MainActor
final class AgentReplyNotificationCategoryTests: XCTestCase {
    func testRegisteredCategoriesCoverAllThreePushFamilies() {
        XCTAssertEqual(
            Set(AgentReplyNotificationService.registeredCategories.map(\.identifier)),
            ["AGENT_REPLY", "AI_INBOX_ITEM", "DEVICE_APPROVAL_REQUEST"]
        )
    }

    func testDeviceApprovalCategoryCarriesApproveAndDenyActions() {
        let category = AgentReplyNotificationService.registeredCategories
            .first { $0.identifier == "DEVICE_APPROVAL_REQUEST" }
        XCTAssertNotNil(category)
        XCTAssertEqual(
            category?.actions.map(\.identifier),
            ["DEVICE_APPROVAL_APPROVE", "DEVICE_APPROVAL_DENY"]
        )
        XCTAssertEqual(category?.actions.map(\.title), ["Approve", "Deny"])
        for action in category?.actions ?? [] {
            XCTAssertTrue(action.options.contains(.foreground), action.identifier)
            XCTAssertTrue(action.options.contains(.authenticationRequired), action.identifier)
        }
    }

    func testAgentReplyAndInboxCategoriesKeepTheirSiblingShapes() {
        let categories = AgentReplyNotificationService.registeredCategories
        let agentReply = categories.first { $0.identifier == "AGENT_REPLY" }
        XCTAssertEqual(
            agentReply?.actions.map(\.identifier),
            ["AGENT_REPLY_INLINE_REPLY", "AGENT_REPLY_OPEN"]
        )
        let inbox = categories.first { $0.identifier == "AI_INBOX_ITEM" }
        XCTAssertEqual(inbox?.actions.map(\.identifier), ["AI_INBOX_OPEN"])
    }
}

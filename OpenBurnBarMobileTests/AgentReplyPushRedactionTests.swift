import XCTest
@testable import OpenBurnBarMobile

/// T-IOS-04 — the receive-path guarantee that a server-supplied agent-reply push
/// preview is redacted to a generic string before it can reach a banner / lock
/// screen, unless the build explicitly opts in. Pure decision over injected
/// `UserDefaults`.
final class AgentReplyPushRedactionTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentReplyPushRedactionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultRedactsServerSuppliedPreview() {
        let defaults = makeDefaults()
        let redacted = AgentReplyPushRedaction.redactedPreview("Your bank statement balance is $4,201", defaults: defaults)
        XCTAssertEqual(redacted, AgentReplyPushRedaction.genericPreview)
        XCTAssertFalse(redacted.contains("bank"), "Reply content must never reach the banner by default.")
    }

    func testEmptyPreviewFallsBackToGenericEvenWhenRawEnabled() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AgentReplyPushRedaction.showRawPreviewDefaultsKey)
        XCTAssertEqual(
            AgentReplyPushRedaction.redactedPreview("   ", defaults: defaults),
            AgentReplyPushRedaction.genericPreview
        )
    }

    func testRawPreviewShownOnlyWhenExplicitlyEnabled() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AgentReplyPushRedaction.showRawPreviewDefaultsKey)
        XCTAssertEqual(
            AgentReplyPushRedaction.redactedPreview("hello", defaults: defaults),
            "hello"
        )
    }
}

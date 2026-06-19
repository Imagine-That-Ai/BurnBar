import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore

final class RemoteAccessUnicodeTypingPlanTests: XCTestCase {
    func testUnicodeFallbackOnlyCarriesTextOnKeyDown() {
        let events = RemoteAccessUnicodeTypingPlan.events(for: "ab")

        XCTAssertEqual(events, [
            .init(text: "a", isKeyDown: true, carriesUnicodeText: true),
            .init(text: "a", isKeyDown: false, carriesUnicodeText: false),
            .init(text: "b", isKeyDown: true, carriesUnicodeText: true),
            .init(text: "b", isKeyDown: false, carriesUnicodeText: false)
        ])
    }

    func testUnicodeFallbackPreservesExtendedGraphemeClusters() {
        let events = RemoteAccessUnicodeTypingPlan.events(for: "e\u{301}")

        XCTAssertEqual(events, [
            .init(text: "e\u{301}", isKeyDown: true, carriesUnicodeText: true),
            .init(text: "e\u{301}", isKeyDown: false, carriesUnicodeText: false)
        ])
    }
}

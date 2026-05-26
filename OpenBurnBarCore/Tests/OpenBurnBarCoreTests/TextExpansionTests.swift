import XCTest
@testable import OpenBurnBarCore

final class TextExpansionTests: XCTestCase {
    func testTriggerNormalizationAndValidation() {
        XCTAssertEqual(TextExpansionTrigger.canonicalName("&&Confident"), "confident")
        XCTAssertEqual(TextExpansionTrigger.activationToken(for: "confident"), "&&confident")
        XCTAssertNil(TextExpansionTrigger.validationError(for: "confident_reply"))
        XCTAssertNil(TextExpansionTrigger.validationError(for: "follow-up_2"))
        XCTAssertNotNil(TextExpansionTrigger.validationError(for: "too short"))
        XCTAssertNotNil(TextExpansionTrigger.validationError(for: "with space"))
        XCTAssertNotNil(TextExpansionTrigger.validationError(for: "bad$"))
    }

    func testStaticExpansionReplacesTokenAndPreservesBoundary() {
        let snippet = TextExpansionSnippet(
            title: "Confident",
            trigger: "confident",
            body: "I'm confident this is the right next step."
        )

        let result = TextExpansionMatcher.expandStaticIfAvailable(
            in: "Send &&confident ",
            snippets: [snippet],
            surface: .inAppThread
        )

        XCTAssertEqual(result?.text, "Send I'm confident this is the right next step. ")
        XCTAssertEqual(result?.match.token, "&&confident")
        XCTAssertEqual(result?.match.boundary, " ")
    }

    func testStaticExpansionTreatsSentencePunctuationAsBoundary() {
        let snippet = TextExpansionSnippet(title: "Thanks", trigger: "thanks", body: "Thank you")

        XCTAssertEqual(TextExpansionMatcher.expandStaticIfAvailable(
            in: "Send &&thanks.",
            snippets: [snippet],
            surface: .inAppThread
        )?.text, "Send Thank you.")
    }

    func testDoesNotExpandPrefixCollisionBeforeBoundary() {
        let short = TextExpansionSnippet(title: "Pro", trigger: "pro", body: "professional")
        let long = TextExpansionSnippet(title: "Proposal", trigger: "proposal", body: "proposal draft")

        XCTAssertNil(TextExpansionMatcher.expandStaticIfAvailable(
            in: "&&pro",
            snippets: [short, long],
            surface: .inAppThread
        ))

        XCTAssertEqual(TextExpansionMatcher.expandStaticIfAvailable(
            in: "&&pro ",
            snippets: [short, long],
            surface: .inAppThread
        )?.text, "professional ")
    }

    func testUnambiguousTokenCanExpandWithoutBoundary() {
        let snippet = TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready.")

        XCTAssertEqual(TextExpansionMatcher.expandStaticIfAvailable(
            in: "&&confident",
            snippets: [snippet],
            surface: .inAppThread
        )?.text, "Ready.")
    }

    func testLLMModeReturnsPreviewMatchInsteadOfExpanding() {
        let snippet = TextExpansionSnippet(
            title: "Contextual",
            trigger: "ctx",
            body: "Make this fit.",
            mode: .llmRewrite
        )

        let match = TextExpansionMatcher.match(
            in: "Please &&ctx ",
            snippets: [snippet],
            surface: .inAppThread
        )

        XCTAssertEqual(match?.token, "&&ctx")
        XCTAssertEqual(match?.requiresPreview, true)
        XCTAssertNil(TextExpansionMatcher.expandStaticIfAvailable(
            in: "Please &&ctx ",
            snippets: [snippet],
            surface: .inAppThread
        ))
    }

    func testScopeBlocksUnavailableSurfaces() {
        let snippet = TextExpansionSnippet(
            title: "Thread Only",
            trigger: "thread",
            body: "Thread text",
            scope: TextExpansionScope(surfaces: [.inAppThread], threadIDs: ["abc"])
        )

        XCTAssertNil(TextExpansionMatcher.match(
            in: "&&thread ",
            snippets: [snippet],
            surface: .macGlobal
        ))
        XCTAssertNil(TextExpansionMatcher.match(
            in: "&&thread ",
            snippets: [snippet],
            surface: .inAppThread,
            threadID: "other"
        ))
        XCTAssertNotNil(TextExpansionMatcher.match(
            in: "&&thread ",
            snippets: [snippet],
            surface: .inAppThread,
            threadID: "abc"
        ))
    }
}

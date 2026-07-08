import XCTest
@testable import OpenBurnBarMobile

/// Locks the exact behavior of `ComputerUseSecurityCallableClient.providerAccountSubjectId`
/// across the audit-wave-4 force-unwrap removal (item 9, site 3). The helper is pure, so these
/// assertions must pass byte-for-byte both before and after the refactor:
/// - nil / empty / whitespace-only account IDs fall back to `<provider>_default`.
/// - Non-blank account IDs pass the ORIGINAL (untrimmed) string into the sanitizer, whose
///   hyphen-collapse + edge-trim makes " acct " and "acct" produce the same subject id.
final class ComputerUseProviderAccountSubjectIdTests: XCTestCase {

    func testNilAccountIDFallsBackToProviderDefault() {
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.providerAccountSubjectId(provider: "codex", accountID: nil),
            "codex_default"
        )
    }

    func testEmptyAccountIDFallsBackToProviderDefault() {
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.providerAccountSubjectId(provider: "codex", accountID: ""),
            "codex_default"
        )
    }

    func testWhitespaceOnlyAccountIDFallsBackToProviderDefault() {
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.providerAccountSubjectId(provider: "codex", accountID: "  "),
            "codex_default"
        )
    }

    func testPlainAccountIDIsUsedDirectly() {
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.providerAccountSubjectId(provider: "codex", accountID: "acct"),
            "acct"
        )
    }

    func testUntrimmedAccountIDPreservesOriginalStringThroughSanitizer() {
        // The original " acct " (not a pre-trimmed copy) reaches the sanitizer; its
        // whitespace becomes hyphens that the sanitizer's edge-trim removes.
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.providerAccountSubjectId(provider: "codex", accountID: " acct "),
            "acct"
        )
    }

    func testSanitizerFallbackWhenAccountIDSanitizesToEmpty() {
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.providerAccountSubjectId(provider: "OpenAI", accountID: "!!!"),
            "openai_default"
        )
    }
}

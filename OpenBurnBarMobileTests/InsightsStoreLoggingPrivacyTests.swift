import XCTest
@testable import OpenBurnBarMobile

final class InsightsStoreLoggingPrivacyTests: XCTestCase {

    func testSensitiveTextLogContextDoesNotExposePromptText() {
        let secretPrompt = "Investigate api_key=sk-test-123 and customer@example.com"

        let context = InsightsStore.sensitiveTextLogContext(secretPrompt)

        XCTAssertEqual(context.fingerprint.count, 64)
        XCTAssertTrue(context.fingerprint.allSatisfy(\.isHexDigit))
        XCTAssertEqual(context.characterCount, secretPrompt.count)
        XCTAssertFalse(context.fingerprint.contains("sk-test-123"))
        XCTAssertFalse(context.fingerprint.contains("customer@example.com"))
        XCTAssertFalse(context.fingerprint.contains(secretPrompt))
    }

    func testSensitiveTextLogContextIsStableForCorrelation() {
        let prompt = "Compare provider spend for the last week."

        XCTAssertEqual(
            InsightsStore.sensitiveTextLogContext(prompt),
            InsightsStore.sensitiveTextLogContext(prompt)
        )
        XCTAssertNotEqual(
            InsightsStore.sensitiveTextLogContext(prompt).fingerprint,
            InsightsStore.sensitiveTextLogContext(prompt + " Include quota risk.").fingerprint
        )
    }

    func testErrorLogContextDoesNotExposeLocalizedMessage() {
        let error = SensitiveTestError(message: "Request failed for bearer secret-token-123")

        let context = InsightsStore.errorLogContext(error)

        XCTAssertTrue(context.typeName.contains("SensitiveTestError"))
        XCTAssertEqual(context.message.fingerprint.count, 64)
        XCTAssertTrue(context.message.fingerprint.allSatisfy(\.isHexDigit))
        XCTAssertEqual(context.message.characterCount, error.localizedDescription.count)
        XCTAssertFalse(context.message.fingerprint.contains("secret-token-123"))
        XCTAssertFalse(context.message.fingerprint.contains(error.localizedDescription))
    }

    private struct SensitiveTestError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }
}

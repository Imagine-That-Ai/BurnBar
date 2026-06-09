import XCTest
import OpenBurnBarSignalCore

/// F5: a present at-rest envelope that fails sender authentication must NOT
/// silently downgrade to the unauthenticated legacy `sealedPayload`.
final class SignalAtRestFallbackPolicyTests: XCTestCase {
    func testForgedStrippedAndRelocatedAlwaysFailClosed() {
        for complete in [false, true] {
            XCTAssertFalse(
                OpenBurnBarSignalCoreError.senderSignatureInvalid.allowsLegacyAtRestFallback(senderSetComplete: complete),
                "a forged sender signature never falls back to legacy"
            )
            XCTAssertFalse(
                OpenBurnBarSignalCoreError.senderAuthMissing.allowsLegacyAtRestFallback(senderSetComplete: complete),
                "a stripped sender block never falls back to legacy"
            )
            XCTAssertFalse(
                OpenBurnBarSignalCoreError.bindingMismatch.allowsLegacyAtRestFallback(senderSetComplete: complete),
                "a relocated/replayed envelope never falls back to legacy"
            )
        }
    }

    func testUnknownSenderIsConditionalOnSetCompleteness() {
        let err = OpenBurnBarSignalCoreError.senderNotTrusted("device-x")
        XCTAssertTrue(
            err.allowsLegacyAtRestFallback(senderSetComplete: false),
            "while the trusted-sender set is still resolving, an unknown sender is a readiness gap — legacy-eligible"
        )
        XCTAssertFalse(
            err.allowsLegacyAtRestFallback(senderSetComplete: true),
            "once every sender is resolved, an unknown sender is an attack — fail closed"
        )
    }

    func testStructuralErrorsPreserveLegacyBehavior() {
        let structural: [OpenBurnBarSignalCoreError] = [
            .noRecipients, .tooManyRecipients, .invalidRecipientKind("x"),
            .duplicateRecipientIdentityKeyId("x"), .invalidEnvelope,
            .missingRecipientWrap("x"), .invalidContentKey, .recipientPrivateKeyMismatch,
        ]
        for err in structural {
            XCTAssertTrue(
                err.allowsLegacyAtRestFallback(senderSetComplete: true),
                "\(err) is not a sender downgrade and stays legacy-eligible"
            )
        }
    }
}

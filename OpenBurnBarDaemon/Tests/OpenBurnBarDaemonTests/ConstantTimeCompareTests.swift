import Foundation
import XCTest
@testable import OpenBurnBarDaemon

/// L6 — the daemon control socket and the local HTTP gateway authenticate
/// presented tokens with `constantTimeTokensEqual` instead of `==` so a
/// byte-position timing oracle cannot leak the configured token. These tests
/// pin the comparator's correctness matrix: equality is exact (whole-byte,
/// whole-length), every class of mismatch fails, and length is folded into
/// the result rather than short-circuited.
final class ConstantTimeCompareTests: XCTestCase {
    func testEqualTokensCompareEqual() {
        XCTAssertTrue(constantTimeTokensEqual("", ""))
        XCTAssertTrue(constantTimeTokensEqual("a", "a"))
        XCTAssertTrue(constantTimeTokensEqual("secret-token-123", "secret-token-123"))

        let highEntropy = UUID().uuidString + UUID().uuidString
        XCTAssertTrue(constantTimeTokensEqual(highEntropy, highEntropy))
    }

    func testFirstByteMismatchFails() {
        XCTAssertFalse(constantTimeTokensEqual("Xecret-token-123", "secret-token-123"))
    }

    func testLastByteMismatchFails() {
        XCTAssertFalse(constantTimeTokensEqual("secret-token-12X", "secret-token-123"))
    }

    func testMiddleByteMismatchFails() {
        XCTAssertFalse(constantTimeTokensEqual("secret-tokXn-123", "secret-token-123"))
    }

    func testLengthMismatchFailsInBothDirections() {
        // The length difference is folded into the accumulator, not an early
        // return — both prefix and extension mismatches must fail.
        XCTAssertFalse(constantTimeTokensEqual("secret", "secret-token-123"))
        XCTAssertFalse(constantTimeTokensEqual("secret-token-123", "secret"))
        XCTAssertFalse(constantTimeTokensEqual("", "x"))
        XCTAssertFalse(constantTimeTokensEqual("x", ""))
    }

    func testSharedPrefixWithTrailingNulLikeBytesFails() {
        // The padding byte for the shorter operand is 0x00; a token whose extra
        // suffix is a literal NUL must still mismatch (diff folds count XOR).
        let short = "token"
        let padded = "token\u{0000}"
        XCTAssertFalse(constantTimeTokensEqual(short, padded))
        XCTAssertFalse(constantTimeTokensEqual(padded, short))
    }

    func testComparisonIsByteExactForMultibyteUTF8() {
        XCTAssertTrue(constantTimeTokensEqual("töken-é", "töken-é"))
        XCTAssertFalse(constantTimeTokensEqual("töken-é", "token-e"))
        // Same scalars, different normalization forms are different bytes —
        // the comparator must treat them as a mismatch (token equality is
        // byte equality, never Unicode-canonical equality).
        let composed = "caf\u{00E9}"        // é as a single scalar
        let decomposed = "cafe\u{0301}"     // e + combining acute
        XCTAssertFalse(constantTimeTokensEqual(composed, decomposed))
    }
}

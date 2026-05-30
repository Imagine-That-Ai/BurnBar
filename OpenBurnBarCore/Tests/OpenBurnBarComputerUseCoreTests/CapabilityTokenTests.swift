import XCTest
@testable import OpenBurnBarComputerUseCore

final class CapabilityTokenTests: XCTestCase {
    func test_expiredTokenDetected() {
        let token = CapabilityToken(
            domain: .remoteUnlock,
            nonce: "n1",
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 1),
            allowedActionKinds: ["click"],
            scopeHash: "abc",
            actionBudget: 1
        )
        XCTAssertTrue(token.isExpired())
    }

    func test_allowsListedActionKind() {
        let token = CapabilityToken(
            domain: .computerUse,
            nonce: "n2",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            allowedActionKinds: ["pointer_move", "click"],
            scopeHash: "def",
            actionBudget: 3
        )
        XCTAssertTrue(token.allows(actionKind: "click"))
        XCTAssertFalse(token.allows(actionKind: "type"))
    }
}

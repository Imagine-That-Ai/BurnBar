import XCTest
@testable import OpenBurnBarComputerUseCore

final class PhoneControlAttestationPolicyTests: XCTestCase {
    func testPermissiveNeverRequiresAttestation() {
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: false, macHostHasBoundClaim: false),
            .none
        )
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: false, macHostHasBoundClaim: true),
            .none
        )
    }

    func testStrictRequiresMacHostBound() {
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: true, macHostHasBoundClaim: false),
            .rejectUnboundHost
        )
    }

    func testStrictRequiresPhoneEnvelopeAttestationWhenMacBound() {
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: true, macHostHasBoundClaim: true),
            .requirePresent
        )
    }
}
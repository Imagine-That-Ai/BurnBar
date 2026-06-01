import XCTest
@testable import OpenBurnBarComputerUseCore

final class PhoneControlAttestationPolicyTests: XCTestCase {
    func testPermissiveWhenStrictOffAndMacUnbound() {
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: false, macBoundDigest: nil),
            .none
        )
    }

    func testRequiredWhenStrictOffAndMacBound() {
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: false, macBoundDigest: "abc"),
            .required(digest: "abc")
        )
    }

    func testRejectUnboundWhenStrictOnAndMacUnbound() {
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: true, macBoundDigest: nil),
            .rejectUnboundHost
        )
    }

    func testRequiredWhenStrictOnAndMacBound() {
        XCTAssertEqual(
            PhoneControlAttestationPolicy.requirement(strictMode: true, macBoundDigest: "digest"),
            .required(digest: "digest")
        )
    }
}
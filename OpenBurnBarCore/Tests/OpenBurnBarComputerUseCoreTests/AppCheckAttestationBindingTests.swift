import XCTest
@testable import OpenBurnBarComputerUseCore

final class AppCheckAttestationBindingTests: XCTestCase {
    func testDigestIsStableForClaim() {
        let claim = AppCheckAttestationBinding.Claim(appId: "1:123:ios:abc", boundAtMillis: 1_700_000_000_000)
        let a = AppCheckAttestationBinding.digestHex(for: claim)
        let b = AppCheckAttestationBinding.digestHex(appId: claim.appId, boundAtMillis: claim.boundAtMillis)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64) // SHA-256 hex
    }

    func testDigestMatchesFunctionsGoldenVector() {
        let claim = AppCheckAttestationBinding.Claim(appId: "1:123:ios:abc", boundAtMillis: 1_700_000_000_000)
        XCTAssertEqual(
            AppCheckAttestationBinding.digestHex(for: claim),
            "fd33c159e0a5e24cdbb037c2d0be37e43dfde84c4adcfa711e59f1a039a4c1ce"
        )
    }

    func testParseClaimFromTokenDictionary() {
        let token: [String: Any] = [
            AppCheckAttestationBinding.claimKey: [
                "v": 1,
                "appId": "1:456:ios:def",
                "boundAtMillis": Int64(1_800_000_000_000),
            ],
        ]
        let claim = AppCheckAttestationBinding.parseClaim(from: token)
        XCTAssertEqual(claim?.appId, "1:456:ios:def")
        XCTAssertEqual(claim?.boundAtMillis, 1_800_000_000_000)
    }
}
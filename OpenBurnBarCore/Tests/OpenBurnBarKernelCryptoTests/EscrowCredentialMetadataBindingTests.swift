import XCTest
@testable import OpenBurnBarKernelCrypto

final class EscrowCredentialMetadataBindingTests: XCTestCase {
    func testAssociatedDataChangesWhenCredentialMetadataChanges() {
        let base = EscrowCredentialMetadataBinding(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "iphone-1",
            providerId: "minimax",
            credentialKind: .apiKey,
            accountLabel: "primary",
            keyVersion: 3
        )
        let providerTampered = EscrowCredentialMetadataBinding(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "iphone-1",
            providerId: "openai",
            credentialKind: .apiKey,
            accountLabel: "primary",
            keyVersion: 3
        )
        let kindTampered = EscrowCredentialMetadataBinding(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "iphone-1",
            providerId: "minimax",
            credentialKind: .oauthToken,
            accountLabel: "primary",
            keyVersion: 3
        )

        XCTAssertNotEqual(base.associatedData, providerTampered.associatedData)
        XCTAssertNotEqual(base.associatedData, kindTampered.associatedData)
        XCTAssertEqual(String(data: base.associatedData, encoding: .utf8)?.contains("provider:7:minimax"), true)
    }
}

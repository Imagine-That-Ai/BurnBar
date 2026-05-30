import XCTest
import CryptoKit
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarRemoteAccessAgentCore

final class VirtualHIDBridgeCapabilityGateTests: XCTestCase {
    private let issuer = CapabilityTokenIssuer()

    func test_layersPolicyAndToken() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let leafVerifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "click"
        )
        let ok = VirtualHIDBridgeCapabilityGate.Request(
            kind: "click",
            text: nil,
            key: nil,
            modifiers: nil,
            capabilityToken: token
        )
        if case .failure = VirtualHIDBridgeCapabilityGate.validate(ok, verifier: leafVerifier) {
            XCTFail("Expected success")
        }

        let missingToken = VirtualHIDBridgeCapabilityGate.Request(
            kind: "click",
            text: nil,
            key: nil,
            modifiers: nil,
            capabilityToken: nil
        )
        guard case .failure(.capabilityTokenMissing) = VirtualHIDBridgeCapabilityGate.validate(
            missingToken,
            verifier: leafVerifier
        ) else {
            return XCTFail("Expected missing token")
        }

        let disallowed = VirtualHIDBridgeCapabilityGate.Request(
            kind: "type",
            text: "pw",
            key: nil,
            modifiers: nil,
            capabilityToken: token
        )
        guard case .failure(.disallowedTypeOperation) = VirtualHIDBridgeCapabilityGate.validate(
            disallowed,
            verifier: leafVerifier
        ) else {
            return XCTFail("Expected disallowed type")
        }
    }
}

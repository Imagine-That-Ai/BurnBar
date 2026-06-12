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
            XCTFail("Expected missing token")
            return
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
            XCTFail("Expected disallowed type")
            return
        }
    }

    func test_credentialTypeRequiresCredentialCapabilityToken() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let leafVerifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "type_credential"
        )

        let ok = VirtualHIDBridgeCapabilityGate.CredentialRequest(capabilityToken: token)
        if case .failure = VirtualHIDBridgeCapabilityGate.validateCredentialType(ok, verifier: leafVerifier) {
            XCTFail("Expected credential token success")
        }

        let missingToken = VirtualHIDBridgeCapabilityGate.CredentialRequest(capabilityToken: nil)
        guard case .failure(.capabilityTokenMissing) = VirtualHIDBridgeCapabilityGate.validateCredentialType(
            missingToken,
            verifier: leafVerifier
        ) else {
            XCTFail("Expected missing credential token")
            return
        }

        let clickToken = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "click"
        )
        let wrongAction = VirtualHIDBridgeCapabilityGate.CredentialRequest(capabilityToken: clickToken)
        guard case .failure(.capabilityTokenActionNotAllowed) = VirtualHIDBridgeCapabilityGate.validateCredentialType(
            wrongAction,
            verifier: leafVerifier
        ) else {
            XCTFail("Expected click token to be rejected for credential typing")
            return
        }
    }
}

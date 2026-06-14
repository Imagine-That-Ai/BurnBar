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

    func test_bindingRejectsMismatchedEscrowDevice() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let leafVerifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "click",
            boundEscrowDeviceId: "iphone-a"
        )
        let request = VirtualHIDBridgeCapabilityGate.Request(
            kind: "click",
            text: nil,
            key: nil,
            modifiers: nil,
            capabilityToken: token
        )
        let binding = VirtualHIDBridgeCapabilityGate.PresenterBinding(escrowDeviceId: "iphone-b")
        guard case .failure(.capabilityTokenEscrowMismatch) = VirtualHIDBridgeCapabilityGate.validate(
            request,
            verifier: leafVerifier,
            presenterBinding: binding
        ) else {
            XCTFail("Expected escrow device mismatch")
            return
        }
    }

    func test_bindingRejectsMismatchedAttestationHash() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let leafVerifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "click",
            attestationHashBlake3: "aaa"
        )
        let request = VirtualHIDBridgeCapabilityGate.Request(
            kind: "click",
            text: nil,
            key: nil,
            modifiers: nil,
            capabilityToken: token
        )
        let binding = VirtualHIDBridgeCapabilityGate.PresenterBinding(attestationHashBlake3: "bbb")
        guard case .failure(.capabilityTokenAttestationMismatch) = VirtualHIDBridgeCapabilityGate.validate(
            request,
            verifier: leafVerifier,
            presenterBinding: binding
        ) else {
            XCTFail("Expected attestation mismatch")
            return
        }
    }

    func test_bindingRejectsMismatchedScopeHash() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let leafVerifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope-a",
            actionKind: "click"
        )
        let request = VirtualHIDBridgeCapabilityGate.Request(
            kind: "click",
            text: nil,
            key: nil,
            modifiers: nil,
            capabilityToken: token
        )
        let binding = VirtualHIDBridgeCapabilityGate.PresenterBinding(scopeHash: "scope-b")
        guard case .failure(.capabilityTokenScopeMismatch) = VirtualHIDBridgeCapabilityGate.validate(
            request,
            verifier: leafVerifier,
            presenterBinding: binding
        ) else {
            XCTFail("Expected scope mismatch")
            return
        }
    }

    func test_bindingAcceptsMatchingPresenter() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let leafVerifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope-a",
            actionKind: "click",
            boundEscrowDeviceId: "iphone-a",
            attestationHashBlake3: "attest-a"
        )
        let request = VirtualHIDBridgeCapabilityGate.Request(
            kind: "click",
            text: nil,
            key: nil,
            modifiers: nil,
            capabilityToken: token
        )
        let binding = VirtualHIDBridgeCapabilityGate.PresenterBinding(
            escrowDeviceId: "iphone-a",
            attestationHashBlake3: "attest-a",
            scopeHash: "scope-a"
        )
        if case .failure = VirtualHIDBridgeCapabilityGate.validate(
            request,
            verifier: leafVerifier,
            presenterBinding: binding
        ) {
            XCTFail("Expected success with matching binding")
        }
    }
}

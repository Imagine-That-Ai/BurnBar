import XCTest
import CryptoKit
@testable import OpenBurnBarComputerUseCore

final class CapabilityTokenVerifierTests: XCTestCase {
    private let issuer = CapabilityTokenIssuer()
    private let signer = CapabilityTokenSigner()

    func test_offlineVerification_acceptsValidRemoteUnlockToken() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let verifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope-a",
            actionKind: "click",
            ttl: 60
        )
        let request = CapabilityTokenLeafVerifier.Request(
            token: token,
            expectedDomain: .remoteUnlock,
            actionKind: "click"
        )
        if case .failure = verifier.verify(request: request) {
            XCTFail("Expected success")
        }
    }

    func test_offlineVerification_rejectsExpiredToken() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = CapabilityTokenLeafVerifier(nonceStore: InMemoryCapabilityTokenNonceStore()) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        var token = CapabilityToken(
            domain: .remoteUnlock,
            nonce: "n-expired",
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 1),
            allowedActionKinds: ["click"],
            scopeHash: "scope",
            actionBudget: 1
        )
        token = try signer.sign(token: token, privateKey: privateKey)
        let request = CapabilityTokenLeafVerifier.Request(
            token: token,
            expectedDomain: .remoteUnlock,
            actionKind: "click"
        )
        guard case .failure(.expired) = verifier.verify(
            request: request,
            now: Date(timeIntervalSince1970: 100)
        ) else {
            XCTFail("Expected expired")
            return
        }
    }

    func test_offlineVerification_rejectsNonceReplay() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonceStore = InMemoryCapabilityTokenNonceStore()
        let verifier = CapabilityTokenLeafVerifier(nonceStore: nonceStore) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "pointer_move",
            nonce: "fixed-nonce"
        )
        let request = CapabilityTokenLeafVerifier.Request(
            token: token,
            expectedDomain: .remoteUnlock,
            actionKind: "pointer_move"
        )
        if case .failure = verifier.verify(request: request) {
            XCTFail("Expected success")
        }
        guard case .failure(.nonceReplay) = verifier.verify(request: request) else {
            XCTFail("Expected nonce replay")
            return
        }
    }

    func test_offlineVerification_rejectsAttestationMismatch() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = CapabilityTokenLeafVerifier(nonceStore: InMemoryCapabilityTokenNonceStore()) {
            CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "test")
        }
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "click",
            attestationHashBlake3: "aaa"
        )
        let request = CapabilityTokenLeafVerifier.Request(
            token: token,
            expectedDomain: .remoteUnlock,
            actionKind: "click",
            requiredAttestationHashBlake3: "bbb"
        )
        guard case .failure(.attestationMismatch) = verifier.verify(request: request) else {
            XCTFail("Expected attestation mismatch")
            return
        }
    }

    func test_issuerTrustMaterial_roundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let material = CapabilityTokenIssuerTrustMaterial(
            keyId: "cap-test",
            publicKeyEd25519Base64: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("issuer-trust-\(UUID().uuidString).json")
            .path
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        try material.write(to: tempPath)
        let loaded = CapabilityTokenIssuerTrustMaterial.load(from: tempPath)
        XCTAssertEqual(loaded?.keyId, material.keyId)
        XCTAssertEqual(loaded?.publicKeyEd25519Base64, material.publicKeyEd25519Base64)
        let trust = try XCTUnwrap(loaded).issuerTrust()
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope",
            actionKind: "click"
        )
        XCTAssertTrue(try signer.verify(token: token, publicKey: trust.publicKey))
    }
}

import XCTest
import CryptoKit
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarRemoteAccessAgentCore

final class RemoteUnlockSessionContextFileProviderTests: XCTestCase {
    func test_contextProviderLoadsVerifiedSnapshotForTokenScope() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = RemoteUnlockSessionContextSnapshotSigner()
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-session-context-\(UUID().uuidString).json")
            .path
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        let now = Date(timeIntervalSince1970: 2_000)
        let issuer = CapabilityTokenIssuer()
        let token = try issuer.mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope-a",
            actionKind: "click",
            boundEscrowDeviceId: "iphone-a",
            attestationHashBlake3: "attest-a",
            now: now
        )
        let snapshot = RemoteUnlockSessionContextSnapshot(
            sessionId: "session-a",
            peerNodeId: "peer-a",
            scopeHash: token.scopeHash,
            escrowDeviceId: token.boundEscrowDeviceId,
            attestationHashBlake3: token.attestationHashBlake3,
            issuedAt: token.issuedAt,
            expiresAt: token.expiresAt,
            issuerKeyId: "cap-test"
        )
        let store = RemoteUnlockSessionContextSnapshotStore(path: tempPath, signer: signer)
        try store.save(try signer.sign(snapshot: snapshot, privateKey: privateKey), now: now)

        let provider = RemoteUnlockSessionContextFileProvider(
            path: tempPath,
            now: { now },
            issuerTrustProvider: {
                CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "cap-test")
            }
        )

        let context = provider.context(for: token)
        XCTAssertEqual(context.scopeHash, "scope-a")
        XCTAssertEqual(context.escrowDeviceId, "iphone-a")
        XCTAssertEqual(context.attestationHashBlake3, "attest-a")
    }

    func test_contextProviderIgnoresUnsignedRequestScopeWithoutSnapshot() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = try CapabilityTokenIssuer().mintRemoteUnlockToken(
            privateKey: privateKey,
            scopeHash: "scope-a",
            actionKind: "click"
        )
        let provider = RemoteUnlockSessionContextFileProvider(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-session-context-\(UUID().uuidString).json")
                .path,
            issuerTrustProvider: {
                CapabilityTokenIssuerTrust(publicKey: privateKey.publicKey, keyId: "cap-test")
            }
        )

        XCTAssertEqual(provider.context(for: token), .none)
    }
}

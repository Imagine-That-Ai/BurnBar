#if os(Linux)
import Foundation
import XCTest
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon

private struct TestRemoteReadRouteAuthorizer: LinuxIrohRemoteReadRouteAuthorizing {
    let allowed: Bool

    func authorizesRemoteRead(_ request: LinuxIrohRemoteReadRequest) async -> Bool {
        allowed
    }
}

private struct TestRemoteReadAuthorizer: LinuxIrohRemoteReadAuthorizing {
    let authorization: LinuxIrohRemoteReadAuthorization?

    func authorizeRemoteRead(
        _: LinuxIrohRemoteReadRequest
    ) async throws -> LinuxIrohRemoteReadAuthorization {
        guard let authorization else { throw LinuxIrohRemoteReadError.authorizationUnavailable }
        return authorization
    }
}

private struct TestCredentialEscrowAuthorizer: LinuxIrohCredentialEscrowAuthorizing {
    let authorization: LinuxIrohCredentialEscrowAuthorization?

    func authorizeCredentialEscrow(
        _: LinuxIrohCredentialEscrowRequest
    ) async throws -> LinuxIrohCredentialEscrowAuthorization {
        guard let authorization else { throw LinuxIrohCredentialEscrowError.authorizationUnavailable }
        return authorization
    }
}

final class LinuxIrohRemoteReadCredentialEscrowTests: XCTestCase {
    private let nowMillis: Int64 = 2_000_000_000_000

    func testRemoteReadRequiresLiveRouteBeforeTrustedDeviceApproval() async throws {
        let request = makeRemoteReadRequest()
        let authorization = LinuxIrohRemoteReadAuthorization(
            requestID: request.requestID,
            trustedDeviceID: "ipad-1",
            nonce: "nonce",
            proof: String(repeating: "p", count: 16),
            expiresAtMillis: request.expiresAtMillis
        )
        let readerCalls = ReadCallCounter()
        let bridge = LinuxIrohRemoteReadRPCBridge(
            routeAuthorizer: TestRemoteReadRouteAuthorizer(allowed: false),
            trustedDeviceAuthorizer: TestRemoteReadAuthorizer(authorization: authorization),
            reader: { _ in
                await readerCalls.increment()
                return Data("should-not-read".utf8)
            },
            nowMillis: { self.nowMillis }
        )

        do {
            _ = try await bridge.read(request)
            XCTFail("A stale or unbound route must fail closed")
        } catch let error as LinuxIrohRemoteReadError {
            XCTAssertEqual(error, .routeUnavailable)
        }
        let calls = await readerCalls.value()
        XCTAssertEqual(calls, 0)
    }

    func testRemoteReadRequiresNonceBoundAuthorizationAndReturnsBoundedPayload() async throws {
        let request = makeRemoteReadRequest()
        let authorization = LinuxIrohRemoteReadAuthorization(
            requestID: request.requestID,
            trustedDeviceID: "ipad-1",
            nonce: "nonce",
            proof: String(repeating: "p", count: 16),
            expiresAtMillis: request.expiresAtMillis
        )
        let bridge = LinuxIrohRemoteReadRPCBridge(
            routeAuthorizer: TestRemoteReadRouteAuthorizer(allowed: true),
            trustedDeviceAuthorizer: TestRemoteReadAuthorizer(authorization: authorization),
            reader: { _ in Data("authorized-content".utf8) },
            nowMillis: { self.nowMillis }
        )

        let response = try await bridge.read(request)

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.expiresAtMillis, request.expiresAtMillis)
        XCTAssertEqual(response.payload, Data("authorized-content".utf8))
    }

    func testRemoteReadRejectsAuthorizationForAnotherRequest() async throws {
        let request = makeRemoteReadRequest()
        let authorization = LinuxIrohRemoteReadAuthorization(
            requestID: "different-request",
            trustedDeviceID: "ipad-1",
            nonce: "nonce",
            proof: String(repeating: "p", count: 16),
            expiresAtMillis: request.expiresAtMillis
        )
        let bridge = LinuxIrohRemoteReadRPCBridge(
            routeAuthorizer: TestRemoteReadRouteAuthorizer(allowed: true),
            trustedDeviceAuthorizer: TestRemoteReadAuthorizer(authorization: authorization),
            reader: { _ in Data("should-not-read".utf8) },
            nowMillis: { self.nowMillis }
        )

        do {
            _ = try await bridge.read(request)
            XCTFail("Authorization must be bound to the exact request id")
        } catch let error as LinuxIrohRemoteReadError {
            XCTAssertEqual(error, .authorizationInvalid)
        }
    }

    func testCredentialEscrowEncryptsWithMetadataAADAndNeverReturnsPlaintext() async throws {
        let privateKey = PlatformCrypto.p256KeyAgreementPrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let request = LinuxIrohCredentialEscrowRequest(
            requestID: "request-1",
            grantID: "grant-1",
            targetDeviceID: "ipad-1",
            targetPublicKeyBase64: publicKey.base64EncodedString(),
            targetPublicKeyFingerprint: PlatformCrypto.sha256(publicKey).base64EncodedString(),
            targetKeyVersion: 2,
            providerID: "anthropic",
            slotID: "primary",
            accountLabel: "work@example.com",
            credentialKind: .oauthToken,
            requestedAtMillis: nowMillis,
            expiresAtMillis: nowMillis + 60_000
        )
        let authorization = LinuxIrohCredentialEscrowAuthorization(
            requestID: request.requestID,
            grantID: request.grantID,
            trustedDeviceID: request.targetDeviceID,
            nonce: "nonce",
            proof: String(repeating: "p", count: 16),
            expiresAtMillis: request.expiresAtMillis
        )
        let bridge = LinuxIrohCredentialEscrowBridge(
            sourceIdentityProvider: { "linux-source" },
            credentialSource: { providerID, slotID in
                XCTAssertEqual(providerID, "anthropic")
                XCTAssertEqual(slotID, "primary")
                return "oauth-secret-value"
            },
            trustedDeviceAuthorizer: TestCredentialEscrowAuthorizer(authorization: authorization),
            nowMillis: { self.nowMillis }
        )

        let envelope = try await bridge.createEnvelope(request)

        XCTAssertEqual(envelope.grantId, request.grantID)
        XCTAssertEqual(envelope.sourceDeviceId, "linux-source")
        XCTAssertEqual(envelope.targetDeviceId, request.targetDeviceID)
        XCTAssertEqual(envelope.envelopeVersion, EscrowCredentialMetadataBinding.envelopeVersion)
        XCTAssertFalse(envelope.ciphertext.contains("oauth-secret-value"))
        let ciphertext = try XCTUnwrap(Data(base64Encoded: envelope.ciphertext))
        let binding = EscrowCredentialMetadataBinding(
            grantId: envelope.grantId,
            sourceDeviceId: envelope.sourceDeviceId,
            targetDeviceId: envelope.targetDeviceId,
            providerId: envelope.providerId,
            credentialKind: envelope.credentialKind,
            accountLabel: envelope.accountLabel,
            keyVersion: envelope.keyVersion
        )
        let opened = try CloudVaultCrypto.openEscrowPayload(
            ciphertext,
            privateKey: privateKey,
            authenticating: binding.associatedData
        )
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), "oauth-secret-value")
    }

    func testCredentialEscrowRejectsTargetFingerprintOrApprovalMismatch() async throws {
        let privateKey = PlatformCrypto.p256KeyAgreementPrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let request = LinuxIrohCredentialEscrowRequest(
            requestID: "request-1",
            grantID: "grant-1",
            targetDeviceID: "ipad-1",
            targetPublicKeyBase64: publicKey.base64EncodedString(),
            targetPublicKeyFingerprint: String(repeating: "x", count: 8),
            targetKeyVersion: 1,
            providerID: "openai",
            slotID: "primary",
            credentialKind: .apiKey,
            requestedAtMillis: nowMillis,
            expiresAtMillis: nowMillis + 60_000
        )
        let bridge = LinuxIrohCredentialEscrowBridge(
            sourceIdentityProvider: { "linux-source" },
            credentialSource: { _, _ in "secret" },
            trustedDeviceAuthorizer: TestCredentialEscrowAuthorizer(authorization: nil),
            nowMillis: { self.nowMillis }
        )

        do {
            _ = try await bridge.createEnvelope(request)
            XCTFail("A target-key fingerprint mismatch must fail before authorization")
        } catch let error as LinuxIrohCredentialEscrowError {
            XCTAssertEqual(error, .invalidRequest)
        }
    }

    private func makeRemoteReadRequest() -> LinuxIrohRemoteReadRequest {
        LinuxIrohRemoteReadRequest(
            requestID: "read-1",
            sessionID: "session-1",
            connectionID: "linux-host-1",
            transportPeerNodeID: String(repeating: "a", count: 64),
            authorityPeerNodeID: "ipad-peer",
            routeGeneration: 2,
            domain: "conversations",
            recordID: "thread-1",
            requestedAtMillis: nowMillis,
            expiresAtMillis: nowMillis + 30_000
        )
    }
}

private actor ReadCallCounter {
    private var calls = 0

    func increment() { calls += 1 }
    func value() -> Int { calls }
}
#endif

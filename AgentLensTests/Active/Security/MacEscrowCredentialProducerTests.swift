import CryptoKit
import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// RR-6: Mac→phone escrow PRODUCER must emit envelopes the iOS import path
/// (`LiveCloudReader.loadAvailableEnvelopes` / `LiveEscrowGateway.runImport`)
/// reads byte-for-byte. These tests pin the seal's byte-compat with the import
/// decrypt and the Firestore field shape the import consumes.
@MainActor
final class MacEscrowCredentialProducerTests: XCTestCase {

    // MARK: - Helpers

    /// Decrypts a producer-sealed payload with the recipient private key using
    /// the EXACT construction `iOSDeviceKeypair.decrypt` performs (inlined so the
    /// Mac test target does not need the iOS module): ephemeral pub (65 bytes)
    /// || AES.GCM sealed box, HKDF-SHA256 over the shared secret with an empty
    /// salt and `"OpenBurnBar-Escrow-v1"` info, 32-byte key.
    private func importDecrypt(_ ciphertext: Data, recipientPrivateKey: P256.KeyAgreement.PrivateKey) throws -> Data {
        XCTAssertGreaterThan(ciphertext.count, 65, "ciphertext must carry the 65-byte ephemeral key prefix")
        let ephemeralPubKeyData = ciphertext.prefix(65)
        let sealedBoxData = ciphertext.suffix(from: 65)
        let ephemeralKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPubKeyData)
        let sharedSecret = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: "OpenBurnBar-Escrow-v1".data(using: .utf8)!,
            outputByteCount: 32
        )
        let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    private func recipientKey(_ priv: P256.KeyAgreement.PrivateKey, keyVersion: Int = 1) -> MacEscrowRecipientKey {
        let publicKeyData = priv.publicKey.x963Representation
        let fingerprint = Data(SHA256.hash(data: publicKeyData)).base64EncodedString()
        return MacEscrowRecipientKey(
            deviceId: "iphone-1",
            keyVersion: keyVersion,
            publicKeyData: publicKeyData,
            publicKeyFingerprint: fingerprint
        )
    }

    // MARK: - Seal byte-compat

    func test_seal_roundTripsThroughImportDecrypt() throws {
        let recipientPriv = P256.KeyAgreement.PrivateKey()
        let secret = "sk-ant-api-1234567890abcdef"
        let ciphertext = try MacEscrowSeal.seal(Data(secret.utf8), recipientPublicKey: recipientPriv.publicKey.x963Representation)
        let decrypted = try importDecrypt(ciphertext, recipientPrivateKey: recipientPriv)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), secret)
    }

    func test_seal_prependsEphemeralPublicKey() throws {
        let recipientPriv = P256.KeyAgreement.PrivateKey()
        let ciphertext = try MacEscrowSeal.seal(Data("payload".utf8), recipientPublicKey: recipientPriv.publicKey.x963Representation)
        // First 65 bytes must be a valid X9.63 P-256 public key (0x04 prefix).
        XCTAssertEqual(ciphertext.first, 0x04)
        XCTAssertNoThrow(try P256.KeyAgreement.PublicKey(x963Representation: ciphertext.prefix(65)))
    }

    func test_seal_rejectsInvalidRecipientKey() {
        XCTAssertThrowsError(try MacEscrowSeal.seal(Data("x".utf8), recipientPublicKey: Data([0x00, 0x01]))) { error in
            XCTAssertEqual(error as? MacEscrowProducerError, .invalidRecipientPublicKey)
        }
    }

    func test_seal_isNonDeterministic_freshEphemeralPerCall() throws {
        let recipientPriv = P256.KeyAgreement.PrivateKey()
        let pub = recipientPriv.publicKey.x963Representation
        let a = try MacEscrowSeal.seal(Data("dup".utf8), recipientPublicKey: pub)
        let b = try MacEscrowSeal.seal(Data("dup".utf8), recipientPublicKey: pub)
        XCTAssertNotEqual(a, b, "each seal must use a fresh ephemeral key + nonce")
        XCTAssertEqual(try importDecrypt(a, recipientPrivateKey: recipientPriv), try importDecrypt(b, recipientPrivateKey: recipientPriv))
    }

    // MARK: - Envelope shape

    func test_buildEnvelopePlan_matchesImportExpectations() throws {
        let recipientPriv = P256.KeyAgreement.PrivateKey()
        let recipient = recipientKey(recipientPriv, keyVersion: 3)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try MacEscrowCredentialProducer.buildEnvelopePlan(
            provider: .minimax,
            credential: MacEscrowCredentialSecret(secret: "secret-token", credentialKind: .apiKey, accountLabel: "primary"),
            sourceDeviceID: "mac-1",
            recipient: recipient,
            grantId: "grant-1",
            envelopeId: "env-1",
            createdAt: createdAt
        )

        // Grant doc — keyed/filtered by loadAvailableEnvelopes via the doc id.
        XCTAssertEqual(plan.grant["sourceDeviceId"] as? String, "mac-1")
        XCTAssertEqual(plan.grant["targetDeviceId"] as? String, "iphone-1")
        XCTAssertEqual(plan.grant["providerId"] as? String, AgentProvider.minimax.persistedToken)
        XCTAssertEqual(plan.grant["status"] as? String, EscrowGrantStatus.granted.rawValue)
        XCTAssertEqual(plan.grant["credentialKind"] as? String, EscrowCredentialKind.apiKey.rawValue)

        // Envelope doc — the import reads these exact fields.
        let envelope = plan.envelope
        XCTAssertEqual(envelope["grantId"] as? String, "grant-1")
        XCTAssertEqual(envelope["targetDeviceId"] as? String, "iphone-1")
        XCTAssertEqual(envelope["sourceDeviceId"] as? String, "mac-1")
        XCTAssertEqual(envelope["providerId"] as? String, AgentProvider.minimax.persistedToken)
        XCTAssertEqual(envelope["credentialKind"] as? String, EscrowCredentialKind.apiKey.rawValue)
        XCTAssertEqual(envelope["accountLabel"] as? String, "primary")
        XCTAssertEqual(envelope["keyVersion"] as? Int, 3)
        XCTAssertEqual(envelope["envelopeVersion"] as? Int, 1)
        XCTAssertNotNil(envelope["ciphertext"] as? String)
        XCTAssertNotNil(envelope["createdAt"])

        // The ciphertext must decrypt to the original secret on the phone.
        let ctB64 = try XCTUnwrap(envelope["ciphertext"] as? String)
        let ct = try XCTUnwrap(Data(base64Encoded: ctB64))
        let plain = try importDecrypt(ct, recipientPrivateKey: recipientPriv)
        XCTAssertEqual(String(data: plain, encoding: .utf8), "secret-token")
    }

    func test_buildEnvelopePlan_defaultsAccountLabelToDisplayName() throws {
        let recipient = recipientKey(P256.KeyAgreement.PrivateKey())
        let plan = try MacEscrowCredentialProducer.buildEnvelopePlan(
            provider: .claudeCode,
            credential: MacEscrowCredentialSecret(secret: "oauth-token", credentialKind: .oauthToken, accountLabel: nil),
            sourceDeviceID: "mac-1",
            recipient: recipient,
            grantId: "g",
            envelopeId: "e",
            createdAt: Date()
        )
        XCTAssertEqual(plan.envelope["accountLabel"] as? String, AgentProvider.claudeCode.displayName)
        XCTAssertEqual(plan.envelope["credentialKind"] as? String, EscrowCredentialKind.oauthToken.rawValue)
    }

    // MARK: - Producer orchestration / fail-closed

    func test_startExport_emitsHonestStagesAndWritesOnce() async throws {
        let recipientPriv = P256.KeyAgreement.PrivateKey()
        let resolver = StubRecipientKeyResolver(result: .success(recipientKey(recipientPriv)))
        let reader = StubSecretReader(secret: MacEscrowCredentialSecret(secret: "tok", credentialKind: .apiKey, accountLabel: "primary"))
        let writer = SpyEnvelopeWriter()
        let producer = MacEscrowCredentialProducer(
            sourceDeviceID: "mac-1",
            recipientKeyResolver: resolver,
            secretReader: reader,
            writer: writer,
            grantIdFactory: { "grant-1" },
            envelopeIdFactory: { "env-1" },
            now: { Date(timeIntervalSince1970: 1) }
        )

        var stages: [MacExportStage] = []
        await producer.startExport(uid: "uid-1", provider: .minimax, destinationDeviceID: "iphone-1") { stages.append($0) }

        XCTAssertEqual(stages, [.encrypting, .uploading, .done])
        XCTAssertEqual(writer.writtenPlans.count, 1)
        XCTAssertEqual(writer.writtenPlans.first?.grantId, "grant-1")
        XCTAssertEqual(writer.writtenPlans.first?.envelopeId, "env-1")
    }

    func test_startExport_failsClosedWhenNoSecret() async {
        let writer = SpyEnvelopeWriter()
        let producer = MacEscrowCredentialProducer(
            sourceDeviceID: "mac-1",
            recipientKeyResolver: StubRecipientKeyResolver(result: .success(recipientKey(P256.KeyAgreement.PrivateKey()))),
            secretReader: StubSecretReader(secret: nil),
            writer: writer
        )
        var stages: [MacExportStage] = []
        await producer.startExport(uid: "uid-1", provider: .minimax, destinationDeviceID: "iphone-1") { stages.append($0) }

        guard case .failed(let message) = stages.last else {
            return XCTFail("Expected fail-closed, got \(stages)")
        }
        XCTAssertTrue(message.contains("No transferable"))
        XCTAssertTrue(writer.writtenPlans.isEmpty, "no envelope must be written when no credential is read")
    }

    func test_startExport_failsClosedWhenNotAuthenticated() async {
        let writer = SpyEnvelopeWriter()
        let producer = MacEscrowCredentialProducer(
            sourceDeviceID: "mac-1",
            recipientKeyResolver: StubRecipientKeyResolver(result: .success(recipientKey(P256.KeyAgreement.PrivateKey()))),
            secretReader: StubSecretReader(secret: MacEscrowCredentialSecret(secret: "tok", credentialKind: .apiKey, accountLabel: nil)),
            writer: writer
        )
        var stages: [MacExportStage] = []
        await producer.startExport(uid: nil, provider: .minimax, destinationDeviceID: "iphone-1") { stages.append($0) }
        if case .failed = stages.last {} else { XCTFail("Expected failure for nil uid") }
        XCTAssertTrue(writer.writtenPlans.isEmpty)
    }

    func test_startExport_failsClosedWhenRecipientUnresolved() async {
        let writer = SpyEnvelopeWriter()
        let producer = MacEscrowCredentialProducer(
            sourceDeviceID: "mac-1",
            recipientKeyResolver: StubRecipientKeyResolver(result: .failure(MacEscrowProducerError.recipientKeyUntrusted(deviceId: "iphone-1"))),
            secretReader: StubSecretReader(secret: MacEscrowCredentialSecret(secret: "tok", credentialKind: .apiKey, accountLabel: nil)),
            writer: writer
        )
        var stages: [MacExportStage] = []
        await producer.startExport(uid: "uid-1", provider: .minimax, destinationDeviceID: "iphone-1") { stages.append($0) }
        // encrypting is emitted before recipient resolution fails; never uploads.
        XCTAssertEqual(stages.first, .encrypting)
        if case .failed = stages.last {} else { XCTFail("Expected failure on recipient resolve") }
        XCTAssertTrue(writer.writtenPlans.isEmpty)
    }

    func test_startExport_failsClosedWhenDestinationPlaceholder() async {
        let writer = SpyEnvelopeWriter()
        let producer = MacEscrowCredentialProducer(
            sourceDeviceID: "mac-1",
            recipientKeyResolver: StubRecipientKeyResolver(result: .success(recipientKey(P256.KeyAgreement.PrivateKey()))),
            secretReader: StubSecretReader(secret: MacEscrowCredentialSecret(secret: "tok", credentialKind: .apiKey, accountLabel: nil)),
            writer: writer
        )
        var stages: [MacExportStage] = []
        await producer.startExport(uid: "uid-1", provider: .minimax, destinationDeviceID: "pending-device") { stages.append($0) }
        if case .failed = stages.last {} else { XCTFail("Expected failure for placeholder destination") }
        XCTAssertTrue(writer.writtenPlans.isEmpty)
    }
}

// MARK: - Test doubles

@MainActor
private final class StubRecipientKeyResolver: MacEscrowRecipientKeyResolver {
    let result: Result<MacEscrowRecipientKey, Error>
    init(result: Result<MacEscrowRecipientKey, Error>) { self.result = result }
    func recipientKey(uid: String, destinationDeviceID: String) async throws -> MacEscrowRecipientKey {
        try result.get()
    }
}

@MainActor
private final class StubSecretReader: MacEscrowCredentialSecretReader {
    let secret: MacEscrowCredentialSecret?
    init(secret: MacEscrowCredentialSecret?) { self.secret = secret }
    func credentialSecret(for provider: AgentProvider) async -> MacEscrowCredentialSecret? { secret }
}

@MainActor
private final class SpyEnvelopeWriter: MacEscrowEnvelopeWriter {
    private(set) var writtenPlans: [MacEscrowEnvelopePlan] = []
    func write(uid: String, plan: MacEscrowEnvelopePlan) async throws {
        writtenPlans.append(plan)
    }
}

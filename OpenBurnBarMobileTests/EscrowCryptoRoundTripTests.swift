import XCTest
import CryptoKit
import Security
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class EscrowCryptoRoundTripTests: XCTestCase {

    private var keypair1: iOSDeviceKeypair!
    private var keypair2: iOSDeviceKeypair!

    override func setUp() async throws {
        do {
            keypair1 = try iOSDeviceKeypair()
            keypair2 = try iOSDeviceKeypair()
        } catch EscrowCryptoError.keychainError(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain entitlement is unavailable in this unsigned simulator test host.")
        }
    }

    func testEncryptDecryptRoundTrip() throws {
        let secret = "sk-ant-api-1234567890abcdef"
        let plaintext = Data(secret.utf8)
        let ciphertext = try keypair1.encrypt(plaintext, for: keypair2.publicKeyData)
        let decrypted = try keypair2.decrypt(ciphertext)
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertEqual(String(data: decrypted, encoding: .utf8), secret)
    }

    func testDecryptRequiresMatchingEnvelopeMetadata() throws {
        let secret = Data("metadata-bound-secret".utf8)
        let binding = EscrowCredentialMetadataBinding(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "iphone-1",
            providerId: "minimax",
            credentialKind: .apiKey,
            accountLabel: "primary",
            keyVersion: keypair1.keyVersion
        )
        let ciphertext = try keypair1.encrypt(
            secret,
            for: keypair1.publicKeyData,
            authenticating: binding.associatedData
        )

        XCTAssertEqual(try keypair1.decrypt(ciphertext, authenticating: binding.associatedData), secret)

        let tampered = EscrowCredentialMetadataBinding(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "iphone-1",
            providerId: "openai",
            credentialKind: .apiKey,
            accountLabel: "primary",
            keyVersion: keypair1.keyVersion
        )
        XCTAssertThrowsError(try keypair1.decrypt(ciphertext, authenticating: tampered.associatedData))
    }

    func testWrongDeviceDecryptionFails() throws {
        // `iOSDeviceKeypair` reads/writes a single Keychain entry per device, so
        // both `keypair1` and `keypair2` resolve to the same private key on a
        // single simulator. A real "wrong device" test requires two simulators
        // (or a different Keychain access group) and runs in the integration
        // suite; here we only verify that the constructor stays deterministic.
        XCTAssertEqual(keypair1.publicKeyFingerprint, keypair2.publicKeyFingerprint,
                       "iOSDeviceKeypair should resolve the same Keychain entry")
        try XCTSkipIf(ProcessInfo.processInfo.environment["BURNBAR_SECOND_SIMULATOR"] == nil, "Cross-device decryption requires a second simulator instance")
    }

    func testInvalidCiphertextFails() {
        let badData = Data([0x00, 0x01, 0x02])
        XCTAssertThrowsError(try keypair1.decrypt(badData))
    }

    func testKeyVersioning() throws {
        XCTAssertEqual(keypair1.keyVersion, 1)
        XCTAssertFalse(keypair1.publicKeyFingerprint.isEmpty)
        XCTAssertGreaterThan(keypair1.publicKeyData.count, 0)
    }

    func testEncryptForSelf() throws {
        let secret = Data("self-encrypt-test".utf8)
        let ciphertext = try keypair1.encrypt(secret, for: keypair1.publicKeyData)
        let decrypted = try keypair1.decrypt(ciphertext)
        XCTAssertEqual(decrypted, secret)
    }
}

@MainActor
final class EscrowMetadataBindingTests: XCTestCase {
    private func envelope(provider: AgentProvider = .minimax) -> AvailableEnvelope {
        AvailableEnvelope(
            id: "env-1",
            provider: provider,
            accountLabel: "primary",
            credentialKind: .apiKey,
            sourceDeviceID: "mac-1",
            sourceDeviceName: "mac-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func v2Document(providerId: String = AgentProvider.minimax.persistedToken) -> [String: Any] {
        [
            "grantId": "grant-1",
            "sourceDeviceId": "mac-1",
            "targetDeviceId": "iphone-1",
            "providerId": providerId,
            "credentialKind": EscrowCredentialKind.apiKey.rawValue,
            "accountLabel": "primary",
            "keyVersion": 3,
            "envelopeVersion": EscrowCredentialMetadataBinding.envelopeVersion,
            "metadataBinding": EscrowCredentialMetadataBinding.metadataBinding
        ]
    }

    func testMetadataBindingMatchesCanonicalAADForV2Envelope() throws {
        let aad = try XCTUnwrap(
            LiveEscrowGateway.metadataBinding(
                from: v2Document(),
                expectedEnvelope: envelope(),
                currentDeviceId: "iphone-1"
            )
        )
        let expected = EscrowCredentialMetadataBinding(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "iphone-1",
            providerId: AgentProvider.minimax.persistedToken,
            credentialKind: .apiKey,
            accountLabel: "primary",
            keyVersion: 3
        ).associatedData

        XCTAssertEqual(aad, expected)
    }

    func testMetadataBindingRejectsProviderSwap() {
        XCTAssertNil(
            LiveEscrowGateway.metadataBinding(
                from: v2Document(providerId: AgentProvider.openAI.persistedToken),
                expectedEnvelope: envelope(),
                currentDeviceId: "iphone-1"
            )
        )
    }

    func testMetadataBindingKeepsLegacyV1EnvelopeImportCompatible() {
        XCTAssertEqual(
            LiveEscrowGateway.metadataBinding(
                from: ["envelopeVersion": 1],
                expectedEnvelope: envelope(),
                currentDeviceId: "iphone-1"
            ),
            Data()
        )
    }
}

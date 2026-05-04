import XCTest
import OpenBurnBarCore

/// Verifies that escrow envelope serialization never contains plaintext secret field names.
final class FirestorePlaintextProhibitionTests: XCTestCase {

    /// Forbidden field names that must never appear as keys in Firestore-bound JSON.
    private let forbiddenFields = Set([
        "apiKey", "token", "refreshToken", "accessToken", "idToken",
        "cookie", "password", "secret", "secretVersionName", "authorization", "bearer", "credential"
    ])

    func testEscrowEnvelopeContainsNoPlaintextSecretFields() throws {
        let envelope = EscrowSecretEnvelope(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "ios-1",
            providerId: "claudecode",
            credentialKind: .apiKey,
            accountLabel: "Work",
            ciphertext: "YWJjMTIz" // base64 of random data
        )
        let data = try JSONEncoder().encode(envelope)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(dict)

        let keys: Set<String> = Set(dict?.keys.map { String($0) } ?? [])
        let violations = keys.intersection(forbiddenFields)
        XCTAssertTrue(violations.isEmpty, "EscrowEnvelope contains forbidden field names: \(violations)")
    }

    func testEscrowSecretMetadataContainsNoPlaintextSecrets() throws {
        let meta = EscrowSecretMetadata(
            providerId: "claudecode",
            accountLabel: "Work",
            credentialKind: .apiKey,
            sourceDeviceId: "mac-1",
            destinationDeviceId: "ios-1"
        )
        let data = try JSONEncoder().encode(meta)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(dict)

        let keys: Set<String> = Set(dict?.keys.map { String($0) } ?? [])
        let violations = keys.intersection(forbiddenFields)
        XCTAssertTrue(violations.isEmpty, "EscrowSecretMetadata contains forbidden field names: \(violations)")
    }

    func testAllEscrowModelsAreSecretsFree() throws {
        let models: [any Encodable] = [
            EscrowDevice(deviceId: "d1", deviceName: "test", platform: "iOS"),
            EscrowPublicKey(deviceId: "d1", publicKeyData: "base64key"),
            EscrowGrant(sourceDeviceId: "s1", targetDeviceId: "t1", providerId: "p1", credentialKind: .apiKey),
            EscrowSecretMetadata(providerId: "p1", credentialKind: .bearerToken, sourceDeviceId: "s1", destinationDeviceId: "d1"),
            EscrowAuditEvent(eventType: .envelopeCreated, actorDeviceId: "a1")
        ]

        for model in models {
            let data = try JSONEncoder().encode(model)
            let json = String(data: data, encoding: .utf8) ?? ""
            // Verify NO raw API key patterns appear
            XCTAssertFalse(json.contains("sk-ant-"), "Model contains API key pattern")
            XCTAssertFalse(json.contains("Bearer "), "Model contains Bearer token")
        }
    }

    func testCiphertextFieldIsBase64Encoded() throws {
        let plaintext = "This is a real API key: sk-ant-api03-xxxxx"
        // Verify that when we create an envelope, the raw text goes into ciphertext as base64
        let envelope = EscrowSecretEnvelope(
            grantId: "g1",
            sourceDeviceId: "s1",
            targetDeviceId: "t1",
            providerId: "p1",
            ciphertext: Data(plaintext.utf8).base64EncodedString()
        )
        let data = try JSONEncoder().encode(envelope)
        let json = String(data: data, encoding: .utf8) ?? ""

        // The raw API key should NOT appear in the JSON
        XCTAssertFalse(json.contains("sk-ant-api03-xxxxx"),
                       "Raw API key appeared in serialized envelope JSON")
        // But the base64-encoded version should
        XCTAssertTrue(json.contains(Data(plaintext.utf8).base64EncodedString()),
                      "Ciphertext field missing base64 payload")
    }
}

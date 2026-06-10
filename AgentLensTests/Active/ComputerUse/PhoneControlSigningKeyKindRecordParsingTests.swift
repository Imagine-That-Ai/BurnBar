#if canImport(AppKit)
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// F2 — the two Firestore record readers that resolve a controller's
/// `signingKeyKind` into a key-custody class must agree on the rule:
/// absent ⇒ legacy Ed25519; present-but-unrecognized fails CLOSED (a record
/// claiming a stronger key is never silently downgraded); and the raw key
/// bytes must match the declared class (32-byte raw Ed25519 vs 65-byte
/// X9.63 SE-P256).
final class PhoneControlSigningKeyKindRecordParsingTests: XCTestCase {
    private let ed25519Raw = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    private let seP256Raw = P256.Signing.PrivateKey().publicKey.x963Representation

    // MARK: - FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind

    func test_providerAbsentKindDefaultsToLegacyEd25519() throws {
        XCTAssertEqual(
            try FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind(
                signingKeyKindRaw: nil,
                publicKeyRaw: ed25519Raw
            ),
            .ed25519
        )
    }

    func test_providerParsesBothDeclaredKinds() throws {
        XCTAssertEqual(
            try FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind(
                signingKeyKindRaw: "ed25519",
                publicKeyRaw: ed25519Raw
            ),
            .ed25519
        )
        XCTAssertEqual(
            try FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind(
                signingKeyKindRaw: "se-p256",
                publicKeyRaw: seP256Raw
            ),
            .secureEnclaveP256
        )
        XCTAssertEqual(ed25519Raw.count, 32)
        XCTAssertEqual(seP256Raw.count, 65)
    }

    func test_providerUnrecognizedKindFailsClosedInsteadOfDowngrading() {
        XCTAssertThrowsError(
            try FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind(
                signingKeyKindRaw: "se-p384",
                publicKeyRaw: seP256Raw
            )
        ) { error in
            XCTAssertEqual(error as? PhoneControlAuthorityProviderError, .malformed)
        }
    }

    func test_providerKeyLengthMustMatchDeclaredClass() {
        // A 65-byte key claiming the legacy class (or vice versa) is malformed —
        // this is the wire shape of a key-kind swap attack.
        XCTAssertThrowsError(
            try FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind(
                signingKeyKindRaw: "ed25519",
                publicKeyRaw: seP256Raw
            )
        )
        XCTAssertThrowsError(
            try FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind(
                signingKeyKindRaw: "se-p256",
                publicKeyRaw: ed25519Raw
            )
        )
        XCTAssertThrowsError(
            try FirestorePhoneControlAuthorityProvider.validatedSigningKeyKind(
                signingKeyKindRaw: nil,
                publicKeyRaw: Data(repeating: 1, count: 31)
            )
        )
    }

    // MARK: - AgentCapabilityGrantQueueListener.signingKeyKind

    func test_queueListenerAbsentKindDefaultsToLegacyEd25519() throws {
        XCTAssertEqual(try AgentCapabilityGrantQueueListener.signingKeyKind(fromRecordValue: nil), .ed25519)
    }

    func test_queueListenerParsesBothDeclaredKinds() throws {
        XCTAssertEqual(
            try AgentCapabilityGrantQueueListener.signingKeyKind(fromRecordValue: "ed25519"),
            .ed25519
        )
        XCTAssertEqual(
            try AgentCapabilityGrantQueueListener.signingKeyKind(fromRecordValue: "se-p256"),
            .secureEnclaveP256
        )
    }

    func test_queueListenerUnrecognizedKindFailsClosed() {
        XCTAssertThrowsError(
            try AgentCapabilityGrantQueueListener.signingKeyKind(fromRecordValue: "rsa-2048")
        ) { error in
            guard case AgentCapabilityGrantQueueListener.QueueError.missingAuthority = error else {
                return XCTFail("Expected missingAuthority, got \(error)")
            }
        }
    }
}
#endif

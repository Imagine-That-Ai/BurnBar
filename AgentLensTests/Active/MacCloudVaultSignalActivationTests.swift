import FirebaseFirestore
import Foundation
import XCTest
@testable import OpenBurnBar

final class MacCloudVaultSignalActivationTests: XCTestCase {
    func test_activationPolicy_isOffWithoutSchemeOrEnablement() {
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: false,
                enabled: true,
                required: true,
                hardKill: false
            ),
            .off
        )
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: false,
                required: true,
                hardKill: false
            ),
            .off
        )
    }

    func test_activationPolicy_distinguishesEnabledFromRequired() {
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: true,
                required: false,
                hardKill: false
            ),
            .enabled
        )
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: true,
                required: true,
                hardKill: false
            ),
            .required
        )
    }

    func test_activationPolicy_hardKillOverridesRequiredMode() {
        XCTAssertEqual(
            MacCloudVaultSignalPayloads.activationState(
                hasSignalScheme: true,
                enabled: true,
                required: true,
                hardKill: true
            ),
            .off
        )
    }

    func test_applyingSignalEnvelope_doesNotResolveFirestoreWhenSignalIsOff() async throws {
        let payload = try await MacCloudVaultSignalPayloads.applyingSignalEnvelope(
            to: ["id": "doc-1"],
            domainID: "conversations_chat",
            uid: "uid-1",
            firestore: Firestore.firestore(),
            collection: "conversations",
            docId: "doc-1",
            plaintext: Data("plaintext".utf8),
            resolvedKey: CloudVaultResolvedKey(
                keyData: Data(repeating: 0x11, count: 32),
                vaultKeyID: "key-1"
            ),
            legacyPrivateFields: ["sealedPayload"],
            mergeWrite: true
        )

        XCTAssertEqual(payload["id"] as? String, "doc-1")
        XCTAssertTrue(payload["signalEnvelope"] is FieldValue)
    }
}

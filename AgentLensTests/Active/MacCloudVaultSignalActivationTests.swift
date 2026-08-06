import FirebaseFirestore
import XCTest
@testable import OpenBurnBar

final class MacCloudVaultSignalActivationTests: XCTestCase {
    private struct FirestoreResolvedWhileGateOff: Error {}

    /// Regression guard for the App PR Gate failure on run 30972808776: the write-path
    /// sync services pass `Firestore.firestore()` to `applyingSignalEnvelope`, and
    /// `Firestore.firestore()` raises FIRIllegalStateException whenever FirebaseApp is
    /// not configured (the unit lane has no GoogleService-Info.plist). The `firestore`
    /// parameter is an @autoclosure precisely so the instance is only resolved after
    /// the activation gate says the domain's Signal seal path is ON.
    func test_applyingSignalEnvelope_gateOff_neverResolvesFirestore() async throws {
        let resolvedKey = try TestConversationVaultKeyProvider().resolvedKey()

        let payload = try await MacCloudVaultSignalPayloads.applyingSignalEnvelope(
            to: ["title": "t", "sealedPayload": "legacy-seal"],
            domainID: "conversations_chat",
            uid: "test-uid-1",
            firestore: try Self.failResolution(),
            collection: "conversations",
            docId: "device-1_conv-1",
            plaintext: Data("plaintext".utf8),
            resolvedKey: resolvedKey,
            legacyPrivateFields: ["sealedPayload"],
            mergeWrite: true
        )

        // Gate OFF: the legacy payload survives untouched and the envelope field is
        // cleared with a merge-write delete marker.
        XCTAssertEqual(payload["title"] as? String, "t")
        XCTAssertEqual(payload["sealedPayload"] as? String, "legacy-seal")
        XCTAssertTrue(payload["signalEnvelope"] is FieldValue)
    }

    private static func failResolution() throws -> Firestore {
        // Evaluating the autoclosure at all is the regression: with an unconfigured
        // FirebaseApp the real `Firestore.firestore()` would raise, so the lazy gate
        // must return before ever resolving the instance.
        XCTFail("applyingSignalEnvelope resolved Firestore while the Signal gate is OFF")
        throw FirestoreResolvedWhileGateOff()
    }
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

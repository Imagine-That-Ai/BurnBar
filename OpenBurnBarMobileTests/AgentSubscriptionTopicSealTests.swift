import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Verifies the privacy-leak remediation for `subscription_topics`: the
/// per-agent display text (`displayName` / `description`, which echoes which
/// agent the user follows) is SEALED with the vault key before it touches
/// Firestore (`sealedDisplayName` / `sealedDescription`). `agentURI` / `topicID`
/// stay plaintext (routing / doc-ID key). The reader keeps a legacy plaintext
/// fallback so pre-migration documents still render.
@MainActor
final class AgentSubscriptionTopicSealTests: XCTestCase {

    private func makeTopic() -> SubscriptionTopic {
        SubscriptionTopic(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            displayName: "Research Scout updates",
            description: "Weekly digest from the Research Scout agent.",
            cadence: .weekly,
            consentGivenAt: Date(),
            isMuted: false,
            deliveryMode: .actionOnly,
            minimumEventImportance: .actionRequired,
            deliveryCountThisMonth: 0,
            lastDeliveredAt: nil
        )
    }

    func test_encodeTopic_sealsDisplayText_writesNoPlaintext() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let encoded = try AgentSubscriptionTopicStore.encodeTopic(makeTopic(), vaultKey: key)

        // Display text is sealed; no plaintext leaks.
        XCTAssertNotNil(encoded["sealedDisplayName"])
        XCTAssertNotNil(encoded["sealedDescription"])
        XCTAssertNil(encoded["displayName"])
        XCTAssertNil(encoded["description"])

        // Routing identifiers stay plaintext-functional.
        XCTAssertEqual(encoded["agentURI"] as? String, "agent://burnbar/research-scout")
        XCTAssertEqual(encoded["topicID"] as? String, "agent-updates")

        // Canonical sealed-text envelope shape.
        let sealed = try XCTUnwrap(encoded["sealedDisplayName"] as? [String: Any])
        XCTAssertEqual(sealed["algorithm"] as? String, CloudVaultCrypto.aesGCMAlgorithm)
        XCTAssertNotNil(sealed["nonce"])
        XCTAssertNotNil(sealed["ciphertext"])
        XCTAssertNotNil(sealed["tag"])
    }

    func test_encodeTopic_thenDecodeTopic_roundTrips() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let topic = makeTopic()
        let encoded = try AgentSubscriptionTopicStore.encodeTopic(topic, vaultKey: key)

        let decoded = try XCTUnwrap(
            AgentSubscriptionTopicStore.decodeTopic(documentID: "doc-1", data: encoded, vaultKey: key)
        )
        XCTAssertEqual(decoded.displayName, "Research Scout updates")
        XCTAssertEqual(decoded.description, "Weekly digest from the Research Scout agent.")
        XCTAssertEqual(decoded.agentURI, "agent://burnbar/research-scout")
        XCTAssertEqual(decoded.topicID, "agent-updates")
    }

    func test_decodeTopic_legacyPlaintext_stillDecodes() throws {
        let legacy: [String: Any] = [
            "agentURI": "agent://burnbar/research-scout",
            "topicID": "agent-updates",
            "displayName": "Legacy display",
            "description": "Legacy description",
            "cadence": "weekly"
        ]
        let decoded = try XCTUnwrap(
            AgentSubscriptionTopicStore.decodeTopic(documentID: "doc-legacy", data: legacy, vaultKey: nil)
        )
        XCTAssertEqual(decoded.displayName, "Legacy display")
        XCTAssertEqual(decoded.description, "Legacy description")
    }

    func test_decodeTopic_sealedDisplayUnreadableWithoutKey_fallsBackToDocumentID() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let encoded = try AgentSubscriptionTopicStore.encodeTopic(makeTopic(), vaultKey: key)

        // Without the key (and no legacy plaintext), the sealed display name is
        // empty, so the existing `displayName.isEmpty ? documentID` fallback
        // renders the doc ID instead of leaking — and the row still decodes.
        let decoded = try XCTUnwrap(
            AgentSubscriptionTopicStore.decodeTopic(documentID: "doc-id-fallback", data: encoded, vaultKey: nil)
        )
        XCTAssertEqual(decoded.displayName, "doc-id-fallback")
        XCTAssertEqual(decoded.description, "")
        // Routing identifiers remain readable (they were never sealed).
        XCTAssertEqual(decoded.agentURI, "agent://burnbar/research-scout")
    }
}

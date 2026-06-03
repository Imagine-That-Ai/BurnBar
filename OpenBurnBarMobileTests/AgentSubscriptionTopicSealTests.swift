import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Verifies the subscription-graph cloak for `subscription_topics`: not only is
/// the per-agent display text sealed, the GRAPH EDGE itself (`agentURI` /
/// `topicID`, which tells the server exactly which agents the user follows) is
/// sealed (`sealedAgentURI` / `sealedTopicID`) and the Firestore doc id is an
/// opaque vault-keyed HMAC (`CloudVaultCrypto.subscriptionDocID`) instead of the
/// human-readable `agentURI:topicID`. The reader keeps a legacy plaintext
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

    func test_encodeTopic_sealsGraphAndDisplay_writesNoPlaintext() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let encoded = try AgentSubscriptionTopicStore.encodeTopic(makeTopic(), vaultKey: key)

        // The graph edge AND the display text are sealed; no plaintext leaks.
        XCTAssertNotNil(encoded["sealedAgentURI"])
        XCTAssertNotNil(encoded["sealedTopicID"])
        XCTAssertNotNil(encoded["sealedDisplayName"])
        XCTAssertNotNil(encoded["sealedDescription"])
        XCTAssertNil(encoded["agentURI"])
        XCTAssertNil(encoded["topicID"])
        XCTAssertNil(encoded["displayName"])
        XCTAssertNil(encoded["description"])

        // Server-side order/filter inputs stay cleartext (no graph identity).
        XCTAssertEqual(encoded["cadence"] as? String, "weekly")
        XCTAssertNotNil(encoded["consentGivenAt"])

        // Canonical sealed-text envelope shape on the graph edge.
        let sealed = try XCTUnwrap(encoded["sealedAgentURI"] as? [String: Any])
        XCTAssertEqual(sealed["algorithm"] as? String, CloudVaultCrypto.aesGCMAlgorithm)
        XCTAssertNotNil(sealed["nonce"])
        XCTAssertNotNil(sealed["ciphertext"])
        XCTAssertNotNil(sealed["tag"])
    }

    func test_documentID_isOpaque_deterministic_keyVarying() throws {
        let keyA = CloudVaultCrypto.generateVaultKey()
        let keyB = CloudVaultCrypto.generateVaultKey()

        let idA1 = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            vaultKey: keyA
        )
        let idA2 = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            vaultKey: keyA
        )
        let idB = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            vaultKey: keyB
        )

        // Deterministic for the same (agentURI, topicID, key) — unsubscribe-by-id
        // and upsert idempotency survive.
        XCTAssertEqual(idA1, idA2)
        // Different vault key → unrelated id.
        XCTAssertNotEqual(idA1, idB)
        // Opaque: it reveals nothing about the agent the user follows.
        XCTAssertTrue(idA1.hasPrefix("sub_"))
        XCTAssertFalse(idA1.contains("research-scout"))
        XCTAssertFalse(idA1.contains("burnbar"))
    }

    func test_documentID_matchesCrossPlatformGoldenVector() throws {
        // Locked interop vector — the IDENTICAL assertion guards the Android
        // `AgentSubscriptionTopicStore.documentID` test. HKDF<SHA256>(0x5A*32,
        // salt: ∅, info: "subscription-topic") → HMAC<SHA256>(
        // "agent://burnbar/research-scout:agent-updates"), first 16 bytes hex.
        let key = Data(repeating: 0x5A, count: 32)
        let id = try CloudVaultCrypto.subscriptionDocID(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            keyData: key
        )
        XCTAssertEqual(id, "sub_64ad3397dff90692866fcdaf93e3c028")

        // Same id reached through the store wrapper (call-site parity).
        let viaStore = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            vaultKey: key
        )
        XCTAssertEqual(viaStore, "sub_64ad3397dff90692866fcdaf93e3c028")
    }

    func test_documentID_distinctPerTopicAndAgent() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let scout = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/research-scout", topicID: "agent-updates", vaultKey: key
        )
        let other = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/other-agent", topicID: "agent-updates", vaultKey: key
        )
        let otherTopic = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/research-scout", topicID: "weekly-roundup", vaultKey: key
        )
        XCTAssertNotEqual(scout, other)
        XCTAssertNotEqual(scout, otherTopic)
    }

    func test_legacyCleartextDocumentIDs_coverKnownPreCloakVariants() {
        let ids = AgentSubscriptionTopicStore.legacyCleartextDocumentIDs(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates"
        )
        XCTAssertTrue(ids.contains("agent:__burnbar_research-scout:agent-updates"))
        XCTAssertTrue(ids.contains("agent___burnbar_research-scout_agent-updates"))
        XCTAssertTrue(ids.contains("agent_burnbar_research-scout_agent-updates"))
        XCTAssertFalse(ids.contains { $0.contains("/") })
    }

    func test_encodeTopic_thenDecodeTopic_roundTrips() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let topic = makeTopic()
        let encoded = try AgentSubscriptionTopicStore.encodeTopic(topic, vaultKey: key)
        let docID = try AgentSubscriptionTopicStore.documentID(
            agentURI: topic.agentURI, topicID: topic.topicID, vaultKey: key
        )

        let decoded = try XCTUnwrap(
            AgentSubscriptionTopicStore.decodeTopic(documentID: docID, data: encoded, vaultKey: key)
        )
        XCTAssertEqual(decoded.displayName, "Research Scout updates")
        XCTAssertEqual(decoded.description, "Weekly digest from the Research Scout agent.")
        XCTAssertEqual(decoded.agentURI, "agent://burnbar/research-scout")
        XCTAssertEqual(decoded.topicID, "agent-updates")
    }

    func test_decodeTopic_legacyPlaintext_stillDecodes() throws {
        // Pre-migration doc: plaintext graph edge + plaintext display, no sealed
        // fields. The legacy fallback must still surface it.
        let legacy: [String: Any] = [
            "agentURI": "agent://burnbar/research-scout",
            "topicID": "agent-updates",
            "displayName": "Legacy display",
            "description": "Legacy description",
            "cadence": "weekly"
        ]
        let decoded = try XCTUnwrap(
            AgentSubscriptionTopicStore.decodeTopic(documentID: "agent_burnbar_research-scout_agent-updates", data: legacy, vaultKey: nil)
        )
        XCTAssertEqual(decoded.agentURI, "agent://burnbar/research-scout")
        XCTAssertEqual(decoded.topicID, "agent-updates")
        XCTAssertEqual(decoded.displayName, "Legacy display")
        XCTAssertEqual(decoded.description, "Legacy description")
    }

    func test_decodeTopic_sealedGraphUnreadableWithoutKey_returnsNil() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let encoded = try AgentSubscriptionTopicStore.encodeTopic(makeTopic(), vaultKey: key)

        // Without the key (and no legacy plaintext graph edge), the sealed
        // `agentURI`/`topicID` cannot open, so the row decodes to nil rather than
        // leaking the opaque doc id — the graph stays invisible.
        let decoded = AgentSubscriptionTopicStore.decodeTopic(
            documentID: "sub_deadbeefdeadbeef", data: encoded, vaultKey: nil
        )
        XCTAssertNil(decoded)
    }
}

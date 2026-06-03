import XCTest
import Foundation
import FirebaseFirestore
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

    // MARK: consentGivenAt type-tolerance (cross-platform orderBy parity)

    /// `consentGivenAt` is written as a Firestore Timestamp by both platforms now
    /// (iOS from its Swift `Date?`, Android from `Timestamp(Date(createdAtEpoch))`),
    /// but legacy docs may carry a Number (epoch millis — what Android used to
    /// write) or an ISO String. `decodeTopic`'s `decodeDate` must map all three to
    /// the SAME instant so the in-memory re-sort stays correct and no legacy doc
    /// becomes unreadable while the corpus lazily converges on Timestamp. Driven
    /// through the public `decodeTopic` seam so the real read path is locked.
    func test_decodeTopic_consentGivenAt_toleratesTimestampNumberAndStringEquivalently() throws {
        // 2023-11-14T22:13:20Z — whole seconds so Timestamp/Number/ISO agree
        // exactly (Firestore Timestamp has sub-second precision; ISO-8601 here is
        // second-granular).
        let epochMillis = 1_700_000_000_000.0
        let expected = Date(timeIntervalSince1970: epochMillis / 1000.0)

        func decodeConsent(_ rawValue: Any) throws -> Date {
            // Legacy plaintext doc (no sealed fields) so it decodes without a key;
            // only `consentGivenAt`'s wire type varies across the three cases.
            let doc: [String: Any] = [
                "agentURI": "agent://burnbar/research-scout",
                "topicID": "agent-updates",
                "displayName": "Scout",
                "description": "",
                "cadence": "weekly",
                "consentGivenAt": rawValue
            ]
            let topic = try XCTUnwrap(
                AgentSubscriptionTopicStore.decodeTopic(
                    documentID: "agent_burnbar_research-scout_agent-updates",
                    data: doc,
                    vaultKey: nil
                )
            )
            return try XCTUnwrap(topic.consentGivenAt)
        }

        // Canonical Firestore Timestamp (what both platforms now write).
        let fromTimestamp = try decodeConsent(Timestamp(date: expected))
        // Legacy Number (epoch millis — Android's old write type).
        let fromNumber = try decodeConsent(NSNumber(value: epochMillis))
        // Legacy ISO-8601 String.
        let fromString = try decodeConsent("2023-11-14T22:13:20Z")

        XCTAssertEqual(fromTimestamp.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(fromNumber.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(fromString.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_decodeTopic_sealedGraphUnreadableWithoutKey_returnsNil() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        var encoded = try AgentSubscriptionTopicStore.encodeTopic(makeTopic(), vaultKey: key)
        encoded["agentURI"] = "agent://burnbar/legacy-leak"
        encoded["topicID"] = "legacy-topic"
        encoded["displayName"] = "Legacy display leak"

        // Without the key, the sealed `agentURI`/`topicID` cannot open. Because
        // the sealed fields are present, legacy siblings must NOT leak.
        let decoded = AgentSubscriptionTopicStore.decodeTopic(
            documentID: "sub_deadbeefdeadbeef", data: encoded, vaultKey: nil
        )
        XCTAssertNil(decoded)
    }

    // MARK: Ghost-unsubscribe prevention (HIGH)

    /// Unsubscribe must NOT silently no-op the authoritative sealed-doc delete
    /// when the vault key is unavailable. The decision now lives in the pure
    /// `resolveUnsubscribeDocID`: a nil key MUST throw `vaultKeyUnavailable`
    /// (which the live path surfaces and on which it bails BEFORE dropping the
    /// local row), so the cloud subscription can never be orphaned behind a
    /// success UI. With a key present it resolves the same opaque doc id used by
    /// `documentID`, so the delete targets the real sealed doc.
    func test_resolveUnsubscribeDocID_withoutKey_throwsRecoverableError() throws {
        XCTAssertThrowsError(
            try AgentSubscriptionTopicStore.resolveUnsubscribeDocID(
                agentURI: "agent://burnbar/research-scout",
                topicID: "agent-updates",
                vaultKey: nil
            )
        ) { error in
            guard case AgentSubscriptionTopicStore.StoreError.vaultKeyUnavailable = error else {
                return XCTFail("Expected vaultKeyUnavailable, got \(error)")
            }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "The recoverable error must surface copy to the user")
            // Recoverable + jargon-free per the copy policy.
            for jargon in ["vault key", "HMAC", "opaque", "ciphertext", "E2EE"] {
                XCTAssertFalse(
                    message.localizedCaseInsensitiveContains(jargon),
                    "Unsubscribe-needs-unlock copy leaks jargon: \(jargon)"
                )
            }
        }
    }

    func test_resolveUnsubscribeDocID_withKey_targetsTheOpaqueSealedDoc() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let resolved = try AgentSubscriptionTopicStore.resolveUnsubscribeDocID(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            vaultKey: key
        )
        let expected = try AgentSubscriptionTopicStore.documentID(
            agentURI: "agent://burnbar/research-scout",
            topicID: "agent-updates",
            vaultKey: key
        )
        XCTAssertEqual(resolved, expected)
        XCTAssertFalse(resolved.contains("/"), "Doc id must be an opaque Firestore-safe id")
    }
}

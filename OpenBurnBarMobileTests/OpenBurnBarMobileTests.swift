import XCTest
import CryptoKit
import Security
import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBarMobile

/// Hermetic in-memory backing for ``HermesGatewayAgentKeyPinStore`` tests. Mirrors
/// the Keychain backing's three-state read contract without needing Keychain
/// entitlements, so the TOFU pin tests pass on unsigned simulators / CI.
private final class InMemoryGatewayPinBacking: HermesGatewayPinBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func load(account: String) -> HermesGatewayPinLoad {
        lock.lock(); defer { lock.unlock() }
        if let value = storage[account] { return .found(value) }
        return .absent
    }

    @discardableResult
    func save(_ value: String, account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
        return errSecSuccess
    }

    func delete(account: String) {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }
}

@MainActor
final class OpenBurnBarMobileTests: XCTestCase {

    // MARK: - Shared Model Compatibility

    func testAgentProviderRoundTrip() {
        let provider = AgentProvider.minimax
        XCTAssertEqual(provider.displayName, "MiniMax")
        XCTAssertEqual(provider.persistedToken, "minimax")
        XCTAssertEqual(AgentProvider.fromPersistedToken("minimax"), .minimax)
        XCTAssertEqual(AgentProvider.fromPersistedToken("claude-code"), .claudeCode)
        XCTAssertEqual(AgentProvider.fromPersistedToken("Claude Code"), .claudeCode)
        XCTAssertEqual(AgentProvider.fromPersistedToken("open-code"), .openCode)
        XCTAssertNil(AgentProvider.fromPersistedToken("unknown"))
    }

    func testHermesGatewayPairingCodeFormatterNormalizesPastedCodes() {
        XCTAssertEqual(HermesGatewayPairingCodeFormatter.displayString(for: "ab12 cd34"), "AB12-CD34")
        XCTAssertEqual(HermesGatewayPairingCodeFormatter.displayString(for: "ab12-cd34-extra"), "AB12-CD34")
        XCTAssertEqual(HermesGatewayPairingCodeFormatter.displayString(for: "ab1"), "AB1")
        XCTAssertEqual(HermesGatewayPairingCodeFormatter.canonicalCode(from: "ab12cd34"), "AB12-CD34")
        XCTAssertNil(HermesGatewayPairingCodeFormatter.canonicalCode(from: "short"))
    }

    func testHermesGatewayApprovalDecoderPreservesServerTimestampStrings() throws {
        let createdAt = "2026-06-01T07:54:03.234Z"
        let updatedAt = "2026-06-01T07:54:03.833Z"
        let payload = NSDictionary(dictionary: [
            "client": [
                "id": "hgw_test",
                "displayName": "Hermes Agent",
                "status": "active",
                "tokenPreview": "obb_hgw_...test",
                "scopes": [
                    "hermes.gateway.read",
                    "hermes.gateway.write",
                    "hermes.gateway.manage"
                ],
                "homeDestinationId": "burnbar:home",
                "lastSeenAt": Timestamp(date: Date(timeIntervalSince1970: 1_800_000_000)),
                "createdAt": createdAt,
                "updatedAt": updatedAt,
                "schemaVersion": 1
            ],
            "homeDestinationId": "burnbar:home"
        ])

        let client = try FunctionsRepository.decodeHermesGatewayApprovalClientForTesting(payload)

        XCTAssertEqual(client.createdAt, createdAt)
        XCTAssertEqual(client.updatedAt, updatedAt)
        XCTAssertTrue(client.lastSeenAt?.hasPrefix("2027-01-15T08:00:00") == true)
    }

    func testHermesGatewayOnlineStatusRequiresRecentLastSeen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30))
        let stale = ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
        let activeRecent = hermesGatewayClient(lastSeenAt: recent)
        let activeStale = hermesGatewayClient(lastSeenAt: stale)
        let neverSeen = hermesGatewayClient(lastSeenAt: nil)
        let revoked = hermesGatewayClient(status: "revoked", lastSeenAt: recent)

        XCTAssertTrue(activeRecent.isOnline(relativeTo: now))
        XCTAssertFalse(activeStale.isOnline(relativeTo: now))
        XCTAssertFalse(neverSeen.isOnline(relativeTo: now))
        XCTAssertFalse(revoked.isOnline(relativeTo: now))
    }

    func testHermesGatewayClientRecordParsesFirestorePayload() {
        let record = HermesGatewayClientRecord(
            documentID: "hgw_doc",
            data: [
                "id": "hgw_live",
                "displayName": "OpenBurnBar Gateway",
                "status": "active",
                "tokenPreview": "obb_hgw_...live",
                "scopes": [
                    "hermes.gateway.read",
                    "hermes.gateway.write"
                ],
                "homeDestinationId": "burnbar:home",
                "lastSeenAt": "2026-06-01T08:08:04.968Z",
                "runtimeModelId": "minimax-m2.7-highspeed",
                "runtimeProviderId": "minimax",
                "runtimeModelOptions": [
                    [
                        "providerId": "minimax",
                        "providerName": "MiniMax",
                        "modelId": "minimax-m2.7-highspeed",
                        "displayName": "MiniMax M2.7 Highspeed"
                    ],
                    [
                        "modelId": "claude-opus-4-5"
                    ]
                ],
                "runtimeUpdatedAt": "2026-06-01T08:08:04.969Z",
                "createdAt": "2026-06-01T08:00:00Z",
                "updatedAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 1
            ]
        )

        XCTAssertEqual(record?.id, "hgw_live")
        XCTAssertEqual(record?.displayName, "OpenBurnBar Gateway")
        XCTAssertEqual(record?.homeDestinationId, "burnbar:home")
        XCTAssertEqual(record?.scopes, ["hermes.gateway.read", "hermes.gateway.write"])
        XCTAssertEqual(record?.runtimeModelId, "minimax-m2.7-highspeed")
        XCTAssertEqual(record?.runtimeProviderId, "minimax")
        XCTAssertEqual(record?.runtimeModelOptions.count, 2)
        XCTAssertEqual(record?.runtimeModelOptions.first?.hermesRuntimeOption.modelID, "minimax-m2.7-highspeed")
        XCTAssertEqual(record?.runtimeModelOptions.first?.hermesRuntimeOption.displayName, "MiniMax M2.7 Highspeed")
        XCTAssertEqual(record?.runtimeModelOptions.last?.providerId, "hermes")
        XCTAssertEqual(record?.runtimeUpdatedAt, "2026-06-01T08:08:04.969Z")
    }

    func testHermesGatewayMessageRecordParsesReplyPayload() {
        let record = HermesGatewayMessageRecord(
            documentID: "msg_doc",
            data: [
                "id": "msg_123",
                "clientId": "hgw_abc",
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "threadId": "burnbar-ios-e2e",
                "replyToEventId": "evt_123",
                "text": "Hermes received the test.",
                "attachmentIds": ["att_1"],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 1
            ]
        )

        XCTAssertEqual(record?.id, "msg_123")
        XCTAssertEqual(record?.replyToEventId, "evt_123")
        XCTAssertEqual(record?.text, "Hermes received the test.")
        XCTAssertFalse(record?.isSealed ?? true)
        XCTAssertEqual(record?.displayText, "Hermes received the test.")
    }

    func testHermesGatewayMessageRecordParsesSealedReplyAndExposesNoPlaintext() {
        let record = HermesGatewayMessageRecord(
            documentID: "msg_doc",
            data: [
                "id": "msg_sealed",
                "clientId": "hgw_abc",
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "threadId": HermesGatewayMessageResolver.defaultThreadID,
                "relayEnvelope": [
                    "payloadCiphertext": "QkFTRTY0X1BBWUxPQUQ=",
                    "wrappedKey": "QkFTRTY0X1dSQVBQRUQ=",
                    "relayEncryption": HermesRelayCrypto.algorithm,
                    "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 2
            ]
        )

        XCTAssertEqual(record?.id, "msg_sealed")
        XCTAssertNil(record?.text, "Sealed docs must not carry plaintext text")
        XCTAssertTrue(record?.isSealed ?? false)
        XCTAssertNil(record?.displayText, "Unopened sealed reply has no display text")
    }

    func testHermesGatewaySealedReplyRoundTripsThroughPhoneRelayKey() throws {
        let uid = "uid_test"
        let clientId = "hgw_abc"
        let messageId = "msg_round_trip"
        let plaintext = "Hermes received the encrypted test."

        // The agent's role: seal the reply body to the phone's relay pubkey.
        let phoneKeypair = HermesGatewayRelayKeypair.loadOrCreate()
        let phonePublicKey = phoneKeypair.relayPublicKeyBase64
        let key = try HermesRelayCrypto.generateSymmetricKeyData()
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data(plaintext.utf8),
            keyData: key,
            aad: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: messageId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            key,
            recipientPublicKeyBase64: phonePublicKey,
            aad: HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: messageId)
        )

        let sealedRecord = HermesGatewayMessageRecord(
            documentID: messageId,
            data: [
                "id": messageId,
                "clientId": clientId,
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "relayEnvelope": [
                    "payloadCiphertext": payloadCiphertext,
                    "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm,
                    "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 2
            ]
        )
        let opened = sealedRecord?.decodedText(using: phoneKeypair, uid: uid)
        XCTAssertEqual(opened?.resolvedText, plaintext)
        XCTAssertEqual(opened?.displayText, plaintext)
    }

    func testHermesGatewaySealedReplyForAnotherDeviceStaysSealed() throws {
        let uid = "uid_test"
        let clientId = "hgw_abc"
        let messageId = "msg_other_device"

        // Seal to a *different* phone key, then try to open with this device's key.
        let otherDevicePublicKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let key = try HermesRelayCrypto.generateSymmetricKeyData()
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("not for this device".utf8),
            keyData: key,
            aad: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: messageId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            key,
            recipientPublicKeyBase64: otherDevicePublicKey,
            aad: HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: messageId)
        )

        let sealedRecord = HermesGatewayMessageRecord(
            documentID: messageId,
            data: [
                "id": messageId,
                "clientId": clientId,
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "relayEnvelope": [
                    "payloadCiphertext": payloadCiphertext,
                    "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm,
                    "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 2
            ]
        )
        let opened = sealedRecord?.decodedText(using: HermesGatewayRelayKeypair.loadOrCreate(), uid: uid)
        XCTAssertTrue(opened?.isSealed ?? false)
        XCTAssertNil(opened?.resolvedText, "A reply sealed for another device must not open here")
        XCTAssertNil(opened?.displayText)
    }

    func testHermesGatewayEmptyOpenedReplyWithAttachmentShowsAttachmentSummary() throws {
        let record = HermesGatewayMessageRecord(
            documentID: "msg_attachment_only",
            data: [
                "id": "msg_attachment_only",
                "clientId": "hgw_abc",
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "attachmentIds": ["att_1"],
                "relayEnvelope": [
                    "payloadCiphertext": "QkFTRTY0X1BBWUxPQUQ=",
                    "wrappedKey": "QkFTRTY0X1dSQVBQRUQ=",
                    "relayEncryption": HermesRelayCrypto.algorithm,
                    "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 2
            ]
        )

        var opened = try XCTUnwrap(record)
        opened.resolvedText = ""

        XCTAssertFalse(opened.isUndecryptableHere)
        XCTAssertEqual(opened.chatRenderText(), "Hermes sent 1 attachment.")
    }

    func testHermesGatewayAttachmentOpenFailureShowsRecoverableMessage() throws {
        let record = HermesGatewayMessageRecord(
            documentID: "msg_attachment_failed",
            data: [
                "id": "msg_attachment_failed",
                "clientId": "hgw_abc",
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "attachmentIds": ["att_missing"],
                "relayEnvelope": [
                    "payloadCiphertext": "QkFTRTY0X1BBWUxPQUQ=",
                    "wrappedKey": "QkFTRTY0X1dSQVBQRUQ=",
                    "relayEncryption": HermesRelayCrypto.algorithm,
                    "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 2
            ]
        )

        var opened = try XCTUnwrap(record)
        opened.resolvedText = ""
        opened = opened.withAttachmentHydration(opened: [], failedAttachmentIds: ["att_missing"])

        XCTAssertFalse(opened.isUndecryptableHere)
        XCTAssertEqual(
            opened.chatRenderText(),
            "One attachment could not open on this device. Reconnect Hermes here, then try again."
        )
    }

    func testHermesGatewayUndecryptableReplyKeepsRePairCopyWhenAttachmentOpenFails() throws {
        let record = HermesGatewayMessageRecord(
            documentID: "msg_other_device_attachment_failed",
            data: [
                "id": "msg_other_device_attachment_failed",
                "clientId": "hgw_abc",
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "attachmentIds": ["att_missing"],
                "relayEnvelope": [
                    "payloadCiphertext": "QkFTRTY0X1BBWUxPQUQ=",
                    "wrappedKey": "QkFTRTY0X1dSQVBQRUQ=",
                    "relayEncryption": HermesRelayCrypto.algorithm,
                    "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 2
            ]
        )

        let opened = try XCTUnwrap(record?.withAttachmentHydration(opened: [], failedAttachmentIds: ["att_missing"]))

        XCTAssertTrue(opened.isUndecryptableHere)
        XCTAssertEqual(
            opened.chatRenderText(),
            "\(HermesGatewayMessageRecord.sealedForAnotherDeviceText)\n\nOne attachment could not open on this device. Reconnect Hermes here, then try again."
        )
    }

    func testHermesGatewayBodyIncludesAttachmentFailureHint() throws {
        let record = HermesGatewayMessageRecord(
            documentID: "msg_body_attachment_failed",
            data: [
                "id": "msg_body_attachment_failed",
                "clientId": "hgw_abc",
                "kind": "agent_message",
                "destinationId": "burnbar:home",
                "attachmentIds": ["att_missing"],
                "createdAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 1,
                "text": "Here is the result."
            ]
        )

        let opened = try XCTUnwrap(record?.withAttachmentHydration(opened: [], failedAttachmentIds: ["att_missing"]))

        XCTAssertEqual(
            opened.chatRenderText(),
            "Here is the result.\n\nOne attachment could not open on this device. Reconnect Hermes here, then try again."
        )
    }

    func testHermesGatewaySealedAttachmentRoundTripsAndImportsIntoChatWorkspace() throws {
        let uid = "uid_test"
        let clientId = "hgw_abc"
        let attachmentId = "att_round_trip_\(UUID().uuidString)"
        let plaintext = Data("private file bytes".utf8)
        let fileName = "notes.txt"
        let contentType = "text/plain"
        let threadID = "gateway-attachment-test-\(UUID().uuidString)"
        defer {
            if let root = HermesAttachmentWorkspace.threadRoot(threadID: threadID) {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let phoneKeypair = HermesGatewayRelayKeypair.loadOrCreate()
        let bodyKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let sealedBody = try HermesRelayCrypto.sealToBase64(
            plaintext: plaintext,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        let manifestData = try JSONSerialization.data(withJSONObject: [
            "fileName": fileName,
            "byteCount": plaintext.count,
            "contentType": contentType
        ])
        let sealedManifest = try HermesRelayCrypto.sealToBase64(
            plaintext: manifestData,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentManifestAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            bodyKey,
            recipientPublicKeyBase64: phoneKeypair.relayPublicKeyBase64,
            aad: HermesRelayCrypto.gatewayAttachmentKeyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )

        let record = HermesGatewayAttachmentRecord(
            documentID: attachmentId,
            data: [
                "id": attachmentId,
                "clientId": clientId,
                "bodyStoragePath": "users/\(uid)/hermes_gateway_attachments/\(attachmentId)",
                "relayEnvelope": [
                    "payloadCiphertext": sealedManifest,
                    "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm,
                    "relayKeyVersion": HermesRelayCrypto.keyVersion
                ]
            ]
        )
        let opened = try XCTUnwrap(record?.opened(downloadedBody: Data(sealedBody.utf8), using: phoneKeypair, uid: uid))
        XCTAssertEqual(opened.fileName, fileName)
        XCTAssertEqual(opened.contentType, contentType)
        XCTAssertEqual(opened.data, plaintext)

        let imported = try HermesAttachmentLoader.importGatewayOpenedAttachment(opened, threadID: threadID)
        XCTAssertEqual(imported.id, attachmentId)
        XCTAssertEqual(imported.displayName, fileName)
        XCTAssertEqual(imported.mimeType, contentType)
        XCTAssertEqual(imported.byteSize, plaintext.count)
        XCTAssertEqual(imported.extractedTextPreview, "private file bytes")

        let workspace = try XCTUnwrap(HermesAttachmentWorkspace.threadRoot(threadID: threadID))
        let stored = try Data(contentsOf: workspace.appendingPathComponent(imported.workspaceRelativePath))
        XCTAssertEqual(stored, plaintext)
    }

    func testHermesGatewayClientRecordReadsAgentRelayPubkeyAndCanSeal() {
        let agentKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let record = HermesGatewayClientRecord(
            documentID: "hgw_doc",
            data: [
                "id": "hgw_live",
                "displayName": "OpenBurnBar Gateway",
                "status": "active",
                "tokenPreview": "obb_hgw_...live",
                "homeDestinationId": "burnbar:home",
                "createdAt": "2026-06-01T08:00:00Z",
                "updatedAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 2,
                "relayPublicKey": agentKey,
                "relayKeyVersion": 1,
                "relayEncryption": HermesRelayCrypto.algorithm
            ]
        )

        XCTAssertEqual(record?.relayPublicKey, agentKey)
        XCTAssertEqual(record?.relayKeyVersion, 1)
        XCTAssertEqual(record?.relayEncryption, HermesRelayCrypto.algorithm)
        XCTAssertTrue(record?.canSealToAgent ?? false)
    }

    func testHermesGatewayClientWithoutAgentPubkeyCannotSeal() {
        let record = HermesGatewayClientRecord(
            documentID: "hgw_doc",
            data: [
                "id": "hgw_live",
                "displayName": "OpenBurnBar Gateway",
                "status": "active",
                "tokenPreview": "obb_hgw_...live",
                "homeDestinationId": "burnbar:home",
                "createdAt": "2026-06-01T08:00:00Z",
                "updatedAt": "2026-06-01T08:08:04.968Z",
                "schemaVersion": 1
            ]
        )
        XCTAssertFalse(record?.canSealToAgent ?? true)
        XCTAssertNil(record?.relayPublicKey)
    }

    // MARK: - Phone-side agent key pinning (TOFU) — FIX-ios finding 1

    /// Build an active, E2EE-ready client that advertises a specific agent relay
    /// pubkey, so seal/pin tests can swap the advertised key under a fixed id.
    private func sealableGatewayClient(id: String, agentPublicKey: String) -> HermesGatewayClientRecord {
        HermesGatewayClientRecord(
            id: id,
            displayName: "Pinned Hermes",
            status: "active",
            tokenPreview: "obb_hgw_...pin",
            scopes: ["hermes.gateway.read", "hermes.gateway.write"],
            homeDestinationId: "burnbar:home",
            lastSeenAt: nil,
            revokedAt: nil,
            createdAt: "2026-06-01T08:00:00Z",
            updatedAt: "2026-06-01T08:08:04.968Z",
            schemaVersion: 2,
            relayPublicKey: agentPublicKey,
            relayKeyVersion: HermesRelayCrypto.keyVersion,
            relayEncryption: HermesRelayCrypto.algorithm
        )
    }

    /// A fresh pin store scoped to a throwaway Keychain account namespace so the
    /// test never collides with a previously pinned device key.
    private func freshPinStore() -> HermesGatewayAgentKeyPinStore {
        // Inject an in-memory backing so the TOFU pin tests run hermetically on
        // unsigned simulators / CI, where the real Keychain returns
        // errSecMissingEntitlement (-34018). Production still uses the Keychain.
        HermesGatewayAgentKeyPinStore(backing: InMemoryGatewayPinBacking())
    }

    func testAgentKeyPinFirstUsePinsAndMatchesSameKey() {
        let store = freshPinStore()
        let uid = "uid_pin"
        let clientId = "hgw_pin_\(UUID().uuidString)"
        let agentKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        defer { store.clearPin(uid: uid, clientId: clientId) }

        XCTAssertEqual(store.verifyOrPin(agentPublicKeyBase64: agentKey, uid: uid, clientId: clientId), .pinnedFirstUse)
        XCTAssertEqual(store.pinnedKey(uid: uid, clientId: clientId), agentKey)
        // Re-observing the same key must match (and stay sealable).
        let again = store.verifyOrPin(agentPublicKeyBase64: agentKey, uid: uid, clientId: clientId)
        XCTAssertEqual(again, .matches)
        XCTAssertTrue(again.allowsSeal)
    }

    func testAgentKeyPinMismatchRefusesAndReportsPinnedKey() {
        let store = freshPinStore()
        let uid = "uid_pin"
        let clientId = "hgw_pin_\(UUID().uuidString)"
        let originalKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let attackerKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        defer { store.clearPin(uid: uid, clientId: clientId) }

        XCTAssertEqual(store.verifyOrPin(agentPublicKeyBase64: originalKey, uid: uid, clientId: clientId), .pinnedFirstUse)
        // A *different* advertised key (post-pairing rotation / MITM) must refuse.
        let result = store.verifyOrPin(agentPublicKeyBase64: attackerKey, uid: uid, clientId: clientId)
        XCTAssertEqual(result, .mismatch(pinned: originalKey))
        XCTAssertFalse(result.allowsSeal)
        // The pin is unchanged — the attacker key never overwrites trust.
        XCTAssertEqual(store.pinnedKey(uid: uid, clientId: clientId), originalKey)
    }

    func testAgentKeyPinClearReestablishesTrustForRepair() {
        let store = freshPinStore()
        let uid = "uid_pin"
        let clientId = "hgw_pin_\(UUID().uuidString)"
        let originalKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let rotatedKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        defer { store.clearPin(uid: uid, clientId: clientId) }

        XCTAssertEqual(store.verifyOrPin(agentPublicKeyBase64: originalKey, uid: uid, clientId: clientId), .pinnedFirstUse)
        XCTAssertFalse(store.verifyOrPin(agentPublicKeyBase64: rotatedKey, uid: uid, clientId: clientId).allowsSeal)
        // Re-pair deliberately clears the pin; the new key is then trusted afresh.
        store.clearPin(uid: uid, clientId: clientId)
        XCTAssertEqual(store.verifyOrPin(agentPublicKeyBase64: rotatedKey, uid: uid, clientId: clientId), .pinnedFirstUse)
        XCTAssertEqual(store.pinnedKey(uid: uid, clientId: clientId), rotatedKey)
    }

    func testAgentKeySafetyCodeIsDeterministicAndKeyDependent() {
        let keyA = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let keyB = HermesRelayCrypto.generatePrivateKey().publicKeyBase64

        let codeA1 = HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: keyA)
        let codeA2 = HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: keyA)
        let codeB = HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: keyB)

        // Same key → identical code, so two devices can compare it out of band.
        XCTAssertNotNil(codeA1)
        XCTAssertEqual(codeA1, codeA2)
        // Different key → different code, so a changed connection is visible.
        XCTAssertNotEqual(codeA1, codeB)
        // Whitespace around the same key must not change the code.
        XCTAssertEqual(codeA1, HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: "  \(keyA)\n"))
        // An empty key yields no code rather than a fabricated one.
        XCTAssertNil(HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: "   "))
    }

    func testAgentKeySafetyCodeFormatIsHumanComparableHexGroups() throws {
        let key = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let code = try XCTUnwrap(HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: key))

        // Four groups of four uppercase hex characters, space separated.
        let groups = code.split(separator: " ").map(String.init)
        XCTAssertEqual(groups.count, 4)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        for group in groups {
            XCTAssertEqual(group.count, 4)
            XCTAssertTrue(group.unicodeScalars.allSatisfy { allowed.contains($0) }, "non-hex in \(group)")
        }
    }

    func testPinnedSafetyCodeReflectsTrustedKeyAfterRepair() {
        let store = freshPinStore()
        let uid = "uid_safety"
        let clientId = "hgw_safety_\(UUID().uuidString)"
        let originalKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let rotatedKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        defer { store.clearPin(uid: uid, clientId: clientId) }

        // No pin yet → no pinned code.
        XCTAssertNil(store.pinnedSafetyCode(uid: uid, clientId: clientId))

        XCTAssertEqual(store.verifyOrPin(agentPublicKeyBase64: originalKey, uid: uid, clientId: clientId), .pinnedFirstUse)
        XCTAssertEqual(
            store.pinnedSafetyCode(uid: uid, clientId: clientId),
            HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: originalKey)
        )

        // After a consented re-pair to a new key, the code tracks the new trust.
        store.clearPin(uid: uid, clientId: clientId)
        XCTAssertEqual(store.verifyOrPin(agentPublicKeyBase64: rotatedKey, uid: uid, clientId: clientId), .pinnedFirstUse)
        XCTAssertEqual(
            store.pinnedSafetyCode(uid: uid, clientId: clientId),
            HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: rotatedKey)
        )
        XCTAssertNotEqual(
            HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: originalKey),
            HermesGatewayAgentKeyPinStore.safetyCode(forPublicKeyBase64: rotatedKey)
        )
    }

    func testGatewayPrivacyStateResolvesFromRealKeyState() {
        let sealableKey = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let verified = sealableGatewayClient(id: "hgw_state_a", agentPublicKey: sealableKey)
        // A sealable, unchanged connection reads as private + verified.
        XCTAssertEqual(
            HermesGatewayPrivacyState.resolve(client: verified, keyChanged: false),
            .privateVerified
        )
        // A changed connection always wins → reconnect, never "private".
        XCTAssertEqual(
            HermesGatewayPrivacyState.resolve(client: verified, keyChanged: true),
            .reconnectNeeded
        )
        // A paired client that can't seal yet (Mac needs an update) → finish setup.
        let notSealable = HermesGatewayClientRecord(
            id: "hgw_state_b",
            displayName: "Mac",
            status: "active",
            tokenPreview: "abcd",
            scopes: [],
            homeDestinationId: "burnbar:home",
            lastSeenAt: nil,
            revokedAt: nil,
            createdAt: "2026-06-02T08:00:00.000Z",
            updatedAt: "2026-06-02T08:00:00.000Z",
            schemaVersion: 2
        )
        XCTAssertEqual(
            HermesGatewayPrivacyState.resolve(client: notSealable, keyChanged: false),
            .updateNeeded
        )
    }

    func testGatewayPrivacyChipCopyIsJargonFree() {
        let jargon = ["relay", "envelope", "P-256", "HKDF", "TOFU", "pin", "keyVersion", "AAD", "ciphertext", "MITM", "man-in-the-middle", "E2EE"]
        let strings: [String] = HermesGatewayPrivacyState.allUserFacingCopyForTests
        for text in strings {
            for term in jargon {
                XCTAssertFalse(
                    text.localizedCaseInsensitiveContains(term),
                    "Privacy copy leaks jargon '\(term)': \(text)"
                )
            }
        }
    }

    func testGatewayEventSealPinsAgentKeyThenRefusesChangedKey() throws {
        let store = freshPinStore()
        let uid = "uid_seal"
        let clientId = "hgw_seal_\(UUID().uuidString)"
        let agentPrivate = HermesRelayCrypto.generatePrivateKey()
        let client = sealableGatewayClient(id: clientId, agentPublicKey: agentPrivate.publicKeyBase64)
        defer { store.clearPin(uid: uid, clientId: clientId) }

        // First seal pins the key and produces a sealed envelope (no plaintext).
        var payload: [String: Any] = ["destinationId": "burnbar:home"]
        try FunctionsRepository.sealGatewayEventPayload(
            into: &payload,
            text: "hello hermes",
            senderDisplayName: "iPhone",
            threadId: "burnbar-ios-e2e",
            modelId: nil,
            targetClient: client,
            uid: uid,
            pinStore: store
        )
        XCTAssertNil(payload["text"], "Plaintext text must never appear at the top level")
        XCTAssertNil(payload["senderDisplayName"])
        let envelope = payload["relayEnvelope"] as? [String: Any]
        XCTAssertNotNil(envelope?["payloadCiphertext"] as? String)
        XCTAssertNotNil(envelope?["wrappedKey"] as? String)
        XCTAssertEqual(envelope?["relayEncryption"] as? String, HermesRelayCrypto.algorithm)
        XCTAssertEqual(store.pinnedKey(uid: uid, clientId: clientId), agentPrivate.publicKeyBase64)

        // Server advertises a DIFFERENT agent key for the same client id → MITM.
        let attackerClient = sealableGatewayClient(
            id: clientId,
            agentPublicKey: HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        )
        var blockedPayload: [String: Any] = ["destinationId": "burnbar:home"]
        XCTAssertThrowsError(
            try FunctionsRepository.sealGatewayEventPayload(
                into: &blockedPayload,
                text: "secret",
                senderDisplayName: "iPhone",
                threadId: "burnbar-ios-e2e",
                modelId: nil,
                targetClient: attackerClient,
                uid: uid,
                pinStore: store
            )
        ) { error in
            XCTAssertEqual(error as? FunctionsError, .gatewayRelayKeyChanged)
        }
        // Fail-closed: nothing sealed, no envelope, no plaintext leaked.
        XCTAssertNil(blockedPayload["relayEnvelope"])
        XCTAssertNil(blockedPayload["text"])
        XCTAssertNil(blockedPayload["eventId"])
    }

    // MARK: - Sealed model_switch — FIX-ios finding 2

    func testSealedModelSwitchCarriesModelIdInsideEnvelopeAndRoundTrips() throws {
        let store = freshPinStore()
        let uid = "uid_model"
        let clientId = "hgw_model_\(UUID().uuidString)"
        let agentPrivate = HermesRelayCrypto.generatePrivateKey()
        let client = sealableGatewayClient(id: clientId, agentPublicKey: agentPrivate.publicKeyBase64)
        defer { store.clearPin(uid: uid, clientId: clientId) }

        // The phone seals a model_switch exactly like other events: modelId rides
        // inside the sealed payload, never as a top-level cleartext field.
        var payload: [String: Any] = [
            "destinationId": "burnbar:home",
            "senderId": "burnbar-ios",
            "eventKind": "model_switch"
        ]
        try FunctionsRepository.sealGatewayEventPayload(
            into: &payload,
            text: "",
            senderDisplayName: "iPhone",
            threadId: "burnbar-ios-e2e",
            modelId: "anthropic/claude-opus",
            targetClient: client,
            uid: uid,
            pinStore: store
        )
        XCTAssertNil(payload["modelId"], "Sealed model_switch must not leak modelId in cleartext")
        guard
            let eventId = payload["eventId"] as? String,
            let envelope = payload["relayEnvelope"] as? [String: Any],
            let payloadCiphertext = envelope["payloadCiphertext"] as? String,
            let wrappedKey = envelope["wrappedKey"] as? String
        else {
            return XCTFail("Sealed model_switch is missing its envelope")
        }

        // The agent opens it: unwrap the per-event key, open the payload, read modelId.
        let symmetricKey = try HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: agentPrivate,
            aad: HermesRelayCrypto.gatewayEventKeyAAD(uid: uid, clientId: clientId, eventId: eventId)
        )
        let openedData = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: symmetricKey,
            aad: HermesRelayCrypto.gatewayEventAAD(uid: uid, clientId: clientId, eventId: eventId)
        )
        let opened = try XCTUnwrap(try JSONSerialization.jsonObject(with: openedData) as? [String: Any])
        XCTAssertEqual(opened["modelId"] as? String, "anthropic/claude-opus")
        XCTAssertEqual(opened["threadId"] as? String, "burnbar-ios-e2e")
        XCTAssertEqual(opened["senderDisplayName"] as? String, "iPhone")
    }

    // MARK: Gateway reply chat-render (BLOCKER + HIGH undecryptable UX)

    /// The chat thread must render the OPENED reply body, not the legacy
    /// (always-nil) `text` field. Closes the BLOCKER where every sealed reply
    /// rendered "Hermes replied without text." in the conversation.
    func testGatewaySealedReplyChatRenderShowsOpenedText() throws {
        let uid = "uid_render"
        let clientId = "hgw_render"
        let messageId = "msg_render"
        let plaintext = "Done — your build is green."

        let phoneKeypair = HermesGatewayRelayKeypair.loadOrCreate()
        let key = try HermesRelayCrypto.generateSymmetricKeyData()
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data(plaintext.utf8),
            keyData: key,
            aad: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: messageId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            key,
            recipientPublicKeyBase64: phoneKeypair.relayPublicKeyBase64,
            aad: HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: messageId)
        )
        let record = HermesGatewayMessageRecord(
            documentID: messageId,
            data: [
                "id": messageId, "clientId": clientId, "kind": "agent_message",
                "destinationId": "burnbar:home",
                "relayEnvelope": [
                    "payloadCiphertext": payloadCiphertext, "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm, "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-02T08:08:04.968Z", "schemaVersion": 2
            ]
        )
        let opened = try XCTUnwrap(record?.decodedText(using: phoneKeypair, uid: uid))
        XCTAssertEqual(opened.chatRenderText(), plaintext)
        XCTAssertFalse(opened.isUndecryptableHere)
    }

    /// A reply sealed for a DIFFERENT paired device must render the calm,
    /// jargon-free re-pair state — never a blank/"no text" bubble and never any
    /// crypto jargon. Closes the HIGH "undecryptable masked as empty reply".
    func testGatewayUndecryptableReplyChatRenderShowsRePairState() throws {
        let uid = "uid_other"
        let clientId = "hgw_other"
        let messageId = "msg_other"
        let otherDevice = HermesRelayCrypto.generatePrivateKey().publicKeyBase64
        let key = try HermesRelayCrypto.generateSymmetricKeyData()
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("secret".utf8),
            keyData: key,
            aad: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: messageId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            key,
            recipientPublicKeyBase64: otherDevice,
            aad: HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: messageId)
        )
        let record = HermesGatewayMessageRecord(
            documentID: messageId,
            data: [
                "id": messageId, "clientId": clientId, "kind": "agent_message",
                "destinationId": "burnbar:home",
                "relayEnvelope": [
                    "payloadCiphertext": payloadCiphertext, "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm, "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-02T08:08:04.968Z", "schemaVersion": 2
            ]
        )
        let opened = try XCTUnwrap(record?.decodedText(using: HermesGatewayRelayKeypair.loadOrCreate(), uid: uid))
        XCTAssertTrue(opened.isUndecryptableHere)
        let rendered = opened.chatRenderText()
        XCTAssertEqual(rendered, HermesGatewayMessageRecord.sealedForAnotherDeviceText)
        XCTAssertFalse(rendered.isEmpty)
        // Copy policy: no transport/crypto jargon in the recourse text.
        for jargon in ["relay key", "E2EE", "end-to-end", "man-in-the-middle", "AES", "ciphertext", "envelope"] {
            XCTAssertFalse(
                rendered.localizedCaseInsensitiveContains(jargon),
                "Re-pair copy leaks jargon: \(jargon)"
            )
        }
    }

    // MARK: Gateway sealed attachment open (HIGH — write-only-dead opener)

    /// Seals an attachment EXACTLY as the Python adapter's `seal_attachment`
    /// does (distinct manifest/body/key AAD labels, body blob = base64 of the
    /// sealed body), then proves the new iOS opener unwraps the body key, opens
    /// the manifest for the filename, and opens the file bytes. Closes the HIGH
    /// "agent→phone sealed attachments have no iOS opener".
    func testGatewaySealedAttachmentOpensRoundTrip() throws {
        let uid = "uid_att"
        let clientId = "hgw_att"
        let attachmentId = "att_round_trip"
        let fileName = "report.pdf"
        let fileBytes = Data((0..<256).map { UInt8($0 % 251) })
        let contentType = "application/pdf"

        let phoneKeypair = HermesGatewayRelayKeypair.loadOrCreate()

        // --- Agent (Python adapter) side: one body key seals body + manifest
        //     under DISTINCT AAD labels, wrapped under the key AAD. ---
        let bodyKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let sealedBodyBase64 = try HermesRelayCrypto.sealToBase64(
            plaintext: fileBytes,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        // The adapter uploads the ASCII base64 of the sealed body as the blob.
        let downloadedBody = Data(sealedBodyBase64.utf8)
        let manifestJSON = try JSONSerialization.data(withJSONObject: [
            "fileName": fileName, "byteCount": fileBytes.count, "contentType": contentType
        ])
        let manifestCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: manifestJSON,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentManifestAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            bodyKey,
            recipientPublicKeyBase64: phoneKeypair.relayPublicKeyBase64,
            aad: HermesRelayCrypto.gatewayAttachmentKeyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )

        let record = try XCTUnwrap(HermesGatewayAttachmentRecord(
            documentID: attachmentId,
            data: [
                "id": attachmentId, "clientId": clientId, "destinationId": "burnbar:home",
                "bodyStoragePath": "hermes_gateway_attachments/\(uid)/\(attachmentId)",
                "relayEnvelope": [
                    "payloadCiphertext": manifestCiphertext, "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm, "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-02T08:08:04.968Z"
            ]
        ))
        XCTAssertTrue(record.isSealed)

        // --- Phone side: the new opener round-trips the Python-sealed wire. ---
        let opened = try XCTUnwrap(
            record.opened(downloadedBody: downloadedBody, using: phoneKeypair, uid: uid),
            "iOS must open a Python-sealed gateway attachment"
        )
        XCTAssertEqual(opened.fileName, fileName)
        XCTAssertEqual(opened.byteCount, fileBytes.count)
        XCTAssertEqual(opened.contentType, contentType)
        XCTAssertEqual(opened.data, fileBytes)
    }

    /// A relay that swaps the body ciphertext into the manifest slot (or vice
    /// versa) must fail the AES-GCM tag — the distinct AAD labels bind each slot.
    func testGatewaySealedAttachmentCrossSlotSwapFailsTag() throws {
        let uid = "uid_swap"
        let clientId = "hgw_swap"
        let attachmentId = "att_swap"
        let phoneKeypair = HermesGatewayRelayKeypair.loadOrCreate()

        let bodyKey = try HermesRelayCrypto.generateSymmetricKeyData()
        // Seal the body, then try to open it AS IF it were the manifest (wrong AAD).
        let sealedBodyBase64 = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("file".utf8),
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            bodyKey,
            recipientPublicKeyBase64: phoneKeypair.relayPublicKeyBase64,
            aad: HermesRelayCrypto.gatewayAttachmentKeyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        // Put the BODY ciphertext into the manifest (payloadCiphertext) slot.
        let record = try XCTUnwrap(HermesGatewayAttachmentRecord(
            documentID: attachmentId,
            data: [
                "id": attachmentId, "clientId": clientId, "destinationId": "burnbar:home",
                "relayEnvelope": [
                    "payloadCiphertext": sealedBodyBase64, "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm, "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-02T08:08:04.968Z"
            ]
        ))
        let bodyKeyUnwrapped = try XCTUnwrap(record.unwrapBodyKey(using: phoneKeypair, uid: uid))
        XCTAssertThrowsError(try record.openManifest(bodyKey: bodyKeyUnwrapped, uid: uid)) { _ in }
    }

    /// An attachment sealed to another paired device cannot be opened here and
    /// returns nil (so the caller shows the same calm re-pair state as a reply).
    func testGatewaySealedAttachmentForAnotherDeviceDoesNotOpen() throws {
        let uid = "uid_att_other"
        let clientId = "hgw_att_other"
        let attachmentId = "att_other"
        let otherDevice = HermesRelayCrypto.generatePrivateKey().publicKeyBase64

        let bodyKey = try HermesRelayCrypto.generateSymmetricKeyData()
        let sealedBodyBase64 = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("file".utf8),
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        let manifestCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: try JSONSerialization.data(withJSONObject: ["fileName": "x.txt", "byteCount": 4]),
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentManifestAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        let wrappedKey = try HermesRelayCrypto.wrapSymmetricKey(
            bodyKey,
            recipientPublicKeyBase64: otherDevice,
            aad: HermesRelayCrypto.gatewayAttachmentKeyAAD(uid: uid, clientId: clientId, attachmentId: attachmentId)
        )
        let record = try XCTUnwrap(HermesGatewayAttachmentRecord(
            documentID: attachmentId,
            data: [
                "id": attachmentId, "clientId": clientId, "destinationId": "burnbar:home",
                "relayEnvelope": [
                    "payloadCiphertext": manifestCiphertext, "wrappedKey": wrappedKey,
                    "relayEncryption": HermesRelayCrypto.algorithm, "relayKeyVersion": 1
                ],
                "createdAt": "2026-06-02T08:08:04.968Z"
            ]
        ))
        XCTAssertNil(record.unwrapBodyKey(using: HermesGatewayRelayKeypair.loadOrCreate(), uid: uid))
        XCTAssertNil(record.opened(
            downloadedBody: Data(sealedBodyBase64.utf8),
            using: HermesGatewayRelayKeypair.loadOrCreate(),
            uid: uid
        ))
    }

    func testHermesGatewayRelayKeypairPublishesX963PubkeyAtPairing() async {
        let suiteName = "HermesGatewaySettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let repository = MockHermesGatewayRepository()
        let store = HermesGatewaySettingsStore(repository: repository, defaults: defaults)
        _ = await store.approve(userCode: "AB12-CD34", displayName: "iPhone")

        let grant = repository.approvalGrants.last
        XCTAssertEqual(grant?.userCode, "AB12-CD34")
        XCTAssertEqual(grant?.relayEncryption, HermesRelayCrypto.algorithm)
        XCTAssertEqual(grant?.relayKeyVersion, HermesRelayCrypto.keyVersion)
        // The published pubkey decodes as a 65-byte X9.63 P-256 point (0x04 || X || Y).
        let pubkey = grant?.relayPublicKey ?? ""
        XCTAssertFalse(pubkey.isEmpty)
        let decoded = Data(base64Encoded: pubkey)
        XCTAssertEqual(decoded?.count, 65)
        XCTAssertEqual(decoded?.first, 0x04)
    }

    func testHermesGatewayQueuedEventParsesTargetClientId() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "evt_123",
            "sequence": 42,
            "targetClientId": "hgw_macbook"
        ])

        let event = try JSONDecoder().decode(HermesGatewayQueuedEvent.self, from: data)

        XCTAssertEqual(event.id, "evt_123")
        XCTAssertEqual(event.sequence, 42)
        XCTAssertEqual(event.targetClientId, "hgw_macbook")
    }

    func testHermesGatewayMessageResolverShowsThreadReplyWithoutPendingEvent() {
        let newest = hermesGatewayMessage(
            id: "msg_newest",
            threadId: HermesGatewayMessageResolver.defaultThreadID,
            text: "Latest reply",
            createdAt: "2026-06-01T10:51:43.304Z"
        )
        let older = hermesGatewayMessage(
            id: "msg_older",
            threadId: HermesGatewayMessageResolver.defaultThreadID,
            text: "Older reply",
            createdAt: "2026-06-01T10:50:00Z"
        )
        let otherThread = hermesGatewayMessage(
            id: "msg_other",
            threadId: "other-thread",
            text: "Wrong thread",
            createdAt: "2026-06-01T10:52:00Z"
        )

        let reply = HermesGatewayMessageResolver.newestThreadReply(
            in: [otherThread, newest, older].compactMap(\.self)
        )

        XCTAssertEqual(reply?.id, "msg_newest")
        XCTAssertEqual(reply?.text, "Latest reply")
    }

    func testHermesGatewayMessageResolverPrefersExactPendingEventReply() {
        let event = HermesGatewayQueuedEvent(id: "evt_expected", sequence: 7, targetClientId: nil)
        let unrelatedThreadReply = hermesGatewayMessage(
            id: "msg_unrelated",
            threadId: HermesGatewayMessageResolver.defaultThreadID,
            replyToEventId: "evt_other",
            text: "Not this test",
            createdAt: "2026-06-01T10:52:00Z"
        )
        let exactReply = hermesGatewayMessage(
            id: "msg_exact",
            threadId: HermesGatewayMessageResolver.defaultThreadID,
            replyToEventId: event.id,
            text: "This is the matching test reply.",
            createdAt: "2026-06-01T10:51:43.304Z"
        )

        let reply = HermesGatewayMessageResolver.newestReply(
            for: event,
            in: [unrelatedThreadReply, exactReply].compactMap(\.self),
            pendingEventSentAt: ISO8601DateFormatter().date(from: "2026-06-01T10:51:00Z")
        )

        XCTAssertEqual(reply?.id, "msg_exact")
        XCTAssertEqual(reply?.replyToEventId, event.id)
    }

    func testHermesGatewayMessageResolverFiltersRepliesByTargetClient() {
        let event = HermesGatewayQueuedEvent(id: "evt_expected", sequence: 7, targetClientId: "hgw_macbook")
        let wrongClientExactReply = hermesGatewayMessage(
            id: "msg_wrong",
            clientId: "hgw_macmini",
            threadId: HermesGatewayMessageResolver.defaultThreadID,
            replyToEventId: event.id,
            text: "Wrong Mac",
            createdAt: "2026-06-01T10:52:00Z"
        )
        let expectedReply = hermesGatewayMessage(
            id: "msg_expected",
            clientId: "hgw_macbook",
            threadId: HermesGatewayMessageResolver.defaultThreadID,
            replyToEventId: event.id,
            text: "Right Mac",
            createdAt: "2026-06-01T10:51:43.304Z"
        )

        let reply = HermesGatewayMessageResolver.newestReply(
            for: event,
            in: [wrongClientExactReply, expectedReply].compactMap(\.self),
            pendingEventSentAt: ISO8601DateFormatter().date(from: "2026-06-01T10:51:00Z")
        )

        XCTAssertEqual(reply?.id, "msg_expected")
        XCTAssertEqual(reply?.clientId, "hgw_macbook")
    }

    func testHermesGatewaySettingsStorePersistsSelectedClientAndTargetsQueuedMessages() async {
        let suiteName = "HermesGatewaySettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = ISO8601DateFormatter().string(from: Date())
        let repository = MockHermesGatewayRepository()
        repository.clients = [
            hermesGatewayClient(id: "hgw_macmini", displayName: "Mac mini Hermes", lastSeenAt: now),
            hermesGatewayClient(id: "hgw_macbook", displayName: "MacBook Pro Hermes", lastSeenAt: nil)
        ]
        let store = HermesGatewaySettingsStore(repository: repository, defaults: defaults)

        await store.refresh(isSignedIn: true)
        XCTAssertEqual(store.selectedClient?.id, "hgw_macmini")

        guard let macBook = store.activeClients.first(where: { $0.id == "hgw_macbook" }) else {
            XCTFail("Expected MacBook client fixture")
            return
        }
        store.selectClient(macBook)

        XCTAssertEqual(defaults.string(forKey: "hermesGateway.selectedClientId"), "hgw_macbook")
        XCTAssertEqual(store.selectedClient?.id, "hgw_macbook")

        let sent = await store.sendGatewayMessage(
            text: "Run this on the MacBook",
            senderDisplayName: "OpenBurnBar iPhone",
            threadId: HermesGatewayMessageResolver.defaultThreadID
        )

        XCTAssertEqual(sent?.targetClientId, "hgw_macbook")
        XCTAssertEqual(repository.enqueuedEvents.last?.targetClientId, "hgw_macbook")
        XCTAssertEqual(repository.enqueuedEvents.last?.text, "Run this on the MacBook")
    }

    func testHermesGatewaySettingsStoreBlocksUnsealedClientBeforeEnqueue() async {
        let suiteName = "HermesGatewaySettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = ISO8601DateFormatter().string(from: Date())
        let repository = MockHermesGatewayRepository()
        repository.clients = [
            hermesGatewayClient(
                id: "hgw_legacy",
                displayName: "Legacy Mac",
                lastSeenAt: now,
                canSealToAgent: false
            )
        ]
        let store = HermesGatewaySettingsStore(repository: repository, defaults: defaults)

        await store.refresh(isSignedIn: true)
        let sent = await store.sendGatewayMessage(
            text: "Do not upload plaintext",
            senderDisplayName: "OpenBurnBar iPhone",
            threadId: HermesGatewayMessageResolver.defaultThreadID
        )

        XCTAssertNil(sent)
        XCTAssertTrue(repository.enqueuedEvents.isEmpty)
        XCTAssertTrue(store.noticeText?.contains("private cloud messages") ?? false)
    }

    func testHermesGatewaySettingsStoreRepairsMissingSelectedClientToOnlineFallback() async {
        let suiteName = "HermesGatewaySettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("hgw_missing", forKey: "hermesGateway.selectedClientId")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = ISO8601DateFormatter().string(from: Date())
        let repository = MockHermesGatewayRepository()
        repository.clients = [
            hermesGatewayClient(id: "hgw_offline", displayName: "Offline Mac", lastSeenAt: nil),
            hermesGatewayClient(id: "hgw_online", displayName: "Online Mac", lastSeenAt: now)
        ]
        let store = HermesGatewaySettingsStore(repository: repository, defaults: defaults)

        await store.refresh(isSignedIn: true)

        XCTAssertEqual(store.selectedClient?.id, "hgw_online")
        XCTAssertEqual(defaults.string(forKey: "hermesGateway.selectedClientId"), "hgw_online")
    }

    func testHermesGatewaySettingsStoreRepairsSelectionAfterRevokingSelectedClient() async {
        let suiteName = "HermesGatewaySettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = ISO8601DateFormatter().string(from: Date())
        let repository = MockHermesGatewayRepository()
        repository.clients = [
            hermesGatewayClient(id: "hgw_macmini", displayName: "Mac mini Hermes", lastSeenAt: now),
            hermesGatewayClient(id: "hgw_macbook", displayName: "MacBook Pro Hermes", lastSeenAt: now)
        ]
        let store = HermesGatewaySettingsStore(repository: repository, defaults: defaults)

        await store.refresh(isSignedIn: true)
        guard let macBook = store.activeClients.first(where: { $0.id == "hgw_macbook" }) else {
            XCTFail("Expected MacBook client fixture")
            return
        }
        store.selectClient(macBook)
        await store.revoke(macBook)

        XCTAssertEqual(repository.revokedClientIds, ["hgw_macbook"])
        XCTAssertEqual(store.selectedClient?.id, "hgw_macmini")
        XCTAssertEqual(defaults.string(forKey: "hermesGateway.selectedClientId"), "hgw_macmini")
    }

    private func hermesGatewayClient(
        id: String? = nil,
        displayName: String = "Hermes Agent",
        status: String = "active",
        lastSeenAt: String?,
        canSealToAgent: Bool = true
    ) -> HermesGatewayClientRecord {
        let relayKey = canSealToAgent ? HermesRelayCrypto.generatePrivateKey().publicKeyBase64 : nil
        return HermesGatewayClientRecord(
            id: id ?? "hgw_test_\(status)_\(lastSeenAt ?? "never")",
            displayName: displayName,
            status: status,
            tokenPreview: "obb_hgw_...test",
            scopes: [
                "hermes.gateway.read",
                "hermes.gateway.write",
                "hermes.gateway.manage"
            ],
            homeDestinationId: "burnbar:home",
            lastSeenAt: lastSeenAt,
            revokedAt: nil,
            createdAt: "2026-06-01T08:00:00Z",
            updatedAt: "2026-06-01T08:00:00Z",
            schemaVersion: canSealToAgent ? 2 : 1,
            relayPublicKey: relayKey,
            relayKeyVersion: canSealToAgent ? HermesRelayCrypto.keyVersion : nil,
            relayEncryption: canSealToAgent ? HermesRelayCrypto.algorithm : nil
        )
    }

    private func hermesGatewayMessage(
        id: String,
        clientId: String = "hgw_abc",
        threadId: String?,
        replyToEventId: String? = nil,
        text: String?,
        createdAt: String
    ) -> HermesGatewayMessageRecord? {
        var data: [String: Any] = [
            "id": id,
            "clientId": clientId,
            "kind": "agent_message",
            "destinationId": "burnbar:home",
            "text": text as Any,
            "attachmentIds": [],
            "createdAt": createdAt,
            "schemaVersion": 1
        ]
        data["threadId"] = threadId
        data["replyToEventId"] = replyToEventId
        return HermesGatewayMessageRecord(documentID: id, data: data)
    }

    func testTokenUsageCodable() throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "sess-1",
            projectName: "Test",
            model: "claude-3",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 0.01,
            startTime: Date(),
            endTime: Date()
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded.provider, usage.provider)
        XCTAssertEqual(decoded.totalTokens, 150)
        XCTAssertEqual(decoded.cost, 0.01)
    }

    func testRemoteUnlockCredentialStoreKeyPrefersStableRecipientKey() {
        let state = makeRemoteUnlockState(credentialRecipientKeyId: " recipient-key-1 ")

        let key = RemoteUnlockCredentialStoreKey.make(
            state: state,
            phoneControlConnectionID: "control-route-older",
            mirrorConnectionID: "mirror-route-newer",
            mirrorRequestID: "request-1"
        )

        XCTAssertEqual(key, "recipient-key-1")
    }

    func testRemoteUnlockCredentialStoreKeyFallsBackToConnectionIdentifiers() {
        XCTAssertEqual(
            RemoteUnlockCredentialStoreKey.make(
                state: nil,
                phoneControlConnectionID: " control-route ",
                mirrorConnectionID: "mirror-route",
                mirrorRequestID: "request-1"
            ),
            "control-route"
        )
        XCTAssertEqual(
            RemoteUnlockCredentialStoreKey.make(
                state: nil,
                phoneControlConnectionID: " ",
                mirrorConnectionID: " mirror-route ",
                mirrorRequestID: "request-1"
            ),
            "mirror-route"
        )
        XCTAssertEqual(
            RemoteUnlockCredentialStoreKey.make(
                state: nil,
                phoneControlConnectionID: nil,
                mirrorConnectionID: " ",
                mirrorRequestID: " request-1 "
            ),
            "request-1"
        )
    }

    func testRemoteUnlockCredentialSenderIsAlwaysRebuilt() {
        XCTAssertFalse(
            RemoteUnlockCredentialSenderReusePolicy.shouldReuseExistingSender(
                phoneControlConnectionID: "same-control-route",
                currentConnectionID: "same-control-route"
            )
        )
        XCTAssertFalse(
            RemoteUnlockCredentialSenderReusePolicy.shouldReuseExistingSender(
                phoneControlConnectionID: nil,
                currentConnectionID: "new-control-route"
            )
        )
    }

    func testMercuryReceiverInstallIsRetainedByRelayTransport() {
        let transport = HermesIrohRelayTransport(
            directory: InMemoryIrohPairingDirectory(),
            pairingPublicKeyProvider: MobileFakeIrohPairingPublicKeyProvider(),
            auditLogger: MobileNoopIrohTransportAuditLogger(),
            transportFactory: { _ in MobileNoopIrohRelayTransport() }
        )

        do {
            let receiver = iOSFileTransferService(
                service: MediaFileTransferService(
                    backend: MobileFakeIrohBlobBackend(),
                    configuration: MediaFileTransferService.Configuration(
                        storeDirectoryURL: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true),
                        inboxDirectoryURL: FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true),
                        secretKeyProvider: { Data(repeating: 0x7, count: 32) }
                    )
                ),
                settingsProvider: { true }
            )
            transport.installMediaControlStream(into: receiver)
        }

        XCTAssertTrue(transport.isMediaControlReceiverInstalledForTesting)
    }

    func testMercuryReceiverCanInstallWithoutBlobBackend() async throws {
        let receiver = iOSFileTransferService(service: nil, settingsProvider: { true })

        do {
            _ = try await receiver.bootstrapBlobEndpoint()
            XCTFail("Expected backendUnavailable")
        } catch {
            guard case iOSFileTransferService.Failure.backendUnavailable = error else {
                return XCTFail("Expected backendUnavailable, got \(error)")
            }
        }

        let transport = HermesIrohRelayTransport(
            directory: InMemoryIrohPairingDirectory(),
            pairingPublicKeyProvider: MobileFakeIrohPairingPublicKeyProvider(),
            auditLogger: MobileNoopIrohTransportAuditLogger(),
            transportFactory: { _ in MobileNoopIrohRelayTransport() }
        )
        transport.installMediaControlStream(into: receiver)

        XCTAssertTrue(transport.isMediaControlReceiverInstalledForTesting)
    }

    func testMobileRootSettingsNotificationRouteIsInstalled() throws {
        let rootTab = try sourceFile("OpenBurnBarMobile/Views/RootTabView.swift")
        let rootNavigation = try sourceFile("OpenBurnBarMobile/Views/RootNavigationView.swift")

        XCTAssertTrue(rootTab.contains(#".init("ShowSettings")"#))
        XCTAssertTrue(rootTab.contains("openSettingsRoute()"))
        XCTAssertTrue(rootTab.contains("youPath.append(YouRoute.settings)"))
        XCTAssertTrue(rootNavigation.contains(#".init("ShowSettings")"#))
        XCTAssertTrue(rootNavigation.contains("openSettingsRoute()"))
        XCTAssertTrue(rootNavigation.contains("selection = .settings"))
    }

    func testWallpaperSettingsActionDoesNotOpenAppSettingsFallback() throws {
        XCTAssertEqual(WallpaperSettingsDeepLink.wallpaperSettingsURL.absoluteString, "App-prefs:Wallpaper")
        XCTAssertEqual(WallpaperSettingsDeepLink.settingsRootURL.absoluteString, "App-prefs:")

        let generator = try sourceFile("OpenBurnBarMobile/Views/Aurora/WallpaperGeneratorView.swift")
        let actionStart = try XCTUnwrap(generator.range(of: "private func openSettingsWallpaper()"))
        let actionAndRest = generator[actionStart.lowerBound...]
        let actionEnd = try XCTUnwrap(actionAndRest.range(of: "private func openPhotosApp()"))
        let actionBody = String(actionAndRest[..<actionEnd.lowerBound])

        XCTAssertFalse(generator.contains("App-prefs:root=Wallpaper"))
        XCTAssertFalse(actionBody.contains("UIApplication.openSettingsURLString"))
        XCTAssertTrue(actionBody.contains("WallpaperSettingsDeepLink.open()"))
    }

    func testLiveWallpaperExportUsesWallpaperReadyLivePhotoShape() throws {
        let generator = try sourceFile("OpenBurnBarMobile/Views/Aurora/WallpaperGeneratorView.swift")

        XCTAssertTrue(generator.contains("let livePhotoDurationSeconds: Int32 = 3"))
        XCTAssertTrue(generator.contains("let keyPhotoFrameIndex = frameCount / 2"))
        XCTAssertTrue(generator.contains("CMTimeRange(start: keyPhotoTime, duration: frameDuration)"))
        XCTAssertTrue(generator.contains("imageOptions.uniformTypeIdentifier = UTType.jpeg.identifier"))
        XCTAssertTrue(generator.contains("videoOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier"))
    }

    func testLiveCloudReaderUsesMacLastSeenHeartbeatAsActivityDate() throws {
        let lastSeen = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_000_000)

        let activity = CloudDeviceActivityDateResolver.date(from: [
            "lastSeenAt": Timestamp(date: lastSeen),
            "updatedAt": Timestamp(date: updated)
        ])

        let unwrappedActivity = try XCTUnwrap(activity)
        XCTAssertEqual(unwrappedActivity.timeIntervalSince1970, lastSeen.timeIntervalSince1970, accuracy: 0.001)
    }

    func testLiveCloudReaderBuildsSyncStatusSnapshotFromLatestStatusDoc() throws {
        let readAt = Date(timeIntervalSince1970: 1_800_000_500)
        let lastSync = Date(timeIntervalSince1970: 1_800_000_000)

        let snapshot = LiveCloudReader.syncStatusSnapshot(
            deviceID: "23AA015D-B6C5-434C-8EBA-E33B8B8E4AAA",
            displayName: "Mac",
            data: [
                "lastSyncAt": Timestamp(date: lastSync)
            ],
            readAt: readAt
        )

        let publishedAt = try XCTUnwrap(snapshot.lastPublishedAt)
        let lastReadAt = try XCTUnwrap(snapshot.lastReadAt)
        XCTAssertEqual(publishedAt.timeIntervalSince1970, lastSync.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(lastReadAt.timeIntervalSince1970, readAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.publisher?.deviceID, "23AA015D-B6C5-434C-8EBA-E33B8B8E4AAA")
        XCTAssertEqual(snapshot.publisher?.displayName, "Mac")
        XCTAssertNil(snapshot.lastErrorClassification)
    }

    func testLiveCloudReaderCarriesSyncStatusErrorClassification() {
        let snapshot = LiveCloudReader.syncStatusSnapshot(
            deviceID: "mac-1",
            displayName: "Mac",
            data: [
                "lastError": "writer failed"
            ],
            readAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(snapshot.lastErrorClassification, .other(message: "writer failed"))
    }

    // MARK: - Stream Session Projection

    func testActivityStoreSummarizesRawUsageRowsBySession() throws {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let kimiRows = (0..<40).map { index in
            makeUsage(
                provider: .kimi,
                sessionId: "kimi-flood",
                model: index < 30 ? "kimi-for-coding" : "kimi-auditor",
                inputTokens: 100 + index,
                outputTokens: 50,
                costUSD: 1,
                startTime: now.addingTimeInterval(Double(index) * 30),
                endTime: now.addingTimeInterval(Double(index) * 30 + 20)
            )
        }
        let codex = makeUsage(
            provider: .codex,
            sessionId: "codex-visible",
            model: "gpt-5.4-codex",
            inputTokens: 500,
            outputTokens: 250,
            costUSD: 2.5,
            startTime: now.addingTimeInterval(2_000),
            endTime: now.addingTimeInterval(2_200)
        )

        let summaries = ActivityStore.summarizeSessions(kimiRows + [codex])

        XCTAssertEqual(summaries.map(\.sessionId), ["codex-visible", "kimi-flood"])
        let kimi = try XCTUnwrap(summaries.first { $0.sessionId == "kimi-flood" })
        XCTAssertEqual(kimi.cost, 40, accuracy: 0.0001)
        XCTAssertEqual(kimi.inputTokens, kimiRows.reduce(0) { $0 + $1.inputTokens })
        XCTAssertEqual(kimi.outputTokens, 2_000)
        XCTAssertEqual(kimi.totalTokens, kimi.inputTokens + kimi.outputTokens)
        XCTAssertEqual(kimi.model, "kimi-for-coding")
        XCTAssertEqual(kimi.startTime, kimiRows.first?.startTime)
        XCTAssertEqual(kimi.endTime, kimiRows.last?.endTime)
    }

    func testActivityStoreDoesNotCollapseBlankSessionIds() {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let rows = [
            makeUsage(provider: .factory, sessionId: "", model: "factory-a", startTime: now, endTime: now),
            makeUsage(provider: .factory, sessionId: "  ", model: "factory-b", startTime: now, endTime: now)
        ]

        let summaries = ActivityStore.summarizeSessions(rows)

        XCTAssertEqual(summaries.count, 2)
    }

    func testActivityStoreSortsSummariesByLatestActivity() {
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let older = makeUsage(
            provider: .claudeCode,
            sessionId: "older",
            model: "claude",
            startTime: now,
            endTime: now.addingTimeInterval(10)
        )
        let newer = makeUsage(
            provider: .factory,
            sessionId: "newer",
            model: "factory",
            startTime: now.addingTimeInterval(100),
            endTime: now.addingTimeInterval(120)
        )

        let summaries = ActivityStore.summarizeSessions([older, newer])

        XCTAssertEqual(summaries.map(\.sessionId), ["newer", "older"])
    }

    func testStreamsSearchStatePrefersEncryptedCloudHits() {
        let state = StreamsSearchResultState(
            query: " session cache ",
            isSearching: false,
            cloudConversationHitCount: 2,
            streamHitCount: 4
        )

        XCTAssertEqual(state.mode, .cloudConversationHits)
    }

    func testStreamsSearchStateFallsBackToLegacyStreamHits() {
        let state = StreamsSearchResultState(
            query: "session cache",
            isSearching: false,
            cloudConversationHitCount: 0,
            streamHitCount: 3
        )

        XCTAssertEqual(state.mode, .streamHits)
    }

    func testStreamsSearchStateShowsSearchingBeforeEmpty() {
        let state = StreamsSearchResultState(
            query: "session cache",
            isSearching: true,
            cloudConversationHitCount: 0,
            streamHitCount: 0
        )

        XCTAssertEqual(state.mode, .searching)
    }

    func testStreamsSearchStateRequiresTwoCharactersForRemoteSearch() {
        let state = StreamsSearchResultState(
            query: "s",
            isSearching: true,
            cloudConversationHitCount: 0,
            streamHitCount: 0
        )

        XCTAssertEqual(state.mode, .inactive)
    }

    func testCloudConversationRowsResolveProviderLogosFromCloudProviderStrings() {
        let claude = makeCloudSearchRow(id: "claude", provider: "Claude Code")
        let forge = makeCloudSearchRow(id: "forge", provider: "forge")

        XCTAssertEqual(claude.providerEnum, .claudeCode)
        XCTAssertEqual(forge.providerEnum, .forgeDev)
    }

    func testCloudConversationSearchRerankerPromotesExactDecryptedMatches() {
        let exact = makeCloudSearchRow(
            id: "exact",
            title: "X Ads API launch notes",
            snippet: "Build reporting for the campaign endpoint.",
            score: 0.22,
            tokenScore: 0.55,
            semanticScore: 0.35,
            matchKind: "hybrid"
        )
        let semantic = makeCloudSearchRow(
            id: "semantic",
            title: "Twitter advertising endpoint migration",
            snippet: "Campaign reporting integration work.",
            score: 0.44,
            tokenScore: 0.10,
            semanticScore: 1.0,
            matchKind: "semantic"
        )
        let weakToken = makeCloudSearchRow(
            id: "weak-token",
            title: "Node 22 runtime upgrade and TypeScript migration",
            snippet: "Current repo facts mention api once.",
            score: 0.50,
            tokenScore: 0.20,
            semanticScore: 0.0,
            matchKind: "token"
        )

        let ranked = ActivityStore.rankCloudConversationRows([weakToken, semantic, exact], query: "x ads api")

        XCTAssertEqual(ranked.map(\.id).first, "exact")
        XCTAssertLessThan(ranked.firstIndex(of: semantic) ?? Int.max, ranked.firstIndex(of: weakToken) ?? Int.max)
    }

    func testCloudTranscriptCacheDefaultsTo250Megabytes() {
        let suite = "cloud-transcript-cache-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defer { defaults?.removePersistentDomain(forName: suite) }

        let settings = CloudTranscriptCacheSettings(defaultsSuiteName: suite)

        XCTAssertEqual(settings.maxMegabytes, 250)
        XCTAssertEqual(settings.maxBytes, 250 * 1_024 * 1_024)

        settings.maxMegabytes = 500
        XCTAssertEqual(settings.maxMegabytes, 500)

        settings.maxMegabytes = -20
        XCTAssertEqual(settings.maxMegabytes, 0)

        settings.maxMegabytes = 9_999
        XCTAssertEqual(settings.maxMegabytes, CloudTranscriptCacheSettings.maximumMegabytes)
    }

    func testCloudTranscriptCacheStoresEncryptedTranscript() async throws {
        let suite = "cloud-transcript-cache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defer { defaults?.removePersistentDomain(forName: suite) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-transcript-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = CloudTranscriptCacheSettings(defaultsSuiteName: suite)
        settings.maxMegabytes = 1
        let cache = CloudTranscriptCache(directory: directory, settings: settings)
        let vaultKey = Data(repeating: 7, count: 32)
        let transcript = "session body with private prompt text"
        let bodyHash = CloudVaultCrypto.sha256Hex(transcript)
        let storagePath = "users/test-user/session_logs/test-doc/bodies/\(bodyHash).json.aesgcm"

        try await cache.storeTranscript(transcript, storagePath: storagePath, bodyHash: bodyHash, vaultKey: vaultKey)
        let loaded = await cache.cachedTranscript(storagePath: storagePath, bodyHash: bodyHash, vaultKey: vaultKey)

        XCTAssertEqual(loaded, transcript)
        let cacheFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != "index.json" }
        XCTAssertEqual(cacheFiles.count, 1)
        let cachedPayload = try String(contentsOf: cacheFiles[0], encoding: .utf8)
        XCTAssertFalse(cachedPayload.contains(transcript))
    }

    func testCloudTranscriptCacheCanBeDisabled() async throws {
        let suite = "cloud-transcript-cache-disabled-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defer { defaults?.removePersistentDomain(forName: suite) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-transcript-cache-disabled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = CloudTranscriptCacheSettings(defaultsSuiteName: suite)
        settings.maxMegabytes = 0
        let cache = CloudTranscriptCache(directory: directory, settings: settings)
        let vaultKey = Data(repeating: 8, count: 32)
        let transcript = "do not cache this body"
        let bodyHash = CloudVaultCrypto.sha256Hex(transcript)
        let storagePath = "users/test-user/session_logs/test-doc/bodies/\(bodyHash).json.aesgcm"

        try await cache.storeTranscript(transcript, storagePath: storagePath, bodyHash: bodyHash, vaultKey: vaultKey)

        let loaded = await cache.cachedTranscript(storagePath: storagePath, bodyHash: bodyHash, vaultKey: vaultKey)
        let snapshot = await cache.snapshot()
        XCTAssertNil(loaded)
        XCTAssertTrue(snapshot.isDisabled)
        XCTAssertEqual(snapshot.usageBytes, 0)
    }

    func testProviderQuotaBucketProgress() {
        let bucket = ProviderQuotaBucket(
            name: "Tokens",
            used: 75,
            limit: 100,
            remaining: 25,
            window: "monthly"
        )
        XCTAssertEqual(bucket.used / bucket.limit, 0.75, accuracy: 0.001)
        XCTAssertEqual((bucket.remaining / bucket.limit) * 100, 25, accuracy: 0.001)
    }

    func testUsageRollupDocCodable() throws {
        let doc = UsageRollupDoc(
            windowKey: .today,
            totals: RollupTotals(requests: 10, tokens: 1000, costUsd: 0.50),
            providerSummaries: [
                RollupProviderSummary(provider: "minimax", totalRequests: 5, totalTokens: 500)
            ],
            modelSummaries: [],
            deviceSummaries: [],
            dailyPoints: [RollupDailyPoint(date: Date(), value: 1000)],
            computedAt: Date(),
            schemaVersion: 1
        )
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(UsageRollupDoc.self, from: data)
        XCTAssertEqual(decoded.windowKey, .today)
        XCTAssertEqual(decoded.totals.tokens, 1000)
    }

    // MARK: - Computer Use Agent Watch

    func testAgentWatchOverlayCoordinatorClassifiesApprovalStreamAndResponds() async throws {
        let uid = "user-agent-watch"
        let connectionID = "relay-connection-1"
        let stream = AgentWatchFakeStream()
        let authorityPublisher = AgentWatchFakeAuthorityPublisher()
        let coordinator = AgentWatchOverlayCoordinator(
            dialer: { dialedUID, dialedConnectionID, relayPublicKey in
                XCTAssertEqual(dialedUID, uid)
                XCTAssertEqual(dialedConnectionID, connectionID)
                XCTAssertEqual(relayPublicKey, Data(repeating: 7, count: 32))
                return stream
            },
            signingKeyStore: AgentWatchFakeSigningKeyStore(),
            authorityPublisher: authorityPublisher,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        defer {
            Task { await coordinator.stop() }
        }

        coordinator.start(
            uid: uid,
            connectionID: connectionID,
            relayPublicKey: Data(repeating: 7, count: 32)
        )

        let classifyFrame = try await waitForFrame(
            from: stream,
            matching: { $0.type == .controlClassify }
        )
        XCTAssertEqual(classifyFrame.uid, uid)
        XCTAssertEqual(classifyFrame.connectionId, connectionID)
        XCTAssertEqual(classifyFrame.control?.streamClass, MediaStreamClass.controlInput.rawValue)
        XCTAssertNotNil(classifyFrame.control?.authorityPeerNodeId)
        XCTAssertNil(classifyFrame.control?.authorityPublicKeyBase64)
        let publishedAuthorities = await authorityPublisher.published()
        XCTAssertEqual(publishedAuthorities.count, 1)
        XCTAssertEqual(publishedAuthorities.first?.uid, uid)
        XCTAssertEqual(publishedAuthorities.first?.connectionId, connectionID)
        XCTAssertEqual(publishedAuthorities.first?.peerNodeId, classifyFrame.control?.authorityPeerNodeId)

        let approval = HermesRealtimeRelayApprovalRequest(
            approvalId: "approval-1",
            runId: "run-1",
            sessionId: "session-1",
            toolKind: "mac.input.click",
            title: "Approve click",
            message: "Click Submit",
            beforeScreenshotBlake3: "abc123",
            actionSummary: "Click Submit",
            requestedAt: Date(timeIntervalSince1970: 1_000)
        )
        await stream.pushInbound(HermesRealtimeRelayFrame(
            type: .controlApprovalRequest,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlApproval.rawValue,
                sessionId: approval.sessionId,
                approvalRequest: approval
            )
        ))

        try await waitForCondition {
            coordinator.state.pendingApproval?.approvalId == approval.approvalId
        }
        XCTAssertEqual(coordinator.state.sessionId?.rawValue, approval.sessionId)

        try await coordinator.receiver?.approve(approval)

        let responseFrame = try await waitForFrame(
            from: stream,
            matching: { $0.type == .controlApprovalResponse }
        )
        XCTAssertEqual(responseFrame.uid, uid)
        XCTAssertEqual(responseFrame.connectionId, connectionID)
        XCTAssertEqual(responseFrame.control?.streamClass, MediaStreamClass.controlApproval.rawValue)
        XCTAssertEqual(responseFrame.control?.sessionId, approval.sessionId)
        XCTAssertEqual(responseFrame.control?.approvalResponse?.approvalId, approval.approvalId)
        XCTAssertEqual(responseFrame.control?.approvalResponse?.decision, .approve)
        XCTAssertNil(coordinator.state.pendingApproval)
    }

    func testAgentWatchLoopbackReflectsTenActionLogEntriesInOrder() async throws {
        let uid = "user-agent-watch-loopback"
        let connectionID = "relay-connection-loopback"
        let sessionID = "session-loopback"
        let stream = AgentWatchFakeStream()
        let coordinator = AgentWatchOverlayCoordinator(
            dialer: { _, _, _ in stream },
            signingKeyStore: AgentWatchFakeSigningKeyStore(),
            authorityPublisher: AgentWatchFakeAuthorityPublisher(),
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        defer {
            Task { await coordinator.stop() }
        }

        coordinator.start(
            uid: uid,
            connectionID: connectionID,
            relayPublicKey: Data(repeating: 8, count: 32)
        )
        _ = try await waitForFrame(from: stream) { $0.type == .controlClassify }

        await stream.pushInbound(HermesRealtimeRelayFrame(
            type: .controlClassify,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: sessionID
            )
        ))
        try await waitForCondition {
            coordinator.state.sessionId?.rawValue == sessionID
        }

        for index in 0..<10 {
            await stream.pushInbound(actionLogFrame(
                uid: uid,
                connectionID: connectionID,
                sessionID: sessionID,
                index: index
            ))
        }
        try await waitForCondition(timeout: 2) {
            coordinator.state.actionTimeline.count == 10
        }

        XCTAssertEqual(coordinator.state.actionTimeline.map(\.entryIndex), Array(0..<10))
        XCTAssertEqual(coordinator.state.actionTimeline.map(\.summary), (0..<10).map { "Fake agent action \($0)" })
        XCTAssertEqual(coordinator.state.actionsExecuted, 10)
    }

    func testAgentWatchReceiverSendsSignedTapAndScrollIntents() async throws {
        let uid = "user-agent-watch-input"
        let connectionID = "relay-connection-input"
        let stream = AgentWatchFakeStream()
        let coordinator = AgentWatchOverlayCoordinator(
            dialer: { _, _, _ in stream },
            signingKeyStore: AgentWatchFakeSigningKeyStore(),
            authorityPublisher: AgentWatchFakeAuthorityPublisher(),
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        defer {
            Task { await coordinator.stop() }
        }

        coordinator.start(
            uid: uid,
            connectionID: connectionID,
            relayPublicKey: Data(repeating: 9, count: 32)
        )
        _ = try await waitForFrame(from: stream) { $0.type == .controlClassify }

        try await coordinator.receiver?.tap(normalizedX: 0.25, normalizedY: 0.75, mouseButton: 1)
        let tapFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .tap
        }
        let tapIntent = try XCTUnwrap(tapFrame.control?.inputIntent)
        XCTAssertEqual(try XCTUnwrap(tapIntent.normalizedX), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(tapIntent.normalizedY), 0.75, accuracy: 0.0001)
        XCTAssertEqual(tapIntent.mouseButton, 1)
        XCTAssertFalse(tapIntent.authority.peerNodeId.isEmpty)
        XCTAssertFalse(tapIntent.authority.signatureEd25519.isEmpty)

        try await coordinator.receiver?.scrollDrag(
            startNormalizedX: 0.40,
            startNormalizedY: 0.45,
            endNormalizedX: 0.40,
            endNormalizedY: 0.20
        )
        let scrollFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .scroll
        }
        let scrollIntent = try XCTUnwrap(scrollFrame.control?.inputIntent)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedX), 0.40, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedY), 0.45, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedX2), 0.40, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(scrollIntent.normalizedY2), 0.20, accuracy: 0.0001)
        XCTAssertEqual(scrollIntent.authority.counter, tapIntent.authority.counter + 1)
        XCTAssertFalse(scrollIntent.authority.signatureEd25519.isEmpty)

        try await coordinator.receiver?.type("hello from iphone")
        let typeFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .type
        }
        let typeIntent = try XCTUnwrap(typeFrame.control?.inputIntent)
        XCTAssertEqual(typeIntent.text, "hello from iphone")
        XCTAssertEqual(typeIntent.authority.counter, scrollIntent.authority.counter + 1)
        XCTAssertFalse(typeIntent.authority.signatureEd25519.isEmpty)

        try await coordinator.receiver?.pointerClick(mouseButton: 1)
        let pointerClickFrame = try await waitForFrame(from: stream) {
            $0.type == .controlInputIntent &&
            $0.control?.inputIntent?.kind == .pointerClick
        }
        let pointerClickIntent = try XCTUnwrap(pointerClickFrame.control?.inputIntent)
        XCTAssertEqual(pointerClickIntent.mouseButton, 1)
        XCTAssertEqual(pointerClickIntent.authority.counter, typeIntent.authority.counter + 1)
        XCTAssertFalse(pointerClickIntent.authority.signatureEd25519.isEmpty)
    }

    func testPhoneControlSenderSerializesConcurrentInputIntentsBeforeWritingFrames() async throws {
        let suiteName = "PhoneControlSenderSerializes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = Curve25519SigningKey(privateKey: Curve25519.Signing.PrivateKey())
        let firstFrameGate = MobileAsyncGate()
        let recorder = PhoneControlFrameOrderRecorder()
        let sender = PhoneControlSender(
            peerNodeId: "ios-phone-glass-trackpad-test",
            uid: "user-glass-trackpad-test",
            connectionId: "relay-glass-trackpad-test",
            signingKeyProvider: { key },
            userDefaults: defaults,
            frameSink: { frame in
                guard let counter = frame.control?.inputIntent?.authority.counter else {
                    return
                }
                await recorder.recordStarted(counter)
                if counter == 1 {
                    await firstFrameGate.wait()
                }
                await recorder.recordFinished(counter)
            }
        )
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: .pointerMove,
            normalizedX2: 12,
            normalizedY2: -7,
            authority: placeholder
        )

        let firstSend = Task { try await sender.send(intent: intent) }
        await recorder.waitForStarted(counter: 1)

        let secondSend = Task { try await sender.send(intent: intent) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let finishedBeforeGateOpen = await recorder.finishedCounters()
        XCTAssertEqual(
            finishedBeforeGateOpen,
            [],
            "A later Glass Trackpad intent must not pass a stalled earlier counter."
        )

        await firstFrameGate.open()
        let firstAuthority = try await firstSend.value
        let secondAuthority = try await secondSend.value

        XCTAssertEqual(firstAuthority.counter, 1)
        XCTAssertEqual(secondAuthority.counter, 2)
        let finishedAfterGateOpen = await recorder.finishedCounters()
        XCTAssertEqual(finishedAfterGateOpen, [1, 2])
    }

    func testPhoneControlSenderCancelsQueuedIntentBeforeItWritesAFrame() async throws {
        let suiteName = "PhoneControlSenderCancellation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = Curve25519SigningKey(privateKey: Curve25519.Signing.PrivateKey())
        let firstFrameGate = MobileAsyncGate()
        let recorder = PhoneControlFrameOrderRecorder()
        let sender = PhoneControlSender(
            peerNodeId: "ios-phone-cancelled-trackpad-test",
            uid: "user-cancelled-trackpad-test",
            connectionId: "relay-cancelled-trackpad-test",
            signingKeyProvider: { key },
            userDefaults: defaults,
            frameSink: { frame in
                guard let counter = frame.control?.inputIntent?.authority.counter else {
                    return
                }
                await recorder.recordStarted(counter)
                if counter == 1 {
                    await firstFrameGate.wait()
                }
                await recorder.recordFinished(counter)
            }
        )
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: .pointerMove,
            normalizedX2: 8,
            normalizedY2: 3,
            authority: placeholder
        )

        let firstSend = Task { try await sender.send(intent: intent) }
        await recorder.waitForStarted(counter: 1)

        let secondSend = Task { try await sender.send(intent: intent) }
        secondSend.cancel()

        await firstFrameGate.open()
        _ = try await firstSend.value

        do {
            _ = try await secondSend.value
            XCTFail("Expected the queued Glass Trackpad intent to honor caller cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        let startedCounters = await recorder.startedCounterValues()
        XCTAssertEqual(startedCounters, [1])
        XCTAssertEqual(defaults.object(forKey: "openburnbar.phoneControl.counter.ios-phone-cancelled-trackpad-test") as? Int, 1)
    }

    func testPhoneControlCounterAllocationIsProcessWideAcrossConcurrentCallers() async throws {
        let suiteName = "PhoneControlCounterGlobal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let peerNodeId = "ios-phone-global-counter-test"
        let count = 200
        let counters = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for _ in 0..<count {
                group.addTask {
                    PhoneControlSender.nextCounter(peerNodeId: peerNodeId, userDefaults: defaults)
                }
            }
            var collected: [UInt64] = []
            for await counter in group {
                collected.append(counter)
            }
            return collected
        }

        XCTAssertEqual(Set(counters).count, count)
        XCTAssertEqual(counters.sorted(), Array(UInt64(1)...UInt64(count)))
    }

    // MARK: - Formatting

    func testCostFormatting() {
        XCTAssertEqual(1.5.formatAsCost(), "$1.50")
        XCTAssertEqual(0.0.formatAsCost(), "$0.00")
        XCTAssertEqual(1234.5.formatAsCost(), "$1,234.50")
        XCTAssertEqual(1_500_000.0.formatAsCost(), "$1,500,000.00")
    }

    func testCostCompactFormatting() {
        XCTAssertEqual(1.5.formatAsCostCompact(), "$1.50")
        XCTAssertEqual(1234.5.formatAsCostCompact(), "$1,234.50")
    }

    func testTokenFormatting() {
        XCTAssertEqual(1500.formatAsTokens(), "1.5K")
        XCTAssertEqual(1_500_000.formatAsTokens(), "1.5M")
        XCTAssertEqual(1_500_000_000.formatAsTokens(), "1.50B")
        XCTAssertEqual(500.formatAsTokens(), "500")
        XCTAssertEqual(1234.formatAsTokens(), "1.2K")
    }

    func testTokenRawFormatting() {
        XCTAssertEqual(500.formatAsTokensRaw(), "500")
        XCTAssertEqual(1234.formatAsTokensRaw(), "1,234")
        XCTAssertEqual(1_500_000.formatAsTokensRaw(), "1,500,000")
    }

    // MARK: - Provider Connection Types

    func testProviderConnectionStatusRawValue() {
        XCTAssertEqual(ProviderConnectionStatus.connected.rawValue, "connected")
        XCTAssertEqual(ProviderConnectionStatus.error.rawValue, "error")
    }

    func testMobileDeviceIdentityPersistsGeneratedDeviceId() throws {
        let suiteName = "com.openburnbar.mobile.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removeObject(forKey: MobileDeviceIdentity.deviceIDKey)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        let first = MobileDeviceIdentity.loadOrCreateDeviceId(defaults: defaults)
        let second = MobileDeviceIdentity.loadOrCreateDeviceId(defaults: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(defaults.string(forKey: MobileDeviceIdentity.deviceIDKey), first)
    }

    // MARK: - Self-hosted Runner Delete Cleanup

    func testSelfHostedRunnerStoreDeleteRemovesURLAndSecret() throws {
        let suiteName = "OpenBurnBarMobileTests.selfHosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secrets = MobileFakeSelfHostedQuotaRunnerSecrets()
        let store = SelfHostedQuotaRunnerStore(defaults: defaults, secrets: secrets)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try store.save(accountID: "cleanup-test", runnerURL: "https://runner.example.com", accessSecret: "secret123")
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("https://runner.example.com"))
        XCTAssertEqual(secrets.savedByAccount["cleanup-test"], "secret123")

        store.delete(accountID: "cleanup-test")
        XCTAssertNil(defaults.string(forKey: "selfHostedQuotaRunnerURL.cleanup-test"))
        XCTAssertNil(secrets.savedByAccount["cleanup-test"])
    }

    // MARK: - Self-hosted Runner URL Validation

    func testValidatedRunnerURLAcceptsHTTPS() {
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("https://runner.example.com"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("  https://runner.example.com/path  "))
    }

    func testValidatedRunnerURLAcceptsLocalhost() {
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://localhost:8080"))
        XCTAssertNotNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://127.0.0.1:3000"))
    }

    func testValidatedRunnerURLRejectsInvalidSchemes() {
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("ftp://runner.example.com"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("http://192.168.1.1"))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL(""))
        XCTAssertNil(SelfHostedQuotaRunnerStore.validatedRunnerURL("not-a-url"))
    }

    private func actionLogFrame(
        uid: String,
        connectionID: String,
        sessionID: String,
        index: Int
    ) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .controlActionLogEntry,
            uid: uid,
            connectionId: connectionID,
            control: HermesRealtimeRelayControlPayload(
                streamClass: MediaStreamClass.controlActionLog.rawValue,
                sessionId: sessionID,
                actionLogEntry: HermesRealtimeRelayActionLogEntry(
                    entryIndex: index,
                    gopOrdinal: UInt32(index),
                    timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                    actionKind: "browser.click",
                    summary: "Fake agent action \(index)",
                    status: .completed,
                    screenshotHashBlake3: "shot-\(index)",
                    parentEntryBlake3: "head-\(index)"
                )
            )
        )
    }

    private func waitForFrame(
        from stream: AgentWatchFakeStream,
        matching predicate: @escaping (HermesRealtimeRelayFrame) -> Bool,
        timeout: TimeInterval = 2
    ) async throws -> HermesRealtimeRelayFrame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = await stream.sentFrames().first(where: predicate) {
                return frame
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Agent Watch frame")
        throw NSError(domain: "AgentWatchOverlayCoordinatorTests", code: 1)
    }

    private func waitForCondition(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Agent Watch condition")
        throw NSError(domain: "AgentWatchOverlayCoordinatorTests", code: 2)
    }

    private func makeRemoteUnlockState(
        credentialRecipientKeyId: String?
    ) -> HermesRealtimeRelayRemoteUnlockState {
        HermesRealtimeRelayRemoteUnlockState(
            sessionId: "unlock-session-1",
            lockState: .loginWindow,
            backend: .appleScreenSharingLoopback,
            capabilities: HermesRealtimeRelayRemoteUnlockCapabilities(
                enabled: true,
                certificationStatus: .certified,
                activeBackend: .appleScreenSharingLoopback,
                supportedBackends: [.appleScreenSharingLoopback],
                supportedLockStates: [.loginWindow],
                allowsCredentialPaste: true,
                allowsSavedCredentialUnlock: true,
                credentialRecipientKeyId: credentialRecipientKeyId,
                credentialRecipientPublicKeyBase64: "recipient-public-key",
                credentialEnvelopeAlgorithm: RemoteUnlockPolicy.credentialEnvelopeAlgorithm
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        let fileManager = FileManager.default
        while root.path != "/" {
            let project = root.appendingPathComponent("OpenBurnBar.xcodeproj")
            if fileManager.fileExists(atPath: project.path) {
                let url = root.appendingPathComponent(relativePath)
                return try String(contentsOf: url, encoding: .utf8)
            }
            root.deleteLastPathComponent()
        }
        throw NSError(domain: "OpenBurnBarMobileTests", code: 1)
    }

    private func makeCloudSearchRow(
        id: String,
        title: String = "Encrypted result",
        snippet: String = "Search snippet",
        provider: String? = "Claude Code",
        score: Double = 0.25,
        tokenScore: Double? = nil,
        semanticScore: Double? = nil,
        matchKind: String? = nil
    ) -> CloudConversationSearchRow {
        CloudConversationSearchRow(
            id: id,
            title: title,
            snippet: snippet,
            provider: provider,
            storagePath: "users/test-user/session_logs/\(id)/bodies/hash.json.aesgcm",
            bodyHash: String(repeating: "a", count: 64),
            score: score,
            tokenScore: tokenScore,
            semanticScore: semanticScore,
            matchKind: matchKind
        )
    }

    private func makeUsage(
        provider: AgentProvider,
        sessionId: String,
        model: String,
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        costUSD: Double = 1,
        startTime: Date,
        endTime: Date
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: "Project",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            startTime: startTime,
            endTime: endTime
        )
    }
}

@MainActor
private final class MockHermesGatewayRepository: HermesGatewayRepository {
    struct EnqueuedEvent: Equatable {
        let text: String
        let threadId: String
        let targetClientId: String?
        let senderDisplayName: String
        let sealedToAgent: Bool
    }

    struct EnqueuedModelSwitch: Equatable {
        let modelId: String
        let threadId: String
        let targetClientId: String?
        let senderDisplayName: String
        let sealedToAgent: Bool
    }

    struct ApprovalGrant: Equatable {
        let userCode: String
        let relayPublicKey: String?
        let relayKeyVersion: Int?
        let relayEncryption: String?
    }

    struct OversightModeChange: Equatable {
        let clientId: String
        let mode: String
    }

    struct ApprovalResponse: Equatable {
        let approvalId: String
        let approve: Bool
        let deviceId: String
    }

    var clients: [HermesGatewayClientRecord] = []
    private(set) var enqueuedEvents: [EnqueuedEvent] = []
    private(set) var enqueuedModelSwitches: [EnqueuedModelSwitch] = []
    private(set) var revokedClientIds: [String] = []
    private(set) var oversightModeChanges: [OversightModeChange] = []
    private(set) var approvalResponses: [ApprovalResponse] = []
    private(set) var approvalGrants: [ApprovalGrant] = []
    private var sequence = 0

    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String?,
        destinationId: String,
        scopes: [String],
        relayPublicKey: String?,
        relayKeyVersion: Int?,
        relayEncryption: String?
    ) async throws -> HermesGatewayClientRecord {
        approvalGrants.append(
            ApprovalGrant(
                userCode: userCode,
                relayPublicKey: relayPublicKey,
                relayKeyVersion: relayKeyVersion,
                relayEncryption: relayEncryption
            )
        )
        let client = HermesGatewayClientRecord(
            id: "hgw_approved",
            displayName: displayName ?? "Hermes Agent",
            status: "active",
            tokenPreview: "obb_hgw_...test",
            scopes: scopes,
            homeDestinationId: destinationId,
            lastSeenAt: nil,
            revokedAt: nil,
            createdAt: "2026-06-01T08:00:00Z",
            updatedAt: "2026-06-01T08:00:00Z",
            schemaVersion: 1,
            runtimeModelId: nil,
            runtimeProviderId: nil,
            runtimeModelOptions: [],
            runtimeUpdatedAt: nil
        )
        clients.insert(client, at: 0)
        return client
    }

    func listHermesGatewayClients(includeRevoked: Bool) async throws -> [HermesGatewayClientRecord] {
        includeRevoked ? clients : clients.filter(\.isActive)
    }

    func revokeHermesGatewayClient(clientId: String) async throws {
        revokedClientIds.append(clientId)
        clients.removeAll { $0.id == clientId }
    }

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String,
        threadId: String,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent {
        sequence += 1
        enqueuedEvents.append(
            EnqueuedEvent(
                text: text,
                threadId: threadId,
                targetClientId: targetClientId,
                senderDisplayName: senderDisplayName,
                sealedToAgent: targetClient?.canSealToAgent ?? false
            )
        )
        return HermesGatewayQueuedEvent(
            id: "evt_test_\(sequence)",
            sequence: sequence,
            targetClientId: targetClientId
        )
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String,
        threadId: String,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent {
        sequence += 1
        enqueuedModelSwitches.append(
            EnqueuedModelSwitch(
                modelId: modelId,
                threadId: threadId,
                targetClientId: targetClientId,
                senderDisplayName: senderDisplayName,
                sealedToAgent: targetClient?.canSealToAgent ?? false
            )
        )
        return HermesGatewayQueuedEvent(
            id: "evt_model_\(sequence)",
            sequence: sequence,
            targetClientId: targetClientId
        )
    }

    func setHermesGatewayOversightMode(clientId: String, mode: String) async throws {
        oversightModeChanges.append(OversightModeChange(clientId: clientId, mode: mode))
    }

    func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws {
        approvalResponses.append(ApprovalResponse(approvalId: approvalId, approve: approve, deviceId: deviceId))
    }
}

final class ScreenShareControlInputPolicyTests: XCTestCase {
    func testSingleControlTapUsesPrimaryClick() {
        XCTAssertEqual(ScreenShareControlInputPolicy.controlClickMouseButton(heldDuration: 0.08), 0)
    }

    func testLongControlPressUsesSecondaryClick() {
        XCTAssertEqual(
            ScreenShareControlInputPolicy.controlClickMouseButton(
                heldDuration: ScreenShareControlInputPolicy.rightClickHoldDuration
            ),
            1
        )
        XCTAssertEqual(ScreenShareControlInputPolicy.rightClickHoldDelayNanoseconds, 550_000_000)
    }

    func testPendingControlRightClickCancelsOnlyAfterGestureBecomesScrollOrPan() {
        XCTAssertFalse(
            ScreenShareControlInputPolicy.shouldCancelPendingControlRightClick(
                distance: 12,
                panStartDistance: 30,
                isEdgeScrollGesture: false,
                hasResolvedClickPoint: true
            )
        )
        XCTAssertFalse(
            ScreenShareControlInputPolicy.shouldCancelPendingControlRightClick(
                distance: 34,
                panStartDistance: 30,
                isEdgeScrollGesture: false,
                hasResolvedClickPoint: true
            )
        )
        XCTAssertTrue(
            ScreenShareControlInputPolicy.shouldCancelPendingControlRightClick(
                distance: 34,
                panStartDistance: 30,
                isEdgeScrollGesture: false,
                hasResolvedClickPoint: false
            )
        )
        XCTAssertTrue(
            ScreenShareControlInputPolicy.shouldCancelPendingControlRightClick(
                distance: 12,
                panStartDistance: 30,
                isEdgeScrollGesture: true,
                hasResolvedClickPoint: true
            )
        )
    }

    func testTrackpadTapClicksImmediatelyButDragDoesNot() {
        XCTAssertEqual(
            ScreenShareControlInputPolicy.trackpadClickMouseButton(
                heldDuration: 0.06,
                travelDistance: ScreenShareControlInputPolicy.trackpadTapTravelLimit - 0.1
            ),
            0
        )
        XCTAssertNil(
            ScreenShareControlInputPolicy.trackpadClickMouseButton(
                heldDuration: 0.06,
                travelDistance: ScreenShareControlInputPolicy.trackpadTapTravelLimit
            )
        )
    }

    func testCursorStartsCenteredAndClampsInsideVideoBounds() {
        let bounds = CGRect(x: 100, y: 50, width: 300, height: 200)

        XCTAssertEqual(
            ScreenShareControlInputPolicy.initialCursorPoint(in: bounds),
            CGPoint(x: 250, y: 150)
        )

        XCTAssertEqual(
            ScreenShareControlInputPolicy.movedCursorPoint(
                current: nil,
                delta: CGSize(width: -1_000, height: 1_000),
                bounds: bounds
            ),
            CGPoint(x: 100, y: 250)
        )
    }
}

final class ScreenShareStreamStateOverlayPolicyTests: XCTestCase {
    func testRemoteUnlockSuppressesNoFrameRestartOverlay() {
        XCTAssertFalse(
            ScreenShareStreamStateOverlayPolicy.shouldShow(
                displayAspectRatioKnown: false,
                streamIsLive: true,
                remoteUnlockActive: true
            )
        )
        XCTAssertFalse(
            ScreenShareStreamStateOverlayPolicy.shouldStartAwaitingFrameWatchdog(
                streamIsLive: true,
                isAwaitingFrame: true,
                remoteUnlockActive: true
            )
        )
    }

    func testUnlockedAwaitingFrameStillShowsRecoverableRestartOverlay() {
        XCTAssertTrue(
            ScreenShareStreamStateOverlayPolicy.shouldShow(
                displayAspectRatioKnown: false,
                streamIsLive: true,
                remoteUnlockActive: false
            )
        )
        XCTAssertTrue(
            ScreenShareStreamStateOverlayPolicy.shouldStartAwaitingFrameWatchdog(
                streamIsLive: true,
                isAwaitingFrame: true,
                remoteUnlockActive: false
            )
        )
    }
}

final class ScreenShareViewerStatsMeterTests: XCTestCase {
    func testRecordsInboundBitrateOverRollingWindow() {
        var meter = ScreenShareViewerStatsMeter(minimumSampleInterval: 0.5)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let first = meter.recordFrame(
            byteCount: 500_000,
            now: start,
            codec: "HEVC",
            resolution: "1920x1080"
        )
        XCTAssertEqual(first.bitsPerSecond, 0, "bitrate should wait for enough elapsed sample time")
        XCTAssertEqual(first.codec, "HEVC")
        XCTAssertEqual(first.resolution, "1920x1080")

        let second = meter.recordFrame(
            byteCount: 500_000,
            now: start.addingTimeInterval(1),
            codec: "HEVC",
            resolution: "1920x1080"
        )

        XCTAssertEqual(second.bitsPerSecond, 8_000_000)
        XCTAssertEqual(second.codec, "HEVC")
        XCTAssertEqual(second.resolution, "1920x1080")
    }

    func testRoundTripMillisIsClampedAndPreservesFrameStats() {
        var meter = ScreenShareViewerStatsMeter(minimumSampleInterval: 0.5)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        _ = meter.recordFrame(byteCount: 250_000, now: start, codec: "H.264", resolution: "1280x720")
        _ = meter.recordFrame(byteCount: 250_000, now: start.addingTimeInterval(0.5), codec: "H.264", resolution: "1280x720")

        let clamped = meter.updateRoundTripMillis(-12)
        XCTAssertEqual(clamped.roundTripMillis, 0)
        XCTAssertEqual(clamped.bitsPerSecond, 8_000_000)

        let updated = meter.updateRoundTripMillis(37)
        XCTAssertEqual(updated.roundTripMillis, 37)
        XCTAssertEqual(updated.codec, "H.264")
        XCTAssertEqual(updated.resolution, "1280x720")
    }
}

final class ScreenShareViewportStateTests: XCTestCase {
    func testMagnificationClampsScaleToSupportedRange() {
        var viewport = ScreenShareViewportState()

        viewport.applyMagnification(10, in: CGSize(width: 390, height: 844))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.maximumScale)

        viewport.applyMagnification(0.01, in: CGSize(width: 390, height: 844))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.minimumScale)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testPanningIsClampedToScaledContentBounds() {
        var viewport = ScreenShareViewportState(scale: 2)

        viewport.applyTranslation(CGSize(width: 1_000, height: -1_000), in: CGSize(width: 400, height: 800))

        XCTAssertEqual(viewport.offset.width, 200)
        XCTAssertEqual(viewport.offset.height, -400)
    }

    func testPanningAtDefaultScaleAlwaysRecenters() {
        var viewport = ScreenShareViewportState()

        viewport.applyTranslation(CGSize(width: 100, height: 100), in: CGSize(width: 400, height: 800))

        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testPreviewDoesNotMutateCommittedViewport() {
        let viewport = ScreenShareViewportState(scale: 2, offset: CGSize(width: 20, height: -40))

        let preview = viewport.preview(
            magnification: 1.5,
            translation: CGSize(width: 10, height: 10),
            in: CGSize(width: 400, height: 800)
        )

        XCTAssertEqual(viewport.scale, 2)
        XCTAssertEqual(viewport.offset, CGSize(width: 20, height: -40))
        XCTAssertEqual(preview.scale, 3)
        XCTAssertEqual(preview.offset, CGSize(width: 30, height: -30))
    }

    func testReclampPreservesZoomAcrossRotationButConstrainsOffset() {
        var viewport = ScreenShareViewportState(scale: 3, offset: CGSize(width: 600, height: 600))

        viewport.reclamp(in: CGSize(width: 844, height: 390))

        XCTAssertEqual(viewport.scale, 3)
        XCTAssertEqual(viewport.offset.width, 600)
        XCTAssertEqual(viewport.offset.height, 390)
    }

    func testQuickZoomTogglesBetweenFitAndZoomed() {
        var viewport = ScreenShareViewportState()

        viewport.toggleQuickZoom(in: CGSize(width: 400, height: 800))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.quickZoomScale)
        XCTAssertEqual(viewport.offset, .zero)

        viewport.toggleQuickZoom(in: CGSize(width: 400, height: 800))
        XCTAssertEqual(viewport.scale, ScreenShareViewportState.minimumScale)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testInlineTerminalInitialZoomOnlyAddsSmallReadabilityNudge() {
        let viewport = CGSize(width: 390, height: 844)
        let content = CGRect(x: 0, y: 312, width: 390, height: 219)
        let heightFillScale = viewport.height / content.height

        let scale = InlineAgentMirrorView.terminalInitialZoomScale(
            viewportSize: viewport,
            contentRect: content
        )

        XCTAssertLessThan(scale, heightFillScale)
        XCTAssertEqual(scale, 1.18, accuracy: 0.0001)
    }

    func testInlineTerminalInitialZoomKeepsAlreadyFitContentAtMinimumScale() {
        let scale = InlineAgentMirrorView.terminalInitialZoomScale(
            viewportSize: CGSize(width: 400, height: 800),
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 800)
        )

        XCTAssertEqual(scale, ScreenShareViewportState.minimumScale)
    }

    func testNormalizedTapMappingAtDefaultScale() {
        let viewport = ScreenShareViewportState()

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 100, y: 600),
            in: CGSize(width: 400, height: 800)
        )

        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.75, accuracy: 0.0001)
    }

    func testNormalizedTapMappingCompensatesForZoomAndPan() {
        let viewport = ScreenShareViewportState(scale: 2, offset: CGSize(width: 40, height: -80))

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 240, y: 320),
            in: CGSize(width: 400, height: 800)
        )

        XCTAssertEqual(point.x, 0.50, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.50, accuracy: 0.0001)
    }

    func testNormalizedTapMappingUsesLetterboxedVideoRect() {
        let viewport = ScreenShareViewportState()
        let container = CGSize(width: 2048, height: 944)
        let contentWidth = container.height * 1.6
        let contentRect = CGRect(
            x: (container.width - contentWidth) / 2,
            y: 0,
            width: contentWidth,
            height: container.height
        )

        let point = viewport.normalizedPoint(
            for: CGPoint(x: contentRect.minX + contentRect.width * 0.25, y: contentRect.height * 0.75),
            in: container,
            contentRect: contentRect
        )
        let leftLetterboxPoint = viewport.normalizedPoint(
            for: CGPoint(x: 20, y: container.height / 2),
            in: container,
            contentRect: contentRect
        )

        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.75, accuracy: 0.0001)
        XCTAssertEqual(leftLetterboxPoint.x, 0, accuracy: 0.0001)
        XCTAssertEqual(leftLetterboxPoint.y, 0.5, accuracy: 0.0001)
    }

    func testNormalizedTapMappingCombinesLetterboxZoomAndPan() {
        let viewport = ScreenShareViewportState(scale: 2, offset: CGSize(width: 50, height: -50))
        let container = CGSize(width: 1_000, height: 500)
        let contentRect = CGRect(x: 100, y: 0, width: 800, height: 500)

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 550, y: 200),
            in: container,
            contentRect: contentRect
        )

        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
    }

    func testNormalizedTapMappingClampsEdgesAfterRotation() {
        var viewport = ScreenShareViewportState(scale: 3, offset: CGSize(width: 900, height: -900))
        viewport.reclamp(in: CGSize(width: 844, height: 390))

        let point = viewport.normalizedPoint(
            for: CGPoint(x: 844, y: 0),
            in: CGSize(width: 844, height: 390)
        )

        XCTAssertGreaterThanOrEqual(point.x, 0)
        XCTAssertLessThanOrEqual(point.x, 1)
        XCTAssertGreaterThanOrEqual(point.y, 0)
        XCTAssertLessThanOrEqual(point.y, 1)
    }
}

private actor AgentWatchFakeStream: IrohRelayStream {
    private var inboundFrames: [HermesRealtimeRelayFrame] = []
    private var outboundFrames: [HermesRealtimeRelayFrame] = []
    private var receiveWaiter: CheckedContinuation<HermesRealtimeRelayFrame?, Error>?
    private var isClosed = false

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        outboundFrames.append(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        if !inboundFrames.isEmpty { return inboundFrames.removeFirst() }
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
        }
    }

    func close() async {
        isClosed = true
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func pushInbound(_ frame: HermesRealtimeRelayFrame) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: frame)
            return
        }
        inboundFrames.append(frame)
    }

    func sentFrames() -> [HermesRealtimeRelayFrame] {
        outboundFrames
    }
}

private actor AgentWatchFakeAuthorityPublisher: PhoneControlAuthorityPublishing {
    struct Published: Equatable {
        let uid: String
        let connectionId: String
        let deviceId: String
        let peerNodeId: String
        let publicKeyData: Data
    }

    private var values: [Published] = []

    func publish(
        uid: String,
        connectionId: String,
        deviceId: String,
        peerNodeId: String,
        publicKey: Curve25519.Signing.PublicKey
    ) async throws {
        values.append(Published(
            uid: uid,
            connectionId: connectionId,
            deviceId: deviceId,
            peerNodeId: peerNodeId,
            publicKeyData: publicKey.rawRepresentation
        ))
    }

    func published() -> [Published] {
        values
    }
}

private actor MobileAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PhoneControlFrameOrderRecorder {
    private var startedCounters: Set<UInt64> = []
    private var finished: [UInt64] = []
    private var startedWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    func recordStarted(_ counter: UInt64) {
        startedCounters.insert(counter)
        let pending = startedWaiters.removeValue(forKey: counter) ?? []
        pending.forEach { $0.resume() }
    }

    func waitForStarted(counter: UInt64) async {
        if startedCounters.contains(counter) {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters[counter, default: []].append(continuation)
        }
    }

    func recordFinished(_ counter: UInt64) {
        finished.append(counter)
    }

    func finishedCounters() -> [UInt64] {
        finished
    }

    func startedCounterValues() -> [UInt64] {
        startedCounters.sorted()
    }
}

private final class AgentWatchFakeSigningKeyStore: PhoneControlSigningKeyProviding {
    private let key = Curve25519SigningKey(privateKey: Curve25519.Signing.PrivateKey())

    func signingKey() throws -> Curve25519SigningKey {
        key
    }

    func peerNodeId(for key: Curve25519SigningKey) -> String {
        "ios-phone-test-\(key.privateKey.publicKey.rawRepresentation.prefix(4).map { String(format: "%02x", $0) }.joined())"
    }
}

private struct MobileFakeIrohPairingPublicKeyProvider: IrohPairingPublicKeyProviding {
    func fetchPublicKey(uid: String) async throws -> Data {
        Data(repeating: 0x1, count: 32)
    }
}

private struct MobileNoopIrohTransportAuditLogger: IrohTransportAuditLogging {
    func record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: [String: String]
    ) async {}
}

private final class MobileNoopIrohRelayTransport: IrohRelayTransport, @unchecked Sendable {
    func start() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(
            nodeId: "noop-node",
            rawPublicKey: Data(repeating: 0x2, count: 32)
        )
    }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohBackendError.connectFailed("noop")
    }

    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohBackendError.acceptFailed("noop")
    }

    func shutdown() async {}
}

private final class MobileFakeIrohBlobBackend: IrohBlobBackend, @unchecked Sendable {
    func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(
            nodeId: "blob-node",
            rawPublicKey: Data(repeating: 0x3, count: 32),
            relayURL: relayURL
        )
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob-ticket"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        BlobTransferStats(bytesTotal: 0, blake3Hash: "0", durationMillis: 0, didResume: false)
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(
            nodeId: "blob-node",
            rawPublicKey: Data(repeating: 0x3, count: 32)
        )
    }

    func shutdown() async {}
}

@MainActor
private final class MobileFakeSelfHostedQuotaRunnerSecrets: SelfHostedQuotaRunnerSecretStoring {
    var savedByAccount: [String: String] = [:]

    func save(_ value: String, accountID: String) throws {
        savedByAccount[accountID] = value
    }

    func load(accountID: String) throws -> String? {
        savedByAccount[accountID]
    }

    func delete(accountID: String) throws {
        savedByAccount.removeValue(forKey: accountID)
    }
}

final class SwarmBackgroundPowerPolicyTests: XCTestCase {
    func testVisibilityConstraintKeepsMostRestrictiveState() {
        XCTAssertEqual(.prominent, MobileBackgroundVisibility.prominent.constrained(by: .prominent))
        XCTAssertEqual(.subtle, MobileBackgroundVisibility.prominent.constrained(by: .subtle))
        XCTAssertEqual(.obscured, MobileBackgroundVisibility.subtle.constrained(by: .obscured))
        XCTAssertEqual(.hidden, MobileBackgroundVisibility.hidden.constrained(by: .prominent))
    }

    func testProminentActiveBackgroundUsesFullLivePlan() {
        let plan = SwarmBackgroundPowerPolicy.resolve(
            location: .everywhere,
            conditionMet: true,
            requestedVisibility: .prominent,
            scenePhaseActive: true,
            isLowPowerModeEnabled: false,
            reduceMotion: false
        )

        XCTAssertEqual(plan.mode, .live)
        XCTAssertEqual(plan.maxFrameRate, 30)
        XCTAssertEqual(plan.particleScale, 1.0)
        XCTAssertTrue(plan.allowsAutoCycling)
        XCTAssertTrue(plan.allowsSparkles)
        XCTAssertFalse(plan.isBatteryThrottled)
    }

    func testSubtleBackgroundUsesThrottledLivePlan() {
        let plan = SwarmBackgroundPowerPolicy.resolve(
            location: .everywhere,
            conditionMet: true,
            requestedVisibility: .subtle,
            scenePhaseActive: true,
            isLowPowerModeEnabled: false,
            reduceMotion: false
        )

        XCTAssertEqual(plan.mode, .live)
        XCTAssertEqual(plan.maxFrameRate, 15)
        XCTAssertLessThan(plan.particleScale, 0.5)
        XCTAssertFalse(plan.allowsAutoCycling)
        XCTAssertFalse(plan.allowsSparkles)
        XCTAssertTrue(plan.isBatteryThrottled)
    }

    func testCoveredInactiveOrReduceMotionBackgroundBecomesStatic() {
        XCTAssertEqual(
            staticPlan(requestedVisibility: .obscured, scenePhaseActive: true, reduceMotion: false).mode,
            .staticBackdrop
        )
        XCTAssertEqual(
            staticPlan(requestedVisibility: .prominent, scenePhaseActive: false, reduceMotion: false).mode,
            .staticBackdrop
        )
        XCTAssertEqual(
            staticPlan(requestedVisibility: .prominent, scenePhaseActive: true, reduceMotion: true).mode,
            .staticBackdrop
        )
    }

    func testDecorativeEffectsOnlyRunWhenVisibleAndActive() {
        XCTAssertTrue(MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: .prominent,
            scenePhaseActive: true
        ))
        XCTAssertTrue(MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: .subtle,
            scenePhaseActive: true
        ))
        XCTAssertFalse(MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: .obscured,
            scenePhaseActive: true
        ))
        XCTAssertFalse(MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: .hidden,
            scenePhaseActive: true
        ))
        XCTAssertFalse(MobileDecorativeRenderPolicy.allowsLiveEffects(
            visibility: .prominent,
            scenePhaseActive: false
        ))
    }

    func testLowPowerKeepsOnlyProminentBackgroundLiveAtSubtleRate() {
        let prominentPlan = SwarmBackgroundPowerPolicy.resolve(
            location: .everywhere,
            conditionMet: true,
            requestedVisibility: .prominent,
            scenePhaseActive: true,
            isLowPowerModeEnabled: true,
            reduceMotion: false
        )
        let subtlePlan = SwarmBackgroundPowerPolicy.resolve(
            location: .everywhere,
            conditionMet: true,
            requestedVisibility: .subtle,
            scenePhaseActive: true,
            isLowPowerModeEnabled: true,
            reduceMotion: false
        )

        XCTAssertEqual(prominentPlan, .subtleLive)
        XCTAssertEqual(subtlePlan.mode, .staticBackdrop)
    }

    func testDisabledAndUnmetConditionsDoNotStartSwarm() {
        let disabledPlan = SwarmBackgroundPowerPolicy.resolve(
            location: .disabled,
            conditionMet: true,
            requestedVisibility: .prominent,
            scenePhaseActive: true,
            isLowPowerModeEnabled: false,
            reduceMotion: false
        )
        let conditionPlan = SwarmBackgroundPowerPolicy.resolve(
            location: .everywhere,
            conditionMet: false,
            requestedVisibility: .prominent,
            scenePhaseActive: true,
            isLowPowerModeEnabled: false,
            reduceMotion: false
        )

        XCTAssertEqual(disabledPlan.mode, .disabledFallback)
        XCTAssertEqual(conditionPlan.mode, .staticBackdrop)
    }

    private func staticPlan(
        requestedVisibility: MobileBackgroundVisibility,
        scenePhaseActive: Bool,
        reduceMotion: Bool
    ) -> SwarmBackgroundRenderPlan {
        SwarmBackgroundPowerPolicy.resolve(
            location: .everywhere,
            conditionMet: true,
            requestedVisibility: requestedVisibility,
            scenePhaseActive: scenePhaseActive,
            isLowPowerModeEnabled: false,
            reduceMotion: reduceMotion
        )
    }
}

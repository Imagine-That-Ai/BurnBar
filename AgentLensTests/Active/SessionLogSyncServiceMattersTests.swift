import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBar

/// Verifies that the encrypted-search read path fails CLOSED.
///
/// `searchCloudSessionLogs` consumes hits relayed by the `searchEncryptedConversationIndex`
/// Cloud Function. Each `sealedTitle` / `sealedSnippet` is an AES-GCM envelope bound to a
/// `CloudVaultAADContext`. Before the fix, the read decrypted with `try?` and NO AAD, which
/// (a) silently broke decryption for every modern envelope and (b) fell open: a forged or
/// tampered hit was still surfaced to the user as a real result with an "Encrypted session"
/// placeholder title. The hardened path passes the bound AAD and rejects any hit whose present
/// sealed field fails authentication.
final class SessionLogSyncServiceMattersTests: XCTestCase {

    private let uid = "test-uid-search"
    private let documentID = "doc-abc"
    private let chunkID = "doc-abc_0"

    private func makeVaultKey() throws -> Data {
        try CloudVaultCrypto.generateVaultKey()
    }

    /// Serializes a sealed-text envelope into the `[String: Any]` shape the Cloud Function relays.
    private func sealedDict(
        _ plaintext: String,
        key: Data,
        collection: String,
        docID: String,
        field: String
    ) throws -> [String: Any] {
        let envelope = try CloudVaultCrypto.sealText(
            plaintext,
            keyData: key,
            aadContext: CloudVaultAADContext(
                uid: uid,
                collection: collection,
                docID: docID,
                field: field
            )
        )
        let data = try JSONEncoder().encode(envelope)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "test", code: 1)
        }
        return dict
    }

    private func sealedTitleDict(_ plaintext: String, key: Data) throws -> [String: Any] {
        try sealedDict(plaintext, key: key, collection: "cloud_search_documents", docID: documentID, field: "sealedTitle")
    }

    private func sealedSnippetDict(_ plaintext: String, key: Data) throws -> [String: Any] {
        try sealedDict(plaintext, key: key, collection: "cloud_search_chunks", docID: chunkID, field: "sealedSnippet")
    }

    private func baseHit(title: [String: Any], snippet: [String: Any]) -> [String: Any] {
        [
            "provider": AgentProvider.claudeCode.rawValue,
            "documentID": documentID,
            "chunkID": chunkID,
            "sourceID": "session-xyz",
            "sealedTitle": title,
            "sealedSnippet": snippet
        ]
    }

    // MARK: - Happy path

    func test_decodeHit_decryptsTitleAndSnippet_withBoundAAD() throws {
        let key = try makeVaultKey()
        let hit = baseHit(
            title: try sealedTitleDict("Refactor the cache layer", key: key),
            snippet: try sealedSnippetDict("We replaced the LRU with a clock cache.", key: key)
        )

        let record = CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid)

        let unwrapped = try XCTUnwrap(record, "Authentic hit must decrypt and surface")
        XCTAssertEqual(unwrapped.inferredTaskTitle, "Refactor the cache layer")
        XCTAssertEqual(unwrapped.summaryTitle, "Refactor the cache layer")
        XCTAssertEqual(unwrapped.lastAssistantMessage, "We replaced the LRU with a clock cache.")
        XCTAssertEqual(unwrapped.fullText, "We replaced the LRU with a clock cache.")
        XCTAssertEqual(unwrapped.sessionId, documentID)
        XCTAssertEqual(unwrapped.id, "session-xyz")
        XCTAssertTrue(unwrapped.isRemote)
    }

    // MARK: - Fail closed: tampered / forged fields

    func test_decodeHit_rejectsHit_whenTitleAADMismatch() throws {
        let key = try makeVaultKey()
        // Seal the title under the WRONG field (a relayed/forged envelope), then present it as the title.
        let forgedTitle = try sealedDict(
            "Innocent looking title",
            key: key,
            collection: "cloud_search_documents",
            docID: documentID,
            field: "sealedBodyPreview"
        )
        let hit = baseHit(
            title: forgedTitle,
            snippet: try sealedSnippetDict("snippet", key: key)
        )

        XCTAssertNil(
            CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid),
            "A title sealed under a different AAD must be treated as tampered and the hit rejected"
        )
    }

    func test_decodeHit_rejectsHit_whenSnippetCiphertextTampered() throws {
        let key = try makeVaultKey()
        var snippet = try sealedSnippetDict("original snippet", key: key)
        // Flip the ciphertext: GCM auth must fail.
        let ciphertext = try XCTUnwrap(snippet["ciphertext"] as? String)
        var bytes = Array(try XCTUnwrap(Data(base64Encoded: ciphertext)))
        if bytes.isEmpty { bytes = [0] }
        bytes[0] ^= 0xFF
        snippet["ciphertext"] = Data(bytes).base64EncodedString()
        let hit = baseHit(
            title: try sealedTitleDict("ok title", key: key),
            snippet: snippet
        )

        XCTAssertNil(
            CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid),
            "A bit-flipped snippet ciphertext must fail GCM auth and reject the hit"
        )
    }

    func test_decodeHit_rejectsHit_underWrongVaultKey() throws {
        let sealKey = try makeVaultKey()
        let readerKey = try makeVaultKey()
        let hit = baseHit(
            title: try sealedTitleDict("secret title", key: sealKey),
            snippet: try sealedSnippetDict("secret snippet", key: sealKey)
        )

        XCTAssertNil(
            CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: readerKey, uid: uid),
            "Decrypting under the wrong vault key must reject rather than show a placeholder"
        )
    }

    func test_decodeHit_rejectsHit_whenServerSwapsWrongDocumentIDForTitle() throws {
        let key = try makeVaultKey()
        // Title legitimately sealed for documentID, but server relays it under a different documentID.
        let hit: [String: Any] = [
            "provider": AgentProvider.claudeCode.rawValue,
            "documentID": "doc-OTHER",
            "chunkID": chunkID,
            "sourceID": "session-xyz",
            "sealedTitle": try sealedTitleDict("title for doc-abc", key: key),
            "sealedSnippet": try sealedSnippetDict("snippet", key: key)
        ]

        XCTAssertNil(
            CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid),
            "AAD binds the envelope to its documentID; a swapped documentID must reject the hit"
        )
    }

    // MARK: - Legitimate absence still surfaces (with safe placeholders)

    func test_decodeHit_absentSealedFields_surfacePlaceholders() throws {
        let key = try makeVaultKey()
        let hit: [String: Any] = [
            "provider": AgentProvider.claudeCode.rawValue,
            "documentID": documentID,
            "sourceID": "session-xyz"
        ]

        let record = try XCTUnwrap(CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid))
        XCTAssertEqual(record.inferredTaskTitle, "Encrypted session")
        XCTAssertEqual(record.lastAssistantMessage, "")
        XCTAssertEqual(record.summary, "")
    }

    func test_decodeHit_decryptsTitle_whenSnippetLegitimatelyAbsent() throws {
        let key = try makeVaultKey()
        let hit: [String: Any] = [
            "provider": AgentProvider.claudeCode.rawValue,
            "documentID": documentID,
            "sourceID": "session-xyz",
            "sealedTitle": try sealedTitleDict("Title only", key: key)
        ]

        let record = try XCTUnwrap(CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid))
        XCTAssertEqual(record.inferredTaskTitle, "Title only")
        XCTAssertEqual(record.lastAssistantMessage, "")
    }

    // MARK: - Malformed hits are skipped

    func test_decodeHit_rejectsHit_withUnknownProvider() throws {
        let key = try makeVaultKey()
        let hit: [String: Any] = [
            "provider": "not-a-real-provider",
            "documentID": documentID
        ]
        XCTAssertNil(CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid))
    }

    func test_decodeHit_rejectsHit_missingDocumentID() throws {
        let key = try makeVaultKey()
        let hit: [String: Any] = ["provider": AgentProvider.claudeCode.rawValue]
        XCTAssertNil(CloudSyncService.decodeEncryptedSearchHit(hit, vaultKey: key, uid: uid))
    }

    // MARK: - Field-level decode outcomes

    func test_decryptField_decryptedAbsentTampered() throws {
        let key = try makeVaultKey()

        let good = CloudSyncService.decryptEncryptedSearchField(
            try sealedTitleDict("hello", key: key),
            vaultKey: key,
            uid: uid,
            collection: "cloud_search_documents",
            docID: documentID,
            field: "sealedTitle"
        )
        XCTAssertEqual(good, .decrypted("hello"))

        let absent = CloudSyncService.decryptEncryptedSearchField(
            nil,
            vaultKey: key,
            uid: uid,
            collection: "cloud_search_documents",
            docID: documentID,
            field: "sealedTitle"
        )
        XCTAssertEqual(absent, .absent)

        // Present envelope opened with a mismatched field AAD → tampered.
        let tampered = CloudSyncService.decryptEncryptedSearchField(
            try sealedTitleDict("hello", key: key),
            vaultKey: key,
            uid: uid,
            collection: "cloud_search_documents",
            docID: documentID,
            field: "sealedBodyPreview"
        )
        XCTAssertEqual(tampered, .tampered)
    }

    /// FAIL CLOSED on a forged/malformed-but-PRESENT sealed field. The server is
    /// untrusted: a sealed field that is present yet cannot be parsed into a
    /// `CloudVaultSealedText` (missing required `tag`/`nonce`, or a non-dict value)
    /// must reject the hit (`.tampered`), never collapse to the safe-placeholder
    /// `.absent` path that a genuinely-missing field uses. Regression guard for the
    /// auth-gate bypass found in the try?-burn-down review.
    func test_decryptField_presentButMalformed_failsClosedAsTampered() throws {
        let key = try makeVaultKey()
        let args = (collection: "cloud_search_documents", docID: documentID, field: "sealedTitle")

        // Present dict missing every required sealed-envelope field.
        let malformedDict = CloudSyncService.decryptEncryptedSearchField(
            ["unexpected": "shape"],
            vaultKey: key, uid: uid,
            collection: args.collection, docID: args.docID, field: args.field
        )
        XCTAssertEqual(malformedDict, .tampered, "a present-but-undecodable dict must be rejected, not treated as absent")

        // Present dict that has some envelope keys but omits the auth tag.
        let missingTag = CloudSyncService.decryptEncryptedSearchField(
            ["algorithm": "AES-GCM", "keyVersion": 1, "nonce": "AAAA", "ciphertext": "AAAA"],
            vaultKey: key, uid: uid,
            collection: args.collection, docID: args.docID, field: args.field
        )
        XCTAssertEqual(missingTag, .tampered, "a present envelope missing the auth tag must be rejected")

        // Present non-dict value (e.g. a bare string) is not a valid sealed field.
        let nonDict = CloudSyncService.decryptEncryptedSearchField(
            "forged",
            vaultKey: key, uid: uid,
            collection: args.collection, docID: args.docID, field: args.field
        )
        XCTAssertEqual(nonDict, .tampered, "a present non-dict value must be rejected")

        // An explicit null is a legitimate absence, not tamper.
        let explicitNull = CloudSyncService.decryptEncryptedSearchField(
            NSNull(),
            vaultKey: key, uid: uid,
            collection: args.collection, docID: args.docID, field: args.field
        )
        XCTAssertEqual(explicitNull, .absent, "an explicit null field is a legitimate absence")
    }
}

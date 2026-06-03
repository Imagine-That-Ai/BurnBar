import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBarCore

final class CloudVaultCryptoTests: XCTestCase {
    func test_textAndBlobRoundTrip_decryptsOnlyWithVaultKey() throws {
        let key = Data(repeating: 0x42, count: 32)
        let otherKey = Data(repeating: 0x24, count: 32)

        let sealedText = try CloudVaultCrypto.sealText("private launch plan", keyData: key)
        XCTAssertEqual(try CloudVaultCrypto.openText(sealedText, keyData: key), "private launch plan")
        XCTAssertThrowsError(try CloudVaultCrypto.openText(sealedText, keyData: otherKey))

        let body = Data("full encrypted session markdown".utf8)
        let sealedBlob = try CloudVaultCrypto.sealBlob(body, keyData: key)
        XCTAssertEqual(try CloudVaultCrypto.openBlob(sealedBlob, keyData: key), body)
        XCTAssertThrowsError(try CloudVaultCrypto.openBlob(sealedBlob, keyData: otherKey))
    }

    func test_tokenHashes_areKeyedStableDeduplicatedAndNotPlaintext() throws {
        let key = Data(repeating: 0x11, count: 32)
        let otherKey = Data(repeating: 0x22, count: 32)
        let text = "BurnBar BurnBar hosted MiniMax encrypted session search"

        let first = try CloudVaultCrypto.tokenHashes(for: text, keyData: key)
        let second = try CloudVaultCrypto.tokenHashes(for: text, keyData: key)
        let other = try CloudVaultCrypto.tokenHashes(for: text, keyData: otherKey)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, Set(first).count)
        XCTAssertTrue(first.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(first.contains("burnbar"))
        XCTAssertTrue(try CloudVaultCrypto.tokenHashes(for: "the and for", keyData: key).isEmpty)
    }

    func test_searchTokenHashes_supportEncryptedPrefixRecall() throws {
        let key = Data(repeating: 0x55, count: 32)

        let indexHashes = try CloudVaultCrypto.searchIndexTokenHashes(
            for: "/Users/emilionunezgarcia/Developer/LaHormigaDormida",
            keyData: key
        )
        let queryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "emilio",
            keyData: key
        )
        let shortQueryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "emi",
            keyData: key
        )
        let unrelatedHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "factory",
            keyData: key
        )

        XCTAssertFalse(Set(indexHashes).intersection(queryHashes).isEmpty)
        XCTAssertFalse(Set(indexHashes).intersection(shortQueryHashes).isEmpty)
        XCTAssertTrue(Set(indexHashes).intersection(unrelatedHashes).isEmpty)
        XCTAssertTrue(indexHashes.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(indexHashes.contains("emilio"))
    }

    func test_searchTokenHashes_supportEncryptedExactPhraseRecallWithSingleLetterSignals() throws {
        let key = Data(repeating: 0x56, count: 32)

        let indexHashes = try CloudVaultCrypto.searchIndexTokenHashes(
            for: "Build the X Ads API integration for campaign reporting",
            keyData: key
        )
        let exactQueryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "x ads api",
            keyData: key
        )
        let partialQueryHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "ads api",
            keyData: key
        )
        let unrelatedHashes = try CloudVaultCrypto.searchQueryTokenHashes(
            for: "transcript cache",
            keyData: key
        )

        XCTAssertFalse(Set(indexHashes).intersection(exactQueryHashes).isEmpty)
        XCTAssertFalse(Set(indexHashes).intersection(partialQueryHashes).isEmpty)
        XCTAssertTrue(Set(indexHashes).intersection(unrelatedHashes).isEmpty)
        XCTAssertTrue(indexHashes.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(indexHashes.contains("x_ads_api"))
    }

    func test_semanticHashes_areKeyedStableBoundedAndPreserveEncryptedRecall() throws {
        let key = Data(repeating: 0x33, count: 32)
        let otherKey = Data(repeating: 0x44, count: 32)
        let indexed = "Hosted encrypted session logs with semantic search and cloud vault sync"
        let related = "Find searchable cloud sessions that were encrypted and hosted"
        let unrelated = "Espresso roast tasting notes and ceramic mugs"

        let first = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: key)
        let second = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: key)
        let other = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: otherKey)
        let relatedHashes = try CloudVaultCrypto.semanticHashes(for: related, keyData: key)
        let unrelatedHashes = try CloudVaultCrypto.semanticHashes(for: unrelated, keyData: key)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertLessThanOrEqual(first.count, 24)
        XCTAssertEqual(first.count, Set(first).count)
        XCTAssertTrue(first.allSatisfy { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
        XCTAssertFalse(first.contains("encrypted"))
        XCTAssertFalse(Set(first).intersection(relatedHashes).isEmpty)
        XCTAssertGreaterThanOrEqual(
            Set(first).intersection(relatedHashes).count,
            Set(first).intersection(unrelatedHashes).count
        )
    }

    func test_semanticHashes_bridgeDomainSynonymsForMeaningSearch() throws {
        let key = Data(repeating: 0x34, count: 32)
        let indexed = "Twitter advertising endpoint integration and campaign reporting"
        let meaningQuery = "x ads api"
        let unrelated = "transcript cache storage setting"

        let indexedHashes = try CloudVaultCrypto.semanticHashes(for: indexed, keyData: key)
        let meaningHashes = try CloudVaultCrypto.semanticHashes(for: meaningQuery, keyData: key)
        let unrelatedHashes = try CloudVaultCrypto.semanticHashes(for: unrelated, keyData: key)

        XCTAssertFalse(Set(indexedHashes).intersection(meaningHashes).isEmpty)
        XCTAssertGreaterThan(
            Set(indexedHashes).intersection(meaningHashes).count,
            Set(indexedHashes).intersection(unrelatedHashes).count
        )
        XCTAssertFalse(indexedHashes.contains("twitter"))
    }

    func test_projectMemoryDocID_isDeterministicOpaqueAndKeySensitive() throws {
        let key = Data(repeating: 0x42, count: 32)
        let otherKey = Data(repeating: 0x24, count: 32)
        let slug = "la-hormiga-dormida"

        let first = try CloudVaultCrypto.projectMemoryDocID(forSlug: slug, keyData: key)
        let second = try CloudVaultCrypto.projectMemoryDocID(forSlug: slug, keyData: key)
        let otherSlug = try CloudVaultCrypto.projectMemoryDocID(forSlug: "burnbar", keyData: key)
        let otherVault = try CloudVaultCrypto.projectMemoryDocID(forSlug: slug, keyData: otherKey)

        // Deterministic: same slug + key → same id (upsert idempotency).
        XCTAssertEqual(first, second)
        // Distinct slug → distinct id.
        XCTAssertNotEqual(first, otherSlug)
        // Different vault key → different id (per-user opacity).
        XCTAssertNotEqual(first, otherVault)
        // Opaque shape: "pm_" + 32 lowercase hex — passes requiredIdentifier's
        // [a-z0-9_-] filter, and never echoes the plaintext slug.
        XCTAssertTrue(first.range(of: "^pm_[a-f0-9]{32}$", options: .regularExpression) != nil)
        XCTAssertFalse(first.contains(slug))

        // Independent recomputation of the documented recipe:
        // HKDF<SHA256>(key, salt "OpenBurnBar-DocID-Salt-v1",
        //   info "OpenBurnBar-ProjectMemory-DocID-v1", 32B) → HMAC<SHA256>(slug).prefix16.hex
        let docKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data("OpenBurnBar-DocID-Salt-v1".utf8),
            info: Data("OpenBurnBar-ProjectMemory-DocID-v1".utf8),
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: Data(slug.utf8), using: docKey)
        let expected = "pm_" + Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first, expected)
    }

    func test_pensieveDedupHash_isVaultKeyedDeterministicAndNotPlaintextSHA256() throws {
        let keyA = Data(repeating: 0xA1, count: 32)
        let keyB = Data(repeating: 0xB2, count: 32)
        let plaintext = "deploy the daemon before midnight"

        let first = try CloudVaultCrypto.pensieveDedupHash(plaintext, keyData: keyA)
        let second = try CloudVaultCrypto.pensieveDedupHash(plaintext, keyData: keyA)
        let other = try CloudVaultCrypto.pensieveDedupHash(plaintext, keyData: keyB)

        // Deterministic per key; per-user keys diverge for identical plaintext.
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        // Full HMAC-SHA256 digest (64 hex) — satisfies requireHexDigest.
        XCTAssertTrue(first.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
        // Never the keyless SHA-256 a curious server could guess (no dedup oracle).
        let plaintextSHA256 = SHA256.hash(data: Data(plaintext.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(first, plaintextSHA256)

        // Parity with the server test's derivation (knowledgeMemoryDedupHash.test.ts):
        // HKDF<SHA256>(key, salt ∅, info "pensieve-dedup:content", 32B) → HMAC<SHA256>(plaintext).
        let dedupKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyA),
            salt: Data(),
            info: Data("pensieve-dedup:content".utf8),
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plaintext.utf8), using: dedupKey)
        let expected = Data(mac).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first, expected)
    }

    func test_pensieveSlugHmac_isVaultKeyedDeterministicAndDistinctFromDedupHash() throws {
        let key = Data(repeating: 0xC3, count: 32)
        let slug = "burnbar-docs-secret-runbook"

        let first = try CloudVaultCrypto.pensieveSlugHmac(slug, keyData: key)
        let second = try CloudVaultCrypto.pensieveSlugHmac(slug, keyData: key)
        let otherSlug = try CloudVaultCrypto.pensieveSlugHmac("notes-security-md", keyData: key)
        let otherKey = try CloudVaultCrypto.pensieveSlugHmac(slug, keyData: Data(repeating: 0xD4, count: 32))

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, otherSlug)
        XCTAssertNotEqual(first, otherKey)
        XCTAssertTrue(first.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
        XCTAssertFalse(first.contains(slug))

        // The slug info label differs from content, so the same input under the
        // same key must not collide across the two trapdoors (domain separation).
        let asContent = try CloudVaultCrypto.pensieveDedupHash(slug, keyData: key)
        XCTAssertNotEqual(first, asContent)

        // Parity: HKDF<SHA256>(key, salt ∅, info "pensieve-dedup:slug", 32B) → HMAC<SHA256>(slug).
        let slugKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(),
            info: Data("pensieve-dedup:slug".utf8),
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: Data(slug.utf8), using: slugKey)
        let expected = Data(mac).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(first, expected)
    }

    func test_wrappedVaultKeyRoundTrip_unwrapsAcrossGeneratedDeviceKeys() throws {
        let recipient = P256.KeyAgreement.PrivateKey()
        let vaultKey = Data((0..<32).map(UInt8.init))

        let wrapped = try CloudVaultCrypto.wrapVaultKey(
            vaultKey,
            recipientPublicKey: recipient.publicKey.x963Representation
        )
        let unwrapped = try CloudVaultCrypto.unwrapVaultKey(wrapped, privateKey: recipient)

        XCTAssertEqual(unwrapped, vaultKey)
    }

    func test_recoveryWrappedVaultKeyRoundTrip_usesSymmetricRecoveryEnvelope() throws {
        let vaultKey = Data((0..<32).map(UInt8.init))
        let recoveryKey = try CloudVaultCrypto.generateRecoveryKey()

        let wrapped = try CloudVaultCrypto.wrapVaultKeyWithRecovery(
            vaultKey: vaultKey,
            recoveryKey: recoveryKey
        )
        let unwrapped = try CloudVaultCrypto.unwrapVaultKeyWithRecovery(
            wrappedVaultKeyBase64: wrapped.wrappedVaultKeyBase64,
            recoveryKey: recoveryKey
        )

        XCTAssertEqual(unwrapped, vaultKey)
        XCTAssertEqual(wrapped.verificationHash, try CloudVaultCrypto.recoveryVerificationHash(for: recoveryKey))
        XCTAssertTrue(wrapped.verificationHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
    }
}

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
}

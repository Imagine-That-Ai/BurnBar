import XCTest
import CryptoKit
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Verifies the privacy-leak remediation for `media_attachment_manifests`: the
/// human-readable `filename` is SEALED with the per-user vault key into
/// `sealedFilename` before it touches Firestore, the cleartext name is never
/// written, the doc carries exactly the rule's `hasOnly` allowlist, the peer
/// identity is reduced to an opaque hash, and the sealed name round-trips back
/// to the original via `CloudVaultCrypto.openText`.
@MainActor
final class MediaAttachmentManifestStoreTests: XCTestCase {

    private func makeCompletion(
        direction: iOSFileTransferService.TransferCompletion.Direction = .sent,
        filename: String = "Quarterly Roadmap.pdf",
        localURL: URL? = nil
    ) -> iOSFileTransferService.TransferCompletion {
        iOSFileTransferService.TransferCompletion(
            id: "att_2f3c9a1b",
            connectionID: "conn-node-9f12ab",
            direction: direction,
            filename: filename,
            mime: "application/pdf",
            sizeBytes: 482_113,
            completedAt: Date(timeIntervalSince1970: 1_717_000_000),
            bytesPerSecond: 1_024_000,
            didResume: false,
            localURL: localURL
        )
    }

    /// The allowlist must match `validMediaAttachmentManifestKeys()` in
    /// `firestore.rules` exactly (minus the optional `expireAt`, which this
    /// writer does not emit).
    private let allowedKeys: Set<String> = [
        "id", "blobHash", "sealedFilename", "mime", "size",
        "peerDeviceIdHash", "direction", "createdAt", "expireAt", "schemaVersion",
    ]

    func test_encodeManifest_sealsFilename_writesNoPlaintext() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let document = try MediaAttachmentManifestStore.encodeManifest(makeCompletion(), vaultKey: key)

        // Filename is sealed; no cleartext name leaks.
        XCTAssertNotNil(document["sealedFilename"])
        XCTAssertNil(document["filename"])

        // Canonical sealed-text envelope shape.
        let sealed = try XCTUnwrap(document["sealedFilename"] as? [String: Any])
        XCTAssertEqual(sealed["algorithm"] as? String, CloudVaultCrypto.aesGCMAlgorithm)
        XCTAssertEqual(sealed["keyVersion"] as? Int, CloudVaultCrypto.currentKeyVersion)
        XCTAssertNotNil(sealed["nonce"])
        XCTAssertNotNil(sealed["ciphertext"])
        XCTAssertNotNil(sealed["tag"])
    }

    func test_encodeManifest_emitsOnlyAllowlistedKeys() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let document = try MediaAttachmentManifestStore.encodeManifest(makeCompletion(), vaultKey: key)

        // Every emitted key is in the rule's `hasOnly` allowlist — no smuggled
        // fields that the rule would reject.
        for emitted in document.keys {
            XCTAssertTrue(
                allowedKeys.contains(emitted),
                "Unexpected manifest key not in firestore.rules allowlist: \(emitted)"
            )
        }

        // Required, rule-checked invariants.
        XCTAssertEqual(document["id"] as? String, "att_2f3c9a1b")
        XCTAssertEqual(document["mime"] as? String, "application/pdf")
        XCTAssertEqual(document["size"] as? Int64, 482_113)
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertTrue(document["blobHash"] is String)
        XCTAssertFalse((document["blobHash"] as? String ?? "").isEmpty)
        XCTAssertTrue(document["peerDeviceIdHash"] is String)
        XCTAssertTrue(document["createdAt"] is Timestamp)
    }

    func test_encodeManifest_roundTripsSealedFilename() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let completion = makeCompletion(filename: "私的レポート.pdf")
        let document = try MediaAttachmentManifestStore.encodeManifest(completion, vaultKey: key)

        let sealedRaw = document["sealedFilename"]
        let envelope = try XCTUnwrap(CloudVaultCrypto.decodeSealedText(from: sealedRaw))
        let opened = try CloudVaultCrypto.openText(envelope, keyData: key)
        XCTAssertEqual(opened, "私的レポート.pdf")
    }

    func test_direction_mapsPhonePerspective() {
        XCTAssertEqual(MediaAttachmentManifestStore.direction(for: .sent), "iosToMac")
        XCTAssertEqual(MediaAttachmentManifestStore.direction(for: .received), "macToIos")

        // Direction is written through to the doc.
        let key = CloudVaultCrypto.generateVaultKey()
        let sent = try? MediaAttachmentManifestStore.encodeManifest(
            makeCompletion(direction: .sent), vaultKey: key)
        let received = try? MediaAttachmentManifestStore.encodeManifest(
            makeCompletion(direction: .received), vaultKey: key)
        XCTAssertEqual(sent?["direction"] as? String, "iosToMac")
        XCTAssertEqual(received?["direction"] as? String, "macToIos")
    }

    func test_peerDeviceIdHash_isOpaqueSha256_neverPlaintext() {
        let hash = MediaAttachmentManifestStore.peerDeviceIdHash(for: "conn-node-9f12ab")
        // Stable lowercase hex SHA-256 (64 chars) — never the raw connection id.
        XCTAssertEqual(hash.count, 64)
        XCTAssertNotEqual(hash, "conn-node-9f12ab")
        XCTAssertFalse(hash.contains("conn-node"))
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertEqual(
            hash,
            MediaAttachmentManifestStore.peerDeviceIdHash(for: "conn-node-9f12ab"),
            "peerDeviceIdHash must be deterministic"
        )
        let expected = SHA256.hash(data: Data("conn-node-9f12ab".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
    }

    func test_blobHash_hashesLocalFileWhenAvailable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-test-\(UUID().uuidString).bin")
        let payload = Data("mercury attachment bytes".utf8)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hash = MediaAttachmentManifestStore.blobHash(for: makeCompletion(localURL: tmp))
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
    }

    func test_blobHash_deterministicFallbackWhenNoLocalFile() {
        let hash = MediaAttachmentManifestStore.blobHash(for: makeCompletion(localURL: nil))
        let expected = SHA256.hash(data: Data("conn-node-9f12ab:att_2f3c9a1b".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, expected)
        XCTAssertFalse(hash.isEmpty)
    }

    func test_isActiveMediaEntitlement_requiresActiveAndUnexpired() {
        let future = Timestamp(date: Date().addingTimeInterval(86_400))
        let past = Timestamp(date: Date().addingTimeInterval(-86_400))

        XCTAssertTrue(MediaAttachmentManifestStore.isActiveMediaEntitlement([
            "active": true, "expireAt": future,
        ]))
        XCTAssertFalse(MediaAttachmentManifestStore.isActiveMediaEntitlement([
            "active": true, "expireAt": past,
        ]))
        XCTAssertFalse(MediaAttachmentManifestStore.isActiveMediaEntitlement([
            "active": false, "expireAt": future,
        ]))
        XCTAssertFalse(MediaAttachmentManifestStore.isActiveMediaEntitlement([
            "active": true,
        ]))
    }
}

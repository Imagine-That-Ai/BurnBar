import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import OpenBurnBarKernel
import XCTest

final class SafariPayloadAndChunkStoreTests: XCTestCase {
    func test_payloadResolverReadsOnceThenRejectsReplay() throws {
        let root = try temporaryRoot()
        let store = BurnBarSafariAppGroupPayloadStore(
            trustedRoot: root,
            lifetime: 60
        )
        let resolver = BurnBarSafariAppGroupPayloadResolver(trustedRoot: root)
        let payload = Data("beautiful, bounded payload".utf8)
        let reference = try store.store(payload, now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            try resolver.resolve(reference, now: Date(timeIntervalSince1970: 101)),
            payload
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: reference.filePath))
        XCTAssertThrowsError(
            try resolver.resolve(reference, now: Date(timeIntervalSince1970: 102))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarSafariAppGroupPayloadError,
                .fileUnavailable
            )
        }
    }

    func test_payloadResolverRejectsTraversalAndSymlink() throws {
        let root = try temporaryRoot()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).payload")
        let outsideData = Data("outside".utf8)
        try outsideData.write(to: outside)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outside.path
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: outside)
        }

        let traversal = BurnBarSafariAppGroupPayloadReference(
            filePath: outside.path,
            byteLength: outsideData.count,
            sha256: sha256Hex(outsideData),
            expiresAtUnixMillis: 200_000
        )
        let resolver = BurnBarSafariAppGroupPayloadResolver(trustedRoot: root)
        XCTAssertThrowsError(
            try resolver.resolve(traversal, now: Date(timeIntervalSince1970: 100))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarSafariAppGroupPayloadError,
                .pathOutsideTrustedRoot
            )
        }

        let link = root.appendingPathComponent("linked.payload")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )
        let symlink = BurnBarSafariAppGroupPayloadReference(
            filePath: link.path,
            byteLength: outsideData.count,
            sha256: sha256Hex(outsideData),
            expiresAtUnixMillis: 200_000
        )
        XCTAssertThrowsError(
            try resolver.resolve(symlink, now: Date(timeIntervalSince1970: 100))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarSafariAppGroupPayloadError,
                .symbolicLinkRejected
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func test_payloadResolverRejectsPermissionsHashExpiryAndOversize() throws {
        let root = try temporaryRoot()
        let store = BurnBarSafariAppGroupPayloadStore(
            trustedRoot: root,
            lifetime: 10
        )
        let resolver = BurnBarSafariAppGroupPayloadResolver(trustedRoot: root)
        let payload = Data("integrity".utf8)

        let insecure = try store.store(payload, now: Date(timeIntervalSince1970: 100))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: insecure.filePath
        )
        XCTAssertThrowsError(
            try resolver.resolve(insecure, now: Date(timeIntervalSince1970: 101))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarSafariAppGroupPayloadError,
                .insecurePermissions
            )
        }

        let hashed = try store.store(payload, now: Date(timeIntervalSince1970: 100))
        let wrongHash = BurnBarSafariAppGroupPayloadReference(
            filePath: hashed.filePath,
            byteLength: hashed.byteLength,
            sha256: String(repeating: "0", count: 64),
            expiresAtUnixMillis: hashed.expiresAtUnixMillis
        )
        XCTAssertThrowsError(
            try resolver.resolve(wrongHash, now: Date(timeIntervalSince1970: 101))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarSafariAppGroupPayloadError,
                .digestMismatch
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hashed.filePath))

        let expired = try store.store(payload, now: Date(timeIntervalSince1970: 100))
        XCTAssertThrowsError(
            try resolver.resolve(expired, now: Date(timeIntervalSince1970: 111))
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariAppGroupPayloadError, .expired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.filePath))

        let oversized = Data(
            repeating: 0xA5,
            count: BurnBarSafariBridgeWire.maximumChunkedPayloadBytes + 1
        )
        XCTAssertThrowsError(try store.store(oversized)) { error in
            XCTAssertEqual(error as? BurnBarSafariAppGroupPayloadError, .oversized)
        }
    }

    func test_externalizingTransportUsesMarkerOnlyAfterExactRequestBoundFailure() throws {
        let root = try temporaryRoot()
        let store = BurnBarSafariAppGroupPayloadStore(trustedRoot: root)
        let resolver = BurnBarSafariAppGroupPayloadResolver(trustedRoot: root)
        let probe = ExternalizingSenderProbe(resolver: resolver)
        let transport = BurnBarSafariDaemonRPCTransport.externalizing(
            payloadStore: store,
            primarySender: probe.send
        )
        let original: BurnBarJSONValue = .object([
            "page": .string(String(repeating: "x", count: 96 * 1024))
        ])

        let result = try transport.send(
            method: .safariPageContext,
            id: "oversized-request",
            params: original
        )
        XCTAssertEqual(result, .object(["accepted": .bool(true)]))
        XCTAssertEqual(probe.callCount, 2)
        XCTAssertEqual(probe.resolvedPayload, try JSONEncoder().encode(original))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(probe.reference).filePath
            ),
            "daemon-side one-shot resolution must consume the externalized payload"
        )
    }

    func test_chunkStoreCommitsOutOfOrderChunksInDeclaredOrder() throws {
        let root = try temporaryRoot()
        let store = BurnBarSafariBridgeChunkStore(
            trustedRoot: root,
            profileIdentifier: "ordering"
        )
        let chunks = [Data("first-".utf8), Data("second-".utf8), Data("third".utf8)]
        let payload = chunks.reduce(into: Data()) { $0.append($1) }
        try store.begin(
            transferID: "ordered-transfer",
            originalMethod: .poll,
            byteLength: payload.count,
            chunkCount: chunks.count,
            sha256: sha256Hex(payload)
        )
        try store.append(
            transferID: "ordered-transfer",
            index: 2,
            base64Data: chunks[2].base64EncodedString()
        )
        try store.append(
            transferID: "ordered-transfer",
            index: 0,
            base64Data: chunks[0].base64EncodedString()
        )
        try store.append(
            transferID: "ordered-transfer",
            index: 1,
            base64Data: chunks[1].base64EncodedString()
        )

        let committed = try store.commit(transferID: "ordered-transfer")
        XCTAssertEqual(committed.originalMethod, .poll)
        XCTAssertEqual(committed.payload, payload)
        XCTAssertThrowsError(try store.commit(transferID: "ordered-transfer")) { error in
            XCTAssertEqual(error as? BurnBarSafariChunkStoreError, .transferNotFound)
        }
    }

    func test_chunkStoreRejectsDuplicateDigestExpiryAndBounds() throws {
        let root = try temporaryRoot()
        let store = BurnBarSafariBridgeChunkStore(
            trustedRoot: root,
            profileIdentifier: "integrity",
            transferLifetime: 5,
            maximumActiveTransfers: 2
        )
        let payload = Data("chunk".utf8)
        try store.begin(
            transferID: "duplicate-transfer",
            originalMethod: .complete,
            byteLength: payload.count,
            chunkCount: 1,
            sha256: sha256Hex(payload),
            now: Date(timeIntervalSince1970: 100)
        )
        try store.append(
            transferID: "duplicate-transfer",
            index: 0,
            base64Data: payload.base64EncodedString(),
            now: Date(timeIntervalSince1970: 101)
        )
        XCTAssertThrowsError(
            try store.append(
                transferID: "duplicate-transfer",
                index: 0,
                base64Data: payload.base64EncodedString(),
                now: Date(timeIntervalSince1970: 101)
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariChunkStoreError, .duplicateChunk)
        }

        try store.begin(
            transferID: "hash-transfer",
            originalMethod: .poll,
            byteLength: payload.count,
            chunkCount: 1,
            sha256: String(repeating: "0", count: 64),
            now: Date(timeIntervalSince1970: 100)
        )
        try store.append(
            transferID: "hash-transfer",
            index: 0,
            base64Data: payload.base64EncodedString(),
            now: Date(timeIntervalSince1970: 101)
        )
        XCTAssertThrowsError(
            try store.commit(
                transferID: "hash-transfer",
                now: Date(timeIntervalSince1970: 101)
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariChunkStoreError, .digestMismatch)
        }

        XCTAssertThrowsError(
            try store.commit(
                transferID: "duplicate-transfer",
                now: Date(timeIntervalSince1970: 106)
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariChunkStoreError, .expired)
        }

        XCTAssertThrowsError(
            try store.begin(
                transferID: "oversized-transfer",
                originalMethod: .poll,
                byteLength: BurnBarSafariBridgeWire.maximumChunkedPayloadBytes + 1,
                chunkCount: 1,
                sha256: sha256Hex(payload)
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariChunkStoreError, .invalidMetadata)
        }
        XCTAssertThrowsError(
            try store.begin(
                transferID: "recursive-transfer",
                originalMethod: .chunkCommit,
                byteLength: payload.count,
                chunkCount: 1,
                sha256: sha256Hex(payload)
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarSafariChunkStoreError, .invalidMetadata)
        }
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class ExternalizingSenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let resolver: BurnBarSafariAppGroupPayloadResolver
    private var calls = 0
    private var payload: Data?
    private var storedReference: BurnBarSafariAppGroupPayloadReference?

    init(resolver: BurnBarSafariAppGroupPayloadResolver) {
        self.resolver = resolver
    }

    lazy var send: BurnBarSafariDaemonRPCTransport.Sender = { [self] _, _, params in
        lock.lock()
        calls += 1
        let currentCall = calls
        lock.unlock()

        if currentCall == 1 {
            throw BurnBarSafariDaemonSocketError.requestTooLarge
        }
        let reference = try BurnBarSafariAppGroupPayloadReference.decodeMarker(from: params)
        let resolved = try resolver.resolve(reference)
        lock.lock()
        storedReference = reference
        payload = resolved
        lock.unlock()
        return .object(["accepted": .bool(true)])
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var resolvedPayload: Data? {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    var reference: BurnBarSafariAppGroupPayloadReference? {
        lock.lock()
        defer { lock.unlock() }
        return storedReference
    }
}

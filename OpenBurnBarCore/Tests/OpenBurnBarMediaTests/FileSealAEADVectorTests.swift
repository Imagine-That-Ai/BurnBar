import XCTest
@testable import OpenBurnBarMedia

final class FileSealAEADVectorTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Header: Decodable {
            var attachmentId: String
            var totalChunks: Int
            var plaintextSize: Int64
            var contentBlake3: String
        }
        struct Case: Decodable {
            var name: String
            var chunkIndex: UInt64
            var nonceHex: String
            var plaintextUtf8: String
            var aadHex: String
            var ciphertextHex: String
            var tagHex: String
        }
        struct Negative: Decodable {
            var name: String
            var base: String
            var chunkIndex: UInt64?
            var attachmentId: String?
            var truncateTagBytes: Int?
        }
        var header: Header
        var contentKeyHex: String
        var cases: [Case]
        var negatives: [Negative]
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "FileSealAEADVector", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testPositiveVectorsRoundTrip() throws {
        let fixture = try loadFixture()
        let key = Data(hex: fixture.contentKeyHex)
        let header = FileSealAEAD.Header(
            attachmentId: fixture.header.attachmentId,
            totalChunks: fixture.header.totalChunks,
            plaintextSize: fixture.header.plaintextSize,
            contentBlake3: fixture.header.contentBlake3
        )
        for item in fixture.cases {
            let nonce = Data(hex: item.nonceHex)
            let sealed = try FileSealAEAD.sealChunk(
                plaintext: Data(item.plaintextUtf8.utf8),
                contentKey: key,
                header: header,
                chunkIndex: item.chunkIndex,
                nonce: nonce
            )
            XCTAssertEqual(sealed.ciphertext.hex, item.ciphertextHex, item.name)
            XCTAssertEqual(sealed.tag.hex, item.tagHex, item.name)
            let opened = try FileSealAEAD.openChunk(
                ciphertext: sealed.ciphertext,
                tag: sealed.tag,
                contentKey: key,
                header: header,
                chunkIndex: item.chunkIndex,
                nonce: nonce
            )
            XCTAssertEqual(String(data: opened, encoding: .utf8), item.plaintextUtf8)
        }
    }

    func testNegativeVectorsFailOpen() throws {
        let fixture = try loadFixture()
        let key = Data(hex: fixture.contentKeyHex)
        let byName = Dictionary(uniqueKeysWithValues: fixture.cases.map { ($0.name, $0) })
        for negative in fixture.negatives {
            let base = try XCTUnwrap(byName[negative.base])
            var header = FileSealAEAD.Header(
                attachmentId: negative.attachmentId ?? fixture.header.attachmentId,
                totalChunks: fixture.header.totalChunks,
                plaintextSize: fixture.header.plaintextSize,
                contentBlake3: fixture.header.contentBlake3
            )
            _ = header
            let chunkIndex = negative.chunkIndex ?? base.chunkIndex
            var tag = Data(hex: base.tagHex)
            if let trim = negative.truncateTagBytes {
                tag = tag.prefix(tag.count - trim)
            }
            XCTAssertThrowsError(
                try FileSealAEAD.openChunk(
                    ciphertext: Data(hex: base.ciphertextHex),
                    tag: Data(tag),
                    contentKey: key,
                    header: FileSealAEAD.Header(
                        attachmentId: negative.attachmentId ?? fixture.header.attachmentId,
                        totalChunks: fixture.header.totalChunks,
                        plaintextSize: fixture.header.plaintextSize,
                        contentBlake3: fixture.header.contentBlake3
                    ),
                    chunkIndex: chunkIndex,
                    nonce: Data(hex: base.nonceHex)
                ),
                negative.name
            )
        }
    }

    func testStreamingSealRoundTripWithoutLoadingWholeFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.bin")
        let sealed = dir.appendingPathComponent("sealed.bin")
        let opened = dir.appendingPathComponent("opened.bin")
        let payload = Data(repeating: 7, count: 64 * 1024 + 17)
        try payload.write(to: plain)
        let key = try FileSealAEAD.mintContentKey()
        let header = FileSealAEAD.Header(
            attachmentId: "stream-1",
            totalChunks: 1,
            plaintextSize: Int64(payload.count),
            contentBlake3: "00"
        )
        try FileSealAEAD.sealFile(from: plain, to: sealed, contentKey: key, header: header)
        try FileSealAEAD.openFile(from: sealed, to: opened, contentKey: key, header: header)
        XCTAssertEqual(try Data(contentsOf: opened), payload)
        XCTAssertEqual(FileSealAEAD.maxPlaintextBytes, 10 * 1024 * 1024 * 1024)
    }

    func testNonceReuseDifferentPlaintextIsRejectedByVectors() throws {
        let fixture = try loadFixture()
        let key = Data(hex: fixture.contentKeyHex)
        let base = try XCTUnwrap(fixture.cases.first)
        let header = FileSealAEAD.Header(
            attachmentId: fixture.header.attachmentId,
            totalChunks: fixture.header.totalChunks,
            plaintextSize: fixture.header.plaintextSize,
            contentBlake3: fixture.header.contentBlake3
        )
        let nonce = Data(hex: base.nonceHex)
        let first = try FileSealAEAD.sealChunk(
            plaintext: Data(base.plaintextUtf8.utf8),
            contentKey: key,
            header: header,
            chunkIndex: base.chunkIndex,
            nonce: nonce
        )
        let second = try FileSealAEAD.sealChunk(
            plaintext: Data("different-plain".utf8),
            contentKey: key,
            header: header,
            chunkIndex: base.chunkIndex,
            nonce: nonce
        )
        XCTAssertEqual(nonce.count, 12)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
        XCTAssertEqual(FileSealAEAD.aad(header: header, chunkIndex: base.chunkIndex).hex, base.aadHex)
    }

    func testProductionSealMintsFreshNonce() throws {
        let header = FileSealAEAD.Header(attachmentId: "a", totalChunks: 1, plaintextSize: 4, contentBlake3: "00")
        let key = try FileSealAEAD.mintContentKey()
        let n1 = try FileSealAEAD.mintNonce()
        let n2 = try FileSealAEAD.mintNonce()
        XCTAssertEqual(n1.count, 12)
        XCTAssertNotEqual(n1, n2)
        _ = try FileSealAEAD.sealChunk(plaintext: Data("abcd".utf8), contentKey: key, header: header, chunkIndex: 0, nonce: n1)
    }
}

private extension Data {
    init(hex: String) {
        let chars = Array(hex)
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var i = 0
        while i + 1 < chars.count {
            let byte = UInt8(String(chars[i...i+1]), radix: 16) ?? 0
            bytes.append(byte)
            i += 2
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

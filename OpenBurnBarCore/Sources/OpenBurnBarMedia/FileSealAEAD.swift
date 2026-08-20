import Foundation
import OpenBurnBarKernel

/// OBFS1 — chunked AES-GCM file seal. Random 12-byte IVs are stored with each
/// chunk. Never HKDF-derive the nonce; a retry mints a new IV.
public enum FileSealAEAD {
    public static let chunkPlaintextBytes = 32 * 1024 * 1024
    public static let nonceSize = 12
    public static let tagSize = 16
    public static let maxPlaintextBytes: Int64 = 2 * 1024 * 1024 * 1024

    public enum Error: Swift.Error, Equatable {
        case invalidNonce
        case invalidKey
        case truncatedChunk
        case chunkCountMismatch
        case plaintextTooLarge
    }

    public struct Header: Equatable, Sendable {
        public var attachmentId: String
        public var totalChunks: Int
        public var plaintextSize: Int64
        public var contentBlake3: String

        public init(attachmentId: String, totalChunks: Int, plaintextSize: Int64, contentBlake3: String) {
            self.attachmentId = attachmentId
            self.totalChunks = totalChunks
            self.plaintextSize = plaintextSize
            self.contentBlake3 = contentBlake3
        }
    }

    public static func mintContentKey() throws -> Data {
        try PlatformCrypto.secureRandomBytes(count: 32)
    }

    public static func mintNonce() throws -> Data {
        try PlatformCrypto.secureRandomBytes(count: nonceSize)
    }

    public static func aad(header: Header, chunkIndex: UInt64) -> Data {
        var data = Data(header.attachmentId.utf8)
        func appendBE(_ value: UInt64) {
            var be = value.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        appendBE(chunkIndex)
        appendBE(UInt64(header.totalChunks))
        appendBE(UInt64(bitPattern: header.plaintextSize))
        return data
    }

    public static func sealChunk(
        plaintext: Data,
        contentKey: Data,
        header: Header,
        chunkIndex: UInt64,
        nonce: Data
    ) throws -> (ciphertext: Data, tag: Data) {
        guard nonce.count == nonceSize else { throw Error.invalidNonce }
        guard contentKey.count == 32 else { throw Error.invalidKey }
        let sealed = try PlatformCrypto.sealAESGCMDetached(
            plaintext: plaintext,
            keyData: contentKey,
            nonce: nonce,
            authenticating: aad(header: header, chunkIndex: chunkIndex)
        )
        return (sealed.ciphertext, sealed.tag)
    }

    public static func openChunk(
        ciphertext: Data,
        tag: Data,
        contentKey: Data,
        header: Header,
        chunkIndex: UInt64,
        nonce: Data
    ) throws -> Data {
        guard nonce.count == nonceSize else { throw Error.invalidNonce }
        guard contentKey.count == 32 else { throw Error.invalidKey }
        return try PlatformCrypto.openAESGCMDetached(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            keyData: contentKey,
            authenticating: aad(header: header, chunkIndex: chunkIndex)
        )
    }

    /// Stream-seal `source` into `destination` without loading the whole file.
    public static func sealFile(
        from source: URL,
        to destination: URL,
        contentKey: Data,
        header: Header
    ) throws {
        guard header.plaintextSize <= maxPlaintextBytes else { throw Error.plaintextTooLarge }
        let inHandle = try FileHandle(forReadingFrom: source)
        defer { try? inHandle.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destination)
        defer { try? outHandle.close() }
        var index: UInt64 = 0
        while true {
            let chunk = inHandle.readData(ofLength: chunkPlaintextBytes)
            if chunk.isEmpty { break }
            let nonce = try mintNonce()
            let sealed = try sealChunk(
                plaintext: chunk,
                contentKey: contentKey,
                header: header,
                chunkIndex: index,
                nonce: nonce
            )
            var wire = nonce
            wire.append(sealed.ciphertext)
            wire.append(sealed.tag)
            outHandle.write(wire)
            index += 1
        }
        guard Int(index) == header.totalChunks else { throw Error.chunkCountMismatch }
    }

    /// Stream-open `source` into `destination` without loading the whole ciphertext.
    public static func openFile(
        from source: URL,
        to destination: URL,
        contentKey: Data,
        header: Header
    ) throws {
        let inHandle = try FileHandle(forReadingFrom: source)
        defer { try? inHandle.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: destination)
        defer { try? outHandle.close() }
        var remaining = header.plaintextSize
        for index in 0..<header.totalChunks {
            let plaintextLen = Int(min(Int64(chunkPlaintextBytes), remaining))
            let wireLen = nonceSize + plaintextLen + tagSize
            let wire = inHandle.readData(ofLength: wireLen)
            guard wire.count == wireLen else { throw Error.truncatedChunk }
            let nonce = wire.prefix(nonceSize)
            let tag = wire.suffix(tagSize)
            let ciphertext = wire.dropFirst(nonceSize).dropLast(tagSize)
            let plain = try openChunk(
                ciphertext: Data(ciphertext),
                tag: Data(tag),
                contentKey: contentKey,
                header: header,
                chunkIndex: UInt64(index),
                nonce: Data(nonce)
            )
            outHandle.write(plain)
            remaining -= Int64(plain.count)
        }
        guard remaining == 0 else { throw Error.chunkCountMismatch }
    }
}

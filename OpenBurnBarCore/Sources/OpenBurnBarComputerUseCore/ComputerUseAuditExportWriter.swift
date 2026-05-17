import Foundation
import CryptoKit
import zlib

/// Phase 13 audit-export writer.
///
/// Produces a real POSIX ustar archive, compresses it as gzip, and can
/// write a detached JSON signature next to the archive. The archive contains
/// the session `manifest.json`, `chain.jsonl`, optional `head.json`, and
/// optional screenshot PNGs.
public struct ComputerUseAuditExportWriter {
    public enum WriterError: Error, Sendable, Equatable {
        case sessionDirectoryMissing
        case chainFileMissing
        case manifestMissing
        case pathTooLong(String)
        case gzipFailed(String)
        case writeFailed(String)
        case verificationFailed(String)
    }

    public struct ExportResult: Sendable {
        public let archiveURL: URL
        public let signatureURL: URL?
        public let archiveSizeBytes: Int64
        public let entryCount: Int
        public let headHashHex: String
        public let archiveSHA256Hex: String
        public let signature: ComputerUseAuditExportSignature?
    }

    public let fileManager: FileManager
    public let hasher: ComputerUseAuditHasher

    public init(fileManager: FileManager = .default, hasher: ComputerUseAuditHasher = .current) {
        self.fileManager = fileManager
        self.hasher = hasher
    }

    /// Build a signed `.tar.gz` archive of `sessionDirectory` at
    /// `destinationURL`. Includes screenshots if `includeScreenshots` is true.
    @discardableResult
    public func export(
        sessionDirectory: URL,
        destinationURL: URL,
        includeScreenshots: Bool,
        signer: ComputerUseAuditExportSigning? = nil
    ) throws -> ExportResult {
        guard fileManager.fileExists(atPath: sessionDirectory.path) else {
            throw WriterError.sessionDirectoryMissing
        }
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let chainURL = sessionDirectory.appendingPathComponent("chain.jsonl")
        let headURL = sessionDirectory.appendingPathComponent("head.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw WriterError.manifestMissing }
        guard fileManager.fileExists(atPath: chainURL.path) else { throw WriterError.chainFileMissing }

        let entries = try collectEntries(
            sessionDirectory: sessionDirectory,
            manifestURL: manifestURL,
            chainURL: chainURL,
            headURL: headURL,
            includeScreenshots: includeScreenshots
        )

        let tar = try buildTar(entries: entries)
        let archive = try gzipCompress(tar)
        do {
            try archive.write(to: destinationURL, options: [.atomic])
        } catch {
            throw WriterError.writeFailed(error.localizedDescription)
        }

        let archiveSHA256Hex = hasher.hash(data: archive)
        let signature: ComputerUseAuditExportSignature?
        let signatureURL: URL?
        if let signer {
            let signedBytes = try signer.sign(archive)
            let record = ComputerUseAuditExportSignature(
                archiveFilename: destinationURL.lastPathComponent,
                archiveSHA256Hex: archiveSHA256Hex,
                algorithm: signer.algorithm,
                signerIdentifier: signer.signerIdentifier,
                publicKeyBase64: signer.publicKeyBase64,
                signatureBase64: signedBytes.base64EncodedString(),
                signedAt: Date()
            )
            let sidecarURL = destinationURL.appendingPathExtension("sig.json")
            do {
                try ComputerUseAuditHasher.canonicalJSONEncoder
                    .encode(record)
                    .write(to: sidecarURL, options: [.atomic])
            } catch {
                throw WriterError.writeFailed(error.localizedDescription)
            }
            signature = record
            signatureURL = sidecarURL
        } else {
            signature = nil
            signatureURL = nil
        }

        let headHashHex = try ComputerUseAuditChain(hasher: hasher)
            .validate(at: chainURL, sessionManifestHashHex: hasher.hash(data: entries[0].content))
            .headHashHex ?? ""

        return ExportResult(
            archiveURL: destinationURL,
            signatureURL: signatureURL,
            archiveSizeBytes: Int64(archive.count),
            entryCount: entries.count,
            headHashHex: headHashHex,
            archiveSHA256Hex: archiveSHA256Hex,
            signature: signature
        )
    }

    /// Verify the gzip/tar archive and, when provided, its detached signature.
    public func verify(
        archive archiveURL: URL,
        signatureURL: URL? = nil
    ) throws -> [(path: String, sha256: Data, size: Int)] {
        let archive = try Data(contentsOf: archiveURL)
        if let signatureURL {
            try verifySignature(archive: archive, signatureURL: signatureURL, archiveFilename: archiveURL.lastPathComponent)
        }
        let tar = try gzipDecompress(archive)
        return try parseTar(tar)
    }

    private func collectEntries(
        sessionDirectory: URL,
        manifestURL: URL,
        chainURL: URL,
        headURL: URL,
        includeScreenshots: Bool
    ) throws -> [(path: String, content: Data)] {
        var entries: [(path: String, content: Data)] = []
        entries.append(("manifest.json", try Data(contentsOf: manifestURL)))
        entries.append(("chain.jsonl", try Data(contentsOf: chainURL)))
        if fileManager.fileExists(atPath: headURL.path) {
            entries.append(("head.json", try Data(contentsOf: headURL)))
        }
        if includeScreenshots {
            let screenshotsDir = sessionDirectory.appendingPathComponent("screenshots", isDirectory: true)
            if let contents = try? fileManager.contentsOfDirectory(at: screenshotsDir, includingPropertiesForKeys: nil) {
                for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard !url.hasDirectoryPath else { continue }
                    entries.append(("screenshots/" + url.lastPathComponent, try Data(contentsOf: url)))
                }
            }
        }
        return entries
    }

    private func buildTar(entries: [(path: String, content: Data)]) throws -> Data {
        var tar = Data()
        for entry in entries {
            let header = try tarHeader(path: entry.path, size: entry.content.count)
            tar.append(header)
            tar.append(entry.content)
            let padding = (512 - (entry.content.count % 512)) % 512
            if padding > 0 {
                tar.append(Data(repeating: 0, count: padding))
            }
        }
        tar.append(Data(repeating: 0, count: 1024))
        return tar
    }

    private func tarHeader(path: String, size: Int) throws -> Data {
        guard let pathData = path.data(using: .utf8), pathData.count <= 100 else {
            throw WriterError.pathTooLong(path)
        }
        var header = [UInt8](repeating: 0, count: 512)
        write(pathData, into: &header, at: 0, length: 100)
        writeOctal(0o644, into: &header, at: 100, length: 8)
        writeOctal(0, into: &header, at: 108, length: 8)
        writeOctal(0, into: &header, at: 116, length: 8)
        writeOctal(size, into: &header, at: 124, length: 12)
        writeOctal(Int(Date().timeIntervalSince1970), into: &header, at: 136, length: 12)
        for i in 148..<156 { header[i] = 0x20 }
        header[156] = UInt8(ascii: "0")
        write(Data("ustar\u{0}".utf8), into: &header, at: 257, length: 6)
        write(Data("00".utf8), into: &header, at: 263, length: 2)
        write(Data("openburnbar".utf8), into: &header, at: 265, length: 32)
        write(Data("openburnbar".utf8), into: &header, at: 297, length: 32)

        let checksum = header.reduce(0) { $0 + Int($1) }
        let checksumString = String(checksum, radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - checksumString.count)) + checksumString
        write(Data(padded.utf8), into: &header, at: 148, length: 6)
        header[154] = 0
        header[155] = 0x20
        return Data(header)
    }

    private func parseTar(_ tar: Data) throws -> [(path: String, sha256: Data, size: Int)] {
        var offset = 0
        var results: [(path: String, sha256: Data, size: Int)] = []
        while offset + 512 <= tar.count {
            let block = tar.subdata(in: offset..<(offset + 512))
            offset += 512
            if block.allSatisfy({ $0 == 0 }) {
                break
            }
            let nameBytes = block[0..<100].prefix { $0 != 0 }
            guard let path = String(data: Data(nameBytes), encoding: .utf8), !path.isEmpty else {
                throw WriterError.verificationFailed("bad tar path")
            }
            let storedChecksum = try parseOctal(block[148..<156])
            var checksumBlock = [UInt8](block)
            for i in 148..<156 { checksumBlock[i] = 0x20 }
            let observedChecksum = checksumBlock.reduce(0) { $0 + Int($1) }
            guard storedChecksum == observedChecksum else {
                throw WriterError.verificationFailed("tar checksum mismatch at \(path)")
            }
            let size = try parseOctal(block[124..<136])
            guard offset + size <= tar.count else {
                throw WriterError.verificationFailed("truncated tar entry \(path)")
            }
            let content = tar.subdata(in: offset..<(offset + size))
            offset += size
            let padding = (512 - (size % 512)) % 512
            offset += padding
            results.append((path, hashSHA256(content), size))
        }
        return results
    }

    private func verifySignature(archive: Data, signatureURL: URL, archiveFilename: String) throws {
        let record = try ComputerUseAuditHasher.canonicalJSONDecoder
            .decode(ComputerUseAuditExportSignature.self, from: Data(contentsOf: signatureURL))
        guard record.archiveFilename == archiveFilename else {
            throw WriterError.verificationFailed("signature filename mismatch")
        }
        guard record.archiveSHA256Hex == hasher.hash(data: archive) else {
            throw WriterError.verificationFailed("signature archive hash mismatch")
        }
        guard record.algorithm == ComputerUseEd25519AuditExportSigner.algorithmName,
              let publicKeyBase64 = record.publicKeyBase64,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signature = Data(base64Encoded: record.signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: archive) else {
            throw WriterError.verificationFailed("signature validation failed")
        }
    }

    private func gzipCompress(_ input: Data) throws -> Data {
        try zlibTransform(input: input, operation: .deflate)
    }

    private func gzipDecompress(_ input: Data) throws -> Data {
        try zlibTransform(input: input, operation: .inflate)
    }

    private enum ZlibOperation {
        case deflate
        case inflate
    }

    private func zlibTransform(input: Data, operation: ZlibOperation) throws -> Data {
        var stream = z_stream()
        let initStatus: Int32
        switch operation {
        case .deflate:
            initStatus = deflateInit2_(
                &stream,
                Z_BEST_COMPRESSION,
                Z_DEFLATED,
                MAX_WBITS + 16,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        case .inflate:
            initStatus = inflateInit2_(
                &stream,
                MAX_WBITS + 16,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }
        guard initStatus == Z_OK else {
            throw WriterError.gzipFailed("zlib init failed: \(initStatus)")
        }
        defer {
            switch operation {
            case .deflate: _ = deflateEnd(&stream)
            case .inflate: _ = inflateEnd(&stream)
            }
        }

        return try input.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Data()
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = uInt(input.count)

            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            var status: Int32
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { ptr in
                    stream.next_out = ptr.baseAddress
                    stream.avail_out = uInt(ptr.count)
                    switch operation {
                    case .deflate:
                        return deflate(&stream, Z_FINISH)
                    case .inflate:
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                }
                let produced = buffer.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status != Z_OK && status != Z_STREAM_END {
                    throw WriterError.gzipFailed("zlib transform failed: \(status)")
                }
            } while status != Z_STREAM_END
            return output
        }
    }

    private func write(_ data: Data, into header: inout [UInt8], at offset: Int, length: Int) {
        let bytes = Array(data.prefix(length))
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
    }

    private func writeOctal(_ value: Int, into header: inout [UInt8], at offset: Int, length: Int) {
        let raw = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - raw.count)) + raw
        write(Data(padded.utf8), into: &header, at: offset, length: length - 1)
        header[offset + length - 1] = 0
    }

    private func parseOctal(_ bytes: Data.SubSequence) throws -> Int {
        let trimmed = bytes
            .filter { $0 != 0 && $0 != 0x20 }
        guard let text = String(data: Data(trimmed), encoding: .ascii),
              let value = Int(text, radix: 8) else {
            throw WriterError.verificationFailed("bad octal field")
        }
        return value
    }

    private func hashSHA256(_ data: Data) -> Data {
        Data(ComputerUseAuditHasher.current.sha256DigestBytes(of: data))
    }
}

public struct ComputerUseAuditExportSignature: Codable, Hashable, Sendable {
    public let archiveFilename: String
    public let archiveSHA256Hex: String
    public let algorithm: String
    public let signerIdentifier: String
    public let publicKeyBase64: String?
    public let signatureBase64: String
    public let signedAt: Date

    public init(
        archiveFilename: String,
        archiveSHA256Hex: String,
        algorithm: String,
        signerIdentifier: String,
        publicKeyBase64: String?,
        signatureBase64: String,
        signedAt: Date
    ) {
        self.archiveFilename = archiveFilename
        self.archiveSHA256Hex = archiveSHA256Hex
        self.algorithm = algorithm
        self.signerIdentifier = signerIdentifier
        self.publicKeyBase64 = publicKeyBase64
        self.signatureBase64 = signatureBase64
        self.signedAt = signedAt
    }
}

public protocol ComputerUseAuditExportSigning: Sendable {
    var algorithm: String { get }
    var signerIdentifier: String { get }
    var publicKeyBase64: String? { get }
    func sign(_ data: Data) throws -> Data
}

public struct ComputerUseEd25519AuditExportSigner: ComputerUseAuditExportSigning {
    public static let algorithmName = "ed25519"

    public let privateKey: Curve25519.Signing.PrivateKey
    public let signerIdentifier: String

    public var algorithm: String { Self.algorithmName }
    public var publicKeyBase64: String? {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    public init(
        privateKey: Curve25519.Signing.PrivateKey,
        signerIdentifier: String
    ) {
        self.privateKey = privateKey
        self.signerIdentifier = signerIdentifier
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }
}

internal extension ComputerUseAuditHasher {
    func sha256DigestBytes(of data: Data) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: data))
    }
}

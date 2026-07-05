import Foundation
import OpenBurnBarCore
#if os(Windows)
#elseif canImport(zlib)
import zlib
#elseif canImport(Czlib)
import Czlib
#endif

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

        if let signer {
            try ComputerUseAuditHeadFinalizer.finalizeSessionDirectory(
                sessionDirectory,
                signer: signer,
                fileManager: fileManager
            )
        }

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
                signerKind: signer.signerKind,
                trustRoot: signer.trustRoot,
                publicKeyBase64: signer.publicKeyBase64,
                publicKeySHA256Hex: signer.publicKeySHA256Hex,
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
        signatureURL: URL? = nil,
        signatureTrust: ComputerUseAuditExportSignatureTrust = .sidecarOnly
    ) throws -> [(path: String, sha256: Data, size: Int)] {
        let archive = try Data(contentsOf: archiveURL)
        if let signatureURL {
            try verifySignature(
                archive: archive,
                signatureURL: signatureURL,
                archiveFilename: archiveURL.lastPathComponent,
                signatureTrust: signatureTrust
            )
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
        let signedHeadURL = sessionDirectory.appendingPathComponent(ComputerUseAuditHeadFinalizer.signedHeadFilename)
        if fileManager.fileExists(atPath: signedHeadURL.path) {
            entries.append((ComputerUseAuditHeadFinalizer.signedHeadFilename, try Data(contentsOf: signedHeadURL)))
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

    private func verifySignature(
        archive: Data,
        signatureURL: URL,
        archiveFilename: String,
        signatureTrust: ComputerUseAuditExportSignatureTrust
    ) throws {
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
              let publicKey = try? PlatformCrypto.ed25519PublicKey(rawRepresentation: publicKeyData),
              (try? PlatformCrypto.verifyEd25519Signature(signature, message: archive, publicKey: publicKey)) == true else {
            throw WriterError.verificationFailed("signature validation failed")
        }
        if let expectedPublicKeyHash = record.publicKeySHA256Hex,
           hasher.hash(data: publicKeyData) != expectedPublicKeyHash {
            throw WriterError.verificationFailed("signature public-key hash mismatch")
        }
        switch signatureTrust {
        case .sidecarOnly:
            break
        case .trustedDeviceReadback(let readback):
            try verifyTrustedDeviceReadback(record: record, readback: readback)
        }
    }

    private func verifyTrustedDeviceReadback(
        record: ComputerUseAuditExportSignature,
        readback: ComputerUseAuditExportSignerReadback
    ) throws {
        guard readback.status == .active,
              readback.revokedAtMillis == nil else {
            throw WriterError.verificationFailed("signature signer readback is revoked")
        }
        guard readback.algorithm == record.algorithm,
              readback.signerIdentifier == record.signerIdentifier,
              readback.signerKind == record.signerKind,
              readback.trustRoot == record.trustRoot,
              readback.publicKeyBase64 == record.publicKeyBase64,
              readback.publicKeySHA256Hex == record.publicKeySHA256Hex else {
            throw WriterError.verificationFailed("signature signer readback mismatch")
        }
    }

    private func gzipCompress(_ input: Data) throws -> Data {
        #if os(Windows)
        return Self.gzipStoredDeflate(input)
        #else
        return try zlibTransform(input: input, operation: .deflate)
        #endif
    }

    private func gzipDecompress(_ input: Data) throws -> Data {
        #if os(Windows)
        return try Self.gunzipStoredDeflate(input)
        #else
        return try zlibTransform(input: input, operation: .inflate)
        #endif
    }

    #if os(Windows)
    /// Windows Swift SDKs do not currently ship a zlib development header in
    /// the default toolchain image. Gzip permits deflate streams made entirely
    /// of stored (uncompressed) blocks, so Windows can still produce and verify
    /// standards-compliant `.tar.gz` archives without a native zlib binding.
    private static func gzipStoredDeflate(_ input: Data) -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        if input.isEmpty {
            output.append(0x01)
            appendLittleEndianUInt16(0, to: &output)
            appendLittleEndianUInt16(UInt16.max, to: &output)
        } else {
            var offset = 0
            while offset < input.count {
                let chunkCount = min(65_535, input.count - offset)
                output.append(offset + chunkCount == input.count ? 0x01 : 0x00)
                let len = UInt16(chunkCount)
                appendLittleEndianUInt16(len, to: &output)
                appendLittleEndianUInt16(~len, to: &output)
                output.append(input.subdata(in: offset..<(offset + chunkCount)))
                offset += chunkCount
            }
        }
        appendLittleEndianUInt32(crc32(input), to: &output)
        appendLittleEndianUInt32(UInt32(truncatingIfNeeded: input.count), to: &output)
        return output
    }

    private static func gunzipStoredDeflate(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        guard bytes.count >= 18,
              bytes[0] == 0x1f,
              bytes[1] == 0x8b,
              bytes[2] == 0x08 else {
            throw WriterError.gzipFailed("invalid gzip header")
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw WriterError.gzipFailed("truncated gzip extra header") }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }

        var output = Data()
        var finalBlock = false
        while !finalBlock {
            guard offset + 5 <= bytes.count - 8 else { throw WriterError.gzipFailed("truncated stored deflate block") }
            let header = bytes[offset]
            offset += 1
            finalBlock = (header & 0x01) == 0x01
            guard ((header >> 1) & 0x03) == 0 else {
                throw WriterError.gzipFailed("unsupported deflate block type without zlib")
            }
            let len = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            let nlen = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
            offset += 4
            guard nlen == ~len else { throw WriterError.gzipFailed("invalid stored deflate length") }
            let chunkCount = Int(len)
            guard offset + chunkCount <= bytes.count - 8 else { throw WriterError.gzipFailed("truncated stored deflate payload") }
            output.append(contentsOf: bytes[offset..<(offset + chunkCount)])
            offset += chunkCount
        }
        guard offset + 8 <= bytes.count else { throw WriterError.gzipFailed("missing gzip trailer") }
        let expectedCRC = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        let expectedSize = UInt32(bytes[offset + 4])
            | (UInt32(bytes[offset + 5]) << 8)
            | (UInt32(bytes[offset + 6]) << 16)
            | (UInt32(bytes[offset + 7]) << 24)
        guard expectedCRC == crc32(output) else { throw WriterError.gzipFailed("gzip crc mismatch") }
        guard expectedSize == UInt32(truncatingIfNeeded: output.count) else { throw WriterError.gzipFailed("gzip size mismatch") }
        return output
    }

    private static func appendLittleEndianUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = 0 &- (crc & 1)
                crc = (crc >> 1) ^ (0xedb88320 & mask)
            }
        }
        return ~crc
    }
    #endif

    private enum ZlibOperation {
        case deflate
        case inflate
    }

    #if !os(Windows)
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
    #endif

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
    public let signerKind: String?
    public let trustRoot: String?
    public let publicKeyBase64: String?
    public let publicKeySHA256Hex: String?
    public let signatureBase64: String
    public let signedAt: Date

    public init(
        archiveFilename: String,
        archiveSHA256Hex: String,
        algorithm: String,
        signerIdentifier: String,
        signerKind: String? = nil,
        trustRoot: String? = nil,
        publicKeyBase64: String?,
        publicKeySHA256Hex: String? = nil,
        signatureBase64: String,
        signedAt: Date
    ) {
        self.archiveFilename = archiveFilename
        self.archiveSHA256Hex = archiveSHA256Hex
        self.algorithm = algorithm
        self.signerIdentifier = signerIdentifier
        self.signerKind = signerKind
        self.trustRoot = trustRoot
        self.publicKeyBase64 = publicKeyBase64
        self.publicKeySHA256Hex = publicKeySHA256Hex
        self.signatureBase64 = signatureBase64
        self.signedAt = signedAt
    }
}

public protocol ComputerUseAuditExportSigning: Sendable {
    var algorithm: String { get }
    var signerIdentifier: String { get }
    var signerKind: String? { get }
    var trustRoot: String? { get }
    var publicKeyBase64: String? { get }
    var publicKeySHA256Hex: String? { get }
    func sign(_ data: Data) throws -> Data
    /// Signs an already-canonical payload (used for WS3 `signed_head.json`).
    func signCanonicalPayload(_ payload: Data) throws -> Data
}

public enum ComputerUseAuditExportSignatureTrust: Sendable, Equatable {
    /// Offline archive verification. Validates archive hash, public-key hash,
    /// and Ed25519 signature using the public key embedded in `.sig.json`.
    case sidecarOnly

    /// Online trusted-device verification. In addition to sidecar checks,
    /// require a server readback record published beneath a trusted macOS
    /// `escrow_devices/{deviceId}` document.
    case trustedDeviceReadback(ComputerUseAuditExportSignerReadback)
}

public struct ComputerUseAuditExportSignerReadback: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case active
        case revoked
    }

    public static let signerKind = "openburnbar_trusted_device"
    public static let trustRoot = "openburnbar-trusted-device-keychain-v1"
    public static let algorithm = "ed25519"

    public let id: String
    public let userId: String
    public let deviceId: String
    public let signerIdentifier: String
    public let signerKind: String
    public let trustRoot: String
    public let algorithm: String
    public let publicKeyBase64: String
    public let publicKeySHA256Hex: String
    public let status: Status
    public let publishedAtMillis: Int64
    public let lastReadbackAtMillis: Int64?
    public let revokedAtMillis: Int64?
    public let revokedByDeviceId: String?
    public let schemaVersion: Int

    public init(
        id: String,
        userId: String,
        deviceId: String,
        signerIdentifier: String,
        signerKind: String = Self.signerKind,
        trustRoot: String = Self.trustRoot,
        algorithm: String = Self.algorithm,
        publicKeyBase64: String,
        publicKeySHA256Hex: String,
        status: Status = .active,
        publishedAtMillis: Int64,
        lastReadbackAtMillis: Int64? = nil,
        revokedAtMillis: Int64? = nil,
        revokedByDeviceId: String? = nil,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.userId = userId
        self.deviceId = deviceId
        self.signerIdentifier = signerIdentifier
        self.signerKind = signerKind
        self.trustRoot = trustRoot
        self.algorithm = algorithm
        self.publicKeyBase64 = publicKeyBase64
        self.publicKeySHA256Hex = publicKeySHA256Hex
        self.status = status
        self.publishedAtMillis = publishedAtMillis
        self.lastReadbackAtMillis = lastReadbackAtMillis
        self.revokedAtMillis = revokedAtMillis
        self.revokedByDeviceId = revokedByDeviceId
        self.schemaVersion = schemaVersion
    }

    public static func documentPath(userId: String, deviceId: String, publicKeySHA256Hex: String) -> String {
        "users/\(userId)/escrow_devices/\(deviceId)/computer_use_audit_export_signers/\(publicKeySHA256Hex)"
    }

    public static func fromSignature(
        _ signature: ComputerUseAuditExportSignature,
        userId: String,
        deviceId: String,
        publishedAtMillis: Int64
    ) throws -> ComputerUseAuditExportSignerReadback {
        guard let publicKeyBase64 = signature.publicKeyBase64,
              let publicKeySHA256Hex = signature.publicKeySHA256Hex else {
            throw ComputerUseAuditExportWriter.WriterError.verificationFailed("signature missing public-key readback metadata")
        }
        return ComputerUseAuditExportSignerReadback(
            id: publicKeySHA256Hex,
            userId: userId,
            deviceId: deviceId,
            signerIdentifier: signature.signerIdentifier,
            signerKind: signature.signerKind ?? "",
            trustRoot: signature.trustRoot ?? "",
            algorithm: signature.algorithm,
            publicKeyBase64: publicKeyBase64,
            publicKeySHA256Hex: publicKeySHA256Hex,
            publishedAtMillis: publishedAtMillis
        )
    }
}

public struct ComputerUseEd25519AuditExportSigner: ComputerUseAuditExportSigning {
    public static let algorithmName = "ed25519"

    public let privateKey: PlatformEd25519SigningMaterial
    public let signerIdentifier: String
    public let signerKind: String?
    public let trustRoot: String?

    public var algorithm: String { Self.algorithmName }
    public var publicKeyBase64: String? {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }
    public var publicKeySHA256Hex: String? {
        PlatformCrypto.sha256Hex(privateKey.publicKey.rawRepresentation)
    }

    public init(
        privateKey: PlatformEd25519SigningMaterial,
        signerIdentifier: String,
        signerKind: String? = "openburnbar_trusted_device",
        trustRoot: String? = "openburnbar-device-local-ed25519-v1"
    ) {
        self.privateKey = privateKey
        self.signerIdentifier = signerIdentifier
        self.signerKind = signerKind
        self.trustRoot = trustRoot
    }

    public func sign(_ data: Data) throws -> Data {
        try PlatformCrypto.ed25519Signature(message: data, privateKey: privateKey)
    }

    public func signCanonicalPayload(_ payload: Data) throws -> Data {
        try PlatformCrypto.ed25519Signature(message: payload, privateKey: privateKey)
    }
}

internal extension ComputerUseAuditHasher {
    func sha256DigestBytes(of data: Data) -> [UInt8] {
        Array(PlatformCrypto.sha256(data))
    }
}

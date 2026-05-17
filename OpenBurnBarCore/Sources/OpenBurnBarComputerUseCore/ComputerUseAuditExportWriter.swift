import Foundation
import CryptoKit

/// Phase 13 audit-export writer. Produces a single tar-like archive
/// containing the manifest, chain JSONL, head marker, and (optionally)
/// the screenshot PNGs. The archive is **not** a true tarball — to
/// avoid pulling a tar implementation we ship a self-describing
/// `.cua` (Computer Use Archive) format whose layout is:
///
/// ```
/// magic        : "CUARCHIVE\x01"    (10 bytes — version byte at the end)
/// entryCount   : u32 BE
/// entries      : repeated `entryCount` times:
///                  pathLength u16 BE
///                  path        utf8 bytes
///                  contentLen  u64 BE
///                  contentHash 32 bytes (SHA-256 of contentBytes)
///                  contentBytes raw bytes
/// trailerHash  : 32 bytes (SHA-256 of the entire stream up to here)
/// ```
///
/// Decoding is straightforward and a small `validate-computer-use-audit-chain`
/// CLI will be shipped alongside Phase 13 to walk the format and
/// re-validate the contained chain. The format is intentionally simpler
/// than tar — disputes do not need POSIX file metadata, just bytes.
public struct ComputerUseAuditExportWriter {
    public enum WriterError: Error, Sendable, Equatable {
        case sessionDirectoryMissing
        case chainFileMissing
        case manifestMissing
        case writeFailed(String)
    }

    public struct ExportResult: Sendable {
        public let archiveURL: URL
        public let archiveSizeBytes: Int64
        public let entryCount: Int
        public let headHashHex: String
    }

    public let fileManager: FileManager
    public let hasher: ComputerUseAuditHasher

    public init(fileManager: FileManager = .default, hasher: ComputerUseAuditHasher = .current) {
        self.fileManager = fileManager
        self.hasher = hasher
    }

    /// Build a `.cua` archive of `sessionDirectory` at `destinationURL`.
    /// Includes screenshots if `includeScreenshots` is true.
    @discardableResult
    public func export(
        sessionDirectory: URL,
        destinationURL: URL,
        includeScreenshots: Bool
    ) throws -> ExportResult {
        guard fileManager.fileExists(atPath: sessionDirectory.path) else {
            throw WriterError.sessionDirectoryMissing
        }
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let chainURL = sessionDirectory.appendingPathComponent("chain.jsonl")
        let headURL = sessionDirectory.appendingPathComponent("head.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw WriterError.manifestMissing }
        guard fileManager.fileExists(atPath: chainURL.path) else { throw WriterError.chainFileMissing }

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
                    let data = try Data(contentsOf: url)
                    entries.append(("screenshots/" + url.lastPathComponent, data))
                }
            }
        }

        var stream = Data()
        // Magic + version byte.
        stream.append(contentsOf: Array("CUARCHIVE".utf8))
        stream.append(0x01)
        // entryCount u32 BE
        appendUInt32BE(UInt32(entries.count), to: &stream)
        for entry in entries {
            let pathBytes = Array(entry.path.utf8)
            appendUInt16BE(UInt16(pathBytes.count), to: &stream)
            stream.append(contentsOf: pathBytes)
            appendUInt64BE(UInt64(entry.content.count), to: &stream)
            stream.append(contentsOf: hashSHA256(entry.content))
            stream.append(entry.content)
        }
        // Trailer: SHA-256 over everything written so far.
        let trailer = hashSHA256(stream)
        stream.append(contentsOf: trailer)

        do {
            try stream.write(to: destinationURL, options: .atomic)
        } catch {
            throw WriterError.writeFailed(error.localizedDescription)
        }

        // Re-derive head from the chain to surface for the operator.
        let headHashHex = try ComputerUseAuditChain(hasher: hasher)
            .validate(at: chainURL, sessionManifestHashHex: hasher.hash(data: entries.first!.content))
            .headHashHex ?? ""

        return ExportResult(
            archiveURL: destinationURL,
            archiveSizeBytes: Int64(stream.count),
            entryCount: entries.count,
            headHashHex: headHashHex
        )
    }

    /// Verify that `archiveURL` was not modified post-export. Returns
    /// the per-entry hash list on success; throws on any byte mismatch.
    public func verify(archive archiveURL: URL) throws -> [(path: String, sha256: Data, size: Int)] {
        let data = try Data(contentsOf: archiveURL)
        var offset = 0
        func read(_ count: Int) throws -> Data {
            guard offset + count <= data.count else { throw WriterError.writeFailed("truncated") }
            let chunk = data.subdata(in: offset..<(offset + count))
            offset += count
            return chunk
        }
        let magic = try read(10)
        guard magic.prefix(9) == Data("CUARCHIVE".utf8) else { throw WriterError.writeFailed("bad magic") }

        let entryCountBytes = try read(4)
        let entryCount = entryCountBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian

        var results: [(path: String, sha256: Data, size: Int)] = []
        for _ in 0..<entryCount {
            let pathLenBytes = try read(2)
            let pathLen = Int(pathLenBytes.withUnsafeBytes { $0.load(as: UInt16.self) }.bigEndian)
            let pathBytes = try read(pathLen)
            let path = String(data: pathBytes, encoding: .utf8) ?? ""
            let contentLenBytes = try read(8)
            let contentLen = Int(contentLenBytes.withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian)
            let storedHash = try read(32)
            let content = try read(contentLen)
            let observedHash = hashSHA256(content)
            guard observedHash == storedHash else {
                throw WriterError.writeFailed("hash mismatch at \(path)")
            }
            results.append((path, storedHash, contentLen))
        }
        // Trailer.
        let storedTrailer = try read(32)
        let expectedTrailer = hashSHA256(data.subdata(in: 0..<(data.count - 32)))
        guard storedTrailer == expectedTrailer else {
            throw WriterError.writeFailed("trailer mismatch")
        }
        return results
    }

    // MARK: bit-shuffle helpers

    private func appendUInt16BE(_ v: UInt16, to data: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendUInt32BE(_ v: UInt32, to data: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendUInt64BE(_ v: UInt64, to data: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func hashSHA256(_ data: Data) -> Data {
        // CryptoKit is imported in ComputerUseAuditChain.swift via the
        // same module; we reuse the same digest provider here.
        return Data(ComputerUseAuditHasher.current.sha256DigestBytes(of: data))
    }
}

// Internal extension to expose raw SHA-256 bytes (not hex) for the
// export writer's content-hash entries.
internal extension ComputerUseAuditHasher {
    func sha256DigestBytes(of data: Data) -> [UInt8] {
        return Array(CryptoKit.SHA256.hash(data: data))
    }
}

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public struct BurnBarSafariCommittedChunkTransfer: Hashable, Sendable {
    public let transferID: String
    public let originalMethod: BurnBarSafariBridgeMethod
    public let payload: Data

    public init(
        transferID: String,
        originalMethod: BurnBarSafariBridgeMethod,
        payload: Data
    ) {
        self.transferID = transferID
        self.originalMethod = originalMethod
        self.payload = payload
    }
}

public enum BurnBarSafariChunkStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidTransferIdentifier
    case invalidMetadata
    case transferAlreadyExists
    case transferNotFound
    case tooManyTransfers
    case invalidChunkIndex
    case duplicateChunk
    case invalidBase64
    case chunkTooLarge
    case transferTooLarge
    case incompleteTransfer
    case lengthMismatch
    case digestMismatch
    case expired
    case symbolicLinkRejected
    case insecurePermissions

    public var errorDescription: String? {
        switch self {
        case .invalidTransferIdentifier:
            return "Safari chunk transfer identifier is invalid."
        case .invalidMetadata:
            return "Safari chunk transfer metadata is invalid."
        case .transferAlreadyExists:
            return "Safari chunk transfer already exists."
        case .transferNotFound:
            return "Safari chunk transfer was not found."
        case .tooManyTransfers:
            return "Too many Safari chunk transfers are active."
        case .invalidChunkIndex:
            return "Safari chunk index is outside the declared range."
        case .duplicateChunk:
            return "Safari chunk was already appended."
        case .invalidBase64:
            return "Safari chunk data is not valid base64."
        case .chunkTooLarge:
            return "Safari chunk exceeds the per-message size limit."
        case .transferTooLarge:
            return "Safari chunk transfer exceeds the total size limit."
        case .incompleteTransfer:
            return "Safari chunk transfer is incomplete."
        case .lengthMismatch:
            return "Safari chunk transfer length does not match its declaration."
        case .digestMismatch:
            return "Safari chunk transfer digest does not match its declaration."
        case .expired:
            return "Safari chunk transfer has expired."
        case .symbolicLinkRejected:
            return "Symbolic links are not accepted in Safari chunk storage."
        case .insecurePermissions:
            return "Safari chunk storage permissions are too broad."
        }
    }
}

// AUDIT: Every mutable transfer map and filesystem mutation is serialized by
// the store's NSLock; values crossing the boundary are immutable snapshots.
// sendable-allowlist: internal-lock-snapshot-store
/// Disk-backed App Group chunk assembler for Safari native messages.
///
/// The store is intentionally file-backed instead of retaining multi-megabyte
/// screenshots in an extension process. Each chunk is owner-only, transfers are
/// profile-namespaced and bounded, and commit verifies the declared byte length
/// and SHA-256 before returning a single payload.
public final class BurnBarSafariBridgeChunkStore: @unchecked Sendable {
    private struct Metadata: Codable, Hashable, Sendable {
        static let currentVersion = 1

        let version: Int
        let transferID: String
        let originalMethod: BurnBarSafariBridgeMethod
        let byteLength: Int
        let chunkCount: Int
        let sha256: String
        let createdAtUnixMillis: Int64
    }

    public let trustedRoot: URL
    public let profileIdentifier: String
    public let transferLifetime: TimeInterval
    public let maximumActiveTransfers: Int

    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        trustedRoot: URL,
        profileIdentifier: String,
        transferLifetime: TimeInterval = 10 * 60,
        maximumActiveTransfers: Int = 16,
        fileManager: FileManager = .default
    ) {
        self.trustedRoot = trustedRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.profileIdentifier = profileIdentifier
        self.transferLifetime = min(max(transferLifetime, 1), 15 * 60)
        self.maximumActiveTransfers = min(max(maximumActiveTransfers, 1), 64)
        self.fileManager = fileManager
    }

    public static func live(
        profileIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> BurnBarSafariBridgeChunkStore {
        guard let root = BurnBarSafariSharedContainer.liveRoot(fileManager: fileManager) else {
            throw BurnBarSafariAppGroupPayloadError.appGroupUnavailable
        }
        return BurnBarSafariBridgeChunkStore(
            trustedRoot: root,
            profileIdentifier: profileIdentifier,
            fileManager: fileManager
        )
    }

    public func begin(
        transferID: String,
        originalMethod: BurnBarSafariBridgeMethod,
        byteLength: Int,
        chunkCount: Int,
        sha256: String,
        now: Date = Date()
    ) throws {
        try withLock {
            try validateTransferID(transferID)
            guard !originalMethod.isChunkMethod,
                  byteLength > 0,
                  byteLength <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes,
                  chunkCount > 0,
                  chunkCount <= BurnBarSafariBridgeWire.maximumChunkCount,
                  sha256.count == 64,
                  sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
                throw BurnBarSafariChunkStoreError.invalidMetadata
            }

            try prepareProfileDirectory()
            try cleanupExpiredLocked(now: now)
            let activeTransfers = try activeTransferCount()
            guard activeTransfers < maximumActiveTransfers else {
                throw BurnBarSafariChunkStoreError.tooManyTransfers
            }

            let directory = transferDirectory(for: transferID)
            guard !fileManager.fileExists(atPath: directory.path) else {
                throw BurnBarSafariChunkStoreError.transferAlreadyExists
            }
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let metadata = Metadata(
                version: Metadata.currentVersion,
                transferID: transferID,
                originalMethod: originalMethod,
                byteLength: byteLength,
                chunkCount: chunkCount,
                sha256: sha256,
                createdAtUnixMillis: Int64((now.timeIntervalSince1970 * 1_000).rounded())
            )
            do {
                try writeOwnerOnly(JSONEncoder().encode(metadata), to: metadataURL(in: directory))
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }
        }
    }

    public func append(
        transferID: String,
        index: Int,
        base64Data: String,
        now: Date = Date()
    ) throws {
        try withLock {
            try validateTransferID(transferID)
            let directory = transferDirectory(for: transferID)
            let metadata = try readMetadata(in: directory)
            try rejectExpired(metadata, directory: directory, now: now)
            guard index >= 0, index < metadata.chunkCount else {
                throw BurnBarSafariChunkStoreError.invalidChunkIndex
            }
            guard let data = Data(base64Encoded: base64Data, options: []), !data.isEmpty else {
                throw BurnBarSafariChunkStoreError.invalidBase64
            }
            guard data.count <= BurnBarSafariBridgeWire.maximumChunkBytes else {
                throw BurnBarSafariChunkStoreError.chunkTooLarge
            }

            let destination = chunkURL(index: index, in: directory)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw BurnBarSafariChunkStoreError.duplicateChunk
            }
            let existingBytes = try currentChunkBytes(in: directory, count: metadata.chunkCount)
            guard existingBytes + data.count <= metadata.byteLength,
                  existingBytes + data.count <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes else {
                throw BurnBarSafariChunkStoreError.transferTooLarge
            }
            try writeOwnerOnly(data, to: destination)
        }
    }

    public func commit(
        transferID: String,
        now: Date = Date()
    ) throws -> BurnBarSafariCommittedChunkTransfer {
        try withLock {
            try validateTransferID(transferID)
            let directory = transferDirectory(for: transferID)
            let metadata = try readMetadata(in: directory)
            try rejectExpired(metadata, directory: directory, now: now)

            var payload = Data()
            payload.reserveCapacity(metadata.byteLength)
            var hasher = SHA256()

            do {
                for index in 0..<metadata.chunkCount {
                    let url = chunkURL(index: index, in: directory)
                    guard fileManager.fileExists(atPath: url.path) else {
                        throw BurnBarSafariChunkStoreError.incompleteTransfer
                    }
                    try validateOwnerOnlyRegularFile(url)
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    guard !data.isEmpty,
                          data.count <= BurnBarSafariBridgeWire.maximumChunkBytes,
                          payload.count + data.count <= metadata.byteLength,
                          payload.count + data.count <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes else {
                        throw BurnBarSafariChunkStoreError.transferTooLarge
                    }
                    hasher.update(data: data)
                    payload.append(data)
                }
            } catch {
                if error is BurnBarSafariChunkStoreError,
                   error as? BurnBarSafariChunkStoreError != .incompleteTransfer {
                    try? fileManager.removeItem(at: directory)
                }
                throw error
            }

            guard payload.count == metadata.byteLength else {
                try? fileManager.removeItem(at: directory)
                throw BurnBarSafariChunkStoreError.lengthMismatch
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard constantTimeEqual(digest, metadata.sha256) else {
                try? fileManager.removeItem(at: directory)
                throw BurnBarSafariChunkStoreError.digestMismatch
            }

            try fileManager.removeItem(at: directory)
            return BurnBarSafariCommittedChunkTransfer(
                transferID: transferID,
                originalMethod: metadata.originalMethod,
                payload: payload
            )
        }
    }

    public func cleanupExpired(now: Date = Date()) throws {
        try withLock {
            try prepareProfileDirectory()
            try cleanupExpiredLocked(now: now)
        }
    }

    private var profileDirectory: URL {
        trustedRoot
            .appendingPathComponent("SafariBridge", isDirectory: true)
            .appendingPathComponent("Chunks", isDirectory: true)
            .appendingPathComponent(Self.sha256Hex(Data(profileIdentifier.utf8)), isDirectory: true)
    }

    private func transferDirectory(for transferID: String) -> URL {
        profileDirectory
            .appendingPathComponent(Self.sha256Hex(Data(transferID.utf8)), isDirectory: true)
            .standardizedFileURL
    }

    private func metadataURL(in directory: URL) -> URL {
        directory.appendingPathComponent("metadata.json", isDirectory: false)
    }

    private func chunkURL(index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "chunk-%04d.bin", index), isDirectory: false)
    }

    private func prepareProfileDirectory() throws {
        guard BurnBarSafariAppGroupPayloadStore.isContained(profileDirectory, by: trustedRoot) else {
            throw BurnBarSafariAppGroupPayloadError.pathOutsideTrustedRoot
        }
        try fileManager.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: profileDirectory.path
        )
    }

    private func readMetadata(in directory: URL) throws -> Metadata {
        guard BurnBarSafariAppGroupPayloadStore.isContained(directory, by: profileDirectory),
              fileManager.fileExists(atPath: directory.path) else {
            throw BurnBarSafariChunkStoreError.transferNotFound
        }
        let url = metadataURL(in: directory)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BurnBarSafariChunkStoreError.transferNotFound
        }
        try validateOwnerOnlyRegularFile(url)
        let data = try Data(contentsOf: url)
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        let declaredDirectoryPath = transferDirectory(for: metadata.transferID)
            .standardizedFileURL
            .path
        let actualDirectoryPath = directory.standardizedFileURL.path
        guard metadata.version == Metadata.currentVersion,
              declaredDirectoryPath == actualDirectoryPath,
              !metadata.originalMethod.isChunkMethod,
              metadata.byteLength > 0,
              metadata.byteLength <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes,
              metadata.chunkCount > 0,
              metadata.chunkCount <= BurnBarSafariBridgeWire.maximumChunkCount,
              metadata.sha256.count == 64 else {
            throw BurnBarSafariChunkStoreError.invalidMetadata
        }
        return metadata
    }

    private func currentChunkBytes(in directory: URL, count: Int) throws -> Int {
        var total = 0
        for index in 0..<count {
            let url = chunkURL(index: index, in: directory)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try validateOwnerOnlyRegularFile(url)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            total += size
            guard total <= BurnBarSafariBridgeWire.maximumChunkedPayloadBytes else {
                throw BurnBarSafariChunkStoreError.transferTooLarge
            }
        }
        return total
    }

    private func activeTransferCount() throws -> Int {
        let entries = try fileManager.contentsOfDirectory(
            at: profileDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.reduce(into: 0) { count, entry in
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                try? fileManager.removeItem(at: entry)
                return
            }
            if values.isDirectory == true { count += 1 }
        }
    }

    private func cleanupExpiredLocked(now: Date) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: profileDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            guard BurnBarSafariAppGroupPayloadStore.isContained(entry, by: profileDirectory) else {
                continue
            }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                try? fileManager.removeItem(at: entry)
                continue
            }
            guard values.isDirectory == true else { continue }
            guard let metadata = try? readMetadata(in: entry) else {
                try? fileManager.removeItem(at: entry)
                continue
            }
            let createdAt = Date(
                timeIntervalSince1970: Double(metadata.createdAtUnixMillis) / 1_000
            )
            if now.timeIntervalSince(createdAt) > transferLifetime {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func rejectExpired(_ metadata: Metadata, directory: URL, now: Date) throws {
        let createdAt = Date(timeIntervalSince1970: Double(metadata.createdAtUnixMillis) / 1_000)
        guard now.timeIntervalSince(createdAt) <= transferLifetime else {
            try? fileManager.removeItem(at: directory)
            throw BurnBarSafariChunkStoreError.expired
        }
    }

    private func writeOwnerOnly(_ data: Data, to url: URL) throws {
        guard BurnBarSafariAppGroupPayloadStore.isContained(url, by: profileDirectory) else {
            throw BurnBarSafariAppGroupPayloadError.pathOutsideTrustedRoot
        }
        try data.write(to: url, options: [.atomic])
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private func validateOwnerOnlyRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw BurnBarSafariChunkStoreError.symbolicLinkRejected
        }
        guard values.isRegularFile == true else {
            throw BurnBarSafariChunkStoreError.invalidMetadata
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let rawPermissions = attributes[.posixPermissions] as? NSNumber else {
            throw BurnBarSafariChunkStoreError.insecurePermissions
        }
        let permissions = rawPermissions.intValue & 0o777
        guard permissions & ~0o600 == 0, permissions & 0o400 != 0 else {
            throw BurnBarSafariChunkStoreError.insecurePermissions
        }
        #if canImport(Darwin) || canImport(Glibc)
        guard let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == geteuid() else {
            throw BurnBarSafariAppGroupPayloadError.invalidOwner
        }
        #endif
    }

    private func validateTransferID(_ transferID: String) throws {
        guard !transferID.isEmpty,
              transferID.utf8.count <= BurnBarSafariBridgeWire.maximumIdentifierLength,
              !transferID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BurnBarSafariChunkStoreError.invalidTransferIdentifier
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }
}

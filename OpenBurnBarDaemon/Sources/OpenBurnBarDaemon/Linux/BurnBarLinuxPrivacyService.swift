import Foundation

#if os(Linux)
import Glibc

/// Bounded local data/privacy operations owned by the Linux daemon.
///
/// This service deliberately owns an allowlist rather than accepting paths from
/// a renderer.  The preview token binds the requested stores, the resolved
/// daemon paths, and their metadata fingerprints.  Execution revalidates all
/// of those values before deleting anything and returns metadata only.
public actor BurnBarLinuxPrivacyService {
    public typealias StoreID = BurnBarLinuxPrivacyStoreID
    public typealias StoreState = BurnBarLinuxPrivacyStoreState

    public struct InventoryEntry: Codable, Hashable, Sendable {
        public let store: StoreID
        public let state: StoreState
        public let bytes: Int64
        /// Stable, non-sensitive reason codes suitable for UI remediation.
        public let reason: String

        public init(store: StoreID, state: StoreState, bytes: Int64, reason: String) {
            self.store = store
            self.state = state
            self.bytes = bytes
            self.reason = reason
        }
    }

    public struct InventoryResponse: Codable, Hashable, Sendable {
        public let stores: [InventoryEntry]
        public let generatedAt: Date

        public init(stores: [InventoryEntry], generatedAt: Date) {
            self.stores = stores
            self.generatedAt = generatedAt
        }
    }

    public struct DeletionPreview: Codable, Hashable, Sendable {
        public let token: String
        public let stores: [StoreID]
        public let entries: [InventoryEntry]
        public let expiresAt: Date
        public let confirmationPhrase: String

        public init(
            token: String,
            stores: [StoreID],
            entries: [InventoryEntry],
            expiresAt: Date,
            confirmationPhrase: String
        ) {
            self.token = token
            self.stores = stores
            self.entries = entries
            self.expiresAt = expiresAt
            self.confirmationPhrase = confirmationPhrase
        }
    }

    public struct DeletionRequest: Codable, Hashable, Sendable {
        public let token: String
        public let stores: [StoreID]
        public let confirmation: String

        public init(token: String, stores: [StoreID], confirmation: String) {
            self.token = token
            self.stores = stores
            self.confirmation = confirmation
        }
    }

    public struct DeletionResult: Codable, Hashable, Sendable {
        public let stores: [StoreID]
        public let deleted: [StoreID]
        public let alreadyAbsent: [StoreID]
        public let bytesRemoved: Int64
        public let idempotent: Bool

        public init(
            stores: [StoreID],
            deleted: [StoreID],
            alreadyAbsent: [StoreID],
            bytesRemoved: Int64,
            idempotent: Bool
        ) {
            self.stores = stores
            self.deleted = deleted
            self.alreadyAbsent = alreadyAbsent
            self.bytesRemoved = bytesRemoved
            self.idempotent = idempotent
        }
    }

    public enum ServiceError: Error, LocalizedError, Equatable, Sendable {
        case emptyScope
        case invalidToken
        case expiredPreview
        case confirmationRequired
        case scopeMismatch
        case unsafeLocation
        case unsafeFile
        case stalePreview
        case deletionFailed

        public var errorDescription: String? {
            switch self {
            case .emptyScope: return "Choose at least one supported local store."
            case .invalidToken: return "The privacy deletion preview is invalid or no longer available."
            case .expiredPreview: return "The privacy deletion preview expired; refresh and preview again."
            case .confirmationRequired: return "Type the exact confirmation phrase to delete local data."
            case .scopeMismatch: return "The deletion scope changed; preview again before confirming."
            case .unsafeLocation: return "The daemon-owned privacy directory is not safe to modify."
            case .unsafeFile: return "A local privacy store failed ownership, type, or permission checks."
            case .stalePreview: return "A local privacy store changed after preview; refresh before confirming."
            case .deletionFailed: return "The daemon could not remove the approved local privacy store."
            }
        }
    }

    public static let confirmationPhrase = "DELETE LOCAL DATA"
    public static let defaultPreviewLifetime: TimeInterval = 5 * 60

    private struct FileFingerprint: Hashable, Sendable {
        let size: Int64
        let modificationSeconds: Int64
        let inode: UInt64
    }

    private struct PendingPreview: Sendable {
        let stores: [StoreID]
        let paths: [StoreID: URL]
        let fingerprints: [StoreID: FileFingerprint?]
        let expiresAt: Date
        var completed: DeletionResult?
    }

    private let supportDirectory: URL
    private let previewLifetime: TimeInterval
    private var pending: [String: PendingPreview] = [:]
    private let fileManager = FileManager.default

    public init(
        supportDirectory: URL = BurnBarDaemonPaths.supportDirectoryURL,
        previewLifetime: TimeInterval = BurnBarLinuxPrivacyService.defaultPreviewLifetime
    ) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.previewLifetime = max(1, previewLifetime)
    }

    /// Inventory contains only allowlisted store identifiers and byte counts.
    /// It never returns absolute paths, filenames, or file contents.
    public func inventory(now: Date = Date()) -> InventoryResponse {
        InventoryResponse(
            stores: StoreID.allCases.map { inventoryEntry(for: $0) },
            generatedAt: now
        )
    }

    public func previewDeletion(
        stores requestedStores: [StoreID],
        now: Date = Date()
    ) throws -> DeletionPreview {
        let stores = try normalizedScope(requestedStores)
        purgeExpiredPreviews(now: now)
        let descriptors = try stores.reduce(into: [StoreID: URL]()) { result, store in
            result[store] = try allowlistedURL(for: store)
        }
        let entries = stores.map { inventoryEntry(for: $0) }
        guard entries.allSatisfy({ $0.state != .blocked }) else {
            throw ServiceError.unsafeFile
        }
        let token = UUID().uuidString
        let expiresAt = now.addingTimeInterval(previewLifetime)
        let fingerprints = stores.reduce(into: [StoreID: FileFingerprint?]()) { result, store in
            result[store] = fingerprint(at: descriptors[store]!)
        }
        pending[token] = PendingPreview(
            stores: stores,
            paths: descriptors,
            fingerprints: fingerprints,
            expiresAt: expiresAt,
            completed: nil
        )
        return DeletionPreview(
            token: token,
            stores: stores,
            entries: entries,
            expiresAt: expiresAt,
            confirmationPhrase: Self.confirmationPhrase
        )
    }

    public func executeDeletion(
        _ request: DeletionRequest,
        now: Date = Date()
    ) throws -> DeletionResult {
        purgeExpiredPreviews(now: now)
        guard var preview = pending[request.token] else { throw ServiceError.invalidToken }
        guard now <= preview.expiresAt else {
            pending.removeValue(forKey: request.token)
            throw ServiceError.expiredPreview
        }
        let stores = try normalizedScope(request.stores)
        guard stores == preview.stores else { throw ServiceError.scopeMismatch }
        guard request.confirmation == Self.confirmationPhrase else {
            throw ServiceError.confirmationRequired
        }
        if let completed = preview.completed {
            return DeletionResult(
                stores: completed.stores,
                deleted: completed.deleted,
                alreadyAbsent: completed.alreadyAbsent,
                bytesRemoved: completed.bytesRemoved,
                idempotent: true
            )
        }

        for store in stores {
            guard let path = preview.paths[store], isAllowlisted(path, for: store) else {
                throw ServiceError.unsafeLocation
            }
            guard let before = fingerprint(at: path) else { continue }
            guard before == preview.fingerprints[store]!, isSafeStoreFile(path) else {
                throw ServiceError.stalePreview
            }
        }

        var deleted: [StoreID] = []
        var alreadyAbsent: [StoreID] = []
        var bytesRemoved: Int64 = 0
        do {
            for store in stores {
                let path = preview.paths[store]!
                guard let current = fingerprint(at: path) else {
                    alreadyAbsent.append(store)
                    continue
                }
                // Re-check immediately before removal. A replacement is never
                // followed, and only the fixed allowlisted filename is removed.
                guard current == preview.fingerprints[store]!, isSafeStoreFile(path) else {
                    throw ServiceError.stalePreview
                }
                // POSIX unlink removes only the directory entry. Unlike
                // FileManager.removeItem, it cannot recursively remove a
                // directory if an attacker swaps the path after validation.
                guard unlink(path.path) == 0 else {
                    throw ServiceError.deletionFailed
                }
                deleted.append(store)
                bytesRemoved += current.size
            }
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.deletionFailed
        }

        let result = DeletionResult(
            stores: stores,
            deleted: deleted,
            alreadyAbsent: alreadyAbsent,
            bytesRemoved: bytesRemoved,
            idempotent: false
        )
        preview.completed = result
        pending[request.token] = preview
        return result
    }

    private func normalizedScope(_ requested: [StoreID]) throws -> [StoreID] {
        let stores = Array(Set(requested)).sorted { $0.rawValue < $1.rawValue }
        guard stores.isEmpty == false else { throw ServiceError.emptyScope }
        return stores
    }

    private func inventoryEntry(for store: StoreID) -> InventoryEntry {
        do {
            let path = try allowlistedURL(for: store)
            guard fileManager.fileExists(atPath: path.path) else {
                return InventoryEntry(store: store, state: .absent, bytes: 0, reason: "missing")
            }
            guard let fingerprint = fingerprint(at: path), isSafeStoreFile(path) else {
                return InventoryEntry(store: store, state: .blocked, bytes: 0, reason: "unsafe_file")
            }
            return InventoryEntry(store: store, state: .ready, bytes: fingerprint.size, reason: "ready")
        } catch {
            return InventoryEntry(store: store, state: .blocked, bytes: 0, reason: "unsafe_location")
        }
    }

    private func allowlistedURL(for store: StoreID) throws -> URL {
        guard isSafeSupportDirectory() else { throw ServiceError.unsafeLocation }
        let filename: String
        switch store {
        case .proxyRouteLog: filename = "proxy-route-events.jsonl"
        case .textExpansionStore: filename = "text-expansion-v1.obbsealed"
        }
        let path = supportDirectory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard isAllowlisted(path, for: store) else { throw ServiceError.unsafeLocation }
        return path
    }

    private func isAllowlisted(_ path: URL, for store: StoreID) -> Bool {
        let expectedName = store == .proxyRouteLog ? "proxy-route-events.jsonl" : "text-expansion-v1.obbsealed"
        let supportPath = supportDirectory.path.hasSuffix("/") ? supportDirectory.path : supportDirectory.path + "/"
        return path.deletingLastPathComponent().path == supportDirectory.path
            && path.lastPathComponent == expectedName
            && path.path.hasPrefix(supportPath)
            && path.pathComponents.contains("..") == false
    }

    private func isSafeSupportDirectory() -> Bool {
        guard fileManager.fileExists(atPath: supportDirectory.path) else { return true }
        guard let metadata = lstatMetadata(at: supportDirectory), metadata.isDirectory,
              metadata.ownerUID == geteuid(), metadata.mode & 0o022 == 0 else { return false }
        return pathHasNoSymlinks(supportDirectory)
    }

    private func isSafeStoreFile(_ path: URL) -> Bool {
        guard let metadata = lstatMetadata(at: path), metadata.isRegular,
              metadata.ownerUID == geteuid(), metadata.mode & 0o077 == 0 else { return false }
        return pathHasNoSymlinks(path)
    }

    private func pathHasNoSymlinks(_ path: URL) -> Bool {
        var current = URL(fileURLWithPath: "/")
        for component in path.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: false)
            guard let metadata = lstatMetadata(at: current) else {
                // The final file may be absent; its existing parents still must
                // be checked before an inventory or preview is trusted.
                if current.path == path.path { return true }
                return false
            }
            if metadata.isSymlink { return false }
        }
        return true
    }

    private func fingerprint(at path: URL) -> FileFingerprint? {
        guard let metadata = lstatMetadata(at: path), metadata.isRegular,
              metadata.ownerUID == geteuid(), metadata.mode & 0o077 == 0,
              pathHasNoSymlinks(path) else { return nil }
        return FileFingerprint(
            size: metadata.size,
            modificationSeconds: metadata.modificationSeconds,
            inode: metadata.inode
        )
    }

    private struct LStatMetadata {
        let mode: mode_t
        let ownerUID: uid_t
        let size: Int64
        let modificationSeconds: Int64
        let inode: UInt64
        let isRegular: Bool
        let isDirectory: Bool
        let isSymlink: Bool
    }

    private func lstatMetadata(at url: URL) -> LStatMetadata? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        return LStatMetadata(
            mode: metadata.st_mode,
            ownerUID: metadata.st_uid,
            size: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtime),
            inode: UInt64(metadata.st_ino),
            isRegular: kind == mode_t(S_IFREG),
            isDirectory: kind == mode_t(S_IFDIR),
            isSymlink: kind == mode_t(S_IFLNK)
        )
    }

    private func purgeExpiredPreviews(now: Date) {
        pending = pending.filter { $0.value.expiresAt >= now }
    }
}
#endif

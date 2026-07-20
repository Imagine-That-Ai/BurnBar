import Foundation
import OpenBurnBarEngine

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
        case exportTooLarge
        case exportReadFailed
        case exportEncodingFailed
        case exportWriteFailed
        case exportCrypto(BurnBarLinuxPrivacyExportCrypto.Error)
        case retentionConfirmationRequired
        case retentionInvalidPolicy
        case retentionPolicyUnavailable
        case retentionStoreCorrupt
        case retentionRecordTooLarge
        case retentionApplyFailed

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
            case .exportTooLarge: return "The selected local data is too large for a bounded privacy export."
            case .exportReadFailed: return "The daemon could not read the selected local privacy store safely."
            case .exportEncodingFailed: return "The daemon could not encode the selected local privacy data."
            case .exportWriteFailed: return "The daemon could not write the encrypted privacy export."
            case .exportCrypto(let error): return "The privacy export could not be encrypted: \(error)."
            case .retentionConfirmationRequired: return "Type the exact confirmation phrase to apply the retention policy."
            case .retentionInvalidPolicy: return "The retention policy must cover each supported store exactly once within safe bounds."
            case .retentionPolicyUnavailable: return "The saved retention policy is unavailable or unsafe; no local data was changed."
            case .retentionStoreCorrupt: return "A local privacy store is malformed; retention stopped without deleting data."
            case .retentionRecordTooLarge: return "A local privacy record exceeds the configured retention size bound."
            case .retentionApplyFailed: return "The daemon could not apply the retention policy atomically."
            }
        }
    }

    public static let confirmationPhrase = "DELETE LOCAL DATA"
    public static let retentionConfirmationPhrase = "APPLY RETENTION POLICY"
    public static let defaultPreviewLifetime: TimeInterval = 5 * 60
    public static let minimumRetentionAgeSeconds: Int64 = 60 * 60
    public static let maximumRetentionAgeSeconds: Int64 = 365 * 24 * 60 * 60
    public static let minimumRetentionBytes: Int64 = 64 * 1024
    public static let maximumRetentionBytes: Int64 = 64 * 1024 * 1024

    public static let defaultRetentionRules: [BurnBarLinuxPrivacyRetentionRule] = [
        BurnBarLinuxPrivacyRetentionRule(
            store: .proxyRouteLog,
            maxAgeSeconds: 30 * 24 * 60 * 60,
            maxBytes: 8 * 1024 * 1024
        ),
        BurnBarLinuxPrivacyRetentionRule(
            store: .textExpansionStore,
            maxAgeSeconds: 365 * 24 * 60 * 60,
            maxBytes: 4 * 1024 * 1024
        )
    ]

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

    private struct ExportPayload: Codable, Sendable {
        let schemaVersion: Int
        let generatedAt: Date
        let stores: [ExportStore]
    }

    private struct ExportStore: Codable, Sendable {
        let store: StoreID
        let state: StoreState
        let bytes: Int64
        let sha256: String?
        let contents: Data?
    }

    private struct StoredRetentionPolicy: Codable, Sendable {
        let version: Int
        let rules: [BurnBarLinuxPrivacyRetentionRule]
        let updatedAt: Date
    }

    private struct LoadedRetentionPolicy: Sendable {
        let state: BurnBarLinuxPrivacyRetentionPolicyState
        let rules: [BurnBarLinuxPrivacyRetentionRule]
    }

    private struct RouteLogEvaluation: Sendable {
        let entries: [BurnBarProxyRouteLogEntry]
        let originalBytes: Int64
        let oldestAgeSeconds: Int64?
    }

    private let supportDirectory: URL
    private let retentionPolicyURL: URL
    private let previewLifetime: TimeInterval
    private var pending: [String: PendingPreview] = [:]
    private let fileManager = FileManager.default

    public init(
        supportDirectory: URL = BurnBarDaemonPaths.supportDirectoryURL,
        previewLifetime: TimeInterval = BurnBarLinuxPrivacyService.defaultPreviewLifetime
    ) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.retentionPolicyURL = self.supportDirectory.appendingPathComponent(
            "privacy-retention-policy.json",
            isDirectory: false
        )
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
        guard var preview = pending[request.token] else { throw ServiceError.invalidToken }
        guard now <= preview.expiresAt else {
            pending.removeValue(forKey: request.token)
            throw ServiceError.expiredPreview
        }
        // Keep the requested preview visible long enough to return the
        // specific expiry error; then discard unrelated expired previews.
        purgeExpiredPreviews(now: now)
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

    /// Returns the daemon-owned retention policy and a metadata-only evaluation
    /// of both allowlisted stores. A malformed saved policy is reported as
    /// blocked and never replaced with defaults.
    public func retentionStatus(
        now: Date = Date()
    ) throws -> BurnBarLinuxPrivacyRetentionStatusResponse {
        let loaded: LoadedRetentionPolicy
        do {
            loaded = try loadRetentionPolicy()
        } catch {
            return blockedRetentionStatus(now: now)
        }

        let stores = StoreID.allCases.map { store in
            retentionStoreStatus(store: store, rule: loaded.rules.first { $0.store == store }!, now: now)
        }
        return BurnBarLinuxPrivacyRetentionStatusResponse(
            policyState: loaded.state,
            rules: loaded.rules,
            stores: stores,
            evaluatedAt: now
        )
    }

    /// Applies a normalized, bounded policy. Store content is either safely
    /// rewritten atomically or left untouched; malformed route-log data and
    /// unsafe paths fail closed before any mutation.
    public func applyRetention(
        _ request: BurnBarLinuxPrivacyRetentionApplyRequest,
        now: Date = Date()
    ) throws -> BurnBarLinuxPrivacyRetentionApplyResponse {
        guard request.confirmation == Self.retentionConfirmationPhrase else {
            throw ServiceError.retentionConfirmationRequired
        }
        let rules = try normalizedRetentionRules(request.rules)
        // Reading a corrupt existing policy must not be papered over by an
        // apply request. The first apply is allowed only when no policy exists.
        let existing = try loadRetentionPolicy()
        _ = existing
        var removedBytes: Int64 = 0
        var removedEntries = 0

        try ensureSafeSupportDirectory()
        let evaluations = try StoreID.allCases.map { store -> (StoreID, URL, FileFingerprint?, BurnBarLinuxPrivacyRetentionRule) in
            let path = try allowlistedURL(for: store)
            let fingerprint = fingerprint(at: path)
            if fileManager.fileExists(atPath: path.path) && fingerprint == nil {
                throw ServiceError.unsafeFile
            }
            return (store, path, fingerprint, rules.first { $0.store == store }!)
        }

        // Parse all structured stores before persisting the new policy or
        // touching either file. A corrupt route log therefore leaves both the
        // data and the prior policy unchanged.
        for (store, path, before, _) in evaluations where store == .proxyRouteLog {
            if let before {
                _ = try routeLogEvaluation(at: path, before: before, now: now)
            }
        }

        // Persist the requested policy before mutations so a crash cannot
        // silently revert the user's chosen bounds.
        try persistRetentionPolicy(rules: rules, updatedAt: now)

        do {
            for (store, path, before, rule) in evaluations {
                guard let before else { continue }
                guard isSafeStoreFile(path), fingerprint(at: path) == before else {
                    throw ServiceError.stalePreview
                }
                switch store {
                case .proxyRouteLog:
                    let evaluation = try routeLogEvaluation(at: path, before: before, now: now)
                    var kept = evaluation.entries.filter {
                        now.timeIntervalSince($0.occurredAt) <= TimeInterval(rule.maxAgeSeconds)
                    }
                    kept = try trimRouteEntries(kept, maxBytes: rule.maxBytes)
                    let rewritten = try encodedRouteEntries(kept)
                    if rewritten.count == 0 {
                        guard unlink(path.path) == 0 else { throw ServiceError.retentionApplyFailed }
                    } else {
                        let current = try Data(contentsOf: path)
                        if Int64(rewritten.count) != before.size || rewritten != current {
                            try atomicRewrite(rewritten, at: path, expected: before)
                        }
                    }
                    removedBytes += max(0, before.size - Int64(rewritten.count))
                    removedEntries += evaluation.entries.count - kept.count
                case .textExpansionStore:
                    let age = max(0, now.timeIntervalSince1970 - Double(before.modificationSeconds))
                    if age > TimeInterval(rule.maxAgeSeconds) || before.size > rule.maxBytes {
                        guard unlink(path.path) == 0 else { throw ServiceError.retentionApplyFailed }
                        removedBytes += before.size
                        removedEntries += 1
                    }
                }
            }
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.retentionApplyFailed
        }

        let status = try retentionStatus(now: now)
        return BurnBarLinuxPrivacyRetentionApplyResponse(
            status: status,
            removedBytes: removedBytes,
            removedEntries: removedEntries
        )
    }

    /// Export only the explicitly selected allowlisted stores into a
    /// passphrase-encrypted bundle. The renderer supplies a destination and
    /// passphrase, but the daemon validates the path, reads the stores, and
    /// writes the owner-only bundle without returning their contents.
    public func export(
        _ request: BurnBarLinuxPrivacyExportRequest,
        now: Date = Date()
    ) throws -> BurnBarLinuxPrivacyExportResponse {
        let stores = try normalizedScope(request.stores)
        let destination = try validatedExportDestination(request.destinationPath)
        let descriptors = try stores.reduce(into: [StoreID: URL]()) { result, store in
            result[store] = try allowlistedURL(for: store)
        }

        var exportedStores: [ExportStore] = []
        var payloadByteCount = 0
        for store in stores {
            let path = descriptors[store]!
            let entry = inventoryEntry(for: store)
            guard entry.state != .blocked else { throw ServiceError.unsafeFile }
            guard let before = fingerprint(at: path) else {
                exportedStores.append(
                    ExportStore(store: store, state: .absent, bytes: 0, sha256: nil, contents: nil)
                )
                continue
            }
            guard before.size <= Int64(BurnBarLinuxPrivacyExportCrypto.maximumPayloadByteCount) else {
                throw ServiceError.exportTooLarge
            }
            let contents: Data
            do {
                contents = try Data(contentsOf: path, options: .mappedIfSafe)
            } catch {
                throw ServiceError.exportReadFailed
            }
            guard contents.count <= BurnBarLinuxPrivacyExportCrypto.maximumPayloadByteCount,
                  let after = fingerprint(at: path), after == before,
                  isSafeStoreFile(path) else {
                throw ServiceError.stalePreview
            }
            payloadByteCount += contents.count
            guard payloadByteCount <= BurnBarLinuxPrivacyExportCrypto.maximumPayloadByteCount else {
                throw ServiceError.exportTooLarge
            }
            exportedStores.append(
                ExportStore(
                    store: store,
                    state: .ready,
                    bytes: Int64(contents.count),
                    sha256: PlatformCrypto.sha256Hex(contents),
                    contents: contents
                )
            )
        }

        let payload: Data
        do {
            payload = try JSONEncoder().encode(
                ExportPayload(schemaVersion: 1, generatedAt: now, stores: exportedStores)
            )
        } catch {
            throw ServiceError.exportEncodingFailed
        }
        guard payload.count <= BurnBarLinuxPrivacyExportCrypto.maximumPayloadByteCount else {
            throw ServiceError.exportTooLarge
        }
        let bundle: Data
        do {
            bundle = try BurnBarLinuxPrivacyExportCrypto.seal(payload: payload, passphrase: request.passphrase)
        } catch let error as BurnBarLinuxPrivacyExportCrypto.Error {
            throw ServiceError.exportCrypto(error)
        } catch {
            throw ServiceError.exportCrypto(.authenticationFailed)
        }
        do {
            try bundle.write(to: destination, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw ServiceError.exportWriteFailed
        }
        return BurnBarLinuxPrivacyExportResponse(
            stores: stores,
            destinationPath: destination.path,
            byteCount: Int64(bundle.count),
            formatVersion: Int(BurnBarLinuxPrivacyExportCrypto.formatVersion)
        )
    }

    private func normalizedScope(_ requested: [StoreID]) throws -> [StoreID] {
        let stores = Array(Set(requested)).sorted { $0.rawValue < $1.rawValue }
        guard stores.isEmpty == false else { throw ServiceError.emptyScope }
        return stores
    }

    private func normalizedRetentionRules(
        _ requested: [BurnBarLinuxPrivacyRetentionRule]
    ) throws -> [BurnBarLinuxPrivacyRetentionRule] {
        guard requested.count == StoreID.allCases.count else { throw ServiceError.retentionInvalidPolicy }
        let sorted = requested.sorted { $0.store.rawValue < $1.store.rawValue }
        guard Set(sorted.map(\.store)) == Set(StoreID.allCases),
              sorted.allSatisfy({
                  $0.maxAgeSeconds >= Self.minimumRetentionAgeSeconds
                      && $0.maxAgeSeconds <= Self.maximumRetentionAgeSeconds
                      && $0.maxBytes >= Self.minimumRetentionBytes
                      && $0.maxBytes <= Self.maximumRetentionBytes
              }) else {
            throw ServiceError.retentionInvalidPolicy
        }
        return sorted
    }

    private func loadRetentionPolicy() throws -> LoadedRetentionPolicy {
        guard fileManager.fileExists(atPath: retentionPolicyURL.path) else {
            return LoadedRetentionPolicy(state: .defaults, rules: try normalizedRetentionRules(Self.defaultRetentionRules))
        }
        guard isSafePolicyFile(retentionPolicyURL) else { throw ServiceError.retentionPolicyUnavailable }
        do {
            let stored = try JSONDecoder().decode(
                StoredRetentionPolicy.self,
                from: Data(contentsOf: retentionPolicyURL, options: .mappedIfSafe)
            )
            guard stored.version == 1 else { throw ServiceError.retentionPolicyUnavailable }
            return LoadedRetentionPolicy(state: .configured, rules: try normalizedRetentionRules(stored.rules))
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.retentionPolicyUnavailable
        }
    }

    private func persistRetentionPolicy(
        rules: [BurnBarLinuxPrivacyRetentionRule],
        updatedAt: Date
    ) throws {
        let stored = StoredRetentionPolicy(version: 1, rules: rules, updatedAt: updatedAt)
        let data: Data
        do {
            data = try JSONEncoder().encode(stored)
        } catch {
            throw ServiceError.retentionApplyFailed
        }
        do {
            try ensureSafeSupportDirectory()
            try data.write(to: retentionPolicyURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retentionPolicyURL.path)
            guard isSafePolicyFile(retentionPolicyURL) else { throw ServiceError.unsafeFile }
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.retentionApplyFailed
        }
    }

    private func blockedRetentionStatus(now: Date) -> BurnBarLinuxPrivacyRetentionStatusResponse {
        let rules = Self.defaultRetentionRules
        let stores = StoreID.allCases.map { store in
            BurnBarLinuxPrivacyRetentionStoreStatus(
                store: store,
                state: .blocked,
                bytes: 0,
                ageSeconds: nil,
                maxAgeSeconds: rules.first { $0.store == store }!.maxAgeSeconds,
                maxBytes: rules.first { $0.store == store }!.maxBytes,
                wouldPurge: false,
                reason: "policy_unavailable"
            )
        }
        return BurnBarLinuxPrivacyRetentionStatusResponse(
            policyState: .blocked,
            rules: rules,
            stores: stores,
            evaluatedAt: now
        )
    }

    private func retentionStoreStatus(
        store: StoreID,
        rule: BurnBarLinuxPrivacyRetentionRule,
        now: Date
    ) -> BurnBarLinuxPrivacyRetentionStoreStatus {
        do {
            let path = try allowlistedURL(for: store)
            guard fileManager.fileExists(atPath: path.path) else {
                return BurnBarLinuxPrivacyRetentionStoreStatus(
                    store: store, state: .absent, bytes: 0, ageSeconds: nil,
                    maxAgeSeconds: rule.maxAgeSeconds, maxBytes: rule.maxBytes,
                    wouldPurge: false, reason: "missing"
                )
            }
            guard let before = fingerprint(at: path) else {
                return BurnBarLinuxPrivacyRetentionStoreStatus(
                    store: store, state: .blocked, bytes: 0, ageSeconds: nil,
                    maxAgeSeconds: rule.maxAgeSeconds, maxBytes: rule.maxBytes,
                    wouldPurge: false, reason: "unsafe_file"
                )
            }
            switch store {
            case .proxyRouteLog:
                let evaluation = try routeLogEvaluation(at: path, before: before, now: now)
                let tooOld = evaluation.entries.contains {
                    now.timeIntervalSince($0.occurredAt) > TimeInterval(rule.maxAgeSeconds)
                }
                let tooLarge = before.size > rule.maxBytes
                return BurnBarLinuxPrivacyRetentionStoreStatus(
                    store: store, state: .ready, bytes: before.size,
                    ageSeconds: evaluation.oldestAgeSeconds,
                    maxAgeSeconds: rule.maxAgeSeconds, maxBytes: rule.maxBytes,
                    wouldPurge: tooOld || tooLarge,
                    reason: tooOld || tooLarge ? "over_policy" : "within_policy"
                )
            case .textExpansionStore:
                let age = max(0, now.timeIntervalSince1970 - Double(before.modificationSeconds))
                let tooOld = age > TimeInterval(rule.maxAgeSeconds)
                let tooLarge = before.size > rule.maxBytes
                return BurnBarLinuxPrivacyRetentionStoreStatus(
                    store: store, state: .ready, bytes: before.size,
                    ageSeconds: Int64(age.rounded(.down)),
                    maxAgeSeconds: rule.maxAgeSeconds, maxBytes: rule.maxBytes,
                    wouldPurge: tooOld || tooLarge,
                    reason: tooOld || tooLarge ? "over_policy" : "within_policy"
                )
            }
        } catch ServiceError.retentionStoreCorrupt {
            return BurnBarLinuxPrivacyRetentionStoreStatus(
                store: store, state: .blocked, bytes: 0, ageSeconds: nil,
                maxAgeSeconds: rule.maxAgeSeconds, maxBytes: rule.maxBytes,
                wouldPurge: false, reason: "corrupt_store"
            )
        } catch {
            return BurnBarLinuxPrivacyRetentionStoreStatus(
                store: store, state: .blocked, bytes: 0, ageSeconds: nil,
                maxAgeSeconds: rule.maxAgeSeconds, maxBytes: rule.maxBytes,
                wouldPurge: false, reason: "unsafe_location"
            )
        }
    }

    private func routeLogEvaluation(
        at path: URL,
        before: FileFingerprint,
        now: Date
    ) throws -> RouteLogEvaluation {
        guard let current = fingerprint(at: path), current == before else { throw ServiceError.stalePreview }
        let contents: Data
        do {
            contents = try Data(contentsOf: path, options: .mappedIfSafe)
        } catch {
            throw ServiceError.retentionStoreCorrupt
        }
        var entries: [BurnBarProxyRouteLogEntry] = []
        for line in contents.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) where line.isEmpty == false {
            do {
                entries.append(try JSONDecoder().decode(BurnBarProxyRouteLogEntry.self, from: Data(line)))
            } catch {
                throw ServiceError.retentionStoreCorrupt
            }
        }
        let oldestAge = entries.map { max(0, now.timeIntervalSince($0.occurredAt)) }.max().map { Int64($0.rounded(.down)) }
        return RouteLogEvaluation(entries: entries, originalBytes: before.size, oldestAgeSeconds: oldestAge)
    }

    private func trimRouteEntries(
        _ entries: [BurnBarProxyRouteLogEntry],
        maxBytes: Int64
    ) throws -> [BurnBarProxyRouteLogEntry] {
        var kept = entries
        while kept.isEmpty == false {
            let data = try encodedRouteEntries(kept)
            if Int64(data.count) <= maxBytes { return kept }
            if kept.count == 1 { throw ServiceError.retentionRecordTooLarge }
            kept.removeFirst()
        }
        return kept
    }

    private func encodedRouteEntries(_ entries: [BurnBarProxyRouteLogEntry]) throws -> Data {
        do {
            return try entries.reduce(into: Data()) { data, entry in
                data.append(try JSONEncoder().encode(entry))
                data.append(0x0A)
            }
        } catch {
            throw ServiceError.retentionStoreCorrupt
        }
    }

    private func atomicRewrite(
        _ data: Data,
        at path: URL,
        expected: FileFingerprint
    ) throws {
        guard isAllowlisted(path, for: .proxyRouteLog), isSafeStoreFile(path), fingerprint(at: path) == expected else {
            throw ServiceError.stalePreview
        }
        let temporary = supportDirectory.appendingPathComponent(
            ".privacy-retention-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard pathHasNoSymlinks(temporary) else { throw ServiceError.unsafeFile }
            let renamed = temporary.path.withCString { source in
                path.path.withCString { destination in
                    Glibc.rename(source, destination)
                }
            }
            guard renamed == 0 else { throw ServiceError.retentionApplyFailed }
            guard isSafeStoreFile(path) else { throw ServiceError.unsafeFile }
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.retentionApplyFailed
        }
    }

    private func ensureSafeSupportDirectory() throws {
        if fileManager.fileExists(atPath: supportDirectory.path) {
            guard isSafeSupportDirectory() else { throw ServiceError.unsafeLocation }
            return
        }
        let parent = supportDirectory.deletingLastPathComponent()
        guard let metadata = lstatMetadata(at: parent), metadata.isDirectory,
              metadata.ownerUID == geteuid(), metadata.mode & 0o022 == 0,
              pathHasNoSymlinks(parent) else { throw ServiceError.unsafeLocation }
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ServiceError.unsafeLocation
        }
        guard isSafeSupportDirectory() else { throw ServiceError.unsafeLocation }
    }

    private func isSafePolicyFile(_ path: URL) -> Bool {
        guard let metadata = lstatMetadata(at: path), metadata.isRegular,
              metadata.ownerUID == geteuid(), metadata.mode & 0o077 == 0 else { return false }
        return pathHasNoSymlinks(path)
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

    private func validatedExportDestination(_ rawPath: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed.utf8.count <= 4_096,
              trimmed.hasPrefix("/"),
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw ServiceError.unsafeLocation
        }
        let destination = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard destination.path != supportDirectory.path,
              fileManager.fileExists(atPath: destination.path) == false,
              pathHasNoSymlinks(destination) else {
            throw ServiceError.unsafeLocation
        }
        let parent = destination.deletingLastPathComponent()
        guard let metadata = lstatMetadata(at: parent), metadata.isDirectory,
              metadata.ownerUID == geteuid(), metadata.mode & 0o022 == 0,
              pathHasNoSymlinks(parent) else {
            throw ServiceError.unsafeLocation
        }
        // A root-run daemon cannot use UID ownership as a meaningful user
        // boundary: every system directory appears root-owned. In that
        // posture, keep exports inside the daemon support directory so a
        // renderer cannot redirect encrypted local data into /etc, /usr, or
        // another privileged path.
        if geteuid() == 0 && !isDescendantOrSame(destination, of: supportDirectory) {
            throw ServiceError.unsafeLocation
        }
        return destination
    }

    private func isDescendantOrSame(_ path: URL, of directory: URL) -> Bool {
        let directoryComponents = directory.standardizedFileURL.pathComponents
        let pathComponents = path.standardizedFileURL.pathComponents
        guard pathComponents.count >= directoryComponents.count else { return false }
        return Array(pathComponents.prefix(directoryComponents.count)) == directoryComponents
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
            // glibc exposes the nanosecond timestamp as `st_mtim.tv_sec`;
            // Darwin's `st_mtime` spelling is not available in Swift Linux.
            modificationSeconds: Int64(metadata.st_mtim.tv_sec),
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
#else
/// macOS keeps the shared initializer source-compatible while Linux owns the
/// concrete privacy inventory/deletion/export implementation.
public actor BurnBarLinuxPrivacyService {
    public init() {}
}
#endif

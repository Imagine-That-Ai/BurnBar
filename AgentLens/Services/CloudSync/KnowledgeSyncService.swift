import FirebaseAuth
@preconcurrency import FirebaseFunctions
import Foundation
import OpenBurnBarCore

/// Serializes Pensieve knowledge syncs across the process so a folder-watch
/// burst and a manual "Sync now" can't run two commits at once. Mirrors
/// `SessionLogSyncProcessGate` in SessionLogSyncService.swift.
private final class KnowledgeSyncProcessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func tryEnter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    func leave() {
        lock.lock(); running = false; lock.unlock()
    }
}

public enum KnowledgeSyncError: LocalizedError {
    case notSignedIn
    case vaultKeyUnavailable
    case configureFailed
    case commitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to OpenBurnBar Cloud before syncing Pensieve knowledge."
        case .vaultKeyUnavailable:
            return "The device vault key is unavailable, so knowledge cannot be sealed."
        case .configureFailed:
            return "Could not register the Pensieve knowledge source."
        case .commitFailed(let message):
            return message
        }
    }
}

/// Result of one knowledge commit (mirrors the `commitKnowledgeBatch` response).
public struct KnowledgeCommitResult: Sendable {
    public let written: Int
    public let skipped: Int
    public let tier: String
    public let chunkCount: Int
}

/// A unit of work to ingest into Pensieve: one source document + its facets.
public struct KnowledgeIngestItem: Sendable {
    public let text: String
    public let sourceKind: PensieveSourceKind
    /// Stable per-document path used as the source slug seed and sealed metadata.
    public let sourcePath: String
    public let title: String?
    public let section: String?
    public let category: String?

    public init(
        text: String,
        sourceKind: PensieveSourceKind,
        sourcePath: String,
        title: String? = nil,
        section: String? = nil,
        category: String? = nil
    ) {
        self.text = text
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.title = title
        self.section = section
        self.category = category
    }
}

/// Thin seam over the two Pensieve write callables so tests can inject a fake.
public protocol KnowledgeSyncCallable: Sendable {
    func configureKnowledgeSource(
        sourceKind: String,
        rootPath: String?,
        sourceSlug: String?
    ) async throws -> String
    func commitKnowledgeBatch(_ payload: [String: Any]) async throws -> KnowledgeCommitResult
}

/// Vault-key access seam (the same protocol SessionLogSyncService uses).
public protocol KnowledgeVaultKeyProviding: Sendable {
    func loadKey(uid: String) throws -> Data?
    func getOrCreateKey(uid: String) throws -> Data
}

extension CloudVaultKeyStore: KnowledgeVaultKeyProviding {}

/// Live Firebase callable adapter for the Pensieve write path.
public struct FirebaseKnowledgeSyncCallable: KnowledgeSyncCallable {
    public init() {}

    public func configureKnowledgeSource(
        sourceKind: String,
        rootPath: String?,
        sourceSlug: String?
    ) async throws -> String {
        let callable = Functions.functions(region: "us-central1").httpsCallable("configureKnowledgeSource")
        var payload: [String: Any] = ["sourceKind": sourceKind]
        if let rootPath, !rootPath.isEmpty { payload["rootPath"] = rootPath }
        if let sourceSlug, !sourceSlug.isEmpty { payload["sourceSlug"] = sourceSlug }
        let result = try await callable.call(payload)
        guard let dict = result.data as? [String: Any],
              let slug = dict["sourceSlug"] as? String, !slug.isEmpty else {
            throw KnowledgeSyncError.configureFailed
        }
        return slug
    }

    public func commitKnowledgeBatch(_ payload: [String: Any]) async throws -> KnowledgeCommitResult {
        let callable = Functions.functions(region: "us-central1").httpsCallable("commitKnowledgeBatch")
        let result = try await callable.call(payload)
        guard let dict = result.data as? [String: Any] else {
            throw KnowledgeSyncError.commitFailed("Malformed commitKnowledgeBatch response.")
        }
        return KnowledgeCommitResult(
            written: (dict["written"] as? NSNumber)?.intValue ?? 0,
            skipped: (dict["skipped"] as? NSNumber)?.intValue ?? 0,
            tier: dict["tier"] as? String ?? "pro",
            chunkCount: (dict["chunkCount"] as? NSNumber)?.intValue ?? 0
        )
    }
}

/// Device-side Pensieve ingestion. Drives the documented "Sync now" gap:
/// chunk → embed → cloak → seal → `commitKnowledgeBatch`, all on device, so the
/// server only ever stores cloaked vectors + sealed ciphertext (zero plaintext).
///
/// Mirrors the conventions of the other CloudSync services (process gate,
/// vault-key store seam, callable seam) so it slots into the existing sync
/// coordinator. The actual chunk/embed/cloak/seal logic is the shared
/// `PensieveKnowledgeChunker` (byte-identical to the TS shim).
public final class KnowledgeSyncService: @unchecked Sendable {
    private static let processGate = KnowledgeSyncProcessGate()

    private let callable: KnowledgeSyncCallable
    private let vaultKeyStore: KnowledgeVaultKeyProviding
    private let uidProvider: @Sendable () -> String?

    public private(set) var isSyncing = false
    public private(set) var lastSyncError: String?
    public private(set) var lastSyncDate: Date?
    public private(set) var lastWritten = 0

    public init(
        callable: KnowledgeSyncCallable = FirebaseKnowledgeSyncCallable(),
        vaultKeyStore: KnowledgeVaultKeyProviding = CloudVaultKeyStore(),
        uidProvider: @escaping @Sendable () -> String? = { Auth.auth().currentUser?.uid }
    ) {
        self.callable = callable
        self.vaultKeyStore = vaultKeyStore
        self.uidProvider = uidProvider
    }

    /// Ingest a batch of source documents into Pensieve. Registers each source
    /// (idempotent) then commits its cloaked + sealed chunks. Returns the
    /// aggregate written/skipped counts. Process-gated; a concurrent call is a
    /// no-op (returns `nil`).
    @discardableResult
    public func sync(items: [KnowledgeIngestItem]) async throws -> KnowledgeCommitResult? {
        guard !items.isEmpty else { return nil }
        guard let uid = uidProvider() else { throw KnowledgeSyncError.notSignedIn }
        guard Self.processGate.tryEnter() else { return nil }
        defer { Self.processGate.leave() }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let vaultKey: Data
        do {
            vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
        } catch {
            let error = KnowledgeSyncError.vaultKeyUnavailable
            lastSyncError = error.localizedDescription
            throw error
        }

        var totalWritten = 0
        var totalSkipped = 0
        var lastTier = "pro"
        var lastChunkCount = 0

        do {
            for item in items {
                // 1) Register the source (server enforces the per-tier source cap).
                let slug = try await callable.configureKnowledgeSource(
                    sourceKind: item.sourceKind.rawValue,
                    rootPath: item.sourcePath,
                    sourceSlug: Self.slugify(item.sourcePath)
                )

                // 2) chunk → embed → cloak → seal on device.
                let batch = try PensieveKnowledgeChunker.prepareBatch(
                    text: item.text,
                    sourceKind: item.sourceKind,
                    sourcePath: item.sourcePath,
                    sourceSlug: slug,
                    vaultKey: vaultKey,
                    title: item.title,
                    section: item.section,
                    category: item.category
                )
                guard !batch.vectors.isEmpty else { continue }

                // 3) commit (device-authed; server stores only ciphertext + vectors).
                let result = try await callable.commitKnowledgeBatch(Self.encode(batch))
                totalWritten += result.written
                totalSkipped += result.skipped
                lastTier = result.tier
                lastChunkCount = result.chunkCount
            }
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }

        lastWritten = totalWritten
        lastSyncDate = Date()
        return KnowledgeCommitResult(
            written: totalWritten,
            skipped: totalSkipped,
            tier: lastTier,
            chunkCount: lastChunkCount
        )
    }

    @discardableResult
    public func syncPreparedBatchPayloads(_ payloads: [[String: Any]]) async throws -> KnowledgeCommitResult? {
        guard !payloads.isEmpty else { return nil }
        guard uidProvider() != nil else { throw KnowledgeSyncError.notSignedIn }
        guard Self.processGate.tryEnter() else { return nil }
        defer { Self.processGate.leave() }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        var totalWritten = 0
        var totalSkipped = 0
        var lastTier = "pro"
        var lastChunkCount = 0

        do {
            for payload in payloads {
                let result = try await callable.commitKnowledgeBatch(payload)
                totalWritten += result.written
                totalSkipped += result.skipped
                lastTier = result.tier
                lastChunkCount = result.chunkCount
            }
        } catch {
            lastSyncError = error.localizedDescription
            throw error
        }

        lastWritten = totalWritten
        lastSyncDate = Date()
        return KnowledgeCommitResult(
            written: totalWritten,
            skipped: totalSkipped,
            tier: lastTier,
            chunkCount: lastChunkCount
        )
    }

    // MARK: - Encoding

    /// Encode a prepared batch into the `commitKnowledgeBatch` callable payload.
    /// Sends the vault-keyed `slugHmac` (opaque filter column) instead of any
    /// cleartext slug side channel; each vector carries `dedupHash` and NO
    /// cleartext `contentHash`/`sourcePath` (B-SEC-2).
    public static func encode(_ batch: PensieveKnowledgeBatch) -> [String: Any] {
        [
            "sourceSlug": batch.sourceSlug,
            "slugHmac": batch.slugHmac,
            "embeddingModelVersion": batch.embeddingModelVersion,
            "vectors": batch.vectors.map(encode(_:)),
        ]
    }

    private static func encode(_ vector: PensieveKnowledgeVector) -> [String: Any] {
        [
            "vectorId": vector.vectorId,
            "cloakedVector": vector.cloakedVector,
            "sealedCiphertext": encode(vector.sealedCiphertext),
            "sealedMetadata": encode(vector.sealedMetadata),
            "dedupHash": vector.dedupHash,
            "sourceKind": vector.sourceKind.rawValue,
            "chunkIndex": vector.chunkIndex,
            "byteCount": vector.byteCount,
        ]
    }

    private static func encode(_ sealed: CloudVaultSealedText) -> [String: Any] {
        [
            "algorithm": sealed.algorithm,
            "keyVersion": sealed.keyVersion,
            "nonce": sealed.nonce,
            "ciphertext": sealed.ciphertext,
            "tag": sealed.tag,
        ]
    }

    /// Server-compatible slug (matches `slugify` in knowledgeMemory.ts).
    static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let collapsed = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        var slug = String(collapsed)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(120))
    }
}

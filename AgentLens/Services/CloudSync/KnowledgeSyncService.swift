import FirebaseAuth
import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

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
    case signalIdentityUnavailable
    case trustedDeviceMissingSignalIdentity(deviceId: String, keyVersion: Int)
    case trustedDeviceSignalIdentityMismatch(deviceId: String, keyVersion: Int)

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
        case .signalIdentityUnavailable:
            return "This Mac has no published Signal identity for Pensieve knowledge sealing."
        case .trustedDeviceMissingSignalIdentity(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) is missing its Signal identity public key."
        case .trustedDeviceSignalIdentityMismatch(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) has an invalid Signal identity public key."
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

private struct PensieveSignalSealContext: Sendable {
    let uid: String
    let vaultKey: Data
    let localIdentity: OpenBurnBarSignalIdentityKeypair
    let recipients: [OpenBurnBarSignalAtRestRecipient]
}

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
        let signalContext: PensieveSignalSealContext?
        if Self.signalSealingIsEnabled() {
            do {
                let context = try await Self.prepareSignalSealContext(uid: uid)
                vaultKey = context.vaultKey
                signalContext = context
            } catch {
                lastSyncError = error.localizedDescription
                throw error
            }
        } else {
            do {
                vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
                signalContext = nil
            } catch {
                let error = KnowledgeSyncError.vaultKeyUnavailable
                lastSyncError = error.localizedDescription
                throw error
            }
        }

        var totalWritten = 0
        var totalSkipped = 0
        var lastTier = "pro"
        var lastChunkCount = 0

        do {
            for item in items {
                let sourceID = try CloudVaultCrypto.pensieveSlugHmac(Self.slugify(item.sourcePath), keyData: vaultKey)

                // 1) Register the source (server enforces the per-tier source cap).
                // The server sees only an opaque vault-keyed source id; the path is
                // sealed later in the per-vector metadata.
                let slug = try await callable.configureKnowledgeSource(
                    sourceKind: item.sourceKind.rawValue,
                    rootPath: nil,
                    sourceSlug: sourceID
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
                let result = try await callable.commitKnowledgeBatch(Self.encode(batch, signalContext: signalContext))
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
        encode(batch, signalEnvelopeForVector: { _ in nil })
    }

    public static func encode(
        _ batch: PensieveKnowledgeBatch,
        signalEnvelopeForVector: (PensieveKnowledgeVector) throws -> [String: Any]?
    ) rethrows -> [String: Any] {
        let vectors = try batch.vectors.map { vector in
            try encode(vector, signalEnvelope: signalEnvelopeForVector(vector))
        }
        return [
            "sourceSlug": batch.sourceSlug,
            "slugHmac": batch.slugHmac,
            "embeddingModelVersion": batch.embeddingModelVersion,
            "vectors": vectors,
        ]
    }

    private static func encode(_ vector: PensieveKnowledgeVector) -> [String: Any] {
        encode(vector, signalEnvelope: nil)
    }

    private static func encode(
        _ vector: PensieveKnowledgeVector,
        signalEnvelope: [String: Any]?
    ) -> [String: Any] {
        var encoded: [String: Any] = [
            "vectorId": vector.vectorId,
            "cloakedVector": vector.cloakedVector,
            "sealedCiphertext": encode(vector.sealedCiphertext),
            "sealedMetadata": encode(vector.sealedMetadata),
            "dedupHash": vector.dedupHash,
            "sourceKind": vector.sourceKind.rawValue,
            "chunkIndex": vector.chunkIndex,
            "byteCount": vector.byteCount,
        ]
        if let signalEnvelope {
            encoded["signalEnvelope"] = signalEnvelope
        }
        return encoded
    }

    private static func encode(
        _ batch: PensieveKnowledgeBatch,
        signalContext: PensieveSignalSealContext?
    ) throws -> [String: Any] {
        guard let signalContext else {
            return encode(batch)
        }
        return try encode(batch) { vector in
            try signalEnvelopeDictionary(for: vector, context: signalContext)
        }
    }

    private static func signalEnvelopeDictionary(
        for vector: PensieveKnowledgeVector,
        context: PensieveSignalSealContext
    ) throws -> [String: Any] {
        let plaintext = try CloudVaultCrypto.openText(vector.sealedCiphertext, keyData: context.vaultKey)
        let binding = CloudVaultSignalBinding(
            uid: context.uid,
            collection: "cloud_search_knowledge",
            docId: vector.vectorId,
            field: "sealedCiphertext"
        )
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            Data(plaintext.utf8),
            recipients: context.recipients,
            binding: binding
        )
        return try CloudVaultCrypto.signalEnvelopeDictionary(envelope)
    }

    private static func signalSealingIsEnabled() -> Bool {
        DataDomains.domain("pensieve")?.sealingScheme == CloudVaultCrypto.signalAtRestEncryption
    }

    private static func prepareSignalSealContext(uid: String) async throws -> PensieveSignalSealContext {
        let firestore = Firestore.firestore()
        let deviceId = await MainActor.run { AccountManager.shared.deviceId }
        let resolved = try await MacCloudVaultKeyAccess.keyForWriting(
            uid: uid,
            deviceId: deviceId,
            firestore: firestore
        )
        guard let signalIdentity = resolved.signalIdentity else {
            throw KnowledgeSyncError.signalIdentityUnavailable
        }
        let recipients = try await atRestRecipients(
            uid: uid,
            firestore: firestore,
            localIdentity: signalIdentity
        )
        return PensieveSignalSealContext(
            uid: uid,
            vaultKey: resolved.keyData,
            localIdentity: signalIdentity,
            recipients: recipients
        )
    }

    private static func atRestRecipients(
        uid: String,
        firestore: Firestore,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> [OpenBurnBarSignalAtRestRecipient] {
        let userRef = firestore.collection("users").document(uid)
        let trustedDevices = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()

        var recipientsByIdentityKeyId: [String: OpenBurnBarSignalAtRestRecipient] = [
            localIdentity.identityKeyId: localIdentity.atRestRecipient()
        ]

        for document in trustedDevices.documents {
            let data = document.data()
            let rawDeviceId = (data["deviceId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceId: String
            if let rawDeviceId, !rawDeviceId.isEmpty {
                deviceId = rawDeviceId
            } else {
                deviceId = document.documentID
            }
            guard let keyVersion = data["keyVersion"] as? Int else {
                throw KnowledgeSyncError.trustedDeviceSignalIdentityMismatch(
                    deviceId: deviceId,
                    keyVersion: 0
                )
            }
            let identityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(
                deviceId: deviceId,
                keyVersion: keyVersion
            )
            // Self-exclusion: the local recipient was already seeded above from the
            // authoritative in-memory keypair. NEVER overwrite it with a server-fetched
            // copy — a malicious/compromised directory could substitute our own key.
            // (Matches Mac/iOS atRestRecipients; this pensieve copy previously missed it.)
            if identityKeyId == localIdentity.identityKeyId { continue }
            let identityDoc = try await userRef.collection("signal_identity_public_keys")
                .document(identityKeyId)
                .getDocument()
            guard let identityData = identityDoc.data() else {
                throw KnowledgeSyncError.trustedDeviceMissingSignalIdentity(
                    deviceId: deviceId,
                    keyVersion: keyVersion
                )
            }
            guard identityData["deviceId"] as? String == deviceId,
                  identityData["identityKeyId"] as? String == identityKeyId,
                  identityData["keyVersion"] as? Int == keyVersion,
                  identityData["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption,
                  let publicKeyBase64 = identityData["publicKeyData"] as? String,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
                throw KnowledgeSyncError.trustedDeviceSignalIdentityMismatch(
                    deviceId: deviceId,
                    keyVersion: keyVersion
                )
            }
            recipientsByIdentityKeyId[identityKeyId] = OpenBurnBarSignalAtRestRecipient(
                recipientKind: "device",
                recipientIdentityKeyId: identityKeyId,
                publicKeyData: publicKeyData
            )
        }

        return recipientsByIdentityKeyId.values.sorted {
            $0.recipientIdentityKeyId < $1.recipientIdentityKeyId
        }
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

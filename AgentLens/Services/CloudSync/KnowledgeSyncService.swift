import FirebaseAuth
import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

/// Serializes Pensieve knowledge syncs across the process so a folder-watch
/// burst and a manual "Sync now" can't run two commits at once. Mirrors
/// `SessionLogSyncProcessGate` in SessionLogSyncService.swift.
private final class KnowledgeSyncProcessGate: Sendable {
    private let running = Locked(false)

    func tryEnter() -> Bool {
        running.withLock { running in
            guard !running else { return false }
            running = true
            return true
        }
    }

    func leave() { running.write(false) }
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
public final class KnowledgeSyncService: Sendable {
    private static let processGate = KnowledgeSyncProcessGate()

    private let callable: KnowledgeSyncCallable
    private let vaultKeyStore: KnowledgeVaultKeyProviding
    private let uidProvider: @Sendable () -> String?
    private let deviceIDProvider: @Sendable () -> String

    private let state = Locked(CloudSyncDomainState())

    public var isSyncing: Bool { state.read().isSyncing }
    public var lastSyncError: String? { state.read().lastSyncError }
    public var lastSyncDate: Date? { state.read().lastSyncDate }
    private let lastWrittenBox = Locked(0)
    public var lastWritten: Int { lastWrittenBox.read() }

    public init(
        callable: KnowledgeSyncCallable = FirebaseKnowledgeSyncCallable(),
        vaultKeyStore: KnowledgeVaultKeyProviding = CloudVaultKeyStore(),
        uidProvider: @escaping @Sendable () -> String? = { Auth.auth().currentUser?.uid },
        deviceIDProvider: @escaping @Sendable () -> String = {
            UserDefaults.standard.string(forKey: "com.openburnbar.deviceId") ?? "device_local"
        }
    ) {
        self.callable = callable
        self.vaultKeyStore = vaultKeyStore
        self.uidProvider = uidProvider
        self.deviceIDProvider = deviceIDProvider
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

        state.beginSyncing()
        defer { state.endSyncing() }

        let vaultKey: Data
        let signalContext: PensieveSignalSealContext?
        if Self.signalSealingIsEnabled() {
            do {
                let context = try await Self.prepareSignalSealContext(uid: uid, deviceId: deviceIDProvider())
                vaultKey = context.vaultKey
                signalContext = context
            } catch {
                state.withLock { $0.lastSyncError = error.localizedDescription }
                throw error
            }
        } else {
            do {
                vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
                signalContext = nil
            } catch {
                let error = KnowledgeSyncError.vaultKeyUnavailable
                state.withLock { $0.lastSyncError = error.localizedDescription }
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
                    uid: uid,
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
            state.withLock { $0.lastSyncError = error.localizedDescription }
            throw error
        }

        lastWrittenBox.write(totalWritten)
        state.withLock { $0.lastSyncDate = Date() }
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

        state.beginSyncing()
        defer { state.endSyncing() }

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
            state.withLock { $0.lastSyncError = error.localizedDescription }
            throw error
        }

        lastWrittenBox.write(totalWritten)
        state.withLock { $0.lastSyncDate = Date() }
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
            "vectors": vectors
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
            "byteCount": vector.byteCount
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
            binding: binding,
            senderIdentityKeyId: context.localIdentity.identityKeyId,
            senderIdentityPrivateKey: context.localIdentity.privateKeyData
        )
        return try CloudVaultCrypto.signalEnvelopeDictionary(envelope)
    }

    private static func signalSealingIsEnabled() -> Bool {
        DataDomains.domain("pensieve")?.sealingScheme == CloudVaultCrypto.signalAtRestEncryption
    }

    private static func prepareSignalSealContext(uid: String, deviceId: String) async throws -> PensieveSignalSealContext {
        let firestore = Firestore.firestore()
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
            let verified = try await CloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
                uid: uid,
                userRef: userRef,
                deviceDocument: document,
                localIdentity: localIdentity
            )
            if verified.signalIdentityKeyId == localIdentity.identityKeyId { continue }
            recipientsByIdentityKeyId[verified.signalIdentityKeyId] = OpenBurnBarSignalAtRestRecipient(
                recipientKind: "device",
                recipientIdentityKeyId: verified.signalIdentityKeyId,
                publicKeyData: verified.signalIdentityPublicKeyData
            )
        }

        return recipientsByIdentityKeyId.values.sorted {
            $0.recipientIdentityKeyId < $1.recipientIdentityKeyId
        }
    }

    private static func encode(_ sealed: CloudVaultSealedText) -> [String: Any] {
        var dict: [String: Any] = [
            "algorithm": sealed.algorithm,
            "keyVersion": sealed.keyVersion,
            "nonce": sealed.nonce,
            "ciphertext": sealed.ciphertext,
            "tag": sealed.tag
        ]
        // Path-bound (schemaVersion-2) chunks authenticate their AES-GCM tag over a
        // path-derived AAD. The reader rebuilds that AAD from uid+vectorId, but it must
        // see schemaVersion>=2 (to take the v2 branch) and the matching `aad` string (the
        // `aadData` consistency check). Dropping either silently routes the reader into the
        // legacy no-AAD branch and the tag check fails — making every path-bound chunk
        // undecryptable. Carry both when present (nil on the legacy/daemon uid-less path).
        if let schemaVersion = sealed.schemaVersion {
            dict["schemaVersion"] = schemaVersion
        }
        if let aad = sealed.aad {
            dict["aad"] = aad
        }
        return dict
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

struct MemoryCloudSyncResult: Equatable, Sendable {
    let uploaded: Int
    let skipped: Int
    let forgetReceipts: Int
    let cloudFactsDeleted: Int
}

private struct MemoryCloudFactPayload: Codable {
    let schemaVersion: Int
    let memoryID: MemoryID
    let text: String
    let kind: MemoryKind
    let scope: MemoryScope
    let confidence: Double
    let citations: [MemoryCitation]
    let validFrom: Date
    let updatedAt: Date
}

final class MemoryCloudSyncService: Sendable {
    private let store: ControlPlaneStore
    private let firestoreGateway: CloudSyncFirestoreGateway

    init(
        store: ControlPlaneStore,
        firestoreGateway: CloudSyncFirestoreGateway = CloudSyncFirestoreLiveGateway()
    ) {
        self.store = store
        self.firestoreGateway = firestoreGateway
    }

    @discardableResult
    func syncApprovedMemories(uid: String, vaultKey: Data, now: Date = Date()) async throws -> MemoryCloudSyncResult {
        let candidates = try await store.cloudSyncCandidateChatMemories(userID: uid)
        let eligible = try await store.cloudSyncEligibleChatMemories(userID: uid)
        let userDocument = firestoreGateway.collection("users").document(uid)
        let factCollection = userDocument.collection("memory_facts")
        let receiptCollection = userDocument.collection("memory_forget_receipts")

        var uploaded = 0
        for memory in eligible {
            // Chat memories keep their body in the app's snapshot table; memories the
            // Memory MCP engine mirrored keep theirs in `agent_memory_bodies`, and key
            // their document on the engine's own id so every device converges on one
            // document (the daemon id is derived from a path-dependent project id).
            let isAgent = memory.sourceKind == .agent
            let resolvedBody = isAgent
                ? try await store.openAgentMemoryBody(id: memory.id)
                : try await store.openChatMemoryBody(id: memory.id)
            // A forgotten mirrored row keeps its id mapping with an emptied body;
            // it must not be re-uploaded as an empty memory.
            guard let body = resolvedBody, body.isEmpty == false else { continue }
            let identity = isAgent ? try await store.engineMemoryID(for: memory.id) : nil
            if isAgent, identity == nil { continue }
            let encoded = try Self.encodeMemoryFact(
                memory: memory,
                body: body,
                uid: uid,
                vaultKey: vaultKey,
                now: now,
                documentIdentity: identity
            )
            try await factCollection.document(encoded.docID).setData(encoded.data, merge: true)
            uploaded += 1
        }

        var forgetReceipts = 0
        var deletedFacts = 0
        // The daemon cannot write a member-keyed tombstone, so a forgotten mirrored
        // memory would otherwise leave its sealed cloud copy behind for ever.
        try await store.enqueueTombstonesForForgottenAgentMemories(userID: uid, now: now)
        for tombstone in try await store.fetchPendingMemoryFactTombstones(userID: uid) {
            let encoded = try Self.encodeFactForgetReceipt(
                tombstone: tombstone,
                uid: uid,
                vaultKey: vaultKey,
                now: now
            )
            try await receiptCollection.document(encoded.docID).setData(encoded.data, merge: true)
            forgetReceipts += 1
            deletedFacts += try await Self.deleteCloudFact(
                memoryID: tombstone.memoryID,
                // A mirrored memory's document was keyed on the engine's id; the
                // mapping outlives the forget precisely so this can find it.
                cloudIdentity: try await store.cloudFactIdentity(for: tombstone.memoryID),
                vaultKey: vaultKey,
                from: factCollection
            )
            try await store.markMemoryFactTombstoneReplicated(id: tombstone.id, now: now)
        }
        var sourceRefHmacsToDelete = Set<String>()
        var replicatedSourceTombstoneIDs: [String] = []
        for tombstone in try await store.fetchPendingMemorySourceTombstones(userID: uid) {
            let encoded = try Self.encodeForgetReceipt(
                tombstone: tombstone,
                uid: uid,
                vaultKey: vaultKey,
                now: now
            )
            try await receiptCollection.document(encoded.docID).setData(encoded.data, merge: true)
            forgetReceipts += 1
            sourceRefHmacsToDelete.insert(encoded.sourceRefHmac)
            for sourceRef in try await store.fetchMemorySourceReferences(matching: tombstone) {
                sourceRefHmacsToDelete.insert(try Self.sourceRefHmac(
                    threadLogicalID: sourceRef.threadLogicalID,
                    messageID: sourceRef.messageID,
                    contentHash: sourceRef.contentHash,
                    vaultKey: vaultKey
                ))
            }
            replicatedSourceTombstoneIDs.append(tombstone.id)
        }
        if !sourceRefHmacsToDelete.isEmpty {
            deletedFacts += try await Self.deleteCloudFacts(
                matchingSourceRefHmacs: sourceRefHmacsToDelete,
                from: factCollection
            )
        }
        for id in replicatedSourceTombstoneIDs {
            try await store.markMemorySourceTombstoneReplicated(id: id, now: now)
        }

        return MemoryCloudSyncResult(
            uploaded: uploaded,
            skipped: max(0, candidates.count - eligible.count),
            forgetReceipts: forgetReceipts,
            cloudFactsDeleted: deletedFacts
        )
    }

    /// - Parameter documentIdentity: the id the blinded document and the sealed
    ///   payload key on. Nil keeps the local memory id, which is right for chat
    ///   memories; engine-mirrored memories pass the engine's own id so the same
    ///   memory resolves to one document on every device.
    static func encodeMemoryFact(
        memory: Memory,
        body: String,
        uid: String,
        vaultKey: Data,
        now: Date,
        documentIdentity: String? = nil
    ) throws -> (docID: String, data: [String: Any]) {
        let identity = documentIdentity ?? memory.id
        let docID = try CloudVaultCrypto.pensieveSlugHmac("memory-fact:\(identity)", keyData: vaultKey)
        let payload = MemoryCloudFactPayload(
            schemaVersion: 1,
            // The sealed id matches the id the document is keyed on, so a device
            // that opens this envelope can address the same memory it named.
            memoryID: identity,
            text: body,
            kind: memory.kind,
            scope: memory.scope,
            confidence: memory.confidence,
            citations: memory.citations,
            validFrom: memory.validFrom,
            updatedAt: memory.updatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payloadData = try encoder.encode(payload)
        let aad = try CloudVaultAADContext(
            uid: uid,
            collection: "memory_facts",
            docID: docID,
            field: "sealedMemory"
        )
        let sealed = try CloudVaultCrypto.sealBlob(payloadData, keyData: vaultKey, aadContext: aad)
        let rawSourceRefHmacs = try memory.citations.map {
            try Self.sourceRefHmac(
                threadLogicalID: $0.threadLogicalID,
                messageID: $0.messageID,
                contentHash: $0.contentHash,
                vaultKey: vaultKey
            )
        }
        var seenSourceRefs = Set<String>()
        let sourceRefHmacs = Array(rawSourceRefHmacs
            .filter { seenSourceRefs.insert($0).inserted }
            .prefix(50))

        return (
            docID,
            [
                "uid": uid,
                "docID": docID,
                "schemaVersion": 1,
                "sourceKind": memory.sourceKind.rawValue,
                "kind": memory.kind.rawValue,
                "reviewStatus": MemoryReviewStatus.approved.rawValue,
                "sealedMemory": try CloudVaultCrypto.firestoreDictionary(sealed),
                "sourceRefHmacs": sourceRefHmacs,
                "citationCount": min(memory.citations.count, 50),
                "validFrom": memory.validFrom,
                "updatedAt": memory.updatedAt,
                "replicatedAt": now
            ]
        )
    }

    static func encodeForgetReceipt(
        tombstone: ControlPlaneStore.MemorySourceTombstoneRecord,
        uid: String,
        vaultKey: Data,
        now: Date
    ) throws -> (docID: String, sourceRefHmac: String, data: [String: Any]) {
        let sourceRefHmac = try Self.sourceRefHmac(
            threadLogicalID: tombstone.threadLogicalID,
            messageID: tombstone.messageID,
            contentHash: tombstone.contentHash,
            vaultKey: vaultKey
        )
        let docID = try CloudVaultCrypto.pensieveSlugHmac("memory-forget:\(tombstone.id)", keyData: vaultKey)
        return (
            docID,
            sourceRefHmac,
            [
                "uid": uid,
                "receiptID": docID,
                "schemaVersion": 1,
                "sourceRefHmac": sourceRefHmac,
                "reason": normalizedForgetReason(tombstone.reason),
                "createdAt": tombstone.createdAt,
                "replicatedAt": now
            ]
        )
    }

    static func encodeFactForgetReceipt(
        tombstone: ControlPlaneStore.MemoryFactTombstoneRecord,
        uid: String,
        vaultKey: Data,
        now: Date
    ) throws -> (docID: String, data: [String: Any]) {
        let docID = try CloudVaultCrypto.pensieveSlugHmac("memory-forget:\(tombstone.id)", keyData: vaultKey)
        let memoryIDHmac = try CloudVaultCrypto.pensieveSlugHmac("memory-id:\(tombstone.memoryID)", keyData: vaultKey)
        let rawSourceRefHmacs = try tombstone.sourceRefs.map {
            try Self.sourceRefHmac(
                threadLogicalID: $0.threadLogicalID,
                messageID: $0.messageID,
                contentHash: $0.contentHash,
                vaultKey: vaultKey
            )
        }
        var seenSourceRefs = Set<String>()
        let sourceRefHmacs = Array(rawSourceRefHmacs
            .filter { seenSourceRefs.insert($0).inserted }
            .prefix(50))
        return (
            docID,
            [
                "uid": uid,
                "receiptID": docID,
                "schemaVersion": 1,
                "memoryIdHmac": memoryIDHmac,
                "sourceRefHmacs": sourceRefHmacs,
                "reason": normalizedForgetReason(tombstone.reason),
                "createdAt": tombstone.createdAt,
                "replicatedAt": now
            ]
        )
    }

    private static func sourceRefHmac(
        threadLogicalID: String,
        messageID: String?,
        contentHash: String?,
        vaultKey: Data
    ) throws -> String {
        try CloudVaultCrypto.pensieveSlugHmac(
            "memory-source:\(threadLogicalID)|\(messageID ?? "")|\(contentHash ?? "")",
            keyData: vaultKey
        )
    }

    private static func deleteCloudFacts(
        matchingSourceRefHmacs sourceRefHmacs: Set<String>,
        from collection: CloudSyncCollectionGateway
    ) async throws -> Int {
        guard !sourceRefHmacs.isEmpty else { return 0 }
        let snapshot = try await collection.getDocuments()
        var deleted = 0
        for document in snapshot.documents {
            let data = document.data()
            guard let refs = data["sourceRefHmacs"] as? [String],
                  refs.contains(where: { sourceRefHmacs.contains($0) }) else {
                continue
            }
            try await collection.document(document.documentID).deleteDocument()
            deleted += 1
        }
        return deleted
    }

    /// - Parameter cloudIdentity: the id the document was keyed on at upload —
    ///   the engine's own id for a mirrored memory. Passing the local id for one
    ///   of those would delete nothing and silently strand the sealed copy.
    private static func deleteCloudFact(
        memoryID: MemoryID,
        cloudIdentity: String? = nil,
        vaultKey: Data,
        from collection: CloudSyncCollectionGateway
    ) async throws -> Int {
        let docID = try CloudVaultCrypto.pensieveSlugHmac("memory-fact:\(cloudIdentity ?? memoryID)", keyData: vaultKey)
        let document = collection.document(docID)
        let existed = try await document.getData() != nil
        try await document.deleteDocument()
        return existed ? 1 : 0
    }

    private static func normalizedForgetReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "user_delete", "review_status_quarantined", "review_status_rejected", "clear_history", "gc_30d":
            return trimmed
        default:
            return "unknown"
        }
    }
}

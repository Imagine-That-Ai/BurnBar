import CryptoKit
import Foundation

/// Source kind for a Pensieve knowledge chunk. Matches the server `SOURCE_KINDS`
/// set in `functions/src/callables/knowledgeMemory.ts`.
public enum PensieveSourceKind: String, Codable, Sendable {
    case repoDocs = "repo_docs"
    case notes = "notes"
    case chatMemory = "chat_memory"
}

/// One cloaked + sealed knowledge chunk, shaped EXACTLY as one element of the
/// `vectors` array `commitKnowledgeBatch` validates (vectorId, cloakedVector
/// [384], sealedCiphertext, sealedMetadata, dedupHash hex, sourceKind,
/// chunkIndex, byteCount). Mirrors `PreparedVector` in
/// `tools/openburnbar-mcp-remote/src/memoryHook.ts`.
///
/// B-SEC-2 privacy contract: the row carries NO cleartext side channels. The
/// old `contentHash` (keyless SHA-256 of the plaintext — a dedup oracle) and
/// `sourcePath` (real repo file path) are gone. Idempotency is keyed by
/// `dedupHash`, a VAULT-KEYED HMAC of the chunk plaintext the device computes;
/// the real path lives only inside `sealedMetadata`.
public struct PensieveKnowledgeVector: Sendable {
    public let vectorId: String
    public let cloakedVector: [Double]
    public let sealedCiphertext: CloudVaultSealedText
    public let sealedMetadata: CloudVaultSealedText
    public let dedupHash: String
    public let sourceKind: PensieveSourceKind
    public let chunkIndex: Int
    public let byteCount: Int

    public init(
        vectorId: String,
        cloakedVector: [Double],
        sealedCiphertext: CloudVaultSealedText,
        sealedMetadata: CloudVaultSealedText,
        dedupHash: String,
        sourceKind: PensieveSourceKind,
        chunkIndex: Int,
        byteCount: Int
    ) {
        self.vectorId = vectorId
        self.cloakedVector = cloakedVector
        self.sealedCiphertext = sealedCiphertext
        self.sealedMetadata = sealedMetadata
        self.dedupHash = dedupHash
        self.sourceKind = sourceKind
        self.chunkIndex = chunkIndex
        self.byteCount = byteCount
    }
}

/// A fully-prepared batch ready for `commitKnowledgeBatch`.
///
/// `slugHmac` is the vault-keyed HMAC of `sourceSlug` — the opaque filter column
/// that replaces the cleartext `sourceSlug` on the stored rows (B-SEC-2).
public struct PensieveKnowledgeBatch: Sendable {
    public let sourceSlug: String
    public let slugHmac: String
    public let embeddingModelVersion: String
    public let vectors: [PensieveKnowledgeVector]

    public init(
        sourceSlug: String,
        slugHmac: String,
        embeddingModelVersion: String,
        vectors: [PensieveKnowledgeVector]
    ) {
        self.sourceSlug = sourceSlug
        self.slugHmac = slugHmac
        self.embeddingModelVersion = embeddingModelVersion
        self.vectors = vectors
    }
}

/// On-device chunk → redact → embed → cloak → seal pipeline. The text and all
/// metadata are sealed with the vault key before they ever leave the device;
/// the server stores only ciphertext + cloaked vectors (zero plaintext).
///
/// Mirrors the TS device path: chunking sized for `requireSealedText`'s base64
/// cap, the `redactSecrets` patterns from memoryHook.ts, the vault-keyed
/// `dedupHash` used as the idempotent `vectorId`, and `seal.ts` (AES-256-GCM via
/// `CloudVaultCrypto.sealText`).
public enum PensieveKnowledgeChunker {
    /// Keep each sealed chunk well under `requireSealedText`'s base64 cap and the
    /// server's `MAX_CHUNK_BYTES` (64 KiB) — same ceiling memoryHook.ts uses.
    public static let maxChunkBytes = 6 * 1024
    /// Soft overlap so a fact split across a boundary still embeds coherently.
    private static let chunkOverlapBytes = 256

    // MARK: - Path-bound AAD (RR-8)

    /// The Firestore collection a sealed chunk lands in: `users/{uid}/<this>/{vectorId}`
    /// (knowledgeMemory.ts `commitKnowledgeBatch`). This is the same collection the
    /// at-rest Signal binding pins (`CloudVaultSignalBinding` in KnowledgeSyncService),
    /// so the AES-GCM AAD and the Signal HPKE `info` bind to identical coordinates.
    public static let chunkCollection = "cloud_search_knowledge"
    /// Firestore field name the sealed chunk text occupies — the AAD `field` for the
    /// ciphertext, matching the Signal binding's `bindingField`.
    public static let chunkCiphertextField = "sealedCiphertext"
    /// Firestore field name the sealed chunk metadata occupies — the AAD `field` for
    /// the metadata blob.
    public static let chunkMetadataField = "sealedMetadata"

    /// Path-bound AAD context for one sealed chunk field, binding `uid | collection |
    /// docId | field` exactly as `ConversationCloudSealer.seal` does. The doc id IS
    /// the chunk's `vectorId` (= dedupHash) — the opaque Firestore doc id the server
    /// stores it under — so a storage adversary cannot transplant a sealed chunk to a
    /// different vectorId, collection, or field within the same account. Mirrors the
    /// server + Signal binding (`collection: "cloud_search_knowledge"`,
    /// `docId: vectorId`, `field: "sealedCiphertext"`).
    public static func chunkAADContext(
        uid: String,
        vectorId: String,
        field: String
    ) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: chunkCollection,
            docID: vectorId,
            field: field
        )
    }

    // MARK: - Secret redaction (mirror memoryHook.ts SECRET_PATTERNS)

    private struct SecretPattern { let regex: NSRegularExpression; let label: String }

    private static let secretPatterns: [SecretPattern] = {
        let specs: [(String, String)] = [
            ("sk-[A-Za-z0-9]{20,}", "[REDACTED_API_KEY]"),
            ("\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b", "[REDACTED_AWS_KEY]"),
            ("ghp_[A-Za-z0-9]{30,}", "[REDACTED_GH_TOKEN]"),
            ("xox[baprs]-[A-Za-z0-9-]{10,}", "[REDACTED_SLACK_TOKEN]"),
            ("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----", "[REDACTED_PRIVATE_KEY]"),
            ("\\b[Bb]earer\\s+[A-Za-z0-9._-]{20,}", "[REDACTED_BEARER]"),
            ("\\b(?:password|passwd|secret|api[_-]?key|token)\\s*[:=]\\s*\\S+", "[REDACTED_SECRET]"),
            ("\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b", "[REDACTED_JWT]")
        ]
        return specs.compactMap { pattern, label in
            (try? NSRegularExpression(pattern: pattern)).map { SecretPattern(regex: $0, label: label) }
        }
    }()

    /// Replace known secret shapes with labels. Returns the cleaned text.
    public static func redactSecrets(_ text: String) -> String {
        var out = text
        for spec in secretPatterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = spec.regex.stringByReplacingMatches(in: out, range: range, withTemplate: spec.label)
        }
        return out
    }

    // MARK: - Chunking

    /// Split UTF-8 text into byte-bounded chunks at word boundaries with a small
    /// overlap. Never produces a chunk over `maxChunkBytes` bytes.
    public static func chunk(_ text: String, maxBytes: Int = maxChunkBytes) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.utf8.count <= maxBytes { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        // Split on whitespace runs, preserving the words.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        for word in words {
            let wordBytes = word.utf8.count + 1 // +1 for the joining space
            if currentBytes + wordBytes > maxBytes, !current.isEmpty {
                chunks.append(current)
                // Soft overlap from the tail of the previous chunk.
                current = String(current.suffix(chunkOverlapBytes / 4))
                currentBytes = current.utf8.count
            }
            if !current.isEmpty { current += " " }
            current += word
            currentBytes += wordBytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Prepare a batch

    /// Build a `commitKnowledgeBatch`-ready batch from a single source document.
    /// Each chunk is redacted, vault-keyed dedup-hashed (the idempotent
    /// `vectorId`), embedded + cloaked, and the text + metadata are sealed with the
    /// vault key. Duplicate chunks (same dedupHash) within the batch are dropped.
    /// No cleartext `contentHash`/`sourcePath` leaves the device (B-SEC-2).
    ///
    /// - Parameters:
    ///   - text: full plaintext of the source document (stays on device).
    ///   - sourceKind: repo_docs / notes / chat_memory.
    ///   - sourcePath: stable per-chunk path, surfaced in sealed metadata only.
    ///   - sourceSlug: server source slug (from `configureKnowledgeSource`).
    ///   - vaultKey: 32-byte device vault key.
    ///   - uid: signed-in user id. When present (RR-8), every chunk's text and
    ///     metadata are sealed PATH-BOUND to `uid | cloud_search_knowledge | vectorId
    ///     | field`, so a storage adversary cannot transplant a sealed chunk across
    ///     accounts, collections, or doc ids. When `nil` (the daemon queue writer,
    ///     which has no auth session) chunks fall back to the legacy global AAD;
    ///     `openChunkText`/`openChunkMetadata` read both.
    ///   - title / section / category: optional sealed metadata facets.
    public static func prepareBatch(
        text: String,
        sourceKind: PensieveSourceKind,
        sourcePath: String,
        sourceSlug: String,
        vaultKey: Data,
        uid: String? = nil,
        title: String? = nil,
        section: String? = nil,
        category: String? = nil,
        modelVersion: String = PensieveVectorCloak.deterministicModelVersion
    ) throws -> PensieveKnowledgeBatch {
        let cleaned = redactSecrets(text)
        let chunks = chunk(cleaned)
        // The opaque filter column that replaces the cleartext `sourceSlug`.
        let slugHmac = try CloudVaultCrypto.pensieveSlugHmac(sourceSlug, keyData: vaultKey)
        var seen = Set<String>()
        var vectors: [PensieveKnowledgeVector] = []
        vectors.reserveCapacity(chunks.count)

        for (index, chunkText) in chunks.enumerated() {
            let trimmed = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Vault-keyed HMAC of the plaintext — the idempotency key and the
            // opaque `vectorId`. Unlike the legacy keyless SHA-256 `contentHash`,
            // this is unguessable without the vault key (no dedup oracle).
            let dedupHash = try CloudVaultCrypto.pensieveDedupHash(trimmed, keyData: vaultKey)
            guard seen.insert(dedupHash).inserted else { continue }

            let cloaked = PensieveVectorCloak.embedAndCloak(
                trimmed,
                vaultKey: vaultKey,
                isQuery: false,
                modelVersion: modelVersion
            ).vector

            // Sealed metadata mirrors the shape the shim's decryptKnowledgeContent
            // + post-filters read (source_path / section / category / page_title).
            // The real path lives ONLY here, inside the ciphertext.
            var metadata: [String: Any] = [
                "source": "member-knowledge",
                "source_path": sourcePath,
                "chunk_index": index,
                "sourceKind": sourceKind.rawValue,
                "sourceSlug": sourceSlug
            ]
            if let title { metadata["page_title"] = redactSecrets(title).prefix(120).description }
            if let section { metadata["section"] = section }
            if let category { metadata["category"] = category }
            let metadataJSON = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            )
            let metadataString = String(decoding: metadataJSON, as: UTF8.self)

            // RR-8: bind each sealed field to its real Firestore identity
            // (uid | cloud_search_knowledge | vectorId | field). The doc id IS the
            // vectorId (= dedupHash), already computed above. With no uid (daemon
            // queue) we seal with the legacy global AAD so the unauthenticated
            // writer keeps working; readers open both shapes.
            let ciphertextAAD = try uid.map {
                try chunkAADContext(uid: $0, vectorId: dedupHash, field: chunkCiphertextField)
            }
            let metadataAAD = try uid.map {
                try chunkAADContext(uid: $0, vectorId: dedupHash, field: chunkMetadataField)
            }
            let sealedCiphertext = try CloudVaultCrypto.sealText(
                trimmed,
                keyData: vaultKey,
                aadContext: ciphertextAAD
            )
            let sealedMetadata = try CloudVaultCrypto.sealText(
                metadataString,
                keyData: vaultKey,
                aadContext: metadataAAD
            )

            vectors.append(
                PensieveKnowledgeVector(
                    vectorId: dedupHash,
                    cloakedVector: cloaked,
                    sealedCiphertext: sealedCiphertext,
                    sealedMetadata: sealedMetadata,
                    dedupHash: dedupHash,
                    sourceKind: sourceKind,
                    chunkIndex: index,
                    byteCount: trimmed.utf8.count
                )
            )
        }

        return PensieveKnowledgeBatch(
            sourceSlug: sourceSlug,
            slugHmac: slugHmac,
            embeddingModelVersion: modelVersion,
            vectors: vectors
        )
    }

    // MARK: - Read (RR-8 backward-compatible open)

    /// Open a sealed chunk's text, threading the RR-8 path-bound AAD context when the
    /// reader knows the binding coordinates. Mirrors `ConversationCloudSealer.open`'s
    /// fallback: pass `uid` + `vectorId` for path-bound (schemaVersion-2) chunks; legacy
    /// global-AAD chunks (sealed before RR-8, or by the daemon with no uid) still open
    /// because `CloudVaultCrypto.openText` ignores the context for schemaVersion-1
    /// envelopes and accepts the legacy v1 AAD string. Pass `uid: nil` to open ONLY the
    /// legacy shape (the original behavior).
    public static func openChunkText(
        _ sealed: CloudVaultSealedText,
        keyData: Data,
        uid: String? = nil,
        vectorId: String? = nil
    ) throws -> String {
        try CloudVaultCrypto.openText(
            sealed,
            keyData: keyData,
            aadContext: chunkAADContext(uid: uid, vectorId: vectorId, field: chunkCiphertextField)
        )
    }

    /// Open a sealed chunk's metadata blob, threading the RR-8 path-bound AAD context
    /// (field `sealedMetadata`) with the same legacy-readable fallback as
    /// `openChunkText`.
    public static func openChunkMetadata(
        _ sealed: CloudVaultSealedText,
        keyData: Data,
        uid: String? = nil,
        vectorId: String? = nil
    ) throws -> String {
        try CloudVaultCrypto.openText(
            sealed,
            keyData: keyData,
            aadContext: chunkAADContext(uid: uid, vectorId: vectorId, field: chunkMetadataField)
        )
    }

    /// Build the chunk AAD context only when BOTH binding coordinates are known.
    /// Either missing (a legacy reader that never threads the path) yields `nil`,
    /// which makes the open path fall back to the legacy unauthenticated/global-AAD
    /// branch — never a hard failure on pre-RR-8 data.
    private static func chunkAADContext(
        uid: String?,
        vectorId: String?,
        field: String
    ) throws -> CloudVaultAADContext? {
        guard let uid, let vectorId else { return nil }
        return try chunkAADContext(uid: uid, vectorId: vectorId, field: field)
    }
}

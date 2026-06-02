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
/// [384], sealedCiphertext, sealedMetadata, contentHash hex, sourceKind,
/// sourcePath, chunkIndex, byteCount). Mirrors `PreparedVector` in
/// `tools/openburnbar-mcp-remote/src/memoryHook.ts`.
public struct PensieveKnowledgeVector: Sendable {
    public let vectorId: String
    public let cloakedVector: [Double]
    public let sealedCiphertext: CloudVaultSealedText
    public let sealedMetadata: CloudVaultSealedText
    public let contentHash: String
    public let sourceKind: PensieveSourceKind
    public let sourcePath: String
    public let chunkIndex: Int
    public let byteCount: Int

    public init(
        vectorId: String,
        cloakedVector: [Double],
        sealedCiphertext: CloudVaultSealedText,
        sealedMetadata: CloudVaultSealedText,
        contentHash: String,
        sourceKind: PensieveSourceKind,
        sourcePath: String,
        chunkIndex: Int,
        byteCount: Int
    ) {
        self.vectorId = vectorId
        self.cloakedVector = cloakedVector
        self.sealedCiphertext = sealedCiphertext
        self.sealedMetadata = sealedMetadata
        self.contentHash = contentHash
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.chunkIndex = chunkIndex
        self.byteCount = byteCount
    }
}

/// A fully-prepared batch ready for `commitKnowledgeBatch`.
public struct PensieveKnowledgeBatch: Sendable {
    public let sourceSlug: String
    public let embeddingModelVersion: String
    public let vectors: [PensieveKnowledgeVector]

    public init(sourceSlug: String, embeddingModelVersion: String, vectors: [PensieveKnowledgeVector]) {
        self.sourceSlug = sourceSlug
        self.embeddingModelVersion = embeddingModelVersion
        self.vectors = vectors
    }
}

/// On-device chunk → redact → embed → cloak → seal pipeline. The text and all
/// metadata are sealed with the vault key before they ever leave the device;
/// the server stores only ciphertext + cloaked vectors (zero plaintext).
///
/// Mirrors the TS device path: chunking sized for `requireSealedText`'s base64
/// cap, the `redactSecrets` patterns from memoryHook.ts, the SHA-256 contentHash
/// used as the idempotent `vectorId`, and `seal.ts` (AES-256-GCM via
/// `CloudVaultCrypto.sealText`).
public enum PensieveKnowledgeChunker {
    /// Keep each sealed chunk well under `requireSealedText`'s base64 cap and the
    /// server's `MAX_CHUNK_BYTES` (64 KiB) — same ceiling memoryHook.ts uses.
    public static let maxChunkBytes = 6 * 1024
    /// Soft overlap so a fact split across a boundary still embeds coherently.
    private static let chunkOverlapBytes = 256

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
            ("\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b", "[REDACTED_JWT]"),
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
    /// Each chunk is redacted, content-hashed (the idempotent `vectorId`),
    /// embedded + cloaked, and the text + metadata are sealed with the vault key.
    /// Duplicate chunks (same contentHash) within the batch are dropped.
    ///
    /// - Parameters:
    ///   - text: full plaintext of the source document (stays on device).
    ///   - sourceKind: repo_docs / notes / chat_memory.
    ///   - sourcePath: stable per-chunk path, surfaced in sealed metadata only.
    ///   - sourceSlug: server source slug (from `configureKnowledgeSource`).
    ///   - vaultKey: 32-byte device vault key.
    ///   - title / section / category: optional sealed metadata facets.
    public static func prepareBatch(
        text: String,
        sourceKind: PensieveSourceKind,
        sourcePath: String,
        sourceSlug: String,
        vaultKey: Data,
        title: String? = nil,
        section: String? = nil,
        category: String? = nil,
        modelVersion: String = PensieveVectorCloak.deterministicModelVersion
    ) throws -> PensieveKnowledgeBatch {
        let cleaned = redactSecrets(text)
        let chunks = chunk(cleaned)
        var seen = Set<String>()
        var vectors: [PensieveKnowledgeVector] = []
        vectors.reserveCapacity(chunks.count)

        for (index, chunkText) in chunks.enumerated() {
            let trimmed = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let contentHash = sha256Hex(trimmed)
            guard seen.insert(contentHash).inserted else { continue }

            let cloaked = PensieveVectorCloak.embedAndCloak(
                trimmed,
                vaultKey: vaultKey,
                isQuery: false,
                modelVersion: modelVersion
            ).vector

            // Sealed metadata mirrors the shape the shim's decryptKnowledgeContent
            // + post-filters read (source_path / section / category / page_title).
            var metadata: [String: Any] = [
                "source": "member-knowledge",
                "source_path": sourcePath,
                "chunk_index": index,
                "sourceKind": sourceKind.rawValue,
                "sourceSlug": sourceSlug,
            ]
            if let title { metadata["page_title"] = redactSecrets(title).prefix(120).description }
            if let section { metadata["section"] = section }
            if let category { metadata["category"] = category }
            let metadataJSON = try JSONSerialization.data(
                withJSONObject: metadata,
                options: [.sortedKeys]
            )
            let metadataString = String(decoding: metadataJSON, as: UTF8.self)

            let sealedCiphertext = try CloudVaultCrypto.sealText(trimmed, keyData: vaultKey)
            let sealedMetadata = try CloudVaultCrypto.sealText(metadataString, keyData: vaultKey)

            vectors.append(
                PensieveKnowledgeVector(
                    vectorId: contentHash,
                    cloakedVector: cloaked,
                    sealedCiphertext: sealedCiphertext,
                    sealedMetadata: sealedMetadata,
                    contentHash: contentHash,
                    sourceKind: sourceKind,
                    sourcePath: sourcePath,
                    chunkIndex: index,
                    byteCount: trimmed.utf8.count
                )
            )
        }

        return PensieveKnowledgeBatch(
            sourceSlug: sourceSlug,
            embeddingModelVersion: modelVersion,
            vectors: vectors
        )
    }
}

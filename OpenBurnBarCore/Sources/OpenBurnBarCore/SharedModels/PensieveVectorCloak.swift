import CryptoKit
import Foundation

/// Swift port of the Pensieve on-device embedding + vault-key vector cloaking
/// (mirrors `tools/openburnbar-mcp-remote/src/embed.ts`). Lets the iOS/iPadOS
/// app and the Mac daemon produce the exact same cloaked 384-dim vectors the
/// hosted MCP (`knowledge.ts`) and `commitKnowledgeBatch` expect — index-time
/// and query-time must use the SAME model version + cloak so cosine ranking is
/// preserved.
///
/// Cloaking is an orthonormal map Q (a product of Householder reflections,
/// each Hᵢ = I − 2·vᵢvᵢᵀ with ‖vᵢ‖ = 1). Claim only the proven properties (see
/// `docs/pensieve-leakage-analysis.md`):
///   - Hides the public-model (bge) basis: stored vectors are not in the raw
///     bge frame, so off-the-shelf embedding-inversion models cannot be applied
///     DIRECTLY to them (raises the bar; not a non-invertibility proof).
///   - Per-user distinct stored bytes (PARTIAL cross-tenant resistance): Q is
///     per-user, so the same plaintext under two members' keys yields different
///     vectors (defeats exact-match joins). NOT full unlinkability — with 24
///     reflections in 384-dim, cross-tenant cosine ≈ 0.77, so similarity-based
///     cross-tenant linkage is still possible; full decorrelation needs ~dim
///     reflections (a versioned re-cloak).
/// What it does NOT do — accepted, documented leakage: because Q is orthonormal,
/// `<Qx, Qy> = <x, y>` and `‖Qx‖ = ‖x‖`, so cosine similarity is preserved
/// EXACTLY. The pairwise-cosine matrix, k-NN graph, clusters, and
/// similarity-dedup stay computable by the server WITHOUT the key — within one
/// user and across users. (That same identity is the feature: it lets
/// server-side findNearest recall work over cloaked vectors, and it keeps index-
/// vs query-time ranking equal to raw space.) Q is derived deterministically
/// from the 32-byte device vault key and the model version, byte-for-byte
/// identical to the TS construction.
public enum PensieveVectorCloak {
    /// Pinned production embedding model id stored on every vector. Index- and
    /// query-time vectors are only comparable within one version.
    ///
    /// FLAG-DAY (dedup-v0 retirement): bumped from "bge-small-en-v1.5" to the
    /// "-vault-dedup-v1" tag so a re-ingest lands every vector under a NEW tag.
    /// The server search floors `dedupHashVersion == 1` AND filters this tag, so
    /// stranded legacy v0 rows (still on the old "bge-small-en-v1.5" tag) become
    /// unreachable by recall and are deleted by `purgeLegacyKnowledgeVectors`.
    /// MUST stay byte-identical to `EMBEDDING_MODEL_VERSION` in
    /// `tools/openburnbar-mcp-remote/src/embed.ts`.
    public static let embeddingModelVersion = "bge-small-en-v1.5-vault-dedup-v1"
    /// Deterministic offline/test embedder id. Tagged distinctly so its vectors
    /// can never be mixed with real bge vectors by the version-match guard.
    public static let deterministicModelVersion = "hashing-bow-v1"
    public static let embeddingDim = 384

    /// bge retrieval asymmetry: queries get an instruction prefix, documents do not.
    public static let bgeQueryInstruction = "Represent this sentence for searching relevant passages: "

    /// Number of Householder reflections composed into the cloak. Matches
    /// `CLOAK_REFLECTIONS` in embed.ts (>log2(dim) for thorough mixing).
    private static let cloakReflections = 24
    private static let cloakSalt = Data("OpenBurnBar-Pensieve-Cloak-Salt-v1".utf8)

    // MARK: - HKDF (identical construction to embed.ts / resume.ts)

    /// RFC 5869 HKDF-SHA256 keystream, byte-identical to `hkdfSha256` in embed.ts
    /// (counter is a single byte, info then counter, salt defaults to 32 zero
    /// bytes when empty). Kept explicit so the Householder keystream matches the
    /// TS implementation exactly; CryptoKit's `HKDF.deriveKey` only exposes the
    /// final OKM, not the intermediate keystream this PRNG consumes.
    private static func hkdfKeystream(input: Data, salt: Data, info: Data, length: Int) -> Data {
        let saltKey = SymmetricKey(data: salt.isEmpty ? Data(repeating: 0, count: 32) : salt)
        let prk = Data(HMAC<SHA256>.authenticationCode(for: input, using: saltKey))
        let prkKey = SymmetricKey(data: prk)
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var block = previous
            block.append(info)
            block.append(counter)
            let digest = Data(HMAC<SHA256>.authenticationCode(for: block, using: prkKey))
            output.append(digest)
            previous = digest
            counter = counter &+ 1
        }
        return output.prefix(length)
    }

    // MARK: - Deterministic uniform stream + Box-Muller (mirror embed.ts)

    private final class UniformStream {
        private let bytes: [UInt8]
        private var offset = 0
        init(_ data: Data) { self.bytes = Array(data) }

        func next() -> Double {
            if offset + 4 > bytes.count { offset = 0 } // defensive; we derive enough
            let u = (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
            offset += 4
            // Map to (0,1): keep strictly positive so log() in Box-Muller is finite.
            return (Double(u) + 0.5) / 4_294_967_296.0
        }
    }

    private static func nextGaussian(_ stream: UniformStream) -> Double {
        let u1 = stream.next()
        let u2 = stream.next()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }

    // MARK: - Reflection derivation (cached per key+model)

    private struct CacheKey: Hashable {
        let keyHash: String
        let modelVersion: String
        let dim: Int
    }

    private static let cacheLock = NSLock()
    private static var reflectionCache: [CacheKey: [[Double]]] = [:]

    private static func deriveReflections(vaultKey: Data, modelVersion: String, dim: Int) -> [[Double]] {
        let keyHash = SHA256.hash(data: vaultKey).map { String(format: "%02x", $0) }.joined().prefix(32)
        let cacheKey = CacheKey(keyHash: String(keyHash), modelVersion: modelVersion, dim: dim)

        cacheLock.lock()
        if let cached = reflectionCache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let info = Data("OpenBurnBar-Pensieve-Cloak-\(modelVersion)-v1".utf8)
        // 2 uniforms per gaussian, 4 bytes per uniform, reflections * dim gaussians, + slack.
        let byteLen = cloakReflections * dim * 2 * 4 + 64
        let keystream = hkdfKeystream(input: vaultKey, salt: cloakSalt, info: info, length: byteLen)
        let uniform = UniformStream(keystream)

        var vectors: [[Double]] = []
        vectors.reserveCapacity(cloakReflections)
        for _ in 0..<cloakReflections {
            var v = [Double](repeating: 0, count: dim)
            var normSq = 0.0
            for i in 0..<dim {
                let g = nextGaussian(uniform)
                v[i] = g
                normSq += g * g
            }
            let norm = normSq.squareRoot()
            if norm == 0 {
                v[0] = 1 // degenerate guard; keeps Hᵢ orthogonal
            } else {
                for i in 0..<dim { v[i] /= norm }
            }
            vectors.append(v)
        }

        cacheLock.lock()
        reflectionCache[cacheKey] = vectors
        cacheLock.unlock()
        return vectors
    }

    /// Apply the per-user orthonormal cloak to a single embedding. Pass the same
    /// `modelVersion` at index time and query time. Returns a fresh vector; the
    /// input is not mutated.
    public static func cloak(
        _ vector: [Double],
        vaultKey: Data,
        modelVersion: String = embeddingModelVersion
    ) -> [Double] {
        let dim = vector.count
        let reflections = deriveReflections(vaultKey: vaultKey, modelVersion: modelVersion, dim: dim)
        var x = vector
        for v in reflections {
            var dot = 0.0
            for i in 0..<dim { dot += v[i] * x[i] }
            let c = 2.0 * dot
            for i in 0..<dim { x[i] -= c * v[i] }
        }
        return x
    }

    // MARK: - Vector helpers

    public static func l2normalize(_ vector: [Double]) -> [Double] {
        var normSq = 0.0
        for value in vector { normSq += value * value }
        let norm = normSq.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    // MARK: - Deterministic hashing embedder (offline parity)

    /// Deterministic, dependency-free embedder that mirrors
    /// `createDeterministicHashingEmbedder` in embed.ts EXACTLY (same token
    /// split, same SHA-256 bucket index/sign, same L2 normalize). This is the
    /// only embedder available without an ONNX runtime on Apple platforms, so it
    /// is the device embedder for app/daemon-originated knowledge. It is tagged
    /// `hashing-bow-v1` so its vectors never mix with real bge vectors.
    ///
    /// NOTE: this is bag-of-words, not semantic — it provides correct,
    /// reproducible recall for the encrypt/cloak/commit/search loop and exact
    /// term matches, which is the documented offline path. When a real bge
    /// runtime is wired in, switch `modelVersion` to `embeddingModelVersion`.
    public static func deterministicEmbed(_ text: String, isQuery: Bool = false) -> [Double] {
        let prefix = isQuery ? bgeQueryInstruction : ""
        let prepared = (prefix + text).lowercased()
        var acc = [Double](repeating: 0, count: embeddingDim)
        let tokens = prepared
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        for token in tokens {
            let digest = Array(SHA256.hash(data: Data(token.utf8)))
            let index = ((Int(digest[0]) << 8) | Int(digest[1])) % embeddingDim
            let sign: Double = (digest[2] & 1) == 0 ? 1 : -1
            acc[index] += sign
        }
        return l2normalize(acc)
    }

    /// Convenience: deterministic-embed then cloak in one call, returning the
    /// JSON-serialisable `[Double]` the commit/query callables accept.
    public static func embedAndCloak(
        _ text: String,
        vaultKey: Data,
        isQuery: Bool = false,
        modelVersion: String = deterministicModelVersion
    ) -> (modelVersion: String, vector: [Double]) {
        let raw = deterministicEmbed(text, isQuery: isQuery)
        return (modelVersion, cloak(raw, vaultKey: vaultKey, modelVersion: modelVersion))
    }

    #if DEBUG
    /// Test hook: clears the reflection cache so cross-key tests don't bleed.
    public static func resetReflectionCacheForTesting() {
        cacheLock.lock(); reflectionCache.removeAll(); cacheLock.unlock()
    }
    #endif
}

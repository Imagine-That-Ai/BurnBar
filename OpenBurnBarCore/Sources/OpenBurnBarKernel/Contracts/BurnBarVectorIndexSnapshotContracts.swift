import Foundation

/// Wave 2.1c-ii: the daemon owns `vector_index_snapshots` (ADR-005) and the
/// Mac app routes its HNSW snapshot-lifecycle writes through this contract
/// instead of `INSERT`ing into the table directly. Reads stay on the app's
/// local connection until the read cutover.
///
/// Lane semantics, read carefully — the table is shared by two lanes that
/// must never be conflated:
/// - The daemon lane is written by the daemon's own rebuild path
///   (`rebuildSnapshot`), which mints `daemon-`-namespaced storage paths and
///   stamps `createdAt`/`updatedAt` itself.
/// - The app lane carries rows the app already finalized: every field rides
///   the wire and the daemon stores it verbatim. In particular `state` and
///   `distanceMetric` are plain strings here, not enums, for two reasons.
///   First, the app and daemon spellings diverge today (`dot_product` on the
///   app side versus `dotProduct` in `BurnBarEmbeddingDistanceMetric`); the
///   daemon validates shape but must not reinterpret the value, or existing
///   app-written rows change meaning under the cutover. Second, an unknown
///   future state must fail validation loudly instead of crashing a failable
///   enum decode inside the RPC envelope.
///
/// Timestamps ride as ISO 8601 and the daemon persists them in GRDB's
/// `Date` text representation (`yyyy-MM-dd HH:mm:ss.SSS`, UTC) — the exact
/// format the app's pre-cutover GRDB writes used — so RPC-written rows are
/// byte-compatible with legacy rows in `ORDER BY` and `MAX()`.
public struct BurnBarVectorIndexSnapshotUpsertRequest: Codable, Equatable, Sendable {
    public let embeddingVersionID: String
    public let backendID: String
    public let state: String
    public let fingerprint: String
    public let dimensions: Int
    public let distanceMetric: String
    public let vectorCount: Int
    public let storageRelativePath: String?
    public let fileBytes: Int64
    public let backendVersion: String
    public let errorCode: String?
    public let errorMessage: String?
    public let createdAt: String
    public let updatedAt: String
    public let lastBuiltAt: String?

    public init(
        embeddingVersionID: String,
        backendID: String,
        state: String,
        fingerprint: String,
        dimensions: Int,
        distanceMetric: String,
        vectorCount: Int,
        storageRelativePath: String? = nil,
        fileBytes: Int64,
        backendVersion: String,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        createdAt: String,
        updatedAt: String,
        lastBuiltAt: String? = nil
    ) {
        self.embeddingVersionID = embeddingVersionID
        self.backendID = backendID
        self.state = state
        self.fingerprint = fingerprint
        self.dimensions = dimensions
        self.distanceMetric = distanceMetric
        self.vectorCount = vectorCount
        self.storageRelativePath = storageRelativePath
        self.fileBytes = fileBytes
        self.backendVersion = backendVersion
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastBuiltAt = lastBuiltAt
    }
}

public struct BurnBarVectorIndexSnapshotUpsertResponse: Codable, Equatable, Sendable {
    public let embeddingVersionID: String
    public let backendID: String
    public let updatedAt: String

    public init(embeddingVersionID: String, backendID: String, updatedAt: String) {
        self.embeddingVersionID = embeddingVersionID
        self.backendID = backendID
        self.updatedAt = updatedAt
    }
}

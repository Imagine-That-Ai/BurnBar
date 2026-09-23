import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// MARK: - Vector Index Snapshot App Lane (Wave 2.1c-ii)

/// The daemon-owned write path for the app lane of `vector_index_snapshots`
/// (ADR-005). The Mac app routes its HNSW snapshot-lifecycle writes
/// (building → ready/failed, plus the projection pipeline's stale marker)
/// through the `daemon.search.vector_snapshot.upsert` RPC instead of touching
/// the table directly.
///
/// Lane contract (do not blur it): the app finalizes every field before
/// sending. This lane validates shape and bounds, then stores the row
/// verbatim with the same `ON CONFLICT(embeddingVersionID, backendID)`
/// upsert the daemon's own rebuild path uses. It never reinterprets values —
/// notably `distanceMetric`, where the app spelling (`dot_product`) differs
/// from `BurnBarEmbeddingDistanceMetric` (`dotProduct`) by construction.
/// Timestamps ride as ISO 8601 and persist in GRDB's `Date` text
/// representation, exactly as the app's pre-cutover GRDB writes stored them.
extension BurnBarIndexedSearchService {
    /// Bounds for the app-lane snapshot fields. Identifiers stay tight (the
    /// chat lane's rules); `errorMessage` is generous on purpose because it
    /// carries `localizedDescription` text, which can span lines; the byte
    /// bound caps abuse without policing content.
    static let vectorSnapshotMaxVersionIDBytes = 256
    static let vectorSnapshotMaxBackendIDBytes = 128
    static let vectorSnapshotMaxFingerprintBytes = 512
    static let vectorSnapshotMaxMetricBytes = 64
    static let vectorSnapshotMaxPathBytes = 1024
    static let vectorSnapshotMaxBackendVersionBytes = 128
    static let vectorSnapshotMaxErrorCodeBytes = 256
    static let vectorSnapshotMaxErrorMessageBytes = 65_536
    static let vectorSnapshotMaxDimensions = 100_000
    static let vectorSnapshotMaxVectorCount = 1_000_000_000
    static let vectorSnapshotMaxFileBytes: Int64 = 1_099_511_627_776
    /// The only states the app's `VectorIndexSnapshotState` can produce. An
    /// unknown state is a foreign or corrupt row, never a quiet store.
    static let vectorSnapshotKnownStates: Set<String> = ["building", "ready", "stale", "failed"]

    func vectorSnapshotUpsertAppLane(
        _ request: BurnBarVectorIndexSnapshotUpsertRequest
    ) throws -> BurnBarVectorIndexSnapshotUpsertResponse {
        let versionID = try Self.validatedSnapshotIdentifier(
            request.embeddingVersionID,
            field: "embeddingVersionID",
            maxBytes: Self.vectorSnapshotMaxVersionIDBytes
        )
        let backendID = try Self.validatedSnapshotIdentifier(
            request.backendID,
            field: "backendID",
            maxBytes: Self.vectorSnapshotMaxBackendIDBytes
        )
        let state = try Self.validatedSnapshotState(request.state)
        let fingerprint = try Self.validatedSnapshotIdentifier(
            request.fingerprint,
            field: "fingerprint",
            maxBytes: Self.vectorSnapshotMaxFingerprintBytes
        )
        let distanceMetric = try Self.validatedSnapshotIdentifier(
            request.distanceMetric,
            field: "distanceMetric",
            maxBytes: Self.vectorSnapshotMaxMetricBytes
        )
        let dimensions = try Self.validatedSnapshotInt(
            request.dimensions,
            field: "dimensions",
            range: 1 ... Self.vectorSnapshotMaxDimensions
        )
        let vectorCount = try Self.validatedSnapshotInt(
            request.vectorCount,
            field: "vectorCount",
            range: 0 ... Self.vectorSnapshotMaxVectorCount
        )
        let storageRelativePath = try Self.validatedSnapshotPath(request.storageRelativePath)
        guard request.fileBytes >= 0, request.fileBytes <= Self.vectorSnapshotMaxFileBytes else {
            throw VectorSnapshotAppLaneError.invalidRequest(
                "fileBytes must be between 0 and \(Self.vectorSnapshotMaxFileBytes)"
            )
        }
        let backendVersion = try Self.validatedSnapshotIdentifier(
            request.backendVersion,
            field: "backendVersion",
            maxBytes: Self.vectorSnapshotMaxBackendVersionBytes
        )
        let errorCode = try Self.validatedSnapshotOptionalIdentifier(
            request.errorCode,
            field: "errorCode",
            maxBytes: Self.vectorSnapshotMaxErrorCodeBytes
        )
        let errorMessage = try Self.validatedSnapshotOptionalText(
            request.errorMessage,
            field: "errorMessage",
            maxBytes: Self.vectorSnapshotMaxErrorMessageBytes
        )
        let createdAt = try Self.validatedSnapshotTimestamp(request.createdAt, field: "createdAt")
        let updatedAt = try Self.validatedSnapshotTimestamp(request.updatedAt, field: "updatedAt")
        let lastBuiltAt = try Self.validatedSnapshotOptionalTimestamp(request.lastBuiltAt, field: "lastBuiltAt")
        // GRDB `Date` text, not ISO: byte-compatible with the rows the app
        // wrote directly before the cutover. Both lanes store TEXT, so no
        // storage-class split can scramble ordering.
        let storedCreatedAt = Self.sqliteTimestamp(createdAt)
        let storedUpdatedAt = Self.sqliteTimestamp(updatedAt)

        try databaseSync {
            let sql = """
                INSERT INTO vector_index_snapshots (
                    embeddingVersionID, backendID, state, fingerprint, dimensions, distanceMetric,
                    vectorCount, storageRelativePath, fileBytes, backendVersion, errorCode, errorMessage,
                    createdAt, updatedAt, lastBuiltAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(embeddingVersionID, backendID) DO UPDATE SET
                    state = excluded.state,
                    fingerprint = excluded.fingerprint,
                    dimensions = excluded.dimensions,
                    distanceMetric = excluded.distanceMetric,
                    vectorCount = excluded.vectorCount,
                    storageRelativePath = excluded.storageRelativePath,
                    fileBytes = excluded.fileBytes,
                    backendVersion = excluded.backendVersion,
                    errorCode = excluded.errorCode,
                    errorMessage = excluded.errorMessage,
                    updatedAt = excluded.updatedAt,
                    lastBuiltAt = excluded.lastBuiltAt
                """
            guard let stmt = try prepareStatement(sql: sql) else {
                throw sqliteError(db: db, code: sqlite3_errcode(db), context: "vector_snapshot_app_lane_upsert")
            }
            defer { sqlite3_finalize(stmt) }
            try bind([
                .text(versionID),
                .text(backendID),
                .text(state),
                .text(fingerprint),
                .int(Int64(dimensions)),
                .text(distanceMetric),
                .int(Int64(vectorCount)),
                storageRelativePath.map(SQLiteBindValue.text) ?? .null,
                .int(request.fileBytes),
                .text(backendVersion),
                errorCode.map(SQLiteBindValue.text) ?? .null,
                errorMessage.map(SQLiteBindValue.text) ?? .null,
                .text(storedCreatedAt),
                .text(storedUpdatedAt),
                lastBuiltAt.map { .text(Self.sqliteTimestamp($0)) } ?? .null
            ], to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db, code: sqlite3_errcode(db), context: "vector_snapshot_app_lane_upsert")
            }
        }
        return BurnBarVectorIndexSnapshotUpsertResponse(
            embeddingVersionID: versionID,
            backendID: backendID,
            updatedAt: ThreadSafeISO8601DateFormatter.formatFractional(updatedAt)
        )
    }

    // MARK: - Validation (app lane)

    private static func validatedSnapshotIdentifier(
        _ raw: String,
        field: String,
        maxBytes: Int
    ) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed == raw else {
            throw VectorSnapshotAppLaneError.invalidRequest("\(field) must be nonblank and trimmed")
        }
        guard raw.utf8.count <= maxBytes else {
            throw VectorSnapshotAppLaneError.invalidRequest("\(field) exceeds \(maxBytes) UTF-8 bytes")
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw VectorSnapshotAppLaneError.invalidRequest("\(field) contains control characters")
        }
        return raw
    }

    private static func validatedSnapshotOptionalIdentifier(
        _ raw: String?,
        field: String,
        maxBytes: Int
    ) throws -> String? {
        guard let raw else { return nil }
        return try validatedSnapshotIdentifier(raw, field: field, maxBytes: maxBytes)
    }

    /// Length-bounded free text. Unlike identifiers this allows control
    /// characters: `errorMessage` carries `localizedDescription` output, which
    /// can legitimately span lines. Newlines in a TEXT column are harmless;
    /// the daemon never logs or shells this value.
    private static func validatedSnapshotOptionalText(
        _ raw: String?,
        field: String,
        maxBytes: Int
    ) throws -> String? {
        guard let raw else { return nil }
        guard raw.utf8.count <= maxBytes else {
            throw VectorSnapshotAppLaneError.invalidRequest("\(field) exceeds \(maxBytes) UTF-8 bytes")
        }
        return raw
    }

    private static func validatedSnapshotState(_ raw: String) throws -> String {
        guard Self.vectorSnapshotKnownStates.contains(raw) else {
            throw VectorSnapshotAppLaneError.invalidRequest(
                "state must be one of \(Self.vectorSnapshotKnownStates.sorted().joined(separator: ", "))"
            )
        }
        return raw
    }

    /// Strict path validation: both the app and the daemon resolve this value
    /// against a storage root (`appendingPathComponent`), so `..` components
    /// or an absolute path would escape the snapshot directory on cleanup.
    /// The app only ever sends `parent/generation` segments; anything else is
    /// foreign.
    private static func validatedSnapshotPath(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed == raw else {
            throw VectorSnapshotAppLaneError.invalidRequest("storageRelativePath must be nonblank and trimmed")
        }
        guard raw.utf8.count <= vectorSnapshotMaxPathBytes else {
            throw VectorSnapshotAppLaneError.invalidRequest(
                "storageRelativePath exceeds \(vectorSnapshotMaxPathBytes) UTF-8 bytes"
            )
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw VectorSnapshotAppLaneError.invalidRequest("storageRelativePath contains control characters")
        }
        guard raw.hasPrefix("/") == false else {
            throw VectorSnapshotAppLaneError.invalidRequest("storageRelativePath must be relative, not absolute")
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard components.contains("..") == false, components.contains(".") == false else {
            throw VectorSnapshotAppLaneError.invalidRequest("storageRelativePath must not contain . or .. components")
        }
        return raw
    }

    private static func validatedSnapshotInt(_ raw: Int, field: String, range: ClosedRange<Int>) throws -> Int {
        guard range.contains(raw) else {
            throw VectorSnapshotAppLaneError.invalidRequest(
                "\(field) must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return raw
    }

    private static func validatedSnapshotTimestamp(_ raw: String, field: String) throws -> Date {
        guard let date = ThreadSafeISO8601DateFormatter.parse(raw) else {
            throw VectorSnapshotAppLaneError.invalidRequest("\(field) must be ISO 8601")
        }
        return try validatedSnapshotDateRange(date, field: field)
    }

    private static func validatedSnapshotOptionalTimestamp(_ raw: String?, field: String) throws -> Date? {
        guard let raw else { return nil }
        guard let date = ThreadSafeISO8601DateFormatter.parse(raw) else {
            throw VectorSnapshotAppLaneError.invalidRequest("\(field) must be ISO 8601")
        }
        return try validatedSnapshotDateRange(date, field: field)
    }

    private static func validatedSnapshotDateRange(_ date: Date, field: String) throws -> Date {
        let earliest = Date(timeIntervalSince1970: 946_684_800)
        let latest = Date(timeIntervalSince1970: 4_102_444_800)
        guard date >= earliest, date <= latest else {
            throw VectorSnapshotAppLaneError.invalidRequest("\(field) must be between 2000 and 2100")
        }
        return date
    }
}

extension BurnBarIndexedSearchService {
    /// Validation failures for the vector-snapshot app lane. The RPC handler
    /// maps these to `invalidParams` (the caller's fault); every other error
    /// from the lane is a daemon fault.
    enum VectorSnapshotAppLaneError: Error, LocalizedError {
        case invalidRequest(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest(let detail):
                return "Invalid vector index snapshot request: \(detail)"
            }
        }
    }
}

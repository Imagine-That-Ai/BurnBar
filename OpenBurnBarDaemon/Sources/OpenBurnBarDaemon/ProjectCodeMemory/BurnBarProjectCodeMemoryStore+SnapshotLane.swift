import Foundation
import OpenBurnBarEngine

// MARK: - Project Memory Snapshot App Lane (Wave 2.1c)

/// The daemon-owned write path for the app lane of `project_memory_snapshots`
/// (ADR-005). The Mac app routes its snapshot upsert/delete/wipe through the
/// `daemon.memory.snapshot.*` RPCs instead of touching the table directly.
///
/// Lane contract (do not blur it): the app finalizes every byte before
/// sending — `snapshotJSON` is the app's own `ProjectMemorySnapshot`
/// encoding and `contentHash` is the app's change-detection token over its
/// hash payload. This lane validates shape and bounds, then stores both
/// verbatim. It never recomputes the hash (the daemon lane's
/// full-JSON digest is a different value by construction) and never fills in
/// timestamps. Timestamps ride as ISO 8601 and persist in GRDB's `Date` text
/// representation, exactly as the app's pre-cutover GRDB writes stored them.
extension BurnBarProjectCodeMemoryStore {
    /// Bounds for the app-lane snapshot fields. The JSON bound is generous on
    /// purpose: assembled briefs carry pages of cited prose and can legitimately
    /// reach hundreds of kilobytes; the bound exists to cap abuse, not to police
    /// content. Everything else mirrors the tight identifier rules the chat
    /// lane uses.
    static let snapshotMaxSlugBytes = 256
    static let snapshotMaxDisplayNameBytes = 512
    static let snapshotMaxJSONBytes = 1_048_576
    static let snapshotMaxCountValue = 10_000_000
    static let snapshotKnownSchemaVersion = 1

    func snapshotUpsertAppLane(
        _ request: BurnBarProjectMemorySnapshotUpsertRequest
    ) throws -> BurnBarProjectMemorySnapshotUpsertResponse {
        let slug = try Self.validatedSnapshotSlug(request.projectSlug)
        let displayName = try Self.validatedSnapshotDisplayName(request.projectDisplayName)
        let snapshotJSON = try Self.validatedSnapshotJSON(request.snapshotJSON)
        let contentHash = try Self.validatedSnapshotContentHash(request.contentHash)
        let sessionCount = try Self.validatedSnapshotCount(request.sourceSessionCount, field: "sourceSessionCount")
        let conversationCount = try Self.validatedSnapshotCount(
            request.sourceConversationCount,
            field: "sourceConversationCount"
        )
        guard request.schemaVersion == Self.snapshotKnownSchemaVersion else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "schemaVersion \(request.schemaVersion) is not supported (expected \(Self.snapshotKnownSchemaVersion))"
            )
        }
        let generatedAt = try Self.validatedSnapshotTimestamp(request.generatedAt, field: "generatedAt")
        let updatedAt = try Self.validatedSnapshotTimestamp(request.updatedAt, field: "updatedAt")
        // GRDB `Date` text, not ISO: byte-compatible with the rows the app
        // wrote directly before the cutover, so `ORDER BY generatedAt` and the
        // `updatedAt` index keep working across the boundary. Both lanes store
        // TEXT, so no storage-class split can scramble ordering.
        let storedGeneratedAt = BurnBarChatThreadService.grdbStorageTimestamp(generatedAt)
        let storedUpdatedAt = BurnBarChatThreadService.grdbStorageTimestamp(updatedAt)

        return try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                try execute(
                    """
                    INSERT INTO project_memory_snapshots
                        (projectSlug, projectDisplayName, snapshotJSON, contentHash,
                         sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(projectSlug) DO UPDATE SET
                        projectDisplayName = excluded.projectDisplayName,
                        snapshotJSON = excluded.snapshotJSON,
                        contentHash = excluded.contentHash,
                        sourceSessionCount = excluded.sourceSessionCount,
                        sourceConversationCount = excluded.sourceConversationCount,
                        generatedAt = excluded.generatedAt,
                        schemaVersion = excluded.schemaVersion,
                        updatedAt = excluded.updatedAt
                    """,
                    [
                        .text(slug),
                        .text(displayName),
                        .text(snapshotJSON),
                        .text(contentHash),
                        .int(sessionCount),
                        .int(conversationCount),
                        .text(storedGeneratedAt),
                        .int(request.schemaVersion),
                        .text(storedUpdatedAt)
                    ]
                )
                try execute("COMMIT", [])
                return BurnBarProjectMemorySnapshotUpsertResponse(
                    projectSlug: slug,
                    updatedAt: ThreadSafeISO8601DateFormatter.formatFractional(updatedAt)
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func snapshotDeleteAppLane(
        _ request: BurnBarProjectMemorySnapshotDeleteRequest
    ) throws -> BurnBarProjectMemorySnapshotDeleteResponse {
        let slug = try Self.validatedSnapshotSlug(request.projectSlug)
        return try databaseSync {
            let existing = try fetchInt(
                "SELECT COUNT(1) FROM project_memory_snapshots WHERE projectSlug = ?",
                [.text(slug)]
            )
            guard existing > 0 else {
                return BurnBarProjectMemorySnapshotDeleteResponse(projectSlug: slug, deleted: false)
            }
            try execute("DELETE FROM project_memory_snapshots WHERE projectSlug = ?", [.text(slug)])
            return BurnBarProjectMemorySnapshotDeleteResponse(projectSlug: slug, deleted: true)
        }
    }

    func snapshotDeleteAllAppLane() throws -> BurnBarProjectMemorySnapshotDeleteAllResponse {
        try databaseSync {
            let count = try fetchInt("SELECT COUNT(1) FROM project_memory_snapshots", [])
            guard count > 0 else {
                return BurnBarProjectMemorySnapshotDeleteAllResponse(deletedCount: 0)
            }
            try execute("DELETE FROM project_memory_snapshots", [])
            return BurnBarProjectMemorySnapshotDeleteAllResponse(deletedCount: count)
        }
    }

    // MARK: - Validation (app lane)

    private static func validatedSnapshotSlug(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed == raw else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "projectSlug must be nonblank and trimmed"
            )
        }
        guard raw.utf8.count <= snapshotMaxSlugBytes else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "projectSlug exceeds \(snapshotMaxSlugBytes) UTF-8 bytes"
            )
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "projectSlug contains control characters"
            )
        }
        return raw
    }

    private static func validatedSnapshotDisplayName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "projectDisplayName must be nonblank"
            )
        }
        guard raw.utf8.count <= snapshotMaxDisplayNameBytes else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "projectDisplayName exceeds \(snapshotMaxDisplayNameBytes) UTF-8 bytes"
            )
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "projectDisplayName contains control characters"
            )
        }
        return raw
    }

    private static func validatedSnapshotJSON(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest("snapshotJSON must not be blank")
        }
        guard raw.utf8.count <= snapshotMaxJSONBytes else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "snapshotJSON exceeds \(snapshotMaxJSONBytes) UTF-8 bytes"
            )
        }
        guard let data = raw.data(using: .utf8) else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest("snapshotJSON must be valid JSON")
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest("snapshotJSON must be valid JSON")
        }
        return raw
    }

    private static func validatedSnapshotContentHash(_ raw: String) throws -> String {
        // The app produces lowercase hex via `%02x`; accept either case but
        // demand exactly 64 hex digits — anything else is a corrupt or
        // foreign token, never a quiet store.
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard raw.count == 64, raw.unicodeScalars.allSatisfy({ hex.contains($0) }) else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "contentHash must be 64 hexadecimal characters"
            )
        }
        return raw
    }

    private static func validatedSnapshotCount(_ raw: Int, field: String) throws -> Int {
        guard raw >= 0, raw <= snapshotMaxCountValue else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "\(field) must be between 0 and \(snapshotMaxCountValue)"
            )
        }
        return raw
    }

    private static func validatedSnapshotTimestamp(_ raw: String, field: String) throws -> Date {
        guard let date = ThreadSafeISO8601DateFormatter.parse(raw) else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest("\(field) must be ISO 8601")
        }
        let earliest = Date(timeIntervalSince1970: 946_684_800)
        let latest = Date(timeIntervalSince1970: 4_102_444_800)
        guard date >= earliest, date <= latest else {
            throw BurnBarProjectCodeMemoryStoreError.snapshotInvalidRequest(
                "\(field) must be between 2000 and 2100"
            )
        }
        return date
    }
}

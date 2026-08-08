import Foundation
@preconcurrency import GRDB
import OpenBurnBarKernel

// MARK: - AI Inbox item state, as the cloud mirror sees it

/// Reads and writes `ai_inbox_item_state` with its `updated_at` exposed.
///
/// The UI accessors in `ControlPlaneStore+AIInbox` deliberately hide the
/// timestamp — a view only needs to know whether an item is read or snoozed.
/// The cloud mirror needs it: `updated_at` is the sole conflict resolver when
/// the same item is archived on a phone and on the Mac, so it must survive the
/// round trip byte-for-byte rather than being restamped on arrival.
extension ControlPlaneStore {
    /// One row of user intent plus the timestamp that orders it against a
    /// remote write of the same item.
    struct AIInboxItemStateRow: Sendable, Hashable, Identifiable {
        let id: String
        let readAt: Date?
        let archivedAt: Date?
        let snoozedUntil: Date?
        let feedback: String?
        let updatedAt: Date
    }

    /// Keyset-paged: `afterItemID` resumes strictly after the given primary
    /// key. The cloud mirror pages through the WHOLE table with this cursor;
    /// a bare `LIMIT` would silently drop every row past the page size, and
    /// those rows would never sync, because the per-id watermark (unlike the
    /// download's timestamp watermark) cannot queue what it never saw. `item_id`
    /// is the cursor rather than `updated_at` because it is unique, so a page
    /// boundary cannot fall inside a run of equal timestamps and skip the rest
    /// of the tie.
    func fetchAIInboxItemStates(limit: Int = 500, afterItemID: String? = nil) async throws -> [AIInboxItemStateRow] {
        try await dbQueue.read { db in
            guard try db.tableExists("ai_inbox_item_state") else { return [] }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT item_id, read_at, archived_at, snoozed_until, feedback, updated_at
                    FROM ai_inbox_item_state
                    WHERE (:after IS NULL OR item_id > :after)
                    ORDER BY item_id ASC
                    LIMIT :limit
                    """,
                arguments: ["after": afterItemID, "limit": max(1, limit)]
            ).compactMap { row in
                // A row whose `updated_at` will not parse cannot be ordered
                // against a remote write, so it is skipped rather than mirrored
                // with a fabricated timestamp that could win a conflict it
                // should have lost.
                guard let updatedAt = Self.aiInboxDate(row["updated_at"]) else { return nil }
                return AIInboxItemStateRow(
                    id: row["item_id"] ?? "",
                    readAt: Self.aiInboxDate(row["read_at"]),
                    archivedAt: Self.aiInboxDate(row["archived_at"]),
                    snoozedUntil: Self.aiInboxDate(row["snoozed_until"]),
                    feedback: row["feedback"],
                    updatedAt: updatedAt
                )
            }
        }
    }

    /// Applies a phone-written state row, keeping the remote `updatedAt` as the
    /// local one.
    ///
    /// Preserving the timestamp is what stops the two sides from ping-ponging:
    /// restamping to `now` would make the freshly-applied row look locally newer
    /// than the cloud copy, and the next sync would push it straight back.
    ///
    /// Returns `false` when the local row is newer, so the caller can upload it
    /// instead. The comparison and the write share one transaction — a UI action
    /// landing mid-sync must not be silently overwritten by a stale download.
    @discardableResult
    func applyRemoteAIInboxItemState(_ state: AIInboxMirrorItemState) async throws -> Bool {
        try await dbQueue.write { db in
            guard try db.tableExists("ai_inbox_item_state") else { return false }
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT updated_at FROM ai_inbox_item_state WHERE item_id = ?",
                arguments: [state.id]
            )
            if let existing, let localUpdatedAt = Self.aiInboxDate(existing["updated_at"]),
               localUpdatedAt >= state.updatedAt {
                return false
            }

            try db.execute(
                sql: """
                    INSERT INTO ai_inbox_item_state (item_id, read_at, archived_at, snoozed_until, feedback, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(item_id) DO UPDATE SET
                        read_at = excluded.read_at,
                        archived_at = excluded.archived_at,
                        snoozed_until = excluded.snoozed_until,
                        feedback = excluded.feedback,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    state.id,
                    state.readAt.map(Self.aiInboxTimestamp),
                    state.archivedAt.map(Self.aiInboxTimestamp),
                    state.snoozedUntil.map(Self.aiInboxTimestamp),
                    state.feedback,
                    Self.aiInboxTimestamp(state.updatedAt)
                ]
            )
            return true
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportStoreReader — the only file in this target that knows GRDB exists.
//
// Everything it produces is a `MemoryExportSourceSnapshot` of plain values, so
// the classifier, the chain walk and the body resolver never touch a database
// and their tests never open one.
//
// Every read is a READ. The exporter opens the store, takes what it needs and
// writes the bundle elsewhere; it never writes to the source and never mints a
// key. A missing key on an existing encrypted file is `EXPORT_KEY_UNAVAILABLE`,
// never a re-key — which is a decision the CALLER makes when it opens the
// queue, and this file inherits by only ever receiving an already-open one.

import Foundation
@preconcurrency import GRDB

public enum MemoryExportStoreReader {

    /// Read every table the export needs, in one read transaction.
    ///
    /// Column presence is probed rather than assumed: a daemon-only or
    /// Python-created file has no `review_status` and no `source_kind`, and
    /// that absence is §3.1 row 13, not an error.
    public static func read(_ db: Database) throws -> MemoryExportSourceSnapshot {
        var snapshot = MemoryExportSourceSnapshot()
        snapshot.sourceQuickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "ok"

        let memoryColumns = try columnNames(db, table: "agent_memories")
        guard memoryColumns.isEmpty == false else { return snapshot }
        snapshot.memories = try memories(db, columns: memoryColumns)

        if try tableExists(db, "memory_audit") {
            snapshot.auditRows = try auditRows(db)
            snapshot.auditHeadSeq = snapshot.auditRows.map(\.seq).max() ?? 0
            snapshot.auditHeadHash = snapshot.auditRows.max { $0.seq < $1.seq }?.hash
        } else {
            // Row 16 — undecidable, so everything quarantines.
            snapshot.auditTableAvailable = false
        }

        if try tableExists(db, "memory_body_snapshots") {
            snapshot.bodySnapshots = try Row
                .fetchAll(db, sql: """
                    SELECT id, memory_id, body_ref, snapshot_json, body_hash, source_kind, created_at, updated_at
                    FROM memory_body_snapshots
                    """)
                .map { row in
                    MemoryExportBodySnapshotRow(
                        id: row["id"] ?? "",
                        memoryID: row["memory_id"] ?? "",
                        bodyRef: row["body_ref"] ?? "",
                        snapshotJSON: row["snapshot_json"] ?? "{}",
                        bodyHash: row["body_hash"] ?? "",
                        sourceKind: row["source_kind"] ?? "chat",
                        createdAt: row["created_at"] ?? "",
                        updatedAt: row["updated_at"] ?? ""
                    )
                }
        }

        if try tableExists(db, "project_memory_snapshots") {
            for row in try Row.fetchAll(db, sql: "SELECT projectSlug, snapshotJSON FROM project_memory_snapshots") {
                guard let slug: String = row["projectSlug"] else { continue }
                snapshot.projectSnapshots[slug] = row["snapshotJSON"] ?? "{}"
            }
        }

        if try tableExists(db, "memory_quarantine_bodies") {
            for row in try Row.fetchAll(db, sql: "SELECT memory_id, body FROM memory_quarantine_bodies") {
                guard let id: String = row["memory_id"] else { continue }
                snapshot.quarantineBodies[id] = row["body"] ?? ""
            }
        }

        if try tableExists(db, "memory_provenance") {
            snapshot.provenance = try Row
                .fetchAll(db, sql: """
                    SELECT id, memory_id, source_kind, thread_logical_id, message_id, role,
                           authored_at, content_hash, occurrence, citation_state, created_at
                    FROM memory_provenance
                    """)
                .map { row in
                    MemoryExportProvenanceRow(
                        id: row["id"] ?? "",
                        memoryID: row["memory_id"] ?? "",
                        sourceKind: row["source_kind"] ?? "chat_message",
                        threadLogicalID: row["thread_logical_id"] ?? "",
                        messageID: row["message_id"],
                        role: row["role"] ?? "human",
                        authoredAt: row["authored_at"] ?? "",
                        contentHash: row["content_hash"] ?? "",
                        occurrence: row["occurrence"] ?? 0,
                        citationState: row["citation_state"] ?? "live",
                        createdAt: row["created_at"] ?? ""
                    )
                }
        }

        if try tableExists(db, "memory_fact_tombstones") {
            snapshot.factTombstones = try Row
                .fetchAll(db, sql: """
                    SELECT id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at
                    FROM memory_fact_tombstones
                    """)
                .map { row in
                    MemoryExportFactTombstoneRow(
                        id: row["id"] ?? "",
                        userID: row["user_id"] ?? "",
                        memoryID: row["memory_id"] ?? "",
                        sourceRefsJSON: row["source_refs_json"] ?? "[]",
                        reason: row["reason"] ?? "user_forget",
                        createdAt: row["created_at"] ?? "",
                        replicatedAt: row["replicated_at"]
                    )
                }
        }

        if try tableExists(db, "memory_source_tombstones") {
            snapshot.sourceTombstones = try Row
                .fetchAll(db, sql: """
                    SELECT id, user_id, thread_logical_id, message_id, content_hash, reason,
                           created_at, replicated_at
                    FROM memory_source_tombstones
                    """)
                .map { row in
                    MemoryExportSourceTombstoneRow(
                        id: row["id"] ?? "",
                        userID: row["user_id"],
                        threadLogicalID: row["thread_logical_id"] ?? "",
                        messageID: row["message_id"],
                        contentHash: row["content_hash"],
                        reason: row["reason"] ?? "source_deleted",
                        createdAt: row["created_at"] ?? "",
                        replicatedAt: row["replicated_at"]
                    )
                }
        }

        if try tableExists(db, "pcm_projects") {
            let aliasCounts = try tableExists(db, "pcm_project_aliases")
                ? try aliasCountsByProject(db)
                : [:]
            snapshot.projects = try Row
                .fetchAll(db, sql: """
                    SELECT project_id, identity_version, identity_fingerprint, project_name,
                           primary_path, created_at, updated_at
                    FROM pcm_projects
                    """)
                .map { row in
                    let id: String = row["project_id"] ?? ""
                    return MemoryExportProjectRow(
                        projectID: id,
                        identityVersion: row["identity_version"] ?? 1,
                        identityFingerprint: row["identity_fingerprint"] ?? "",
                        projectName: row["project_name"] ?? "",
                        primaryPath: row["primary_path"] ?? "",
                        createdAt: row["created_at"] ?? "",
                        updatedAt: row["updated_at"] ?? "",
                        pathAliasCount: aliasCounts[id] ?? 0
                    )
                }
        }

        if try tableExists(db, "memory_embedding_refs") {
            snapshot.embeddingLanes = try Row
                .fetchAll(db, sql: """
                    SELECT embedding_version_id, MAX(dimension) AS dim, COUNT(*) AS rows
                    FROM memory_embedding_refs
                    GROUP BY embedding_version_id
                    """)
                .map { row in
                    MemoryExportEmbeddingLane(
                        versionID: row["embedding_version_id"] ?? "",
                        dimension: row["dim"] ?? 1,
                        rowCount: row["rows"] ?? 0
                    )
                }
        }
        return snapshot
    }

    /// §5, P5 step 1/2: the head, read before and after the final delta. An
    /// observation of the shared file rather than an assertion about a process,
    /// which is what lets the LaunchAgent stay up.
    public static func auditHead(_ db: Database) throws -> (seq: Int, hash: String?) {
        guard try tableExists(db, "memory_audit") else { return (0, nil) }
        guard let row = try Row.fetchOne(db, sql: "SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1") else {
            return (0, nil)
        }
        return (row["seq"] ?? 0, row["hash"])
    }

    /// The live memory id set, for P5's id-set diff.
    public static func liveMemoryIDs(_ db: Database) throws -> Set<String> {
        guard try tableExists(db, "agent_memories") else { return [] }
        let columns = try columnNames(db, table: "agent_memories")
        let sql = columns.contains("review_status")
            ? "SELECT id FROM agent_memories WHERE review_status <> 'forgotten'"
            : "SELECT id FROM agent_memories"
        return Set(try String.fetchAll(db, sql: sql))
    }

    // MARK: - Probes

    public static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [name]
        ) ?? 0 > 0
    }

    static func columnNames(_ db: Database, table: String) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").compactMap { $0["name"] as String? })
    }

    // MARK: - Row builders

    private static func memories(_ db: Database, columns: Set<String>) throws -> [MemoryExportMemoryRow] {
        try Row.fetchAll(db, sql: "SELECT * FROM agent_memories").map { row in
            MemoryExportMemoryRow(
                id: row["id"] ?? "",
                projectID: row["project_id"] ?? "",
                kind: row["kind"] ?? "other",
                scope: row["scope"] ?? "",
                confidence: row["confidence"] ?? 0,
                bodyRef: row["body_ref"] ?? "",
                bodyRedacted: row["body_redacted"] ?? "",
                tagsJSON: row["tags_json"] ?? "[]",
                sourcePath: row["source_path"],
                validFrom: row["valid_from"] ?? "",
                validTo: row["valid_to"],
                supersededBy: row["superseded_by"],
                createdAt: row["created_at"] ?? "",
                updatedAt: row["updated_at"] ?? "",
                // An ABSENT column is nil; a present-but-null one is nil too,
                // and both mean the same thing to the classifier.
                sourceKind: columns.contains("source_kind") ? row["source_kind"] : nil,
                reviewStatus: columns.contains("review_status") ? row["review_status"] : nil,
                userID: columns.contains("user_id") ? row["user_id"] : nil,
                agentID: columns.contains("agent_id") ? row["agent_id"] : nil,
                runID: columns.contains("run_id") ? row["run_id"] : nil,
                appID: columns.contains("app_id") ? row["app_id"] : nil
            )
        }
    }

    private static func auditRows(_ db: Database) throws -> [MemoryExportAuditRow] {
        try Row
            .fetchAll(db, sql: """
                SELECT seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash
                FROM memory_audit
                ORDER BY seq
                """)
            .map { row in
                MemoryExportAuditRow(
                    seq: row["seq"] ?? 0,
                    ts: row["ts"] ?? "",
                    actor: row["actor"] ?? "",
                    action: row["action"] ?? "",
                    domain: row["domain"] ?? "memory",
                    projectID: row["project_id"],
                    subjectID: row["subject_id"],
                    labels: decodeLabels(row["labels_json"] ?? "[]"),
                    prevHash: row["prev_hash"],
                    hash: row["hash"] ?? ""
                )
            }
    }

    private static func aliasCountsByProject(_ db: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT project_id, COUNT(*) AS n FROM pcm_project_aliases GROUP BY project_id"
        ) {
            guard let id: String = row["project_id"] else { continue }
            counts[id] = row["n"] ?? 0
        }
        return counts
    }

    static func decodeLabels(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return decoded
    }
}

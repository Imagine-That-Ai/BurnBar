// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportFixtureStore — synthetic stores, built by BurnBar's OWN migrator.
//
// Two rules this file exists to hold:
//
//   * The schema under test is `OpenBurnBarDatabase.migrator`, not a hand-typed
//     CREATE TABLE. A fixture that invents its own shape tests the fixture.
//   * **Nothing here ever opens the real store.** Every database is
//     `:memory:`, every body is invented, and no path under `~/Library` is read.
//
// Audit rows are written through the same hash-chain expression
// `ControlPlaneStore.insertMemoryAuditEvent` uses, so a fixture chain verifies
// for the same reason a production one does — and `breakChain` can then corrupt
// exactly one link and prove the walk notices.

import Foundation
import GRDB
// `OpenBurnBarDatabase` is internal to OpenBurnBarData, and the point of this
// file is to run the REAL migrator rather than a copy of its DDL.
@testable import OpenBurnBarData
@testable import OpenBurnBarMemoryExport

enum MemoryExportFixtureStore {

    static func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue)
        return queue
    }

    // MARK: - Writers

    /// One `agent_memories` row plus its `memory_body_snapshots` body, exactly
    /// as the app's authority write path lays them out.
    // swiftlint:disable:next function_parameter_count function_default_parameter_at_end
    static func insertAppMemory(
        _ db: Database,
        id: String,
        body: String,
        reviewStatus: String = "quarantined",
        sourceKind: String = "chat",
        userID: String? = "user-1",
        appID: String? = "app-1",
        projectID: String = "chat:user-1",
        createdAt: String = "2026-01-01T00:00:00.000Z",
        updatedAt: String = "2026-01-01T00:00:00.000Z",
        bodyUpdatedAt: String? = nil,
        bodyRefOverride: String? = nil,
        bodyHashOverride: String? = nil,
        writeBodySnapshot: Bool = true
    ) throws {
        let slug = "memory-\(id)"
        let bodyRef = bodyRefOverride ?? "memory_body_snapshots:\(slug)"
        let bodyHash = bodyHashOverride ?? MemoryExportDigest.sha256Hex(body)
        if writeBodySnapshot {
            let snapshotJSON = """
            {"schemaVersion":1,"memoryID":"\(id)","sourceKind":"\(sourceKind)",\
            "bodyHash":"\(bodyHash)","body":\(jsonString(body)),"citations":[],\
            "createdAt":"\(createdAt)"}
            """
            try db.execute(
                sql: """
                INSERT INTO memory_body_snapshots
                    (id, memory_id, body_ref, snapshot_json, body_hash, source_kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [slug, id, bodyRef, snapshotJSON, bodyHash, sourceKind, createdAt, bodyUpdatedAt ?? createdAt]
            )
        }
        try insertMemoryRow(
            db,
            id: id,
            projectID: projectID,
            bodyRef: bodyRef,
            bodyRedacted: bodyRef,
            sourceKind: sourceKind,
            reviewStatus: reviewStatus,
            userID: userID,
            appID: appID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// One daemon `code` row: a bare `sha256(body)` ref, the locator in
    /// `body_redacted`, and the body inside the project snapshot.
    // swiftlint:disable:next function_default_parameter_at_end
    static func insertDaemonMemory(
        _ db: Database,
        id: String,
        body: String,
        projectID: String,
        reviewStatus: String = "approved",
        quarantineBodyInstead: Bool = false,
        createdAt: String = "2026-01-01T00:00:00.000Z"
    ) throws {
        let bodyRef = MemoryExportDigest.sha256Hex(body)
        let slug = "agent-\(projectID)"
        if quarantineBodyInstead {
            try db.execute(
                sql: """
                INSERT INTO memory_quarantine_bodies (memory_id, project_id, body, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [id, projectID, body, createdAt, createdAt]
            )
        } else {
            let snapshotJSON = """
            {"projectSlug":"\(slug)","projectDisplayName":"\(projectID)","schemaVersion":1,\
            "pages":[{"id":"agent-notes","title":"Agent Notes","sections":\
            [{"id":"\(id)","title":"Fact","body":\(jsonString(body)),"citations":[]}]}]}
            """
            try db.execute(
                sql: """
                INSERT INTO project_memory_snapshots
                    (projectSlug, projectDisplayName, snapshotJSON, contentHash, sourceSessionCount,
                     sourceConversationCount, generatedAt, schemaVersion, updatedAt)
                VALUES (?, ?, ?, ?, 0, 0, ?, 1, ?)
                ON CONFLICT(projectSlug) DO UPDATE SET snapshotJSON = excluded.snapshotJSON
                """,
                arguments: [slug, projectID, snapshotJSON, "hash", createdAt, createdAt]
            )
        }
        try insertMemoryRow(
            db,
            id: id,
            projectID: projectID,
            bodyRef: bodyRef,
            bodyRedacted: quarantineBodyInstead
                ? "Quarantine body ref:\(slug)#\(id)"
                : "Project Memory snapshot ref:\(slug)#\(id)",
            sourceKind: "code",
            reviewStatus: reviewStatus,
            userID: nil,
            appID: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func insertMemoryRow(
        _ db: Database,
        id: String,
        projectID: String,
        bodyRef: String,
        bodyRedacted: String,
        sourceKind: String,
        reviewStatus: String,
        userID: String?,
        appID: String?,
        createdAt: String,
        updatedAt: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO agent_memories
                (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json, source_path,
                 valid_from, valid_to, superseded_by, created_at, updated_at,
                 source_kind, review_status, user_id, agent_id, run_id, app_id)
            VALUES (?, ?, 'fact', ?, 0.75, ?, ?, '["fixture"]', NULL, ?, NULL, NULL, ?, ?, ?, ?, ?, NULL, NULL, ?)
            """,
            arguments: [
                id, projectID, sourceKind, bodyRef, bodyRedacted,
                createdAt, createdAt, updatedAt, sourceKind, reviewStatus, userID, appID
            ]
        )
    }

    /// Append an audit row with a correctly chained hash — the same payload the
    /// app hashes, so the fixture chain verifies for the production reason.
    @discardableResult
    // swiftlint:disable:next function_default_parameter_at_end
    static func appendAudit(
        _ db: Database,
        action: String,
        actor: String = "app",
        projectID: String?,
        subjectID: String?,
        labels: [String],
        ts: String
    ) throws -> Int {
        let previous = try Row.fetchOne(db, sql: "SELECT seq, hash FROM memory_audit ORDER BY seq DESC LIMIT 1")
        let previousSeq: Int = previous?["seq"] ?? 0
        let prevHash: String? = previous?["hash"]
        let row = MemoryExportAuditRow(
            seq: previousSeq + 1,
            ts: ts,
            actor: actor,
            action: action,
            projectID: projectID,
            subjectID: subjectID,
            labels: labels,
            prevHash: prevHash
        )
        let hash = MemoryExportAuditChain.payloadHash(row: row, payloadSeq: previousSeq + 1, prevHash: prevHash)
        let labelsJSON = String(
            data: try JSONSerialization.data(withJSONObject: labels.sorted(), options: [.sortedKeys]),
            encoding: .utf8
        ) ?? "[]"
        try db.execute(
            sql: """
            INSERT INTO memory_audit (ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash)
            VALUES (?, ?, ?, 'memory', ?, ?, ?, ?, ?)
            """,
            arguments: [ts, actor, action, projectID, subjectID, labelsJSON, prevHash, hash]
        )
        return previousSeq + 1
    }

    /// Corrupt exactly one link so the walk has something real to find.
    static func breakChain(_ db: Database, atSeq seq: Int) throws {
        try db.execute(
            sql: "UPDATE memory_audit SET hash = ? WHERE seq = ?",
            arguments: [String(repeating: "f", count: 64), seq]
        )
    }

    // MARK: - Reading back

    static func snapshot(_ queue: DatabaseQueue) throws -> MemoryExportSourceSnapshot {
        try queue.read { try MemoryExportStoreReader.read($0) }
    }

    static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        guard let data, let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }
}

/// A gate that never fires, for tests whose subject is not the gate. Tests that
/// ARE about the gate use `MemoryExportGateRunner.shared` and the real corpus.
extension MemoryExportGateRunner {
    static let alwaysAllow = MemoryExportGateRunner(isAvailable: { true }, evaluate: { _ in .allow })
    static let unavailable = MemoryExportGateRunner(
        isAvailable: { false },
        evaluate: { _ in .reject(findings: []) }
    )
}

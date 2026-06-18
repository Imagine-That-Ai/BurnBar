import Foundation
import OpenBurnBarCore

extension BurnBarProjectCodeMemoryStore {
    func migrateLegacyPlaintextAgentMemories() throws {
        let rows = try queryRows(
            """
            SELECT id, project_id, kind, scope, body_redacted, tags_json, source_path, updated_at
            FROM agent_memories
            WHERE body_redacted NOT LIKE 'Project Memory snapshot ref:%'
            """,
            []
        )
        for row in rows {
            let memoryID = row.string(0)
            let projectID = row.string(1)
            let body = row.string(4)
            let tags = decodeStringArray(row.string(5))
            let now = row.optionalString(7) ?? Self.isoNow()
            try upsertProjectMemorySection(
                projectID: projectID,
                projectDisplayName: projectID,
                memoryID: memoryID,
                body: body,
                kind: row.string(2),
                scope: row.string(3),
                tags: tags,
                sourcePath: row.optionalString(6),
                now: now
            )
            try execute(
                "UPDATE agent_memories SET body_redacted = ?, updated_at = ? WHERE id = ?",
                [.text(Self.memoryBodyReference(memoryID: memoryID, projectID: projectID)), .text(now), .text(memoryID)]
            )
        }
    }

    func upsertProjectMemorySection(
        projectID: String,
        projectDisplayName: String,
        memoryID: String,
        body: String,
        kind: String,
        scope: String,
        tags: [String],
        sourcePath: String?,
        now: String
    ) throws {
        var snapshot = try loadProjectMemorySnapshot(projectID: projectID, projectDisplayName: projectDisplayName, now: now)
        var pages = snapshot["pages"] as? [[String: Any]] ?? []
        let section: [String: Any] = [
            "id": memoryID,
            "title": Self.memorySectionTitle(kind: kind, scope: scope, tags: tags),
            "body": body,
            "citations": Self.memoryCitations(memoryID: memoryID, sourcePath: sourcePath, now: now)
        ]

        if let index = pages.firstIndex(where: { ($0["id"] as? String) == Self.agentMemoryPageID }) {
            var page = pages[index]
            var sections = page["sections"] as? [[String: Any]] ?? []
            sections.removeAll { ($0["id"] as? String) == memoryID }
            sections.append(section)
            sections.sort { (($0["id"] as? String) ?? "") < (($1["id"] as? String) ?? "") }
            page["sections"] = sections
            page["summary"] = "\(sections.count) agent-maintained notes with provenance metadata."
            pages[index] = page
        } else {
            pages.append(Self.agentMemoryPage(sections: [section]))
        }

        snapshot["pages"] = pages
        if let sourcePath, sourcePath.isEmpty == false {
            var keyFiles = snapshot["keyFiles"] as? [String] ?? []
            if keyFiles.contains(sourcePath) == false {
                keyFiles.append(sourcePath)
            }
            snapshot["keyFiles"] = Array(keyFiles.prefix(24))
        }
        try writeProjectMemorySnapshot(snapshot, projectID: projectID, projectDisplayName: projectDisplayName, now: now)
    }

    func removeProjectMemorySection(projectID: String, projectDisplayName: String, memoryID: String, now: String) throws {
        var snapshot = try loadProjectMemorySnapshot(projectID: projectID, projectDisplayName: projectDisplayName, now: now)
        var pages = snapshot["pages"] as? [[String: Any]] ?? []
        guard let index = pages.firstIndex(where: { ($0["id"] as? String) == Self.agentMemoryPageID }) else {
            return
        }
        var page = pages[index]
        var sections = page["sections"] as? [[String: Any]] ?? []
        sections.removeAll { ($0["id"] as? String) == memoryID }
        page["sections"] = sections
        page["summary"] = "\(sections.count) agent-maintained notes with provenance metadata."
        pages[index] = page
        snapshot["pages"] = pages
        try writeProjectMemorySnapshot(snapshot, projectID: projectID, projectDisplayName: projectDisplayName, now: now)
    }

    func projectMemorySectionBody(projectID: String, memoryID: String) throws -> String? {
        guard let snapshot = try loadExistingProjectMemorySnapshot(projectID: projectID),
              let pages = snapshot["pages"] as? [[String: Any]] else {
            return nil
        }
        for page in pages {
            guard let sections = page["sections"] as? [[String: Any]] else { continue }
            if let section = sections.first(where: { ($0["id"] as? String) == memoryID }) {
                return section["body"] as? String
            }
        }
        return nil
    }

    func loadProjectMemorySnapshot(projectID: String, projectDisplayName: String, now: String) throws -> [String: Any] {
        if let existing = try loadExistingProjectMemorySnapshot(projectID: projectID) {
            return existing
        }
        return Self.baseProjectMemorySnapshot(projectID: projectID, projectDisplayName: projectDisplayName, now: now)
    }

    func loadExistingProjectMemorySnapshot(projectID: String) throws -> [String: Any]? {
        let slug = Self.projectMemorySlug(for: projectID)
        guard let json = try queryRows(
            "SELECT snapshotJSON FROM project_memory_snapshots WHERE projectSlug = ? LIMIT 1",
            [.text(slug)]
        ).first?.optionalString(0), let data = json.data(using: .utf8) else {
            return nil
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func writeProjectMemorySnapshot(
        _ snapshot: [String: Any],
        projectID: String,
        projectDisplayName: String,
        now: String
    ) throws {
        var updated = snapshot
        updated["projectSlug"] = Self.projectMemorySlug(for: projectID)
        updated["projectDisplayName"] = (snapshot["projectDisplayName"] as? String)?.nonEmpty ?? projectDisplayName
        updated["schemaVersion"] = 1
        updated["updatedAt"] = now
        if updated["generatedAt"] == nil {
            updated["generatedAt"] = now
        }
        var hashPayload = updated
        hashPayload["contentHash"] = ""
        let contentHash = Self.sha256Hex(try Self.jsonData(hashPayload))
        updated["contentHash"] = contentHash
        let snapshotJSON = String(data: try Self.jsonData(updated), encoding: .utf8) ?? "{}"
        let sourceSessionCount = (updated["sourceSessionIDs"] as? [Any])?.count ?? 0
        let sourceConversationCount = (updated["sourceConversationIDs"] as? [Any])?.count ?? 0
        try execute(
            """
            INSERT INTO project_memory_snapshots
                (projectSlug, projectDisplayName, snapshotJSON, contentHash, sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt)
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
                .text(Self.projectMemorySlug(for: projectID)),
                .text((updated["projectDisplayName"] as? String) ?? projectDisplayName),
                .text(snapshotJSON),
                .text(contentHash),
                .int(sourceSessionCount),
                .int(sourceConversationCount),
                .text((updated["generatedAt"] as? String) ?? now),
                .int(1),
                .text(now)
            ]
        )
    }

    static func baseProjectMemorySnapshot(projectID: String, projectDisplayName: String, now: String) -> [String: Any] {
        [
            "projectSlug": projectMemorySlug(for: projectID),
            "projectDisplayName": projectDisplayName,
            "generatedAt": now,
            "sourceSessionIDs": [],
            "sourceConversationIDs": [],
            "sourceWindowStart": NSNull(),
            "sourceWindowEnd": NSNull(),
            "keyFiles": [],
            "keyCommands": [],
            "usageSummary": "Agent-maintained project memory notes.",
            "freshness": "fresh",
            "contentHash": "",
            "schemaVersion": 1,
            "pages": [agentMemoryPage(sections: [])],
            "visuals": []
        ]
    }

    static func agentMemoryPage(sections: [[String: Any]]) -> [String: Any] {
        [
            "id": agentMemoryPageID,
            "title": "Agent Notes",
            "summary": "\(sections.count) agent-maintained notes with provenance metadata.",
            "sections": sections,
            "visualIDs": []
        ]
    }

    static func memoryCitations(memoryID: String, sourcePath: String?, now: String) -> [[String: Any]] {
        guard let sourcePath, sourcePath.isEmpty == false else { return [] }
        return [[
            "id": "cite_" + String(sha256Hex("\(memoryID):\(sourcePath)").prefix(16)),
            "sourceID": sourcePath,
            "sourceKind": codeSourceKind,
            "title": sourcePath,
            "snippet": "Agent-supplied source path for this memory.",
            "createdAt": now
        ]]
    }

    static func memorySectionTitle(kind: String, scope: String, tags: [String]) -> String {
        let base = "\(kind.capitalized) / \(scope)"
        guard let firstTag = tags.first(where: { $0.isEmpty == false }) else { return base }
        return "\(base) / \(firstTag)"
    }

    static func projectMemorySlug(for projectID: String) -> String {
        "agent-\(projectID)"
    }

    static func memoryBodyReference(memoryID: String, projectID: String) -> String {
        "Project Memory snapshot ref:\(projectMemorySlug(for: projectID))#\(memoryID)"
    }

    static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

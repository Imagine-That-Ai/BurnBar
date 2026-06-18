import Foundation

extension BurnBarProjectCodeMemoryStore {
    func resolveProjectIdentity(root: URL) throws -> ProjectIdentity {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalRoot.path
        let pathHash = Self.sha256Hex(canonicalPath)
        let legacyProjectID = Self.legacyProjectID(for: canonicalRoot)
        let fingerprint = Self.projectIdentityFingerprint(root: canonicalRoot)
        let preferredProjectID = Self.projectID(forFingerprint: fingerprint, fallbackProjectID: legacyProjectID)
        let now = Self.isoNow()

        return try databaseSync {
            let existingForFingerprint = try queryRows(
                "SELECT project_id FROM pcm_projects WHERE identity_fingerprint = ? LIMIT 1",
                [.text(fingerprint)]
            ).first?.string(0)
            let existingForAlias = try queryRows(
                "SELECT project_id FROM pcm_project_aliases WHERE path_hash = ? LIMIT 1",
                [.text(pathHash)]
            ).first?.string(0)
            let projectID: String
            if let existingForFingerprint {
                projectID = existingForFingerprint
            } else if let existingForAlias {
                projectID = existingForAlias
            } else if try hasProjectRows(projectID: legacyProjectID) {
                projectID = legacyProjectID
            } else {
                projectID = preferredProjectID
            }

            try execute(
                """
                INSERT OR IGNORE INTO pcm_projects
                    (project_id, identity_version, identity_fingerprint, project_name, primary_path, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(projectID), .int(2), .text(fingerprint), .text(canonicalRoot.lastPathComponent), .text(canonicalPath), .text(now), .text(now)]
            )
            try execute(
                """
                UPDATE pcm_projects
                SET identity_version = 2,
                    identity_fingerprint = ?,
                    project_name = ?,
                    primary_path = ?,
                    updated_at = ?
                WHERE project_id = ?
                """,
                [.text(fingerprint), .text(canonicalRoot.lastPathComponent), .text(canonicalPath), .text(now), .text(projectID)]
            )
            let aliasID = "alias_" + String(Self.sha256Hex(pathHash).prefix(32))
            try execute(
                """
                INSERT INTO pcm_project_aliases
                    (id, project_id, alias_path, path_hash, first_seen_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(path_hash) DO UPDATE SET
                    project_id = excluded.project_id,
                    alias_path = excluded.alias_path,
                    last_seen_at = excluded.last_seen_at
                """,
                [.text(aliasID), .text(projectID), .text(canonicalPath), .text(pathHash), .text(now), .text(now)]
            )
            try execute(
                "UPDATE code_index_checkpoints SET project_root = ? WHERE project_id = ?",
                [.text(canonicalPath), .text(projectID)]
            )
            return ProjectIdentity(
                projectID: projectID,
                canonicalPath: canonicalPath,
                pathHash: pathHash,
                fingerprint: fingerprint
            )
        }
    }

    func hasProjectRows(projectID: String) throws -> Bool {
        let tables = [
            "agent_memories",
            "code_artifacts",
            "code_index_checkpoints",
            "code_symbols",
            "code_references",
            "code_call_edges",
            "code_diagnostics_cache",
            "memory_audit"
        ]
        for table in tables {
            let count = try fetchInt("SELECT COUNT(*) FROM \(table) WHERE project_id = ?", [.text(projectID)])
            if count > 0 { return true }
        }
        return false
    }

    func projectRoot(_ projectPath: String?) throws -> URL {
        let rawPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? FileManager.default.currentDirectoryPath
        let url = URL(fileURLWithPath: rawPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BurnBarProjectCodeMemoryStoreError.projectPathUnavailable(url.path)
        }
        return url
    }
}

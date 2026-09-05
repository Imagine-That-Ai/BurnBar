import Foundation

extension BurnBarProjectCodeMemoryStore {
    func resolveProjectIdentity(root: URL) throws -> ProjectIdentity {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalRoot.path
        let pathHash = Self.sha256Hex(canonicalPath)
        let legacyProjectID = Self.legacyProjectID(for: canonicalRoot)
        let longLegacyProjectID = Self.longLegacyProjectID(for: canonicalRoot)
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

            // A4 resolution order: this folder's own recorded mapping (the daemon's
            // explicit map) outranks the identity its CONTENTS imply. A folder that
            // already resolved once keeps that project id even if a later `git init`
            // + `git remote add` makes its fingerprint match somebody else's project;
            // repository contents must never silently re-scope a folder's memories.
            // Only an unmapped folder falls through to the git-root fingerprint, then
            // to the legacy ids, then to a provisional path-derived id.
            let projectID: String
            if let existingForAlias {
                projectID = existingForAlias
            } else if let existingForFingerprint {
                projectID = existingForFingerprint
            } else if try hasProjectRows(projectID: legacyProjectID) {
                projectID = legacyProjectID
            } else if try hasProjectRows(projectID: longLegacyProjectID) {
                projectID = longLegacyProjectID
            } else {
                projectID = preferredProjectID
            }

            // `pcm_projects.identity_fingerprint` is UNIQUE, so the fingerprint may
            // only be stamped onto a project that either already owns it or where no
            // project owns it yet. When another project holds it (an alias-mapped
            // folder whose contents now imply that project) only the timestamp moves;
            // the two projects stay separate rather than one stealing the other's key.
            let canUpdateFingerprint = (existingForFingerprint == nil || existingForFingerprint == projectID)
            if canUpdateFingerprint {
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
            } else {
                try execute(
                    """
                    UPDATE pcm_projects
                    SET updated_at = ?
                    WHERE project_id = ?
                    """,
                    [.text(now), .text(projectID)]
                )
            }
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

    func readOnlyProjectIdentity(root: URL) throws -> ProjectIdentity {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalRoot.path
        let pathHash = Self.sha256Hex(canonicalPath)
        let legacyProjectID = Self.legacyProjectID(for: canonicalRoot)
        let longLegacyProjectID = Self.longLegacyProjectID(for: canonicalRoot)
        let fingerprint = Self.projectIdentityFingerprint(root: canonicalRoot)
        let preferredProjectID = Self.projectID(forFingerprint: fingerprint, fallbackProjectID: legacyProjectID)

        return try databaseSync {
            let existingForFingerprint = try queryRows(
                "SELECT project_id FROM pcm_projects WHERE identity_fingerprint = ? LIMIT 1",
                [.text(fingerprint)]
            ).first?.string(0)
            let existingForAlias = try queryRows(
                "SELECT project_id FROM pcm_project_aliases WHERE path_hash = ? LIMIT 1",
                [.text(pathHash)]
            ).first?.string(0)

            // Same A4 resolution order as `resolveProjectIdentity`, read-only: the
            // folder's recorded mapping first, then the git-root fingerprint, then
            // the legacy ids, then a provisional path-derived id.
            let projectID: String
            if let existingForAlias {
                projectID = existingForAlias
            } else if let existingForFingerprint {
                projectID = existingForFingerprint
            } else if try hasProjectRows(projectID: legacyProjectID) {
                projectID = legacyProjectID
            } else if try hasProjectRows(projectID: longLegacyProjectID) {
                projectID = longLegacyProjectID
            } else {
                projectID = preferredProjectID
            }

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

import Foundation

/// One folder whose PROVISIONAL (path-derived) mapping was superseded by the git
/// fingerprint of the repository it now contains.
///
/// This is the reused-directory sequence: someone remembers something in a plain
/// folder, then clones a repository into it that this device already knows from
/// another checkout. The resolution order (A4, and the engine's) puts the git
/// fingerprint above a merely-visited alias, so the folder joins the repository's
/// project — which is correct, and is also the moment the memories written under
/// the folder's old provisional id stop being reachable from here. Nothing is
/// deleted; they are simply no longer in scope. A confirmed `project adopt`
/// (follow-up packet P31) is the way to choose the other answer on purpose.
///
/// Opaque project ids only. A path here would put the member's folder layout in
/// a log line, which is exactly what the identity fingerprint exists to avoid.
struct BurnBarProjectIdentitySplit: Hashable, Sendable {
    let provisionalProjectID: String
    let gitProjectID: String

    var logMetadata: [String: String] {
        ["project_id": provisionalProjectID, "git_project_id": gitProjectID]
    }
}

/// Process-wide, once-per-pair record of the splits above.
///
/// Once per process rather than once per resolve: every recall and every write
/// re-resolves identity, so an unguarded log line would repeat for every RPC on
/// that folder for the life of the daemon. The recorded set is also the surface a
/// future `project adopt` (follow-up packet P31) reads to offer the remedy; today
/// it is read by the daemon's own diagnostic test.
enum BurnBarProjectIdentityDiagnostics {
    private static let lock = NSLock()
    /// `nonisolated(unsafe)`: every access is inside `lock`.
    private nonisolated(unsafe) static var splits: [BurnBarProjectIdentitySplit] = []

    /// Records `split` and returns `true` the FIRST time this process sees it,
    /// `false` every time after — so the caller logs exactly once.
    @discardableResult
    static func noteSplit(_ split: BurnBarProjectIdentitySplit) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard splits.contains(split) == false else { return false }
        splits.append(split)
        return true
    }

    /// Every split observed in this process, oldest first.
    static func observedSplits() -> [BurnBarProjectIdentitySplit] {
        lock.lock()
        defer { lock.unlock() }
        return splits
    }
}

extension BurnBarProjectCodeMemoryStore {
    /// The prefix the engine's `map_project` stamps on an ADOPTED project's
    /// identity fingerprint (`memory_engine/store.py`). It is the daemon's only
    /// evidence that a folder → project mapping is a member's confirmed decision
    /// rather than a row the resolver wrote for itself.
    static let explicitIdentityFingerprintPrefix = "explicit:"

    /// What one folder's rows say about which project it belongs to, before any
    /// of it is written back. Both `resolveProjectIdentity` and
    /// `readOnlyProjectIdentity` decide from this one value, so a recall and a
    /// write can never disagree about which project a folder is.
    struct ProjectIdentityResolution {
        /// The id the folder resolves to.
        let projectID: String
        /// The fingerprint to record for `projectID`: the folder's observed
        /// fingerprint normally, `explicit:<projectID>` when a confirmed adoption
        /// decided the answer — the engine writes exactly this, and stamping the
        /// observed fingerprint instead would erase the adoption marker on the
        /// very next resolve.
        let fingerprint: String
        /// The project that already owns `fingerprint`, if any.
        let fingerprintOwner: String?
        /// A provisional (path-derived) alias for this folder that the resolution
        /// did NOT follow, i.e. the id whose memories just left this folder's
        /// scope. `nil` whenever the alias agrees with `projectID`.
        let supersededProvisionalProjectID: String?
    }

    /// A4 / engine-parity resolution order, in one place:
    ///
    ///   1. a CONFIRMED adoption for this folder — an alias row whose project
    ///      carries the engine's `explicit:` identity fingerprint;
    ///   2. the git-root fingerprint, when some project already owns it;
    ///   3. the folder's own provisional (path-derived) mapping — the alias the
    ///      resolver recorded automatically, then the legacy id shapes, then the
    ///      freshly derived id.
    ///
    /// The order matters in both directions. An alias alone must NOT outrank the
    /// fingerprint: the resolver records an alias for every folder it ever sees,
    /// so a directory that was once used for something else and now holds a
    /// checkout of a repository this device knows would keep the old project's id
    /// and serve the old project's memories — while the engine, resolving the same
    /// folder, would pick the repository's. And an adoption must outrank the
    /// fingerprint, because that is the member saying which project this folder
    /// is, and repository contents may not overrule it.
    ///
    /// Must be called inside `databaseSync`.
    func projectIdentityResolution(
        canonicalRoot: URL,
        pathHash: String,
        fingerprint: String
    ) throws -> ProjectIdentityResolution {
        let legacyProjectID = Self.legacyProjectID(for: canonicalRoot)
        let longLegacyProjectID = Self.longLegacyProjectID(for: canonicalRoot)
        let preferredProjectID = Self.projectID(forFingerprint: fingerprint, fallbackProjectID: legacyProjectID)

        let fingerprintOwner = try queryRows(
            "SELECT project_id FROM pcm_projects WHERE identity_fingerprint = ? LIMIT 1",
            [.text(fingerprint)]
        ).first?.string(0)

        // One row, two questions: which project is this folder mapped to, and is
        // that mapping a confirmed adoption or one the resolver wrote for itself.
        // LEFT JOIN because an alias may point at a project this store has no
        // `pcm_projects` row for (the engine adopts ids the daemon has never seen).
        let aliasRow = try queryRows(
            """
            SELECT alias.project_id, project.identity_fingerprint
            FROM pcm_project_aliases AS alias
            LEFT JOIN pcm_projects AS project ON project.project_id = alias.project_id
            WHERE alias.path_hash = ?
            LIMIT 1
            """,
            [.text(pathHash)]
        ).first
        let aliasProjectID = aliasRow?.optionalString(0)
        let aliasIsConfirmedAdoption = aliasRow?
            .optionalString(1)?
            .hasPrefix(Self.explicitIdentityFingerprintPrefix) == true

        let projectID: String
        if let aliasProjectID, aliasIsConfirmedAdoption {
            projectID = aliasProjectID
        } else if let fingerprintOwner {
            projectID = fingerprintOwner
        } else if let aliasProjectID {
            projectID = aliasProjectID
        } else if try hasProjectRows(projectID: legacyProjectID) {
            projectID = legacyProjectID
        } else if try hasProjectRows(projectID: longLegacyProjectID) {
            projectID = longLegacyProjectID
        } else {
            projectID = preferredProjectID
        }

        let recordedFingerprint = aliasIsConfirmedAdoption
            ? Self.explicitIdentityFingerprintPrefix + projectID
            : fingerprint
        let effectiveOwner: String?
        if recordedFingerprint == fingerprint {
            effectiveOwner = fingerprintOwner
        } else {
            effectiveOwner = try queryRows(
                "SELECT project_id FROM pcm_projects WHERE identity_fingerprint = ? LIMIT 1",
                [.text(recordedFingerprint)]
            ).first?.string(0)
        }

        // Only a PROVISIONAL alias that lost is worth reporting. An adoption that
        // won took precedence by design, and an alias that agrees with the answer
        // superseded nothing.
        let superseded: String? = {
            guard aliasIsConfirmedAdoption == false,
                  let aliasProjectID,
                  aliasProjectID != projectID,
                  fingerprint.hasPrefix("git:"),
                  fingerprintOwner == projectID else { return nil }
            return aliasProjectID
        }()

        return ProjectIdentityResolution(
            projectID: projectID,
            fingerprint: recordedFingerprint,
            fingerprintOwner: effectiveOwner,
            supersededProvisionalProjectID: superseded
        )
    }

    func resolveProjectIdentity(root: URL) throws -> ProjectIdentity {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalRoot.path
        let pathHash = Self.sha256Hex(canonicalPath)
        let fingerprint = Self.projectIdentityFingerprint(root: canonicalRoot)
        let now = Self.isoNow()

        return try databaseSync {
            let resolution = try projectIdentityResolution(
                canonicalRoot: canonicalRoot,
                pathHash: pathHash,
                fingerprint: fingerprint
            )
            let projectID = resolution.projectID

            // The reused-directory diagnostic. The fingerprint winning over a
            // provisional alias is the correct answer and the engine's, but it is
            // also the moment the folder's earlier memories leave its scope, and
            // that was silent. Once per process, opaque ids only; the remedy — a
            // confirmed `project adopt` — is follow-up packet P31.
            if let superseded = resolution.supersededProvisionalProjectID {
                let split = BurnBarProjectIdentitySplit(
                    provisionalProjectID: superseded,
                    gitProjectID: projectID
                )
                if BurnBarProjectIdentityDiagnostics.noteSplit(split) {
                    logger.warning("project_identity_provisional_split", metadata: split.logMetadata)
                }
            }

            // `pcm_projects.identity_fingerprint` is UNIQUE, so the fingerprint may
            // only be stamped onto a project that either already owns it or where no
            // project owns it yet. The order above makes the collision case
            // unreachable (whoever owns the fingerprint IS the resolved project,
            // unless an adoption decided it — and an adoption records
            // `explicit:<its own id>`), so this is a guard, not a branch the daemon
            // is expected to take.
            let canUpdateFingerprint = (resolution.fingerprintOwner == nil || resolution.fingerprintOwner == projectID)
            if canUpdateFingerprint {
                try execute(
                    """
                    INSERT OR IGNORE INTO pcm_projects
                        (project_id, identity_version, identity_fingerprint, project_name, primary_path, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(projectID), .int(2), .text(resolution.fingerprint), .text(canonicalRoot.lastPathComponent), .text(canonicalPath), .text(now), .text(now)]
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
                    [.text(resolution.fingerprint), .text(canonicalRoot.lastPathComponent), .text(canonicalPath), .text(now), .text(projectID)]
                )
            } else {
                // `project_name` and `primary_path` freeze with the fingerprint,
                // and deliberately so: this row belongs to a DIFFERENT folder than
                // the one being resolved, so writing this folder's name or path
                // onto it would relabel the other project. Only `updated_at`,
                // which is about the mapping being live, may move.
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
                fingerprint: resolution.fingerprint
            )
        }
    }

    func readOnlyProjectIdentity(root: URL) throws -> ProjectIdentity {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalRoot.path
        let pathHash = Self.sha256Hex(canonicalPath)
        let fingerprint = Self.projectIdentityFingerprint(root: canonicalRoot)

        return try databaseSync {
            // The same decision as `resolveProjectIdentity`, from the same code:
            // this path writes nothing, and it must not diverge, or a recall and a
            // write disagree about which project a folder is.
            let resolution = try projectIdentityResolution(
                canonicalRoot: canonicalRoot,
                pathHash: pathHash,
                fingerprint: fingerprint
            )
            return ProjectIdentity(
                projectID: resolution.projectID,
                canonicalPath: canonicalPath,
                pathHash: pathHash,
                fingerprint: resolution.fingerprint
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

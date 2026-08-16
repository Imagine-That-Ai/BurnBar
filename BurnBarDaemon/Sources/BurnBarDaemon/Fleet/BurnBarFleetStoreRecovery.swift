import BurnBarCore
import Darwin
import Foundation
import GRDB

/// Store-open/schema validation and live path-recovery helpers. Kept separate
/// from the snapshot/event CRUD surface so the store remains reviewable and
/// lintable as focused persistence components.
extension BurnBarFleetStore {
    /// Validates the complete persisted projection before it can seed
    /// transition derivation. Codable decoding alone accepts duplicate rows
    /// and fabricated aggregate fields, which would otherwise either publish
    /// false health or trap `Dictionary(uniqueKeysWithValues:)`.
    static func validateSnapshot(_ snapshot: BurnBarFleetSnapshot) throws {
        let roster = BurnBarFleetAgentID.declaredRoster
        let rosterSet = Set(roster)
        let agentIDs = snapshot.agents.map(\.id)
        guard snapshot.agents.count == roster.count,
              Set(agentIDs) == rosterSet,
              Set(agentIDs).count == agentIDs.count
        else {
            throw BurnBarFleetPersistenceError.semanticSnapshotInvalid(
                "agents must contain each declared roster id exactly once"
            )
        }
        for agent in snapshot.agents {
            try agent.validateConsistency()
        }

        let healthIDs = snapshot.probeHealth.map(\.agent)
        guard snapshot.probeHealth.count == roster.count,
              Set(healthIDs) == rosterSet,
              Set(healthIDs).count == healthIDs.count
        else {
            throw BurnBarFleetPersistenceError.semanticSnapshotInvalid(
                "probeHealth must contain each declared roster id exactly once"
            )
        }

        let expectedRunningCount = snapshot.agents.filter { $0.status == .running }.count
        guard snapshot.runningCount == expectedRunningCount else {
            throw BurnBarFleetPersistenceError.semanticSnapshotInvalid(
                "runningCount does not match agents"
            )
        }
        guard Set(snapshot.countsByAgent.keys) == Set(roster.map(\.wireValue)),
              snapshot.countsByAgent.allSatisfy({ key, value in
                  guard let id = BurnBarFleetAgentID(wireValue: key),
                        let agent = snapshot.agents.first(where: { $0.id == id })
                  else { return false }
                  return value == (agent.status == .running ? 1 : 0)
              })
        else {
            throw BurnBarFleetPersistenceError.semanticSnapshotInvalid(
                "countsByAgent does not match the fixed roster and statuses"
            )
        }

        let expectedRepos = expectedRepoGroups(from: snapshot.agents)
        guard snapshot.repos == expectedRepos else {
            throw BurnBarFleetPersistenceError.semanticSnapshotInvalid(
                "repos does not match agent project attribution"
            )
        }
        guard snapshot.cadenceSeconds > 0 else {
            throw BurnBarFleetPersistenceError.semanticSnapshotInvalid(
                "cadenceSeconds must be positive"
            )
        }
    }

    private static func expectedRepoGroups(
        from agents: [BurnBarFleetAgent]
    ) -> [BurnBarFleetRepoGroup] {
        var groups: [String: [BurnBarFleetAgentID]] = [:]
        var order: [String] = []
        for agent in agents {
            guard let projectName = agent.projectName, !projectName.isEmpty else { continue }
            if groups[projectName] == nil {
                order.append(projectName)
            }
            groups[projectName, default: []].append(agent.id)
        }
        return order.map { BurnBarFleetRepoGroup(projectName: $0, agents: groups[$0] ?? []) }
    }

    /// Migration metadata can claim that v1 ran while a table/column has
    /// subsequently been removed or an older partial store is supplied. GRDB
    /// will not re-run an applied migration in that case, so validate the
    /// complete fleet schema after migration and take the documented
    /// delete+rebuild path when it does not match.
    static func validateSchema(_ queue: DatabaseQueue) throws {
        let expectedColumns: [String: [String: (type: String, notNull: Bool, primaryKeyIndex: Int)]] = [
            "fleet_snapshots": [
                "id": ("INTEGER", false, 1), "generated_at": ("DOUBLE", true, 0), "payload": ("TEXT", true, 0)
            ],
            "fleet_events": [
                "id": ("INTEGER", false, 1), "at": ("DOUBLE", true, 0), "agent": ("TEXT", true, 0),
                "kind": ("TEXT", true, 0), "from_status": ("TEXT", false, 0),
                "to_status": ("TEXT", false, 0), "detail": ("TEXT", false, 0)
            ],
            "orchestrator_state": [
                "id": ("INTEGER", false, 1), "payload": ("TEXT", true, 0)
            ],
            "fleet_directives": [
                "id": ("INTEGER", false, 1), "directive_id": ("TEXT", true, 0),
                "payload": ("TEXT", true, 0), "created_at": ("DOUBLE", true, 0)
            ]
        ]
        try queue.read { db in
            guard try Set(migrator.appliedIdentifiers(db)) == ["v1_fleet"] else {
                throw BurnBarFleetSchemaMismatchError.invalidMigrationVersion
            }
            guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1 else {
                throw BurnBarFleetSchemaMismatchError.invalidMigrationVersion
            }
            for (table, columns) in expectedColumns {
                guard try db.tableExists(table) else {
                    throw BurnBarFleetSchemaMismatchError.missingTable(table)
                }
                let actual = try db.columns(in: table)
                guard actual.count == columns.count,
                      actual.allSatisfy({ column in
                          guard let expected = columns[column.name] else { return false }
                          return column.type.uppercased() == expected.type
                              && column.isNotNull == expected.notNull
                              && column.primaryKeyIndex == expected.primaryKeyIndex
                      })
                else {
                    throw BurnBarFleetSchemaMismatchError.missingColumns(
                        table: table,
                        columns: actual.map {
                            "\($0.name):\($0.type):notNull=\($0.isNotNull):pk=\($0.primaryKeyIndex)"
                        }.sorted()
                    )
                }
            }

            let snapshotIndexes = try db.indexes(on: "fleet_snapshots")
            guard snapshotIndexes.contains(where: { $0.columns == ["generated_at"] && !$0.isUnique }) else {
                throw BurnBarFleetSchemaMismatchError.invalidIndex("fleet_snapshots.generated_at")
            }
            let eventIndexes = try db.indexes(on: "fleet_events")
            guard eventIndexes.contains(where: { $0.columns == ["at"] && !$0.isUnique }),
                  eventIndexes.contains(where: { $0.columns == ["agent", "at"] && !$0.isUnique })
            else {
                throw BurnBarFleetSchemaMismatchError.invalidIndex("fleet_events")
            }
            let directiveIndexes = try db.indexes(on: "fleet_directives")
            guard directiveIndexes.contains(where: {
                $0.columns == ["directive_id"] && $0.isUnique
            }) else {
                throw BurnBarFleetSchemaMismatchError.invalidIndex("fleet_directives.directive_id")
            }

            let constraints: [String: String] = [
                "orchestrator_state": "id = 1"
            ]
            for (table, check) in constraints {
                let sql: String? = try String.fetchOne(
                    db,
                    sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [table]
                )
                guard sql?.replacingOccurrences(of: " ", with: "").lowercased()
                    .contains("check(\(check.replacingOccurrences(of: " ", with: "").lowercased()))") == true
                else {
                    throw BurnBarFleetSchemaMismatchError.invalidCheck(table)
                }
            }
        }
    }

    static func isRecoverableOpenFailure(_ error: Error) -> Bool {
        if error is BurnBarFleetSchemaMismatchError {
            return true
        }
        guard let databaseError = error as? DatabaseError else { return false }
        switch databaseError.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_IOERR, .SQLITE_ERROR, .SQLITE_SCHEMA:
            return true
        default:
            return false
        }
    }

    static func rebuildDetail(for error: Error) -> String {
        if let mismatch = error as? BurnBarFleetSchemaMismatchError {
            return "schema mismatch (\(mismatch.localizedDescription))"
        }
        if let databaseError = error as? DatabaseError,
           databaseError.resultCode == .SQLITE_ERROR || databaseError.resultCode == .SQLITE_SCHEMA {
            let detail = databaseError.message ?? "migration did not match the current schema"
            return "schema mismatch (\(detail))"
        }
        return "recreated after store open failure"
    }

    func rebuildDatabase(reason: String) throws {
        // A rebuild is a control-state loss boundary. Count it before the
        // recreate attempt so the control store can clear in-memory state
        // even if a read-only destination prevents the replacement.
        advanceRecoveryGeneration()
        try? queue?.close()
        queue = nil
        openedFileIdentity = nil
        do {
            try removeDatabaseFiles()
            queue = try Self.openQueue(at: databasePath, migrate: true)
            openedFileIdentity = Self.fileIdentity(at: databasePath)
            try Self.markInitialized(databasePath: databasePath)
        } catch {
            health = .degraded(reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)"))
            throw error
        }

        let rebuildHealth = BurnBarFleetPersistenceHealth.degraded(
            reason: BurnBarFleetPersistenceReason.storeRebuilt(reason)
        )
        health = rebuildHealth
        // The rebuild window spans the first published recovery snapshot:
        // it must be visible on that snapshot (RPC + file + store row) and
        // clear only on the next successful persist after publication.
        pendingRebuildHealth = rebuildHealth
    }

    private func removeDatabaseFiles() throws {
        let fileManager = FileManager.default
        for path in [
            databasePath, "\(databasePath)-wal", "\(databasePath)-shm", "\(databasePath)-journal"
        ]
            where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    static func fileIdentity(at path: String) -> FileIdentity? {
        var fileStat = stat()
        guard path.withCString({ lstat($0, &fileStat) }) == 0 else {
            return nil
        }
        return FileIdentity(
            device: UInt64(fileStat.st_dev),
            inode: UInt64(fileStat.st_ino)
        )
    }

    static func snapshotPath(for databasePath: String) -> String {
        URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent(BurnBarFleetPersistenceConstants.snapshotFileName)
            .path
    }

    static func initializationMarkerPath(for databasePath: String) -> String {
        URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent(BurnBarFleetPersistenceConstants.storeInitializationMarkerName)
            .path
    }

    static func markInitialized(databasePath: String) throws {
        let marker = initializationMarkerPath(for: databasePath)
        if !FileManager.default.fileExists(atPath: marker) {
            try Data("v1".utf8).write(to: URL(fileURLWithPath: marker), options: .atomic)
        }
    }
}

private enum BurnBarFleetSchemaMismatchError: Error, LocalizedError {
    case missingTable(String)
    case missingColumns(table: String, columns: [String])
    case invalidMigrationVersion
    case invalidIndex(String)
    case invalidCheck(String)

    var errorDescription: String? {
        switch self {
        case .missingTable(let table):
            return "required table \(table) is missing"
        case .missingColumns(let table, let columns):
            return "required columns missing from \(table): \(columns.joined(separator: ","))"
        case .invalidMigrationVersion:
            return "fleet schema migration marker is not exactly v1_fleet"
        case .invalidIndex(let index):
            return "required fleet index is missing or not unique as expected: \(index)"
        case .invalidCheck(let table):
            return "required CHECK constraint is missing from \(table)"
        }
    }
}

import Foundation
import GRDB

// MARK: - Working Directory Backfill

struct WorkingDirectoryBackfillService {
    private let batchSize: Int

    init(batchSize: Int = 1_000) {
        self.batchSize = max(1, batchSize)
    }

    func runIfNeeded(database: OpenBurnBarDatabase) async {
        // Distinguish "column genuinely absent" from "transient read failed": a
        // bare `try?` would collapse both into `false` and silently abort the
        // backfill on a flaky read. Treat a read error as "cannot determine yet"
        // (log + skip this run; the service re-runs next cycle), and only a
        // successful query returning `false` as a true schema absence.
        let hasColumn: Bool
        do {
            hasColumn = try await database.dbQueue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)")
                    .compactMap { $0["name"] as? String }
                    .contains("workingDirectory")
            }
        } catch {
            AppLogger.dataStore.silentFailure(
                "Working-directory backfill: column probe read failed",
                error: error
            )
            return
        }
        guard hasColumn else { return }

        while !Task.isCancelled {
            let limit = self.batchSize
            let batch: [(String, String)]
            do {
                batch = try await database.dbQueue.read { db in
                    try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, keyFiles
                        FROM conversations
                        WHERE workingDirectory IS NULL
                          AND deletedAt IS NULL
                          AND keyFiles IS NOT NULL
                          AND keyFiles != ''
                          AND keyFiles != '[]'
                          AND (
                              keyFiles LIKE '["/%'
                              OR keyFiles LIKE '["~/%'
                              OR keyFiles LIKE '["\\/%'
                          )
                        LIMIT ?
                        """,
                        arguments: [limit]
                    ).compactMap { row -> (String, String)? in
                        guard let id = row["id"] as? String,
                              let keyFiles = row["keyFiles"] as? String else {
                            return nil
                        }
                        return (id, keyFiles)
                    }
                }
            } catch {
                // A read error is NOT "no more rows": collapsing it to `[]` would
                // silently end the backfill as if every row were processed. Log
                // and end this run so the next cycle retries from the top.
                AppLogger.dataStore.silentFailure(
                    "Working-directory backfill: batch read failed",
                    error: error
                )
                return
            }
            guard !batch.isEmpty else { return }

            let updates = batch.compactMap { id, keyFilesJSON -> (id: String, workingDirectory: String)? in
                guard let workingDirectory = Self.inferWorkingDirectory(fromKeyFilesJSON: keyFilesJSON) else {
                    return nil
                }
                return (id, workingDirectory)
            }
            guard !updates.isEmpty else { return }

            do {
                try await database.dbQueue.write { db in
                    for update in updates {
                        try db.execute(
                            sql: "UPDATE conversations SET workingDirectory = ? WHERE id = ? AND workingDirectory IS NULL",
                            arguments: [update.workingDirectory, update.id]
                        )
                    }
                }
            } catch {
                // Losing this write drops the computed backfill for this batch.
                // It is idempotent (re-runs next cycle), but the failure must be
                // observable rather than silently swallowed. End this run so we
                // do not spin the loop re-reading the same unwritten rows.
                AppLogger.dataStore.silentFailure(
                    "Working-directory backfill write failed",
                    error: error
                )
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // try?-ok(cancellation only)
        }
    }

    static func inferWorkingDirectory(fromKeyFilesJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data), // try?-ok(decode fallback nil)
              let first = paths.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty else {
            return nil
        }

        let expanded: String
        if first.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(first.dropFirst(2)))
                .path
        } else {
            expanded = first
        }
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).deletingLastPathComponent().standardizedFileURL.path
    }
}

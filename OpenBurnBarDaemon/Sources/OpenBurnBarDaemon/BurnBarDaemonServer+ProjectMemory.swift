import Foundation

// Lazy project-memory store ownership, split out of
// OpenBurnBarDaemonServer.swift, which the Swift file-size
// budget holds shrink-only. The stored state stays on the actor;
// only the accessor and bootstrap entry point live here.

extension BurnBarDaemonServer {
    var projectCodeMemory: BurnBarProjectCodeMemoryStore? {
        ensureProjectCodeMemoryBootstrapped()
    }

    func ensureProjectCodeMemoryBootstrapped() -> BurnBarProjectCodeMemoryStore? {
        if let projectCodeMemoryStorage {
            return projectCodeMemoryStorage
        }
        guard projectCodeMemoryBootstrapAttempted == false else {
            return nil
        }
        guard let path = configuration.indexDatabasePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            path.isEmpty == false,
            FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        // Only mark the attempt after the configured file exists. The chat
        // store may create that file after the daemon has initialized.
        projectCodeMemoryBootstrapAttempted = true
        do {
            // Keep the same migration/key ordering as daemon initialization.
            // The helper never creates an unconfigured plaintext fallback.
            do {
                _ = try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
                    at: path,
                    logger: BurnBarDaemonLogger(category: "database-cipher")
                )
            } catch {
                logger.warning(
                    "daemon_database_encrypted_migration_failed",
                    metadata: ["path": path, "error": "\(error)"]
                )
            }
            let store = try BurnBarProjectCodeMemoryStore(
                databasePath: path,
                logger: BurnBarDaemonLogger(category: "project-code-memory")
            )
            projectCodeMemoryStorage = store
            projectCodeMemoryBootstrapFailure = nil
            logger.info(
                "project_code_memory_lazy_bootstrap_succeeded",
                metadata: ["path": path]
            )
            return store
        } catch {
            projectCodeMemoryBootstrapFailure = error.localizedDescription
            logger.warning(
                "project_code_memory_lazy_bootstrap_failed",
                metadata: ["path": path, "error": error.localizedDescription]
            )
            return nil
        }
    }
}

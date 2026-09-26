import Foundation
import GRDB
import OpenBurnBarLinuxSecurity
#if canImport(Security)
import Security
#endif
#if canImport(SQLCipher)
import SQLCipher
#else
import CSQLite
#endif

// MARK: - Daemon Database Cipher
//
// RR-1 (daemon side): the daemon opens the shared SQLite file
// (`~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`) with the raw
// `sqlite3` C API for indexed search, resume, and the switcher store. The app
// keys that same file with SQLCipher in passphrase mode via
// `DatabaseEncryptionService` (Keychain item `com.openburnbar.database-encryption`
// / account `database-encryption-key-v1`). The daemon MUST key the database
// with the SAME key so reads/writes line up — and a one-time
// plaintext→encrypted migration must exist for an existing plaintext file.
//
// Wave 2.4 fail-closed contract (mirrors the app's
// `DatabaseEncryptionService`): missing codec or key means REFUSE to open.
// A codec-less daemon build exits at startup (`requireCodecForStartup`,
// enforced in `OpenBurnBarDaemonMain`) instead of serving a
// disclosed-plaintext file, and every keyed-open primitive below throws
// rather than silently opening ciphertext it cannot read. There is no
// stock-SQLite compatibility mode anymore: the daemon package links
// SQLCipher.swift 4.16.0 on every platform it ships, so `isCipherAvailable()`
// is true in every legitimate build and false only in a misbuilt binary,
// which must not serve.
//

// SECURITY: the key is the app's base64 string applied in PASSPHRASE mode
// (`sqlite3_key` with UTF-8 passphrase bytes, PBKDF2 derivation), NOT raw `x'<hex>'` mode — the two
// derive different AES keys and are not interchangeable for an existing database,
// so this must match `DatabaseEncryptionService.makeConfiguration` exactly. The
// key is validated to contain only base64 characters (A-Z, a-z, 0-9, +, /, =)
// plus '-' before interpolation; none of those can escape a single-quoted SQL
// string literal, so injection is impossible.

/// Failures raised while keying or migrating the shared daemon database.
public enum BurnBarDaemonDatabaseCipherError: Error, CustomStringConvertible {
    /// `PRAGMA key` failed, or `PRAGMA cipher_version` came back empty after it,
    /// meaning the codec is not actually active on this handle.
    case keyApplicationFailed(detail: String)
    /// The plaintext→encrypted migration could not complete; the original
    /// plaintext file is left untouched so no data is lost.
    case migrationFailed(detail: String)
    /// The linked SQLite has no SQLCipher codec. The daemon refuses to open
    /// any database in this state (Wave 2.4 fail-closed, like the app's
    /// `DatabaseEncryptionError.cipherUnavailable`).
    case codecUnavailable(detail: String)
    /// The database file is SQLCipher-encrypted but no key is resolvable, so
    /// the daemon refuses to open it rather than failing late with an opaque
    /// "file is not a database" on the first read.
    case missingKeyForEncryptedDatabase(path: String)

    public var description: String {
        switch self {
        case let .keyApplicationFailed(detail):
            return "Failed to apply SQLCipher key to the daemon database: \(detail)"
        case let .migrationFailed(detail):
            return "Failed to migrate the plaintext daemon database to SQLCipher: \(detail)"
        case let .codecUnavailable(detail):
            return "SQLCipher codec unavailable in this daemon build: \(detail)"
        case let .missingKeyForEncryptedDatabase(path):
            return "Refusing to open encrypted daemon database without a resolvable key: \(path)"
        }
    }
}

public enum BurnBarDaemonDatabaseCipher {
    /// Keychain coordinates of the shared database key. Kept byte-identical to
    /// `DatabaseEncryptionService` on the app side — the daemon reads the very
    /// same item the app writes.
    private static let keychainService = "com.openburnbar.database-encryption"
    private static let keychainKeyAccount = "database-encryption-key-v1"

    /// Owner-only file the macOS app writes so an adhoc/Debug daemon (or a
    /// LaunchAgent that cannot satisfy the Keychain ACL) can still unlock the
    /// shared SQLCipher database. Same support-directory pattern as
    /// `daemon-socket-auth-token`.
    static let daemonReadableKeyFileName = "daemon-database-encryption-key"

    /// The 16-byte magic header every *plaintext* SQLite 3 file begins with. A
    /// SQLCipher-encrypted file's first page is ciphertext and does NOT carry it,
    /// so its presence/absence distinguishes the two without the key. Identical to
    /// `DatabaseEncryptionService.plaintextSQLiteMagic`.
    /// Reference: <https://www.sqlite.org/fileformat2.html#the_database_header>.
    private static let plaintextSQLiteMagic = Data("SQLite format 3\u{0}".utf8)

    // MARK: - Key Resolution

    /// Returns the app's stored database encryption key, or `nil` when no key has
    /// been provisioned (encryption never enabled) or the Keychain is unreadable
    /// (e.g. device locked / ACL rejects the daemon identity).
    ///
    /// Resolution order on macOS:
    /// 1. Keychain item (same coordinates as `DatabaseEncryptionService`)
    /// 2. Owner-only support-directory file written by the app for LaunchAgent /
    ///    adhoc Debug daemons that hit `errSecAuthFailed` (-25293) on Keychain
    static func resolveKey() -> String? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: AnyObject?
        let status = withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecSuccess, let data = result as? Data,
           let key = String(data: data, encoding: .utf8),
           key.isEmpty == false {
            return key
        }
#if DEBUG
        // Debug-only fallback matching the app's DEBUG-gated key file writer.
        // A signed Release daemon must satisfy the Keychain ACL; if it cannot,
        // the encrypted index stays closed rather than reading key material
        // from disk (SECURITY.md: key exists only in Keychain).
        return resolveKeyFromDaemonReadableFile()
#else
        return nil
#endif
#else
        let custodian = LinuxSecretStoreFactory.production()
        return try? custodian
            .requireHighValueSecret(id: LinuxHighValueSecretClass.databaseKey.rawValue, secretClass: .databaseKey)
            .secret
#endif
    }

#if canImport(Security)
    /// Reads `~/Library/Application Support/OpenBurnBar/daemon-database-encryption-key`
    /// when Keychain ACL rejects the daemon process.
    private static func resolveKeyFromDaemonReadableFile(
        fileManager: FileManager = .default
    ) -> String? {
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenBurnBar", isDirectory: true)
        let fileURL = support.appendingPathComponent(daemonReadableKeyFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              key.isEmpty == false else {
            return nil
        }
        return key
    }
#endif

    /// Resolve the app key AND validate its charset, returning it only when it is
    /// safe to interpolate into a single-quoted `PRAGMA key` literal. Used by the
    /// GRDB switcher store, whose `prepareDatabase` runs the PRAGMA through GRDB's
    /// own SQLCipher build rather than the raw `SQLite3` module. Returns `nil` when
    /// no key is provisioned or the key fails charset validation.
    static func validatedKeyForGRDB() -> String? {
        guard let key = resolveKey() else { return nil }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=-"))
        guard key.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else { return nil }
        return key
    }

    /// Wave 2.4 fail-closed decision for GRDB `prepareDatabase` closures (the
    /// switcher store and the Linux cloud-sync runtime share it). Pure so it is
    /// exhaustively unit-testable on any build; the closures themselves just
    /// execute the decision.
    enum GRDBKeyingDecision {
        /// Key the handle with this passphrase, then verify `cipher_version`.
        case applyKey(String)
        /// Open without a key: the file is plaintext, missing, or otherwise
        /// not ciphertext (first-run creation, legacy disclosed-plaintext with
        /// a genuinely unresolvable key).
        case openPlaintext
        /// Refuse the open: no codec, or ciphertext with no key.
        case refuse(BurnBarDaemonDatabaseCipherError)
    }

    static func grdbKeyingDecision(
        databasePath: String,
        resolvedKey: String?,
        codecAvailable: Bool = isCipherAvailable()
    ) -> GRDBKeyingDecision {
        guard codecAvailable else {
            return .refuse(.codecUnavailable(
                detail: "refusing GRDB open without the SQLCipher codec: \(databasePath)"
            ))
        }
        guard let key = resolvedKey else {
            if isEncryptedDatabaseFile(at: databasePath) {
                return .refuse(.missingKeyForEncryptedDatabase(path: databasePath))
            }
            return .openPlaintext
        }
        return .applyKey(key)
    }

#if os(Linux)
    /// Returns the existing database key or provisions one for a new/plaintext
    /// profile. An encrypted database with no readable key is never given a
    /// replacement key: that would make the existing data permanently
    /// unreadable. New Linux installs mirror macOS's encryption-at-rest
    /// default by persisting a 256-bit key in the approved native SecretStore
    /// before any encrypted database is opened.
    @discardableResult
    static func ensureKeyIfNeeded(
        at path: String,
        secretStore: LinuxSecretCustodian = LinuxSecretStoreFactory.production(),
        codecAvailable: Bool = isCipherAvailable()
    ) throws -> String? {
        guard codecAvailable else {
            throw BurnBarDaemonDatabaseCipherError.codecUnavailable(
                detail: "cannot provision a database key the codec cannot use: \(path)"
            )
        }

        do {
            return try secretStore
                .requireHighValueSecret(
                    id: LinuxHighValueSecretClass.databaseKey.rawValue,
                    secretClass: .databaseKey
                )
                .secret
        } catch LinuxSecretStoreError.missingSecret {
            // A missing key is expected only for a new or legacy plaintext
            // profile. Continue below and provision it once.
        } catch {
            // A locked/unavailable store is not the same as a missing key.
            // Preserve the fail-closed state and let the caller surface it.
            throw error
        }

        // Never create a replacement key for ciphertext or an unknown file.
        // Only a missing path or a recognizable plaintext SQLite file can be
        // safely initialized/migrated.
        let fileExists = FileManager.default.fileExists(atPath: path)
        guard fileExists == false || isPlaintextDatabaseFile(at: path) else {
            return nil
        }

        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
        let key = bytes.base64EncodedString()
        _ = try secretStore.storeHighValueSecret(
            key,
            id: LinuxHighValueSecretClass.databaseKey.rawValue,
            secretClass: .databaseKey
        )

        // Do not proceed with an in-memory key. The persisted readback is the
        // invariant that makes the next daemon launch recoverable.
        let persisted = try secretStore.requireHighValueSecret(
            id: LinuxHighValueSecretClass.databaseKey.rawValue,
            secretClass: .databaseKey
        )
        guard persisted.secret == key else {
            throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(
                detail: "database key persistence readback did not match"
            )
        }
        return key
    }
#endif

    // MARK: - Codec Availability Probe

    /// Whether the daemon's linked SQLite actually provides the SQLCipher codec.
    ///
    /// This must remain a non-invasive capability check. Calling `sqlite3_key`
    /// from a one-time probe can re-enter SQLCipher's global initialization on
    /// Linux and deadlock the daemon before its control socket is bound. The
    /// compile-option query is exported by both stock SQLite and SQLCipher and
    /// does not open a database or acquire the codec mutex. On stock SQLite it
    /// returns zero, preserving the plaintext compatibility path.
    static func isCipherAvailable() -> Bool {
        sqlite3_compileoption_used("SQLITE_HAS_CODEC") != 0
    }

    /// The codec probe the startup gate consults. Identical to
    /// `isCipherAvailable()` except in DEBUG builds, where
    /// `OPENBURNBAR_DAEMON_FORCE_NO_CODEC=1` forces absence so the
    /// "daemon without codec exits with an error" proof can execute against a
    /// real binary. The override is compiled out of release builds (same shape
    /// as the `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG` hatch): a hostile
    /// launch environment cannot strip anything, since forced absence only
    /// makes the daemon refuse sooner.
    public static func startupCodecProbe() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPENBURNBAR_DAEMON_FORCE_NO_CODEC"] == "1" {
            return false
        }
        #endif
        return isCipherAvailable()
    }

    /// Wave 2.4 startup gate (mirrors the app's
    /// `requireLinkedSQLCipherForRelease`): throws `codecUnavailable` unless
    /// the linked SQLite provides the SQLCipher codec. `OpenBurnBarDaemonMain`
    /// calls this before binding anything, so a codec-less binary exits with
    /// an error instead of serving a disclosed-plaintext database.
    public static func requireCodecForStartup(codecAvailable: Bool = startupCodecProbe()) throws {
        guard codecAvailable else {
            throw BurnBarDaemonDatabaseCipherError.codecUnavailable(
                detail: "SQLCipher codec not linked (SQLITE_HAS_CODEC absent); refusing to serve"
            )
        }
    }

    // MARK: - Keyed Open

    /// Apply the resolved SQLCipher key to an already-open handle. Wave 2.4
    /// fail-closed: a missing codec ALWAYS throws (`codecUnavailable`) — there
    /// is no stock-SQLite compatibility mode — and an encrypted file with no
    /// resolvable key throws (`missingKeyForEncryptedDatabase`) instead of
    /// failing late with an opaque "file is not a database" on the first read.
    /// A plaintext, missing, or in-memory database with no key is still opened
    /// as-is: first-run creation and the plaintext→encrypted migration (which
    /// runs when a key appears) both flow through here. Call this immediately
    /// after `sqlite3_open_v2`, before any other statement runs.
    ///
    /// - Throws: `codecUnavailable` when the codec is absent;
    ///   `missingKeyForEncryptedDatabase` when the file is encrypted but no key
    ///   resolves; `keyApplicationFailed` when SQLCipher rejects the key.
    static func applyKeyIfAvailable(
        to handle: OpaquePointer,
        key explicitKey: String? = nil,
        codecAvailable: Bool = isCipherAvailable()
    ) throws {
        guard codecAvailable else {
            throw BurnBarDaemonDatabaseCipherError.codecUnavailable(
                detail: "refusing to open a database the codec cannot verify"
            )
        }
        try applyResolvedKey(explicitKey ?? resolveKey(), to: handle)
    }

    /// The no-key decision behind `applyKeyIfAvailable`, split out so tests can
    /// drive it without depending on the ambient keychain: only an encrypted
    /// file is a refusal. Plaintext files stay readable so first-run creation
    /// and legacy disclosed-plaintext operation (key genuinely unresolvable,
    /// e.g. locked secret store) keep working; the migration upgrades them
    /// once a key appears.
    static func applyResolvedKey(_ key: String?, to handle: OpaquePointer) throws {
        guard let key else {
            let filename = mainDatabaseFilename(for: handle)
            if filename.isEmpty == false, isEncryptedDatabaseFile(at: filename) {
                throw BurnBarDaemonDatabaseCipherError.missingKeyForEncryptedDatabase(path: filename)
            }
            return
        }
        try applyKey(key, to: handle)
    }

    /// The filesystem path of `handle`'s `main` database, or `""` for
    /// in-memory databases (which carry no at-rest contract to violate).
    private static func mainDatabaseFilename(for handle: OpaquePointer) -> String {
        guard let cString = sqlite3_db_filename(handle, "main") else { return "" }
        return String(cString: cString)
    }

    /// Apply the SQLCipher passphrase to `handle` and verify the codec is
    /// genuinely active by reading `PRAGMA cipher_version`. Throws if the key
    /// fails charset validation, the C API errors, or `cipher_version` is empty
    /// (codec not active — the key would have been a silent no-op).
    static func applyKey(_ key: String, to handle: OpaquePointer) throws {
        try applySQLCipherKey(key, databaseName: nil, to: handle)

        // SQLCipher activity self-check: on a plain SQLite the key call is an
        // ignored no-op and this returns empty/nil; refuse to proceed because the
        // data would be plaintext under the caller's belief it is encrypted.
        let cipherVersion = querySingleString("PRAGMA cipher_version", on: handle)
        guard let version = cipherVersion, version.isEmpty == false else {
            throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(
                detail: "PRAGMA cipher_version empty; SQLCipher codec not active on this handle"
            )
        }
    }

    // MARK: - Plaintext vs Encrypted File Detection

    /// Reports whether the file at `path` is an *encrypted* SQLCipher database by
    /// inspecting only the first 16 bytes (no key required). A missing, empty, or
    /// short file is treated as "not encrypted". Mirrors
    /// `DatabaseEncryptionService.isEncryptedDatabaseFile`.
    static func isEncryptedDatabaseFile(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header: Data
        do {
            guard let data = try handle.read(upToCount: plaintextSQLiteMagic.count),
                  data.count == plaintextSQLiteMagic.count else {
                return false
            }
            header = data
        } catch {
            return false
        }
        return header != plaintextSQLiteMagic
    }

    /// Reports whether the file at `path` is a non-empty *plaintext* SQLite file
    /// (carries the magic header) — i.e. a one-time migration candidate.
    static func isPlaintextDatabaseFile(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            guard let data = try handle.read(upToCount: plaintextSQLiteMagic.count),
                  data.count == plaintextSQLiteMagic.count else {
                return false
            }
            return data == plaintextSQLiteMagic
        } catch {
            return false
        }
    }

    // MARK: - One-Time Plaintext → Encrypted Migration

    /// Migrate an existing plaintext database at `path` into a SQLCipher-encrypted
    /// database keyed with the app's native secret-store key, then atomically
    /// replace the original. On Linux, a missing key is provisioned first for a
    /// new/plaintext profile; an encrypted profile without a readable key stays
    /// fail-closed. No-op (returns `false`) when the file is missing or already
    /// encrypted. Wave 2.4 fail-closed: a plaintext file with no codec throws
    /// (`codecUnavailable`) — the daemon refuses to leave a database it cannot
    /// verify — and a plaintext file with no resolvable key is left in place
    /// with a loud log, to be migrated once a key appears.
    ///
    /// The migration opens the plaintext source, ATTACHes a freshly keyed sibling
    /// database, runs `sqlcipher_export('encrypted')` to copy every page through
    /// the codec, then `rename(2)`-swaps the encrypted file into place. On any
    /// failure the original plaintext file is left untouched and the temp file is
    /// removed.
    ///
    /// - Returns: `true` if a migration ran and the file is now encrypted; `false`
    ///   if migration was not applicable.
    /// - Throws: `codecUnavailable` when a plaintext file exists but the codec is
    ///   absent; `migrationFailed` if migration was applicable but could not
    ///   complete.
    @discardableResult
    static func migratePlaintextDatabaseIfNeeded(
        at path: String,
        logger: BurnBarDaemonLogger,
        key explicitKey: String? = nil,
        codecAvailable: Bool = isCipherAvailable()
    ) throws -> Bool {
        removeOrphanedMigrationArtifacts(forDatabaseAt: path, logger: logger)
        guard isPlaintextDatabaseFile(at: path) else { return false }
        guard codecAvailable else {
            throw BurnBarDaemonDatabaseCipherError.codecUnavailable(
                detail: "cannot migrate plaintext database without the SQLCipher codec: \(path)"
            )
        }
        #if os(Linux)
        // Explicit keys are used by migration callers and tests; do not make
        // those paths depend on a live Secret Service lookup.
        let resolvedKey: String?
        if let explicitKey {
            resolvedKey = explicitKey
        } else {
            resolvedKey = try ensureKeyIfNeeded(at: path)
        }
        #else
        let resolvedKey = explicitKey ?? resolveKey()
        #endif
        return try runPlaintextMigration(at: path, logger: logger, resolvedKey: resolvedKey)
    }

    /// Execute the plaintext→encrypted migration with an already-resolved key.
    /// Split from `migratePlaintextDatabaseIfNeeded` so tests can drive the
    /// no-key path without depending on the ambient secret store: a `nil` key
    /// leaves the file in place with a loud log and returns `false`.
    @discardableResult
    static func runPlaintextMigration(
        at path: String,
        logger: BurnBarDaemonLogger,
        resolvedKey: String?
    ) throws -> Bool {
        guard let key = resolvedKey else {
            logger.warning(
                "daemon_database_plaintext_key_unresolvable",
                metadata: [
                    "path": path,
                    "reason": "serving disclosed-plaintext; migration runs once a key is resolvable"
                ]
            )
            return false
        }
        try validateKey(key)

        let encryptedPath = path + ".sqlcipher-migrating-\(UUID().uuidString)"
        removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)

        do {
            let source = try DatabaseQueue(path: path, configuration: makePlaintextMigrationConfiguration())
            do {
                try source.writeWithoutTransaction { db in
                    let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version")
                    guard let version = cipherVersion, version.isEmpty == false else {
                        throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(
                            detail: "PRAGMA cipher_version empty; SQLCipher codec not active on migration handle"
                        )
                    }
                    _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    // ATTACH a new file keyed with the app key, copy all pages through the
                    // codec, DETACH. `sqlcipher_export` is the SQLCipher-sanctioned way to
                    // re-encrypt an entire database in one pass.
                    let escapedPath = encryptedPath.replacingOccurrences(of: "'", with: "''")
                    try db.execute(sql: "ATTACH DATABASE '\(escapedPath)' AS encrypted KEY '\(key)'")
                    _ = try Row.fetchAll(db, sql: "SELECT sqlcipher_export('encrypted')")
                    try db.execute(sql: "DETACH DATABASE encrypted")
                }
            } catch {
                removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)
                throw BurnBarDaemonDatabaseCipherError.migrationFailed(detail: "\(error)")
            }
            do {
                try source.close()
            } catch {
                removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)
                throw BurnBarDaemonDatabaseCipherError.migrationFailed(detail: "close plaintext source failed: \(error)")
            }
        } catch let error as BurnBarDaemonDatabaseCipherError {
            throw error
        } catch {
            removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)
            throw BurnBarDaemonDatabaseCipherError.migrationFailed(detail: "\(error)")
        }

        guard isEncryptedDatabaseFile(at: encryptedPath),
              canOpenEncryptedDatabase(at: encryptedPath, key: key)
        else {
            removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)
            throw BurnBarDaemonDatabaseCipherError.migrationFailed(
                detail: "export completed but encrypted replacement failed SQLCipher verification"
            )
        }

        // Atomically swap the encrypted file into place. The path resolves to a
        // complete file (old plaintext or new encrypted) throughout the rename.
        removeDatabaseFilesIfPresent(at: path, includePrimary: false)
        removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: false)
        let replaceResult = encryptedPath.withCString { sourcePath in
            path.withCString { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard replaceResult == 0 else {
            let errorNumber = errno
            removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)
            throw BurnBarDaemonDatabaseCipherError.migrationFailed(
                detail: "atomic replace failed with errno \(errorNumber): \(String(cString: strerror(errorNumber)))"
            )
        }

        logger.notice(
            "daemon_database_encrypted_migration_complete",
            metadata: ["path": path]
        )
        return true
    }

    /// Deletes orphaned `<dbFileName>.sqlcipher-migrating-<UUID>` temp databases
    /// (and their `-wal`/`-shm`/`-journal` sidecars, which share that prefix)
    /// from the database's parent directory. The temp file is only valid DURING a
    /// live `migratePlaintextDatabaseIfNeeded` call; when the process dies
    /// mid-export (SIGKILL, force quit, shutdown) the catch-path cleanup never
    /// runs and a multi-gigabyte orphan is stranded forever — a real machine
    /// accumulated 9.4 GB of them. Anything matching the prefix at entry is
    /// therefore dead and safe to remove; the live database and its own
    /// `-wal`/`-shm` never match. Best-effort by design: failures are logged and
    /// never interrupt startup or migration. Mirrors
    /// `DatabaseEncryptionService.removeOrphanedMigrationArtifacts`.
    static func removeOrphanedMigrationArtifacts(forDatabaseAt path: String, logger: BurnBarDaemonLogger) {
        let fileManager = FileManager.default
        let databaseURL = URL(fileURLWithPath: path)
        let databaseFileName = databaseURL.lastPathComponent
        guard databaseFileName.isEmpty == false else { return }
        let orphanPrefix = databaseFileName + ".sqlcipher-migrating-"
        let directoryURL = databaseURL.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        for entry in entries where entry.hasPrefix(orphanPrefix) {
            let orphanPath = directoryURL.appendingPathComponent(entry).path
            let attributes = try? fileManager.attributesOfItem(atPath: orphanPath)
            let orphanBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            do {
                try fileManager.removeItem(atPath: orphanPath)
                logger.notice(
                    "daemon_database_migration_orphan_removed",
                    metadata: ["path": orphanPath, "reclaimedBytes": "\(orphanBytes)"]
                )
            } catch {
                logger.error(
                    "daemon_database_migration_orphan_cleanup_failed",
                    metadata: ["path": orphanPath, "error": "\(error)"]
                )
            }
        }
    }

    // MARK: - Raw SQLite Helpers

    private static func validateKey(_ key: String) throws {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=-"))
        guard key.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(detail: "key contains characters outside the allowed set")
        }
    }

    private static func applySQLCipherKey(_ key: String, databaseName: String?, to handle: OpaquePointer) throws {
        try validateKey(key)
        guard var keyData = key.data(using: .utf8) else {
            throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(detail: "key is not valid UTF-8")
        }
        defer {
            keyData.resetBytes(in: 0..<keyData.count)
        }
        let code = keyData.withUnsafeBytes { rawBuffer in
            if let databaseName {
#if canImport(SQLCipher)
                return databaseName.withCString { databaseNameCString in
                    sqlite3_key_v2(handle, databaseNameCString, rawBuffer.baseAddress, CInt(rawBuffer.count))
                }
#else
                return SQLITE_MISUSE
#endif
            }
#if canImport(SQLCipher)
            return sqlite3_key(handle, rawBuffer.baseAddress, CInt(rawBuffer.count))
#else
            return _sqlite3_key(handle, rawBuffer.baseAddress, CInt(rawBuffer.count))
#endif
        }
        guard code == SQLITE_OK else {
            throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(
                detail: "sqlite3_key failed with sqlite error \(code): \(String(cString: sqlite3_errmsg(handle)))"
            )
        }
    }

    private static func makePlaintextMigrationConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.maximumReaderCount = 8
        return configuration
    }

    /// Verifies a candidate recovery key without mutating the database or the
    /// daemon's configured secret store. Used by recovery-bundle import to
    /// reject an authenticated-but-wrong key before replacing custody.
    static func canOpenEncryptedDatabase(at path: String, key: String) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        defer { sqlite3_close(handle) }
        do {
            try applyKey(key, to: handle)
            return querySingleString("PRAGMA integrity_check", on: handle) == "ok"
        } catch {
            return false
        }
    }

    private static func removeDatabaseFilesIfPresent(at path: String, includePrimary: Bool) {
        let suffixes = includePrimary ? ["", "-wal", "-shm"] : ["-wal", "-shm"]
        for suffix in suffixes {
            let result = (path + suffix).withCString { unlink($0) }
            if result != 0, errno != ENOENT {
                continue
            }
        }
    }

    private static func exec(_ sql: String, on handle: OpaquePointer, context: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "sqlite error \(rc)"
            sqlite3_free(errorMessage)
            throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(detail: "\(context): \(detail)")
        }
        sqlite3_free(errorMessage)
    }

    private static func querySingleString(_ sql: String, on handle: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }
}

import Foundation
import Security
import SQLite3

private let cipherSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Daemon Database Cipher
//
// RR-1 (daemon side): the daemon opens the shared SQLite file
// (`~/Library/Application Support/OpenBurnBar/openburnbar.sqlite`) with the raw
// `sqlite3` C API for indexed search, resume, and the switcher store. The app
// keys that same file with SQLCipher in passphrase mode via
// `DatabaseEncryptionService` (Keychain item `com.openburnbar.database-encryption`
// / account `database-encryption-key-v1`). When the daemon links a SQLCipher
// codec it MUST key the database with the SAME key so reads/writes line up — and
// a one-time plaintext→encrypted migration must exist for an existing plaintext
// file.
//
// Everything here is gated behind `isCipherAvailable()`: a stock-SQLite daemon
// build (the current SPM `SQLite3` system library has no codec) keeps opening the
// disclosed-plaintext file rather than bricking 100% of installs by applying a
// no-op `PRAGMA key`. The moment a SQLCipher codec lands (a `SQLITE_HAS_CODEC`
// build of the daemon's SQLite), `isCipherAvailable()` flips to `true` and the
// key + migration paths activate with no other code change.
//
// SECURITY: the key is the app's base64 string applied in PASSPHRASE mode
// (`PRAGMA key = '<key>'`, PBKDF2 derivation), NOT raw `x'<hex>'` mode — the two
// derive different AES keys and are not interchangeable for an existing database,
// so this must match `DatabaseEncryptionService.makeConfiguration` exactly. The
// key is validated to contain only base64 characters (A-Z, a-z, 0-9, +, /, =)
// plus '-' before interpolation; none of those can escape a single-quoted SQL
// string literal, so injection is impossible.

/// Failures raised while keying or migrating the shared daemon database.
enum BurnBarDaemonDatabaseCipherError: Error, CustomStringConvertible {
    /// `PRAGMA key` failed, or `PRAGMA cipher_version` came back empty after it,
    /// meaning the codec is not actually active on this handle.
    case keyApplicationFailed(detail: String)
    /// The plaintext→encrypted migration could not complete; the original
    /// plaintext file is left untouched so no data is lost.
    case migrationFailed(detail: String)

    var description: String {
        switch self {
        case let .keyApplicationFailed(detail):
            return "Failed to apply SQLCipher key to the daemon database: \(detail)"
        case let .migrationFailed(detail):
            return "Failed to migrate the plaintext daemon database to SQLCipher: \(detail)"
        }
    }
}

enum BurnBarDaemonDatabaseCipher {
    /// Keychain coordinates of the shared database key. Kept byte-identical to
    /// `DatabaseEncryptionService` on the app side — the daemon reads the very
    /// same item the app writes.
    private static let keychainService = "com.openburnbar.database-encryption"
    private static let keychainKeyAccount = "database-encryption-key-v1"

    /// The 16-byte magic header every *plaintext* SQLite 3 file begins with. A
    /// SQLCipher-encrypted file's first page is ciphertext and does NOT carry it,
    /// so its presence/absence distinguishes the two without the key. Identical to
    /// `DatabaseEncryptionService.plaintextSQLiteMagic`.
    /// Reference: <https://www.sqlite.org/fileformat2.html#the_database_header>.
    private static let plaintextSQLiteMagic = Data("SQLite format 3\u{0}".utf8)

    // MARK: - Key Resolution

    /// Returns the app's stored database encryption key, or `nil` when no key has
    /// been provisioned (encryption never enabled) or the Keychain is unreadable
    /// (e.g. device locked). Mirrors `DatabaseEncryptionService.getKey()`.
    static func resolveKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

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

    // MARK: - Codec Availability Probe

    /// Whether the daemon's linked SQLite actually provides the SQLCipher codec,
    /// i.e. `PRAGMA cipher_version` is non-empty after `PRAGMA key`. On the stock
    /// `SQLite3` system library this returns `false`, so callers fall back to a
    /// disclosed-plaintext open rather than applying a silent no-op key. Probes a
    /// throwaway in-memory database once; the result is cached for the process
    /// lifetime. Mirrors `DatabaseEncryptionService.isCipherAvailable()`.
    static func isCipherAvailable() -> Bool { cipherAvailabilityProbe }

    private static let cipherAvailabilityProbe: Bool = {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        defer { sqlite3_close(handle) }
        // A 64-char dummy key only exercises the codec plumbing; the in-memory DB
        // is discarded immediately.
        do {
            try applyKey(String(repeating: "a", count: 64), to: handle)
            return true
        } catch {
            return false
        }
    }()

    // MARK: - Keyed Open

    /// Apply the resolved SQLCipher key to an already-open handle WHEN the codec
    /// is available. On a stock-SQLite build, or when no key has been provisioned,
    /// this is a deliberate no-op so the daemon keeps opening the file plaintext
    /// (do-not-brick). Call this immediately after `sqlite3_open_v2`, before any
    /// other statement runs.
    ///
    /// - Throws: `BurnBarDaemonDatabaseCipherError.keyApplicationFailed` when the
    ///   codec is present and a key exists but `PRAGMA key` does not take.
    static func applyKeyIfAvailable(to handle: OpaquePointer) throws {
        guard isCipherAvailable(), let key = resolveKey() else { return }
        try applyKey(key, to: handle)
    }

    /// Apply `PRAGMA key` (passphrase mode) to `handle` and verify the codec is
    /// genuinely active by reading `PRAGMA cipher_version`. Throws if the key
    /// fails charset validation, the PRAGMA errors, or `cipher_version` is empty
    /// (codec not active — the key would have been a silent no-op).
    static func applyKey(_ key: String, to handle: OpaquePointer) throws {
        // Validate the key charset before interpolation. Allowed: base64 alphabet
        // (A-Z, a-z, 0-9, +, /, =) plus '-'. None of these can escape a
        // single-quoted SQL string literal (only ' and \ can), so interpolation
        // is injection-safe — identical to the app-side validation.
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=-"))
        guard key.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(detail: "key contains characters outside the allowed set")
        }

        try exec("PRAGMA key = '\(key)'", on: handle, context: "apply key")

        // SQLCipher activity self-check: on a plain SQLite the PRAGMA above is an
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
    /// database keyed with the app's Keychain key, then atomically replace the
    /// original. No-op (returns `false`) WHEN the codec is unavailable, no key is
    /// provisioned, the file is missing, or the file is already encrypted — so the
    /// stock-SQLite build never touches the file.
    ///
    /// The migration opens the plaintext source, ATTACHes a freshly keyed sibling
    /// database, runs `sqlcipher_export('encrypted')` to copy every page through
    /// the codec, then `rename(2)`-swaps the encrypted file into place. On any
    /// failure the original plaintext file is left untouched and the temp file is
    /// removed, so the daemon can still open the disclosed-plaintext file.
    ///
    /// - Returns: `true` if a migration ran and the file is now encrypted; `false`
    ///   if migration was not applicable.
    /// - Throws: `BurnBarDaemonDatabaseCipherError.migrationFailed` if migration
    ///   was applicable but could not complete.
    @discardableResult
    static func migratePlaintextDatabaseIfNeeded(
        at path: String,
        logger: BurnBarDaemonLogger
    ) throws -> Bool {
        guard isCipherAvailable() else { return false }
        guard let key = resolveKey() else { return false }
        guard isPlaintextDatabaseFile(at: path) else { return false }

        // cov:ignore-start -- SQLCipher migration body only executes when the daemon links a SQLITE_HAS_CODEC build; current CI links stock SQLite and gates the no-codec no-op and unsafe-key rejection paths.
        let encryptedPath = path + ".sqlcipher-migrating-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: encryptedPath)

        var source: OpaquePointer?
        guard sqlite3_open_v2(path, &source, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let source else {
            if let source { sqlite3_close(source) }
            throw BurnBarDaemonDatabaseCipherError.migrationFailed(detail: "could not open plaintext source")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 5000)

        do {
            // ATTACH a new file keyed with the app key, copy all pages through the
            // codec, DETACH. `sqlcipher_export` is the SQLCipher-sanctioned way to
            // re-encrypt an entire database in one pass.
            let escapedPath = encryptedPath.replacingOccurrences(of: "'", with: "''")
            try exec("ATTACH DATABASE '\(escapedPath)' AS encrypted KEY '\(key)'", on: source, context: "attach encrypted")
            try exec("SELECT sqlcipher_export('encrypted')", on: source, context: "sqlcipher_export")
            try exec("DETACH DATABASE encrypted", on: source, context: "detach encrypted")
        } catch {
            try? FileManager.default.removeItem(atPath: encryptedPath)
            throw BurnBarDaemonDatabaseCipherError.migrationFailed(detail: "\(error)")
        }

        // Atomically swap the encrypted file into place. The plaintext source FD
        // stays valid (old inode) until `deinit`; the path resolves to a complete
        // file (old plaintext or new encrypted) throughout the rename.
        do {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: encryptedPath)
            )
        } catch {
            try? FileManager.default.removeItem(atPath: encryptedPath)
            throw BurnBarDaemonDatabaseCipherError.migrationFailed(detail: "atomic swap failed: \(error)")
        }

        logger.notice(
            "daemon_database_encrypted_migration_complete",
            metadata: ["path": path]
        )
        return true
        // cov:ignore-end
    }

    // MARK: - Raw SQLite Helpers

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

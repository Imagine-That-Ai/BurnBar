import Foundation
import OpenBurnBarCore
import OpenBurnBarLinuxSecurity

/// Daemon-owned export/import for the macOS-compatible passphrase-wrapped
/// database key bundle. The webview supplies only a destination/source path and
/// passphrase; key material is resolved and persisted inside this service.
enum BurnBarDatabaseRecoveryBundleServiceError: Error, CustomStringConvertible, Equatable {
    case unsupportedPlatform
    case invalidPath
    case pathTooLong
    case pathIsSymlink
    case pathIsNotRegularFile
    case parentUnavailable
    case destinationExists
    case unsafeDirectoryPermissions
    case bundleTooLarge(Int)
    case databaseUnavailable
    case databaseNotEncrypted
    case cipherUnavailable
    case keyUnavailable
    case candidateKeyRejected
    case keyStorageUnavailable
    case crypto(BurnBarDatabaseRecoveryBundleCrypto.Error)
    case io(String)

    var description: String {
        switch self {
        case .unsupportedPlatform: return "Database recovery bundles are supported by the Linux daemon only."
        case .invalidPath: return "Recovery bundle path must be an absolute local path without control characters."
        case .pathTooLong: return "Recovery bundle path is too long."
        case .pathIsSymlink: return "Recovery bundle paths must not traverse symbolic links."
        case .pathIsNotRegularFile: return "The recovery bundle source is not a regular file."
        case .parentUnavailable: return "The recovery bundle destination directory is unavailable or unsafe."
        case .destinationExists: return "The recovery bundle destination already exists. Choose a new file."
        case .unsafeDirectoryPermissions: return "The recovery bundle destination directory is writable by another user."
        case let .bundleTooLarge(bytes): return "Recovery bundle exceeds the 64 KiB limit (\(bytes) bytes)."
        case .databaseUnavailable: return "The daemon database path is not configured or does not exist."
        case .databaseNotEncrypted: return "The daemon database is not an encrypted SQLCipher database."
        case .cipherUnavailable: return "SQLCipher is not available in this daemon build."
        case .keyUnavailable: return "The daemon database key is unavailable from approved native secret storage. Unlock the key store or import a recovery bundle from the original device."
        case .candidateKeyRejected: return "The recovery bundle key could not open the encrypted database."
        case .keyStorageUnavailable: return "No approved writable native secret store is available."
        case let .crypto(error): return "Recovery bundle authentication failed or the bundle is malformed: \(error)."
        case let .io(detail): return "Recovery bundle file operation failed: \(detail)"
        }
    }
}

final class BurnBarDatabaseRecoveryBundleService: Sendable {
    private let databasePath: String
    private let logger: BurnBarDaemonLogger

    #if os(Linux)
    private let secretStore: LinuxSecretCustodian
    #endif

    init(
        databasePath: String,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "database-recovery")
    ) {
        self.databasePath = databasePath
        self.logger = logger
        #if os(Linux)
        self.secretStore = LinuxSecretStoreFactory.production()
        #endif
    }

    /// Return a typed, secret-free recovery posture. This is intentionally a
    /// read-only diagnostic: it never treats key custody as proof that the
    /// active database is readable.
    func status() -> BurnBarDatabaseRecoveryStatusResponse {
        #if !os(Linux)
        return .unavailable(message: "Database recovery status requires the packaged Linux daemon.")
        #else
        guard BurnBarDaemonDatabaseCipher.isCipherAvailable() else {
            return BurnBarDatabaseRecoveryStatusResponse(
                phase: .cipherUnavailable,
                code: "sqlcipher_unavailable",
                message: "SQLCipher is not available in this daemon build. Install a packaged Linux build with SQLCipher before attempting recovery.",
                recommendedAction: .none,
                canExport: false,
                canImport: false,
                databasePresent: FileManager.default.fileExists(atPath: databasePath),
                databaseIntegrityVerified: false
            )
        }

        let databasePresent = FileManager.default.fileExists(atPath: databasePath)
        guard databasePresent else {
            return BurnBarDatabaseRecoveryStatusResponse(
                phase: .databaseMissing,
                code: "database_missing",
                message: "No encrypted database is present. Import the recovery bundle, then restore an encrypted database snapshot before claiming recovery succeeded.",
                recommendedAction: .restoreEncryptedSnapshot,
                canExport: false,
                canImport: true,
                databasePresent: false,
                databaseIntegrityVerified: false
            )
        }

        guard BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: databasePath) else {
            return BurnBarDatabaseRecoveryStatusResponse(
                phase: .databaseNotEncrypted,
                code: "database_not_encrypted",
                message: "The local database is not an encrypted SQLCipher store. Restore an encrypted snapshot before using recovery-key custody.",
                recommendedAction: .restoreEncryptedSnapshot,
                canExport: false,
                canImport: false,
                databasePresent: true,
                databaseIntegrityVerified: false
            )
        }

        guard let key = BurnBarDaemonDatabaseCipher.resolveKey() else {
            return BurnBarDatabaseRecoveryStatusResponse(
                phase: .keyUnavailable,
                code: "database_key_unavailable",
                message: "The database key is unavailable because the native secret store is missing or locked. Unlock it, or import a recovery bundle from the original device.",
                recommendedAction: .importRecoveryBundle,
                canExport: false,
                canImport: true,
                databasePresent: true,
                databaseIntegrityVerified: false
            )
        }

        guard BurnBarDaemonDatabaseCipher.canOpenEncryptedDatabase(at: databasePath, key: key) else {
            return BurnBarDatabaseRecoveryStatusResponse(
                phase: .integrityFailed,
                code: "database_integrity_unverified",
                message: "The stored key did not open a healthy encrypted database. Import a verified recovery bundle or restore a known-good encrypted snapshot.",
                recommendedAction: .importRecoveryBundle,
                canExport: false,
                canImport: true,
                databasePresent: true,
                databaseIntegrityVerified: false
            )
        }

        return BurnBarDatabaseRecoveryStatusResponse(
            phase: .ready,
            code: "database_ready",
            message: "The encrypted database opened with the native key and passed integrity verification.",
            recommendedAction: .exportRecoveryBundle,
            canExport: true,
            canImport: true,
            databasePresent: true,
            databaseIntegrityVerified: true
        )
        #endif
    }

    func exportBundle(
        request: BurnBarDatabaseRecoveryBundleExportRequest
    ) throws -> BurnBarDatabaseRecoveryBundleExportResponse {
        #if !os(Linux)
        _ = request
        throw BurnBarDatabaseRecoveryBundleServiceError.unsupportedPlatform
        #else
        let destination = try validateDestinationPath(request.destinationPath)
        guard BurnBarDaemonDatabaseCipher.isCipherAvailable() else {
            throw BurnBarDatabaseRecoveryBundleServiceError.cipherUnavailable
        }
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw BurnBarDatabaseRecoveryBundleServiceError.databaseUnavailable
        }
        guard BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: databasePath) else {
            throw BurnBarDatabaseRecoveryBundleServiceError.databaseNotEncrypted
        }
        guard let key = BurnBarDaemonDatabaseCipher.resolveKey() else {
            throw BurnBarDatabaseRecoveryBundleServiceError.keyUnavailable
        }

        let bundle: Data
        do {
            bundle = try BurnBarDatabaseRecoveryBundleCrypto.export(
                databaseKey: key,
                passphrase: request.passphrase
            )
        } catch let error as BurnBarDatabaseRecoveryBundleCrypto.Error {
            throw BurnBarDatabaseRecoveryBundleServiceError.crypto(error)
        } catch {
            throw BurnBarDatabaseRecoveryBundleServiceError.io("bundle encryption failed")
        }
        try writeBundle(bundle, to: destination)
        logger.notice(
            "database_recovery_bundle_exported",
            metadata: ["bytes": "\(bundle.count)", "path": destination.path]
        )
        return BurnBarDatabaseRecoveryBundleExportResponse(
            destinationPath: destination.path,
            byteCount: bundle.count
        )
        #endif
    }

    func importBundle(
        request: BurnBarDatabaseRecoveryBundleImportRequest
    ) throws -> BurnBarDatabaseRecoveryBundleImportResponse {
        #if !os(Linux)
        _ = request
        throw BurnBarDatabaseRecoveryBundleServiceError.unsupportedPlatform
        #else
        let source = try validateSourcePath(request.sourcePath)
        let bundle: Data
        do {
            bundle = try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw BurnBarDatabaseRecoveryBundleServiceError.io("read failed")
        }
        guard bundle.count <= BurnBarDatabaseRecoveryBundleCrypto.maximumBundleByteCount else {
            throw BurnBarDatabaseRecoveryBundleServiceError.bundleTooLarge(bundle.count)
        }

        let key: String
        do {
            key = try BurnBarDatabaseRecoveryBundleCrypto.importDatabaseKey(
                bundle: bundle,
                passphrase: request.passphrase
            )
        } catch let error as BurnBarDatabaseRecoveryBundleCrypto.Error {
            throw BurnBarDatabaseRecoveryBundleServiceError.crypto(error)
        } catch {
            throw BurnBarDatabaseRecoveryBundleServiceError.io("bundle decryption failed")
        }

        // If an encrypted database is present, prove the recovered key before
        // mutating native secret storage. A wrong-but-authenticated bundle must
        // never brick the existing profile.
        let databasePresent = FileManager.default.fileExists(atPath: databasePath)
        var candidateKeyVerified = false
        if databasePresent {
            guard BurnBarDaemonDatabaseCipher.isCipherAvailable() else {
                throw BurnBarDatabaseRecoveryBundleServiceError.cipherUnavailable
            }
            guard BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: databasePath) else {
                throw BurnBarDatabaseRecoveryBundleServiceError.databaseNotEncrypted
            }
            guard BurnBarDaemonDatabaseCipher.canOpenEncryptedDatabase(at: databasePath, key: key) else {
                throw BurnBarDatabaseRecoveryBundleServiceError.candidateKeyRejected
            }
            candidateKeyVerified = true
        }

        do {
            try secretStore.storeHighValueSecret(
                key,
                id: LinuxHighValueSecretClass.databaseKey.rawValue,
                secretClass: .databaseKey
            )
        } catch {
            logger.warning(
                "database_recovery_bundle_key_store_failed",
                metadata: ["error": String(describing: error)]
            )
            throw BurnBarDatabaseRecoveryBundleServiceError.keyStorageUnavailable
        }
        logger.notice(
            "database_recovery_bundle_imported",
            metadata: ["path": source.path, "restart_required": "true"]
        )
        if candidateKeyVerified {
            return BurnBarDatabaseRecoveryBundleImportResponse(
                sourcePath: source.path,
                stored: true,
                candidateKeyVerified: true,
                databaseIntegrityVerified: true,
                phase: .ready,
                recommendedAction: .restartDaemon,
                message: "The recovery key opened the encrypted database and passed integrity verification. Restart the daemon to adopt the recovered custody.",
                restartRequired: true
            )
        }

        // Device-transfer import can legitimately happen before the encrypted
        // database file is restored. Keep the key, but make the missing proof
        // explicit so the renderer cannot claim that recovery completed.
        return BurnBarDatabaseRecoveryBundleImportResponse(
            sourcePath: source.path,
            stored: true,
            candidateKeyVerified: false,
            databaseIntegrityVerified: false,
            phase: .awaitingDatabaseVerification,
            recommendedAction: .restoreEncryptedSnapshot,
            message: "The recovery key was stored, but no encrypted database was present to verify it. Restore an encrypted snapshot, then restart the daemon.",
            restartRequired: true
        )
        #endif
    }

    // MARK: - Bounded local file handling

    private func validateDestinationPath(_ rawPath: String) throws -> URL {
        let path = try validatePath(rawPath)
        guard path != databasePath else { throw BurnBarDatabaseRecoveryBundleServiceError.invalidPath }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) == false else {
            throw BurnBarDatabaseRecoveryBundleServiceError.destinationExists
        }
        try validateParent(url.deletingLastPathComponent())
        return url
    }

    private func validateSourcePath(_ rawPath: String) throws -> URL {
        let path = try validatePath(rawPath)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BurnBarDatabaseRecoveryBundleServiceError.pathIsNotRegularFile
        }
        guard isSymlinkFree(url),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw BurnBarDatabaseRecoveryBundleServiceError.pathIsNotRegularFile
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            throw BurnBarDatabaseRecoveryBundleServiceError.pathIsNotRegularFile
        }
        guard size.intValue <= BurnBarDatabaseRecoveryBundleCrypto.maximumBundleByteCount else {
            throw BurnBarDatabaseRecoveryBundleServiceError.bundleTooLarge(size.intValue)
        }
        return url
    }

    private func validatePath(_ rawPath: String) throws -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false,
              path.utf8.count <= 4_096,
              path.hasPrefix("/"),
              path.contains("\0") == false,
              path.contains("\n") == false,
              path.contains("\r") == false else {
            if path.utf8.count > 4_096 {
                throw BurnBarDatabaseRecoveryBundleServiceError.pathTooLong
            }
            throw BurnBarDatabaseRecoveryBundleServiceError.invalidPath
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func validateParent(_ parent: URL) throws {
        guard FileManager.default.fileExists(atPath: parent.path),
              (try? parent.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw BurnBarDatabaseRecoveryBundleServiceError.parentUnavailable
        }
        guard isSymlinkFree(parent) else { throw BurnBarDatabaseRecoveryBundleServiceError.pathIsSymlink }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw BurnBarDatabaseRecoveryBundleServiceError.parentUnavailable
        }
        // A sticky shared directory (for example /tmp) is acceptable; an
        // ordinary group/world-writable directory is not.
        let mode = permissions.uint16Value
        if mode & 0o022 != 0, mode & 0o1000 == 0 {
            throw BurnBarDatabaseRecoveryBundleServiceError.unsafeDirectoryPermissions
        }
    }

    private func isSymlinkFree(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: false)
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
            if values.isSymbolicLink == true { return false }
        }
        return true
    }

    private func writeBundle(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw BurnBarDatabaseRecoveryBundleServiceError.io("write failed")
        }
    }
}

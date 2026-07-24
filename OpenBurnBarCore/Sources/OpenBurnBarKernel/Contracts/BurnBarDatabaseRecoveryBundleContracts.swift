import Foundation

/// The daemon-owned recovery posture for the encrypted local database.
///
/// These states deliberately distinguish custody from verification. In
/// particular, `awaiting_database_verification` means a candidate key was
/// stored for a device transfer, but no encrypted database was present to
/// prove that the key opens a healthy store.
public enum BurnBarDatabaseRecoveryPhase: String, Codable, Hashable, Sendable {
    case ready
    case databaseMissing = "database_missing"
    case cipherUnavailable = "cipher_unavailable"
    case databaseNotEncrypted = "database_not_encrypted"
    case keyUnavailable = "key_unavailable"
    case integrityFailed = "integrity_failed"
    case awaitingDatabaseVerification = "awaiting_database_verification"
    case unavailable
}

/// A bounded action the UI may present as the next recovery step. The daemon
/// remains the authority for whether the action is currently allowed.
public enum BurnBarDatabaseRecoveryAction: String, Codable, Hashable, Sendable {
    case none
    case exportRecoveryBundle = "export_recovery_bundle"
    case importRecoveryBundle = "import_recovery_bundle"
    case restoreEncryptedSnapshot = "restore_encrypted_snapshot"
    case unlockSecretStore = "unlock_secret_store"
    case restartDaemon = "restart_daemon"
}

public struct BurnBarDatabaseRecoveryStatusResponse: Codable, Hashable, Sendable {
    public let phase: BurnBarDatabaseRecoveryPhase
    public let code: String
    public let message: String
    public let recommendedAction: BurnBarDatabaseRecoveryAction
    public let canExport: Bool
    public let canImport: Bool
    public let databasePresent: Bool
    public let databaseIntegrityVerified: Bool
    public let restartRequired: Bool

    public init(
        phase: BurnBarDatabaseRecoveryPhase,
        code: String,
        message: String,
        recommendedAction: BurnBarDatabaseRecoveryAction,
        canExport: Bool,
        canImport: Bool,
        databasePresent: Bool,
        databaseIntegrityVerified: Bool,
        restartRequired: Bool = false
    ) {
        self.phase = phase
        self.code = code
        self.message = message
        self.recommendedAction = recommendedAction
        self.canExport = canExport
        self.canImport = canImport
        self.databasePresent = databasePresent
        self.databaseIntegrityVerified = databaseIntegrityVerified
        self.restartRequired = restartRequired
    }

    public static func unavailable(message: String) -> Self {
        Self(
            phase: .unavailable,
            code: "recovery_service_unavailable",
            message: message,
            recommendedAction: .none,
            canExport: false,
            canImport: false,
            databasePresent: false,
            databaseIntegrityVerified: false
        )
    }
}

/// Native-only passphrase input for a database recovery bundle export. The
/// daemon never serializes the database key or passphrase into logs/UI state.
public struct BurnBarDatabaseRecoveryBundleExportRequest: Codable, Hashable, Sendable {
    public let destinationPath: String
    public let passphrase: String

    public init(destinationPath: String, passphrase: String) {
        self.destinationPath = destinationPath
        self.passphrase = passphrase
    }
}

public struct BurnBarDatabaseRecoveryBundleExportResponse: Codable, Hashable, Sendable {
    public let destinationPath: String
    public let byteCount: Int
    public let formatVersion: Int

    public init(destinationPath: String, byteCount: Int, formatVersion: Int = 1) {
        self.destinationPath = destinationPath
        self.byteCount = byteCount
        self.formatVersion = formatVersion
    }
}

/// Native-only passphrase input for importing a previously exported recovery
/// bundle. The bundle is read by the daemon, not by the webview.
public struct BurnBarDatabaseRecoveryBundleImportRequest: Codable, Hashable, Sendable {
    public let sourcePath: String
    public let passphrase: String

    public init(sourcePath: String, passphrase: String) {
        self.sourcePath = sourcePath
        self.passphrase = passphrase
    }
}

public struct BurnBarDatabaseRecoveryBundleImportResponse: Codable, Hashable, Sendable {
    public let sourcePath: String
    public let stored: Bool
    /// True only when the candidate key opened the active encrypted database
    /// and passed `PRAGMA integrity_check`. A missing database is intentionally
    /// not treated as verified during device transfer.
    public let candidateKeyVerified: Bool
    public let databaseIntegrityVerified: Bool
    public let phase: BurnBarDatabaseRecoveryPhase
    public let recommendedAction: BurnBarDatabaseRecoveryAction
    public let message: String
    public let restartRequired: Bool

    public init(
        sourcePath: String,
        stored: Bool,
        candidateKeyVerified: Bool = false,
        databaseIntegrityVerified: Bool = false,
        phase: BurnBarDatabaseRecoveryPhase = .awaitingDatabaseVerification,
        recommendedAction: BurnBarDatabaseRecoveryAction = .restoreEncryptedSnapshot,
        message: String = "The recovery key was stored, but database integrity is not verified yet.",
        restartRequired: Bool = true
    ) {
        self.sourcePath = sourcePath
        self.stored = stored
        self.candidateKeyVerified = candidateKeyVerified
        self.databaseIntegrityVerified = databaseIntegrityVerified
        self.phase = phase
        self.recommendedAction = recommendedAction
        self.message = message
        self.restartRequired = restartRequired
    }
}

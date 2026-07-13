import Foundation

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
    public let restartRequired: Bool

    public init(sourcePath: String, stored: Bool, restartRequired: Bool = true) {
        self.sourcePath = sourcePath
        self.stored = stored
        self.restartRequired = restartRequired
    }
}

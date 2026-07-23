import Foundation
import GRDB
import OpenBurnBarEngine
import OpenBurnBarLinuxSecurity

/// Production composition for Linux cloud replica sync.
///
/// The renderer never owns this graph. The daemon opens the canonical local
/// database, resolves the stable installation identity, and obtains Firebase
/// credentials and the vault key only inside the injected providers.
public enum LinuxCloudSyncRuntimeFactory {
    /// Builds a runtime around an already-authorized gateway. This small
    /// boundary keeps database ownership testable without requiring a live
    /// Firebase session in unit tests.
    public static func make(
        databasePath: String,
        deviceID: String,
        gateway: any LinuxCloudReplicaEngine.Gateway,
        identityProvider: @escaping LinuxCloudSyncIdentityProvider,
        vaultKeyProvider: @escaping LinuxCloudSyncVaultKeyProvider,
        globalConsentProvider: @escaping LinuxCloudSyncConsentProvider = { true },
        backgroundIntervalMillis: Int64 = LinuxCloudSyncRuntime.defaultBackgroundIntervalMillis
    ) throws -> LinuxCloudSyncRuntime {
        let path = databasePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            throw LinuxCloudReplicaEngine.EngineError.invalidIdentifier
        }
        let databaseURL = URL(fileURLWithPath: path).standardizedFileURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try DatabasePool(
            path: databaseURL.path,
            configuration: databaseConfiguration()
        )
        let engine = try LinuxCloudReplicaEngine(
            database: database,
            gateway: gateway,
            deviceID: deviceID
        )
        return LinuxCloudSyncRuntime(
            engine: engine,
            identityProvider: identityProvider,
            vaultKeyProvider: vaultKeyProvider,
            globalConsentProvider: globalConsentProvider,
            backgroundIntervalMillis: backgroundIntervalMillis
        )
    }

    #if os(Linux)
    /// Builds the production Firebase-backed runtime. Missing sign-in or vault
    /// material is intentionally deferred to the providers so the daemon can
    /// start and expose a locked/unavailable status instead of crashing.
    public static func makeProduction(
        configuration: BurnBarDaemonConfiguration,
        credentialAuthority: LinuxDaemonCloudCredentialAuthority,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "cloud-sync")
    ) -> LinuxCloudSyncRuntime? {
        guard let databasePath = configuration.indexDatabasePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            databasePath.isEmpty == false else {
            logger.notice(
                "linux_cloud_sync_runtime_unconfigured",
                metadata: ["reason": "index_database_path_missing"]
            )
            return nil
        }

        do {
            // Keep migration ordering identical to the rest of daemon startup.
            // A failed migration leaves the original file untouched; opening it
            // below preserves the existing daemon's non-bricking behavior.
            do {
                _ = try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(
                    at: databasePath,
                    logger: BurnBarDaemonLogger(category: "database-cipher")
                )
            } catch {
                logger.warning(
                    "linux_cloud_sync_database_migration_failed",
                    metadata: ["path": databasePath, "error": "\\(error)"]
                )
            }

            let identity = try LinuxIrohHostIdentityStore().loadOrCreate()
            let deviceID = "linux_" + PlatformCrypto.sha256Hex(identity.pairingKeypair.publicKeyRaw)
            let identityProvider: LinuxCloudSyncIdentityProvider = {
                try await credentialAuthority.credentialContext().uid
            }
            let credentials: FirebaseLinuxCloudReplicaCredentialProvider = {
                let context = try await credentialAuthority.credentialContext()
                return FirebaseLinuxCloudReplicaCredentials(
                    idToken: context.idToken,
                    appCheckToken: context.appCheckToken
                )
            }
            let gateway = FirebaseLinuxCloudReplicaGateway(credentials: credentials)
            let configStore = BurnBarConfigStore()
            let globalConsentProvider: LinuxCloudSyncConsentProvider = {
                // A malformed or unreadable config must not silently preserve
                // the prior cloud policy; fail closed until the user repairs it.
                (try? await configStore.snapshot().cloudSyncEnabled) ?? false
            }
            let vaultKeyProvider: LinuxCloudSyncVaultKeyProvider = {
                let custodian = LinuxSecretStoreFactory.production(environment: environment)
                let record = try custodian.requireHighValueSecret(
                    id: LinuxHighValueSecretClass.cloudVaultKey.rawValue,
                    secretClass: .cloudVaultKey
                )
                guard let key = Data(base64Encoded: record.secret), key.count == 32 else {
                    throw LinuxCloudReplicaEngine.EngineError.invalidVaultKey
                }
                return key
            }
            return try make(
                databasePath: databasePath,
                deviceID: deviceID,
                gateway: gateway,
                identityProvider: identityProvider,
                vaultKeyProvider: vaultKeyProvider,
                globalConsentProvider: globalConsentProvider
            )
        } catch {
            logger.warning(
                "linux_cloud_sync_runtime_unavailable",
                metadata: ["path": databasePath, "error": "\\(error)"]
            )
            return nil
        }
    }
    #endif

    private static func databaseConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.readonly = false
        configuration.busyMode = .timeout(5)
        if BurnBarDaemonDatabaseCipher.isCipherAvailable(),
           let key = BurnBarDaemonDatabaseCipher.validatedKeyForGRDB() {
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA key = '\(key)'")
                let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version")
                guard let cipherVersion, cipherVersion.isEmpty == false else {
                    throw BurnBarDaemonDatabaseCipherError.keyApplicationFailed(
                        detail: "PRAGMA cipher_version empty; SQLCipher codec not active on this handle"
                    )
                }
            }
        }
        return configuration
    }
}

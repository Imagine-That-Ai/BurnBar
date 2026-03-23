import BurnBarCore
import Foundation

public struct BurnBarResolvedProviderConfiguration: Sendable {
    public let provider: BurnBarCatalogProvider
    public let settings: BurnBarProviderSettings
    public let preferredModels: [BurnBarCatalogModel]
    public let apiKey: String?

    public var hasCredential: Bool {
        guard let apiKey else { return false }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public protocol BurnBarProviderSecretStoring: Sendable {
    func secret(for providerID: String) async throws -> String?
    func setSecret(_ secret: String?, for providerID: String) async throws
}

public actor BurnBarInMemorySecretStore: BurnBarProviderSecretStoring {
    private var secrets: [String: String]

    public init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public func secret(for providerID: String) async throws -> String? {
        secrets[providerID]
    }

    public func setSecret(_ secret: String?, for providerID: String) async throws {
        let normalized = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            secrets[providerID] = normalized
        } else {
            secrets.removeValue(forKey: providerID)
        }
    }
}

public enum BurnBarConfigStoreError: Error, LocalizedError {
    case unsupportedProvider(String)
    case invalidBaseURL(String)
    case unsupportedModel(providerID: String, modelID: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let providerID):
            return "Provider '\(providerID)' is not supported by BurnBar daemon routing."
        case .invalidBaseURL(let providerID):
            return "Provider '\(providerID)' must have a non-empty base URL."
        case .unsupportedModel(let providerID, let modelID):
            return "Model '\(modelID)' is not supported for provider '\(providerID)'."
        }
    }
}

public actor BurnBarConfigStore {
    private let fileURL: URL
    private let secretStore: any BurnBarProviderSecretStoring
    private let catalogSupport: BurnBarProviderCatalogSupport
    private let logger: BurnBarDaemonLogger
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var cachedSnapshot: BurnBarProviderConfigurationSnapshot?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultConfigStoreURL,
        catalog: BurnBarCatalog = BurnBarCatalogLoader.bundledCatalog,
        secretStore: any BurnBarProviderSecretStoring = BurnBarKeychainSecretStore(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "config-store")
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        self.catalogSupport = BurnBarProviderCatalogSupport(catalog: catalog)
        self.logger = logger
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func snapshot() throws -> BurnBarProviderConfigurationSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        let defaultSnapshot = try makeDefaultSnapshot()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedSnapshot = defaultSnapshot
            logger.debug(
                "config_defaults_loaded",
                metadata: ["file_path": fileURL.path]
            )
            return defaultSnapshot
        }

        let data = try Data(contentsOf: fileURL)
        let decodedSnapshot = try decoder.decode(BurnBarProviderConfigurationSnapshot.self, from: data)
        let normalizedSnapshot = try normalize(decodedSnapshot, defaults: defaultSnapshot)
        cachedSnapshot = normalizedSnapshot

        logger.debug(
            "config_loaded",
            metadata: [
                "file_path": fileURL.path,
                "provider_count": "\(normalizedSnapshot.providers.count)"
            ]
        )

        return normalizedSnapshot
    }

    @discardableResult
    public func replaceSnapshot(_ snapshot: BurnBarProviderConfigurationSnapshot) throws -> BurnBarProviderConfigurationSnapshot {
        let normalized = try normalize(snapshot, defaults: makeDefaultSnapshot())
        try persist(normalized)
        cachedSnapshot = normalized

        logger.notice(
            "config_replaced",
            metadata: [
                "file_path": fileURL.path,
                "provider_count": "\(normalized.providers.count)"
            ]
        )

        return normalized
    }

    @discardableResult
    public func upsertProvider(_ settings: BurnBarProviderSettings) throws -> BurnBarProviderSettings {
        let defaultSnapshot = try makeDefaultSnapshot()
        var snapshot = try snapshot()
        let normalizedSettings = try normalize(settings, defaults: defaultSnapshot)

        if let index = snapshot.providers.firstIndex(where: { $0.providerID == settings.providerID }) {
            snapshot.providers[index] = normalizedSettings
        } else {
            snapshot.providers.append(normalizedSettings)
        }

        snapshot = try normalize(snapshot, defaults: defaultSnapshot)
        try persist(snapshot)
        cachedSnapshot = snapshot

        logger.notice(
            "provider_config_updated",
            metadata: [
                "provider_id": settings.providerID,
                "enabled": "\(normalizedSettings.isEnabled)"
            ]
        )

        return normalizedSettings
    }

    public func setSecret(_ secret: String?, for providerID: String) async throws {
        guard BurnBarSupportedProvider.isSupported(providerID: providerID) else {
            throw BurnBarConfigStoreError.unsupportedProvider(providerID)
        }

        try await secretStore.setSecret(secret, for: providerID)
        logger.notice(
            "provider_secret_updated",
            metadata: [
                "provider_id": providerID,
                "has_secret": "\(!(secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))"
            ]
        )
    }

    public func resolvedConfigurations() async throws -> [BurnBarResolvedProviderConfiguration] {
        let orderedProviders = try snapshot().providers
            .sorted { catalogSupport.providerSortRank(providerID: $0.providerID) < catalogSupport.providerSortRank(providerID: $1.providerID) }

        var resolved: [BurnBarResolvedProviderConfiguration] = []
        resolved.reserveCapacity(orderedProviders.count)

        for settings in orderedProviders {
            let provider = try catalogSupport.requiredProvider(id: settings.providerID)
            let secret = try await secretStore.secret(for: settings.providerID)
            resolved.append(
                BurnBarResolvedProviderConfiguration(
                    provider: provider,
                    settings: settings,
                    preferredModels: catalogSupport.preferredModels(
                        providerID: settings.providerID,
                        preferredModelIDs: settings.preferredModelIDs
                    ),
                    apiKey: secret
                )
            )
        }

        return resolved
    }

    public func resolvedConfiguration(for providerID: String) async throws -> BurnBarResolvedProviderConfiguration {
        guard let configuration = try await resolvedConfigurations().first(where: { $0.provider.id == providerID }) else {
            throw BurnBarConfigStoreError.unsupportedProvider(providerID)
        }
        return configuration
    }

    private func normalize(
        _ snapshot: BurnBarProviderConfigurationSnapshot,
        defaults defaultSnapshot: BurnBarProviderConfigurationSnapshot
    ) throws -> BurnBarProviderConfigurationSnapshot {
        let providers = try BurnBarSupportedProvider.allCases.map { supportedProvider in
            let providerID = supportedProvider.rawValue
            let loadedSettings = snapshot.providerSettings(id: providerID)
            let defaultSettings = defaultSnapshot.providerSettings(id: providerID)!
            return try normalize(loadedSettings ?? defaultSettings, defaults: defaultSnapshot)
        }

        return BurnBarProviderConfigurationSnapshot(providers: providers)
    }

    private func normalize(
        _ settings: BurnBarProviderSettings,
        defaults defaultSnapshot: BurnBarProviderConfigurationSnapshot
    ) throws -> BurnBarProviderSettings {
        guard BurnBarSupportedProvider.isSupported(providerID: settings.providerID) else {
            throw BurnBarConfigStoreError.unsupportedProvider(settings.providerID)
        }

        guard !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BurnBarConfigStoreError.invalidBaseURL(settings.providerID)
        }

        for modelID in settings.preferredModelIDs {
            guard catalogSupport.supportsModelID(modelID, providerID: settings.providerID) else {
                throw BurnBarConfigStoreError.unsupportedModel(providerID: settings.providerID, modelID: modelID)
            }
        }

        let fallbackModels = defaultSnapshot.providerSettings(id: settings.providerID)?.preferredModelIDs ?? []
        let preferredModelIDs = settings.preferredModelIDs.isEmpty ? fallbackModels : settings.preferredModelIDs

        return BurnBarProviderSettings(
            providerID: settings.providerID,
            isEnabled: settings.isEnabled,
            baseURL: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredModelIDs: preferredModelIDs
        )
    }

    private func makeDefaultSnapshot() throws -> BurnBarProviderConfigurationSnapshot {
        let providers = try BurnBarSupportedProvider.allCases.map { providerID in
            let provider = try catalogSupport.requiredProvider(id: providerID.rawValue)
            return BurnBarProviderSettings(
                providerID: provider.id,
                isEnabled: false,
                baseURL: provider.baseURL,
                preferredModelIDs: catalogSupport.defaultModelIDs(forProviderID: provider.id)
            )
        }

        return BurnBarProviderConfigurationSnapshot(providers: providers)
    }

    private func persist(_ snapshot: BurnBarProviderConfigurationSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(underestimatedCount)

        for element in self {
            let value = try await transform(element)
            results.append(value)
        }

        return results
    }
}

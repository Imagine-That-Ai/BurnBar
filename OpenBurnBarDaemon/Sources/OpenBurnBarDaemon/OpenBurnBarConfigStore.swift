import OpenBurnBarCore
import Foundation

public struct BurnBarResolvedProviderConfiguration: Sendable {
    public struct ResolvedCredentialSlot: Sendable {
        public let slot: BurnBarProviderCredentialSlot
        public let apiKey: String?
    }

    public let provider: BurnBarCatalogProvider
    public let settings: BurnBarProviderSettings
    public let preferredModels: [BurnBarCatalogModel]
    public let credentialSlots: [ResolvedCredentialSlot]
    public let apiKey: String?

    public var hasCredential: Bool {
        if credentialSlots.contains(where: {
            guard let apiKey = $0.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !apiKey.isEmpty
        }) {
            return true
        }
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
    case missingCredential(providerID: String)
    case credentialReadbackFailed(providerID: String, slotID: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let providerID):
            return "Provider '\(providerID)' is not supported by OpenBurnBar daemon routing."
        case .invalidBaseURL(let providerID):
            return "Provider '\(providerID)' must have a non-empty base URL."
        case .unsupportedModel(let providerID, let modelID):
            return "Model '\(modelID)' is not supported for provider '\(providerID)'."
        case .missingCredential(let providerID):
            return "Provider '\(providerID)' needs a non-empty credential before it can be routed."
        case .credentialReadbackFailed(let providerID, let slotID):
            return "Provider '\(providerID)' credential slot '\(slotID)' was not readable after saving."
        }
    }
}

public actor BurnBarConfigStore {
    private let fileURL: URL
    private let secretStore: any BurnBarProviderSecretStoring
    let catalogSupport: BurnBarProviderCatalogSupport
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
        guard catalogSupport.isSupported(providerID: providerID) else {
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

    @discardableResult
    public func upsertCredentialSlot(
        providerID: String,
        slotID: String? = nil,
        label: String,
        apiKey: String,
        isEnabled: Bool = true
    ) async throws -> BurnBarProviderCredentialSlot {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard catalogSupport.isSupported(providerID: normalizedProviderID) else {
            throw BurnBarConfigStoreError.unsupportedProvider(normalizedProviderID)
        }

        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = normalizedLabel.isEmpty ? "Plan \(slotID ?? "")".trimmingCharacters(in: .whitespacesAndNewlines) : normalizedLabel
        let resolvedSlotID = (slotID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        guard key.isEmpty == false else {
            throw BurnBarConfigStoreError.missingCredential(providerID: normalizedProviderID)
        }

        let secretStoreKey = slotSecretStoreKey(providerID: normalizedProviderID, slotID: resolvedSlotID)
        try await secretStore.setSecret(key, for: secretStoreKey)
        guard let persistedKey = try await secretStore.secret(for: secretStoreKey),
              persistedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            try? await secretStore.setSecret(nil, for: secretStoreKey)
            throw BurnBarConfigStoreError.credentialReadbackFailed(
                providerID: normalizedProviderID,
                slotID: resolvedSlotID
            )
        }

        var updatedSlot = BurnBarProviderCredentialSlot(slotID: resolvedSlotID, label: resolvedLabel, isEnabled: isEnabled, status: isEnabled ? .ready : .disabled)
        let updatedSettings = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            mutable.isEnabled = true
            if let index = mutable.credentialSlots.firstIndex(where: { $0.slotID == resolvedSlotID }) {
                var existing = mutable.credentialSlots[index]
                existing.label = resolvedLabel
                existing.isEnabled = isEnabled
                existing.status = isEnabled ? .ready : .disabled
                existing.cooldownUntil = nil
                existing.lastStatusMessage = nil
                existing.updatedAt = Date()
                mutable.credentialSlots[index] = existing
                updatedSlot = existing
            } else {
                mutable.credentialSlots.append(updatedSlot)
            }
            if mutable.preferredCredentialSlotID == nil, isEnabled {
                mutable.preferredCredentialSlotID = resolvedSlotID
            }
            return mutable
        }

        logger.notice(
            "provider_slot_upserted",
            metadata: [
                "provider_id": normalizedProviderID,
                "slot_id": resolvedSlotID,
                "slots": "\(updatedSettings.credentialSlots.count)",
                "secret_readback": "true"
            ]
        )
        return updatedSlot
    }

    public func setCredentialSlotEnabled(
        providerID: String,
        slotID: String,
        isEnabled: Bool
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            guard let index = mutable.credentialSlots.firstIndex(where: { $0.slotID == slotID }) else {
                return mutable
            }
            var slot = mutable.credentialSlots[index]
            slot.isEnabled = isEnabled
            slot.status = isEnabled ? .ready : .disabled
            slot.updatedAt = Date()
            mutable.credentialSlots[index] = slot
            if mutable.preferredCredentialSlotID == slotID, isEnabled == false {
                mutable.preferredCredentialSlotID = mutable.credentialSlots.first(where: { $0.isEnabled })?.slotID
            }
            return mutable
        }
    }

    public func removeCredentialSlot(
        providerID: String,
        slotID: String
    ) async throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            mutable.credentialSlots.removeAll { $0.slotID == slotID }
            if mutable.preferredCredentialSlotID == slotID {
                mutable.preferredCredentialSlotID = mutable.credentialSlots.first(where: { $0.isEnabled })?.slotID
            }
            return mutable
        }
        try await secretStore.setSecret(nil, for: slotSecretStoreKey(providerID: normalizedProviderID, slotID: slotID))
    }

    public func setPreferredCredentialSlot(
        providerID: String,
        slotID: String?
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            if let slotID {
                guard mutable.credentialSlots.contains(where: { $0.slotID == slotID }) else {
                    return mutable
                }
                mutable.preferredCredentialSlotID = slotID
            } else {
                mutable.preferredCredentialSlotID = nil
            }
            return mutable
        }
    }

    public func setRouterMode(_ mode: ProviderRouterMode) throws {
        var currentSnapshot = try snapshot()
        currentSnapshot.routerMode = mode
        let normalizedSnapshot = try normalize(currentSnapshot, defaults: makeDefaultSnapshot())
        try persist(normalizedSnapshot)
        cachedSnapshot = normalizedSnapshot
        logger.notice(
            "router_mode_updated",
            metadata: ["router_mode": mode.rawValue]
        )
    }

    public func recordCredentialSelection(
        providerID: String,
        slotID: String
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            guard let index = mutable.credentialSlots.firstIndex(where: { $0.slotID == slotID }) else {
                return mutable
            }
            var slot = mutable.credentialSlots[index]
            slot.lastSelectedAt = Date()
            slot.updatedAt = Date()
            if slot.isEnabled {
                slot.status = .ready
            }
            mutable.credentialSlots[index] = slot
            return mutable
        }
    }

    public func updateCredentialSlotStatus(
        providerID: String,
        slotID: String,
        status: BurnBarProviderCredentialSlotStatus,
        cooldownUntil: Date?,
        message: String?
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            guard let index = mutable.credentialSlots.firstIndex(where: { $0.slotID == slotID }) else {
                return mutable
            }
            var slot = mutable.credentialSlots[index]
            slot.status = status
            slot.cooldownUntil = cooldownUntil
            slot.lastStatusMessage = message
            slot.updatedAt = Date()
            mutable.credentialSlots[index] = slot
            return mutable
        }
    }

    public func updateCredentialSlotQuota(
        providerID: String,
        slotID: String,
        remainingPercent: Double?,
        resetsAt: Date?,
        message: String?
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            guard let index = mutable.credentialSlots.firstIndex(where: { $0.slotID == slotID }) else {
                return mutable
            }
            var slot = mutable.credentialSlots[index]
            slot.lastQuotaRemainingPercent = remainingPercent
            slot.lastQuotaResetsAt = resetsAt
            slot.lastStatusMessage = message
            if slot.isEnabled {
                if let remainingPercent, remainingPercent <= 0 {
                    slot.status = .exhausted
                } else if let cooldownUntil = slot.cooldownUntil, cooldownUntil > Date() {
                    slot.status = .coolingDown
                } else {
                    slot.status = .ready
                    slot.cooldownUntil = nil
                }
            }
            slot.updatedAt = Date()
            mutable.credentialSlots[index] = slot
            return mutable
        }
    }

    public func resolvedConfigurations() async throws -> [BurnBarResolvedProviderConfiguration] {
        let orderedProviders = try snapshot().providers
            .sorted { catalogSupport.providerSortRank(providerID: $0.providerID) < catalogSupport.providerSortRank(providerID: $1.providerID) }

        var resolved: [BurnBarResolvedProviderConfiguration] = []
        resolved.reserveCapacity(orderedProviders.count)

        for settings in orderedProviders {
            let provider = try catalogSupport.requiredProvider(id: settings.providerID)
            var mutableSettings = settings
            let legacySecret = mutableSettings.credentialSlots.isEmpty
                ? try await secretStore.secret(for: settings.providerID)
                : nil
            if mutableSettings.credentialSlots.isEmpty,
               let legacySecret,
               legacySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                let migratedSlot = BurnBarProviderCredentialSlot(
                    slotID: "default",
                    label: "Default plan",
                    isEnabled: true,
                    status: .ready
                )
                mutableSettings.credentialSlots = [migratedSlot]
                mutableSettings.preferredCredentialSlotID = migratedSlot.slotID
                _ = try upsertProvider(mutableSettings)
                try await secretStore.setSecret(legacySecret, for: slotSecretStoreKey(providerID: settings.providerID, slotID: migratedSlot.slotID))
            }

            var resolvedSlots: [BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot] = []
            resolvedSlots.reserveCapacity(mutableSettings.credentialSlots.count)
            for slot in mutableSettings.credentialSlots {
                let key = try await secretStore.secret(for: slotSecretStoreKey(providerID: settings.providerID, slotID: slot.slotID))
                resolvedSlots.append(.init(slot: slot, apiKey: key))
            }

            let selectedKey = selectPreferredAPIKey(
                settings: mutableSettings,
                resolvedSlots: resolvedSlots,
                legacySecret: legacySecret
            )
            resolved.append(
                BurnBarResolvedProviderConfiguration(
                    provider: provider,
                    settings: mutableSettings,
                    preferredModels: catalogSupport.preferredModels(
                        providerID: mutableSettings.providerID,
                        preferredModelIDs: mutableSettings.preferredModelIDs
                    ),
                    credentialSlots: resolvedSlots,
                    apiKey: selectedKey
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

    private func slotSecretStoreKey(providerID: String, slotID: String) -> String {
        "\(providerID).slot.\(slotID)"
    }

    private func mutateProviderSettings(
        providerID: String,
        mutate: (BurnBarProviderSettings) -> BurnBarProviderSettings
    ) throws -> BurnBarProviderSettings {
        guard catalogSupport.isSupported(providerID: providerID) else {
            throw BurnBarConfigStoreError.unsupportedProvider(providerID)
        }

        var currentSnapshot = try snapshot()
        guard let index = currentSnapshot.providers.firstIndex(where: { $0.providerID == providerID }) else {
            throw BurnBarConfigStoreError.unsupportedProvider(providerID)
        }

        let mutatedSettings = mutate(currentSnapshot.providers[index])
        let normalizedSettings = try normalize(mutatedSettings, defaults: makeDefaultSnapshot())
        currentSnapshot.providers[index] = normalizedSettings
        let normalizedSnapshot = try normalize(currentSnapshot, defaults: makeDefaultSnapshot())
        try persist(normalizedSnapshot)
        cachedSnapshot = normalizedSnapshot
        return normalizedSettings
    }

    private func selectPreferredAPIKey(
        settings: BurnBarProviderSettings,
        resolvedSlots: [BurnBarResolvedProviderConfiguration.ResolvedCredentialSlot],
        legacySecret: String?
    ) -> String? {
        let activeSlots = resolvedSlots.filter { resolved in
            guard resolved.slot.isEnabled else { return false }
            guard let key = resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return false
            }
            if let cooldown = resolved.slot.cooldownUntil, cooldown > Date() {
                return false
            }
            return resolved.slot.status != .exhausted
                && resolved.slot.status != .missingSecret
                && resolved.slot.status != .disabled
        }

        if let preferredSlotID = settings.preferredCredentialSlotID,
           let preferred = activeSlots.first(where: { $0.slot.slotID == preferredSlotID }) {
            return preferred.apiKey
        }

        if let next = activeSlots.sorted(by: {
            ($0.slot.lastSelectedAt ?? .distantPast) < ($1.slot.lastSelectedAt ?? .distantPast)
        }).first {
            return next.apiKey
        }

        if let legacySecret,
           !legacySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return legacySecret
        }
        return nil
    }

    private func normalize(
        _ snapshot: BurnBarProviderConfigurationSnapshot,
        defaults defaultSnapshot: BurnBarProviderConfigurationSnapshot
    ) throws -> BurnBarProviderConfigurationSnapshot {
        let providers = try catalogSupport.supportedProviderIDs.map { providerID in
            let loadedSettings = snapshot.providerSettings(id: providerID)
            let defaultSettings = defaultSnapshot.providerSettings(id: providerID)!
            return try normalize(loadedSettings ?? defaultSettings, defaults: defaultSnapshot)
        }

        return BurnBarProviderConfigurationSnapshot(
            providers: providers,
            routerMode: snapshot.routerMode
        )
    }

    private func normalize(
        _ settings: BurnBarProviderSettings,
        defaults defaultSnapshot: BurnBarProviderConfigurationSnapshot
    ) throws -> BurnBarProviderSettings {
        guard catalogSupport.isSupported(providerID: settings.providerID) else {
            throw BurnBarConfigStoreError.unsupportedProvider(settings.providerID)
        }

        // Only routing-capable providers require a non-empty base URL.
        // Accounting-only providers (like "misc") may have an empty base URL.
        if catalogSupport.supportsRouting(providerID: settings.providerID) {
            guard !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BurnBarConfigStoreError.invalidBaseURL(settings.providerID)
            }
        }

        for modelID in settings.preferredModelIDs {
            guard catalogSupport.supportsModelID(modelID, providerID: settings.providerID) else {
                throw BurnBarConfigStoreError.unsupportedModel(providerID: settings.providerID, modelID: modelID)
            }
        }

        let fallbackModels = defaultSnapshot.providerSettings(id: settings.providerID)?.preferredModelIDs ?? []
        let preferredModelIDs = settings.preferredModelIDs.isEmpty ? fallbackModels : settings.preferredModelIDs
        let normalizedSlots = settings.credentialSlots.map { slot in
            BurnBarProviderCredentialSlot(
                slotID: slot.slotID.trimmingCharacters(in: .whitespacesAndNewlines),
                label: slot.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Plan" : slot.label.trimmingCharacters(in: .whitespacesAndNewlines),
                isEnabled: slot.isEnabled,
                status: slot.isEnabled ? (slot.status == .disabled ? .ready : slot.status) : .disabled,
                cooldownUntil: slot.cooldownUntil,
                lastSelectedAt: slot.lastSelectedAt,
                lastQuotaRemainingPercent: slot.lastQuotaRemainingPercent,
                lastQuotaResetsAt: slot.lastQuotaResetsAt,
                lastStatusMessage: slot.lastStatusMessage,
                updatedAt: slot.updatedAt
            )
        }.filter { !$0.slotID.isEmpty }

        let preferredSlotID: String? = {
            guard let preferred = settings.preferredCredentialSlotID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !preferred.isEmpty,
                  normalizedSlots.contains(where: { $0.slotID == preferred }) else {
                return nil
            }
            return preferred
        }()

        return BurnBarProviderSettings(
            providerID: settings.providerID,
            isEnabled: settings.isEnabled,
            baseURL: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredModelIDs: preferredModelIDs,
            preferredCredentialSlotID: preferredSlotID,
            credentialSlots: normalizedSlots
        )
    }

    private func makeDefaultSnapshot() throws -> BurnBarProviderConfigurationSnapshot {
        let providers = try catalogSupport.supportedProviderIDs.map { providerID in
            let provider = try catalogSupport.requiredProvider(id: providerID)
            return BurnBarProviderSettings(
                providerID: provider.id,
                isEnabled: false,
                baseURL: provider.baseURL,
                preferredModelIDs: catalogSupport.defaultModelIDs(forProviderID: provider.id)
            )
        }

        return BurnBarProviderConfigurationSnapshot(
            providers: providers,
            routerMode: .providerFamilyFailover
        )
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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

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
    case invalidModelAliasID(String)
    case duplicateModelAlias(aliasID: String)
    case modelAliasConflictsWithVariant(aliasID: String)
    case modelAliasConflictsWithCatalogModel(aliasID: String, baseModelID: String)

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
        case .invalidModelAliasID(let aliasID):
            return "Model alias '\(aliasID)' is invalid. Use letters, numbers, and . _ - : / only."
        case .duplicateModelAlias(let aliasID):
            return "Model alias '\(aliasID)' is already in use."
        case .modelAliasConflictsWithVariant(let aliasID):
            return "Model alias '\(aliasID)' conflicts with an existing thinking-level variant."
        case .modelAliasConflictsWithCatalogModel(let aliasID, let baseModelID):
            return "Model alias '\(aliasID)' conflicts with a catalog model and cannot route to '\(baseModelID)'."
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
        isEnabled: Bool = true,
        endpointProfileID: String? = nil,
        region: ProviderEndpointRegion? = nil,
        tokenPlanTier: MimoTokenPlanTier? = nil,
        tokenPlanBillingCycle: MimoTokenPlanBillingCycle? = nil,
        authMethodID: String? = nil
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
        let resolvedProfile = ProviderEndpointProfileRegistry.resolveProfileID(
            providerID: ProviderID(rawValue: normalizedProviderID),
            apiKey: key,
            explicitProfileID: endpointProfileID,
            region: region
        )
        if let resolvedProfile {
            updatedSlot.endpointProfileID = resolvedProfile.id
            updatedSlot.region = resolvedProfile.region == .global ? region : resolvedProfile.region
            updatedSlot.authMethodID = authMethodID ?? resolvedProfile.authMethodID
        } else if let endpointProfileID {
            updatedSlot.endpointProfileID = endpointProfileID
            updatedSlot.region = region
            updatedSlot.authMethodID = authMethodID
        }
        if let tokenPlanTier {
            updatedSlot.tokenPlanTier = tokenPlanTier
        }
        if let tokenPlanBillingCycle {
            updatedSlot.tokenPlanBillingCycle = tokenPlanBillingCycle
        }

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
                if let resolvedProfile {
                    existing.endpointProfileID = resolvedProfile.id
                    existing.region = resolvedProfile.region == .global ? region : resolvedProfile.region
                    existing.authMethodID = authMethodID ?? resolvedProfile.authMethodID
                } else if let endpointProfileID {
                    existing.endpointProfileID = endpointProfileID
                    existing.region = region
                    existing.authMethodID = authMethodID
                }
                if let tokenPlanTier {
                    existing.tokenPlanTier = tokenPlanTier
                }
                if let tokenPlanBillingCycle {
                    existing.tokenPlanBillingCycle = tokenPlanBillingCycle
                }
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

    @discardableResult
    public func upsertModelVariant(
        providerID: String,
        variant: BurnBarModelVariant
    ) throws -> BurnBarModelVariant {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedVariant = BurnBarModelVariant(
            variantID: variant.variantID.trimmingCharacters(in: .whitespacesAndNewlines),
            label: variant.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? BurnBarModelVariant.defaultLabel(for: variant.thinkingLevel)
                : variant.label.trimmingCharacters(in: .whitespacesAndNewlines),
            baseModelID: variant.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            thinkingLevel: variant.thinkingLevel,
            maxOutputTokens: variant.maxOutputTokens,
            createdAt: variant.createdAt,
            updatedAt: Date()
        )

        guard !normalizedVariant.variantID.isEmpty else {
            throw BurnBarConfigStoreError.invalidBaseURL(normalizedProviderID)
        }
        guard !normalizedVariant.baseModelID.isEmpty,
              catalogSupport.supportsModelID(normalizedVariant.baseModelID, providerID: normalizedProviderID) else {
            throw BurnBarConfigStoreError.unsupportedModel(
                providerID: normalizedProviderID,
                modelID: normalizedVariant.baseModelID
            )
        }

        let updated = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            mutable.upsertModelVariant(normalizedVariant)
            return mutable
        }
        return updated.modelVariants.first(where: { $0.variantID == normalizedVariant.variantID }) ?? normalizedVariant
    }

    public func removeModelVariant(
        providerID: String,
        variantID: String
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            _ = mutable.removeModelVariant(variantID: variantID)
            return mutable
        }
    }

    @discardableResult
    public func upsertModelAlias(
        providerID: String,
        alias: BurnBarModelAlias
    ) throws -> BurnBarModelAlias {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAlias = BurnBarModelAlias(
            aliasID: alias.aliasID.trimmingCharacters(in: .whitespacesAndNewlines),
            baseModelID: alias.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: BurnBarModelAlias.normalizedDisplayName(
                aliasID: alias.aliasID,
                displayName: alias.displayName
            ),
            hidesBaseModel: alias.hidesBaseModel,
            createdAt: alias.createdAt,
            updatedAt: Date()
        )

        guard BurnBarModelAlias.isValidAliasID(normalizedAlias.aliasID) else {
            throw BurnBarConfigStoreError.invalidModelAliasID(normalizedAlias.aliasID)
        }
        guard !normalizedAlias.baseModelID.isEmpty,
              normalizedAlias.aliasID.caseInsensitiveCompare(normalizedAlias.baseModelID) != .orderedSame,
              catalogSupport.supportsModelID(normalizedAlias.baseModelID, providerID: normalizedProviderID) else {
            throw BurnBarConfigStoreError.unsupportedModel(
                providerID: normalizedProviderID,
                modelID: normalizedAlias.baseModelID
            )
        }

        let snapshot = try snapshot()
        try validateModelAlias(normalizedAlias, providerID: normalizedProviderID, snapshot: snapshot)

        let updated = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            mutable.upsertModelAlias(normalizedAlias)
            return mutable
        }
        return updated.modelAliases.first(where: {
            $0.aliasID.caseInsensitiveCompare(normalizedAlias.aliasID) == .orderedSame
        }) ?? normalizedAlias
    }

    public func removeModelAlias(
        providerID: String,
        aliasID: String
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try mutateProviderSettings(providerID: normalizedProviderID) { settings in
            var mutable = settings
            _ = mutable.removeModelAlias(aliasID: aliasID)
            return mutable
        }
    }

    /// Seed default thinking-level variants for known reasoning-capable models
    /// the first time the daemon boots after this feature ships. Idempotent —
    /// re-seeding never runs once the marker file exists. The seed only touches
    /// providers that are already configured; providers added later get their
    /// defaults the next time the daemon boots after the user enables them.
    public func seedDefaultModelVariantsIfNeeded(
        markerURL: URL? = nil,
        now: Date = Date()
    ) throws {
        let resolvedMarkerURL = markerURL ?? fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("model-variants-seed.v1")
        if FileManager.default.fileExists(atPath: resolvedMarkerURL.path) {
            return
        }

        let defaults: [(providerID: String, baseModelID: String, levels: [BurnBarThinkingLevel])] = [
            ("anthropic", "claude-opus-4-8", [.high, .xhigh, .max]),
            ("openai", "gpt-5.3-codex", [.low, .medium, .high, .xhigh])
        ]

        var didMutate = false
        for entry in defaults {
            guard catalogSupport.isSupported(providerID: entry.providerID),
                  catalogSupport.supportsModelID(entry.baseModelID, providerID: entry.providerID) else {
                continue
            }
            for level in entry.levels {
                let variantID = BurnBarModelVariant.defaultVariantID(
                    baseModelID: entry.baseModelID,
                    level: level
                )
                let variant = BurnBarModelVariant(
                    variantID: variantID,
                    label: BurnBarModelVariant.defaultLabel(for: level),
                    baseModelID: entry.baseModelID,
                    thinkingLevel: level,
                    maxOutputTokens: nil,
                    createdAt: now,
                    updatedAt: now
                )
                _ = try? mutateProviderSettings(providerID: entry.providerID) { settings in
                    var mutable = settings
                    guard !mutable.modelVariants.contains(where: { $0.variantID.caseInsensitiveCompare(variantID) == .orderedSame }) else {
                        return mutable
                    }
                    mutable.upsertModelVariant(variant)
                    didMutate = true
                    return mutable
                }
            }
        }

        let directoryURL = resolvedMarkerURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? Data("seeded".utf8).write(to: resolvedMarkerURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: resolvedMarkerURL.path
        )

        if didMutate {
            logger.notice(
                "default_model_variants_seeded",
                metadata: ["marker_path": resolvedMarkerURL.path]
            )
        }
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
            guard let key = resolved.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return false
            }
            return BurnBarProviderCredentialSlotRoutingPolicy.canAttemptRoute(
                slot: resolved.slot,
                hasCredential: true,
                providerEnabled: settings.isEnabled
            )
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
                endpointProfileID: slot.endpointProfileID,
                region: slot.region,
                tokenPlanTier: slot.tokenPlanTier,
                tokenPlanBillingCycle: slot.tokenPlanBillingCycle,
                authMethodID: slot.authMethodID,
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

        let normalizedBaseURL = normalizedBaseURL(
            providerID: settings.providerID,
            rawBaseURL: settings.baseURL
        )

        if catalogSupport.supportsRouting(providerID: settings.providerID) {
            let trimmedBase = normalizedBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let scheme = URL(string: trimmedBase)?.scheme?.lowercased() {
                let blockedSchemes: Set<String> = ["file", "javascript", "data"]
                if blockedSchemes.contains(scheme) {
                    throw BurnBarConfigStoreError.invalidBaseURL(settings.providerID)
                }
                if scheme == "http" || scheme == "https" {
                    do {
                        _ = try BurnBarProviderExecutorError.validatedProviderBaseURL(trimmedBase)
                    } catch {
                        throw BurnBarConfigStoreError.invalidBaseURL(settings.providerID)
                    }
                }
            } else if trimmedBase.isEmpty == false {
                throw BurnBarConfigStoreError.invalidBaseURL(settings.providerID)
            }
        }

        let supportedVariants = settings.modelVariants.filter { variant in
            catalogSupport.supportsModelID(variant.baseModelID, providerID: settings.providerID)
        }
        let supportedAliases = settings.modelAliases.filter { alias in
            catalogSupport.supportsModelID(alias.baseModelID, providerID: settings.providerID)
        }

        return BurnBarProviderSettings(
            providerID: settings.providerID,
            isEnabled: settings.isEnabled,
            baseURL: normalizedBaseURL,
            preferredModelIDs: preferredModelIDs,
            disabledAdvertisedModelIDs: settings.disabledAdvertisedModelIDs,
            preferredCredentialSlotID: preferredSlotID,
            credentialSlots: normalizedSlots,
            modelVariants: supportedVariants,
            modelAliases: supportedAliases
        )
    }

    private func validateModelAlias(
        _ alias: BurnBarModelAlias,
        providerID: String,
        snapshot: BurnBarProviderConfigurationSnapshot
    ) throws {
        let normalizedAliasID = alias.aliasID.lowercased()
        for provider in snapshot.providers {
            if provider.modelVariants.contains(where: {
                $0.variantID.caseInsensitiveCompare(alias.aliasID) == .orderedSame
            }) {
                throw BurnBarConfigStoreError.modelAliasConflictsWithVariant(aliasID: alias.aliasID)
            }
            if provider.modelAliases.contains(where: {
                $0.aliasID.caseInsensitiveCompare(alias.aliasID) == .orderedSame
                    && provider.providerID.caseInsensitiveCompare(providerID) != .orderedSame
            }) {
                throw BurnBarConfigStoreError.duplicateModelAlias(aliasID: alias.aliasID)
            }
        }

        if let catalogModel = catalogSupport.exactCatalogModel(id: alias.aliasID, providerID: providerID) {
            let catalogBase = catalogModel.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let requestedBase = alias.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let aliasMatchesBase = catalogModel.aliases.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == requestedBase
            }
            if catalogBase != requestedBase, !aliasMatchesBase {
                throw BurnBarConfigStoreError.modelAliasConflictsWithCatalogModel(
                    aliasID: alias.aliasID,
                    baseModelID: alias.baseModelID
                )
            }
        }
    }

    private func normalizedBaseURL(providerID: String, rawBaseURL: String) -> String {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerID.caseInsensitiveCompare("opencode") == .orderedSame,
              var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              host == "opencode.ai" || host.hasSuffix(".opencode.ai") else {
            return trimmed
        }

        let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return catalogSupport.provider(id: "opencode")?.baseURL ?? trimmed
        }
        if path.caseInsensitiveCompare("zen/go") == .orderedSame {
            components.percentEncodedPath = "/zen/go/v1"
            return components.string ?? trimmed
        }
        return trimmed
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

import OpenBurnBarEngine
import Foundation

extension BurnBarConfigStore {
    func normalize(
        _ settings: BurnBarProviderSettings,
        defaults defaultSnapshot: BurnBarProviderConfigurationSnapshot,
        unsupportedPreferredModels: UnsupportedPreferredModelHandling = .prune
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

        let configuredPreferredModelIDs: [String]
        switch unsupportedPreferredModels {
        case .reject:
            for modelID in settings.preferredModelIDs {
                guard catalogSupport.supportsModelID(modelID, providerID: settings.providerID) else {
                    throw BurnBarConfigStoreError.unsupportedModel(providerID: settings.providerID, modelID: modelID)
                }
            }
            configuredPreferredModelIDs = settings.preferredModelIDs
        case .prune:
            configuredPreferredModelIDs = settings.preferredModelIDs.filter {
                catalogSupport.supportsModelID($0, providerID: settings.providerID)
            }
        }

        let fallbackModels = defaultSnapshot.providerSettings(id: settings.providerID)?.preferredModelIDs ?? []
        let preferredModelIDs = Self.mergedPreferredModelIDs(
            configured: configuredPreferredModelIDs,
            defaults: fallbackModels
        )
        var normalizedSlots = settings.credentialSlots.map { slot in
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

        let normalizedBaseURL = normalizedBaseURL(
            providerID: settings.providerID,
            rawBaseURL: settings.baseURL
        )
        var endpointSettings = settings
        endpointSettings.baseURL = normalizedBaseURL
        let normalizedOllamaEndpoints = try normalizedOllamaEndpoints(
            settings: endpointSettings
        )
        if isOllamaLocalProvider(settings.providerID) {
            normalizedSlots = Self.mergingOllamaEndpointSlots(
                existingSlots: normalizedSlots,
                endpoints: normalizedOllamaEndpoints
            )
        }

        let preferredSlotID: String? = {
            guard let preferred = settings.preferredCredentialSlotID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !preferred.isEmpty,
                  normalizedSlots.contains(where: { $0.slotID == preferred }) else {
                return nil
            }
            return preferred
        }()

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
        let modelVariants = Self.mergedDefaultModelVariants(
            configured: supportedVariants,
            providerID: settings.providerID,
            catalogSupport: catalogSupport
        )
        let supportedAliases = settings.modelAliases.filter { alias in
            catalogSupport.supportsModelID(alias.baseModelID, providerID: settings.providerID)
        }
        let supportedCustomModels: [BurnBarCustomModel]
        switch unsupportedPreferredModels {
        case .reject:
            for customModel in settings.customModels {
                guard catalogSupport.modelID(customModel.modelID, isNamespaceSafeFor: settings.providerID) else {
                    throw BurnBarConfigStoreError.unsupportedModel(
                        providerID: settings.providerID,
                        modelID: customModel.modelID
                    )
                }
            }
            supportedCustomModels = settings.customModels
        case .prune:
            supportedCustomModels = settings.customModels.filter {
                catalogSupport.modelID($0.modelID, isNamespaceSafeFor: settings.providerID)
            }
        }

        return BurnBarProviderSettings(
            providerID: settings.providerID,
            isEnabled: settings.isEnabled,
            baseURL: normalizedBaseURL,
            preferredModelIDs: preferredModelIDs,
            disabledAdvertisedModelIDs: settings.disabledAdvertisedModelIDs,
            preferredCredentialSlotID: preferredSlotID,
            credentialSlots: normalizedSlots,
            ollamaEndpoints: normalizedOllamaEndpoints,
            modelVariants: modelVariants,
            modelAliases: supportedAliases,
            modelDisplayOverrides: settings.modelDisplayOverrides,
            customModels: supportedCustomModels
        )
    }

    private func normalizedOllamaEndpoints(
        settings: BurnBarProviderSettings
    ) throws -> [BurnBarOllamaEndpointConfig] {
        guard isOllamaLocalProvider(settings.providerID) else {
            return []
        }

        do {
            return try BurnBarOllamaEndpointConfig.normalizedList(settings.ollamaEndpoints)
        } catch BurnBarOllamaEndpointConfig.ValidationError.invalidBaseURL(_) {
            throw BurnBarConfigStoreError.invalidBaseURL(settings.providerID)
        } catch {
            throw error
        }
    }

    static func mergingOllamaEndpointSlots(
        existingSlots: [BurnBarProviderCredentialSlot],
        endpoints: [BurnBarOllamaEndpointConfig]
    ) -> [BurnBarProviderCredentialSlot] {
        var existingByID: [String: BurnBarProviderCredentialSlot] = [:]
        for slot in existingSlots {
            existingByID[slot.slotID] = slot
        }

        return endpoints.map { endpoint in
            var slot = existingByID[endpoint.id] ?? BurnBarProviderCredentialSlot(
                slotID: endpoint.id,
                label: endpoint.label,
                isEnabled: endpoint.enabled,
                status: endpoint.enabled ? .ready : .disabled
            )
            slot.label = endpoint.label
            slot.isEnabled = endpoint.enabled
            slot.endpointProfileID = nil
            slot.authMethodID = nil
            if endpoint.enabled {
                if slot.status == .disabled || slot.status == .missingSecret {
                    slot.status = .ready
                    slot.cooldownUntil = nil
                    slot.lastStatusMessage = nil
                }
            } else {
                slot.status = .disabled
                slot.cooldownUntil = nil
                slot.lastStatusMessage = nil
            }
            return slot
        }
    }

    static func ollamaEndpoint(
        slotID: String,
        settings: BurnBarProviderSettings
    ) -> BurnBarOllamaEndpointConfig? {
        guard isOllamaLocalProvider(settings.providerID) else { return nil }
        return settings.ollamaEndpoints.first { $0.id == slotID }
    }

    static func isOllamaLocalProvider(_ providerID: String) -> Bool {
        providerID.caseInsensitiveCompare("ollama-local") == .orderedSame
    }

    func isOllamaLocalProvider(_ providerID: String) -> Bool {
        Self.isOllamaLocalProvider(providerID)
    }

    static let defaultModelVariantSeeds: [(providerID: String, baseModelID: String, levels: [BurnBarThinkingLevel])] = [
        ("anthropic", "claude-opus-4-8", [.high, .xhigh, .max]),
        ("openai", "gpt-5.3-codex", [.low, .medium, .high, .xhigh]),
        ("meta", "muse-spark-1.2-contributor", [.xhigh]),
        ("prime-agent", "muse-spark-1.2-contributor", [.xhigh])
    ]

    private static func mergedPreferredModelIDs(configured: [String], defaults: [String]) -> [String] {
        guard configured.isEmpty == false else { return defaults }

        var seen = Set(configured.map { $0.lowercased() })
        var merged = configured
        for modelID in defaults where seen.insert(modelID.lowercased()).inserted {
            merged.append(modelID)
        }
        return merged
    }

    private static func mergedDefaultModelVariants(
        configured: [BurnBarModelVariant],
        providerID: String,
        catalogSupport: BurnBarProviderCatalogSupport
    ) -> [BurnBarModelVariant] {
        var variants = configured
        var seen = Set(configured.map { $0.variantID.lowercased() })

        for entry in defaultModelVariantSeeds where entry.providerID.caseInsensitiveCompare(providerID) == .orderedSame {
            guard catalogSupport.supportsModelID(entry.baseModelID, providerID: providerID) else {
                continue
            }
            for level in entry.levels {
                let variantID = BurnBarModelVariant.defaultVariantID(
                    baseModelID: entry.baseModelID,
                    level: level
                )
                guard seen.insert(variantID.lowercased()).inserted else {
                    continue
                }
                variants.append(BurnBarModelVariant(
                    variantID: variantID,
                    label: BurnBarModelVariant.defaultLabel(for: level),
                    baseModelID: entry.baseModelID,
                    thinkingLevel: level
                ))
            }
        }

        return variants
    }

    func validateModelAlias(
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
}

import Foundation
import os
import OpenBurnBarCore

extension ProviderQuotaService {
    internal func makeContext(  // pure-move: was private
        apiKeyOverrides: [AgentProvider: String] = [:]
    ) -> ProviderQuotaAdapterContext {
        var resolvedKeys: [String: String?] = [:]
        for provider in Self.supportedProviders {
            let resolvedValue: String?
            if let override = apiKeyOverrides[provider] {
                resolvedValue = override
            } else {
                resolvedValue = providerQuotaAPIKey(for: provider)
            }

            for identifier in quotaKeyIdentifiers(for: provider) {
                resolvedKeys[identifier] = resolvedValue
            }
        }
        resolvedKeys["cursor_cookie"] = keyStore.apiKey(for: "cursor_cookie")
        for identifier in ["factory_cookie_header", "factory_cookie", "ollama_cookie_header", "ollama_cookie", "kimi_auth_token"] {
            resolvedKeys[identifier] = keyStore.apiKey(for: identifier)
        }

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxMode: miniMaxModeProvider(),
            factoryPlan: factoryPlanProvider(),
            xaiPlan: xaiPlanProvider(),
            mimoTokenPlanRegion: mimoTokenPlanRegionProvider(),
            mimoTokenPlanTier: mimoTokenPlanTierProvider(),
            mimoTokenPlanBillingCycle: mimoTokenPlanBillingCycleProvider(),
            codexRolloutScanCache: codexRolloutScanCacheBox.read(),
            updateCodexRolloutScanCache: { [codexCacheBox = codexRolloutScanCacheBox, store = snapshotStore] cache, didChange in
                codexCacheBox.write(cache)
                if didChange {
                    store.persistCodexRolloutScanCache(cache)
                }
            },
            claudeCredentialsReader: claudeCredentialsReader,
            resolvedAPIKeys: resolvedKeys
        )
    }

    internal func makeSwitcherProfileFetcher(dataStore: DataStore) -> ProviderQuotaSwitcherProfileFetcher {  // pure-move: was private
        { [weak dataStore] in
            guard let dataStore else { return [] }
            do {
                return try await dataStore.fetchSwitcherProfilesForQuota()
            } catch {
                return []
            }
        }
    }

    private func providerQuotaAPIKey(for provider: AgentProvider) -> String? {
        for identifier in quotaKeyIdentifiers(for: provider) {
            if let value = quotaNonEmpty(keyStore.apiKey(for: identifier)) {
                return value
            }
        }
        return daemonPlanAPIKey(for: provider)
    }

    private func daemonPlanAPIKey(for provider: AgentProvider) -> String? {
        guard let providerID = daemonProviderID(for: provider) else { return nil }
        guard let configuration = OpenBurnBarDaemonManager.shared.providerConfigurations.first(
            where: { $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame }
        ) else {
            return nil
        }

        let preferredSlot = configuration.preferredCredentialSlotID.flatMap { preferredID in
            configuration.credentialSlots.first(where: { $0.slotID == preferredID })
        }

        var orderedSlots: [OpenBurnBarDaemonProviderConfiguration.CredentialSlot] = []
        if let preferredSlot {
            orderedSlots.append(preferredSlot)
        }
        orderedSlots.append(
            contentsOf: configuration.credentialSlots.filter { slot in
                slot.slotID != preferredSlot?.slotID && slot.isEnabled
            }
        )
        orderedSlots.append(
            contentsOf: configuration.credentialSlots.filter { slot in
                slot.slotID != preferredSlot?.slotID && !slot.isEnabled
            }
        )

        for slot in orderedSlots {
            let account = "provider.\(providerID).slot.\(slot.slotID).apiKey"
            if let key = providerRuntimeKeyStore.credentialIfPresent(
                for: account,
                allowUserInteraction: false,
                event: "daemon_plan_api_key_read_failed"
            ),
               let normalized = quotaNonEmpty(key) {
                return normalized
            }
        }
        return nil
    }

    private func daemonProviderID(for provider: AgentProvider) -> String? {
        switch provider {
        case .minimax:
            return "minimax"
        case .zai:
            return "zai"
        case .ollama:
            return "ollama"
        case .openCode:
            return "opencode"
        case .deepSeek:
            return "deepseek"
        case .kimi:
            return "moonshot"
        case .claudeCode:
            return "anthropic"
        case .mimo:
            return "mimo"
        default:
            return nil
        }
    }

    private func quotaKeyIdentifiers(for provider: AgentProvider) -> [String] {
        let rawValue = provider.rawValue
        let lowercased = rawValue.lowercased()
        let collapsed = lowercased.replacingOccurrences(of: " ", with: "")
        let snakeCased = lowercased.replacingOccurrences(of: " ", with: "_")

        var identifiers = [rawValue, lowercased, collapsed, snakeCased]

        switch provider {
        case .minimax:
            identifiers.append("minimax")
        case .zai:
            identifiers.append(contentsOf: ["zai", "z_ai"])
        case .kimi:
            identifiers.append("kimi_auth_token")
        case .openCode:
            identifiers.append(contentsOf: ["opencode", "open_code", "opencode_auth_json"])
        case .deepSeek:
            identifiers.append(contentsOf: ["deepseek", "deep_seek"])
        case .mimo:
            identifiers.append(contentsOf: ["mimo", "xiaomimimo", "xiaomi", "provider.mimo.apiKey"])
        default:
            break
        }

        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    internal func quotaProvider(forKeyIdentifier key: String) -> AgentProvider? {  // pure-move: was private
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        for provider in Self.supportedProviders where quotaKeyIdentifiers(for: provider).contains(normalized) {
            return provider
        }
        switch normalized {
        case "cursor_cookie":
            return .cursor
        case "factory_cookie_header", "factory_cookie":
            return .factory
        case "ollama_cookie_header", "ollama_cookie":
            return .ollama
        case "kimi_auth_token":
            return .kimi
        default:
            return nil
        }
    }

}

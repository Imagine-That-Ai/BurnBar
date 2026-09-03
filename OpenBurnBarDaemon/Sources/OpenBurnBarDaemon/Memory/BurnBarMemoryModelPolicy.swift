import Foundation
import OpenBurnBarEngine

/// Assembles the `daemon.memory.model_policy` response from daemon state:
/// the offline membership cache (Pro), the memory egress policy the app
/// wrote into the config store, and the provider catalog (model defaults).
/// Mints a scoped gateway token only when the policy is usable.
enum BurnBarMemoryModelPolicy {
    static let proRequiredCode = "PRO_REQUIRED"
    static let consentRequiredCode = "CLOUD_CONSENT_REQUIRED"

    /// Data-retention class the daemon can assert per provider. OpenRouter
    /// requests carry `provider.data_collection = "deny"` (Task 2); the others
    /// run under the vendor's published policy.
    static func retentionClass(providerID: String) -> String {
        switch providerID {
        case "openrouter":
            return "deny"
        case "vercel-ai-gateway", "anthropic", "openai":
            return "provider-policy"
        default:
            return "unknown"
        }
    }

    static func isEmbeddingModel(_ modelID: String) -> Bool {
        let lowered = modelID.lowercased()
        return lowered.contains("embedding") || lowered.contains("embed-")
    }

    static func defaultModels(providerID: String, catalogSupport: BurnBarProviderCatalogSupport) -> [String: [String]] {
        // Catalog ids are globally unique (`openrouter-anthropic-claude-opus-5`);
        // the name the provider accepts upstream is the model's first alias.
        let models = catalogSupport.catalog.suggestedModels(forProviderID: providerID)
            .map { (name: $0.aliases.first ?? $0.id, price: $0.pricing.inputPerMToken) }
        let chat = models.filter { !isEmbeddingModel($0.name) }
        let embed = models.filter { isEmbeddingModel($0.name) }
        let cheapest = chat.min { lhs, rhs in (lhs.price, lhs.name) < (rhs.price, rhs.name) }
        let chatIDs = chat.map(\.name)
        return [
            "memory-extract": chatIDs,
            "memory-judge": chatIDs,
            "memory-answer": chatIDs,
            "memory-embed": embed.map(\.name),
            "memory-rerank": cheapest.map { [$0.name] } ?? []
        ]
    }

    static func assemble(
        snapshot: BurnBarProviderConfigurationSnapshot,
        membership: BurnBarMembershipSnapshot,
        catalogSupport: BurnBarProviderCatalogSupport,
        tokenStore: BurnBarGatewayScopedTokenStore?,
        gatewayURL: String?,
        now: Date
    ) async -> BurnBarMemoryModelPolicyResponse {
        let policy = snapshot.memoryEgress
        let proActive = BurnBarMembershipFreshness.isProActive(membership, now: now)
        let providers: [BurnBarMemoryModelPolicyProvider] = policy.consentedProviderIDs
            .filter { catalogSupport.isSupported(providerID: $0) }
            .sorted()
            .map { providerID in
                var purposes = defaultModels(providerID: providerID, catalogSupport: catalogSupport)
                for (purpose, override) in policy.allowedModelIDsByPurpose where !override.isEmpty {
                    purposes[purpose] = override
                }
                return BurnBarMemoryModelPolicyProvider(
                    id: providerID,
                    consented: true,
                    retention: retentionClass(providerID: providerID),
                    purposes: purposes
                )
            }
        let cli = Dictionary(uniqueKeysWithValues: BurnBarMemoryEgressPolicy.cliProviderIDs.map {
            ($0, policy.consentedCLIProviderIDs.contains($0))
        })
        let code: String?
        if !proActive {
            code = proRequiredCode
        } else if !policy.enabled {
            code = consentRequiredCode
        } else {
            code = nil
        }
        var token: String?
        var expiresAt: String?
        if code == nil, !providers.isEmpty, let tokenStore, let gatewayURL, !gatewayURL.isEmpty {
            let minted = await tokenStore.mint(purposes: Set(BurnBarMemoryEgressPolicy.purposes))
            token = minted.token
            expiresAt = BurnBarMembershipFreshness.iso(minted.expiresAt)
        }
        return BurnBarMemoryModelPolicyResponse(
            proActive: proActive,
            enabled: policy.enabled,
            gatewayURL: gatewayURL,
            gatewayToken: token,
            tokenExpiresAt: expiresAt,
            providers: providers,
            cli: cli,
            membershipUpdatedAt: membership.updatedAt,
            code: code
        )
    }
}

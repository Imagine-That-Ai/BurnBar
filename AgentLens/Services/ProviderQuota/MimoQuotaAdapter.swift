import Foundation
import OpenBurnBarCore

@MainActor
struct MimoQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = resolveMimoAPIKey(context: context) else {
            return unavailableSnapshot(
                for: .mimo,
                source: .unavailable,
                message: "Add a MiMo API key to report quota."
            )
        }

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("sk-") {
            return unavailableSnapshot(
                for: .mimo,
                source: .unavailable,
                message: "MiMo pay-as-you-go balance is only visible in the Xiaomi console. OpenBurnBar validates routing keys but does not expose PAYG balance yet."
            )
        }

        guard trimmed.hasPrefix("tp-") else {
            return unavailableSnapshot(
                for: .mimo,
                source: .unavailable,
                message: "MiMo quota reporting requires a Token Plan key (`tp-…`)."
            )
        }

        let region = context.mimoTokenPlanRegionProvider()
        let profile = ProviderEndpointProfileRegistry.mimoTokenPlan(region: region)
        guard let remainsURL = profile.quotaRemainsURL.flatMap(URL.init(string:)) else {
            return unavailableSnapshot(
                for: .mimo,
                source: .unavailable,
                message: "MiMo Token Plan remains URL is unavailable for the selected region."
            )
        }

        var request = URLRequest(url: remainsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await context.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("MiMo returned a non-HTTP response.")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return unavailableSnapshot(
                for: .mimo,
                source: .officialAPI,
                message: "MiMo rejected the Token Plan key for the selected region."
            )
        }

        if (200..<300).contains(http.statusCode) {
            let object = try JSONSerialization.jsonObject(with: data)
            let buckets = FlexibleQuotaBucketNormalizer.extractFlexibleBuckets(
                from: object,
                provider: .mimo,
                endpointLabel: "mimo"
            )
            if !buckets.isEmpty {
                return ProviderQuotaSnapshot(
                    provider: .mimo,
                    fetchedAt: Date(),
                    source: .officialAPI,
                    confidence: .exact,
                    managementURL: "https://platform.xiaomimimo.com/docs/en-US/tokenplan/subscription",
                    statusMessage: "Quota fetched from MiMo Token Plan remains endpoint.",
                    buckets: buckets
                )
            }
        }

        if let tier = context.mimoTokenPlanTierProvider() {
            let cycle = context.mimoTokenPlanBillingCycleProvider()
            let limit = tier.creditLimit(billingCycle: cycle)
            return ProviderQuotaSnapshot(
                provider: .mimo,
                fetchedAt: Date(),
                source: .manualEstimate,
                confidence: .estimated,
                managementURL: "https://platform.xiaomimimo.com/docs/en-US/tokenplan/subscription",
                statusMessage: "Vendor remains unavailable. Showing \(tier.displayName) tier cap for BurnBar-routed credit tracking.",
                buckets: [
                    ProviderQuotaBucket(
                        key: "token_plan_credits",
                        label: "Token Plan Credits",
                        windowKind: cycle == .annual ? .monthly : .monthly,
                        usedValue: 0,
                        limitValue: limit,
                        remainingValue: limit,
                        usedPercent: 0,
                        resetsAt: nil,
                        unit: .tokens,
                        isEstimated: true
                    )
                ]
            )
        }

        return unavailableSnapshot(
            for: .mimo,
            source: .officialAPI,
            message: "MiMo Token Plan remains endpoint returned no recognizable buckets. Select a tier in quota settings to enable BurnBar credit tracking."
        )
    }

    private func resolveMimoAPIKey(context: ProviderQuotaAdapterContext) -> String? {
        quotaNonEmpty(context.resolvedAPIKeys["mimo"] ?? nil)
            ?? cursorConnectorKey(for: "provider.mimo.apiKey")
            ?? quotaNonEmpty(context.environment["MIMO_API_KEY"])
    }

    private func cursorConnectorKey(for account: String) -> String? {
        let keychain = KeychainStore()
        let raw = try? keychain.string(for: account, allowUserInteraction: false)
        return quotaNonEmpty(raw ?? nil)
    }
}

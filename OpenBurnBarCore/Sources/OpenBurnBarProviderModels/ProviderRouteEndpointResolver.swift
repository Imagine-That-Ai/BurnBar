import Foundation

public struct ResolvedProviderEndpoint: Hashable, Sendable {
    public let baseURL: String
    public let endpointProfileID: String
    public let billingLane: ProviderEndpointBillingLane
    public let region: ProviderEndpointRegion
    public let quotaRemainsURL: String?
    public let authMethodID: String?

    public init(profile: ProviderEndpointProfile) {
        self.baseURL = profile.inferenceBaseURL
        self.endpointProfileID = profile.id
        self.billingLane = profile.billingLane
        self.region = profile.region
        self.quotaRemainsURL = profile.quotaRemainsURL
        self.authMethodID = profile.authMethodID
    }

    init(
        baseURL: String,
        endpointProfileID: String,
        billingLane: ProviderEndpointBillingLane,
        region: ProviderEndpointRegion,
        quotaRemainsURL: String?,
        authMethodID: String?
    ) {
        self.baseURL = baseURL
        self.endpointProfileID = endpointProfileID
        self.billingLane = billingLane
        self.region = region
        self.quotaRemainsURL = quotaRemainsURL
        self.authMethodID = authMethodID
    }
}

public enum ProviderRouteEndpointResolver {
    public struct SlotContext: Sendable {
        public let endpointProfileID: String?
        public let region: ProviderEndpointRegion?
        public let authMethodID: String?

        public init(
            endpointProfileID: String? = nil,
            region: ProviderEndpointRegion? = nil,
            authMethodID: String? = nil
        ) {
            self.endpointProfileID = endpointProfileID
            self.region = region
            self.authMethodID = authMethodID
        }
    }

    public static func resolve(
        providerID: String,
        apiKey: String,
        defaultBaseURL: String,
        slot: SlotContext = SlotContext()
    ) -> ResolvedProviderEndpoint {
        let normalizedProvider = ProviderID(rawValue: providerID)
        let region = slot.region ?? regionFromProfileID(slot.endpointProfileID)

        if let profile = ProviderEndpointProfileRegistry.resolveProfileID(
            providerID: normalizedProvider,
            apiKey: apiKey,
            explicitProfileID: slot.endpointProfileID,
            region: region
        ) {
            return ResolvedProviderEndpoint(profile: profile)
        }

        return ResolvedProviderEndpoint(
            baseURL: defaultBaseURL,
            endpointProfileID: "legacy.\(normalizedProvider.rawValue)",
            billingLane: .unknown,
            region: .global,
            quotaRemainsURL: nil,
            authMethodID: slot.authMethodID
        )
    }

    private static func regionFromProfileID(_ profileID: String?) -> ProviderEndpointRegion? {
        guard let profileID else { return nil }
        if profileID.hasSuffix(".cn") { return .cn }
        if profileID.hasSuffix(".sgp") { return .sgp }
        if profileID.hasSuffix(".ams") { return .ams }
        return nil
    }
}

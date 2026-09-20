import Foundation

/// `daemon.memory.model_policy` request: no parameters.
public struct BurnBarMemoryModelPolicyRequest: Codable, Hashable, Sendable {
    public init() {}
}

/// One provider the memory engine may use, with the models it may send each
/// purpose to and the provider's data-retention class (`deny`,
/// `provider-policy`, or `unknown`).
public struct BurnBarMemoryModelPolicyProvider: Codable, Hashable, Sendable {
    public let id: String
    public let consented: Bool
    public let retention: String
    public let purposes: [String: [String]]

    public init(id: String, consented: Bool, retention: String, purposes: [String: [String]]) {
        self.id = id
        self.consented = consented
        self.retention = retention
        self.purposes = purposes
    }
}

/// What the Python memory engine receives from the signed courier. Never
/// carries an API key: `gatewayToken` is a short-lived bearer scoped to
/// `memory-*` purposes on the loopback gateway.
public struct BurnBarMemoryModelPolicyResponse: Codable, Hashable, Sendable {
    public let proActive: Bool
    public let enabled: Bool
    public let gatewayURL: String?
    public let gatewayToken: String?
    public let tokenExpiresAt: String?
    public let providers: [BurnBarMemoryModelPolicyProvider]
    public let cli: [String: Bool]
    public let membershipUpdatedAt: String?
    /// `PRO_REQUIRED` or `CLOUD_CONSENT_REQUIRED` when the policy is not usable; nil otherwise.
    public let code: String?

    public init(
        proActive: Bool,
        enabled: Bool,
        gatewayURL: String?,
        gatewayToken: String?,
        tokenExpiresAt: String?,
        providers: [BurnBarMemoryModelPolicyProvider],
        cli: [String: Bool],
        membershipUpdatedAt: String?,
        code: String?
    ) {
        self.proActive = proActive
        self.enabled = enabled
        self.gatewayURL = gatewayURL
        self.gatewayToken = gatewayToken
        self.tokenExpiresAt = tokenExpiresAt
        self.providers = providers
        self.cli = cli
        self.membershipUpdatedAt = membershipUpdatedAt
        self.code = code
    }
}

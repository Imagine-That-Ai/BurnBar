import Foundation

// MARK: - Codex Models

public struct CodexRateLimitEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let planType: String?
    public let primary: CodexRateLimitWindow?
    public let secondary: CodexRateLimitWindow?
}

public struct CodexRateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowMinutes: Int?
    public let resetsAt: Date?
}

public struct CodexRolloutFileSignature: Codable, Equatable, Sendable {
    public let modifiedAt: TimeInterval
    public let sizeBytes: Int64
}

public struct CodexRolloutFileCacheEntry: Codable, Equatable, Sendable {
    public let signature: CodexRolloutFileSignature
    public let latestRateLimitEvent: CodexRateLimitEvent?
}

public struct CodexRolloutScanCache: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var fileEntries: [String: CodexRolloutFileCacheEntry]
    public var latestRateLimitEvent: CodexRateLimitEvent?
    public var lastUpdatedAt: Date?

    public static let empty = CodexRolloutScanCache(
        schemaVersion: 1,
        fileEntries: [:],
        latestRateLimitEvent: nil,
        lastUpdatedAt: nil
    )
}

public struct CodexRateLimitScanResult: Sendable {
    public let latestEvent: CodexRateLimitEvent?
    public let cache: CodexRolloutScanCache
    public let didChangeCache: Bool
}

struct CodexRolloutEnvelope: Decodable {
    let timestamp: Date
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }

        struct RateLimits: Decodable {
            let primary: Window?
            let secondary: Window?
            let planType: String?

            enum CodingKeys: String, CodingKey {
                case primary
                case secondary
                case planType = "plan_type"
            }
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let windowMinutes: Int?
            let resetsAt: Date?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
                windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)

                if let unixSeconds = try container.decodeIfPresent(Double.self, forKey: .resetsAt) {
                    resetsAt = Date(timeIntervalSince1970: unixSeconds)
                } else if let stringValue = try container.decodeIfPresent(String.self, forKey: .resetsAt),
                          let parsed = FlexibleQuotaBucketNormalizer.parseDateValue(stringValue) {
                    resetsAt = parsed
                } else {
                    resetsAt = nil
                }
            }
        }
    }
}

// MARK: - Cursor Models

public struct CursorUsageSummary: Decodable {
    public let billingCycleEnd: String?
    public let membershipType: String?
    public let isUnlimited: Bool?
    public let individualUsage: CursorIndividualUsage?
}

public struct CursorIndividualUsage: Decodable {
    public let plan: CursorPlanUsage?
    public let onDemand: CursorOnDemandUsage?
}

public struct CursorPlanUsage: Decodable {
    public let used: Int?
    public let limit: Int?
    public let autoPercentUsed: Double?
    public let apiPercentUsed: Double?
    public let totalPercentUsed: Double?
}

public struct CursorOnDemandUsage: Decodable {
    public let used: Int?
    public let limit: Int?
}

public struct CursorUserInfo: Decodable {
    public let id: String?
    public let email: String?
    public let name: String?
}

// MARK: - Factory Models

struct FactorySessionCredentialEnvelope: Sendable {
    let cookieHeader: String?
    let bearerToken: String?
    let sourceLabel: String
}

struct FactoryAuthResponseEnvelope: Sendable {
    let planName: String?
    let tier: String?
    let organizationName: String?
    /// Stripe / Orb status — "active" / "trialing" / "past_due" / "canceled".
    /// Surfaced in the popover status line when not `active`.
    let subscriptionStatus: String?
    /// Inferred Pro / Plus / Max from the API response. `.unknown` when
    /// `/api/app/auth/me` cannot be reached or returns a tier name
    /// OpenBurnBar doesn't recognize.
    let inferredPlanTier: FactoryQuotaPlanTier
}

struct FactoryUsageEnvelope: Sendable {
    struct Lane: Sendable {
        let userTokens: Double
        let totalAllowance: Double?
        let usedPercent: Double?
    }

    /// Prepaid Extra Usage credits returned by Factory's billing API.
    /// Reflects the `~/.factory` user's current prepaid wallet (USD,
    /// drawn down as sessions burn through models). `enabled=false` means
    /// the toggle is off — even with a positive balance, Standard Usage
    /// is consumed first and Extra Usage stays untouched.
    struct ExtraUsage: Sendable {
        let balanceUSD: Double
        let enabled: Bool
    }

    let periodEnd: Date?
    let standard: Lane
    let premium: Lane
    /// Droid Core lane (open-weight models, separate free pool). Populated
    /// when the billing API exposes a `droidCore` / `core` lane block.
    let droidCore: Lane?
    let extraUsage: ExtraUsage?
}

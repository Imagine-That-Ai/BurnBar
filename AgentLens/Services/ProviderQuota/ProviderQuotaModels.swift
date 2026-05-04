import Foundation

// MARK: - Codex Models

struct CodexRateLimitEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let planType: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

struct CodexRateLimitWindow: Codable, Equatable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
}

struct CodexRolloutFileSignature: Codable, Equatable, Sendable {
    let modifiedAt: TimeInterval
    let sizeBytes: Int64
}

struct CodexRolloutFileCacheEntry: Codable, Equatable, Sendable {
    let signature: CodexRolloutFileSignature
    let latestRateLimitEvent: CodexRateLimitEvent?
}

struct CodexRolloutScanCache: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var fileEntries: [String: CodexRolloutFileCacheEntry]
    var latestRateLimitEvent: CodexRateLimitEvent?
    var lastUpdatedAt: Date?

    static let empty = CodexRolloutScanCache(
        schemaVersion: 1,
        fileEntries: [:],
        latestRateLimitEvent: nil,
        lastUpdatedAt: nil
    )
}

struct CodexRateLimitScanResult: Sendable {
    let latestEvent: CodexRateLimitEvent?
    let cache: CodexRolloutScanCache
    let didChangeCache: Bool
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

struct CursorUsageSummary: Decodable {
    let billingCycleEnd: String?
    let membershipType: String?
    let isUnlimited: Bool?
    let individualUsage: CursorIndividualUsage?
}

struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

struct CursorPlanUsage: Decodable {
    let used: Int?
    let limit: Int?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

struct CursorOnDemandUsage: Decodable {
    let used: Int?
    let limit: Int?
}

struct CursorUserInfo: Decodable {
    let id: String?
    let email: String?
    let name: String?
}

struct CursorLegacyUsageResponse: Decodable {
    let gpt4: CursorLegacyRequestUsage?
}

struct CursorLegacyRequestUsage: Decodable {
    let numRequests: Int?
    let numRequestsTotal: Int?
    let maxRequestUsage: Int?
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
}

struct FactoryUsageEnvelope: Sendable {
    struct Lane: Sendable {
        let userTokens: Double
        let totalAllowance: Double?
        let usedPercent: Double?
    }

    let periodEnd: Date?
    let standard: Lane
    let premium: Lane
}

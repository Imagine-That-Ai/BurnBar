import Foundation
import OpenBurnBarKernel

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
    /// Directories this payload scanned. In-memory hop for merge-on-write;
    /// missing on disk (pre-overlap caches) means "replace the whole map".
    public var scannedDirectoryPaths: [String]

    public static let empty = CodexRolloutScanCache(
        schemaVersion: 1,
        fileEntries: [:],
        latestRateLimitEvent: nil,
        lastUpdatedAt: nil,
        scannedDirectoryPaths: []
    )

    public init(
        schemaVersion: Int,
        fileEntries: [String: CodexRolloutFileCacheEntry],
        latestRateLimitEvent: CodexRateLimitEvent?,
        lastUpdatedAt: Date?,
        scannedDirectoryPaths: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.fileEntries = fileEntries
        self.latestRateLimitEvent = latestRateLimitEvent
        self.lastUpdatedAt = lastUpdatedAt
        self.scannedDirectoryPaths = scannedDirectoryPaths
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fileEntries
        case latestRateLimitEvent
        case lastUpdatedAt
        case scannedDirectoryPaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        fileEntries = try container.decode([String: CodexRolloutFileCacheEntry].self, forKey: .fileEntries)
        latestRateLimitEvent = try container.decodeIfPresent(
            CodexRateLimitEvent.self,
            forKey: .latestRateLimitEvent
        )
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        scannedDirectoryPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .scannedDirectoryPaths
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(fileEntries, forKey: .fileEntries)
        try container.encodeIfPresent(latestRateLimitEvent, forKey: .latestRateLimitEvent)
        try container.encodeIfPresent(lastUpdatedAt, forKey: .lastUpdatedAt)
        if !scannedDirectoryPaths.isEmpty {
            try container.encode(scannedDirectoryPaths, forKey: .scannedDirectoryPaths)
        }
    }

    /// Overlay `incoming` for keys under that scan's directories. Other roots stay.
    /// Empty `incoming.scannedDirectoryPaths` is a full replace (legacy writers).
    public func mergingScan(incoming: CodexRolloutScanCache) -> CodexRolloutScanCache {
        let roots = incoming.scannedDirectoryPaths
        guard !roots.isEmpty else { return incoming.persistingWithoutScanRoots() }

        var merged = fileEntries
        for key in merged.keys where Self.path(key, isUnder: roots) && incoming.fileEntries[key] == nil {
            merged.removeValue(forKey: key)
        }
        for (key, value) in incoming.fileEntries where Self.path(key, isUnder: roots) {
            merged[key] = value
        }

        let latest = merged.values
            .compactMap(\.latestRateLimitEvent)
            .max { $0.timestamp < $1.timestamp }
        return CodexRolloutScanCache(
            schemaVersion: max(schemaVersion, incoming.schemaVersion),
            fileEntries: merged,
            latestRateLimitEvent: latest,
            lastUpdatedAt: incoming.lastUpdatedAt ?? lastUpdatedAt,
            scannedDirectoryPaths: []
        )
    }

    public func persistingWithoutScanRoots() -> CodexRolloutScanCache {
        guard scannedDirectoryPaths.isEmpty else {
            return CodexRolloutScanCache(
                schemaVersion: schemaVersion,
                fileEntries: fileEntries,
                latestRateLimitEvent: latestRateLimitEvent,
                lastUpdatedAt: lastUpdatedAt,
                scannedDirectoryPaths: []
            )
        }
        return self
    }

    public static func path(_ path: String, isUnder directories: [String]) -> Bool {
        let standardized = (path as NSString).standardizingPath
        for directory in directories {
            let root = (directory as NSString).standardizingPath
            if standardized == root { return true }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if standardized.hasPrefix(prefix) { return true }
        }
        return false
    }
}

/// Merge `incoming` into a live locked box. Callers persist when `didChange` is true.
public enum CodexRolloutScanCacheUpdate {
    public static func apply(
        incoming: CodexRolloutScanCache,
        didChangeIncoming: Bool,
        to box: Locked<CodexRolloutScanCache>
    ) -> (cache: CodexRolloutScanCache, didChange: Bool) {
        box.withLock { cache in
            let merged = cache.mergingScan(incoming: incoming)
            let changed = didChangeIncoming || merged != cache
            cache = merged
            return (merged, changed)
        }
    }
}

public struct CodexRateLimitScanResult: Sendable {
    public let latestEvent: CodexRateLimitEvent?
    public let cache: CodexRolloutScanCache
    public let didChangeCache: Bool
    public let scannedDirectoryPaths: [String]

    public init(
        latestEvent: CodexRateLimitEvent?,
        cache: CodexRolloutScanCache,
        didChangeCache: Bool,
        scannedDirectoryPaths: [String] = []
    ) {
        self.latestEvent = latestEvent
        self.cache = cache
        self.didChangeCache = didChangeCache
        self.scannedDirectoryPaths = scannedDirectoryPaths
    }
}

public struct CodexRolloutEnvelope: Decodable {
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

public struct FactorySessionCredentialEnvelope: Sendable {
    let cookieHeader: String?
    let bearerToken: String?
    let sourceLabel: String
}

public struct FactoryAuthResponseEnvelope: Sendable {
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

public struct FactoryUsageEnvelope: Sendable {
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

import Foundation

// MARK: - Provider Quota Source Kind

public enum ProviderQuotaSourceKind: String, Codable, Sendable {
    case provider
    case officialAPI
    case localCLI
    case localSession
    case manualEstimate
    case unavailable

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .provider
    }
}

// MARK: - Provider Quota Confidence

public enum ProviderQuotaConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case stale

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Self.high.rawValue, "exact":
            self = .high
        case Self.medium.rawValue, "estimated":
            self = .medium
        case Self.low.rawValue:
            self = .low
        case Self.stale.rawValue, "unavailable":
            self = .stale
        default:
            self = .stale
        }
    }
}

// MARK: - Provider Quota Unit

public enum ProviderQuotaUnit: String, Codable, Sendable {
    case tokens
    case requests
    case fastCalls = "fast-calls"
    case credits
    case unknown
}

// MARK: - Provider Quota Window Kind

public enum ProviderQuotaWindowKind: String, Codable, Sendable {
    case rollingHours
    case rollingDays
    case daily
    case weekly
    case monthly
    case lifetime
    case custom
}

// MARK: - Provider Quota Bucket

public struct ProviderQuotaBucket: Codable, Hashable, Sendable {
    public let name: String
    public let used: Double
    public let limit: Double
    public let remaining: Double
    public let window: String?
    public let meta: [String: String]?
    public let resetsAt: Date?

    public init(
        name: String,
        used: Double,
        limit: Double,
        remaining: Double,
        window: String? = nil,
        meta: [String: String]? = nil,
        resetsAt: Date? = nil
    ) {
        self.name = name
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.window = window
        self.meta = meta
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, used, limit, remaining, window, meta, resetsAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.used = try c.decode(Double.self, forKey: .used)
        self.limit = try c.decode(Double.self, forKey: .limit)
        self.remaining = try c.decode(Double.self, forKey: .remaining)
        self.window = try c.decodeIfPresent(String.self, forKey: .window)
        let decodedMeta = try c.decodeIfPresent([String: String].self, forKey: .meta)
        self.meta = decodedMeta

        // Three input shapes are valid for the top-level field:
        //  1. `Date` (Codable's deferred-to-date Double or whatever strategy
        //     the decoder is using) — emitted by iOS after `sanitizeForJSON`
        //     turns Firestore `Timestamp` into `timeIntervalSinceReferenceDate`.
        //  2. ISO8601 string — emitted by Cloud Functions HTTP responses and
        //     by older Mac builds before the field was first-class.
        //  3. Missing → fall back to `meta["resetsAt"]` for docs written
        //     before the field was promoted.
        if let direct = try? c.decodeIfPresent(Date.self, forKey: .resetsAt) {
            self.resetsAt = direct
        } else if let isoString = try? c.decodeIfPresent(String.self, forKey: .resetsAt),
                  let parsed = Self.parseResetsAtString(isoString) {
            self.resetsAt = parsed
        } else if let legacy = decodedMeta?["resetsAt"],
                  let parsed = Self.parseResetsAtString(legacy) {
            self.resetsAt = parsed
        } else {
            self.resetsAt = nil
        }
    }

    /// Accept ISO8601 with or without fractional seconds. The Mac writer
    /// historically emits the fraction-less form (default `ISO8601DateFormatter`
    /// options); Cloud Functions and some other writers include fractional
    /// seconds. Try both before giving up.
    private static func parseResetsAtString(_ s: String) -> Date? {
        if let d = Self.iso8601WithFraction.date(from: s) { return d }
        if let d = Self.iso8601Basic.date(from: s) { return d }
        return nil
    }

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Reset Time Display

public extension ProviderQuotaBucket {
    /// Pre-formatted reset-time strings used by every quota details surface
    /// (Mac, iOS, Android via the shared logic, Smart Hub cast). Returns
    /// `nil` when the bucket has no known reset moment so callers can omit
    /// the row entirely instead of showing a placeholder.
    ///
    /// Example: `(relative: "in 2h 14m", absolute: "May 8, 3:35 AM")`.
    var resetsAtDisplay: (relative: String, absolute: String)? {
        guard let resetsAt = Self.displayResetDate(resetsAt, name: name, window: window) else { return nil }
        let now = Date()
        let relative = Self.relativeResetsFormatter.localizedString(
            for: resetsAt,
            relativeTo: now
        )
        let absolute = resetsAt.formatted(date: .abbreviated, time: .shortened)
        return (relative: relative, absolute: absolute)
    }

    private static func displayResetDate(
        _ resetsAt: Date?,
        name: String,
        window: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard let resetsAt else { return nil }
        guard resetsAt <= now else { return resetsAt }

        let marker = "\(name) \(window ?? "")".lowercased()
        if marker.contains("5") || marker.contains("five") {
            return advance(resetsAt, by: 5 * 60 * 60, after: now)
        }
        if marker.contains("7") || marker.contains("seven") || marker.contains("week") {
            return advance(resetsAt, by: 7 * 24 * 60 * 60, after: now)
        }
        if marker.contains("day") {
            return advance(resetsAt, by: 24 * 60 * 60, after: now)
        }
        if marker.contains("month") {
            var candidate = resetsAt
            for _ in 0..<60 {
                guard let next = calendar.date(byAdding: .month, value: 1, to: candidate) else { return nil }
                candidate = next
                if candidate > now { return candidate }
            }
        }
        return nil
    }

    private static func advance(_ date: Date, by interval: TimeInterval, after now: Date) -> Date? {
        guard interval > 0 else { return nil }
        let elapsed = max(0, now.timeIntervalSince(date))
        let steps = floor(elapsed / interval) + 1
        let candidate = date.addingTimeInterval(steps * interval)
        return candidate > now ? candidate : candidate.addingTimeInterval(interval)
    }

    /// Single-line combined label ("in 2h 14m · May 8, 3:35 AM") used as the
    /// default rendering on every surface. Mac micro-badge and iOS/Android
    /// reset rows both prepend "Resets " themselves so the helper stays free
    /// of UI copy.
    var resetsAtCombinedLabel: String? {
        guard let pair = resetsAtDisplay else { return nil }
        return "\(pair.relative) · \(pair.absolute)"
    }

    private static let relativeResetsFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .numeric
        return f
    }()
}

public extension ProviderQuotaBucket {
    var isDisplayableQuotaSignal: Bool {
        guard limit.isFinite, limit > 0, used.isFinite, remaining.isFinite else {
            return false
        }

        let marker = "\(name) \(meta?["label"] ?? "")".lowercased()
        if ["cache", "hit rate", "local model", "cloud model", "installed", "task", "conversation", "line", "file"].contains(where: marker.contains) {
            return false
        }

        if let unit = meta?["unit"]?.lowercased() {
            if ["sessions", "session", "lines", "files"].contains(unit) {
                return false
            }
            if unit == "count" && !(marker.contains("credit") || marker.contains("budget")) {
                return false
            }
        }

        return used >= 0 || remaining >= 0 || meta?["usedPercent"] != nil
    }
}

// MARK: - Provider Quota Snapshot

public struct ProviderQuotaSnapshot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let providerID: ProviderID
    public let accountID: String?
    public let accountLabel: String?
    public let accountStorageScope: ProviderAccountStorageScope?
    public let sourceKind: ProviderQuotaSourceKind
    public let sourceId: String
    public let fetchedAt: Date
    public let source: String
    public let confidence: ProviderQuotaConfidence
    public let managementURL: String?
    public let statusMessage: String?
    public let buckets: [ProviderQuotaBucket]
    public let schemaVersion: Int
    public let updatedAt: Date

    public var sourceID: String { sourceId }

    public init(
        id: String,
        provider: String,
        providerID: ProviderID? = nil,
        accountID: String? = nil,
        accountLabel: String? = nil,
        accountStorageScope: ProviderAccountStorageScope? = nil,
        sourceKind: ProviderQuotaSourceKind,
        sourceId: String,
        fetchedAt: Date,
        source: String,
        confidence: ProviderQuotaConfidence,
        managementURL: String? = nil,
        statusMessage: String? = nil,
        buckets: [ProviderQuotaBucket],
        schemaVersion: Int = 2,
        updatedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.providerID = providerID ?? ProviderID(rawValue: provider)
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.accountStorageScope = accountStorageScope
        self.sourceKind = sourceKind
        self.sourceId = sourceId
        self.fetchedAt = fetchedAt
        self.source = source
        self.confidence = confidence
        self.managementURL = managementURL
        self.statusMessage = statusMessage
        self.buckets = buckets
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, providerID, accountID, accountLabel, accountStorageScope
        case sourceKind, sourceId, sourceID, fetchedAt, source, confidence
        case managementURL, statusMessage, buckets, schemaVersion, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        providerID = try c.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? ProviderID(rawValue: provider)
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
        accountLabel = try c.decodeIfPresent(String.self, forKey: .accountLabel)
        accountStorageScope = try c.decodeIfPresent(ProviderAccountStorageScope.self, forKey: .accountStorageScope)
        sourceKind = try c.decode(ProviderQuotaSourceKind.self, forKey: .sourceKind)
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
            ?? c.decodeIfPresent(String.self, forKey: .sourceID)
            ?? ""
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        source = try c.decode(String.self, forKey: .source)
        confidence = try c.decode(ProviderQuotaConfidence.self, forKey: .confidence)
        managementURL = try c.decodeIfPresent(String.self, forKey: .managementURL)
        statusMessage = try c.decodeIfPresent(String.self, forKey: .statusMessage)
        buckets = try c.decode([ProviderQuotaBucket].self, forKey: .buckets)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(providerID, forKey: .providerID)
        try c.encodeIfPresent(accountID, forKey: .accountID)
        try c.encodeIfPresent(accountLabel, forKey: .accountLabel)
        try c.encodeIfPresent(accountStorageScope, forKey: .accountStorageScope)
        try c.encode(sourceKind, forKey: .sourceKind)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(sourceId, forKey: .sourceID)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encode(source, forKey: .source)
        try c.encode(confidence, forKey: .confidence)
        try c.encodeIfPresent(managementURL, forKey: .managementURL)
        try c.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try c.encode(buckets, forKey: .buckets)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

public extension ProviderQuotaSnapshot {
    private var quotaProvider: AgentProvider? {
        AgentProvider.fromProviderID(providerID)
            ?? AgentProvider.fromPersistedToken(provider)
            ?? AgentProvider(rawValue: provider)
    }

    var displayableQuotaBuckets: [ProviderQuotaBucket] {
        buckets.filter(\.isDisplayableQuotaSignal)
    }

    var hasDisplayableQuotaSignal: Bool {
        guard quotaProvider?.isQuotaSignalProvider == true else {
            return false
        }
        return !displayableQuotaBuckets.isEmpty
    }

    var isExplicitlyStale: Bool {
        if confidence == .stale { return true }
        return statusMessage?.localizedCaseInsensitiveContains("stale") == true
    }

    func isStale(relativeTo now: Date = Date()) -> Bool {
        isExplicitlyStale || now.timeIntervalSince(fetchedAt) > 12 * 60 * 60
    }

    func filteringToDisplayableQuotaSignal() -> ProviderQuotaSnapshot? {
        let filteredBuckets = displayableQuotaBuckets
        guard quotaProvider?.isQuotaSignalProvider == true,
              !filteredBuckets.isEmpty else {
            return nil
        }

        return ProviderQuotaSnapshot(
            id: id,
            provider: provider,
            providerID: providerID,
            accountID: accountID,
            accountLabel: accountLabel,
            accountStorageScope: accountStorageScope,
            sourceKind: sourceKind,
            sourceId: sourceId,
            fetchedAt: fetchedAt,
            source: source,
            confidence: confidence,
            managementURL: managementURL,
            statusMessage: statusMessage,
            buckets: filteredBuckets,
            schemaVersion: schemaVersion,
            updatedAt: updatedAt
        )
    }
}

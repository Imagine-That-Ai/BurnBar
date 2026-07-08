import Foundation

// MARK: - Provider Quota Source Kind

public enum ProviderQuotaSourceKind: String, Codable, Sendable {
    case provider
    case officialAPI
    case localCLI
    case localSession
    case manualEstimate
    case unavailable

    public var label: String {
        switch self {
        case .provider: return "Provider"
        case .officialAPI: return "Official API"
        case .localCLI: return "Local CLI"
        case .localSession: return "Local session"
        case .manualEstimate: return "Estimated"
        case .unavailable: return "Unavailable"
        }
    }

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
    case percent
    case tokens
    case requests
    case fastCalls = "fast-calls"
    case credits
    case currency
    case count
    case lines
    case files
    case sessions
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
//
// WS-C2 parity: stored mac/Windows-harness fields (`key`, `label`, `windowKind`,
// `usedValue`, `limitValue`, `remainingValue`, `usedPercent`, `unit`, `isEstimated`)
// are canonical for adapter output. `name`/`used`/`limit`/`remaining`/`window`/`meta`
// are derived for legacy Core routing/UI. Codable prefers the mac JSON shape when
// `key` is present; otherwise decodes the legacy `name`/`used`/`limit` shape.

public struct ProviderQuotaBucket: Codable, Hashable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let windowKind: ProviderQuotaWindowKind
    public let usedValue: Double?
    public let limitValue: Double?
    public let remainingValue: Double?
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let unit: ProviderQuotaUnit
    public let isEstimated: Bool

    public let name: String
    public let used: Double
    public let limit: Double
    public let remaining: Double
    public let window: String?
    public let meta: [String: String]?

    public var id: String { key }

    public var remainingPercent: Double? {
        if let usedPercent {
            return max(0, min(100 - usedPercent, 100))
        }
        if let remainingValue, unit == .percent {
            return min(max(remainingValue, 0), 100)
        }
        if let remainingValue, let limitValue, limitValue > 0 {
            return min(max((remainingValue / limitValue) * 100, 0), 100)
        }
        return nil
    }

    /// macOS adapter / Windows `ExpectedBucket` initializer.
    public init(
        key: String,
        label: String,
        windowKind: ProviderQuotaWindowKind,
        usedValue: Double?,
        limitValue: Double?,
        remainingValue: Double?,
        usedPercent: Double?,
        resetsAt: Date?,
        unit: ProviderQuotaUnit,
        isEstimated: Bool
    ) {
        self.key = key
        self.label = label
        self.windowKind = windowKind
        self.usedValue = usedValue
        self.limitValue = limitValue
        self.remainingValue = remainingValue
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.unit = unit
        self.isEstimated = isEstimated

        self.name = key
        self.window = windowKind.rawValue
        // Branch on unit FIRST: percent-unit buckets use percent math
        // (usedPercent, or remainingValue → 100 - remaining). Non-percent
        // buckets (currency/tokens/requests/credits/count/sessions) use the
        // concrete value fields directly. This keeps the derived used/limit/
        // remaining consistent with the Firestore serializer
        // (QuotaSnapshotSyncService.encodeBucket) which reads the value fields
        // directly and never recomputes from usedPercent.
        if unit == .percent {
            if let usedPercent {
                self.used = usedPercent
                self.limit = 100
                self.remaining = max(0, 100 - usedPercent)
            } else if let remainingValue {
                self.used = max(0, 100 - remainingValue)
                self.limit = 100
                self.remaining = remainingValue
            } else {
                self.used = usedValue ?? 0
                self.limit = 100
                self.remaining = max(0, 100 - self.used)
            }
        } else {
            self.used = usedValue ?? 0
            let lim = limitValue ?? -1
            self.limit = lim
            if let remainingValue {
                self.remaining = remainingValue
            } else if let limVal = limitValue, limVal > 0, let usedVal = usedValue {
                self.remaining = max(0, limVal - usedVal)
            } else {
                self.remaining = 0
            }
        }

        var meta: [String: String] = ["label": label, "unit": unit.rawValue]
        if isEstimated { meta["isEstimated"] = "true" }
        if let usedPercent { meta["usedPercent"] = String(usedPercent) }
        self.meta = meta.isEmpty ? nil : meta
    }

    /// Legacy Core initializer (routing / Firestore).
    public init(
        name: String,
        used: Double,
        limit: Double,
        remaining: Double,
        window: String? = nil,
        meta: [String: String]? = nil,
        resetsAt: Date? = nil
    ) {
        let windowKind = window.flatMap { ProviderQuotaWindowKind(rawValue: $0) } ?? .custom
        let unitRaw = meta?["unit"] ?? "unknown"
        let unit = ProviderQuotaUnit(rawValue: unitRaw) ?? .unknown
        let usedPercent = meta.flatMap { m in
            ["usedPercent", "used_percent", "usage_percent"].compactMap { m[$0] }.first.flatMap(Double.init)
        }
        let isEstimated = meta?["isEstimated"] == "true"

        self.key = name
        self.label = meta?["label"] ?? name
        self.windowKind = windowKind
        self.usedValue = used
        self.limitValue = limit > 0 ? limit : nil
        self.remainingValue = remaining
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.unit = unit
        self.isEstimated = isEstimated
        self.name = name
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.window = window
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, windowKind, usedValue, limitValue, remainingValue, usedPercent, resetsAt, unit, isEstimated
        case name, used, limit, remaining, window, meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let key = try c.decodeIfPresent(String.self, forKey: .key) {
            self.key = key
            self.label = try c.decode(String.self, forKey: .label)
            self.windowKind = try c.decode(ProviderQuotaWindowKind.self, forKey: .windowKind)
            self.usedValue = try c.decodeIfPresent(Double.self, forKey: .usedValue)
            self.limitValue = try c.decodeIfPresent(Double.self, forKey: .limitValue)
            self.remainingValue = try c.decodeIfPresent(Double.self, forKey: .remainingValue)
            self.usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent)
            self.unit = try c.decode(ProviderQuotaUnit.self, forKey: .unit)
            self.isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
            self.resetsAt = Self.decodeResetsAt(from: c)
            self.name = key
            self.window = windowKind.rawValue
            if unit == .percent {
                if let usedPercent {
                    self.used = usedPercent
                    self.limit = 100
                    self.remaining = max(0, 100 - usedPercent)
                } else if let remainingValue {
                    self.used = max(0, 100 - remainingValue)
                    self.limit = 100
                    self.remaining = remainingValue
                } else {
                    self.used = usedValue ?? 0
                    self.limit = 100
                    self.remaining = max(0, 100 - self.used)
                }
            } else {
                self.used = usedValue ?? 0
                let lim = limitValue ?? -1
                self.limit = lim
                if let remainingValue {
                    self.remaining = remainingValue
                } else if let limVal = limitValue, limVal > 0, let usedVal = usedValue {
                    self.remaining = max(0, limVal - usedVal)
                } else {
                    self.remaining = 0
                }
            }
            var meta: [String: String] = ["label": label, "unit": unit.rawValue]
            if isEstimated { meta["isEstimated"] = "true" }
            if let usedPercent { meta["usedPercent"] = String(usedPercent) }
            self.meta = meta
        } else {
            self.name = try c.decode(String.self, forKey: .name)
            self.used = try c.decode(Double.self, forKey: .used)
            self.limit = try c.decode(Double.self, forKey: .limit)
            self.remaining = try c.decode(Double.self, forKey: .remaining)
            self.window = try c.decodeIfPresent(String.self, forKey: .window)
            self.meta = try c.decodeIfPresent([String: String].self, forKey: .meta)
            self.resetsAt = Self.decodeResetsAt(from: c, meta: meta)
            self.key = name
            self.label = meta?["label"] ?? name
            self.windowKind = window.flatMap { ProviderQuotaWindowKind(rawValue: $0) } ?? .custom
            self.usedValue = used
            self.limitValue = limit > 0 ? limit : nil
            self.remainingValue = remaining
            self.usedPercent = meta.flatMap { m in
                ["usedPercent", "used_percent", "usage_percent"].compactMap { m[$0] }.first.flatMap(Double.init)
            }
            let unitRaw = meta?["unit"] ?? "unknown"
            self.unit = ProviderQuotaUnit(rawValue: unitRaw) ?? .unknown
            self.isEstimated = meta?["isEstimated"] == "true"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(label, forKey: .label)
        try c.encode(windowKind, forKey: .windowKind)
        try c.encodeIfPresent(usedValue, forKey: .usedValue)
        try c.encodeIfPresent(limitValue, forKey: .limitValue)
        try c.encodeIfPresent(remainingValue, forKey: .remainingValue)
        try c.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encode(unit, forKey: .unit)
        try c.encode(isEstimated, forKey: .isEstimated)
    }

    private static func decodeResetsAt(
        from c: KeyedDecodingContainer<CodingKeys>,
        meta: [String: String]? = nil
    ) -> Date? {
        if let direct = try? c.decodeIfPresent(Date.self, forKey: .resetsAt) {
            return direct
        }
        if let isoString = try? c.decodeIfPresent(String.self, forKey: .resetsAt),
           let parsed = parseResetsAtString(isoString) {
            return parsed
        }
        if let legacy = meta?["resetsAt"], let parsed = parseResetsAtString(legacy) {
            return parsed
        }
        return nil
    }

    private static func parseResetsAtString(_ s: String) -> Date? {
        ThreadSafeISO8601DateFormatter.parse(s)
    }
}

// MARK: - Reset Time Display

public extension ProviderQuotaBucket {
    /// Whether this bucket represents a prepaid credit balance (no hard
    /// limit or window) as opposed to a time-windowed quota bucket.
    /// Detectable by: no meaningful limit value, but a positive remaining
    /// value, and a "lifetime" or absent window.
    var isCreditBalance: Bool {
        let effectiveLimit = limit.isFinite ? limit : 0
        guard effectiveLimit <= 0, remaining > 0 else { return false }
        let windowLower = (window ?? "").lowercased()
        return windowLower.contains("lifetime") || windowLower.isEmpty
    }

    /// Pre-formatted reset-time strings used by every quota details surface
    /// (Mac, iOS, Android via the shared logic, Smart Hub cast). Returns
    /// `nil` when the bucket has no known reset moment so callers can omit
    /// the row entirely instead of showing a placeholder.
    ///
    /// Example: `(relative: "in 2h 14m", absolute: "May 8, 3:35 AM")`.
    var resetsAtDisplay: (relative: String, absolute: String)? {
        guard let resetsAt = Self.displayResetDate(resetsAt, name: name, window: window) else { return nil }
        let now = Date()
        #if canImport(Darwin)
        let relative = Self.makeRelativeResetsFormatter().localizedString(
            for: resetsAt,
            relativeTo: now
        )
        #else
        let relative = Self.fallbackRelativeResetsString(for: resetsAt, relativeTo: now)
        #endif
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
        // Recognise the canonical `ProviderQuotaWindowKind` raw values the Mac
        // writes as `window` first. Codex syncs `window: "rollingHours"` with a
        // bare `name: "codex-primary"`, so the digit/word markers below never
        // match it — without these two lines a rolled-over Codex 5h window can
        // neither advance its countdown nor reset its bar on iOS / Android.
        // `rollingdays` must precede the generic `day` branch (it contains
        // "day") so the weekly window advances by 7 days, not 1.
        if marker.contains("rollinghours") {
            return advance(resetsAt, by: 5 * 60 * 60, after: now)
        }
        if marker.contains("rollingdays") {
            return advance(resetsAt, by: 7 * 24 * 60 * 60, after: now)
        }
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

    /// Returns the bucket reconciled to `now`. When a fixed-reset rolling
    /// window's `resetsAt` has already passed, the provider's counter has
    /// rolled into a fresh window, so the bucket reports 0 used / full
    /// remaining with `resetsAt` advanced to the next boundary. Buckets whose
    /// window has no known period (lifetime balances, custom windows) or whose
    /// reset is still in the future are returned unchanged.
    ///
    /// This reuses the exact gate `resetsAtDisplay` uses (`displayResetDate`),
    /// so the usage bar and the reset countdown always agree: whenever the
    /// countdown shows a fresh future reset, the bar shows the matching fresh
    /// window. The historical bug was that the countdown advanced past a stale
    /// reset while the bar stayed pinned at the old window's usage — most
    /// visible on Codex, whose snapshot freezes once the user is capped (no
    /// new rollout events get written), but latent for every provider.
    func reconcilingElapsedWindow(asOf now: Date = Date()) -> ProviderQuotaBucket {
        guard let resetsAt, resetsAt <= now,
              let nextReset = Self.displayResetDate(resetsAt, name: name, window: window, now: now)
        else { return self }

        // Full remaining for the fresh window. Percent buckets carry limit 100;
        // value buckets carry their real cap. When the cap is unknown we leave
        // `remaining` untouched and rely on the zeroed percent meta below.
        let fullRemaining = (limit.isFinite && limit > 0) ? limit : remaining

        // `displayRemainingFraction` reads the percent meta aliases before the
        // used/limit/remaining triple, so zero every used-percent alias and
        // fill every remaining-percent alias the payload actually carries.
        var resetMeta = meta ?? [:]
        for key in Self.usedPercentMetaKeys where resetMeta[key] != nil {
            resetMeta[key] = "0"
        }
        for key in Self.remainingPercentMetaKeys where resetMeta[key] != nil {
            resetMeta[key] = "100"
        }

        return ProviderQuotaBucket(
            name: name,
            used: 0,
            limit: limit,
            remaining: fullRemaining,
            window: window,
            meta: resetMeta.isEmpty ? nil : resetMeta,
            resetsAt: nextReset
        )
    }

    private static let usedPercentMetaKeys = [
        "usedPercent", "used_percent", "used_percentage",
        "usagePercent", "usage_percent", "percentage"
    ]

    private static let remainingPercentMetaKeys = [
        "remainingPercent", "remaining_percent", "remainingPercentage",
        "remaining_percentage", "percentRemaining", "percent_remaining"
    ]

    #if canImport(Darwin)
    private static func makeRelativeResetsFormatter() -> RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .numeric
        return f
    }
    #else
    // `RelativeDateTimeFormatter` is Apple-only. Off-Apple we format the relative
    // reset string by hand ("in 2h 14m" / "3h ago") so the quota reset row stays
    // populated on the Windows/Linux Engine subset. Not localized — the Apple path
    // keeps the localized formatter.
    private static func fallbackRelativeResetsString(for date: Date, relativeTo now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        let isPast = delta < 0
        var remaining = Int(abs(delta).rounded())
        let days = remaining / 86_400; remaining %= 86_400
        let hours = remaining / 3_600; remaining %= 3_600
        let minutes = remaining / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0, days == 0 { parts.append("\(minutes)m") }
        if parts.isEmpty { parts.append("0m") }
        let body = parts.joined(separator: " ")
        return isPast ? "\(body) ago" : "in \(body)"
    }
    #endif
}

public extension ProviderQuotaBucket {
    /// Display-safe remaining fraction for quota UI. Provider payloads are not
    /// perfectly uniform: some sources expose only `meta.usedPercent`, some
    /// percent buckets arrive with `limit == 0`, and unknown/unlimited buckets
    /// use `limit == -1`. Treating all of those as `remaining / limit` makes
    /// healthy providers render as `0%`.
    var displayRemainingFraction: Double? {
        if let usedPercent = quotaMetaNumber(for: [
            "usedPercent",
            "used_percent",
            "used_percentage",
            "usagePercent",
            "usage_percent",
            "percentage"
        ]) {
            return Self.clamp((100 - usedPercent) / 100)
        }

        if let remainingPercent = quotaMetaNumber(for: [
            "remainingPercent",
            "remaining_percent",
            "remainingPercentage",
            "remaining_percentage",
            "percentRemaining",
            "percent_remaining"
        ]) {
            return Self.clamp(remainingPercent / 100)
        }

        let unit = meta?["unit"]?.lowercased()
        let limitKind = meta?["limitKind"]?.lowercased()
        if unit == "unlimited" || limitKind == "unlimited" {
            return 1
        }

        guard used.isFinite, limit.isFinite, remaining.isFinite else {
            return nil
        }

        if limit > 0 {
            return Self.clamp(max(0, remaining) / limit)
        }

        if unit == "percent" || unit == "%" {
            if remaining >= 0 {
                return Self.clamp(remaining / 100)
            }
            if used >= 0 {
                return Self.clamp((100 - used) / 100)
            }
        }

        if limit < 0, remaining > 0 {
            // Remaining-only or balance-only provider signals have no cap, so
            // they should not be presented as exhausted.
            let syntheticLimit = remaining + max(0, used)
            return syntheticLimit > 0 ? Self.clamp(remaining / syntheticLimit) : 1
        }

        return nil
    }

    var displayRemainingPercent: Double? {
        displayRemainingFraction.map { $0 * 100 }
    }

    private func quotaMetaNumber(for keys: [String]) -> Double? {
        guard let meta else { return nil }
        for key in keys {
            guard let raw = meta[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.isEmpty == false else { continue }
            if let value = Double(raw.replacingOccurrences(of: "%", with: "")) {
                return value
            }
        }
        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    var isDisplayableQuotaSignal: Bool {
        guard limit.isFinite, used.isFinite, remaining.isFinite else {
            return false
        }

        let marker = "\(name) \(meta?["label"] ?? "")".lowercased()
        if ["cache", "hit rate", "local model", "cloud model", "installed"].contains(where: marker.contains) {
            return false
        }
        // Short generic words must match whole tokens only: a raw `contains`
        // check blacklists real quota buckets whose identifiers merely embed
        // the word — "codex-profile-5h" contains "file", "statusline"
        // contains "line" — silently hiding genuine percentage signals.
        let markerTokens = Set(
            marker.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        )
        if !markerTokens.isDisjoint(with: [
            "task", "tasks", "conversation", "conversations",
            "line", "lines", "file", "files"
        ]) {
            return false
        }

        if let unit = meta?["unit"]?.lowercased() {
            if ["sessions", "session", "lines", "files", "models"].contains(unit) {
                return false
            }
            if unit == "count" && !(marker.contains("credit") || marker.contains("budget")) {
                return false
            }
        }

        return displayRemainingFraction != nil
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
    public var quotaProvider: AgentProvider? {
        AgentProvider.fromProviderID(providerID)
            ?? AgentProvider.fromPersistedToken(provider)
            ?? AgentProvider(rawValue: provider)
    }

    var displayableQuotaBuckets: [ProviderQuotaBucket] {
        // Reconcile each survivor to the current moment so a rolled-over window
        // reports its fresh (0 used / full remaining) state. This is the single
        // chokepoint feeding the popover, customizedBuckets, the cross-surface
        // sync writer (`filteringToDisplayableQuotaSignal`), and the iOS rows.
        buckets.filter(\.isDisplayableQuotaSignal).map { $0.reconcilingElapsedWindow() }
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

    func isTooOldForQuotaDecisions(relativeTo now: Date = Date()) -> Bool {
        isStale(relativeTo: now)
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

    var providerToken: String {
        quotaProvider?.persistedToken ?? provider.lowercased()
    }

    func customizedBuckets(
        hiddenBuckets: Set<String>,
        bucketOrders: [String: [String]]
    ) -> [ProviderQuotaBucket] {
        let displayable = displayableQuotaBuckets
        let token = providerToken

        let filtered = displayable.filter { bucket in
            let compositeKey = "\(token):\(bucket.key)"
            return !hiddenBuckets.contains(compositeKey)
        }

        if let customOrder = bucketOrders[token] {
            return filtered.sorted { lhs, rhs in
                let lhsIdx = customOrder.firstIndex(of: lhs.key) ?? Int.max
                let rhsIdx = customOrder.firstIndex(of: rhs.key) ?? Int.max
                if lhsIdx != rhsIdx {
                    return lhsIdx < rhsIdx
                }
                return lhs.label.localizedCompare(rhs.label) == .orderedAscending
            }
        }

        return filtered
    }
}

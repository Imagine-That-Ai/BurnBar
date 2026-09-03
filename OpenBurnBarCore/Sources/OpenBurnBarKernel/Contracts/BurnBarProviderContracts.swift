import Foundation

public enum BurnBarProviderCredentialSlotStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case ready
    case coolingDown
    case exhausted
    case disabled
    case missingSecret
}

public struct BurnBarProviderCredentialSlot: Codable, Hashable, Identifiable, Sendable {
    public let slotID: String
    public var label: String
    public var isEnabled: Bool
    public var status: BurnBarProviderCredentialSlotStatus
    public var cooldownUntil: Date?
    public var lastSelectedAt: Date?
    public var lastQuotaRemainingPercent: Double?
    public var lastQuotaResetsAt: Date?
    public var lastStatusMessage: String?
    public var endpointProfileID: String?
    public var region: ProviderEndpointRegion?
    public var tokenPlanTier: MimoTokenPlanTier?
    public var tokenPlanBillingCycle: MimoTokenPlanBillingCycle?
    public var authMethodID: String?
    public var updatedAt: Date

    public var id: String { slotID }

    public init(
        slotID: String = UUID().uuidString,
        label: String,
        isEnabled: Bool = true,
        status: BurnBarProviderCredentialSlotStatus = .ready,
        cooldownUntil: Date? = nil,
        lastSelectedAt: Date? = nil,
        lastQuotaRemainingPercent: Double? = nil,
        lastQuotaResetsAt: Date? = nil,
        lastStatusMessage: String? = nil,
        endpointProfileID: String? = nil,
        region: ProviderEndpointRegion? = nil,
        tokenPlanTier: MimoTokenPlanTier? = nil,
        tokenPlanBillingCycle: MimoTokenPlanBillingCycle? = nil,
        authMethodID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.slotID = slotID
        self.label = label
        self.isEnabled = isEnabled
        self.status = status
        self.cooldownUntil = cooldownUntil
        self.lastSelectedAt = lastSelectedAt
        self.lastQuotaRemainingPercent = lastQuotaRemainingPercent
        self.lastQuotaResetsAt = lastQuotaResetsAt
        self.lastStatusMessage = lastStatusMessage
        self.endpointProfileID = endpointProfileID
        self.region = region
        self.tokenPlanTier = tokenPlanTier
        self.tokenPlanBillingCycle = tokenPlanBillingCycle
        self.authMethodID = authMethodID
        self.updatedAt = updatedAt
    }
}

public struct BurnBarOllamaEndpointConfig: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var baseURL: String
    public var apiKeyRef: String?
    public var label: String
    public var priority: Int
    public var enabled: Bool

    public init(
        id: String,
        baseURL: String,
        apiKeyRef: String? = nil,
        label: String = "",
        priority: Int = 0,
        enabled: Bool = true
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.label = label
        self.priority = priority
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case baseURL
        case apiKeyRef
        case label
        case priority
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = BurnBarOllamaEndpointConfig(
            id: try container.decode(String.self, forKey: .id),
            baseURL: try container.decode(String.self, forKey: .baseURL),
            apiKeyRef: try container.decodeIfPresent(String.self, forKey: .apiKeyRef),
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            priority: try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0,
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
        do {
            self = try Self.normalized(decoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .baseURL,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    public static func normalized(_ endpoint: BurnBarOllamaEndpointConfig) throws -> BurnBarOllamaEndpointConfig {
        let normalizedID = endpoint.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw ValidationError.emptyID
        }

        let normalizedBaseURL = try normalizedHTTPBaseURL(endpoint.baseURL)
        let normalizedAPIKeyRef = endpoint.apiKeyRef?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        let normalizedLabel = endpoint.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? normalizedID

        return BurnBarOllamaEndpointConfig(
            id: normalizedID,
            baseURL: normalizedBaseURL,
            apiKeyRef: normalizedAPIKeyRef,
            label: normalizedLabel,
            priority: endpoint.priority,
            enabled: endpoint.enabled
        )
    }

    public static func normalizedList(_ endpoints: [BurnBarOllamaEndpointConfig]) throws -> [BurnBarOllamaEndpointConfig] {
        var seen = Set<String>()
        var normalized: [BurnBarOllamaEndpointConfig] = []
        normalized.reserveCapacity(endpoints.count)

        for endpoint in endpoints {
            let normalizedEndpoint = try Self.normalized(endpoint)
            let key = normalizedEndpoint.id.lowercased()
            guard seen.insert(key).inserted else {
                throw ValidationError.duplicateID(normalizedEndpoint.id)
            }
            normalized.append(normalizedEndpoint)
        }

        return normalized.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    public static func synthesizedLegacyDefault(
        providerBaseURL: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BurnBarOllamaEndpointConfig {
        let baseURL = normalizedOllamaServerRoot(environment["OLLAMA_HOST"])
            ?? normalizedOllamaServerRoot(providerBaseURL)
            ?? "http://localhost:11434"
        return BurnBarOllamaEndpointConfig(
            id: "default",
            baseURL: baseURL,
            label: "Default endpoint",
            priority: 0,
            enabled: true
        )
    }

    public static func normalizedOllamaServerRoot(_ rawValue: String?) -> String? {
        guard var rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        if !rawValue.contains("://") {
            rawValue = "http://\(rawValue)"
        }
        guard var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let normalizedPath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.caseInsensitiveCompare("v1") == .orderedSame
            || normalizedPath.lowercased().hasSuffix("/v1") {
            var parts = normalizedPath.split(separator: "/").map(String.init)
            if parts.last?.caseInsensitiveCompare("v1") == .orderedSame {
                parts.removeLast()
                components.percentEncodedPath = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
            }
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }
        components.query = nil
        components.fragment = nil
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalizedHTTPBaseURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ValidationError.invalidBaseURL(rawValue)
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }
        components.fragment = nil
        guard let value = components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              !value.isEmpty else {
            throw ValidationError.invalidBaseURL(rawValue)
        }
        return value
    }

    public enum ValidationError: Error, LocalizedError, Hashable {
        case emptyID
        case duplicateID(String)
        case invalidBaseURL(String)

        public var errorDescription: String? {
            switch self {
            case .emptyID:
                return "Ollama endpoint id must not be empty."
            case .duplicateID(let id):
                return "Ollama endpoint id '\(id)' is duplicated."
            case .invalidBaseURL(let baseURL):
                return "Ollama endpoint baseURL '\(baseURL)' must be an http(s) URL."
            }
        }
    }
}

public enum BurnBarProviderCredentialSlotRoutingPolicy {
    public static let defaultExhaustionRetryInterval: TimeInterval = 30 * 60

    public static func canAttemptRoute(
        status: BurnBarProviderCredentialSlotStatus,
        isEnabled: Bool,
        hasCredential: Bool,
        cooldownUntil: Date?,
        lastQuotaRemainingPercent: Double?,
        lastQuotaResetsAt: Date?,
        lastStatusMessage: String?,
        updatedAt: Date,
        now: Date = Date(),
        exhaustionRetryInterval: TimeInterval = defaultExhaustionRetryInterval
    ) -> Bool {
        guard isEnabled, hasCredential else { return false }
        return effectiveStatus(
            status: status,
            isEnabled: isEnabled,
            cooldownUntil: cooldownUntil,
            lastQuotaRemainingPercent: lastQuotaRemainingPercent,
            lastQuotaResetsAt: lastQuotaResetsAt,
            lastStatusMessage: lastStatusMessage,
            updatedAt: updatedAt,
            now: now,
            exhaustionRetryInterval: exhaustionRetryInterval
        ) == .ready
    }

    public static func canAttemptRoute(
        slot: BurnBarProviderCredentialSlot,
        providerID: String? = nil,
        hasCredential: Bool,
        providerEnabled: Bool = true,
        now: Date = Date(),
        exhaustionRetryInterval: TimeInterval = defaultExhaustionRetryInterval
    ) -> Bool {
        if let providerID,
           !BurnBarProviderAuthRegistry.authMethodAllowsProxyRouting(
            providerID: providerID,
            authMethodID: slot.authMethodID
           ) {
            return false
        }
        return canAttemptRoute(
            status: slot.status,
            isEnabled: providerEnabled && slot.isEnabled,
            hasCredential: hasCredential,
            cooldownUntil: slot.cooldownUntil,
            lastQuotaRemainingPercent: slot.lastQuotaRemainingPercent,
            lastQuotaResetsAt: slot.lastQuotaResetsAt,
            lastStatusMessage: slot.lastStatusMessage,
            updatedAt: slot.updatedAt,
            now: now,
            exhaustionRetryInterval: exhaustionRetryInterval
        )
    }

    public static func effectiveStatus(
        for slot: BurnBarProviderCredentialSlot,
        providerEnabled: Bool = true,
        now: Date = Date(),
        exhaustionRetryInterval: TimeInterval = defaultExhaustionRetryInterval
    ) -> BurnBarProviderCredentialSlotStatus {
        effectiveStatus(
            status: slot.status,
            isEnabled: providerEnabled && slot.isEnabled,
            cooldownUntil: slot.cooldownUntil,
            lastQuotaRemainingPercent: slot.lastQuotaRemainingPercent,
            lastQuotaResetsAt: slot.lastQuotaResetsAt,
            lastStatusMessage: slot.lastStatusMessage,
            updatedAt: slot.updatedAt,
            now: now,
            exhaustionRetryInterval: exhaustionRetryInterval
        )
    }

    public static func effectiveStatus(
        status: BurnBarProviderCredentialSlotStatus,
        isEnabled: Bool,
        cooldownUntil: Date?,
        lastQuotaRemainingPercent: Double?,
        lastQuotaResetsAt: Date?,
        lastStatusMessage: String?,
        updatedAt: Date,
        now: Date = Date(),
        exhaustionRetryInterval: TimeInterval = defaultExhaustionRetryInterval
    ) -> BurnBarProviderCredentialSlotStatus {
        guard isEnabled else { return .disabled }
        switch status {
        case .disabled, .missingSecret:
            return status
        case .ready:
            if let remaining = lastQuotaRemainingPercent, remaining <= 0 {
                return isStale(updatedAt: updatedAt, now: now, interval: exhaustionRetryInterval) ? .ready : .exhausted
            }
            return .ready
        case .coolingDown:
            let resetDates = resetBlockDates(
                cooldownUntil: cooldownUntil,
                lastQuotaResetsAt: lastQuotaResetsAt,
                lastStatusMessage: lastStatusMessage
            )
            if resetDates.contains(where: { $0 > now }) {
                return .coolingDown
            }
            if !resetDates.isEmpty {
                return .ready
            }
            return .ready
        case .exhausted:
            let resetDates = resetBlockDates(
                cooldownUntil: cooldownUntil,
                lastQuotaResetsAt: lastQuotaResetsAt,
                lastStatusMessage: lastStatusMessage
            )
            if resetDates.contains(where: { $0 > now }) {
                return .coolingDown
            }
            if !resetDates.isEmpty {
                return .ready
            }
            if let remaining = lastQuotaRemainingPercent, remaining > 0 {
                return .ready
            }
            return isStale(updatedAt: updatedAt, now: now, interval: exhaustionRetryInterval) ? .ready : .exhausted
        }
    }

    public static func resetDate(from message: String?) -> Date? {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let pattern = #"(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\s*(Z|[+-]\d{2}:?\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              let dateRange = Range(match.range(at: 1), in: message),
              let timeRange = Range(match.range(at: 2), in: message) else {
            return nil
        }
        let timezoneRange = match.range(at: 3).location == NSNotFound
            ? nil
            : Range(match.range(at: 3), in: message)
        let datePart = String(message[dateRange])
        let timePart = String(message[timeRange])
        let timezonePart = timezoneRange.map { String(message[$0]) } ?? ""
        return parseResetDate("\(datePart) \(timePart)\(timezonePart)")
    }

    private static func resetBlockDates(
        cooldownUntil: Date?,
        lastQuotaResetsAt: Date?,
        lastStatusMessage: String?
    ) -> [Date] {
        [cooldownUntil, lastQuotaResetsAt, resetDate(from: lastStatusMessage)]
            .compactMap { $0 }
            .sorted()
    }

    private static func isStale(updatedAt: Date, now: Date, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(updatedAt) >= interval
    }

    private static func parseResetDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)

        let hasTimezone = value.hasSuffix("Z")
            || value.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        if hasTimezone {
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
            if let parsed = formatter.date(from: value) {
                return parsed
            }
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
            return formatter.date(from: value)
        }

        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

/// Thinking-level ladder shared across providers.
///
/// Anthropic maps each level to a `thinking.budget_tokens` budget (and the new
/// `effort` parameter shipped under `effort-2025-11-24`). OpenAI maps each
/// level to `reasoning_effort` / `reasoning.effort`. `.max` collapses to
/// `xhigh` on OpenAI (no higher tier exists) while pushing Anthropic's budget
/// to its documented effective ceiling.
public enum BurnBarThinkingLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    /// Lower-case slug used to suffix a variant's wire id (`claude-opus-4-7-xhigh`).
    public var slug: String { rawValue }

    /// Human-friendly label used in the Settings editor and `displayName`.
    public var displayLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        }
    }

    /// Anthropic `thinking.budget_tokens` value. Pinned to documented tiers.
    public var anthropicBudgetTokens: Int {
        switch self {
        case .low: return 2048
        case .medium: return 4096
        case .high: return 8192
        case .xhigh: return 16384
        case .max: return 32768
        }
    }

    /// OpenAI `reasoning_effort` / `reasoning.effort` value. `.max` collapses
    /// to `xhigh` since OpenAI does not expose a higher tier.
    public var openAIEffort: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh, .max: return "xhigh"
        }
    }

    /// Anthropic `effort` value sent on routes that include the `effort-2025-11-24`
    /// beta. `.max` collapses to `xhigh` because Anthropic only documents up to
    /// `xhigh`; the deeper budget is expressed via `thinking.budget_tokens`.
    public var anthropicEffort: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh, .max: return "xhigh"
        }
    }

    /// Sort order from lowest effort to highest.
    public var ladderIndex: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .xhigh: return 3
        case .max: return 4
        }
    }
}

/// A user-defined variant of an advertised model that pins a specific
/// `BurnBarThinkingLevel` (and optional `maxOutputTokens`). Variants are
/// surfaced as distinct rows in `/v1/models` and in every wired CLI's model
/// picker, with stable wire ids derived from the base model id + level slug.
public struct BurnBarModelVariant: Codable, Hashable, Identifiable, Sendable {
    public let variantID: String
    public var label: String
    public var baseModelID: String
    public var thinkingLevel: BurnBarThinkingLevel
    public var maxOutputTokens: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { variantID }

    public init(
        variantID: String,
        label: String,
        baseModelID: String,
        thinkingLevel: BurnBarThinkingLevel,
        maxOutputTokens: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.variantID = variantID
        self.label = label
        self.baseModelID = baseModelID
        self.thinkingLevel = thinkingLevel
        self.maxOutputTokens = maxOutputTokens
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Default wire id derived from the base model + level (`claude-opus-4-7-xhigh`).
    public static func defaultVariantID(baseModelID: String, level: BurnBarThinkingLevel) -> String {
        let trimmed = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmed)-\(level.slug)"
    }

    /// Default label rendered alongside the variant ("XHigh").
    public static func defaultLabel(for level: BurnBarThinkingLevel) -> String {
        level.displayLabel
    }
}

/// A user-defined proxy alias that exposes a base model under a custom wire id
/// in `/v1/models` and wired CLI pickers while routing through `baseModelID`.
public struct BurnBarModelAlias: Codable, Hashable, Identifiable, Sendable {
    public var aliasID: String
    public var baseModelID: String
    public var displayName: String
    public var hidesBaseModel: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { aliasID }

    public init(
        aliasID: String,
        baseModelID: String,
        displayName: String = "",
        hidesBaseModel: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.aliasID = aliasID
        self.baseModelID = baseModelID
        self.displayName = displayName
        self.hidesBaseModel = hidesBaseModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Characters allowed in a user-chosen alias wire id.
    public static let allowedAliasIDCharacterSet = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-:/"))

    public static func isValidAliasID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { allowedAliasIDCharacterSet.contains($0) }
    }

    public static func normalizedDisplayName(aliasID: String, displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A user-defined display-name override for an advertised model.
///
/// Unlike `BurnBarModelAlias`, this does **not** introduce a new wire id and
/// does **not** change how the model is routed — the model keeps being called
/// by its canonical `modelID`. It only relabels how the model *presents to
/// humans*: the `display_name` emitted in `/v1/models`, every wired CLI's
/// picker, and the BurnBar / Hermes / PI apps. This is "rename", not "alias".
///
/// The chosen name is honored **verbatim** end-to-end — free text (spaces,
/// punctuation, mixed case allowed) emitted exactly as typed, without the
/// provider / route / reasoning suffixes the gateway otherwise composes.
public struct BurnBarModelDisplayOverride: Codable, Hashable, Identifiable, Sendable {
    /// The canonical advertised wire id this override relabels. Stable: the
    /// model keeps routing under this id; only its human label changes.
    public var modelID: String
    /// The verbatim, human-facing name. Free text emitted exactly as typed.
    public var displayName: String
    public var createdAt: Date
    public var updatedAt: Date

    /// Keyed case-insensitively by `modelID` so a rename replaces the prior
    /// override for the same model regardless of casing.
    public var id: String { Self.normalizedModelID(modelID).lowercased() }

    public init(
        modelID: String,
        displayName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A display name is usable once it carries at least one visible
    /// character. Empty / whitespace-only input clears the override instead.
    public static func isValidDisplayName(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Trim a candidate model id for stable keying.
    public static func normalizedModelID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trim a candidate display name to its emitted form.
    public static func normalizedDisplayName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A user-declared provider model that the bundled catalog does not know about.
///
/// Unlike `BurnBarModelAlias` (which points a brand-new wire id at an *existing*
/// base model and routes through it), a custom model advertises a model id that
/// the **provider itself serves** — the gateway routes it verbatim to the
/// provider, exactly like a model surfaced by live `/models` discovery. This is
/// the escape hatch for models newer than the bundled catalog when live
/// discovery can't see them (no credential yet, or an upstream that doesn't list
/// the id). The model presents to humans as `displayName`.
public struct BurnBarCustomModel: Codable, Hashable, Identifiable, Sendable {
    /// The wire id sent to the provider and advertised in `/v1/models`.
    public var modelID: String
    /// Human-facing label; falls back to `modelID` when blank.
    public var displayName: String
    public var createdAt: Date
    public var updatedAt: Date

    /// Keyed case-insensitively by `modelID` so re-adding the same id replaces
    /// the prior entry regardless of casing.
    public var id: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    public init(
        modelID: String,
        displayName: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Characters allowed in a user-chosen model id. Matches the alias charset
    /// so provider-style ids (`minimax-m3`, `glm-5.1`, `kimi-k2.6:cloud`,
    /// `moonshotai/Kimi-K2.6`) are accepted verbatim.
    public static let allowedModelIDCharacterSet = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-:/"))

    public static func isValidModelID(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { allowedModelIDCharacterSet.contains($0) }
    }

    public static func normalizedDisplayName(modelID: String, displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct BurnBarProviderSettings: Codable, Hashable, Identifiable, Sendable {
    public let providerID: String
    public var isEnabled: Bool
    public var baseURL: String
    public var preferredModelIDs: [String]
    public var disabledAdvertisedModelIDs: [String]
    public var preferredCredentialSlotID: String?
    public var credentialSlots: [BurnBarProviderCredentialSlot]
    /// Local Ollama endpoint slots. Only `providerID == "ollama-local"` uses
    /// this field; when absent, the daemon synthesizes a legacy `default`
    /// endpoint from `OLLAMA_HOST`, the provider base URL, or localhost.
    public var ollamaEndpoints: [BurnBarOllamaEndpointConfig]
    /// User-defined thinking-level variants. Each variant ships as its own
    /// row in `/v1/models` and in every wired CLI's picker, while still
    /// routing through `baseModelID`.
    public var modelVariants: [BurnBarModelVariant]
    /// User-defined proxy aliases with custom wire ids and optional hide-base behavior.
    public var modelAliases: [BurnBarModelAlias]
    /// User-defined display name overrides.
    public var modelDisplayOverrides: [BurnBarModelDisplayOverride]
    /// User-declared provider models the bundled catalog does not know about.
    /// Advertised and routed verbatim through the provider, like a live-
    /// discovered model.
    public var customModels: [BurnBarCustomModel]

    public var id: String { providerID }

    public init(
        providerID: String,
        isEnabled: Bool = false,
        baseURL: String,
        preferredModelIDs: [String],
        disabledAdvertisedModelIDs: [String] = [],
        preferredCredentialSlotID: String? = nil,
        credentialSlots: [BurnBarProviderCredentialSlot] = [],
        ollamaEndpoints: [BurnBarOllamaEndpointConfig] = [],
        modelVariants: [BurnBarModelVariant] = [],
        modelAliases: [BurnBarModelAlias] = [],
        modelDisplayOverrides: [BurnBarModelDisplayOverride] = [],
        customModels: [BurnBarCustomModel] = []
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.preferredModelIDs = preferredModelIDs
        self.disabledAdvertisedModelIDs = Self.normalizedDisabledAdvertisedModelIDs(disabledAdvertisedModelIDs)
        self.preferredCredentialSlotID = preferredCredentialSlotID
        self.credentialSlots = credentialSlots
        self.ollamaEndpoints = (try? BurnBarOllamaEndpointConfig.normalizedList(ollamaEndpoints)) ?? ollamaEndpoints
        self.modelVariants = Self.normalizedModelVariants(modelVariants)
        self.modelAliases = Self.normalizedModelAliases(modelAliases)
        self.modelDisplayOverrides = Self.normalizedModelDisplayOverrides(modelDisplayOverrides)
        self.customModels = Self.normalizedCustomModels(customModels)
    }

    public func isModelAdvertisementEnabled(_ modelID: String) -> Bool {
        let normalized = Self.normalizedAdvertisedModelID(modelID)
        guard !normalized.isEmpty else { return true }
        return !Set(disabledAdvertisedModelIDs.map(Self.normalizedAdvertisedModelID)).contains(normalized)
    }

    public mutating func setModelAdvertisement(modelID: String, isEnabled: Bool) {
        let normalized = Self.normalizedAdvertisedModelID(modelID)
        guard !normalized.isEmpty else { return }
        var disabled = Set(disabledAdvertisedModelIDs.map(Self.normalizedAdvertisedModelID))
        if isEnabled {
            disabled.remove(normalized)
        } else {
            disabled.insert(normalized)
        }
        disabledAdvertisedModelIDs = disabled.sorted()
    }

    /// Bulk variant of `setModelAdvertisement`: flip every supplied model id in
    /// a single mutation so an entire provider can be muted (or unmuted) at
    /// once, after which individual models can be toggled back on selectively.
    public mutating func setModelsAdvertisement(modelIDs: [String], isEnabled: Bool) {
        var disabled = Set(disabledAdvertisedModelIDs.map(Self.normalizedAdvertisedModelID))
        for modelID in modelIDs {
            let normalized = Self.normalizedAdvertisedModelID(modelID)
            guard !normalized.isEmpty else { continue }
            if isEnabled {
                disabled.remove(normalized)
            } else {
                disabled.insert(normalized)
            }
        }
        disabledAdvertisedModelIDs = disabled.sorted()
    }

    /// Insert or update a variant, keyed by `variantID`. Touches `updatedAt`.
    public mutating func upsertModelVariant(_ variant: BurnBarModelVariant) {
        var working = modelVariants
        var inserted = variant
        inserted.updatedAt = Date()
        if let index = working.firstIndex(where: { $0.variantID == inserted.variantID }) {
            inserted.createdAt = working[index].createdAt
            working[index] = inserted
        } else {
            working.append(inserted)
        }
        modelVariants = Self.normalizedModelVariants(working)
    }

    /// Remove a variant by id. Returns `true` if a row was removed.
    @discardableResult
    public mutating func removeModelVariant(variantID: String) -> Bool {
        let trimmed = variantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let before = modelVariants.count
        modelVariants.removeAll { $0.variantID.caseInsensitiveCompare(trimmed) == .orderedSame }
        return modelVariants.count != before
    }

    /// Variants that target a specific base model id.
    public func variants(forBaseModelID baseModelID: String) -> [BurnBarModelVariant] {
        let normalized = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return modelVariants.filter {
            $0.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    /// Insert or update an alias, keyed by `aliasID`. Touches `updatedAt`.
    public mutating func upsertModelAlias(_ alias: BurnBarModelAlias) {
        var working = modelAliases
        var inserted = alias
        inserted.updatedAt = Date()
        if let index = working.firstIndex(where: { $0.aliasID.caseInsensitiveCompare(inserted.aliasID) == .orderedSame }) {
            inserted.createdAt = working[index].createdAt
            working[index] = inserted
        } else {
            working.append(inserted)
        }
        modelAliases = Self.normalizedModelAliases(working)
    }

    /// Remove an alias by id. Returns `true` if a row was removed.
    @discardableResult
    public mutating func removeModelAlias(aliasID: String) -> Bool {
        let trimmed = aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let before = modelAliases.count
        modelAliases.removeAll { $0.aliasID.caseInsensitiveCompare(trimmed) == .orderedSame }
        return modelAliases.count != before
    }

    /// Aliases that target a specific base model id.
    public func aliases(forBaseModelID baseModelID: String) -> [BurnBarModelAlias] {
        let normalized = baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return modelAliases.filter {
            $0.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    /// Insert or update an override, keyed by `modelID`. Touches `updatedAt`.
    public mutating func upsertModelDisplayOverride(_ override: BurnBarModelDisplayOverride) {
        var working = modelDisplayOverrides
        var inserted = override
        inserted.updatedAt = Date()
        if let index = working.firstIndex(where: { $0.modelID.caseInsensitiveCompare(inserted.modelID) == .orderedSame }) {
            inserted.createdAt = working[index].createdAt
            working[index] = inserted
        } else {
            working.append(inserted)
        }
        modelDisplayOverrides = Self.normalizedModelDisplayOverrides(working)
    }

    /// Remove an override by model id. Returns `true` if a row was removed.
    @discardableResult
    public mutating func removeModelDisplayOverride(modelID: String) -> Bool {
        let trimmed = BurnBarModelDisplayOverride.normalizedModelID(modelID)
        guard !trimmed.isEmpty else { return false }
        let before = modelDisplayOverrides.count
        modelDisplayOverrides.removeAll { $0.modelID.caseInsensitiveCompare(trimmed) == .orderedSame }
        return modelDisplayOverrides.count != before
    }

    /// Get the display override for a specific model id.
    public func displayOverride(forModelID modelID: String) -> BurnBarModelDisplayOverride? {
        let trimmed = BurnBarModelDisplayOverride.normalizedModelID(modelID)
        guard !trimmed.isEmpty else { return nil }
        return modelDisplayOverrides.first { $0.modelID.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The verbatim override name for a model id, or `nil` when none applies.
    /// Returns the trimmed, non-empty display string ready to emit as-is.
    public func displayName(forModelID modelID: String) -> String? {
        guard let override = displayOverride(forModelID: modelID) else { return nil }
        let trimmed = BurnBarModelDisplayOverride.normalizedDisplayName(override.displayName)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Insert or update a custom model, keyed case-insensitively by `modelID`.
    /// Touches `updatedAt`.
    public mutating func upsertCustomModel(_ model: BurnBarCustomModel) {
        var working = customModels
        var inserted = model
        inserted.updatedAt = Date()
        if let index = working.firstIndex(where: { $0.modelID.caseInsensitiveCompare(inserted.modelID) == .orderedSame }) {
            inserted.createdAt = working[index].createdAt
            working[index] = inserted
        } else {
            working.append(inserted)
        }
        customModels = Self.normalizedCustomModels(working)
    }

    /// Remove a custom model by id. Returns `true` if a row was removed.
    @discardableResult
    public mutating func removeCustomModel(modelID: String) -> Bool {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let before = customModels.count
        customModels.removeAll { $0.modelID.caseInsensitiveCompare(trimmed) == .orderedSame }
        return customModels.count != before
    }

    /// The custom model registered for a wire id, or `nil` when none applies.
    public func customModel(forModelID modelID: String) -> BurnBarCustomModel? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return customModels.first { $0.modelID.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isEnabled
        case baseURL
        case preferredModelIDs
        case disabledAdvertisedModelIDs
        case preferredCredentialSlotID
        case credentialSlots
        case ollamaEndpoints
        case modelVariants
        case modelAliases
        case modelDisplayOverrides
        case customModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        preferredModelIDs = try container.decode([String].self, forKey: .preferredModelIDs)
        disabledAdvertisedModelIDs = Self.normalizedDisabledAdvertisedModelIDs(
            try container.decodeIfPresent([String].self, forKey: .disabledAdvertisedModelIDs) ?? []
        )
        preferredCredentialSlotID = try container.decodeIfPresent(String.self, forKey: .preferredCredentialSlotID)
        credentialSlots = try container.decodeIfPresent([BurnBarProviderCredentialSlot].self, forKey: .credentialSlots) ?? []
        if let decodedOllamaEndpoints = try container.decodeIfPresent([BurnBarOllamaEndpointConfig].self, forKey: .ollamaEndpoints) {
            do {
                ollamaEndpoints = try BurnBarOllamaEndpointConfig.normalizedList(decodedOllamaEndpoints)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .ollamaEndpoints,
                    in: container,
                    debugDescription: error.localizedDescription
                )
            }
        } else if providerID.caseInsensitiveCompare("ollama-local") == .orderedSame {
            ollamaEndpoints = [
                BurnBarOllamaEndpointConfig.synthesizedLegacyDefault(providerBaseURL: baseURL)
            ]
        } else {
            ollamaEndpoints = []
        }
        modelVariants = Self.normalizedModelVariants(
            try container.decodeIfPresent([BurnBarModelVariant].self, forKey: .modelVariants) ?? []
        )
        modelAliases = Self.normalizedModelAliases(
            try container.decodeIfPresent([BurnBarModelAlias].self, forKey: .modelAliases) ?? []
        )
        modelDisplayOverrides = Self.normalizedModelDisplayOverrides(
            try container.decodeIfPresent([BurnBarModelDisplayOverride].self, forKey: .modelDisplayOverrides) ?? []
        )
        customModels = Self.normalizedCustomModels(
            try container.decodeIfPresent([BurnBarCustomModel].self, forKey: .customModels) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(preferredModelIDs, forKey: .preferredModelIDs)
        try container.encode(disabledAdvertisedModelIDs, forKey: .disabledAdvertisedModelIDs)
        try container.encodeIfPresent(preferredCredentialSlotID, forKey: .preferredCredentialSlotID)
        try container.encode(credentialSlots, forKey: .credentialSlots)
        if !ollamaEndpoints.isEmpty || providerID.caseInsensitiveCompare("ollama-local") == .orderedSame {
            try container.encode(ollamaEndpoints, forKey: .ollamaEndpoints)
        }
        try container.encode(modelVariants, forKey: .modelVariants)
        try container.encode(modelAliases, forKey: .modelAliases)
        try container.encode(modelDisplayOverrides, forKey: .modelDisplayOverrides)
        try container.encode(customModels, forKey: .customModels)
    }

    private static func normalizedDisabledAdvertisedModelIDs(_ modelIDs: [String]) -> [String] {
        var seen = Set<String>()
        return modelIDs.compactMap { raw in
            let normalized = normalizedAdvertisedModelID(raw)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func normalizedAdvertisedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedModelVariants(_ variants: [BurnBarModelVariant]) -> [BurnBarModelVariant] {
        var seen = Set<String>()
        return variants.compactMap { raw in
            let trimmedID = raw.variantID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBase = raw.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty,
                  !trimmedBase.isEmpty,
                  seen.insert(trimmedID.lowercased()).inserted else {
                return nil
            }
            let label = raw.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTokens: Int? = raw.maxOutputTokens.flatMap { tokens in
                tokens > 0 ? tokens : nil
            }
            return BurnBarModelVariant(
                variantID: trimmedID,
                label: label.isEmpty ? BurnBarModelVariant.defaultLabel(for: raw.thinkingLevel) : label,
                baseModelID: trimmedBase,
                thinkingLevel: raw.thinkingLevel,
                maxOutputTokens: normalizedTokens,
                createdAt: raw.createdAt,
                updatedAt: raw.updatedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.baseModelID.caseInsensitiveCompare(rhs.baseModelID) != .orderedSame {
                return lhs.baseModelID.localizedCaseInsensitiveCompare(rhs.baseModelID) == .orderedAscending
            }
            return lhs.thinkingLevel.ladderIndex < rhs.thinkingLevel.ladderIndex
        }
    }

    private static func normalizedModelAliases(_ aliases: [BurnBarModelAlias]) -> [BurnBarModelAlias] {
        var seen = Set<String>()
        return aliases.compactMap { raw in
            let trimmedID = raw.aliasID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBase = raw.baseModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard BurnBarModelAlias.isValidAliasID(trimmedID),
                  !trimmedBase.isEmpty,
                  trimmedID.caseInsensitiveCompare(trimmedBase) != .orderedSame,
                  seen.insert(trimmedID.lowercased()).inserted else {
                return nil
            }
            return BurnBarModelAlias(
                aliasID: trimmedID,
                baseModelID: trimmedBase,
                displayName: BurnBarModelAlias.normalizedDisplayName(aliasID: trimmedID, displayName: raw.displayName),
                hidesBaseModel: raw.hidesBaseModel,
                createdAt: raw.createdAt,
                updatedAt: raw.updatedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.baseModelID.caseInsensitiveCompare(rhs.baseModelID) != .orderedSame {
                return lhs.baseModelID.localizedCaseInsensitiveCompare(rhs.baseModelID) == .orderedAscending
            }
            return lhs.aliasID.localizedCaseInsensitiveCompare(rhs.aliasID) == .orderedAscending
        }
    }

    private static func normalizedModelDisplayOverrides(_ overrides: [BurnBarModelDisplayOverride]) -> [BurnBarModelDisplayOverride] {
        var seen = Set<String>()
        return overrides.compactMap { raw in
            let trimmedModelID = BurnBarModelDisplayOverride.normalizedModelID(raw.modelID)
            let trimmedDisplayName = BurnBarModelDisplayOverride.normalizedDisplayName(raw.displayName)
            guard !trimmedModelID.isEmpty,
                  BurnBarModelDisplayOverride.isValidDisplayName(trimmedDisplayName),
                  seen.insert(trimmedModelID.lowercased()).inserted else {
                return nil
            }
            return BurnBarModelDisplayOverride(
                modelID: trimmedModelID,
                displayName: trimmedDisplayName,
                createdAt: raw.createdAt,
                updatedAt: raw.updatedAt
            )
        }
        .sorted { lhs, rhs in
            lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
        }
    }

    private static func normalizedCustomModels(_ models: [BurnBarCustomModel]) -> [BurnBarCustomModel] {
        var seen = Set<String>()
        return models.compactMap { raw in
            let trimmedID = raw.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard BurnBarCustomModel.isValidModelID(trimmedID),
                  seen.insert(trimmedID.lowercased()).inserted else {
                return nil
            }
            return BurnBarCustomModel(
                modelID: trimmedID,
                displayName: BurnBarCustomModel.normalizedDisplayName(modelID: trimmedID, displayName: raw.displayName),
                createdAt: raw.createdAt,
                updatedAt: raw.updatedAt
            )
        }
        .sorted { lhs, rhs in
            lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
        }
    }
}

/// Memory Pro egress policy: what the memory engine may send to which
/// providers. Written by the app from the consent UI, read by the loopback
/// gateway before any memory-purpose request leaves the Mac, and reported to
/// the Python engine through `daemon.memory.model_policy`. Every field decodes
/// with a default so an older `provider-config.json` keeps loading.
public struct BurnBarMemoryEgressPolicy: Codable, Hashable, Sendable {
    public static let purposes = ["memory-extract", "memory-judge", "memory-embed", "memory-rerank", "memory-answer"]
    public static let cliProviderIDs = ["claude_cli", "codex_cli"]
    public static let maxDailyCapUSD: Double = 1_000

    public var enabled: Bool
    public var consentedProviderIDs: [String]
    public var consentedCLIProviderIDs: [String]
    public var allowedModelIDsByPurpose: [String: [String]]
    public var requireNoRetention: Bool
    public var dailyCapUSD: Double
    public var updatedAt: Date?

    public init(
        enabled: Bool = false,
        consentedProviderIDs: [String] = [],
        consentedCLIProviderIDs: [String] = [],
        allowedModelIDsByPurpose: [String: [String]] = [:],
        requireNoRetention: Bool = true,
        dailyCapUSD: Double = 2.0,
        updatedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.consentedProviderIDs = consentedProviderIDs
        self.consentedCLIProviderIDs = consentedCLIProviderIDs
        self.allowedModelIDsByPurpose = allowedModelIDsByPurpose
        self.requireNoRetention = requireNoRetention
        self.dailyCapUSD = dailyCapUSD
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case consentedProviderIDs
        case consentedCLIProviderIDs
        case allowedModelIDsByPurpose
        case requireNoRetention
        case dailyCapUSD
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.consentedProviderIDs = try container.decodeIfPresent([String].self, forKey: .consentedProviderIDs) ?? []
        self.consentedCLIProviderIDs = try container.decodeIfPresent([String].self, forKey: .consentedCLIProviderIDs) ?? []
        self.allowedModelIDsByPurpose = try container.decodeIfPresent([String: [String]].self, forKey: .allowedModelIDsByPurpose) ?? [:]
        self.requireNoRetention = try container.decodeIfPresent(Bool.self, forKey: .requireNoRetention) ?? true
        self.dailyCapUSD = try container.decodeIfPresent(Double.self, forKey: .dailyCapUSD) ?? 2.0
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

public struct BurnBarProviderConfigurationSnapshot: Codable, Hashable, Sendable {
    public var providers: [BurnBarProviderSettings]
    public var routerMode: ProviderRouterMode
    public var telemetryEnabled: Bool
    public var privacyOptIn: Bool
    public var cloudSyncEnabled: Bool
    public var memoryEgress: BurnBarMemoryEgressPolicy

    public init(
        providers: [BurnBarProviderSettings],
        routerMode: ProviderRouterMode = .providerFamilyFailover,
        telemetryEnabled: Bool = false,
        privacyOptIn: Bool = false,
        cloudSyncEnabled: Bool = false,
        memoryEgress: BurnBarMemoryEgressPolicy = BurnBarMemoryEgressPolicy()
    ) {
        self.providers = providers
        self.routerMode = routerMode
        self.telemetryEnabled = telemetryEnabled
        self.privacyOptIn = privacyOptIn
        self.cloudSyncEnabled = cloudSyncEnabled
        self.memoryEgress = memoryEgress
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case routerMode
        case telemetryEnabled
        case privacyOptIn
        case cloudSyncEnabled
        case memoryEgress
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = try container.decode([BurnBarProviderSettings].self, forKey: .providers)
        self.routerMode = try container.decodeIfPresent(ProviderRouterMode.self, forKey: .routerMode)
            ?? .providerFamilyFailover
        self.telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled) ?? false
        self.privacyOptIn = try container.decodeIfPresent(Bool.self, forKey: .privacyOptIn) ?? false
        self.cloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .cloudSyncEnabled) ?? false
        self.memoryEgress = try container.decodeIfPresent(BurnBarMemoryEgressPolicy.self, forKey: .memoryEgress)
            ?? BurnBarMemoryEgressPolicy()
    }

    public func providerSettings(id: String) -> BurnBarProviderSettings? {
        providers.first(where: { $0.providerID == id })
    }
}

public struct BurnBarConfigGetRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarConfigUpdateRequest: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(snapshot: BurnBarProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarConfigResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(snapshot: BurnBarProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarProviderCredentialSlotUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let slotID: String?
    public let label: String
    public let apiKey: String
    public let isEnabled: Bool
    public let endpointProfileID: String?
    public let region: ProviderEndpointRegion?
    public let tokenPlanTier: MimoTokenPlanTier?
    public let tokenPlanBillingCycle: MimoTokenPlanBillingCycle?
    public let authMethodID: String?

    public init(
        providerID: String,
        slotID: String? = nil,
        label: String,
        apiKey: String,
        isEnabled: Bool = true,
        endpointProfileID: String? = nil,
        region: ProviderEndpointRegion? = nil,
        tokenPlanTier: MimoTokenPlanTier? = nil,
        tokenPlanBillingCycle: MimoTokenPlanBillingCycle? = nil,
        authMethodID: String? = nil
    ) {
        self.providerID = providerID
        self.slotID = slotID
        self.label = label
        self.apiKey = apiKey
        self.isEnabled = isEnabled
        self.endpointProfileID = endpointProfileID
        self.region = region
        self.tokenPlanTier = tokenPlanTier
        self.tokenPlanBillingCycle = tokenPlanBillingCycle
        self.authMethodID = authMethodID
    }
}

public struct BurnBarProviderCredentialSlotRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let slotID: String

    public init(providerID: String, slotID: String) {
        self.providerID = providerID
        self.slotID = slotID
    }
}

public struct BurnBarProviderCredentialSlotMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let slot: BurnBarProviderCredentialSlot?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        slot: BurnBarProviderCredentialSlot? = nil
    ) {
        self.snapshot = snapshot
        self.slot = slot
    }
}

public struct BurnBarProviderModelVariantUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let variant: BurnBarModelVariant

    public init(providerID: String, variant: BurnBarModelVariant) {
        self.providerID = providerID
        self.variant = variant
    }
}

public struct BurnBarProviderModelVariantRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let variantID: String

    public init(providerID: String, variantID: String) {
        self.providerID = providerID
        self.variantID = variantID
    }
}

public struct BurnBarProviderModelVariantMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let variant: BurnBarModelVariant?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        variant: BurnBarModelVariant? = nil
    ) {
        self.snapshot = snapshot
        self.variant = variant
    }
}

public struct BurnBarProviderModelAliasUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let alias: BurnBarModelAlias

    public init(providerID: String, alias: BurnBarModelAlias) {
        self.providerID = providerID
        self.alias = alias
    }
}

public struct BurnBarProviderModelAliasRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let aliasID: String

    public init(providerID: String, aliasID: String) {
        self.providerID = providerID
        self.aliasID = aliasID
    }
}

public struct BurnBarProviderModelAliasMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let alias: BurnBarModelAlias?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        alias: BurnBarModelAlias? = nil
    ) {
        self.snapshot = snapshot
        self.alias = alias
    }
}

public struct BurnBarProviderCustomModelUpsertRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let customModel: BurnBarCustomModel

    public init(providerID: String, customModel: BurnBarCustomModel) {
        self.providerID = providerID
        self.customModel = customModel
    }
}

public struct BurnBarProviderCustomModelRemoveRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct BurnBarProviderCustomModelMutationResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot
    public let customModel: BurnBarCustomModel?

    public init(
        snapshot: BurnBarProviderConfigurationSnapshot,
        customModel: BurnBarCustomModel? = nil
    ) {
        self.snapshot = snapshot
        self.customModel = customModel
    }
}

public struct BurnBarProviderModelDisplayNameSetRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let displayName: String

    public init(providerID: String, modelID: String, displayName: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.displayName = displayName
    }
}

public struct BurnBarProviderModelDisplayNameClearRequest: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct BurnBarProviderModelDisplayNameMutationResponse: Codable, Hashable, Sendable {
    public let override: BurnBarModelDisplayOverride?
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(override: BurnBarModelDisplayOverride?, snapshot: BurnBarProviderConfigurationSnapshot) {
        self.override = override
        self.snapshot = snapshot
    }
}

public struct BurnBarRecentUsageRequest: Codable, Hashable, Sendable {
    public let limit: Int

    public init(limit: Int = 20) {
        self.limit = limit
    }
}

public struct BurnBarRecentUsageResponse: Codable, Hashable, Sendable {
    public let usage: [BurnBarUsageEvent]

    public init(usage: [BurnBarUsageEvent]) {
        self.usage = usage
    }
}

/// Requests the daemon's durable all-time usage projection. The projection is
/// rebuilt from the append-only ledger whenever its content fingerprint is
/// stale, so clients never need to treat renderer-side arithmetic as authority.
public struct BurnBarUsageProjectionRequest: Codable, Hashable, Sendable {
    public init() {}
}

/// Requests an explicit authoritative recount of the daemon usage ledger.
/// Recount never mutates source events; it replaces only the derived projection.
public struct BurnBarUsageRecountRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarUsageProjectionTotals: Codable, Hashable, Sendable {
    public let eventCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int
    public let cost: Double

    public init(
        eventCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int,
        totalTokens: Int,
        cost: Double
    ) {
        self.eventCount = eventCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

/// One UTC-day/provider/model aggregate. Day boundaries are UTC by contract,
/// making the same ledger project identically on macOS and Linux regardless of
/// the host locale or current time zone.
public struct BurnBarUsageProjectionBucket: Codable, Hashable, Sendable {
    public let dayUTC: String
    public let providerID: String
    public let modelID: String
    public let totals: BurnBarUsageProjectionTotals
    public let exactEventCount: Int
    public let estimatedEventCount: Int
    public let unknownEventCount: Int
    public let firstRecordedAt: Date
    public let lastRecordedAt: Date

    public init(
        dayUTC: String,
        providerID: String,
        modelID: String,
        totals: BurnBarUsageProjectionTotals,
        exactEventCount: Int,
        estimatedEventCount: Int,
        unknownEventCount: Int,
        firstRecordedAt: Date,
        lastRecordedAt: Date
    ) {
        self.dayUTC = dayUTC
        self.providerID = providerID
        self.modelID = modelID
        self.totals = totals
        self.exactEventCount = exactEventCount
        self.estimatedEventCount = estimatedEventCount
        self.unknownEventCount = unknownEventCount
        self.firstRecordedAt = firstRecordedAt
        self.lastRecordedAt = lastRecordedAt
    }
}

public struct BurnBarUsageProjection: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generation: Int
    public let generatedAt: Date
    public let ledgerSHA256: String
    public let totals: BurnBarUsageProjectionTotals
    public let buckets: [BurnBarUsageProjectionBucket]

    public init(
        schemaVersion: Int = 1,
        generation: Int,
        generatedAt: Date,
        ledgerSHA256: String,
        totals: BurnBarUsageProjectionTotals,
        buckets: [BurnBarUsageProjectionBucket]
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.generatedAt = generatedAt
        self.ledgerSHA256 = ledgerSHA256
        self.totals = totals
        self.buckets = buckets
    }
}

public struct BurnBarUsageProjectionResponse: Codable, Hashable, Sendable {
    public let projection: BurnBarUsageProjection

    public init(projection: BurnBarUsageProjection) {
        self.projection = projection
    }
}

/// Requests a bounded, daemon-owned snapshot of the indexed conversation
/// history used by Activity export. Unlike `BurnBarRecentUsageRequest`, this
/// contract carries an explicit completeness proof and persisted session body.
public struct BurnBarActivityHistoryRequest: Codable, Hashable, Sendable {
    public let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
    }
}

public struct BurnBarActivityHistorySession: Codable, Hashable, Sendable {
    public let id: String
    public let provider: String
    public let model: String
    public let startedAt: String
    public let tokens: Int
    public let costUsd: Double
    public let title: String
    public let sourceID: String
    public let providerSessionID: String
    public let runID: String?
    public let projectName: String?
    public let bodyMD: String

    public init(
        id: String,
        provider: String,
        model: String,
        startedAt: String,
        tokens: Int,
        costUsd: Double,
        title: String,
        sourceID: String,
        providerSessionID: String,
        runID: String? = nil,
        projectName: String? = nil,
        bodyMD: String
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.tokens = tokens
        self.costUsd = costUsd
        self.title = title
        self.sourceID = sourceID
        self.providerSessionID = providerSessionID
        self.runID = runID
        self.projectName = projectName
        self.bodyMD = bodyMD
    }
}

public struct BurnBarActivityHistoryResponse: Codable, Hashable, Sendable {
    public let sessions: [BurnBarActivityHistorySession]
    public let nextCursor: String?
    public let historyComplete: Bool
    public let historyLimit: Int
    public let totalCount: Int

    public init(
        sessions: [BurnBarActivityHistorySession],
        nextCursor: String?,
        historyComplete: Bool,
        historyLimit: Int,
        totalCount: Int
    ) {
        self.sessions = sessions
        self.nextCursor = nextCursor
        self.historyComplete = historyComplete
        self.historyLimit = historyLimit
        self.totalCount = totalCount
    }
}

/// Requests a privacy-bounded, daemon-owned qualitative insight brief. The
/// daemon builds the digest from its usage ledger; the renderer never receives
/// raw transcripts or provider credentials.
public struct BurnBarUsageInsightsRequest: Codable, Hashable, Sendable {
    public let limit: Int
    public let windowSeconds: TimeInterval
    public let prompt: String

    public init(
        limit: Int = 200,
        windowSeconds: TimeInterval = 7 * 24 * 60 * 60,
        prompt: String = "Summarize the most important usage changes and actions."
    ) {
        self.limit = limit
        self.windowSeconds = windowSeconds
        self.prompt = prompt
    }
}

/// Confidence level for a recorded `BurnBarUsageEvent`. Mirrors `UsageProvenanceConfidence`
/// at the contract layer so the daemon ledger can be written by Hermes/MCP/CLI clients
/// without depending on the app's `OpenBurnBarCore` runtime types.
public enum BurnBarUsageConfidence: String, Codable, Hashable, CaseIterable, Sendable {
    case exact
    case derivedExact = "derived_exact"
    case highConfidenceEstimate = "high_confidence_estimate"
    case lowConfidenceEstimate = "low_confidence_estimate"
    case unknown
}

/// Whether a usage event represents real per-token dollars leaving a wallet
/// (`api`) or the imputed list-price value of work that actually ran inside a
/// flat plan (`subscription`). `unknown` is the fail-honest default for rows
/// recorded before this dimension existed; consumers must surface it as its
/// own bucket rather than silently folding it into either side.
public enum BurnBarBillingKind: String, Codable, Hashable, Sendable, CaseIterable {
    case api
    case subscription
    case unknown
}

/// Fallback classifier for ledger rows that predate the stamped
/// `billingKind` field. Deliberately conservative: the daemon's provider
/// router only ever dials key-backed provider slots, so every provider it can
/// name is API-billed; anything unrecognized stays `unknown` instead of
/// guessing. Writers should stamp the kind at record time — this table exists
/// only so history remains classifiable.
public enum BurnBarBillingProvenance {
    /// Provider ids the daemon reaches with a configured API key. Kept as an
    /// explicit allowlist (not "everything") so a future subscription-bridged
    /// route cannot be silently misbilled as API spend.
    private static let apiKeyProviderIDs: Set<String> = [
        "deepseek", "openai", "anthropic", "openrouter", "meta", "metadev",
        "xai", "mistral", "gemini", "groq", "zai", "minimax", "moonshot",
        "fireworks", "together", "local-rules"
    ]

    public static func classify(providerID: String) -> BurnBarBillingKind {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return .unknown }
        // "local-rules" rows carry zero cost either way; classifying them as
        // api keeps the budget arithmetic exact without a special case.
        return apiKeyProviderIDs.contains(normalized) ? .api : .unknown
    }

    /// The effective kind for a ledger event: the stamped value when present,
    /// the classifier's answer for legacy rows otherwise.
    public static func effectiveKind(of event: BurnBarUsageEvent) -> BurnBarBillingKind {
        event.billingKind ?? classify(providerID: event.providerID)
    }

    /// Harnesses whose parsed sessions are overwhelmingly plan-billed. Kept in
    /// exact lockstep with the v60 `billingKindBackfillSQL` CASE — the Swift
    /// write path and the SQL backfill must never disagree about a row.
    private static let subscriptionFirstProviders: Set<AgentProvider> = [
        .claudeCode, .codex, .copilot, .cursor, .cursorAgent,
        .factory, .junie, .windsurf, .warp
    ]

    /// Bring-your-own-key harnesses: parsed sessions bill against the user's
    /// own API key. Mirror of the backfill's second CASE arm.
    private static let apiKeyFirstProviders: Set<AgentProvider> = [
        .aider, .hermes, .deepSeek, .openAI, .xAI
    ]

    /// Deterministic write-time classification for `token_usage` rows,
    /// mirroring the v60 backfill exactly:
    /// billing-API and daemon-gateway ingest are real dollars by construction;
    /// plan-first harness logs are subscription; BYO-key harness logs are api;
    /// everything else is `.unknown` — a wrong guess would corrupt the
    /// money/imputed split forever, an unknown can be reclassified later.
    public static func classify(
        provider: AgentProvider,
        usageSource: UsageSource
    ) -> BurnBarBillingKind {
        switch usageSource {
        case .billingAPI, .daemon:
            return .api
        case .providerLog:
            if subscriptionFirstProviders.contains(provider) { return .subscription }
            if apiKeyFirstProviders.contains(provider) { return .api }
            return .unknown
        case .inAppChat, .cursorBridge, .unknown:
            return .unknown
        }
    }
}

public struct BurnBarUsageEvent: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID?
    public let providerID: String
    public let modelID: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int
    public let cost: Double
    public let recordedAt: Date
    /// Optional client-supplied session id for app/Hermes session attribution.
    public let sessionID: String?
    /// Optional client-supplied project name. Defaults to "OpenBurnBar Daemon" on import when nil.
    public let projectName: String?
    /// Product surface that originated the request (for example Cursor or
    /// Grok Build). Optional for backward-compatible daemon ledger decoding.
    public let executionSourceID: String?
    public let executionSourceName: String?
    public let executionSourceKind: UsageExecutionSourceKind?
    public let executionSourceConfidence: BurnBarUsageConfidence?
    /// Confidence level for the recorded counts. Defaults to `.exact` for backwards compat
    /// (existing daemon-recorded rows are exact provider responses).
    public let confidence: BurnBarUsageConfidence
    /// Optional rollup key tying several sub-call usage events to one
    /// originating request. The Elder Wand model-fusion router stamps every
    /// panel/judge/synthesis sub-call with a shared `parentRequestID` so the N
    /// rows recorded for one fusion completion sum back to a single request
    /// (each sub-call still uses a DISTINCT idempotency key so they are not
    /// deduped). `nil` for ordinary single-route completions; additive and
    /// decode-optional so existing rows and call sites are unaffected.
    public let parentRequestID: String?
    /// Billing provenance of this event: real API dollars vs subscription-plan
    /// imputed value. Stamped by the writer that knows the route; `nil` on
    /// rows recorded before the field existed (resolve via
    /// `BurnBarBillingProvenance.effectiveKind(of:)`). Additive and
    /// decode-optional like `parentRequestID`.
    public let billingKind: BurnBarBillingKind?

    private enum CodingKeys: String, CodingKey {
        case runID
        case providerID
        case modelID
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case reasoningTokens
        case cost
        case recordedAt
        case sessionID
        case projectName
        case executionSourceID
        case executionSourceName
        case executionSourceKind
        case executionSourceConfidence
        case confidence
        case parentRequestID
        case billingKind
    }

    public init(
        runID: BurnBarRunID? = nil,
        providerID: String,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int,
        reasoningTokens: Int = 0,
        cost: Double,
        recordedAt: Date,
        sessionID: String? = nil,
        projectName: String? = nil,
        executionSourceID: String? = nil,
        executionSourceName: String? = nil,
        executionSourceKind: UsageExecutionSourceKind? = nil,
        executionSourceConfidence: BurnBarUsageConfidence? = nil,
        confidence: BurnBarUsageConfidence = .exact,
        parentRequestID: String? = nil,
        billingKind: BurnBarBillingKind? = nil
    ) {
        self.runID = runID
        self.providerID = providerID
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.recordedAt = recordedAt
        self.sessionID = sessionID
        self.projectName = projectName
        self.executionSourceID = executionSourceID
        self.executionSourceName = executionSourceName
        self.executionSourceKind = executionSourceKind
        self.executionSourceConfidence = executionSourceConfidence
        self.confidence = confidence
        self.parentRequestID = parentRequestID
        self.billingKind = billingKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decodeIfPresent(BurnBarRunID.self, forKey: .runID)
        providerID = try container.decode(String.self, forKey: .providerID)
        modelID = try container.decode(String.self, forKey: .modelID)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0
        cost = try container.decode(Double.self, forKey: .cost)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        executionSourceID = try container.decodeIfPresent(String.self, forKey: .executionSourceID)
        executionSourceName = try container.decodeIfPresent(String.self, forKey: .executionSourceName)
        executionSourceKind = try container.decodeIfPresent(UsageExecutionSourceKind.self, forKey: .executionSourceKind)
        executionSourceConfidence = try container.decodeIfPresent(BurnBarUsageConfidence.self, forKey: .executionSourceConfidence)
        confidence = try container.decodeIfPresent(BurnBarUsageConfidence.self, forKey: .confidence) ?? .exact
        parentRequestID = try container.decodeIfPresent(String.self, forKey: .parentRequestID)
        billingKind = try container.decodeIfPresent(BurnBarBillingKind.self, forKey: .billingKind)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(reasoningTokens, forKey: .reasoningTokens)
        try container.encode(cost, forKey: .cost)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(projectName, forKey: .projectName)
        try container.encodeIfPresent(executionSourceID, forKey: .executionSourceID)
        try container.encodeIfPresent(executionSourceName, forKey: .executionSourceName)
        try container.encodeIfPresent(executionSourceKind, forKey: .executionSourceKind)
        try container.encodeIfPresent(executionSourceConfidence, forKey: .executionSourceConfidence)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(parentRequestID, forKey: .parentRequestID)
        try container.encodeIfPresent(billingKind, forKey: .billingKind)
    }
}

public struct BurnBarRecordUsageRequest: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let event: BurnBarUsageEvent

    public init(idempotencyKey: String, event: BurnBarUsageEvent) {
        self.idempotencyKey = idempotencyKey
        self.event = event
    }
}

public struct BurnBarRecordUsageResponse: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let inserted: Bool
    public let event: BurnBarUsageEvent

    public init(idempotencyKey: String, inserted: Bool, event: BurnBarUsageEvent) {
        self.idempotencyKey = idempotencyKey
        self.inserted = inserted
        self.event = event
    }
}

public struct BurnBarHealthRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarHealthResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let daemonVersion: String
    public let protocolVersion: Int
    public let socketPath: String?
    public let gatewayEnabled: Bool
    public let gatewayHost: String?
    public let gatewayPort: Int?

    public init(ok: Bool, daemonVersion: String, protocolVersion: Int, socketPath: String? = nil, gatewayEnabled: Bool = false, gatewayHost: String? = nil, gatewayPort: Int? = nil) {
        self.ok = ok
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
        self.gatewayEnabled = gatewayEnabled
        self.gatewayHost = gatewayHost
        self.gatewayPort = gatewayPort
    }
}

public struct BurnBarCatalogRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarCatalogResponse: Codable, Hashable, Sendable {
    public let catalog: BurnBarCatalog

    public init(catalog: BurnBarCatalog) {
        self.catalog = catalog
    }
}

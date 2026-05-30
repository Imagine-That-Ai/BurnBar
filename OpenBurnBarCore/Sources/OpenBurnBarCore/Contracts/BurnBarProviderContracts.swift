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
        hasCredential: Bool,
        providerEnabled: Bool = true,
        now: Date = Date(),
        exhaustionRetryInterval: TimeInterval = defaultExhaustionRetryInterval
    ) -> Bool {
        canAttemptRoute(
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

public struct BurnBarProviderSettings: Codable, Hashable, Identifiable, Sendable {
    public let providerID: String
    public var isEnabled: Bool
    public var baseURL: String
    public var preferredModelIDs: [String]
    public var disabledAdvertisedModelIDs: [String]
    public var preferredCredentialSlotID: String?
    public var credentialSlots: [BurnBarProviderCredentialSlot]
    /// User-defined thinking-level variants. Each variant ships as its own
    /// row in `/v1/models` and in every wired CLI's picker, while still
    /// routing through `baseModelID`.
    public var modelVariants: [BurnBarModelVariant]
    /// User-defined proxy aliases with custom wire ids and optional hide-base behavior.
    public var modelAliases: [BurnBarModelAlias]
    /// User-defined display name overrides.
    public var modelDisplayOverrides: [BurnBarModelDisplayOverride]

    public var id: String { providerID }

    public init(
        providerID: String,
        isEnabled: Bool = false,
        baseURL: String,
        preferredModelIDs: [String],
        disabledAdvertisedModelIDs: [String] = [],
        preferredCredentialSlotID: String? = nil,
        credentialSlots: [BurnBarProviderCredentialSlot] = [],
        modelVariants: [BurnBarModelVariant] = [],
        modelAliases: [BurnBarModelAlias] = [],
        modelDisplayOverrides: [BurnBarModelDisplayOverride] = []
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.preferredModelIDs = preferredModelIDs
        self.disabledAdvertisedModelIDs = Self.normalizedDisabledAdvertisedModelIDs(disabledAdvertisedModelIDs)
        self.preferredCredentialSlotID = preferredCredentialSlotID
        self.credentialSlots = credentialSlots
        self.modelVariants = Self.normalizedModelVariants(modelVariants)
        self.modelAliases = Self.normalizedModelAliases(modelAliases)
        self.modelDisplayOverrides = Self.normalizedModelDisplayOverrides(modelDisplayOverrides)
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

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isEnabled
        case baseURL
        case preferredModelIDs
        case disabledAdvertisedModelIDs
        case preferredCredentialSlotID
        case credentialSlots
        case modelVariants
        case modelAliases
        case modelDisplayOverrides
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
        modelVariants = Self.normalizedModelVariants(
            try container.decodeIfPresent([BurnBarModelVariant].self, forKey: .modelVariants) ?? []
        )
        modelAliases = Self.normalizedModelAliases(
            try container.decodeIfPresent([BurnBarModelAlias].self, forKey: .modelAliases) ?? []
        )
        modelDisplayOverrides = Self.normalizedModelDisplayOverrides(
            try container.decodeIfPresent([BurnBarModelDisplayOverride].self, forKey: .modelDisplayOverrides) ?? []
        )
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
}

public struct BurnBarProviderConfigurationSnapshot: Codable, Hashable, Sendable {
    public var providers: [BurnBarProviderSettings]
    public var routerMode: ProviderRouterMode

    public init(
        providers: [BurnBarProviderSettings],
        routerMode: ProviderRouterMode = .providerFamilyFailover
    ) {
        self.providers = providers
        self.routerMode = routerMode
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case routerMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providers = try container.decode([BurnBarProviderSettings].self, forKey: .providers)
        self.routerMode = try container.decodeIfPresent(ProviderRouterMode.self, forKey: .routerMode)
            ?? .providerFamilyFailover
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
    /// Confidence level for the recorded counts. Defaults to `.exact` for backwards compat
    /// (existing daemon-recorded rows are exact provider responses).
    public let confidence: BurnBarUsageConfidence

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
        case confidence
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
        confidence: BurnBarUsageConfidence = .exact
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
        self.confidence = confidence
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
        confidence = try container.decodeIfPresent(BurnBarUsageConfidence.self, forKey: .confidence) ?? .exact
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
        try container.encode(confidence, forKey: .confidence)
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

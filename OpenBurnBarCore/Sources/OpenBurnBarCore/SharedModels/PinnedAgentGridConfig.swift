import Foundation

// MARK: - Pinned Agent Grid Config (Hermes Square §3 / §6.2)
//
// The Alipay-style 12-slot home grid at the top of the Hermes Square
// Living Inbox. Carries:
//   • The ordered list of pinned agent URIs (≤ 12).
//   • A small set of layout hints (compact vs comfortable, glyph-only vs
//     name-shown).
//
// Persisted as a JSON blob:
//   • iOS    — UserDefaults key `square.pinnedGrid.v1`
//   • Android — DataStore key `square.pinned_grid.v1`
//   • Cloud-synced via Firestore `users/{uid}/square_state/pinned_grid`
//
// Mirrors `ChatTilePreferences`'s codable patterns (deterministic key
// ordering, `sanitized()` invariant).

public struct PinnedAgentGridConfig: Codable, Sendable, Hashable {
    /// Maximum number of slots in the grid (plan-mandated: 12).
    public static let maxSlots = 12

    /// Default pinned set on first install — the five built-in runtimes in
    /// `AssistantRuntimeID.allCases` order, leaving the rest of the 12
    /// slots empty.
    public static var defaultPinnedURIs: [String] {
        AssistantRuntimeID.allCases.map(AgentIdentity.builtInURI)
    }

    /// Ordered list of pinned agent URIs.
    public var pinnedURIs: [String]

    /// Layout hints.
    public var displayMode: DisplayMode

    /// Last time the user re-arranged the grid. Used for the "you
    /// recently re-organized your dock" affordance on Mac.
    public var lastRearrangedAt: Date?

    public enum DisplayMode: String, Codable, Sendable, Hashable, CaseIterable {
        /// Glyph + abbreviated name, 4 columns × 3 rows.
        case comfortable
        /// Glyph only, 6 columns × 2 rows. More agents fit on a smaller phone.
        case compact

        public var columns: Int {
            switch self {
            case .comfortable: return 4
            case .compact:     return 6
            }
        }

        public var rows: Int {
            switch self {
            case .comfortable: return 3
            case .compact:     return 2
            }
        }
    }

    public init(
        pinnedURIs: [String] = PinnedAgentGridConfig.defaultPinnedURIs,
        displayMode: DisplayMode = .comfortable,
        lastRearrangedAt: Date? = nil
    ) {
        self.pinnedURIs = pinnedURIs
        self.displayMode = displayMode
        self.lastRearrangedAt = lastRearrangedAt
    }

    public static let `default` = PinnedAgentGridConfig()

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case pinnedURIs
        case displayMode
        case lastRearrangedAt
    }

    // MARK: - Sanitisation

    /// Returns a copy with:
    ///   • duplicate URIs removed (first wins),
    ///   • list truncated to `maxSlots`,
    ///   • at least the first built-in agent pinned (so the grid is never
    ///     empty after a sanitisation pass).
    public func sanitized() -> PinnedAgentGridConfig {
        var seen: Set<String> = []
        var deduped: [String] = []
        for uri in pinnedURIs where !seen.contains(uri) {
            seen.insert(uri)
            deduped.append(uri)
        }
        var trimmed = Array(deduped.prefix(Self.maxSlots))
        if trimmed.isEmpty,
           let firstBuiltIn = Self.defaultPinnedURIs.first {
            trimmed = [firstBuiltIn]
        }
        return PinnedAgentGridConfig(
            pinnedURIs: trimmed,
            displayMode: displayMode,
            lastRearrangedAt: lastRearrangedAt
        )
    }

    // MARK: - Mutation helpers

    /// Append `uri` to the end of the grid if there's room and it isn't
    /// already pinned. Returns the mutated config.
    public func pinning(_ uri: String) -> PinnedAgentGridConfig {
        guard !pinnedURIs.contains(uri), pinnedURIs.count < Self.maxSlots else {
            return self
        }
        var copy = self
        copy.pinnedURIs.append(uri)
        copy.lastRearrangedAt = Date()
        return copy
    }

    public func pinningPairedMac(
        _ uri: String,
        pairedMacPrefix: String = "device://paired-mac/"
    ) -> PinnedAgentGridConfig {
        guard uri.hasPrefix(pairedMacPrefix) else {
            return pinning(uri)
        }
        var copy = self
        copy.pinnedURIs.removeAll { $0 == uri }
        copy.pinnedURIs.insert(uri, at: 0)
        copy.pinnedURIs = Array(copy.pinnedURIs.prefix(Self.maxSlots))
        copy.lastRearrangedAt = Date()
        return copy.sanitized()
    }

    /// Remove `uri` from the grid. Returns the mutated config.
    public func unpinning(_ uri: String) -> PinnedAgentGridConfig {
        var copy = self
        copy.pinnedURIs.removeAll { $0 == uri }
        copy.lastRearrangedAt = Date()
        return copy.sanitized()
    }

    /// Move a slot from `sourceIndex` to `destinationIndex`. Returns the
    /// mutated config. Out-of-range indices are clamped.
    public func moving(from sourceIndex: Int, to destinationIndex: Int) -> PinnedAgentGridConfig {
        var copy = self
        let safeFrom = max(0, min(sourceIndex, copy.pinnedURIs.count - 1))
        guard safeFrom < copy.pinnedURIs.count else { return self }
        let value = copy.pinnedURIs.remove(at: safeFrom)
        let safeTo = max(0, min(destinationIndex, copy.pinnedURIs.count))
        copy.pinnedURIs.insert(value, at: safeTo)
        copy.lastRearrangedAt = Date()
        return copy
    }

    // MARK: - JSON convenience

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    public static func from(jsonString raw: String) -> PinnedAgentGridConfig {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return .default
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode(PinnedAgentGridConfig.self, from: data))
            ?? .default).sanitized()
    }
}

// MARK: - Persistence keys

extension PinnedAgentGridConfig {
    public static let userDefaultsKey = "square.pinnedGrid.v1"
    public static let androidDataStoreKey = "square.pinned_grid.v1"
}

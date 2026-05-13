import Foundation

// MARK: - Chat Tile Preferences
//
// Cross-platform model for "which chat tiles appear in the chat section" and
// "which Hermes sub-providers are visible inside the Hermes picker." Persisted
// as a single JSON blob on each platform:
//
//   • macOS   — SettingsPersistenceCoordinator key `chatTilePreferencesJSON`
//   • iOS     — UserDefaults key `chat.tilePreferences.v1`
//   • Android — DataStore key `chat.tile_preferences.v1`
//
// The model intentionally normalizes to **stable rawValues** (`hermes`, `pi`,
// `codex`, `claude`, `openclaw` for tiles; `codex`, `claude`, `zai`, `kimi`,
// `minimax`, `ollama` for Hermes sub-providers). Older clients reading future
// rawValues simply drop them — they won't decode to a tile that doesn't exist.

public struct ChatTilePreferences: Codable, Equatable, Sendable {
    /// Set of top-level tiles visible in the chat surface's runtime pill.
    /// At least one tile is always enforced via `sanitized()`.
    public var enabledTiles: Set<AssistantRuntimeID>

    /// Set of Hermes sub-providers visible in the Hermes model picker. When
    /// empty the picker falls back to showing all advertised models.
    public var enabledHermesSubProviders: Set<HermesSubProvider>

    public init(
        enabledTiles: Set<AssistantRuntimeID> = AssistantRuntimeID.defaultEnabledTiles,
        enabledHermesSubProviders: Set<HermesSubProvider> = HermesSubProvider.defaultVisible
    ) {
        self.enabledTiles = enabledTiles
        self.enabledHermesSubProviders = enabledHermesSubProviders
    }

    public static let `default` = ChatTilePreferences()

    // MARK: - Codable (deterministic JSON shape across platforms)

    private enum CodingKeys: String, CodingKey {
        case tiles
        case hermesSubProviders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tileStrings = try container.decodeIfPresent([String].self, forKey: .tiles) ?? []
        let subStrings  = try container.decodeIfPresent([String].self, forKey: .hermesSubProviders) ?? []
        let tiles = Set(tileStrings.compactMap(AssistantRuntimeID.init(rawValue:)))
        let subs  = Set(subStrings.compactMap(HermesSubProvider.init(rawValue:)))
        self.enabledTiles = tiles.isEmpty ? AssistantRuntimeID.defaultEnabledTiles : tiles
        self.enabledHermesSubProviders = subs.isEmpty ? HermesSubProvider.defaultVisible : subs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Sort for deterministic on-disk shape (helps tests & diffs).
        let tileValues = enabledTiles.map(\.rawValue).sorted()
        let subValues  = enabledHermesSubProviders.map(\.rawValue).sorted()
        try container.encode(tileValues, forKey: .tiles)
        try container.encode(subValues, forKey: .hermesSubProviders)
    }

    // MARK: - Mutation helpers

    public mutating func setTile(_ id: AssistantRuntimeID, enabled: Bool) {
        if enabled {
            enabledTiles.insert(id)
        } else {
            enabledTiles.remove(id)
        }
    }

    public mutating func setHermesSubProvider(_ provider: HermesSubProvider, enabled: Bool) {
        if enabled {
            enabledHermesSubProviders.insert(provider)
        } else {
            enabledHermesSubProviders.remove(provider)
        }
    }

    /// Returns a copy with the tile set guaranteed to contain at least one
    /// runtime (defaults to `.hermes`) so the chat UI is never empty.
    public func sanitized() -> ChatTilePreferences {
        var copy = self
        if copy.enabledTiles.isEmpty {
            copy.enabledTiles = [.hermes]
        }
        return copy
    }

    /// Hermes tiles only: filtered by `enabledTiles` preserving the canonical
    /// order in `AssistantRuntimeID.allCases`. Pure helper for the pill UI.
    public var orderedVisibleTiles: [AssistantRuntimeID] {
        AssistantRuntimeID.allCases.filter { enabledTiles.contains($0) }
    }

    /// Hermes sub-providers ordered by the canonical catalog order.
    public var orderedVisibleHermesSubProviders: [HermesSubProvider] {
        HermesSubProvider.allCases.filter { enabledHermesSubProviders.contains($0) }
    }

    // MARK: - JSON convenience

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    public static func from(jsonString raw: String) -> ChatTilePreferences {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return .default
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(ChatTilePreferences.self, from: data)) ?? .default
    }
}

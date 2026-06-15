import Foundation
import OpenBurnBarCore

// MARK: - Elder Wand Settings
//
// Persists the user's saved **The Elder Wand** model-fusion presets
// (OpenRouter "Fusion"-compatible). Each preset names a panel of analysis
// models, a judge model, and a per-model tool-call budget; exactly one preset
// is the default, enforced by `Array<ElderWandPreset>.presetsSanitized()`.
//
// The list is JSON-encoded and stored as a single `UserDefaults` string under
// `elderWand.presets.v1` via `SettingsPersistenceCoordinator`, matching the
// rest of the domain-store family (primitive-typed coordinator writes only).
//
// `elderWandPluginsPayload()` lowers the active/default preset into the wire
// `plugins` block the daemon gateway expects:
// `[{ "id":"fusion", "analysis_models":[...], "model":<judge>, "max_tool_calls":n }]`
// — `nil` when no preset is configured, which means "no fusion this request".

@Observable
@MainActor
final class ElderWandSettings {
    /// `UserDefaults` key for the JSON-encoded preset list.
    static let presetsStorageKey = "elderWand.presets.v1"

    private let persistence: SettingsPersistenceCoordinator

    /// The user's saved presets, sanitized so exactly one is the default.
    /// Mutating through the public mutators below re-sanitizes and persists.
    private(set) var presets: [ElderWandPreset] = [] {
        didSet { persist() }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        self.presets = Self.decodePresets(
            from: persistence.optionalString(forKey: Self.presetsStorageKey)
        ).presetsSanitized()
    }

    // MARK: - Derived state

    /// The active preset is the user's default. `nil` when no presets exist.
    var activePreset: ElderWandPreset? {
        presets.first { $0.isDefault } ?? presets.first
    }

    /// Alias kept for call sites that read the default explicitly.
    var defaultPreset: ElderWandPreset? { activePreset }

    // MARK: - Mutators

    /// Saves a new preset or replaces an existing one with the same `id`. The
    /// list is re-sanitized so exactly one preset stays the default.
    func save(_ preset: ElderWandPreset) {
        var next = presets
        let existingWasDefault: Bool
        if let index = next.firstIndex(where: { $0.id == preset.id }) {
            existingWasDefault = next[index].isDefault
            next[index] = preset.withIsDefault(preset.isDefault || existingWasDefault)
        } else {
            existingWasDefault = false
            next.append(preset)
        }

        if preset.isDefault || existingWasDefault {
            presets = next.map { $0.withIsDefault($0.id == preset.id) }
        } else {
            presets = next.presetsSanitized()
        }
    }

    /// Renames the preset with the given `id`. No-op when the id is unknown.
    func rename(id: String, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let existing = presets[index]
        var next = presets
        next[index] = ElderWandPreset(
            id: existing.id,
            name: name,
            analysisModelIDs: existing.analysisModelIDs,
            judgeModelID: existing.judgeModelID,
            maxToolCalls: existing.maxToolCalls,
            isDefault: existing.isDefault
        )
        presets = next.presetsSanitized()
    }

    /// Deletes the preset with the given `id`. The remaining list is
    /// re-sanitized so a new default is promoted if the deleted one was it.
    func delete(id: String) {
        let next = presets.filter { $0.id != id }
        presets = next.presetsSanitized()
    }

    /// Marks the preset with the given `id` as the default. No-op when unknown.
    func setDefault(id: String) {
        guard presets.contains(where: { $0.id == id }) else { return }
        let next = presets.map { $0.withIsDefault($0.id == id) }
        presets = next.presetsSanitized()
    }

    /// Replaces the entire preset list (used by the configurator's batch save).
    func replaceAll(_ newPresets: [ElderWandPreset]) {
        presets = newPresets.presetsSanitized()
    }

    // MARK: - Wire payload

    /// Lowers the active preset into the OpenRouter "Fusion"-compatible
    /// `plugins` array the daemon gateway reads. Returns `nil` when no preset is
    /// configured, signalling "no fusion for this request".
    func elderWandPluginsPayload() -> [[String: any Sendable]]? {
        guard let preset = activePreset else { return nil }
        let analysisModels = preset.analysisModelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let judge = preset.judgeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !analysisModels.isEmpty, !judge.isEmpty else { return nil }
        let clampedToolCalls = min(
            max(preset.maxToolCalls, ElderWandPreset.maxToolCallsRange.lowerBound),
            ElderWandPreset.maxToolCallsRange.upperBound
        )
        return [[
            "id": "fusion",
            "enabled": true,
            "analysis_models": analysisModels,
            "model": judge,
            "max_tool_calls": clampedToolCalls
        ]]
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(presets), // try?-ok(persist best-effort; bad list never written)
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        persistence.set(json, forKey: Self.presetsStorageKey)
    }

    private static func decodePresets(from json: String?) -> [ElderWandPreset] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([ElderWandPreset].self, from: data)) ?? [] // try?-ok(corrupt store → empty list)
    }
}

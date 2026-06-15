import Foundation
import OpenBurnBarCore

/// iOS preset store for **The Elder Wand** model-fusion router (OpenRouter
/// "Fusion"-compatible). Mirrors the macOS `ElderWandSettings` store: a pure
/// `UserDefaults`-backed `[ElderWandPreset]` (the Core type) keyed under
/// `"elderWand.presets.v1"`, JSON-encoded, with the same one-default
/// invariant enforced by `Array.presetsSanitized()`.
///
/// The store is the single source of truth the chat send-path reads from:
/// when a preset is active it returns the `plugins:[{id:"fusion", …}]` block
/// (`elderWandPluginsPayload()`) that `HermesService` injects into the
/// `/v1/chat/completions` body and routes to the BurnBar daemon gateway
/// (port 8317), where `ElderWandFusionOrchestrator` runs the panel + judge.
///
/// The "active" preset is the user's default (`isDefault == true`). With no
/// presets saved, fusion is off and every accessor returns `nil`/empty, so
/// the chat path behaves exactly as before.
@Observable
@MainActor
final class ElderWandSettings {
    /// Shared instance the chat surfaces read from. Production code uses this;
    /// tests inject an isolated store with their own `UserDefaults`.
    static let shared = ElderWandSettings()

    /// UserDefaults key for the JSON-encoded `[ElderWandPreset]`.
    static let presetsDefaultsKey = "elderWand.presets.v1"

    /// Wire-compatible plugin id (OpenRouter "Fusion").
    static let fusionPluginID = "fusion"

    /// All saved presets, always sanitized to exactly-one-default. Mutating
    /// this re-sanitizes and persists. `@ObservationIgnored`-free so the
    /// configurator UI invalidates on any change.
    private(set) var presets: [ElderWandPreset] = []

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.presets = Self.loadPresets(from: defaults)
    }

    // MARK: - Active preset

    /// The active preset is the user's default. `nil` when no presets exist.
    var activePreset: ElderWandPreset? {
        presets.first { $0.isDefault } ?? presets.first
    }

    /// Whether a usable Elder Wand preset is active (so the send-path should
    /// redirect to the daemon gateway and carry the fusion plugin block). A
    /// preset is usable only when it has at least one analysis model and a
    /// judge model, matching the OpenRouter Fusion contract.
    var isFusionActive: Bool {
        guard let preset = activePreset else { return false }
        let analysisModels = preset.analysisModelIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !analysisModels.isEmpty
            && !preset.judgeModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The OpenRouter Fusion `plugins` block for the active preset, or `nil`
    /// when fusion is off. Shape mirrors the macOS payload exactly:
    /// `[{ "id":"fusion", "analysis_models":[…], "model":<judge>,
    ///    "max_tool_calls":<n> }]`.
    func elderWandPluginsPayload() -> [[String: any Sendable]]? {
        guard isFusionActive, let preset = activePreset else { return nil }
        let analysisModels = preset.analysisModelIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !analysisModels.isEmpty else { return nil }
        let judge = preset.judgeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedToolCalls = min(
            max(preset.maxToolCalls, ElderWandPreset.maxToolCallsRange.lowerBound),
            ElderWandPreset.maxToolCallsRange.upperBound
        )
        let plugin: [String: any Sendable] = [
            "id": Self.fusionPluginID,
            "enabled": true,
            "analysis_models": analysisModels,
            "model": judge,
            "max_tool_calls": clampedToolCalls
        ]
        return [plugin]
    }

    // MARK: - Mutation

    /// Replaces the whole preset list (sanitizes + persists). Used by the
    /// configurator's save/import paths.
    func replacePresets(_ newPresets: [ElderWandPreset]) {
        apply(newPresets)
    }

    /// Inserts or updates a preset by `id` (sanitizes + persists).
    func upsert(_ preset: ElderWandPreset) {
        var updated = presets
        let existingWasDefault: Bool
        if let index = updated.firstIndex(where: { $0.id == preset.id }) {
            existingWasDefault = updated[index].isDefault
            updated[index] = preset.withIsDefault(preset.isDefault || existingWasDefault)
        } else {
            existingWasDefault = false
            updated.append(preset)
        }
        if preset.isDefault || existingWasDefault {
            apply(updated.map { $0.withIsDefault($0.id == preset.id) })
        } else {
            apply(updated)
        }
    }

    /// Removes a preset by `id` (sanitizes + persists).
    func remove(id: String) {
        apply(presets.filter { $0.id != id })
    }

    /// Promotes the preset with `id` to the single default (sanitizes +
    /// persists). No-op when the id is unknown.
    func setDefault(id: String) {
        guard presets.contains(where: { $0.id == id }) else { return }
        let updated = presets.map { $0.withIsDefault($0.id == id) }
        apply(updated)
    }

    private func apply(_ newPresets: [ElderWandPreset]) {
        let sanitized = newPresets.presetsSanitized()
        presets = sanitized
        Self.persist(sanitized, to: defaults)
    }

    // MARK: - Persistence

    private static func loadPresets(from defaults: UserDefaults) -> [ElderWandPreset] {
        guard let data = defaults.data(forKey: presetsDefaultsKey) else { return [] }
        guard let decoded = try? JSONDecoder().decode([ElderWandPreset].self, from: data) else {
            return []
        }
        return decoded.presetsSanitized()
    }

    private static func persist(_ presets: [ElderWandPreset], to defaults: UserDefaults) {
        guard !presets.isEmpty else {
            defaults.removeObject(forKey: presetsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: presetsDefaultsKey)
    }
}

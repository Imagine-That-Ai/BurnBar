import Foundation
import OpenBurnBarCore

// MARK: - Grouped model list value types
//
// The configurator view resolves the live advertised models from the chat
// controller and groups them by provider once (prefilter + cache — no inline
// `.filter` in section bodies). These value types carry that prepared list to
// the analysis/judge sections so each section stays a pure renderer.

/// A single selectable model in a chip cloud.
struct ElderWandModelOption: Identifiable, Hashable {
    /// The wire model ID (what gets written into the preset).
    let id: String
    /// Human-facing label for the chip.
    let title: String
    /// Whether the model has an eligible live route right now. Ineligible
    /// models render disabled so the user can't build an unroutable panel.
    let isRouteEligible: Bool
}

/// A provider-titled group of model options.
struct ElderWandProviderGroup: Identifiable, Hashable {
    /// Stable identity — the provider display name (groups are de-duped by it).
    var id: String { providerName }
    let providerName: String
    let options: [ElderWandModelOption]
}

// MARK: - Elder Wand Configurator Model
//
// Pure in-flight edit state for The Elder Wand configurator. Holds the panel
// the user is assembling (selected analysis models, judge, tool-call budget,
// name) and which saved preset — if any — is being edited. It performs NO
// persistence: the configurator view reads `buildPreset()` and hands the
// result to the injected `ElderWandSettings` store.
//
// Editing maps directly onto the OpenRouter "Fusion" contract the daemon
// gateway expects: 1–8 analysis models answer in parallel, one judge compares
// them, capped by `maxToolCalls` (1–16, default 8).

@Observable
@MainActor
final class ElderWandConfiguratorModel {
    /// Currently selected analysis-panel model IDs. Stored as a `Set` so chip
    /// toggling is O(1) and order-independent; lowered to a stable array on
    /// `buildPreset()`.
    var selectedAnalysisIDs: Set<String> = []

    /// The judge model ID, or `nil` when none is chosen yet.
    var judgeID: String?

    /// Per-model tool-loop budget (OpenRouter Fusion parity: 1–16, default 8).
    var maxToolCalls: Int = ElderWandPreset.defaultMaxToolCalls

    /// Working preset name.
    var name: String = ""

    /// The id of the saved preset being edited, or `nil` for a brand-new one.
    var editingPresetID: String?

    init() {}

    // MARK: - Derived validity

    /// Whether the current edit satisfies the OpenRouter Fusion contract:
    /// a named panel of 1–8 analysis models, a non-empty judge, and a
    /// tool-call budget within range.
    var isValid: Bool {
        buildPreset() != nil
    }

    /// The panel size, clamped to the contract maximum for the picker's
    /// "N of 8 selected" affordance.
    var analysisCount: Int { selectedAnalysisIDs.count }

    /// Whether the panel can accept another analysis model (Fusion caps at 8).
    var canAddMoreAnalysis: Bool {
        selectedAnalysisIDs.count < ElderWandPreset.analysisPanelRange.upperBound
    }

    // MARK: - Mutation

    /// Toggles a model in the analysis panel. Adding past the contract maximum
    /// is a no-op so the caller can present the cap without surprising drops.
    func toggleAnalysis(_ id: String) {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if selectedAnalysisIDs.contains(key) {
            selectedAnalysisIDs.remove(key)
        } else if canAddMoreAnalysis {
            selectedAnalysisIDs.insert(key)
        }
    }

    /// Selects (or clears) the judge model. Passing the already-selected id
    /// deselects it.
    func selectJudge(_ id: String) {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        judgeID = (judgeID == key) ? nil : key
    }

    // MARK: - Load / build / reset

    /// Loads an existing preset into the edit buffer for in-place editing.
    func load(from preset: ElderWandPreset) {
        editingPresetID = preset.id
        name = preset.name
        selectedAnalysisIDs = Set(preset.analysisModelIDs.filter { !$0.isEmpty })
        let judge = preset.judgeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        judgeID = judge.isEmpty ? nil : judge
        maxToolCalls = min(
            max(preset.maxToolCalls, ElderWandPreset.maxToolCallsRange.lowerBound),
            ElderWandPreset.maxToolCallsRange.upperBound
        )
    }

    /// Builds a sanitized preset from the current edit state, or `nil` when the
    /// edit is incomplete (missing name, empty panel, or missing judge). When
    /// editing an existing preset its `id` and `isDefault` flag are preserved;
    /// the store re-sanitizes the one-default invariant on save.
    func buildPreset() -> ElderWandPreset? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let analysis = selectedAnalysisIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard ElderWandPreset.analysisPanelRange.contains(analysis.count) else { return nil }

        guard let judge = judgeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !judge.isEmpty else { return nil }

        let clampedToolCalls = min(
            max(maxToolCalls, ElderWandPreset.maxToolCallsRange.lowerBound),
            ElderWandPreset.maxToolCallsRange.upperBound
        )

        return ElderWandPreset(
            id: editingPresetID ?? UUID().uuidString,
            name: trimmedName,
            analysisModelIDs: analysis,
            judgeModelID: judge,
            maxToolCalls: clampedToolCalls,
            isDefault: false
        )
    }

    /// Clears the edit buffer back to a fresh, unnamed panel.
    func reset() {
        selectedAnalysisIDs = []
        judgeID = nil
        maxToolCalls = ElderWandPreset.defaultMaxToolCalls
        name = ""
        editingPresetID = nil
    }
}

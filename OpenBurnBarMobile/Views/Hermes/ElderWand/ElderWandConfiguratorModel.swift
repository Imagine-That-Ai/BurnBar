import Foundation
import OpenBurnBarCore

// MARK: - Elder Wand Configurator Model (iOS)
//
// The editable draft state behind the iOS Elder Wand configurator. Holds the
// *working* copy the UI mutates (panel selection, judge, name, tool-call
// budget) so the underlying `ElderWandSettings.shared` store is only written
// on an explicit Save/Set-default action — never on every chip tap.
//
// This is plain edit state with no view dependencies, kept out of `body` so
// the SwiftUI views stay pure and diff cheaply (the configurator binds it with
// `@Bindable`). All persistence funnels through the injected store, which
// owns the one-default sanitiser and UserDefaults I/O.

@Observable
@MainActor
final class ElderWandConfiguratorModel {
    /// The persistence store (the single source of truth for saved presets).
    @ObservationIgnored let store: ElderWandSettings

    /// The preset currently loaded into the editor, or `nil` when authoring a
    /// brand-new (unsaved) panel.
    private(set) var editingPresetID: String?

    /// Working draft name.
    var draftName: String = ""

    /// Working draft analysis-panel selection (ordered, deduplicated model IDs).
    private(set) var selectedAnalysisModelIDs: [String] = []

    /// Working draft judge model ID (single select). Empty == none chosen.
    var judgeModelID: String = ""

    /// Working draft per-model tool-call budget (OpenRouter Fusion 1...16).
    var maxToolCalls: Int = ElderWandPreset.defaultMaxToolCalls

    init(store: ElderWandSettings = .shared) {
        self.store = store
        loadActiveOrBlank()
    }

    // MARK: - Derived state

    /// The saved presets, newest-default-first ordering left to the store.
    var savedPresets: [ElderWandPreset] { store.presets }

    /// Whether the draft satisfies the OpenRouter Fusion contract enough to be
    /// saved: a name, 1...8 analysis models, and a judge.
    var canSave: Bool {
        !trimmedName.isEmpty
            && ElderWandPreset.analysisPanelRange.contains(selectedAnalysisModelIDs.count)
            && !judgeModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the panel has reached the OpenRouter Fusion ceiling (8 models),
    /// so the UI can stop adding and explain why.
    var isPanelFull: Bool {
        selectedAnalysisModelIDs.count >= ElderWandPreset.analysisPanelRange.upperBound
    }

    /// Whether the draft matches an already-saved preset by id (Save updates it
    /// in place) versus authoring a new one (Save inserts).
    var isEditingExistingPreset: Bool { editingPresetID != nil }

    /// The currently active default preset's id, for the picker's selection ring.
    var activePresetID: String? { store.activePreset?.id }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Panel mutation (multi-select)

    func isAnalysisSelected(_ modelID: String) -> Bool {
        selectedAnalysisModelIDs.contains(modelID)
    }

    /// Toggle an analysis-panel member. Adding past the contract ceiling is a
    /// no-op (the caller surfaces a soft haptic / ceiling note instead). The
    /// judge can also sit on the panel; the two selections are independent.
    /// Returns `true` when the toggle changed the panel.
    @discardableResult
    func toggleAnalysis(_ modelID: String) -> Bool {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let index = selectedAnalysisModelIDs.firstIndex(of: trimmed) {
            selectedAnalysisModelIDs.remove(at: index)
            return true
        }
        guard !isPanelFull else { return false }
        selectedAnalysisModelIDs.append(trimmed)
        return true
    }

    // MARK: - Judge mutation (single-select)

    func isJudge(_ modelID: String) -> Bool {
        judgeModelID == modelID
    }

    func selectJudge(_ modelID: String) {
        judgeModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool-call budget

    /// Clamp the budget back into the OpenRouter Fusion range when a stepper or
    /// decode pushes it out of bounds.
    func clampMaxToolCalls() {
        if !ElderWandPreset.maxToolCallsRange.contains(maxToolCalls) {
            maxToolCalls = min(
                max(maxToolCalls, ElderWandPreset.maxToolCallsRange.lowerBound),
                ElderWandPreset.maxToolCallsRange.upperBound
            )
        }
    }

    // MARK: - Load / reset

    /// Load the store's active preset into the editor, or start blank when none
    /// exist. Called on init and after a destructive edit.
    func loadActiveOrBlank() {
        if let active = store.activePreset {
            load(active)
        } else {
            resetToBlank()
        }
    }

    /// Load a specific saved preset into the editor for editing.
    func load(_ preset: ElderWandPreset) {
        editingPresetID = preset.id
        draftName = preset.name
        selectedAnalysisModelIDs = preset.analysisModelIDs
        judgeModelID = preset.judgeModelID
        maxToolCalls = preset.maxToolCalls
        clampMaxToolCalls()
    }

    /// Clear the editor to author a new panel from scratch.
    func resetToBlank() {
        editingPresetID = nil
        draftName = ""
        selectedAnalysisModelIDs = []
        judgeModelID = ""
        maxToolCalls = ElderWandPreset.defaultMaxToolCalls
    }

    // MARK: - Persistence (funnels through the store)

    /// Build the preset value the current draft represents. `makeDefault`
    /// promotes it to the active preset (the store re-sanitises to one default).
    /// When updating a preset that is ALREADY the default, its default flag is
    /// preserved so a plain "Update" never silently demotes the active panel.
    private func draftPreset(makeDefault: Bool) -> ElderWandPreset {
        let id = editingPresetID ?? UUID().uuidString
        let wasDefault = store.presets.first(where: { $0.id == id })?.isDefault ?? false
        return ElderWandPreset(
            id: id,
            name: trimmedName,
            analysisModelIDs: selectedAnalysisModelIDs,
            judgeModelID: judgeModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            maxToolCalls: maxToolCalls,
            isDefault: makeDefault || wasDefault
        )
    }

    /// Persist the draft. When this is the first saved preset it becomes the
    /// default automatically (the store's sanitiser promotes the only preset).
    /// Returns the saved preset so the caller can keep editing it in place.
    @discardableResult
    func save(makeDefault: Bool = false) -> ElderWandPreset? {
        guard canSave else { return nil }
        let isFirstPreset = store.presets.isEmpty
        let preset = draftPreset(makeDefault: makeDefault || isFirstPreset)
        store.upsert(preset)
        editingPresetID = preset.id
        // Re-read the sanitised default flag back into the draft so the UI's
        // "default" affordance reflects the store, not the requested flag.
        if let persisted = store.presets.first(where: { $0.id == preset.id }) {
            draftName = persisted.name
        }
        return preset
    }

    /// Promote the editing preset (saving first if it is a clean new draft) to
    /// the single default.
    func setEditingAsDefault() {
        if let id = editingPresetID {
            store.setDefault(id: id)
        } else if let saved = save(makeDefault: true) {
            store.setDefault(id: saved.id)
        }
    }

    func setDefault(id: String) {
        store.setDefault(id: id)
    }

    /// Delete a saved preset. If it was the one being edited, reload the new
    /// active preset (or blank) so the editor never points at a dead id.
    func delete(id: String) {
        let wasEditing = editingPresetID == id
        store.remove(id: id)
        if wasEditing {
            loadActiveOrBlank()
        }
    }
}

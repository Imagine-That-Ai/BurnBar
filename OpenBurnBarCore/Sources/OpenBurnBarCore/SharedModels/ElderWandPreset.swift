import Foundation

// MARK: - Elder Wand Preset
//
// A saved configuration for **The Elder Wand** model-fusion router
// (OpenRouter "Fusion"-compatible). A preset names a panel of *analysis
// models* that answer a prompt in parallel, a *judge* model that COMPARES
// their answers into a structured verdict (consensus / contradictions /
// partial coverage / unique insights / blind spots — it does not merge), and
// a per-model tool-call budget. The *originating* chat model (whatever the
// user is already chatting with) writes the final answer from the verdict, so
// it is intentionally NOT stored on the preset.
//
// Exactly one preset is the user's default, enforced by
// `Array<ElderWandPreset>.presetsSanitized()` — the same one-default
// invariant `AgentPersona` uses (`personasSanitized()`).

public struct ElderWandPreset: Codable, Sendable, Hashable, Identifiable {
    /// Stable preset ID (UUID string).
    public let id: String

    /// User-facing preset name shown in the picker.
    public let name: String

    /// The analysis panel: 1–8 model IDs that answer the prompt in parallel.
    public let analysisModelIDs: [String]

    /// The judge model that compares the panel answers into the structured verdict.
    public let judgeModelID: String

    /// Per-model tool-loop budget (OpenRouter Fusion parity: 1–16, default 8).
    public let maxToolCalls: Int

    /// Whether this is the user's default preset. Exactly one preset should
    /// have this true (enforced by `Array.presetsSanitized()`).
    public let isDefault: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        analysisModelIDs: [String],
        judgeModelID: String,
        maxToolCalls: Int = ElderWandPreset.defaultMaxToolCalls,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.analysisModelIDs = analysisModelIDs
        self.judgeModelID = judgeModelID
        self.maxToolCalls = maxToolCalls
        self.isDefault = isDefault
    }

    // MARK: - OpenRouter Fusion contract constants

    /// OpenRouter Fusion default tool-call budget.
    public static let defaultMaxToolCalls = 8

    /// OpenRouter Fusion valid `max_tool_calls` range.
    public static let maxToolCallsRange: ClosedRange<Int> = 1...16

    /// OpenRouter Fusion analysis-panel size range.
    public static let analysisPanelRange: ClosedRange<Int> = 1...8

    /// A copy with `isDefault` overridden (value-type friendly mutation used
    /// by the sanitizer and the "set default" UI path).
    public func withIsDefault(_ value: Bool) -> ElderWandPreset {
        ElderWandPreset(
            id: id,
            name: name,
            analysisModelIDs: analysisModelIDs,
            judgeModelID: judgeModelID,
            maxToolCalls: maxToolCalls,
            isDefault: value
        )
    }

    /// Whether the preset's panel size and tool-call budget are within the
    /// OpenRouter Fusion contract bounds.
    public var isWithinContractBounds: Bool {
        ElderWandPreset.analysisPanelRange.contains(analysisModelIDs.count)
            && ElderWandPreset.maxToolCallsRange.contains(maxToolCalls)
    }
}

// MARK: - Sanitisation

extension Array where Element == ElderWandPreset {
    /// Ensures exactly one preset is `isDefault`. If none are marked, the first
    /// is promoted; if multiple are marked, only the first marked one stays.
    /// An element that is already the single default is returned unchanged.
    public func presetsSanitized() -> [ElderWandPreset] {
        guard !isEmpty else { return [] }
        let defaultCount = filter { $0.isDefault }.count
        if defaultCount == 1 { return self }
        let defaultIndex = firstIndex { $0.isDefault } ?? startIndex
        return enumerated().map { index, preset in
            preset.withIsDefault(index == defaultIndex)
        }
    }
}

import Foundation

/// What the user is asking the model to do.
///
/// The gateway uses this request to build the system prompt, attach the
/// digest, and configure the structured-output tier.
public struct InsightInvestigateRequest: Hashable, Sendable {
    public var prompt: String                    // user prompt or template seed
    public var digest: InsightDigest             // sanitized data snapshot
    public var canvas: InsightCanvas?            // current canvas if refining
    public var widget: InsightWidget?            // if a single widget is being refreshed
    public var modelTag: InsightModelTag         // target model
    public var capabilityTier: InsightCapabilityTier
    public var maxNewWidgets: Int                // safety cap
    public var allowToolCalls: Bool
    public var instruction: Instruction          // semantic hint for the prompt engine

    public init(
        prompt: String,
        digest: InsightDigest,
        canvas: InsightCanvas? = nil,
        widget: InsightWidget? = nil,
        modelTag: InsightModelTag,
        capabilityTier: InsightCapabilityTier,
        maxNewWidgets: Int = 12,
        allowToolCalls: Bool = true,
        instruction: Instruction = .composeCanvas
    ) {
        self.prompt = prompt
        self.digest = digest
        self.canvas = canvas
        self.widget = widget
        self.modelTag = modelTag
        self.capabilityTier = capabilityTier
        self.maxNewWidgets = maxNewWidgets
        self.allowToolCalls = allowToolCalls
        self.instruction = instruction
    }

    public enum Instruction: String, Hashable, Sendable {
        /// Author a new multi-widget canvas from scratch.
        case composeCanvas
        /// Refine an existing canvas based on the prompt.
        case refineCanvas
        /// Refresh narrative widgets only, leave structure intact.
        case refreshNarratives
        /// Investigate a single widget — re-emit it improved.
        case refineWidget
        /// Produce one narrative widget with key findings (no other widgets).
        case explainBriefly
    }
}

import Foundation
import OpenBurnBarEngine

extension BurnBarAnthropicProviderExecutor {

    // MARK: - Thinking variant application

    /// Variant-always-wins injection of Anthropic extended-thinking config.
    ///
    /// Typed core shared by the live proxy rewrite and the chat/responses
    /// compatibility bridge. Sets `thinking = { type: enabled, budget_tokens: ... }`.
    /// Anthropic rejects `budget_tokens >= max_tokens`, so in bridge mode the
    /// helper raises the floor of `max_tokens` to `budget_tokens + 4096` when
    /// the caller's value would conflict. In `effortOnly` (live proxy) mode it
    /// instead clamps the thinking budget under the caller's `max_tokens`
    /// ceiling and never raises a value the caller provided.
    static func applyAnthropicVariant(
        _ variant: BurnBarModelVariant,
        thinking: inout BurnBarBridgeValue?,
        maxTokens: inout BurnBarBridgeValue?,
        effortOnly: Bool = false
    ) {
        let budget = variant.thinkingLevel.anthropicBudgetTokens

        if effortOnly {
            // Respect the caller's max_tokens ceiling. Anthropic requires
            // budget_tokens < max_tokens, so clamp the thinking budget to fit
            // under whatever the caller asked for rather than inflating it.
            let callerMax = maxTokens?.asPositiveInt
                ?? variant.maxOutputTokens
                ?? (budget + 4096)
            // Keep a minimum slice for the visible answer beyond the thinking
            // budget; Anthropic's floor for a thinking budget is 1024 tokens.
            let maxBudget = callerMax - 1024
            if maxBudget >= 1024 {
                let effectiveBudget = max(1024, min(budget, maxBudget))
                thinking = AnthropicThinkingConfig(type: "enabled", budgetTokens: effectiveBudget).bridgeValue()
            } else {
                // Caller's budget is too small to host extended thinking;
                // leave thinking disabled rather than raising their ceiling.
                thinking = nil
            }
            // Only set max_tokens when the caller omitted it (Anthropic
            // requires the field); never raise a value they provided.
            if maxTokens?.asPositiveInt == nil {
                maxTokens = .int(callerMax)
            }
            return
        }

        thinking = AnthropicThinkingConfig(type: "enabled", budgetTokens: budget).bridgeValue()

        let floor = budget + 4096
        let callerMax = maxTokens?.asPositiveInt ?? 0
        let chosenMax: Int
        if let variantMax = variant.maxOutputTokens {
            chosenMax = max(variantMax, floor)
        } else {
            chosenMax = max(callerMax, floor)
        }
        maxTokens = .int(chosenMax)
    }

    /// Test-compatible entry point kept for `BurnBarModelVariantExecutorTests`.
    ///
    /// Round-trips through the typed core above so the dictionary shape always
    /// exercises the same logic as the proxy. New code should call the typed
    /// core directly.
    static func applyAnthropicVariant(
        _ variant: BurnBarModelVariant,
        to object: inout [String: Any],
        effortOnly: Bool = false
    ) {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           var request = try? JSONDecoder().decode(AnthropicPassthroughRequest.self, from: data) {
            request.additionalFields.removeValue(forKey: "effort")
            Self.applyAnthropicVariant(
                variant,
                thinking: &request.thinking,
                maxTokens: &request.maxTokens,
                effortOnly: effortOnly
            )
            if let out = try? JSONEncoder().encode(request),
               let restored = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] {
                object = restored
                return
            }
        }
        // Fallback for values JSONSerialization cannot round-trip (never hit
        // for JSON-derived dictionaries): same semantics, inline.
        let budget = variant.thinkingLevel.anthropicBudgetTokens
        object.removeValue(forKey: "effort")
        if effortOnly {
            let callerMax = Self.positiveInt(object["max_tokens"])
                ?? variant.maxOutputTokens
                ?? (budget + 4096)
            let maxBudget = callerMax - 1024
            if maxBudget >= 1024 {
                let effectiveBudget = max(1024, min(budget, maxBudget))
                object["thinking"] = ["type": "enabled", "budget_tokens": effectiveBudget]
            } else {
                object.removeValue(forKey: "thinking")
            }
            if Self.positiveInt(object["max_tokens"]) == nil {
                object["max_tokens"] = callerMax
            }
            return
        }
        object["thinking"] = ["type": "enabled", "budget_tokens": budget]
        let floor = budget + 4096
        let callerMax = Self.positiveInt(object["max_tokens"]) ?? 0
        if let variantMax = variant.maxOutputTokens {
            object["max_tokens"] = max(variantMax, floor)
        } else {
            object["max_tokens"] = max(callerMax, floor)
        }
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return max(1, value) }
        if let value = value as? NSNumber { return max(1, value.intValue) }
        if let value = value as? String, let parsed = Int(value) { return max(1, parsed) }
        return nil
    }
}

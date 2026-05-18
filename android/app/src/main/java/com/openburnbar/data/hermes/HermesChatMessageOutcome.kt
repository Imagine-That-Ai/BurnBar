package com.openburnbar.data.hermes

/**
 * First-class classification of an assistant turn so the bubble UI can
 * render distinct visual treatments (tag, color, retry button) without
 * parsing prose.
 *
 * 1:1 port of `enum HermesChatMessageOutcome` in
 * `OpenBurnBarMobile/Services/HermesService.swift`. `NORMAL` is the
 * default; the rescue helper sets the others when a stream finishes
 * without producing real `content`.
 */
enum class HermesChatMessageOutcome(val rawValue: String) {
    /** Model returned a real reply. No special chrome. */
    NORMAL("normal"),

    /**
     * Model intentionally declined (OpenAI `delta.refusal`). Not an
     * error — the model responded — but worth flagging so users don't
     * think their question was misunderstood.
     */
    REFUSAL("refusal"),

    /**
     * Stream produced no `content` but did emit the reasoning channel.
     * The bubble hoists the reasoning into `text`; the badge tells the
     * user this is raw thinking, not a polished answer.
     */
    REASONING_FALLBACK("reasoningFallback"),

    /** `finish_reason: "length"` with no content. */
    LENGTH_CAP("lengthCap"),

    /** `finish_reason: "content_filter"` with no content. */
    CONTENT_FILTER("contentFilter"),

    /** Model emitted `tool_calls` but no follow-up turn produced a real reply. */
    TOOL_CALL_NO_FOLLOW_UP("toolCallNoFollowUp"),

    /** Stream closed cleanly with no usable signals at all. */
    EMPTY("empty");

    /**
     * `true` when this outcome should offer the user a "Try again"
     * affordance. Refusals are excluded — the model intentionally
     * declined; mashing retry won't change that.
     */
    val supportsRetry: Boolean
        get() = when (this) {
            LENGTH_CAP, CONTENT_FILTER, TOOL_CALL_NO_FOLLOW_UP, EMPTY -> true
            NORMAL, REFUSAL, REASONING_FALLBACK -> false
        }

    /** Short label rendered as a badge above the bubble. */
    val label: String?
        get() = when (this) {
            NORMAL -> null
            REFUSAL -> "Declined"
            REASONING_FALLBACK -> "Reasoning channel"
            LENGTH_CAP -> "Reply truncated"
            CONTENT_FILTER -> "Filtered"
            TOOL_CALL_NO_FOLLOW_UP -> "Tool call dropped"
            EMPTY -> "No reply"
        }

    /**
     * Hint name for the leading badge glyph. Mirrors the SF Symbol
     * identifiers iOS uses; the Android badge view picks the matching
     * `Icons.Filled.*` based on the name.
     */
    val iconName: String?
        get() = when (this) {
            NORMAL -> null
            REFUSAL -> "hand.raised.fill"
            REASONING_FALLBACK -> "brain"
            LENGTH_CAP -> "scissors"
            CONTENT_FILTER -> "shield.lefthalf.filled"
            TOOL_CALL_NO_FOLLOW_UP -> "wrench.and.screwdriver"
            EMPTY -> "exclamationmark.bubble"
        }

    companion object {
        /**
         * Body + first-class outcome to use when the upstream stream
         * finished without producing any visible `content` or executable
         * `tool_calls`. Three rescue paths in priority order:
         *
         * 1. **Refusal**: model declined; surface the refusal reason.
         * 2. **Reasoning-only**: hoist the raw reasoning into the bubble.
         * 3. **Hard empty**: surface a finish-reason-keyed message.
         *
         * Mirrors `HermesChatMessage.emptyResponseFallback(...)` in
         * `OpenBurnBarMobile/Services/HermesService.swift` exactly.
         */
        fun emptyResponseFallback(
            refusal: String,
            reasoning: String,
            finishReason: String?
        ): EmptyResponseFallback {
            val trimmedRefusal = refusal.trim()
            if (trimmedRefusal.isNotEmpty()) {
                return EmptyResponseFallback(trimmedRefusal, isError = false, outcome = REFUSAL)
            }
            val trimmedReasoning = reasoning.trim()
            if (trimmedReasoning.isNotEmpty()) {
                return EmptyResponseFallback(trimmedReasoning, isError = false, outcome = REASONING_FALLBACK)
            }
            return when (finishReason?.lowercase()) {
                "length" -> EmptyResponseFallback(
                    "Hermes hit its reply length cap before finishing. Try a shorter prompt or switch to a model with a larger reply ceiling.",
                    isError = true,
                    outcome = LENGTH_CAP
                )
                "content_filter" -> EmptyResponseFallback(
                    "Hermes blocked this reply for content safety. Try rewording the prompt or switch models.",
                    isError = true,
                    outcome = CONTENT_FILTER
                )
                "tool_calls" -> EmptyResponseFallback(
                    "Hermes asked to use a tool but didn't follow up with a reply. Try again or switch models.",
                    isError = true,
                    outcome = TOOL_CALL_NO_FOLLOW_UP
                )
                else -> EmptyResponseFallback(
                    "Hermes returned no text. Try again or switch models.",
                    isError = true,
                    outcome = EMPTY
                )
            }
        }
    }
}

/** Result tuple returned by [HermesChatMessageOutcome.emptyResponseFallback]. */
data class EmptyResponseFallback(
    val text: String,
    val isError: Boolean,
    val outcome: HermesChatMessageOutcome
)

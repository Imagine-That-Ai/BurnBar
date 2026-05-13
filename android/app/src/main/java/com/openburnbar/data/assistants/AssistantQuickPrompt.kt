package com.openburnbar.data.assistants

import com.openburnbar.data.hermes.AssistantRuntimeID

/**
 * A curated catalog of widget-friendly prompts shared between the
 * "Ask Hermes" / "Ask Pi" chip rows on the bigger widgets
 * (`BurnBarLargeWidget`, `BurnBarMediumWidget`) and any future surface
 * that wants a one-tap suggestion. Mirrors
 * `OpenBurnBarCore/SharedModels/AssistantQuickPrompt.swift` on iOS — keep
 * the two lists in sync.
 *
 * Each prompt has a *preferred assistant* hint so the chip routes to the
 * assistant the prompt is most likely to want, but both runtimes accept
 * any prompt — the hint is a soft suggestion. If the preferred runtime is
 * unreachable at tap time, callers may transparently fall back to the
 * other.
 */
enum class AssistantQuickPromptId {
    BURN_TODAY,
    FORECAST_EOD,
    CACHE_RECAP,
    TOP_THREE,
    SUMMARIZE_SESSION,
    CODE_REVIEW
}

data class AssistantQuickPrompt(
    val id: AssistantQuickPromptId,
    /** Short label rendered on a widget chip — fits ~10 characters comfortably. */
    val chipLabel: String,
    /** Full prompt the assistant receives when the chip is tapped. */
    val fullPrompt: String,
    /** Soft preference; user can flip runtimes once inside the app. */
    val preferredAssistant: AssistantRuntimeID
)

object AssistantQuickPromptCatalog {
    /**
     * Order matters — Large widgets surface the first 3, second-row chips
     * (ExtraLarge / Android Medium) surface the first 6.
     */
    val all: List<AssistantQuickPrompt> = listOf(
        AssistantQuickPrompt(
            id = AssistantQuickPromptId.BURN_TODAY,
            chipLabel = "Burn?",
            fullPrompt = "What's my burn today, and where's it going?",
            preferredAssistant = AssistantRuntimeID.HERMES
        ),
        AssistantQuickPrompt(
            id = AssistantQuickPromptId.FORECAST_EOD,
            chipLabel = "Forecast",
            fullPrompt = "Forecast my spend through end of day.",
            preferredAssistant = AssistantRuntimeID.HERMES
        ),
        AssistantQuickPrompt(
            id = AssistantQuickPromptId.CACHE_RECAP,
            chipLabel = "Cache",
            fullPrompt = "Recap my cache hit rate and what I'd save by raising it.",
            preferredAssistant = AssistantRuntimeID.HERMES
        ),
        AssistantQuickPrompt(
            id = AssistantQuickPromptId.TOP_THREE,
            chipLabel = "Top 3",
            fullPrompt = "Show me my top three providers and what changed since yesterday.",
            preferredAssistant = AssistantRuntimeID.HERMES
        ),
        AssistantQuickPrompt(
            id = AssistantQuickPromptId.SUMMARIZE_SESSION,
            chipLabel = "Summarize",
            fullPrompt = "Summarize my last project session in three bullets.",
            preferredAssistant = AssistantRuntimeID.PI
        ),
        AssistantQuickPrompt(
            id = AssistantQuickPromptId.CODE_REVIEW,
            chipLabel = "Code review",
            fullPrompt = "What are the top issues in my staged diff right now?",
            preferredAssistant = AssistantRuntimeID.PI
        )
    )

    /** Hermes-tagged prompts only — used by the Large widget's narrow second row. */
    val hermesShortlist: List<AssistantQuickPrompt> =
        all.filter { it.preferredAssistant == AssistantRuntimeID.HERMES }

    fun prompt(id: AssistantQuickPromptId): AssistantQuickPrompt? =
        all.firstOrNull { it.id == id }
}

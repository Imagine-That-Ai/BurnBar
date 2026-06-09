package com.openburnbar

import android.content.Intent

/** Keeps assistant launch intents navigation-only; prompt auto-submit is forbidden. */
internal object MainActivityIntentActions {
    fun stashPendingPromptFromIntent(intent: Intent?) {
        // Public/browsable intents are navigation-only. Never auto-submit a
        // prompt supplied by an exported Activity Intent; in-app surfaces can
        // still route prompts through process-local state when they have a
        // trusted UI event.
        if (intent == null) return
    }
}

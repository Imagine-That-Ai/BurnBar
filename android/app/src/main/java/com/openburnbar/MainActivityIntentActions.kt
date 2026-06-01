package com.openburnbar

import android.content.Intent
import com.openburnbar.data.assistants.PiPendingPrompt
import com.openburnbar.ui.navigation.HermesPendingPrompt

/** Handles assistant prompt hints from launch / deep-link intents. */
internal object MainActivityIntentActions {
    fun stashPendingPromptFromIntent(intent: Intent?) {
        if (intent == null) return
        val prompt = readPromptHint(intent)?.takeIf { it.isNotBlank() } ?: return
        val assistant = readAssistantHint(intent)
        if (assistant == MainActivity.ASSISTANT_PI) {
            PiPendingPrompt.pending = prompt
        } else {
            HermesPendingPrompt.pending = prompt
        }
    }

    fun readAssistantHint(intent: Intent): String {
        intent.getStringExtra(MainActivity.EXTRA_ASSISTANT)?.lowercase()?.let { return it }
        intent.data?.let { uri ->
            uri.getQueryParameter("runtime")?.lowercase()?.let { return it }
            uri.host?.lowercase()?.let { host ->
                if (host == MainActivity.ASSISTANT_PI || host == MainActivity.ASSISTANT_HERMES) return host
            }
        }
        return MainActivity.ASSISTANT_HERMES
    }

    fun readPromptHint(intent: Intent): String? {
        intent.getStringExtra(MainActivity.EXTRA_PROMPT)?.let { return it }
        return intent.data?.getQueryParameter("prompt")
    }
}

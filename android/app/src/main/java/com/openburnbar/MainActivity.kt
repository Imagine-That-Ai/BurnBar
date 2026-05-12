package com.openburnbar

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.openburnbar.data.assistants.PiPendingPrompt
import com.openburnbar.ui.navigation.BurnBarNavHost
import com.openburnbar.ui.navigation.HermesPendingPrompt
import com.openburnbar.ui.theme.AuroraTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        stashPendingPromptFromIntent(intent)
        setContent {
            AuroraTheme {
                BurnBarNavHost()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        stashPendingPromptFromIntent(intent)
    }

    /**
     * Read the optional "assistant" + "prompt" hint from a launch / new
     * intent and stash the prompt into the matching pending-prompt
     * singleton. Both intent forms are accepted:
     *
     *   • Direct extras: `EXTRA_ASSISTANT` ("hermes" | "pi") + `EXTRA_PROMPT`.
     *     Widget chips use this path via `actionStartActivity(Intent.putExtra)`.
     *   • Deep-link URI: `burnbar://hermes?prompt=…` or `burnbar://pi?prompt=…`,
     *     also `burnbar://assistants?runtime=pi&prompt=…`. Adb / external
     *     deep links use this path.
     *
     * The assistant tab destination itself is resolved by the existing
     * deep-link route in `BurnBarNavHost`; this hook only owns the
     * prompt-stash side of the bridge.
     */
    private fun stashPendingPromptFromIntent(intent: Intent?) {
        if (intent == null) return
        val prompt = readPromptHint(intent)?.takeIf { it.isNotBlank() } ?: return
        val assistant = readAssistantHint(intent)
        if (assistant == ASSISTANT_PI) {
            PiPendingPrompt.pending = prompt
        } else {
            HermesPendingPrompt.pending = prompt
        }
    }

    private fun readAssistantHint(intent: Intent): String {
        intent.getStringExtra(EXTRA_ASSISTANT)?.lowercase()?.let { return it }
        intent.data?.let { uri ->
            uri.getQueryParameter("runtime")?.lowercase()?.let { return it }
            // `burnbar://pi` and `burnbar://hermes` both encode runtime in
            // the host segment — fall back to that when no explicit hint
            // is present.
            uri.host?.lowercase()?.let { host ->
                if (host == ASSISTANT_PI || host == ASSISTANT_HERMES) return host
            }
        }
        return ASSISTANT_HERMES
    }

    private fun readPromptHint(intent: Intent): String? {
        intent.getStringExtra(EXTRA_PROMPT)?.let { return it }
        return intent.data?.getQueryParameter("prompt")
    }

    companion object {
        const val EXTRA_ASSISTANT = "burnbar.assistant"
        const val EXTRA_PROMPT = "burnbar.prompt"
        const val ASSISTANT_HERMES = "hermes"
        const val ASSISTANT_PI = "pi"
    }
}

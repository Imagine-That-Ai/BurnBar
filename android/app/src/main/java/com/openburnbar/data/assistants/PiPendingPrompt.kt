package com.openburnbar.data.assistants

/**
 * Process-wide pending-prompt slot for the Pi runtime. Mirrors the
 * existing `HermesPendingPrompt` (in `ui/navigation/BurnBarNavHost.kt`)
 * and is read by `PiAssistantView` via a `LaunchedEffect` that auto-sends
 * the prompt and clears the slot.
 *
 * Writers:
 *   • `MainActivity.stashPendingPromptFromIntent` — on launch / new intent.
 *   • The widget Ask-Pi chip's `actionStartActivity` Intent carries the
 *     prompt as an extra and a `burnbar://pi` data URI; MainActivity
 *     decodes either form and stashes the slot here.
 */
object PiPendingPrompt {
    var pending: String? = null
}

package com.openburnbar.ui.analytics

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.openburnbar.analytics.AnalyticsManager

/**
 * First-run, opt-in analytics consent prompt (Compose). Renders ONLY when the
 * tri-state consent is still `unset`; declining — or never answering — keeps the
 * app dark (the Amplitude SDK is never constructed). Mirrors the macOS first-run
 * prompt and the website ConsentBanner.astro.
 *
 * On Accept: persist `granted`, start the transport, and emit exactly one
 * `consent.analytics.granted` plus the session-start spine. On "Not now":
 * persist `declined` and stay dark. Either choice dismisses the prompt for good.
 */
@Composable
fun AnalyticsConsentPrompt() {
    // Snapshot the undecided state once at composition. AnalyticsManager state is
    // process-wide, so a local flag drives dismissal after the user chooses.
    var visible by remember { mutableStateOf(!AnalyticsManager.hasDecided) }
    if (!visible) return

    AlertDialog(
        onDismissRequest = { /* require an explicit choice; no tap-outside dismiss */ },
        title = { Text("Privacy-first, opt-in analytics") },
        text = {
            Text(
                "We'd like to measure feature usage with privacy-preserving analytics " +
                    "(Amplitude) to improve BurnBar. No personal data, no message content, " +
                    "no tracking until you choose to opt in. You can change this anytime in " +
                    "Settings → Privacy.",
                style = MaterialTheme.typography.bodyMedium,
            )
        },
        confirmButton = {
            TextButton(onClick = {
                AnalyticsManager.grant()
                AnalyticsManager.trackCurrentSessionStartIfConsented()
                visible = false
            }) {
                Text("Enable analytics")
            }
        },
        dismissButton = {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
                TextButton(onClick = {
                    AnalyticsManager.decline()
                    visible = false
                }) {
                    Text("Not now")
                }
            }
        },
    )
}

/** Convenience host that simply overlays the prompt; no layout footprint when hidden. */
@Composable
fun AnalyticsConsentHost(modifier: Modifier = Modifier) {
    Column(modifier = modifier) { AnalyticsConsentPrompt() }
}

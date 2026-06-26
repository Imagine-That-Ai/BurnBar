package com.openburnbar.ui.analytics

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.openburnbar.analytics.AnalyticsEvent
import com.openburnbar.analytics.AnalyticsManager
import com.openburnbar.analytics.AnalyticsValue
import com.openburnbar.diagnostics.CrashReportingConsentStore

/**
 * Revisitable privacy / analytics control. Lets the user grant or revoke the
 * opt-in analytics at any time — the settings-side counterpart to the first-run
 * [AnalyticsConsentPrompt], mirroring the macOS settings toggle and the website
 * "manage analytics" control.
 *
 * Turning it ON grants consent, starts the transport, and emits exactly one
 * `consent.analytics.granted`. Turning it OFF revokes (= declined): the
 * transport stops, nothing is flushed, and no "revoked" event is sent (that
 * would be a send after revoke). The `settings.changed` event is emitted only
 * for the ON edge (while consent is granted) so the OFF edge stays silent.
 */
@Composable
fun AnalyticsPrivacyScreen(onBack: () -> Unit) {
    val context = LocalContext.current.applicationContext
    val crashReportingConsent = remember(context) { CrashReportingConsentStore.fromContext(context) }
    var granted by remember { mutableStateOf(AnalyticsManager.isGranted) }
    var crashReportsEnabled by remember { mutableStateOf(crashReportingConsent.isEnabled) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Spacer(Modifier.height(16.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
            }
            Text(
                "Privacy & Analytics",
                fontWeight = FontWeight.Bold,
                fontSize = 22.sp,
                modifier = Modifier.weight(1f),
            )
        }

        AnalyticsConsentToggleRow(
            checked = granted,
            onCheckedChange = { wantOn ->
                if (wantOn) {
                    AnalyticsManager.grant()
                    // Emitted while consent is now granted, so it actually sends.
                    AnalyticsManager.track(
                        AnalyticsEvent.SETTINGS_CHANGED,
                        mapOf(
                            "setting_key" to AnalyticsValue.Str("analytics_consent"),
                            "new_value" to AnalyticsValue.Bool(true),
                        ),
                    )
                } else {
                    // Revoke stops sends; do NOT emit settings.changed (post-revoke send).
                    AnalyticsManager.revoke()
                }
                granted = wantOn
            },
        )

        CrashReportingConsentToggleRow(
            checked = crashReportsEnabled,
            onCheckedChange = { wantOn ->
                crashReportingConsent.setEnabled(wantOn)
                FirebaseCrashlytics.getInstance().setCrashlyticsCollectionEnabled(wantOn)
                AnalyticsManager.track(
                    AnalyticsEvent.SETTINGS_CHANGED,
                    mapOf(
                        "setting_key" to AnalyticsValue.Str("crash_reporting_consent"),
                        "new_value" to AnalyticsValue.Bool(wantOn),
                    ),
                )
                crashReportsEnabled = wantOn
            },
        )

        Text(
            "When enabled, BurnBar sends privacy-preserving, opt-in usage analytics " +
                "(Amplitude) to improve the app. We never send message content, prompts, " +
                "responses, file paths, API keys, or personal data — only feature usage, " +
                "outcomes, and coarse, bucketed counts and durations. Crash reports are a " +
                "separate diagnostics toggle and stay off until you enable them.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontSize = 13.sp,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
private fun CrashReportingConsentToggleRow(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val isDark = isSystemInDarkTheme()
    val border = MaterialTheme.colorScheme.outlineVariant
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (isDark) 0.4f else 0.6f))
            .border(1.dp, border, RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text("Crash reports", fontWeight = FontWeight.SemiBold)
            Text(
                "Optional diagnostics (Firebase Crashlytics)",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
            )
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

@Composable
private fun AnalyticsConsentToggleRow(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val isDark = isSystemInDarkTheme()
    val border = MaterialTheme.colorScheme.outlineVariant
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (isDark) 0.4f else 0.6f))
            .border(1.dp, border, RoundedCornerShape(12.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text("Usage analytics", fontWeight = FontWeight.SemiBold)
            Text(
                "Opt-in, privacy-preserving (Amplitude)",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontSize = 12.sp,
            )
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

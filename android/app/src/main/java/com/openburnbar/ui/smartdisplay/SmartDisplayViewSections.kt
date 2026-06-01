@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.smartdisplay

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSecondaryButton
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
internal fun StatusFeedback(state: SmartHubSnapshot) {
    val message = state.actionError ?: state.actionMessage ?: return
    val tone = if (state.actionError != null) AuroraBadgeTone.Error else AuroraBadgeTone.Info
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        ) {
            AuroraBadge(text = if (state.actionError != null) "Needs attention" else "Working", tone = tone)
            Text(message, style = AuroraType.body, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    Spacer(Modifier.height(AuroraSpacing.md.dp))
}

@Composable
internal fun NestHubCard(state: SmartHubSnapshot) {
    val bridgeReady = state.bridgeEnabled && state.bridgeIsLive && !state.refreshUrl.isNullOrBlank()
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        NestHubCardHeader(state = state, bridgeReady = bridgeReady)

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        Text(
            text = bridgeSummary(state),
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        NestHubBridgeActionButtons(state = state, bridgeReady = bridgeReady)

        Spacer(Modifier.height(AuroraSpacing.lg.dp))

        NestHubCastDiscoverySection(state = state)
    }
}

@Composable
internal fun PixelClockCard(state: SmartHubSnapshot) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        PixelClockCardHeader(state = state)

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        PixelClockEnableToggle(state = state)

        Spacer(Modifier.height(AuroraSpacing.sm.dp))

        PixelClockDeviceList(state = state)

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        PixelClockRepairActions(state = state)

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        PixelClockBrightnessSlider(state = state)

        Spacer(Modifier.height(AuroraSpacing.sm.dp))

        PixelClockTimeFormatRow(state = state)

        Spacer(Modifier.height(AuroraSpacing.sm.dp))

        PixelClockRefreshSlider(state = state)
    }
}

@Composable
internal fun CastDeviceRow(device: CastDisplayDevice, selected: Boolean, busy: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = AuroraSpacing.xs.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                Text(device.friendlyName, style = AuroraType.body)
                if (selected) {
                    AuroraBadge(text = "Selected", tone = AuroraBadgeTone.Success)
                }
            }
            Text(
                listOf(device.model, device.host).filter { it.isNotBlank() }.joinToString(" • "),
                style = AuroraType.tiny,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        AuroraSecondaryButton(
            onClick = { SmartHubBridgeClientCastActions.saveCastSelection(device) },
            enabled = !busy,
        ) {
            Icon(Icons.Filled.Save, contentDescription = null)
            Text("Save")
        }
        Spacer(Modifier.width(AuroraSpacing.xs.dp))
        AuroraSecondaryButton(
            onClick = { SmartHubBridgeClientCastActions.testCast(device) },
            enabled = !busy,
        ) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null)
            Text("Cast")
        }
    }
}

internal fun bridgeSummary(state: SmartHubSnapshot): String {
    val source = state.bridgeSourceDeviceName?.takeIf { it.isNotBlank() } ?: "No Mac has published a bridge yet"
    val published = state.bridgePublishedAtMs?.let { " • updated ${relativeAge(it)}" }.orEmpty()
    val email = state.signedInEmail?.let { "\nAccount: $it" }.orEmpty()
    val bridge =
        when {
            state.refreshUrl != null && state.bridgeIsLive -> "Bridge: ready"
            state.refreshUrl != null -> state.bridgeFreshnessMessage
            state.bridgeEnabled -> "Bridge: enabled but missing refresh URL"
            else -> "Bridge: not active"
        }
    return "$source$published\n$bridge$email"
}

internal fun relativeAge(timestampMs: Long): String {
    val seconds = ((System.currentTimeMillis() - timestampMs) / 1000).coerceAtLeast(0)
    return when {
        seconds < 60 -> "${seconds}s ago"
        seconds < 3600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3600}h ago"
        else -> "${seconds / 86_400}d ago"
    }
}

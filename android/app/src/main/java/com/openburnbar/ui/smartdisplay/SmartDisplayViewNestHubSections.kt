@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.smartdisplay

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.components.AuroraSecondaryButton
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
internal fun NestHubCardHeader(state: SmartHubSnapshot, bridgeReady: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(Icons.Filled.Devices, contentDescription = null, tint = AuroraColors.whimsy)
        Text("Google Smart Display", style = AuroraType.title, modifier = Modifier.weight(1f))
        AuroraBadge(
            text =
            when {
                state.isLoading -> "Loading"
                bridgeReady -> "Bridge ready"
                state.bridgeEnabled && !state.bridgeIsLive -> "Mac offline"
                state.bridgeEnabled -> "No refresh URL"
                else -> "No Mac bridge"
            },
            tone =
            when {
                bridgeReady -> AuroraBadgeTone.Success
                state.bridgeEnabled && !state.bridgeIsLive -> AuroraBadgeTone.Warning
                state.bridgeEnabled -> AuroraBadgeTone.Warning
                else -> AuroraBadgeTone.Neutral
            },
        )
    }
}

@Composable
internal fun NestHubBridgeActionButtons(state: SmartHubSnapshot, bridgeReady: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        AuroraSecondaryButton(
            onClick = SmartHubBridgeClientCastActions::refreshNestHub,
            enabled = !state.actionInFlight && bridgeReady,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Refresh, contentDescription = null)
            Text("Refresh display")
        }
        AuroraSecondaryButton(
            onClick = SmartHubBridgeClientCastActions::repairAllSmartDisplays,
            enabled = !state.actionInFlight && state.bridgeIsLive,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Settings, contentDescription = null)
            Text("Repair connection")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            AuroraSecondaryButton(
                onClick = SmartHubBridgeClientCastActions::identifyNestHub,
                enabled = !state.actionInFlight && state.bridgeIsLive,
                modifier = Modifier.weight(1f),
            ) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null)
                Text("Identify")
            }
            AuroraSecondaryButton(
                onClick = SmartHubBridgeClientCastActions::stopNestHub,
                enabled = !state.actionInFlight && state.bridgeIsLive,
                modifier = Modifier.weight(1f),
            ) {
                Icon(Icons.Filled.Stop, contentDescription = null)
                Text("Stop")
            }
        }
    }
}

@Composable
internal fun NestHubCastDiscoverySection(state: SmartHubSnapshot) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            "Available Google displays",
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        AuroraSecondaryButton(
            onClick = SmartHubBridgeClientCastActions::runCastDiscovery,
            enabled = !state.actionInFlight && state.bridgeIsLive,
            loading = state.isDiscoveringCastDevices,
        ) {
            Icon(Icons.Filled.Search, contentDescription = null)
            Text("Find")
        }
    }

    Spacer(Modifier.height(AuroraSpacing.xs.dp))

    if (state.castDevices.isEmpty()) {
        Text(
            if (state.bridgeIsLive) {
                "Run Find while the Mac app is open. The Mac scans the network, then Android can save and cast to the selected display."
            } else {
                state.bridgeFreshnessMessage
            },
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    } else {
        state.castDevices.forEach { device ->
            CastDeviceRow(device = device, selected = device.id == state.selectedCastDeviceId, busy = state.actionInFlight)
        }
    }
}

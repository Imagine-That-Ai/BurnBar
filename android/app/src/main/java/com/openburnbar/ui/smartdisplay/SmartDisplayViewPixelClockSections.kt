// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.smartdisplay

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.components.AuroraSecondaryButton
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
internal fun PixelClockCardHeader(state: SmartHubSnapshot) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(Icons.Filled.Tv, contentDescription = null, tint = AuroraColors.ember)
        Text("Pixel Clock", style = AuroraType.title, modifier = Modifier.weight(1f))
        AuroraBadge(
            text = if (state.pixelClockSelectedDeviceId != null) "Connected" else "No device",
            tone = if (state.pixelClockSelectedDeviceId != null) AuroraBadgeTone.Success else AuroraBadgeTone.Warning,
        )
    }
}

@Composable
internal fun PixelClockDeviceList(state: SmartHubSnapshot) {
    Text(
        "Discovered devices",
        style = AuroraType.caption,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )

    Spacer(Modifier.height(AuroraSpacing.xs.dp))

    if (state.discoveredDevices.isEmpty()) {
        Text(
            "Looking on the local network… make sure the device is awake.",
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        return
    }

    state.discoveredDevices.forEach { device ->
        val isSelected = device.id == state.pixelClockSelectedDeviceId
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(vertical = AuroraSpacing.xs.dp),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(device.name, style = AuroraType.body)
                Text(
                    "${device.host}:${device.port}",
                    style = AuroraType.tiny,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            AuroraSecondaryButton(
                onClick = { SmartHubBridgeClientPixelClockActions.selectDevice(device.id.takeIf { !isSelected }) },
                enabled = !state.actionInFlight,
            ) {
                Text(if (isSelected) "Disconnect" else "Use")
            }
        }
    }
}

@Composable
internal fun PixelClockRepairActions(state: SmartHubSnapshot) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
        AuroraSecondaryButton(
            onClick = SmartHubBridgeClientPixelClockActions::repairPixelClock,
            enabled = !state.actionInFlight && state.bridgeIsLive,
            modifier = Modifier.weight(1f),
        ) {
            Icon(Icons.Filled.Settings, contentDescription = null)
            Text("Make work")
        }
        AuroraSecondaryButton(
            onClick = SmartHubBridgeClientPixelClockActions::pushPixelClockNow,
            enabled = !state.actionInFlight && state.bridgeIsLive,
            modifier = Modifier.weight(1f),
        ) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null)
            Text("Push now")
        }
    }
}

@Composable
internal fun PixelClockBrightnessSlider(state: SmartHubSnapshot) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Filled.Brightness6,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(AuroraSpacing.sm.dp))
        Text(
            "Brightness ${(state.pixelClockBrightness * 100).toInt()}%",
            style = AuroraType.caption,
        )
    }
    Slider(
        value = state.pixelClockBrightness,
        onValueChange = ::smartHubPreviewPixelClockBrightness,
        onValueChangeFinished = SmartHubBridgeClientPixelClockActions::commitPixelClockConfig,
        steps = 9,
        enabled = !state.actionInFlight,
    )
}

@Composable
internal fun PixelClockTimeFormatRow(state: SmartHubSnapshot) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Filled.Schedule,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(AuroraSpacing.sm.dp))
        Text("Time format", style = AuroraType.caption, modifier = Modifier.weight(1f))
        AuroraSecondaryButton(
            onClick = {
                val next =
                    when (state.pixelClockTimeFormat) {
                        PixelClockTimeFormat.HOUR_12 -> PixelClockTimeFormat.HOUR_24
                        PixelClockTimeFormat.HOUR_24 -> PixelClockTimeFormat.HOUR_12
                    }
                SmartHubBridgeClientPixelClockActions.setTimeFormat(next)
            },
            enabled = !state.actionInFlight,
        ) {
            Text(
                when (state.pixelClockTimeFormat) {
                    PixelClockTimeFormat.HOUR_12 -> "12-hour"
                    PixelClockTimeFormat.HOUR_24 -> "24-hour"
                },
            )
        }
    }
}

@Composable
internal fun PixelClockRefreshSlider(state: SmartHubSnapshot) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Filled.Refresh,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(AuroraSpacing.sm.dp))
        Text(
            "Refresh every ${state.pixelClockRefreshSeconds}s",
            style = AuroraType.caption,
        )
    }
    Slider(
        value = state.pixelClockRefreshSeconds.toFloat(),
        onValueChange = { smartHubPreviewPixelClockRefreshSeconds(it.toInt()) },
        onValueChangeFinished = SmartHubBridgeClientPixelClockActions::commitPixelClockConfig,
        valueRange = 5f..120f,
        steps = 22,
        enabled = !state.actionInFlight,
    )
}

@Composable
internal fun PixelClockEnableToggle(state: SmartHubSnapshot) {
    AuroraSettingsToggle(
        icon = Icons.Filled.Tv,
        label = "Enable Pixel Clock",
        subtitle = "Save the AWTRIX device to the same Mac bridge settings iOS uses",
        checked = state.pixelClockEnabled,
        onCheckedChange = { SmartHubBridgeClientPixelClockActions.setPixelClockEnabled(it) },
        enabled = !state.actionInFlight,
    )
}

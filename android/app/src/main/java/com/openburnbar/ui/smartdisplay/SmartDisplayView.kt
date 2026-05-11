package com.openburnbar.ui.smartdisplay

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSecondaryButton
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Native Android port of iOS Views/SmartHub. Same information architecture
 * (Pixel Clock + HomeAssistant), Aurora glass treatment everywhere.
 */
@Composable
fun SmartDisplayView(
    onBack: (() -> Unit)? = null
) {
    val context = LocalContext.current
    val state by SmartHubBridgeClient.state.collectAsState()
    val isDark = isSystemInDarkTheme()

    DisposableEffect(Unit) {
        SmartHubBridgeClient.startDiscovery(context)
        onDispose { SmartHubBridgeClient.stopDiscovery() }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp)
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

        // Header
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back"
                    )
                }
            }
            Text("Smart Displays", style = AuroraType.displayLarge,
                 color = MaterialTheme.colorScheme.onSurface)
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        PixelClockCard(state = state)

        Spacer(Modifier.height(AuroraSpacing.lg.dp))

        HomeAssistantCard(state = state)

        Spacer(Modifier.height(AuroraSpacing.xxxl.dp))
    }
}

@Composable
private fun PixelClockCard(state: SmartHubSnapshot) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(Icons.Filled.Tv, contentDescription = null, tint = AuroraColors.ember)
            Text("Pixel Clock", style = AuroraType.title, modifier = Modifier.weight(1f))
            AuroraBadge(
                text = if (state.pixelClockSelectedDeviceId != null) "Connected"
                       else "No device",
                tone = if (state.pixelClockSelectedDeviceId != null)
                    AuroraBadgeTone.Success else AuroraBadgeTone.Warning
            )
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        AuroraSettingsToggle(
            icon = Icons.Filled.Tv,
            label = "Enable Pixel Clock",
            subtitle = "Stream BurnBar metrics to your nightstand",
            checked = state.pixelClockEnabled,
            onCheckedChange = { SmartHubBridgeClient.setPixelClockEnabled(it) }
        )

        Spacer(Modifier.height(AuroraSpacing.sm.dp))

        Text("Discovered devices", style = AuroraType.caption,
             color = MaterialTheme.colorScheme.onSurfaceVariant)

        Spacer(Modifier.height(AuroraSpacing.xs.dp))

        if (state.discoveredDevices.isEmpty()) {
            Text(
                "Looking on the local network… make sure the device is awake.",
                style = AuroraType.body,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            state.discoveredDevices.forEach { device ->
                val isSelected = device.id == state.pixelClockSelectedDeviceId
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = AuroraSpacing.xs.dp)
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(device.name, style = AuroraType.body)
                        Text("${device.host}:${device.port}", style = AuroraType.tiny,
                             color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    AuroraSecondaryButton(
                        onClick = { SmartHubBridgeClient.selectDevice(device.id.takeIf { !isSelected }) }
                    ) {
                        Text(if (isSelected) "Disconnect" else "Use")
                    }
                }
            }
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Brightness6, contentDescription = null,
                 tint = MaterialTheme.colorScheme.onSurfaceVariant,
                 modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(AuroraSpacing.sm.dp))
            Text("Brightness ${(state.pixelClockBrightness * 100).toInt()}%",
                 style = AuroraType.caption)
        }
        Slider(
            value = state.pixelClockBrightness,
            onValueChange = SmartHubBridgeClient::setBrightness,
            steps = 9
        )

        Spacer(Modifier.height(AuroraSpacing.sm.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Schedule, contentDescription = null,
                 tint = MaterialTheme.colorScheme.onSurfaceVariant,
                 modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(AuroraSpacing.sm.dp))
            Text("Time format", style = AuroraType.caption,
                 modifier = Modifier.weight(1f))
            AuroraSecondaryButton(
                onClick = {
                    val next = when (state.pixelClockTimeFormat) {
                        PixelClockTimeFormat.HOUR_12 -> PixelClockTimeFormat.HOUR_24
                        PixelClockTimeFormat.HOUR_24 -> PixelClockTimeFormat.HOUR_12
                    }
                    SmartHubBridgeClient.setTimeFormat(next)
                }
            ) {
                Text(
                    when (state.pixelClockTimeFormat) {
                        PixelClockTimeFormat.HOUR_12 -> "12-hour"
                        PixelClockTimeFormat.HOUR_24 -> "24-hour"
                    }
                )
            }
        }

        Spacer(Modifier.height(AuroraSpacing.sm.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Refresh, contentDescription = null,
                 tint = MaterialTheme.colorScheme.onSurfaceVariant,
                 modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(AuroraSpacing.sm.dp))
            Text("Refresh every ${state.pixelClockRefreshSeconds}s",
                 style = AuroraType.caption)
        }
        Slider(
            value = state.pixelClockRefreshSeconds.toFloat(),
            onValueChange = { SmartHubBridgeClient.setRefreshSeconds(it.toInt()) },
            valueRange = 5f..120f,
            steps = 22
        )
    }
}

@Composable
private fun HomeAssistantCard(state: SmartHubSnapshot) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(Icons.Filled.Home, contentDescription = null,
                 tint = AuroraColors.whimsy)
            Spacer(Modifier.width(AuroraSpacing.sm.dp))
            Text("Home Assistant", style = AuroraType.title,
                 modifier = Modifier.weight(1f))
            AuroraBadge(
                text = if (state.homeAssistantConnected) "Online" else "Offline",
                tone = if (state.homeAssistantConnected) AuroraBadgeTone.Success
                       else AuroraBadgeTone.Neutral
            )
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        Text(
            text = if (state.homeAssistantConnected) {
                val ago = state.homeAssistantLastSyncMs?.let {
                    val sec = (System.currentTimeMillis() - it) / 1000
                    when {
                        sec < 60 -> "${sec}s ago"
                        sec < 3600 -> "${sec / 60}m ago"
                        else -> "${sec / 3600}h ago"
                    }
                } ?: "—"
                "Last sync $ago — BurnBar can publish cost sensors to your dashboard."
            } else {
                "Connect Home Assistant to expose BurnBar cost metrics and quota alerts as sensors and automations."
            },
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        AuroraSecondaryButton(
            onClick = {
                SmartHubBridgeClient.setHomeAssistantConnected(!state.homeAssistantConnected)
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(if (state.homeAssistantConnected) "Disconnect" else "Connect")
        }
    }
}

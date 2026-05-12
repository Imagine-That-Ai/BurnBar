package com.openburnbar.ui.smartdisplay

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
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
 * (Google smart displays + Pixel Clock), Aurora glass treatment everywhere.
 */
@Composable
fun SmartDisplayView(
    onBack: (() -> Unit)? = null
) {
    val context = LocalContext.current
    val state by SmartHubBridgeClient.state.collectAsState()
    val isDark = isSystemInDarkTheme()

    DisposableEffect(Unit) {
        SmartHubBridgeClient.start(context)
        onDispose { SmartHubBridgeClient.stop() }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp)
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

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
                 color = MaterialTheme.colorScheme.onSurface,
                 modifier = Modifier.weight(1f))
            IconButton(onClick = SmartHubBridgeClient::refresh) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh smart displays")
            }
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        StatusFeedback(state)

        NestHubCard(state = state)

        Spacer(Modifier.height(AuroraSpacing.lg.dp))

        PixelClockCard(state = state)

        Spacer(Modifier.height(AuroraSpacing.xxxl.dp))
    }
}

@Composable
private fun StatusFeedback(state: SmartHubSnapshot) {
    val message = state.actionError ?: state.actionMessage ?: return
    val tone = if (state.actionError != null) AuroraBadgeTone.Error else AuroraBadgeTone.Info
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
        ) {
            AuroraBadge(text = if (state.actionError != null) "Needs attention" else "Working", tone = tone)
            Text(message, style = AuroraType.body, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    Spacer(Modifier.height(AuroraSpacing.md.dp))
}

@Composable
private fun NestHubCard(state: SmartHubSnapshot) {
    val bridgeReady = state.bridgeEnabled && state.bridgeIsLive && !state.refreshUrl.isNullOrBlank()
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(Icons.Filled.Devices, contentDescription = null, tint = AuroraColors.whimsy)
            Text("Google Smart Display", style = AuroraType.title, modifier = Modifier.weight(1f))
            AuroraBadge(
                text = when {
                    state.isLoading -> "Loading"
                    bridgeReady -> "Bridge ready"
                    state.bridgeEnabled && !state.bridgeIsLive -> "Mac offline"
                    state.bridgeEnabled -> "No refresh URL"
                    else -> "No Mac bridge"
                },
                tone = when {
                    bridgeReady -> AuroraBadgeTone.Success
                    state.bridgeEnabled && !state.bridgeIsLive -> AuroraBadgeTone.Warning
                    state.bridgeEnabled -> AuroraBadgeTone.Warning
                    else -> AuroraBadgeTone.Neutral
                }
            )
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        Text(
            text = bridgeSummary(state),
            style = AuroraType.body,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            AuroraSecondaryButton(
                onClick = SmartHubBridgeClient::refreshNestHub,
                enabled = !state.actionInFlight && bridgeReady,
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.Refresh, contentDescription = null)
                Text("Refresh display")
            }
            AuroraSecondaryButton(
                onClick = SmartHubBridgeClient::repairAllSmartDisplays,
                enabled = !state.actionInFlight && state.bridgeIsLive,
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.Settings, contentDescription = null)
                Text("Repair connection")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                AuroraSecondaryButton(
                    onClick = SmartHubBridgeClient::identifyNestHub,
                    enabled = !state.actionInFlight && state.bridgeIsLive,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = null)
                    Text("Identify")
                }
                AuroraSecondaryButton(
                    onClick = SmartHubBridgeClient::stopNestHub,
                    enabled = !state.actionInFlight && state.bridgeIsLive,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Filled.Stop, contentDescription = null)
                    Text("Stop")
                }
            }
        }

        Spacer(Modifier.height(AuroraSpacing.lg.dp))

        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Available Google displays", style = AuroraType.caption,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f))
            AuroraSecondaryButton(
                onClick = SmartHubBridgeClient::runCastDiscovery,
                enabled = !state.actionInFlight && state.bridgeIsLive,
                loading = state.isDiscoveringCastDevices
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
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            state.castDevices.forEach { device ->
                CastDeviceRow(device = device, selected = device.id == state.selectedCastDeviceId, busy = state.actionInFlight)
            }
        }
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
            subtitle = "Save the AWTRIX device to the same Mac bridge settings iOS uses",
            checked = state.pixelClockEnabled,
            onCheckedChange = { SmartHubBridgeClient.setPixelClockEnabled(it) },
            enabled = !state.actionInFlight
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
                        onClick = { SmartHubBridgeClient.selectDevice(device.id.takeIf { !isSelected }) },
                        enabled = !state.actionInFlight
                    ) {
                        Text(if (isSelected) "Disconnect" else "Use")
                    }
                }
            }
        }

        Spacer(Modifier.height(AuroraSpacing.md.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            AuroraSecondaryButton(
                onClick = SmartHubBridgeClient::repairPixelClock,
                enabled = !state.actionInFlight && state.bridgeIsLive,
                modifier = Modifier.weight(1f)
            ) {
                Icon(Icons.Filled.Settings, contentDescription = null)
                Text("Make work")
            }
            AuroraSecondaryButton(
                onClick = SmartHubBridgeClient::pushPixelClockNow,
                enabled = !state.actionInFlight && state.bridgeIsLive,
                modifier = Modifier.weight(1f)
            ) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null)
                Text("Push now")
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
            onValueChange = SmartHubBridgeClient::previewBrightness,
            onValueChangeFinished = SmartHubBridgeClient::commitPixelClockConfig,
            steps = 9,
            enabled = !state.actionInFlight
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
                },
                enabled = !state.actionInFlight
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
            onValueChange = { SmartHubBridgeClient.previewRefreshSeconds(it.toInt()) },
            onValueChangeFinished = SmartHubBridgeClient::commitPixelClockConfig,
            valueRange = 5f..120f,
            steps = 22,
            enabled = !state.actionInFlight
        )
    }
}

@Composable
private fun CastDeviceRow(device: CastDisplayDevice, selected: Boolean, busy: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = AuroraSpacing.xs.dp)
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
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        AuroraSecondaryButton(
            onClick = { SmartHubBridgeClient.saveCastSelection(device) },
            enabled = !busy
        ) {
            Icon(Icons.Filled.Save, contentDescription = null)
            Text("Save")
        }
        Spacer(Modifier.width(AuroraSpacing.xs.dp))
        AuroraSecondaryButton(
            onClick = { SmartHubBridgeClient.testCast(device) },
            enabled = !busy
        ) {
            Icon(Icons.Filled.PlayArrow, contentDescription = null)
            Text("Cast")
        }
    }
}

private fun bridgeSummary(state: SmartHubSnapshot): String {
    val source = state.bridgeSourceDeviceName?.takeIf { it.isNotBlank() } ?: "No Mac has published a bridge yet"
    val published = state.bridgePublishedAtMs?.let { " • updated ${relativeAge(it)}" }.orEmpty()
    val email = state.signedInEmail?.let { "\nAccount: $it" }.orEmpty()
    val bridge = when {
        state.refreshUrl != null && state.bridgeIsLive -> "Bridge: ready"
        state.refreshUrl != null -> state.bridgeFreshnessMessage
        state.bridgeEnabled -> "Bridge: enabled but missing refresh URL"
        else -> "Bridge: not active"
    }
    return "$source$published\n$bridge$email"
}

private fun relativeAge(timestampMs: Long): String {
    val seconds = ((System.currentTimeMillis() - timestampMs) / 1000).coerceAtLeast(0)
    return when {
        seconds < 60 -> "${seconds}s ago"
        seconds < 3600 -> "${seconds / 60}m ago"
        seconds < 86_400 -> "${seconds / 3600}h ago"
        else -> "${seconds / 86_400}d ago"
    }
}

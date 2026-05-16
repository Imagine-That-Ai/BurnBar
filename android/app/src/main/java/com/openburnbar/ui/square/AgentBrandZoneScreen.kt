package com.openburnbar.ui.square

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddComment
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.openburnbar.data.assistants.CLIAgentMissionDispatcher
import com.openburnbar.data.assistants.DispatchException
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentAvailability
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.AgentSubscriptionTopic
import com.openburnbar.data.square.AgentSubscriptionTopicStore
import com.openburnbar.data.square.SubscriptionCadence
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

// MARK: - Agent Brand Zone Screen (Android parity, Hermes Square §6.3)
//
// Per-agent "brand zone" — hero with subtle parallax (accelerometer-driven,
// gated by reduce-motion), quick actions, capability pills, last-7-days
// strip, persona slots, dispatch / forward / subscribe sheets. Mirrors
// `AgentBrandZoneView.swift`.

@Composable
fun AgentBrandZoneScreen(
    identity: AgentIdentity,
    registry: AgentIdentityRegistry,
    missionHost: MobileMissionConsoleHost,
    onOpenRuntimeThread: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val subscriptionStore = remember(context) { AgentSubscriptionTopicStore.shared(context) }
    val topics by subscriptionStore.topics.collectAsStateWithLifecycle()
    val activeTopic = remember(topics, identity) { topics.firstOrNull { it.agentURI == identity.id } }

    val tilt = rememberAccelerometerTilt()
    val accent = remember(identity) { hexColor(identity.paletteHex) }
    val scrollState = rememberScrollState()

    var showDispatch by remember { mutableStateOf(false) }
    var showForward by remember { mutableStateOf(false) }
    var showSubscribe by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf<String?>(null) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(horizontal = 18.dp, vertical = 14.dp)
    ) {
        BrandHero(identity = identity, accent = accent, tilt = tilt)
        Spacer(modifier = Modifier.height(20.dp))
        QuickActions(
            accent = accent,
            onNewThread = {
                if (onOpenRuntimeThread != null) onOpenRuntimeThread()
                else showDispatch = true
            },
            onDispatch = { showDispatch = true },
            onForward = { showForward = true },
            onSubscribe = { showSubscribe = true }
        )
        Spacer(modifier = Modifier.height(20.dp))
        CapabilitiesSection(identity = identity, accent = accent)
        Spacer(modifier = Modifier.height(20.dp))
        LastSevenDaysSection(identity = identity)
        Spacer(modifier = Modifier.height(20.dp))
        PersonasSection(identity = identity, accent = accent)
        Spacer(modifier = Modifier.height(20.dp))
        AboutSection(identity = identity)
        Spacer(modifier = Modifier.height(20.dp))
        statusMessage?.let { msg ->
            Text(
                msg,
                fontSize = 12.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Spacer(modifier = Modifier.height(40.dp))
    }

    if (showDispatch) {
        AgentBrandDispatchSheet(
            identity = identity,
            missionHost = missionHost,
            onDismiss = { showDispatch = false },
            onResult = { msg ->
                statusMessage = msg
                showDispatch = false
            }
        )
    }

    if (showForward) {
        AgentBrandForwardSheet(
            source = identity,
            registry = registry,
            onDismiss = { showForward = false },
            onForward = { destination, note ->
                showForward = false
                statusMessage = "Forwarded to ${destination.displayName}."
            }
        )
    }

    if (showSubscribe) {
        AgentBrandSubscribeSheet(
            identity = identity,
            existingTopic = activeTopic,
            onDismiss = { showSubscribe = false },
            onAction = { action ->
                statusMessage = when (action) {
                    is SubscribeAction.Subscribe -> {
                        subscriptionStore.subscribe(identity, action.cadence)
                        "Subscribed to ${identity.displayName} (${action.cadence.displayLabel.lowercase()})."
                    }
                    SubscribeAction.Unsubscribe -> {
                        subscriptionStore.unsubscribe(identity.id)
                        "Unsubscribed from ${identity.displayName}."
                    }
                    is SubscribeAction.SetMuted -> {
                        subscriptionStore.setMuted(identity.id, action.muted)
                        if (action.muted) "Muted ${identity.displayName}." else "Unmuted ${identity.displayName}."
                    }
                }
                showSubscribe = false
            }
        )
    }
}

@Composable
private fun BrandHero(
    identity: AgentIdentity,
    accent: Color,
    tilt: TiltState,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val xOffset = if (reduceMotion) 0f else tilt.x * 10f
    val yOffset = if (reduceMotion) 0f else tilt.y * 10f
    val backdropX = if (reduceMotion) 0f else -tilt.x * 6f
    val backdropY = if (reduceMotion) 0f else -tilt.y * 6f
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(92.dp)
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(92.dp)
                    .offset { IntOffset(backdropX.roundToInt(), backdropY.roundToInt()) }
                    .background(
                        Brush.radialGradient(
                            colors = listOf(
                                accent.copy(alpha = 0.32f),
                                accent.copy(alpha = 0.06f),
                                Color.Transparent
                            )
                        ),
                        shape = RoundedCornerShape(50)
                    )
            ) {}
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(64.dp)
                    .offset { IntOffset(xOffset.roundToInt(), yOffset.roundToInt()) }
                    .clip(RoundedCornerShape(50))
                    .background(accent)
            ) {
                Text(
                    identity.glyph,
                    color = Color.White,
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold
                )
            }
        }
        Spacer(modifier = Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    identity.displayName,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.width(6.dp))
                Surface(
                    shape = RoundedCornerShape(999.dp),
                    color = accent.copy(alpha = 0.18f)
                ) {
                    Text(
                        identity.tier.displayLabel,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = accent,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
            }
            Spacer(modifier = Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(7.dp)
                        .clip(RoundedCornerShape(50))
                        .background(availabilityHexColor(identity.availability))
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    identity.availability.displayLabel,
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            identity.tagline?.let { tagline ->
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    tagline,
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }
    }
}

@Composable
private fun QuickActions(
    accent: Color,
    onNewThread: () -> Unit,
    onDispatch: () -> Unit,
    onForward: () -> Unit,
    onSubscribe: () -> Unit
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuickAction(label = "New thread", icon = Icons.Filled.AddComment, accent = accent, onClick = onNewThread, modifier = Modifier.weight(1f))
        QuickAction(label = "Dispatch", icon = Icons.Filled.Send, accent = accent, onClick = onDispatch, modifier = Modifier.weight(1f))
        QuickAction(label = "Forward", icon = Icons.Filled.Share, accent = accent, onClick = onForward, modifier = Modifier.weight(1f))
        QuickAction(label = "Subscribe", icon = Icons.Filled.NotificationsActive, accent = accent, onClick = onSubscribe, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun QuickAction(
    label: String,
    icon: ImageVector,
    accent: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 10.dp)
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = accent, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                label,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}

@Composable
private fun CapabilitiesSection(identity: AgentIdentity, accent: Color) {
    Column {
        Text(
            "Capabilities",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(6.dp))
        val pills = identity.capabilities.displayPills
        if (pills.isEmpty()) {
            Text(
                "No declared capabilities yet.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            // Compose lacks FlowRow in foundation 1.7 — wrap rows of 3.
            pills.chunked(3).forEach { row ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.padding(bottom = 6.dp)
                ) {
                    row.forEach { pill ->
                        Surface(
                            shape = RoundedCornerShape(999.dp),
                            color = accent.copy(alpha = 0.14f)
                        ) {
                            Text(
                                pill,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = accent,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LastSevenDaysSection(identity: AgentIdentity) {
    Column {
        Text(
            "Last 7 days",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(6.dp))
        val stats = identity.lastSevenDays
        if (stats == null) {
            Text(
                "No telemetry yet — start a thread or dispatch a mission.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                StatBlock(label = "Threads", value = "${stats.threadCount}")
                StatBlock(label = "Missions", value = "${stats.missionCount}")
                StatBlock(label = "Burn", value = "$${"%.2f".format(stats.burnUSD)}")
                StatBlock(label = "Success", value = "${(stats.successRate * 100).roundToInt()}%")
            }
        }
    }
}

@Composable
private fun StatBlock(label: String, value: String) {
    Column {
        Text(
            label,
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            value,
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
private fun PersonasSection(identity: AgentIdentity, accent: Color) {
    Column {
        Text(
            "Personas",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(6.dp))
        if (identity.personas.isEmpty()) {
            Text(
                "Default persona only.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            identity.personas.forEach { persona ->
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 6.dp)
                ) {
                    Column(modifier = Modifier.padding(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                persona.name,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            if (persona.isDefault) {
                                Spacer(modifier = Modifier.width(6.dp))
                                Surface(
                                    shape = RoundedCornerShape(999.dp),
                                    color = accent.copy(alpha = 0.16f)
                                ) {
                                    Text(
                                        "default",
                                        fontSize = 9.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = accent,
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                                    )
                                }
                            }
                        }
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(
                            persona.description,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AboutSection(identity: AgentIdentity) {
    Column {
        Text(
            "About",
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.height(6.dp))
        AboutRow(label = "URI", value = identity.id)
        AboutRow(label = "Install", value = identity.installSource.displayLabel)
        AboutRow(label = "Transport", value = identity.dispatchTransport.displayLabel)
        identity.lastRefreshedAtEpoch?.let {
            AboutRow(label = "Last refreshed", value = relativeTime(it))
        }
    }
}

@Composable
private fun AboutRow(label: String, value: String) {
    Row(modifier = Modifier.padding(vertical = 1.dp)) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(110.dp)
        )
        Text(
            value,
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

// MARK: - Accelerometer tilt

private data class TiltState(val x: Float, val y: Float)

@Composable
private fun rememberAccelerometerTilt(): TiltState {
    val context = LocalContext.current
    var tilt by remember { mutableStateOf(TiltState(0f, 0f)) }
    val reduceMotion = LocalAuroraReduceMotion.current
    DisposableEffect(reduceMotion) {
        if (reduceMotion) {
            tilt = TiltState(0f, 0f)
            return@DisposableEffect onDispose { }
        }
        val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            ?: return@DisposableEffect onDispose { }
        val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            ?: return@DisposableEffect onDispose { }
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                // Map accel values (-10..10 m/s² roughly) into -1..1.
                val nx = (event.values[0] / 9.81f).coerceIn(-1f, 1f)
                val ny = (-event.values[1] / 9.81f).coerceIn(-1f, 1f)
                tilt = TiltState(nx, ny)
            }
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        sensorManager.registerListener(listener, accelerometer, SensorManager.SENSOR_DELAY_UI)
        onDispose {
            sensorManager.unregisterListener(listener)
        }
    }
    return tilt
}

private fun availabilityHexColor(availability: AgentAvailability): Color = when (availability) {
    AgentAvailability.ONLINE -> AuroraColors.success
    AgentAvailability.DEGRADED -> AuroraColors.warning
    AgentAvailability.OFFLINE -> AuroraColors.error
    AgentAvailability.UNKNOWN -> AuroraColors.lightTextMuted
}

// `relativeTime` lives in HermesSquareScreen.kt; reused via the same
// `com.openburnbar.ui.square` package.

// MARK: - Subscribe action shape (shared with AgentBrandSubscribeSheet)

sealed class SubscribeAction {
    data class Subscribe(val cadence: SubscriptionCadence) : SubscribeAction()
    data class SetMuted(val muted: Boolean) : SubscribeAction()
    object Unsubscribe : SubscribeAction()
}

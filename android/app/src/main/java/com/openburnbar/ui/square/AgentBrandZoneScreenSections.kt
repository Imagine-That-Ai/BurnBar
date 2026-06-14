// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AddComment
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.openburnbar.data.missions.MobileMissionConsoleHost
import com.openburnbar.data.square.AgentAvailability
import com.openburnbar.data.square.AgentIdentity
import com.openburnbar.data.square.AgentIdentityRegistry
import com.openburnbar.data.square.AgentSubscriptionTopicStore
import com.openburnbar.data.square.AgentSubscriptionUnsubscribeResult
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import com.openburnbar.util.Formatting
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

@Composable
internal fun AgentBrandZoneScreenLayout(
    identity: AgentIdentity,
    registry: AgentIdentityRegistry,
    missionHost: MobileMissionConsoleHost,
    onOpenRuntimeThread: (() -> Unit)?,
    modifier: Modifier = Modifier,
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
    val coroutineScope = rememberCoroutineScope()

    AgentBrandZoneMainColumn(
        state =
        AgentBrandZoneMainColumnState(
            identity = identity,
            accent = accent,
            tilt = tilt,
            scrollState = scrollState,
            statusMessage = statusMessage,
            modifier = modifier,
        ),
        actions =
        AgentBrandZoneMainColumnActions(
            onComposeMission = { if (onOpenRuntimeThread != null) onOpenRuntimeThread() else showDispatch = true },
            onDispatch = { showDispatch = true },
            onForward = { showForward = true },
            onSubscribe = { showSubscribe = true },
        ),
    )
    AgentBrandZoneOverlays(
        context =
        AgentBrandZoneOverlayContext(
            identity = identity,
            registry = registry,
            missionHost = missionHost,
            subscriptionStore = subscriptionStore,
            activeTopic = activeTopic,
            coroutineScope = coroutineScope,
        ),
        overlayState = AgentBrandZoneOverlayState(showDispatch, showForward, showSubscribe),
        overlayCallbacks =
        AgentBrandZoneOverlayCallbacks(
            onDismissDispatch = { showDispatch = false },
            onDismissForward = { showForward = false },
            onDismissSubscribe = { showSubscribe = false },
            onDispatchResult = { msg ->
                statusMessage = msg
                showDispatch = false
            },
            onForwardResult = { msg ->
                statusMessage = msg
                showForward = false
            },
            onSubscribeResult = { msg ->
                statusMessage = msg
                showSubscribe = false
            },
        ),
    )
}

@Composable
internal fun BrandHero(identity: AgentIdentity, accent: Color, tilt: TiltState) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        BrandHeroAvatar(identity = identity, accent = accent, tilt = tilt)
        Spacer(modifier = Modifier.width(14.dp))
        BrandHeroDetails(identity = identity, accent = accent)
    }
}

@Composable
private fun BrandHeroAvatar(identity: AgentIdentity, accent: Color, tilt: TiltState) {
    val reduceMotion = LocalAuroraReduceMotion.current
    val xOffset = if (reduceMotion) 0f else tilt.x * 10f
    val yOffset = if (reduceMotion) 0f else tilt.y * 10f
    val backdropX = if (reduceMotion) 0f else -tilt.x * 6f
    val backdropY = if (reduceMotion) 0f else -tilt.y * 6f
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(92.dp)) {
        Box(
            contentAlignment = Alignment.Center,
            modifier =
            Modifier
                .size(92.dp)
                .offset { IntOffset(backdropX.roundToInt(), backdropY.roundToInt()) }
                .background(
                    Brush.radialGradient(
                        colors =
                        listOf(
                            accent.copy(alpha = 0.32f),
                            accent.copy(alpha = 0.06f),
                            Color.Transparent,
                        ),
                    ),
                    shape = RoundedCornerShape(50),
                ),
        ) {}
        Box(
            contentAlignment = Alignment.Center,
            modifier =
            Modifier
                .size(64.dp)
                .offset { IntOffset(xOffset.roundToInt(), yOffset.roundToInt()) }
                .clip(RoundedCornerShape(50))
                .background(accent),
        ) {
            Text(identity.glyph, color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun RowScope.BrandHeroDetails(identity: AgentIdentity, accent: Color) {
    Column(modifier = Modifier.weight(1f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                identity.displayName,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(modifier = Modifier.width(6.dp))
            Surface(shape = RoundedCornerShape(999.dp), color = accent.copy(alpha = 0.18f)) {
                Text(
                    identity.tier.displayLabel,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = accent,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
        Spacer(modifier = Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier =
                Modifier
                    .size(7.dp)
                    .clip(RoundedCornerShape(50))
                    .background(availabilityHexColor(identity.availability)),
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                identity.availability.displayLabel,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        identity.tagline?.let { tagline ->
            Spacer(modifier = Modifier.height(4.dp))
            Text(tagline, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
internal fun QuickActions(accent: Color, onNewThread: () -> Unit, onDispatch: () -> Unit, onForward: () -> Unit, onSubscribe: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        QuickAction(label = "New thread", icon = Icons.Filled.AddComment, accent = accent, onClick = onNewThread, modifier = Modifier.weight(1f))
        QuickAction(label = "Dispatch", icon = Icons.AutoMirrored.Filled.Send, accent = accent, onClick = onDispatch, modifier = Modifier.weight(1f))
        QuickAction(label = "Forward", icon = Icons.Filled.Share, accent = accent, onClick = onForward, modifier = Modifier.weight(1f))
        QuickAction(label = "Subscribe", icon = Icons.Filled.NotificationsActive, accent = accent, onClick = onSubscribe, modifier = Modifier.weight(1f))
    }
}

@Composable
internal fun QuickAction(label: String, icon: ImageVector, accent: Color, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
        modifier = modifier.clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = accent, modifier = Modifier.size(18.dp))
            Spacer(modifier = Modifier.height(4.dp))
            Text(label, fontSize = 10.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
        }
    }
}

@Composable
internal fun CapabilitiesSection(identity: AgentIdentity, accent: Color) {
    Column {
        Text("Capabilities", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.height(6.dp))
        val pills = identity.capabilities.displayPills
        if (pills.isEmpty()) {
            Text("No declared capabilities yet.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            pills.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(bottom = 6.dp)) {
                    row.forEach { pill ->
                        Surface(shape = RoundedCornerShape(999.dp), color = accent.copy(alpha = 0.14f)) {
                            Text(
                                pill,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                color = accent,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun LastSevenDaysSection(identity: AgentIdentity) {
    Column {
        Text("Last 7 days", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.height(6.dp))
        val stats = identity.lastSevenDays
        if (stats == null) {
            Text(
                "No telemetry yet — start a thread or dispatch a mission.",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                StatBlock(label = "Threads", value = "${stats.threadCount}")
                StatBlock(label = "Missions", value = "${stats.missionCount}")
                StatBlock(label = "Burn", value = Formatting.formatCurrency(stats.burnUSD))
                StatBlock(label = "Success", value = "${(stats.successRate * 100).roundToInt()}%")
            }
        }
    }
}

@Composable
internal fun StatBlock(label: String, value: String) {
    Column {
        Text(label, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
internal fun PersonasSection(identity: AgentIdentity, accent: Color) {
    Column {
        Text("Personas", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.height(6.dp))
        if (identity.personas.isEmpty()) {
            Text("Default persona only.", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            identity.personas.forEach { persona ->
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.5f),
                    modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp),
                ) {
                    Column(modifier = Modifier.padding(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                persona.name,
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            if (persona.isDefault) {
                                Spacer(modifier = Modifier.width(6.dp))
                                Surface(shape = RoundedCornerShape(999.dp), color = accent.copy(alpha = 0.16f)) {
                                    Text(
                                        "default",
                                        fontSize = 9.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = accent,
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
                                    )
                                }
                            }
                        }
                        Spacer(modifier = Modifier.height(2.dp))
                        Text(
                            persona.description,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun AboutSection(identity: AgentIdentity) {
    Column {
        Text("About", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(modifier = Modifier.height(6.dp))
        AboutRow(label = "URI", value = identity.id)
        AboutRow(label = "Install", value = identity.installSource.displayLabel)
        AboutRow(label = "Transport", value = identity.dispatchTransport.displayLabel)
        identity.lastRefreshedAtEpoch?.let { AboutRow(label = "Last refreshed", value = relativeTime(it)) }
    }
}

@Composable
internal fun AboutRow(label: String, value: String) {
    Row(modifier = Modifier.padding(vertical = 1.dp)) {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(110.dp),
        )
        Text(value, fontSize = 11.sp, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
internal fun rememberAccelerometerTilt(): TiltState {
    val context = LocalContext.current
    var tilt by remember { mutableStateOf(TiltState(0f, 0f)) }
    val reduceMotion = LocalAuroraReduceMotion.current
    DisposableEffect(reduceMotion) {
        if (reduceMotion) {
            tilt = TiltState(0f, 0f)
            return@DisposableEffect onDispose { }
        }
        val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager ?: return@DisposableEffect onDispose { }
        val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) ?: return@DisposableEffect onDispose { }
        val listener =
            object : SensorEventListener {
                override fun onSensorChanged(event: SensorEvent) {
                    val nx = (event.values[0] / 9.81f).coerceIn(-1f, 1f)
                    val ny = (-event.values[1] / 9.81f).coerceIn(-1f, 1f)
                    tilt = TiltState(nx, ny)
                }

                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
            }
        sensorManager.registerListener(listener, accelerometer, SensorManager.SENSOR_DELAY_UI)
        onDispose { sensorManager.unregisterListener(listener) }
    }
    return tilt
}

@Composable
internal fun AgentBrandZoneMainColumn(state: AgentBrandZoneMainColumnState, actions: AgentBrandZoneMainColumnActions) {
    Column(
        modifier =
        state.modifier
            .fillMaxSize()
            .verticalScroll(state.scrollState)
            .padding(horizontal = 18.dp, vertical = 14.dp),
    ) {
        BrandHero(identity = state.identity, accent = state.accent, tilt = state.tilt)
        Spacer(modifier = Modifier.height(20.dp))
        QuickActions(
            accent = state.accent,
            onNewThread = actions.onComposeMission,
            onDispatch = actions.onDispatch,
            onForward = actions.onForward,
            onSubscribe = actions.onSubscribe,
        )
        Spacer(modifier = Modifier.height(20.dp))
        CapabilitiesSection(identity = state.identity, accent = state.accent)
        Spacer(modifier = Modifier.height(20.dp))
        LastSevenDaysSection(identity = state.identity)
        Spacer(modifier = Modifier.height(20.dp))
        PersonasSection(identity = state.identity, accent = state.accent)
        Spacer(modifier = Modifier.height(20.dp))
        AboutSection(identity = state.identity)
        Spacer(modifier = Modifier.height(20.dp))
        state.statusMessage?.let { msg ->
            Text(msg, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(modifier = Modifier.height(40.dp))
    }
}

internal data class AgentBrandZoneMainColumnState(
    val identity: AgentIdentity,
    val accent: Color,
    val tilt: TiltState,
    val scrollState: ScrollState,
    val statusMessage: String?,
    val modifier: Modifier = Modifier,
)

@Composable
internal fun AgentBrandZoneOverlays(
    context: AgentBrandZoneOverlayContext,
    overlayState: AgentBrandZoneOverlayState,
    overlayCallbacks: AgentBrandZoneOverlayCallbacks,
) {
    val showDispatch = overlayState.showDispatch
    val showForward = overlayState.showForward
    val showSubscribe = overlayState.showSubscribe
    if (showDispatch) {
        AgentBrandDispatchSheet(
            identity = context.identity,
            missionHost = context.missionHost,
            onDismiss = overlayCallbacks.onDismissDispatch,
            onResult = overlayCallbacks.onDispatchResult,
        )
    }
    if (showForward) {
        AgentBrandForwardSheet(
            source = context.identity,
            registry = context.registry,
            onDismiss = overlayCallbacks.onDismissForward,
            onForward = { destination, _ -> overlayCallbacks.onForwardResult("Forwarded to ${destination.displayName}.") },
        )
    }
    if (showSubscribe) {
        AgentBrandSubscribeSheet(
            identity = context.identity,
            existingTopic = context.activeTopic,
            onDismiss = overlayCallbacks.onDismissSubscribe,
            onAction = { action ->
                overlayCallbacks.onSubscribeResult(agentBrandSubscribeActionMessage(context, overlayCallbacks, action))
            },
        )
    }
}

private fun agentBrandSubscribeActionMessage(
    context: AgentBrandZoneOverlayContext,
    overlayCallbacks: AgentBrandZoneOverlayCallbacks,
    action: SubscribeAction,
): String = when (action) {
    is SubscribeAction.Subscribe -> {
        context.subscriptionStore.subscribe(context.identity, action.cadence, action.deliveryMode)
        "Subscribed to ${context.identity.displayName} (${action.cadence.displayLabel.lowercase()}, ${action.deliveryMode.displayLabel.lowercase()})."
    }
    SubscribeAction.Unsubscribe -> {
        context.coroutineScope.launch {
            val message = runCatching {
                agentBrandUnsubscribeResultMessage(context)
            }.getOrElse {
                "Could not unsubscribe from ${context.identity.displayName}. Try again."
            }
            overlayCallbacks.onSubscribeResult(message)
        }
        "Removing ${context.identity.displayName} subscription..."
    }
    is SubscribeAction.SetMuted -> {
        context.subscriptionStore.setMuted(context.identity.id, action.muted)
        if (action.muted) "Muted ${context.identity.displayName}." else "Unmuted ${context.identity.displayName}."
    }
    is SubscribeAction.SetDeliveryMode -> {
        context.subscriptionStore.setDeliveryMode(context.identity.id, action.deliveryMode)
        "${context.identity.displayName} delivery set to ${action.deliveryMode.displayLabel.lowercase()}."
    }
}

private suspend fun agentBrandUnsubscribeResultMessage(context: AgentBrandZoneOverlayContext): String =
    when (context.subscriptionStore.unsubscribe(context.identity.id)) {
        AgentSubscriptionUnsubscribeResult.REMOVED ->
            "Unsubscribed from ${context.identity.displayName}."
        AgentSubscriptionUnsubscribeResult.LOCAL_ONLY_REMOVED ->
            "Removed local subscription for ${context.identity.displayName}."
        AgentSubscriptionUnsubscribeResult.MISSING_CLOUD_KEY ->
            "Connect this device to private cloud backup, then try again."
    }

internal fun availabilityHexColor(availability: AgentAvailability): Color = when (availability) {
    AgentAvailability.ONLINE -> AuroraColors.success
    AgentAvailability.DEGRADED -> AuroraColors.warning
    AgentAvailability.OFFLINE -> AuroraColors.error
    AgentAvailability.UNKNOWN -> AuroraColors.lightTextMuted
}

internal data class TiltState(val x: Float, val y: Float)

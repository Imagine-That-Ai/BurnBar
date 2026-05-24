package com.openburnbar.ui.pulse

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Percent
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingFraction
import com.openburnbar.data.models.displayRemainingPercent
import com.openburnbar.data.models.isDisplayableQuotaSignal
import com.openburnbar.data.models.key
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.burn.buildQuotaRingItems
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.EmptyStateView
import com.openburnbar.ui.theme.*

@Composable
fun QuotaPulseCard(
    snapshots: List<ProviderQuotaSnapshot>,
    onSelect: (String) -> Unit,
    onOpenBurn: () -> Unit
) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val prefs = remember(context) { QuotaPreferences.get(context) }

    val providerOrder by prefs.providerOrder.collectAsState()
    val visibleProviders by prefs.visibleProviders.collectAsState()
    val hiddenBuckets by prefs.hiddenBuckets.collectAsState()
    val bucketOrders by prefs.bucketOrders.collectAsState()
    val percentageDisplayMode by prefs.percentageDisplayMode.collectAsState()

    var isJiggling by remember { mutableStateOf(false) }

    val items = buildQuotaRingItems(snapshots).filter {
        val p = AgentProvider.fromKey(it.providerKey)
        p != null && visibleProviders.contains(p)
    }

    val hasUrgent = snapshots.flatMap { it.buckets }.any { bucket ->
        (bucket.displayRemainingFraction ?: 1.0) < 0.25
    }
    val fleetHealth = if (items.isNotEmpty()) {
        items.map { it.pressureRemaining }.average()
    } else 1.0
    val fleetPct = (fleetHealth * 100).toInt()
    val statusColor = when {
        hasUrgent -> AuroraColors.warning
        fleetHealth < 0.5 -> AuroraColors.amber
        else -> AuroraColors.success
    }
    val urgentCount = items.count { it.pressureRemaining < 0.25 }
    val providerWord = if (items.size == 1) "provider" else "providers"
    val fleetSubtitle = if (hasUrgent) {
        "${items.size} $providerWord · $urgentCount under pressure"
    } else {
        "${items.size} $providerWord · all healthy"
    }

    AuroraGlassCard(
        modifier = Modifier
            .padding(horizontal = AuroraSpacing.lg.dp)
            .pointerInput(Unit) {
                detectTapGestures(
                    onLongPress = {
                        if (!isJiggling) {
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            isJiggling = true
                        }
                    }
                )
            },
        cornerRadius = AuroraRadius.xl
    ) {
        Column {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(statusColor)
                    )
                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                    Text(
                        text = if (isJiggling) "CUSTOMIZE QUOTA" else "QUOTA",
                        fontSize = AuroraTypography.tiny.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        letterSpacing = 1.6.sp
                    )
                }

                if (isJiggling) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(
                            onClick = {
                                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                val modes = listOf("remainingPercent", "usedPercent", "absoluteValues", "fractional")
                                val idx = modes.indexOf(percentageDisplayMode).takeIf { it >= 0 } ?: 0
                                prefs.setPercentageDisplayMode(modes[(idx + 1) % modes.size])
                            },
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(Icons.Filled.Percent, "Display Mode", tint = AuroraColors.ember, modifier = Modifier.size(16.dp))
                        }
                        IconButton(
                            onClick = {
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                isJiggling = false
                            },
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(Icons.Filled.Check, "Done", tint = AuroraColors.success, modifier = Modifier.size(18.dp))
                        }
                    }
                } else {
                    Text(
                        text = "Open ›",
                        fontSize = AuroraTypography.tiny.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = AuroraColors.ember,
                        modifier = Modifier.clickable { onOpenBurn() }
                    )
                }
            }

            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            if (items.isEmpty() && !isJiggling) {
                EmptyStateView(
                    title = "No quota signal yet",
                    message = "Connect a provider on your Mac to start tracking quota."
                )
            } else if (isJiggling) {
                // Jiggling Customization List
                val orderedProviders = providerOrder.filter { visibleProviders.contains(it) }
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    orderedProviders.forEachIndexed { pIdx, p ->
                        JigglingProviderRow(
                            provider = p,
                            snapshots = snapshots.filter { AgentProvider.fromKey(it.providerId) == p || AgentProvider.fromKey(it.provider) == p },
                            prefs = prefs,
                            index = pIdx,
                            total = orderedProviders.size,
                            hiddenBuckets = hiddenBuckets,
                            bucketOrders = bucketOrders,
                            providerOrder = providerOrder,
                            percentageDisplayMode = percentageDisplayMode
                        )
                    }
                }
            } else {
                // Fleet hero
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FleetGauge(
                        progress = fleetHealth,
                        accent = statusColor,
                        modifier = Modifier.size(72.dp)
                    )
                    Spacer(modifier = Modifier.width(AuroraSpacing.lg.dp))
                    Column {
                        Text(
                            text = "$fleetPct% remaining",
                            fontSize = 22.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            text = fleetSubtitle,
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

                androidx.compose.material3.Divider(
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
                )

                Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

                // Provider rows
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    items.take(5).forEach { item ->
                        QuotaProviderRow(
                            item = item,
                            onClick = { onSelect(item.providerKey) }
                        )
                    }
                    if (items.size > 5) {
                        Text(
                            text = "${items.size - 5} more · See all",
                            fontSize = AuroraTypography.caption.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.clickable { onOpenBurn() }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun JigglingProviderRow(
    provider: AgentProvider,
    snapshots: List<ProviderQuotaSnapshot>,
    prefs: QuotaPreferences,
    index: Int,
    total: Int,
    hiddenBuckets: Set<String>,
    bucketOrders: Map<String, List<String>>,
    providerOrder: List<AgentProvider>,
    percentageDisplayMode: String
) {
    val haptic = LocalHapticFeedback.current

    // Shake animation
    val infiniteTransition = rememberInfiniteTransition(label = "shake")
    val shake by infiniteTransition.animateFloat(
        initialValue = -1.5f,
        targetValue = 1.5f,
        animationSpec = infiniteRepeatable(
            animation = tween(120, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "shake"
    )

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.3f))
            .rotate(shake)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            ProviderAuroraAvatar(providerKey = provider.key, size = 32, showHalo = false)
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text(
                text = provider.displayName,
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f)
            )

            // Move up/down
            IconButton(
                onClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    val newOrder = providerOrder.toMutableList()
                    val idx = newOrder.indexOf(provider)
                    if (idx > 0) {
                        newOrder[idx] = newOrder[idx - 1]
                        newOrder[idx - 1] = provider
                        prefs.setProviderOrder(newOrder)
                    }
                },
                enabled = index > 0,
                modifier = Modifier.size(32.dp)
            ) {
                Icon(Icons.Filled.ArrowUpward, "Move Up", tint = if (index > 0) AuroraColors.ember else Color.Gray)
            }
            IconButton(
                onClick = {
                    haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    val newOrder = providerOrder.toMutableList()
                    val idx = newOrder.indexOf(provider)
                    if (idx < newOrder.size - 1) {
                        newOrder[idx] = newOrder[idx + 1]
                        newOrder[idx + 1] = provider
                        prefs.setProviderOrder(newOrder)
                    }
                },
                enabled = index < total - 1,
                modifier = Modifier.size(32.dp)
            ) {
                Icon(Icons.Filled.ArrowDownward, "Move Down", tint = if (index < total - 1) AuroraColors.ember else Color.Gray)
            }
        }

        // Buckets
        val allBuckets = snapshots.flatMap { it.buckets.filter { b -> b.isDisplayableQuotaSignal() } }.distinctBy { it.key }
        val token = provider.key
        val customOrder = bucketOrders[token]
        val sortedBuckets = if (customOrder != null) {
            allBuckets.sortedWith { lhs: QuotaBucket, rhs: QuotaBucket ->
                val lhsIdx = customOrder.indexOf(lhs.key).takeIf { it >= 0 } ?: Int.MAX_VALUE
                val rhsIdx = customOrder.indexOf(rhs.key).takeIf { it >= 0 } ?: Int.MAX_VALUE
                if (lhsIdx != rhsIdx) {
                    lhsIdx.compareTo(rhsIdx)
                } else {
                    val label1 = (lhs.meta?.get("label") as? String) ?: lhs.name
                    val label2 = (rhs.meta?.get("label") as? String) ?: rhs.name
                    label1.compareTo(label2)
                }
            }
        } else {
            allBuckets
        }

        val currentKeys = customOrder ?: sortedBuckets.map { it.key }

        sortedBuckets.forEachIndexed { bIdx, bucket ->
            val isHidden = hiddenBuckets.contains("${provider.key}:${bucket.key}")
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                IconButton(
                    onClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        val key = "${provider.key}:${bucket.key}"
                        val newHidden = hiddenBuckets.toMutableSet()
                        if (newHidden.contains(key)) newHidden.remove(key) else newHidden.add(key)
                        prefs.setHiddenBuckets(newHidden)
                    },
                    modifier = Modifier.size(24.dp)
                ) {
                    Icon(
                        imageVector = if (isHidden) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                        contentDescription = "Toggle Visibility",
                        tint = if (isHidden) Color.Gray else AuroraColors.ember,
                        modifier = Modifier.size(16.dp)
                    )
                }
                Spacer(modifier = Modifier.width(8.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = (bucket.meta?.get("label") as? String) ?: bucket.name,
                        fontSize = 12.sp,
                        color = if (isHidden) Color.Gray else MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "${bucket.displayRemainingPercent?.toInt() ?: 0}%",
                        fontSize = 10.sp,
                        color = if (isHidden) Color.Gray else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                IconButton(
                    onClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        val newKeys = currentKeys.toMutableList()
                        val idx = newKeys.indexOf(bucket.key)
                        if (idx > 0) {
                            newKeys[idx] = newKeys[idx - 1]
                            newKeys[idx - 1] = bucket.key
                            val map = bucketOrders.toMutableMap()
                            map[token] = newKeys
                            prefs.setBucketOrders(map)
                        }
                    },
                    enabled = bIdx > 0,
                    modifier = Modifier.size(24.dp)
                ) {
                    Icon(Icons.Filled.ArrowUpward, "Move Up", tint = if (bIdx > 0) AuroraColors.ember else Color.Gray, modifier = Modifier.size(16.dp))
                }
                IconButton(
                    onClick = {
                        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        val newKeys = currentKeys.toMutableList()
                        val idx = newKeys.indexOf(bucket.key)
                        if (idx < newKeys.size - 1) {
                            newKeys[idx] = newKeys[idx + 1]
                            newKeys[idx + 1] = bucket.key
                            val map = bucketOrders.toMutableMap()
                            map[token] = newKeys
                            prefs.setBucketOrders(map)
                        }
                    },
                    enabled = bIdx < sortedBuckets.size - 1,
                    modifier = Modifier.size(24.dp)
                ) {
                    Icon(Icons.Filled.ArrowDownward, "Move Down", tint = if (bIdx < sortedBuckets.size - 1) AuroraColors.ember else Color.Gray, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

@Composable
private fun FleetGauge(
    progress: Double,
    accent: Color,
    modifier: Modifier = Modifier
) {
    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0.0, 1.0).toFloat(),
        animationSpec = tween(600),
        label = "fleet_gauge"
    )
    val trackColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f)
    Box(contentAlignment = Alignment.Center, modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidth = 7f
            val diameter = size.minDimension - strokeWidth
            val topLeft = Offset((size.width - diameter) / 2, (size.height - diameter) / 2)
            drawCircle(
                color = trackColor,
                radius = diameter / 2,
                style = Stroke(width = strokeWidth)
            )
            drawArc(
                brush = Brush.sweepGradient(
                    colors = listOf(accent, accent.copy(alpha = 0.85f), AuroraColors.amber, accent),
                    center = Offset(size.width / 2, size.height / 2)
                ),
                startAngle = -90f,
                sweepAngle = 360f * animatedProgress,
                useCenter = false,
                topLeft = topLeft,
                size = Size(diameter, diameter),
                style = Stroke(width = 8f, cap = StrokeCap.Round)
            )
        }
        Text(text = "\uD83D\uDD25", fontSize = 22.sp)
    }
}

@Composable
private fun QuotaProviderRow(
    item: com.openburnbar.ui.burn.QuotaRingItem,
    onClick: () -> Unit
) {
    val primary = Color(item.provider.brandColor)
    val statusColor = when {
        item.pressureRemaining < 0.25 -> AuroraColors.error
        item.pressureRemaining < 0.50 -> AuroraColors.warning
        else -> AuroraColors.success
    }
    val pct = (item.pressureRemaining * 100).toInt()

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.45f))
            .clickable { onClick() }
            .padding(vertical = 6.dp, horizontal = 8.dp)
    ) {
        // Status indicator rail
        Box(
            modifier = Modifier
                .width(3.dp)
                .height(28.dp)
                .clip(CircleShape)
                .background(statusColor)
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        ProviderAuroraAvatar(providerKey = item.providerKey, size = 32, showHalo = false)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.label,
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface
            )
            LinearProgressIndicator(
                progress = { item.pressureRemaining.toFloat().coerceIn(0f, 1f) },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(5.dp)
                    .clip(CircleShape),
                color = primary.copy(alpha = 0.85f),
                trackColor = Color.Black.copy(alpha = 0.42f)
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "$pct%",
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            color = statusColor
        )
    }
}

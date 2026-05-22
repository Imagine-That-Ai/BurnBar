package com.openburnbar.ui.settings

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.models.*
import com.openburnbar.data.stores.QuotaPreferences
import com.openburnbar.data.stores.QuotaStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.theme.*
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraTypography
import kotlin.math.roundToInt

@Composable
fun QuotaCustomizationScreen(
    router: SettingsRouter,
    onBack: () -> Unit,
    quotaStore: QuotaStore = viewModel()
) {
    val context = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val isDark = isSystemInDarkTheme()

    val prefs = remember(context) { QuotaPreferences.get(context) }
    val providerOrder by prefs.providerOrder.collectAsState()
    val visibleProviders by prefs.visibleProviders.collectAsState()
    val hiddenBuckets by prefs.hiddenBuckets.collectAsState()
    val bucketOrders by prefs.bucketOrders.collectAsState()
    val percentageDisplayMode by prefs.percentageDisplayMode.collectAsState()

    val snapshots by quotaStore.snapshots.collectAsState()
    var expandedProviderKey by remember { mutableStateOf<String?>(null) }

    // Live Interactive Preview Mock Bucket
    val mockBucket = remember {
        QuotaBucket(
            name = "Included Usage",
            used = 12.0,
            limit = 15.0,
            remaining = 3.0,
            window = "monthly",
            meta = mapOf("unit" to "currency", "label" to "Included Usage")
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    if (isDark) AuroraColors.darkBackground
                    else AuroraColors.lightBackground
                )
                .padding(horizontal = AuroraSpacing.lg.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
        ) {
            Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                IconButton(onClick = onBack) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = MaterialTheme.colorScheme.onSurface
                    )
                }
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(
                    text = "Quota Customisation",
                    style = AuroraType.displayLarge,
                    color = MaterialTheme.colorScheme.onSurface
                )
            }

            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
                modifier = Modifier.fillMaxSize()
            ) {
                // SECTION 1: Dynamic Preview Card
                item {
                    Text(
                        "LIVE PREVIEW",
                        fontWeight = FontWeight.Bold,
                        fontSize = AuroraTypography.tiny.sp,
                        letterSpacing = 1.2.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(4.dp))

                    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            ProviderLogo(provider = AgentProvider.CLAUDE_CODE, size = 32.dp)
                            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = "Monthly limit",
                                    fontSize = AuroraTypography.caption.sp,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Text(
                                    text = mockBucket.getRemainingText(percentageDisplayMode),
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Column(horizontalAlignment = Alignment.End) {
                                val pct = mockBucket.displayRemainingPercent?.roundToInt() ?: 20
                                Text(
                                    text = when (percentageDisplayMode) {
                                        "remainingPercent" -> "$pct%"
                                        "usedPercent" -> "${100 - pct}%"
                                        "fractional" -> "%.2f".format(pct / 100.0)
                                        "absoluteValues" -> mockBucket.formatValue(mockBucket.remaining)
                                        else -> "$pct%"
                                    },
                                    fontWeight = FontWeight.Bold
                                )
                                LinearProgressIndicator(
                                    progress = {
                                        if (percentageDisplayMode == "usedPercent") 0.8f else 0.2f
                                    },
                                    modifier = Modifier
                                        .width(72.dp)
                                        .height(4.dp)
                                        .clip(RoundedCornerShape(2.dp)),
                                    color = if (percentageDisplayMode == "usedPercent") AuroraColors.warning else AuroraColors.burnOrange,
                                    trackColor = AuroraColors.darkBorder.copy(alpha = 0.25f)
                                )
                            }
                        }
                    }
                }

                // SECTION 2: Format Selector
                item {
                    Text(
                        "PERCENTAGE DISPLAY FORMAT",
                        fontWeight = FontWeight.Bold,
                        fontSize = AuroraTypography.tiny.sp,
                        letterSpacing = 1.2.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(4.dp))

                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(AuroraRadius.lg.dp),
                        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
                    ) {
                        Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
                            listOf(
                                Pair("remainingPercent", "Remaining % (e.g. 20% left)"),
                                Pair("usedPercent", "Used % (e.g. 80% used)"),
                                Pair("fractional", "Fractional (e.g. 0.20 left)"),
                                Pair("absoluteValues", "Absolute values (e.g. $3.00 / $15.00)")
                            ).forEach { (mode, label) ->
                                val selected = percentageDisplayMode == mode
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            prefs.setPercentageDisplayMode(mode)
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                        }
                                        .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp)
                                ) {
                                    RadioButton(
                                        selected = selected,
                                        onClick = {
                                            prefs.setPercentageDisplayMode(mode)
                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                        }
                                    )
                                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                                    Text(
                                        text = label,
                                        fontSize = AuroraTypography.body.sp,
                                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                                        color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                }

                // SECTION 3: Provider List & Reordering
                item {
                    Text(
                        "PROVIDERS DISPLAY ORDER & VISIBILITY",
                        fontWeight = FontWeight.Bold,
                        fontSize = AuroraTypography.tiny.sp,
                        letterSpacing = 1.2.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                itemsIndexed(providerOrder) { idx, provider ->
                    val isVisible = provider in visibleProviders
                    val isExpanded = expandedProviderKey == provider.key
                    val matchingSnapshot = snapshots.find { it.provider.lowercase() == provider.key.lowercase() }

                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(AuroraRadius.lg.dp),
                        color = MaterialTheme.colorScheme.surface.copy(alpha = if (isVisible) 0.6f else 0.3f)
                    ) {
                        Column {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(AuroraSpacing.md.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Checkbox(
                                    checked = isVisible,
                                    onCheckedChange = { checked ->
                                        val next = visibleProviders.toMutableSet()
                                        if (checked) next.add(provider) else next.remove(provider)
                                        prefs.setVisibleProviders(next)
                                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    }
                                )
                                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                ProviderLogo(provider = provider, size = 28.dp)
                                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = provider.displayName,
                                        fontSize = AuroraTypography.body.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = if (isVisible) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                    val bucketCount = matchingSnapshot?.buckets?.filter { it.isDisplayableQuotaSignal() }?.size ?: 0
                                    Text(
                                        text = if (bucketCount > 0) "$bucketCount active bucket(s)" else "No active buckets",
                                        fontSize = AuroraTypography.caption.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }

                                // Reordering Arrow buttons
                                Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
                                    IconButton(
                                        onClick = {
                                            if (idx > 0) {
                                                val next = providerOrder.toMutableList()
                                                val temp = next[idx]
                                                next[idx] = next[idx - 1]
                                                next[idx - 1] = temp
                                                prefs.setProviderOrder(next)
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            }
                                        },
                                        enabled = idx > 0,
                                        modifier = Modifier.size(32.dp)
                                    ) {
                                        Icon(
                                            imageVector = Icons.Filled.KeyboardArrowUp,
                                            contentDescription = "Move Up",
                                            modifier = Modifier.size(20.dp)
                                        )
                                    }
                                    IconButton(
                                        onClick = {
                                            if (idx < providerOrder.size - 1) {
                                                val next = providerOrder.toMutableList()
                                                val temp = next[idx]
                                                next[idx] = next[idx + 1]
                                                next[idx + 1] = temp
                                                prefs.setProviderOrder(next)
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            }
                                        },
                                        enabled = idx < providerOrder.size - 1,
                                        modifier = Modifier.size(32.dp)
                                    ) {
                                        Icon(
                                            imageVector = Icons.Filled.KeyboardArrowDown,
                                            contentDescription = "Move Down",
                                            modifier = Modifier.size(20.dp)
                                        )
                                    }
                                }

                                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))

                                val expandRotation by animateFloatAsState(
                                    targetValue = if (isExpanded) 180f else 0f,
                                    animationSpec = tween(durationMillis = 200),
                                    label = "chevron"
                                )
                                IconButton(
                                    onClick = {
                                        expandedProviderKey = if (isExpanded) null else provider.key
                                    },
                                    modifier = Modifier.graphicsLayer { rotationZ = expandRotation }
                                ) {
                                    Icon(
                                        imageVector = Icons.Filled.KeyboardArrowDown,
                                        contentDescription = "Toggle buckets",
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }

                            // Dynamic Bucket Subscreen inside Accordion
                            AnimatedVisibility(
                                visible = isExpanded,
                                enter = expandVertically() + fadeIn(),
                                exit = shrinkVertically() + fadeOut()
                            ) {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                                        .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp)
                                ) {
                                    val displayableBuckets = remember(matchingSnapshot?.buckets) {
                                        matchingSnapshot?.buckets?.filter { it.isDisplayableQuotaSignal() } ?: emptyList()
                                    }

                                    if (displayableBuckets.isEmpty()) {
                                        Text(
                                            text = "No dynamic buckets reported for this provider yet.",
                                            fontSize = AuroraTypography.caption.sp,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.padding(AuroraSpacing.md.dp)
                                        )
                                    } else {
                                        val customOrder = bucketOrders[provider.key] ?: emptyList()
                                        val sortedBuckets = remember(displayableBuckets, customOrder) {
                                            displayableBuckets.sortedBy { b ->
                                                val pos = customOrder.indexOf(b.key)
                                                if (pos >= 0) pos else Int.MAX_VALUE
                                            }
                                        }

                                        Text(
                                            text = "SUB-QUOTA CHANNELS",
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 9.sp,
                                            letterSpacing = 1.0.sp,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.padding(bottom = 4.dp, start = 8.dp)
                                        )

                                        sortedBuckets.forEachIndexed { bIdx, bucket ->
                                            val compositeKey = "${provider.key}:${bucket.key}"
                                            val bucketVisible = !hiddenBuckets.contains(compositeKey)

                                            Row(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(vertical = 4.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                Checkbox(
                                                    checked = bucketVisible,
                                                    onCheckedChange = { checked ->
                                                        val next = hiddenBuckets.toMutableSet()
                                                        if (checked) next.remove(compositeKey) else next.add(compositeKey)
                                                        prefs.setHiddenBuckets(next)
                                                        haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                    }
                                                )
                                                Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                                                Column(modifier = Modifier.weight(1f)) {
                                                    Text(
                                                        text = bucket.label,
                                                        fontSize = AuroraTypography.caption.sp,
                                                        fontWeight = FontWeight.SemiBold,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis
                                                    )
                                                    Text(
                                                        text = bucket.effectiveWindowLabel,
                                                        fontSize = 10.sp,
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                                    )
                                                }

                                                // Sub-bucket reorder arrows
                                                IconButton(
                                                    onClick = {
                                                        if (bIdx > 0) {
                                                            val nextKeys = sortedBuckets.map { it.key }.toMutableList()
                                                            val temp = nextKeys[bIdx]
                                                            nextKeys[bIdx] = nextKeys[bIdx - 1]
                                                            nextKeys[bIdx - 1] = temp

                                                            val nextOrders = bucketOrders.toMutableMap()
                                                            nextOrders[provider.key] = nextKeys
                                                            prefs.setBucketOrders(nextOrders)
                                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                        }
                                                    },
                                                    enabled = bIdx > 0,
                                                    modifier = Modifier.size(28.dp)
                                                ) {
                                                    Icon(
                                                        imageVector = Icons.Filled.KeyboardArrowUp,
                                                        contentDescription = "Move Up",
                                                        modifier = Modifier.size(16.dp)
                                                    )
                                                }
                                                IconButton(
                                                    onClick = {
                                                        if (bIdx < sortedBuckets.size - 1) {
                                                            val nextKeys = sortedBuckets.map { it.key }.toMutableList()
                                                            val temp = nextKeys[bIdx]
                                                            nextKeys[bIdx] = nextKeys[bIdx + 1]
                                                            nextKeys[bIdx + 1] = temp

                                                            val nextOrders = bucketOrders.toMutableMap()
                                                            nextOrders[provider.key] = nextKeys
                                                            prefs.setBucketOrders(nextOrders)
                                                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                                        }
                                                    },
                                                    enabled = bIdx < sortedBuckets.size - 1,
                                                    modifier = Modifier.size(28.dp)
                                                ) {
                                                    Icon(
                                                        imageVector = Icons.Filled.KeyboardArrowDown,
                                                        contentDescription = "Move Down",
                                                        modifier = Modifier.size(16.dp)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                item {
                    Spacer(modifier = Modifier.height(AuroraSpacing.xxl.dp))
                }
            }
        }
    }
}

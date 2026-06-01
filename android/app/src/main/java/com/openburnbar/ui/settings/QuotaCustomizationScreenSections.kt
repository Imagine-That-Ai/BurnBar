@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.settings

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.ProviderQuotaSnapshot
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingPercent
import com.openburnbar.data.models.effectiveWindowLabel
import com.openburnbar.data.models.formatValue
import com.openburnbar.data.models.getRemainingText
import com.openburnbar.data.models.isDisplayableQuotaSignal
import com.openburnbar.data.models.key
import com.openburnbar.data.models.label
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.ProviderLogo
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography
import kotlin.math.roundToInt


@Composable
internal fun QuotaCustomizationScaffold(
    isDark: Boolean,
    actions: QuotaCustomizationActions,
    content: @Composable () -> Unit,
) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground,
            )
            .padding(horizontal = AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        QuotaCustomizationHeader(onBack = actions.onBack)
        content()
    }
}

@Composable
internal fun QuotaCustomizationHeader(onBack: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        IconButton(onClick = onBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = MaterialTheme.colorScheme.onSurface,
            )
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text(
            text = "Quota Customisation",
            style = AuroraType.displayLarge,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
internal fun QuotaCustomizationSectionLabel(text: String) {
    Text(
        text = text,
        fontWeight = FontWeight.Bold,
        fontSize = AuroraTypography.tiny.sp,
        letterSpacing = 1.2.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
internal fun QuotaCustomizationPreviewCard(
    mockBucket: QuotaBucket,
    percentageDisplayMode: String,
) {
    QuotaCustomizationSectionLabel(text = "LIVE PREVIEW")
    Spacer(modifier = Modifier.height(4.dp))
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        QuotaCustomizationPreviewCardBody(
            mockBucket = mockBucket,
            percentageDisplayMode = percentageDisplayMode,
        )
    }
}

@Composable
private fun QuotaCustomizationPreviewCardBody(
    mockBucket: QuotaBucket,
    percentageDisplayMode: String,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        ProviderLogo(provider = AgentProvider.CLAUDE_CODE, size = 32.dp)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Monthly limit",
                fontSize = AuroraTypography.caption.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = mockBucket.getRemainingText(percentageDisplayMode),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        QuotaCustomizationPreviewMetrics(
            mockBucket = mockBucket,
            percentageDisplayMode = percentageDisplayMode,
        )
    }
}

@Composable
private fun QuotaCustomizationPreviewMetrics(
    mockBucket: QuotaBucket,
    percentageDisplayMode: String,
) {
    Column(horizontalAlignment = Alignment.End) {
        val pct = mockBucket.displayRemainingPercent?.roundToInt() ?: 20
        Text(
            text = quotaPreviewPrimaryText(mockBucket, percentageDisplayMode, pct),
            fontWeight = FontWeight.Bold,
        )
        LinearProgressIndicator(
            progress = {
                if (percentageDisplayMode == "usedPercent") 0.8f else 0.2f
            },
            modifier =
            Modifier
                .width(72.dp)
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp)),
            color = if (percentageDisplayMode == "usedPercent") AuroraColors.warning else AuroraColors.burnOrange,
            trackColor = AuroraColors.darkBorder.copy(alpha = 0.25f),
        )
    }
}

private fun quotaPreviewPrimaryText(
    mockBucket: QuotaBucket,
    percentageDisplayMode: String,
    pct: Int,
): String =
    when (percentageDisplayMode) {
        "remainingPercent" -> "$pct%"
        "usedPercent" -> "${100 - pct}%"
        "fractional" -> "%.2f".format(pct / 100.0)
        "absoluteValues" -> mockBucket.formatValue(mockBucket.remaining)
        else -> "$pct%"
    }

private val quotaDisplayModeOptions =
    listOf(
        Pair("remainingPercent", "Remaining % (e.g. 20% left)"),
        Pair("usedPercent", "Used % (e.g. 80% used)"),
        Pair("fractional", "Fractional (e.g. 0.20 left)"),
        Pair("absoluteValues", "Absolute values (e.g. $3.00 / $15.00)"),
    )

@Composable
internal fun QuotaCustomizationFormatSelector(
    percentageDisplayMode: String,
    onSelectMode: (String) -> Unit,
    onHaptic: () -> Unit,
) {
    QuotaCustomizationSectionLabel(text = "PERCENTAGE DISPLAY FORMAT")
    Spacer(modifier = Modifier.height(4.dp))
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.lg.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
    ) {
        Column(modifier = Modifier.padding(AuroraSpacing.sm.dp)) {
            quotaDisplayModeOptions.forEach { (mode, label) ->
                QuotaCustomizationFormatOptionRow(
                    mode = mode,
                    label = label,
                    selected = percentageDisplayMode == mode,
                    onSelectMode = onSelectMode,
                    onHaptic = onHaptic,
                )
            }
        }
    }
}

@Composable
private fun QuotaCustomizationFormatOptionRow(
    mode: String,
    label: String,
    selected: Boolean,
    onSelectMode: (String) -> Unit,
    onHaptic: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .clickable {
                onSelectMode(mode)
                onHaptic()
            }
            .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
    ) {
        RadioButton(
            selected = selected,
            onClick = {
                onSelectMode(mode)
                onHaptic()
            },
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Text(
            text = label,
            fontSize = AuroraTypography.body.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color =
            if (selected) {
                MaterialTheme.colorScheme.onSurface
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
        )
    }
}

@Composable
internal fun QuotaCustomizationContent(
    state: QuotaCustomizationUiState,
    actions: QuotaCustomizationActions,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp),
        modifier = modifier.fillMaxSize(),
    ) {
        item {
            QuotaCustomizationPreviewCard(
                mockBucket = state.mockBucket,
                percentageDisplayMode = state.percentageDisplayMode,
            )
        }
        item {
            QuotaCustomizationFormatSelector(
                percentageDisplayMode = state.percentageDisplayMode,
                onSelectMode = actions.onPercentageDisplayMode,
                onHaptic = actions.onHaptic,
            )
        }
        item {
            QuotaCustomizationSectionLabel(text = "PROVIDERS DISPLAY ORDER & VISIBILITY")
        }
        quotaCustomizationProviderItems(
            state = state,
            actions = actions,
        )
        item {
            Spacer(modifier = Modifier.height(AuroraSpacing.xxl.dp))
        }
    }
}

internal fun LazyListScope.quotaCustomizationProviderItems(
    state: QuotaCustomizationUiState,
    actions: QuotaCustomizationActions,
) {
    itemsIndexed(state.providerOrder) { idx, provider ->
        QuotaCustomizationProviderCard(
            context =
            QuotaCustomizationProviderCardContext(
                provider = provider,
                index = idx,
                providerCount = state.providerOrder.size,
                isVisible = provider in state.visibleProviders,
                isExpanded = state.expandedProviderKey == provider.key,
                matchingSnapshot = state.snapshots.find { it.provider.lowercase() == provider.key.lowercase() },
            ),
            state = state,
            actions = actions,
        )
    }
}

@Composable
internal fun QuotaCustomizationProviderCard(
    context: QuotaCustomizationProviderCardContext,
    state: QuotaCustomizationUiState,
    actions: QuotaCustomizationActions,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.lg.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = if (context.isVisible) 0.6f else 0.3f),
    ) {
        Column {
            QuotaCustomizationProviderRowHeader(
                context = context,
                state = state,
                actions = actions,
            )
            QuotaCustomizationProviderBucketsAccordion(
                context = context,
                state = state,
                actions = actions,
            )
        }
    }
}

@Composable
internal fun QuotaCustomizationProviderRowHeader(
    context: QuotaCustomizationProviderCardContext,
    state: QuotaCustomizationUiState,
    actions: QuotaCustomizationActions,
) {
    val provider = context.provider
    val isVisible = context.isVisible
    val matchingSnapshot = context.matchingSnapshot
    val index = context.index
    val providerCount = context.providerCount
    val isExpanded = context.isExpanded
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(AuroraSpacing.md.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = isVisible,
            onCheckedChange = { checked ->
                val next = state.visibleProviders.toMutableSet()
                if (checked) next.add(provider) else next.remove(provider)
                actions.onVisibleProviders(next)
                actions.onHaptic()
            },
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
        ProviderLogo(provider = provider, size = 28.dp)
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        QuotaCustomizationProviderTitleColumn(
            provider = provider,
            isVisible = isVisible,
            matchingSnapshot = matchingSnapshot,
        )
        QuotaCustomizationProviderReorderButtons(
            index = index,
            providerCount = providerCount,
            providerOrder = state.providerOrder,
            onProviderOrder = actions.onProviderOrder,
            onHaptic = actions.onHaptic,
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
        QuotaCustomizationProviderExpandButton(
            isExpanded = isExpanded,
            providerKey = provider.key,
            onExpandedProviderKey = actions.onExpandedProviderKey,
        )
    }
}

@Composable
private fun RowScope.QuotaCustomizationProviderTitleColumn(
    provider: AgentProvider,
    isVisible: Boolean,
    matchingSnapshot: ProviderQuotaSnapshot?,
) {
    Column(modifier = Modifier.weight(1f)) {
        Text(
            text = provider.displayName,
            fontSize = AuroraTypography.body.sp,
            fontWeight = FontWeight.Bold,
            color =
            if (isVisible) {
                MaterialTheme.colorScheme.onSurface
            } else {
                MaterialTheme.colorScheme.onSurfaceVariant
            },
        )
        val bucketCount = matchingSnapshot?.buckets?.filter { it.isDisplayableQuotaSignal() }?.size ?: 0
        Text(
            text = if (bucketCount > 0) "$bucketCount active bucket(s)" else "No active buckets",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun QuotaCustomizationProviderReorderButtons(
    index: Int,
    providerCount: Int,
    providerOrder: List<AgentProvider>,
    onProviderOrder: (List<AgentProvider>) -> Unit,
    onHaptic: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.xs.dp)) {
        IconButton(
            onClick = {
                if (index > 0) {
                    val next = providerOrder.toMutableList()
                    val temp = next[index]
                    next[index] = next[index - 1]
                    next[index - 1] = temp
                    onProviderOrder(next)
                    onHaptic()
                }
            },
            enabled = index > 0,
            modifier = Modifier.size(32.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.KeyboardArrowUp,
                contentDescription = "Move Up",
                modifier = Modifier.size(20.dp),
            )
        }
        IconButton(
            onClick = {
                if (index < providerCount - 1) {
                    val next = providerOrder.toMutableList()
                    val temp = next[index]
                    next[index] = next[index + 1]
                    next[index + 1] = temp
                    onProviderOrder(next)
                    onHaptic()
                }
            },
            enabled = index < providerCount - 1,
            modifier = Modifier.size(32.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.KeyboardArrowDown,
                contentDescription = "Move Down",
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun QuotaCustomizationProviderExpandButton(
    isExpanded: Boolean,
    providerKey: String,
    onExpandedProviderKey: (String?) -> Unit,
) {
    val expandRotation by animateFloatAsState(
        targetValue = if (isExpanded) 180f else 0f,
        animationSpec = tween(durationMillis = 200),
        label = "chevron",
    )
    IconButton(
        onClick = { onExpandedProviderKey(if (isExpanded) null else providerKey) },
        modifier = Modifier.graphicsLayer { rotationZ = expandRotation },
    ) {
        Icon(
            imageVector = Icons.Filled.KeyboardArrowDown,
            contentDescription = "Toggle buckets",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun QuotaCustomizationProviderBucketsAccordion(
    context: QuotaCustomizationProviderCardContext,
    state: QuotaCustomizationUiState,
    actions: QuotaCustomizationActions,
) {
    AnimatedVisibility(
        visible = context.isExpanded,
        enter = expandVertically() + fadeIn(),
        exit = shrinkVertically() + fadeOut(),
    ) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
        ) {
            QuotaCustomizationProviderBucketsPanel(
                provider = context.provider,
                matchingSnapshot = context.matchingSnapshot,
                state = state,
                actions = actions,
            )
        }
    }
}

@Composable
private fun QuotaCustomizationProviderBucketsPanel(
    provider: AgentProvider,
    matchingSnapshot: ProviderQuotaSnapshot?,
    state: QuotaCustomizationUiState,
    actions: QuotaCustomizationActions,
) {
    val bucketOrders = state.bucketOrders
    val displayableBuckets =
        remember(matchingSnapshot?.buckets) {
            matchingSnapshot?.buckets?.filter { it.isDisplayableQuotaSignal() } ?: emptyList()
        }
    if (displayableBuckets.isEmpty()) {
        Text(
            text = "No dynamic buckets reported for this provider yet.",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(AuroraSpacing.md.dp),
        )
        return
    }
    val customOrder = bucketOrders[provider.key] ?: emptyList()
    val sortedBuckets =
        remember(displayableBuckets, customOrder) {
            displayableBuckets.sortedBy { bucket ->
                val pos = customOrder.indexOf(bucket.key)
                if (pos >= 0) pos else Int.MAX_VALUE
            }
        }
    Text(
        text = "SUB-QUOTA CHANNELS",
        fontWeight = FontWeight.Bold,
        fontSize = 9.sp,
        letterSpacing = 1.0.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(bottom = 4.dp, start = 8.dp),
    )
    sortedBuckets.forEachIndexed { bucketIndex, bucket ->
        QuotaCustomizationBucketRow(
            provider = provider,
            bucket = bucket,
            bucketIndex = bucketIndex,
            sortedBuckets = sortedBuckets,
            state = state,
            actions = actions,
        )
    }
}

@Composable
private fun QuotaCustomizationBucketRow(
    provider: AgentProvider,
    bucket: QuotaBucket,
    bucketIndex: Int,
    sortedBuckets: List<QuotaBucket>,
    state: QuotaCustomizationUiState,
    actions: QuotaCustomizationActions,
) {
    val hiddenBuckets = state.hiddenBuckets
    val bucketOrders = state.bucketOrders
    val compositeKey = "${provider.key}:${bucket.key}"
    val bucketVisible = !hiddenBuckets.contains(compositeKey)
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = bucketVisible,
            onCheckedChange = { checked ->
                val next = hiddenBuckets.toMutableSet()
                if (checked) next.remove(compositeKey) else next.add(compositeKey)
                actions.onHiddenBuckets(next)
                actions.onHaptic()
            },
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
        QuotaCustomizationBucketLabelColumn(bucket = bucket)
        QuotaCustomizationBucketReorderButtons(
            bucketIndex = bucketIndex,
            sortedBuckets = sortedBuckets,
            providerKey = provider.key,
            bucketOrders = bucketOrders,
            onBucketOrders = actions.onBucketOrders,
            onHaptic = actions.onHaptic,
        )
    }
}

@Composable
private fun RowScope.QuotaCustomizationBucketLabelColumn(bucket: QuotaBucket) {
    Column(modifier = Modifier.weight(1f)) {
        Text(
            text = bucket.label,
            fontSize = AuroraTypography.caption.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = bucket.effectiveWindowLabel,
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun QuotaCustomizationBucketReorderButtons(
    bucketIndex: Int,
    sortedBuckets: List<QuotaBucket>,
    providerKey: String,
    bucketOrders: Map<String, List<String>>,
    onBucketOrders: (Map<String, List<String>>) -> Unit,
    onHaptic: () -> Unit,
) {
    IconButton(
        onClick = {
            if (bucketIndex > 0) {
                val nextKeys = sortedBuckets.map { it.key }.toMutableList()
                val temp = nextKeys[bucketIndex]
                nextKeys[bucketIndex] = nextKeys[bucketIndex - 1]
                nextKeys[bucketIndex - 1] = temp
                val nextOrders = bucketOrders.toMutableMap()
                nextOrders[providerKey] = nextKeys
                onBucketOrders(nextOrders)
                onHaptic()
            }
        },
        enabled = bucketIndex > 0,
        modifier = Modifier.size(28.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.KeyboardArrowUp,
            contentDescription = "Move Up",
            modifier = Modifier.size(16.dp),
        )
    }
    IconButton(
        onClick = {
            if (bucketIndex < sortedBuckets.size - 1) {
                val nextKeys = sortedBuckets.map { it.key }.toMutableList()
                val temp = nextKeys[bucketIndex]
                nextKeys[bucketIndex] = nextKeys[bucketIndex + 1]
                nextKeys[bucketIndex + 1] = temp
                val nextOrders = bucketOrders.toMutableMap()
                nextOrders[providerKey] = nextKeys
                onBucketOrders(nextOrders)
                onHaptic()
            }
        },
        enabled = bucketIndex < sortedBuckets.size - 1,
        modifier = Modifier.size(28.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.KeyboardArrowDown,
            contentDescription = "Move Down",
            modifier = Modifier.size(16.dp),
        )
    }
}

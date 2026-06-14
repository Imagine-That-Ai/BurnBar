// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pulse

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.QuotaBucket
import com.openburnbar.data.models.displayRemainingPercent
import com.openburnbar.data.models.isDisplayableQuotaSignal
import com.openburnbar.data.models.key
import com.openburnbar.ui.burn.ProviderAuroraAvatar
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
internal fun JigglingProviderRow(model: JigglingProviderRowModel) {
    val infiniteTransition = rememberInfiniteTransition(label = "shake")
    val shake by infiniteTransition.animateFloat(
        initialValue = -1.5f,
        targetValue = 1.5f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(120, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "shake",
    )
    val sortedBuckets = sortedJigglingBuckets(model)

    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.3f))
            .rotate(shake)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        JigglingProviderHeader(model = model)
        sortedBuckets.forEachIndexed { bIdx, bucket ->
            JigglingBucketRow(
                model = model,
                bucket = bucket,
                bucketIndex = bIdx,
                totalBuckets = sortedBuckets.size,
                currentKeys = model.bucketOrders[model.provider.key] ?: sortedBuckets.map { it.key },
            )
        }
    }
}

@Composable
private fun JigglingProviderHeader(model: JigglingProviderRowModel) {
    val haptic = LocalHapticFeedback.current
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        ProviderAuroraAvatar(providerKey = model.provider.key, size = 32, showHalo = false)
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Text(
            text = model.provider.displayName,
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        JigglingMoveButton(
            enabled = model.index > 0,
            up = true,
            onClick = {
                reorderProvider(model, direction = -1)
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            },
        )
        JigglingMoveButton(
            enabled = model.index < model.total - 1,
            up = false,
            onClick = {
                reorderProvider(model, direction = 1)
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
            },
        )
    }
}

@Composable
private fun JigglingMoveButton(enabled: Boolean, up: Boolean, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(32.dp)) {
        Icon(
            imageVector = if (up) Icons.Filled.ArrowUpward else Icons.Filled.ArrowDownward,
            contentDescription = if (up) "Move Up" else "Move Down",
            tint = if (enabled) AuroraColors.ember else Color.Gray,
        )
    }
}

@Composable
private fun JigglingBucketRow(model: JigglingProviderRowModel, bucket: QuotaBucket, bucketIndex: Int, totalBuckets: Int, currentKeys: List<String>) {
    val haptic = LocalHapticFeedback.current
    val provider = model.provider
    val isHidden = model.hiddenBuckets.contains("${provider.key}:${bucket.key}")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        IconButton(
            onClick = {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                toggleBucketVisibility(model, bucket)
            },
            modifier = Modifier.size(24.dp),
        ) {
            Icon(
                imageVector = if (isHidden) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                contentDescription = "Toggle Visibility",
                tint = if (isHidden) Color.Gray else AuroraColors.ember,
                modifier = Modifier.size(16.dp),
            )
        }
        Spacer(modifier = Modifier.width(8.dp))
        JigglingBucketLabels(bucket = bucket, isHidden = isHidden)
        JigglingBucketMoveButtons(
            enabledUp = bucketIndex > 0,
            enabledDown = bucketIndex < totalBuckets - 1,
            onUp = {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                reorderBucket(model, bucket, currentKeys, direction = -1)
            },
            onDown = {
                haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                reorderBucket(model, bucket, currentKeys, direction = 1)
            },
        )
    }
}

@Composable
private fun RowScope.JigglingBucketLabels(bucket: QuotaBucket, isHidden: Boolean) {
    Column(modifier = Modifier.weight(1f)) {
        Text(
            text = bucket.meta?.get("label") as? String ?: bucket.name,
            fontSize = 12.sp,
            color = if (isHidden) Color.Gray else MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = "${bucket.displayRemainingPercent?.toInt() ?: 0}%",
            fontSize = 10.sp,
            color = if (isHidden) Color.Gray else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun JigglingBucketMoveButtons(enabledUp: Boolean, enabledDown: Boolean, onUp: () -> Unit, onDown: () -> Unit) {
    IconButton(onClick = onUp, enabled = enabledUp, modifier = Modifier.size(24.dp)) {
        Icon(Icons.Filled.ArrowUpward, "Move Up", tint = if (enabledUp) AuroraColors.ember else Color.Gray, modifier = Modifier.size(16.dp))
    }
    IconButton(onClick = onDown, enabled = enabledDown, modifier = Modifier.size(24.dp)) {
        Icon(
            Icons.Filled.ArrowDownward,
            "Move Down",
            tint = if (enabledDown) AuroraColors.ember else Color.Gray,
            modifier = Modifier.size(16.dp),
        )
    }
}

private fun sortedJigglingBuckets(model: JigglingProviderRowModel): List<QuotaBucket> {
    val allBuckets =
        model.snapshots
            .flatMap { it.buckets.filter { bucket -> bucket.isDisplayableQuotaSignal() } }
            .distinctBy { it.key }
    val customOrder = model.bucketOrders[model.provider.key]
    return if (customOrder != null) {
        allBuckets.sortedWith { lhs, rhs ->
            val lhsIdx = customOrder.indexOf(lhs.key).takeIf { it >= 0 } ?: Int.MAX_VALUE
            val rhsIdx = customOrder.indexOf(rhs.key).takeIf { it >= 0 } ?: Int.MAX_VALUE
            if (lhsIdx != rhsIdx) {
                lhsIdx.compareTo(rhsIdx)
            } else {
                val label1 = lhs.meta?.get("label") as? String ?: lhs.name
                val label2 = rhs.meta?.get("label") as? String ?: rhs.name
                label1.compareTo(label2)
            }
        }
    } else {
        allBuckets
    }
}

private fun reorderProvider(model: JigglingProviderRowModel, direction: Int) {
    val newOrder = model.providerOrder.toMutableList()
    val idx = newOrder.indexOf(model.provider)
    val swapIdx = idx + direction
    if (swapIdx !in newOrder.indices) return
    newOrder[idx] = newOrder[swapIdx]
    newOrder[swapIdx] = model.provider
    model.prefs.setProviderOrder(newOrder)
}

private fun toggleBucketVisibility(model: JigglingProviderRowModel, bucket: QuotaBucket) {
    val key = "${model.provider.key}:${bucket.key}"
    val newHidden = model.hiddenBuckets.toMutableSet()
    if (newHidden.contains(key)) newHidden.remove(key) else newHidden.add(key)
    model.prefs.setHiddenBuckets(newHidden)
}

private fun reorderBucket(model: JigglingProviderRowModel, bucket: QuotaBucket, currentKeys: List<String>, direction: Int) {
    val newKeys = currentKeys.toMutableList()
    val idx = newKeys.indexOf(bucket.key)
    val swapIdx = idx + direction
    if (swapIdx !in newKeys.indices) return
    newKeys[idx] = newKeys[swapIdx]
    newKeys[swapIdx] = bucket.key
    val map = model.bucketOrders.toMutableMap()
    map[model.provider.key] = newKeys
    model.prefs.setBucketOrders(map)
}

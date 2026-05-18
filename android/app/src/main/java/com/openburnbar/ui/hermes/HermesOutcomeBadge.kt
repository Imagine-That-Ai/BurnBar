package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.HermesChatMessageOutcome
import com.openburnbar.ui.theme.AuroraColors

// MARK: - Hermes Outcome Badge + Retry Pill
//
// Inline tag rendered above the bubble for non-`.NORMAL` outcomes. Symbol
// + label so power users can tell at a glance why the model didn't
// produce a normal reply. Mirrors iOS `outcomeBadge` and `retryPill`
// inside `HermesTabView.swift`.

@Composable
fun HermesOutcomeBadge(
    outcome: HermesChatMessageOutcome,
    modifier: Modifier = Modifier
) {
    val label = outcome.label ?: return
    val color = outcomeBadgeColor(outcome)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = modifier
            .clip(RoundedCornerShape(percent = 50))
            .background(color.copy(alpha = 0.12f))
            .border(0.5.dp, color.copy(alpha = 0.45f), RoundedCornerShape(percent = 50))
            .padding(horizontal = 8.dp, vertical = 3.dp)
    ) {
        outcome.iconName?.let { name ->
            Icon(
                imageVector = iconForOutcome(name),
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(10.dp)
            )
        }
        Text(
            text = label,
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

/**
 * Inline retry pill rendered for an assistant turn whose outcome
 * supports retry. Tactile (the caller can wire haptics on tap).
 */
@Composable
fun HermesRetryPill(
    outcome: HermesChatMessageOutcome,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier
) {
    if (!outcome.supportsRetry) return
    val color = outcomeBadgeColor(outcome)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = modifier
            .clip(RoundedCornerShape(percent = 50))
            .clickable(onClick = onRetry)
            .background(color.copy(alpha = 0.10f))
            .border(0.75.dp, color.copy(alpha = 0.55f), RoundedCornerShape(percent = 50))
            .padding(horizontal = 10.dp, vertical = 5.dp)
    ) {
        Icon(
            imageVector = Icons.Filled.Refresh,
            contentDescription = "Try again",
            tint = color,
            modifier = Modifier.size(11.dp)
        )
        Text(
            text = "Try again",
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

private fun outcomeBadgeColor(outcome: HermesChatMessageOutcome): Color = when (outcome) {
    HermesChatMessageOutcome.NORMAL -> AuroraColors.lightTextSecondary
    HermesChatMessageOutcome.REFUSAL,
    HermesChatMessageOutcome.REASONING_FALLBACK -> AuroraColors.hermesAureate
    HermesChatMessageOutcome.LENGTH_CAP,
    HermesChatMessageOutcome.CONTENT_FILTER,
    HermesChatMessageOutcome.TOOL_CALL_NO_FOLLOW_UP,
    HermesChatMessageOutcome.EMPTY -> AuroraColors.error
}

private fun iconForOutcome(name: String): ImageVector = when (name) {
    "hand.raised.fill" -> Icons.Filled.PanTool
    "brain" -> Icons.Filled.Psychology
    "scissors" -> Icons.Filled.ContentCut
    "shield.lefthalf.filled" -> Icons.Filled.Shield
    "wrench.and.screwdriver" -> Icons.Filled.Build
    "exclamationmark.bubble" -> Icons.Filled.ErrorOutline
    "block" -> Icons.Filled.Block
    else -> Icons.Filled.AutoFixHigh
}

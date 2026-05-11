package com.openburnbar.ui.chartstudio

import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun InsightCardView(
    title: String,
    body: String,
    tone: InsightTone = InsightTone.NEUTRAL,
    onAction: (() -> Unit)? = null,
    actionLabel: String? = null
) {
    val tint = when (tone) {
        InsightTone.POSITIVE -> AuroraColors.success
        InsightTone.WARNING -> AuroraColors.warning
        InsightTone.NEGATIVE -> AuroraColors.error
        InsightTone.NEUTRAL -> AuroraColors.hermesAureate
    }

    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(AuroraSpacing.lg.dp)) {
            Text(
                text = title,
                fontSize = AuroraTypography.headline.sp,
                fontWeight = FontWeight.Bold,
                color = tint
            )
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            Text(
                text = body,
                fontSize = AuroraTypography.body.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (onAction != null && actionLabel != null) {
                Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                TextButton(onClick = onAction) {
                    Text(actionLabel, color = tint)
                }
            }
        }
    }
}

enum class InsightTone {
    POSITIVE, WARNING, NEGATIVE, NEUTRAL
}

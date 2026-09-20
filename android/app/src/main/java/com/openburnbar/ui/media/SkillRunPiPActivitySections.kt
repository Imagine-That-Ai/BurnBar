// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openburnbar.data.assistants.CLIAgentMissionSnapshot
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
internal fun SkillRunPiPScreen(mission: CLIAgentMissionSnapshot?, error: String?, onEnterPiP: () -> Unit, onClose: () -> Unit) {
    val accent =
        when {
            mission?.isWaitingForApproval == true -> AuroraColors.amber
            mission?.isTerminal == true -> AuroraColors.success
            else -> AuroraColors.ember
        }
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    listOf(
                        MaterialTheme.colorScheme.background,
                        accent.copy(alpha = 0.18f),
                        MaterialTheme.colorScheme.surface,
                    ),
                ),
            )
            .padding(14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.96f),
            shape = RoundedCornerShape(18.dp),
            shadowElevation = 10.dp,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(
                modifier = Modifier.padding(AuroraSpacing.MD.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
            ) {
                SkillRunPiPHeaderRow(
                    mission = mission,
                    error = error,
                    accent = accent,
                    onEnterPiP = onEnterPiP,
                    onClose = onClose,
                )
                SkillRunPiPBodyText(mission = mission, error = error)
                SkillRunPiPStatusPills(mission = mission, accent = accent)
            }
        }
    }
}

@Composable
private fun SkillRunPiPHeaderRow(mission: CLIAgentMissionSnapshot?, error: String?, accent: Color, onEnterPiP: () -> Unit, onClose: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        Icon(
            imageVector = skillRunPiPMissionIcon(mission, error),
            contentDescription = null,
            tint = accent,
        )
        Text(
            text = mission?.skillRunID?.displayLabel ?: "Hermes Skill Run",
            style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        IconButton(onClick = onEnterPiP) {
            Icon(
                imageVector = Icons.Filled.PictureInPictureAlt,
                contentDescription = "Enter Picture in Picture",
                tint = AuroraColors.amber,
            )
        }
        IconButton(onClick = onClose) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Close",
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SkillRunPiPBodyText(mission: CLIAgentMissionSnapshot?, error: String?) {
    Text(
        text = mission?.title ?: error ?: "Waiting for Skill Run...",
        style = AuroraType.body.copy(fontWeight = FontWeight.SemiBold),
        color = MaterialTheme.colorScheme.onSurface,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
    )
    Text(
        text =
        error
            ?: mission?.events?.lastOrNull()?.fullMessage
            ?: mission?.events?.lastOrNull()?.message
            ?: mission?.displayLiveSummary
            ?: mission?.currentStepLabel
            ?: "Opening live timeline.",
        style = AuroraType.caption,
        color = if (error == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
        maxLines = 4,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun SkillRunPiPStatusPills(mission: CLIAgentMissionSnapshot?, accent: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.XS.dp)) {
        SkillRunPiPPill(mission?.displayStatus?.uppercase() ?: "LISTENING", accent)
        mission?.deliveryMode?.displayLabel?.let { SkillRunPiPPill(it, AuroraColors.whimsy) }
    }
}

private fun skillRunPiPMissionIcon(mission: CLIAgentMissionSnapshot?, error: String?) = when {
    error != null -> Icons.Filled.WarningAmber
    mission?.isWaitingForApproval == true -> Icons.Filled.WarningAmber
    mission?.isTerminal == true -> Icons.Filled.CheckCircle
    else -> Icons.Filled.AutoAwesome
}

@Composable
private fun SkillRunPiPPill(text: String, color: Color) {
    Text(
        text = text,
        style = AuroraType.tiny.copy(fontWeight = FontWeight.Bold),
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier =
        Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(9.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    )
}

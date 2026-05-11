package com.openburnbar.ui.hermes

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
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
import com.openburnbar.ui.theme.AuroraColors

@Composable
fun HermesAtomChip(
    label: String,
    url: String,
    onClick: (String, String) -> Unit,
    modifier: Modifier = Modifier
) {
    val accent = accentForUrl(url)
    val icon = iconForUrl(url)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(7.dp))
            .clickable { onClick(label, url) }
            .background(accent.copy(alpha = 0.13f))
            .border(0.5.dp, accent.copy(alpha = 0.32f), RoundedCornerShape(7.dp))
            .padding(horizontal = 7.dp, vertical = 1.5.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(12.dp)
        )
        Spacer(modifier = Modifier.width(4.dp))
        Text(
            text = label,
            color = accent,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

private fun accentForUrl(url: String): Color {
    val lower = url.lowercase()
    return when {
        lower.contains("burn") -> AuroraColors.amber
        lower.contains("session") -> AuroraColors.hermesAureate
        lower.contains("provider") -> AuroraColors.ember
        lower.contains("model") -> AuroraColors.whimsy
        lower.contains("window") -> AuroraColors.hermesAureate
        lower.contains("tool") -> AuroraColors.blaze
        lower.contains("project") -> AuroraColors.amber
        lower.contains("token") -> AuroraColors.success
        lower.contains("quota") -> AuroraColors.warning
        lower.contains("runtime") -> AuroraColors.hermesAureate
        else -> AuroraColors.hermesMercury
    }
}

private fun iconForUrl(url: String): ImageVector {
    val lower = url.lowercase()
    return when {
        lower.contains("burn") -> Icons.Filled.LocalFireDepartment
        lower.contains("session") -> Icons.Filled.ChatBubble
        lower.contains("provider") -> Icons.Filled.Business
        lower.contains("model") -> Icons.Filled.Psychology
        lower.contains("window") -> Icons.Filled.CalendarToday
        lower.contains("tool") -> Icons.Filled.Construction
        lower.contains("project") -> Icons.Filled.Folder
        lower.contains("token") -> Icons.Filled.Token
        lower.contains("quota") -> Icons.Filled.Speed
        lower.contains("runtime") -> Icons.Filled.Computer
        else -> Icons.Filled.OpenInNew
    }
}

// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.pro

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraColors

@Composable
internal fun CloudBadgePickerTile(style: CloudBadgeStyle, isSelected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onClick),
    ) {
        CloudBadgePickerTileArt(style = style, isSelected = isSelected, shape = shape)
        Spacer(Modifier.height(10.dp))
        CloudBadgePickerTileLabels(style = style, isSelected = isSelected)
    }
}

@Composable
private fun CloudBadgePickerTileArt(style: CloudBadgeStyle, isSelected: Boolean, shape: RoundedCornerShape) {
    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .height(170.dp)
            .shadow(
                elevation = if (isSelected) 14.dp else 4.dp,
                shape = shape,
                ambientColor = AuroraColors.ember,
                spotColor = AuroraColors.ember,
            )
            .clip(shape)
            .background(
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        AuroraColors.ember.copy(alpha = if (isSelected) 0.34f else 0.16f),
                        AuroraColors.amber.copy(alpha = if (isSelected) 0.26f else 0.12f),
                        AuroraColors.blaze.copy(alpha = if (isSelected) 0.22f else 0.10f),
                    ),
                ),
            )
            .border(
                width = if (isSelected) 1.6.dp else 0.7.dp,
                brush = cloudBadgeTileBorderBrush(isSelected),
                shape = shape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        CloudBadge(size = CloudBadgeSize.Large, styleOverride = style)
    }
}

@Composable
private fun CloudBadgePickerTileLabels(style: CloudBadgeStyle, isSelected: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (isSelected) {
            Icon(
                imageVector = Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = AuroraColors.ember,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(4.dp))
        }
        Text(
            text = style.title,
            color = AuroraColors.darkTextPrimary,
            fontWeight = FontWeight.SemiBold,
            fontSize = 14.sp,
        )
    }
    Text(
        text = style.blurb,
        color = AuroraColors.darkTextMuted,
        fontSize = 11.sp,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(top = 2.dp, start = 4.dp, end = 4.dp),
    )
}

private fun cloudBadgeTileBorderBrush(isSelected: Boolean): Brush =
    if (isSelected) {
        Brush.linearGradient(
            colors = listOf(AuroraColors.amber, AuroraColors.ember, AuroraColors.amber),
        )
    } else {
        Brush.linearGradient(
            colors =
            listOf(
                Color.White.copy(alpha = 0.12f),
                Color.White.copy(alpha = 0.04f),
            ),
        )
    }
